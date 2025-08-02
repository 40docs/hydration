#!/usr/bin/env bash
#
# Infrastructure Hydration Control Script
#
# This script orchestrates a multi-repository documentation and infrastructure platform.
# It manages 8+ interconnected repositories, automating GitHub/Azure authentication,
# SSH deploy key generation, secrets management, and CI/CD workflow deployment.
#
# Usage: ./infrastructure.sh [--initialize|--destroy|--sync-forks|--deploy-keys|--help]
#
# Author: 40docs
# Version: 1.0

set -euo pipefail
IFS=$'\n\t'

# Global Constants and Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/config.json"
readonly MAX_RETRIES=3
readonly RETRY_INTERVAL=5

# Initialize global variables
RUN_INFRASTRUCTURE="false"
CURRENT_DIR=""
declare -a CONTENTREPOS=()
declare -a CONTENTREPOSONLY=()
declare -a DEPLOYKEYSREPOS=()
declare -a PATREPOS=()
declare -a ALLREPOS=()

# Export environment variables
export GH_PAGER=""

# Ensure the config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: $CONFIG_FILE file not found. Exiting." >&2
  exit 1
fi

# Parse configuration from JSON
parse_config() {
    local config_file="$1"

    # Core configuration
    DEPLOYED=$(jq -r '.DEPLOYED' "$config_file")
    PROJECT_NAME=$(jq -r '.PROJECT_NAME' "$config_file")
    LOCATION=$(jq -r '.LOCATION' "$config_file")
    DNS_ZONE=$(jq -r '.DNS_ZONE' "$config_file")
    CLOUDSHELL=$(jq -r '.CLOUDSHELL // "false"' "$config_file")

    # Repository names
    THEME_REPO_NAME=$(jq -r '.THEME_REPO_NAME' "$config_file")
    LANDING_PAGE_REPO_NAME=$(jq -r '.LANDING_PAGE_REPO_NAME' "$config_file")
    DOCS_BUILDER_REPO_NAME=$(jq -r '.DOCS_BUILDER_REPO_NAME' "$config_file")
    INFRASTRUCTURE_REPO_NAME=$(jq -r '.INFRASTRUCTURE_REPO_NAME' "$config_file")
    MANIFESTS_INFRASTRUCTURE_REPO_NAME=$(jq -r '.MANIFESTS_INFRASTRUCTURE_REPO_NAME' "$config_file")
    MANIFESTS_APPLICATIONS_REPO_NAME=$(jq -r '.MANIFESTS_APPLICATIONS_REPO_NAME' "$config_file")
    MKDOCS_REPO_NAME=$(jq -r '.MKDOCS_REPO_NAME' "$config_file")
    HELM_CHARTS_REPO_NAME=$(jq -r '.HELM_CHARTS_REPO_NAME' "$config_file")

    # Build repository arrays
    while IFS= read -r repo; do
        CONTENTREPOSONLY+=("$repo")
    done < <(jq -r '.REPOS[]' "$config_file")

    # Content repositories (includes theme and landing page)
    CONTENTREPOS=("${CONTENTREPOSONLY[@]}")
    CONTENTREPOS+=("$THEME_REPO_NAME")
    CONTENTREPOS+=("$LANDING_PAGE_REPO_NAME")

    # Deploy keys repositories
    DEPLOYKEYSREPOS=("$MANIFESTS_INFRASTRUCTURE_REPO_NAME" "$MANIFESTS_APPLICATIONS_REPO_NAME")

    # PAT repositories
    PATREPOS=("${CONTENTREPOSONLY[@]}")
    PATREPOS+=("$THEME_REPO_NAME" "$LANDING_PAGE_REPO_NAME" "$INFRASTRUCTURE_REPO_NAME")
    PATREPOS+=("$MANIFESTS_INFRASTRUCTURE_REPO_NAME" "$MANIFESTS_APPLICATIONS_REPO_NAME")
    PATREPOS+=("$DOCS_BUILDER_REPO_NAME")

    # All repositories
    ALLREPOS=("${CONTENTREPOSONLY[@]}")
    ALLREPOS+=("$THEME_REPO_NAME" "$LANDING_PAGE_REPO_NAME" "$DOCS_BUILDER_REPO_NAME")
    ALLREPOS+=("$INFRASTRUCTURE_REPO_NAME" "$MANIFESTS_INFRASTRUCTURE_REPO_NAME")
    ALLREPOS+=("$MANIFESTS_APPLICATIONS_REPO_NAME" "$MKDOCS_REPO_NAME" "$HELM_CHARTS_REPO_NAME")
}

# Initialize configuration
parse_config "$CONFIG_FILE"
CURRENT_DIR="$(pwd)"

# Validate configuration
validate_config() {
    if [[ -z "$DEPLOYED" || -z "$PROJECT_NAME" || -z "$LOCATION" || ${#CONTENTREPOS[@]} -eq 0 ]]; then
        echo "Error: Failed to initialize variables from $CONFIG_FILE." >&2
        exit 1
    fi
}

# Initialize derived variables
initialize_environment() {
    local github_org
    github_org=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)/.*#\1#p')

    if [[ -z "$github_org" ]]; then
        echo "Error: Could not detect GitHub organization." >&2
        exit 1
    fi

    readonly GITHUB_ORG="$github_org"

    # Adjust naming for forks
    if [[ "$GITHUB_ORG" != "$PROJECT_NAME" ]]; then
        PROJECT_NAME="${GITHUB_ORG}-${PROJECT_NAME}"
        DNS_ZONE="${GITHUB_ORG}.${DNS_ZONE}"
        readonly LETSENCRYPT_URL='https://acme-staging-v02.api.letsencrypt.org/directory'
    else
        readonly LETSENCRYPT_URL='https://acme-v02.api.letsencrypt.org/directory'
    fi

    # Initialize derived constants
    readonly DOCS_FQDN="docs.${DNS_ZONE}"
    readonly OLLAMA_FQDN="ollama.${DNS_ZONE}"
    readonly ARTIFACTS_FQDN="artifacts.${DNS_ZONE}"

    # Generate Azure storage account name (max 24 chars, alphanumeric only)
    AZURE_STORAGE_ACCOUNT_NAME=$(echo "rmmuap${PROJECT_NAME}account" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z' | cut -c 1-24)
    readonly AZURE_STORAGE_ACCOUNT_NAME

    # Handle MkDocs repo name format
    if [[ "$MKDOCS_REPO_NAME" != */* ]]; then
        MKDOCS_REPO_NAME="ghcr.io/${GITHUB_ORG}/${MKDOCS_REPO_NAME}"
    fi
    if [[ "$MKDOCS_REPO_NAME" != *:* ]]; then
        MKDOCS_REPO_NAME="${MKDOCS_REPO_NAME}:latest"
    fi
}

# Initialize the environment
validate_config
initialize_environment

# Utility Functions
#

# Retry a command with exponential backoff
retry_command() {
    local -r max_attempts="$1"
    local -r delay="$2"
    local -r description="$3"
    shift 3

    local attempt=1
    while (( attempt <= max_attempts )); do
        if "$@"; then
            return 0
        fi

        if (( attempt < max_attempts )); then
            echo "Warning: $description failed. Attempt $attempt of $max_attempts. Retrying in ${delay}s..." >&2
            sleep "$delay"
        else
            echo "Error: $description failed after $max_attempts attempts." >&2
            return 1
        fi

        ((attempt++))
    done
}

# Get GitHub username from authenticated session
get_github_username() {
    local output

    if ! output=$(gh auth status 2>/dev/null); then
        echo "Error: Unable to retrieve GitHub authentication status." >&2
        return 1
    fi

    echo "$output" | grep -oE "account [a-zA-Z0-9_\-]+" | awk '{print $2}'
}

# Prompt for GitHub username with default
prompt_github_username() {
    local default_user
    default_user=$(get_github_username) || default_user=""

    read -r -e -p "Enter your personal GitHub account name [${default_user:-no user found}]: " USER
    USER="${USER:-$default_user}"

    if [[ -z "$USER" ]]; then
        echo "Error: No GitHub username provided." >&2
        exit 1
    fi
}

# GitHub Authentication and Management
#

# Ensure GitHub CLI is authenticated
update_github_auth_login() {
    export GITHUB_TOKEN=""

    if ! gh auth status &>/dev/null; then
        echo "GitHub authentication required..."
        if ! gh auth login; then
            echo "Error: GitHub login failed." >&2
            exit 1
        fi
    fi

    gh auth setup-git
    echo "GitHub authentication verified."
}

# Manage GitHub repository forks
update_github_forks() {
    local -r upstream_org="$GITHUB_ORG"
    local -r repo_owner="$GITHUB_ORG"
    local -r max_retries=3
    local -r delay_seconds=5

    echo "Processing repository forks..."

    for repo_name in "${ALLREPOS[@]}"; do
        echo "Processing repository: $repo_name"

        if gh repo view "${repo_owner}/${repo_name}" &>/dev/null; then
            # Repository exists - check if it's a fork
            local repo_info parent
            repo_info=$(gh repo view "$repo_owner/$repo_name" --json parent)
            parent=$(echo "$repo_info" | jq -r '.parent | if type == "object" then (.owner.login + "/" + .name) else "" end')

            if [[ -n "$parent" ]]; then
                # Repository is a fork, sync it
                echo "  Syncing fork: $repo_name"
                if ! gh repo sync "$repo_owner/$repo_name" --branch main --force; then
                    echo "  Warning: Failed to sync $repo_name" >&2
                fi
            else
                echo "  Repository $repo_name exists but is not a fork. Skipping."
            fi
        else
            # Repository does not exist, fork it
            echo "  Forking $upstream_org/$repo_name..."
            if gh repo fork "$upstream_org/$repo_name" --clone=false; then
                echo "  Successfully forked $upstream_org/$repo_name"

                # Retry sync after forking
                if ! retry_command "$max_retries" "$delay_seconds" "sync $repo_name after forking" \
                    gh repo sync "$repo_owner/$repo_name" --branch main --force; then
                    echo "  Warning: Failed to sync $repo_name after forking" >&2
                fi
            else
                echo "  Error: Failed to fork $upstream_org/$repo_name" >&2
            fi
        fi
    done

    echo "Repository fork processing complete."
}


# Copy dispatch workflow to content repositories
copy_dispatch_workflow_to_content_repos() {
    local -r workflow_file="dispatch.yml"
    local temp_dir

    # Create temporary directory with cleanup trap
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT

    # Validate workflow file exists
    if [[ ! -f "$workflow_file" ]]; then
        echo "Error: Workflow file '$workflow_file' not found in current directory." >&2
        return 1
    fi

    echo "Copying dispatch workflow to content repositories..."

    for repo in "${CONTENTREPOS[@]}"; do
        echo "  Processing repository: $repo"

        # Work in temp directory
        cd "$temp_dir" || {
            echo "    Error: Failed to change to temp directory" >&2
            continue
        }

        # Clone repository
        if ! git clone "https://github.com/${GITHUB_ORG}/${repo}"; then
            echo "    Error: Failed to clone repository $repo" >&2
            continue
        fi

        cd "$repo" || {
            echo "    Error: Failed to change to repository directory" >&2
            continue
        }

        # Setup workflow directory and copy file
        mkdir -p .github/workflows
        cp "${CURRENT_DIR}/${workflow_file}" .github/workflows/dispatch.yml

        # Commit and push if changes exist
        if [[ -n $(git status --porcelain) ]]; then
            git add .
            if git commit -m "Add or update dispatch.yml workflow"; then
                if ! git push origin main; then
                    echo "    Warning: Failed to push changes to $repo" >&2
                fi
            else
                echo "    Warning: No changes to commit for $repo" >&2
            fi
        else
            echo "    No changes detected for $repo"
        fi
    done

    # Return to original directory
    cd "$CURRENT_DIR" || {
        echo "Error: Failed to return to original directory" >&2
        exit 1
    }

    echo "Dispatch workflow copy complete."
}

# Azure Authentication and Management
#

# Ensure Azure CLI is authenticated
update_azure_auth_login() {
    echo "Verifying Azure authentication..."

    # Check if account is active and token is valid
    if ! az account show &>/dev/null || ! az account get-access-token &>/dev/null; then
        echo "Azure authentication required..."
        if ! az login --use-device-code; then
            echo "Error: Azure login failed." >&2
            exit 1
        fi
    fi

    # Get owner email and validate format
    OWNER_EMAIL=$(az account show --query user.name -o tsv)
    if [[ -z "$OWNER_EMAIL" || ! "$OWNER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "Error: OWNER_EMAIL is not properly initialized or is not in a valid email format." >&2
        exit 1
    fi

    get_signed_in_user_name
    echo "Azure authentication verified."
}

update_owner_email() {

  local max_retries=3
  local retry_interval=5
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if gh secret set OWNER_EMAIL -b "$OWNER_EMAIL" --repo "${GITHUB_ORG}/${INFRASTRUCTURE_REPO_NAME}"; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if [[ $attempt -lt $max_retries ]]; then
        echo "Warning: Failed to set GitHub secret owner_email. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret owner_email:$ after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
  done
}

get_signed_in_user_name() {
  # Get the JSON output of the current signed-in user
  user_info=$(az ad signed-in-user show --output json)

  # Extract givenName, surname, and displayName from the JSON output
  given_name=$(echo "$user_info" | jq -r '.givenName')
  surname=$(echo "$user_info" | jq -r '.surname')
  display_name=$(echo "$user_info" | jq -r '.displayName')

  # Determine which value to use for the NAME variable
  if [[ "$given_name" != "null" && "$surname" != "null" ]]; then
    NAME="$given_name $surname"
  elif [[ "$display_name" != "null" ]]; then
    NAME="$display_name"
  else
    read -p "Please enter your full name: " NAME
  fi

  # Export the NAME variable for further use if needed
  export NAME
}

update_azure_subscription_selection() {
  local current_sub_name current_sub_id confirm subscription_name login_choice

  current_sub_name=$(az account show --query "NAME" --output tsv 2>/dev/null)
  current_sub_id=$(az account show --query "id" --output tsv 2>/dev/null)

  if [[ -z "$current_sub_name" || -z "$current_sub_id" ]]; then
    echo "Failed to retrieve current subscription."
    echo "This could mean you're not logged in to Azure or no subscription is set as default."
    echo ""
    echo "Options:"
    echo "1) Login to Azure and select subscription"
    echo "2) Exit script"
    echo ""
    read -rp "Choose an option (1-2): " login_choice

    case "$login_choice" in
      1)
        echo "Initiating Azure login..."
        if ! az login --use-device-code; then
          echo "Error: Azure login failed." >&2
          exit 1
        fi

        # Retry getting subscription info after login
        current_sub_name=$(az account show --query "NAME" --output tsv 2>/dev/null)
        current_sub_id=$(az account show --query "id" --output tsv 2>/dev/null)

        if [[ -z "$current_sub_name" || -z "$current_sub_id" ]]; then
          echo "No default subscription found after login. Listing available subscriptions..."
          az account list --query '[].{Name:name, ID:id}' --output table
          read -rp "Enter the name of the subscription you want to set as default: " subscription_name
          SUBSCRIPTION_ID=$(az account list --query "[?name=='$subscription_name'].id" --output tsv 2>/dev/null)
          if [[ -z "$SUBSCRIPTION_ID" ]]; then
            echo "Invalid subscription name. Exiting."
            exit 1
          fi
          az account set --subscription "$SUBSCRIPTION_ID"
          echo "Successfully set subscription: $subscription_name"
          return
        fi
        ;;
      2)
        echo "Exiting script as requested."
        exit 0
        ;;
      *)
        echo "Invalid option. Exiting."
        exit 1
        ;;
    esac
  fi

  read -rp "Use the current default subscription: $current_sub_name (ID: $current_sub_id) (Y/n)? " confirm
  confirm=${confirm:-Y}  # Default to 'Y' if the user presses enter

  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    SUBSCRIPTION_ID="$current_sub_id"
  else
    az account list --query '[].{Name:name, ID:id}' --output table
    read -rp "Enter the name of the subscription you want to set as default: " subscription_name
    SUBSCRIPTION_ID=$(az account list --query "[?name=='$subscription_name'].id" --output tsv 2>/dev/null)
    if [[ -z "$SUBSCRIPTION_ID" ]]; then
      echo "Invalid subscription name. Exiting."
      exit 1
    fi
    az account set --subscription "$SUBSCRIPTION_ID"
  fi
}

update_azure_tfstate_resources() {
  # Ensure OWNER_EMAIL is set
  if [[ -z "$OWNER_EMAIL" || ! "$OWNER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Error: OWNER_EMAIL is not properly initialized or is not in a valid email format." >&2
    return 1
  fi

  # Ensure NAME is set
  if [[ -z "$NAME" ]]; then
    echo "Error: NAME is not properly initialized." >&2
    return 1
  fi

  # Replace spaces with underscores in tag values
  OWNER_EMAIL_SANITIZED=${OWNER_EMAIL// /_}
  NAME_SANITIZED=${NAME// /_}

  # Define resource tags
  TAGS="Username=${OWNER_EMAIL_SANITIZED} FullName=${NAME_SANITIZED}"

  # Check if resource group exists
  if ! az group show -n "${PROJECT_NAME}-tfstate" &>/dev/null; then
    az group create -n "${PROJECT_NAME}-tfstate" -l "${LOCATION}"
  fi

  # Update tags for resource group
  az tag update --resource-id "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${PROJECT_NAME}-tfstate" --operation merge --tags $TAGS

  # Check if storage account exists
  if ! az storage account show -n "${AZURE_STORAGE_ACCOUNT_NAME}" -g "${PROJECT_NAME}-tfstate" &>/dev/null; then
    az storage account create -n "${AZURE_STORAGE_ACCOUNT_NAME}" -g "${PROJECT_NAME}-tfstate" -l "${LOCATION}" --sku Standard_LRS
  fi

  # Update tags for storage account
  az tag update --resource-id "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${PROJECT_NAME}-tfstate/providers/Microsoft.Storage/storageAccounts/${AZURE_STORAGE_ACCOUNT_NAME}" --operation merge --tags $TAGS

  # Adding a delay to ensure resources are fully available
  sleep 10

  # Attempt to create or verify storage container
  attempt=1
  max_attempts=5
  while (( attempt <= max_attempts )); do
    if az storage container show -n "${PROJECT_NAME}tfstate" --account-name "${AZURE_STORAGE_ACCOUNT_NAME}" &>/dev/null; then
      break
    else
      if az storage container create -n "${PROJECT_NAME}tfstate" --account-name "${AZURE_STORAGE_ACCOUNT_NAME}" --auth-mode login --metadata Username="$OWNER_EMAIL_SANITIZED" Name="$NAME_SANITIZED"; then
        break
      else
        sleep 5
      fi
    fi
    (( attempt++ ))
  done

  if (( attempt > max_attempts )); then
    echo "Error: Failed to create storage container after $max_attempts attempts."
    return 1
  fi
}

update_azure_credentials() {
  local sp_output
  # Create or get existing service principal
  sp_output=$(az ad sp create-for-rbac --name "${PROJECT_NAME}" --role Contributor --scopes "/subscriptions/${1}" --sdk-auth --only-show-errors)
  clientId=$(echo "$sp_output" | jq -r .clientId)
  tenantId=$(echo "$sp_output" | jq -r .tenantId)
  clientSecret=$(echo "$sp_output" | jq -r .clientSecret)
  subscriptionId=$(echo "$sp_output" | jq -r .subscriptionId)
  AZURE_CREDENTIALS=$(echo "$sp_output" | jq -c '{clientId, clientSecret, subscriptionId, tenantId, resourceManagerEndpointUrl}')

  if [[ -z "$clientId" || "$clientId" == "null" ]]; then
    echo "Error: Failed to retrieve or create the service principal. Exiting."
    exit 1
  fi

  role_exists=$(az role assignment list --assignee "$clientId" --role "User Access Administrator" --scope "/subscriptions/$1" --query '[].id' -o tsv)

  if [[ -z "$role_exists" ]]; then
    az role assignment create --assignee "$clientId" --role "User Access Administrator" --scope "/subscriptions/$1" || {
      echo "Failed to assign the role. Exiting."
      exit 1
    }
  fi
}

delete_azure_tfstate_resources() {
  # Delete storage container if it exists
  if az storage container show -n "${PROJECT_NAME}tfstate" --account-name "${AZURE_STORAGE_ACCOUNT_NAME}" &>/dev/null; then
    az storage container delete -n "${PROJECT_NAME}tfstate" --account-name "${AZURE_STORAGE_ACCOUNT_NAME}"
  fi

  # Delete storage account if it exists
  if az storage account show -n "${AZURE_STORAGE_ACCOUNT_NAME}" -g "${PROJECT_NAME}-tfstate" &>/dev/null; then
    az storage account delete -n "${AZURE_STORAGE_ACCOUNT_NAME}" -g "${PROJECT_NAME}-tfstate" --yes
  fi

  # Delete resource group if it exists
  if az group show -n "${PROJECT_NAME}-tfstate" &>/dev/null; then
    az group delete -n "${PROJECT_NAME}-tfstate" --yes --no-wait
  fi
}

delete_azure_credentials() {
  # Check if service principal exists
  local sp_exists
  sp_exists=$(az ad sp show --id "http://${PROJECT_NAME}" --query "appId" -o tsv 2>/dev/null)

  if [[ -n "$sp_exists" ]]; then
    # Remove role assignment
    az role assignment delete --assignee "$sp_exists" --role "User Access Administrator" --scope "/subscriptions/$1"

    # Delete service principal
    az ad sp delete --id "http://${PROJECT_NAME}"
  else
    echo "Service principal '${PROJECT_NAME}' does not exist."
  fi
}

update_pat() {
  local PAT
  local new_PAT_value=""
  local attempts
  local max_attempts=3
  for repo in "${PATREPOS[@]}"; do
    if gh secret list --repo ${GITHUB_ORG}/$repo | grep -q '^PAT\s'; then
      PAT="exists"
    fi
  done
  if [[ -z "$PAT" ]]; then
    read -srp "Enter value for GitHub PAT: " new_PAT_value
    echo
  else
    read -rp "Change the GitHub PAT ? (N/y): " response
    response=${response:-N}
    if [[ "$response" =~ ^[Yy]$ ]]; then
      read -srp "Enter new value for GitHub PAT: " new_PAT_value
      echo
    else
      new_PAT_value=""
    fi
  fi
  if [[ -n "$new_PAT_value" ]]; then
    for repo in "${PATREPOS[@]}"; do
      local attempts=0
      local success=false
      while (( attempts < max_attempts )); do
        if gh secret set PAT -b "$new_PAT_value" --repo ${GITHUB_ORG}/$repo 2>/dev/null; then
          echo "Successfully updated PAT for repository: $repo"
          success=true
          break
        else
          ((attempts++))
          if (( attempts < max_attempts )); then
            echo "Attempt $attempts failed. Retrying in $retry_interval seconds..."
            sleep $retry_interval
          else
            echo "Failed to update PAT for repository: $repo after $max_attempts attempts."
          fi
        fi
      done
      # If all attempts failed, this might help with script continuation
      if ! $success; then
        echo "All attempts to update PAT for $repo failed."
      fi
    done
  fi
}

update_manifests_applications_variables() {
    local max_retries=3
    local retry_interval=5
    for variable in \
      "OLLAMA_FQDN:$OLLAMA_FQDN" \
      "ARTIFACTS_FQDN:$ARTIFACTS_FQDN" \
      "DOCS_FQDN:$DOCS_FQDN" ; do
      key="${variable%%:*}"
      value="${variable#*:}"
      for ((attempt=1; attempt<=max_retries; attempt++)); do
        if gh variable set "$key" -b "$value" --repo ${GITHUB_ORG}/$MANIFESTS_APPLICATIONS_REPO_NAME; then
          break
        else
          if [[ $attempt -lt $max_retries ]]; then
            echo "Warning: Failed to set GitHub variable $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
            sleep $retry_interval
          else
            echo "Error: Failed to set GitHub variable $key after $max_retries attempts. Exiting."
            exit 1
          fi
        fi
      done
    done
}

update_content_repos_variables() {
  local max_retries=3
  local retry_interval=5
  for repo in "${CONTENTREPOS[@]}"; do
    for variable in \
      "DOCS_BUILDER_REPO_NAME:$DOCS_BUILDER_REPO_NAME"; do
      key="${variable%%:*}"
      value="${variable#*:}"
      for ((attempt=1; attempt<=max_retries; attempt++)); do
        if gh variable set "$key" -b "$value" --repo ${GITHUB_ORG}/$repo; then
          break
        else
          if [[ $attempt -lt $max_retries ]]; then
            echo "Warning: Failed to set GitHub variable $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
            sleep $retry_interval
          else
            echo "Error: Failed to set GitHub variable $key after $max_retries attempts. Exiting."
            exit 1
          fi
        fi
      done
    done
  done
}

update_deploy_keys() {
  local max_retries=3
  local retry_interval=5
  local replace_keys
  read -r -p "Do you want to replace the deploy-keys? (N/y): " replace_keys
  replace_keys=${replace_keys:-n}

  if [[ ! $replace_keys =~ ^[Yy]$ ]]; then
    return 0
  fi
  local attempts
  local max_attempts=3
  for repo in "${DEPLOYKEYSREPOS[@]}"; do
    local key_path="$HOME/.ssh/id_ed25519-$repo"
    if [ ! -f "$key_path" ]; then
      ssh-keygen -t ed25519 -N "" -f "$key_path" -q
    fi
    deploy_key_id=$(gh repo deploy-key list --repo ${GITHUB_ORG}/$repo --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')
    if [[ -n "$deploy_key_id" ]]; then
      attempts=0
      while (( attempts < max_attempts )); do
        if gh repo deploy-key delete --repo ${GITHUB_ORG}/$repo "$deploy_key_id"; then
          break
        else
          ((attempts++))
          if (( attempts < max_attempts )); then
            echo "Retrying in $retry_interval seconds..."
            sleep $retry_interval
          fi
        fi
      done
    fi
    attempts=0
    while (( attempts < max_attempts )); do
      if gh repo deploy-key add $HOME/.ssh/id_ed25519-${repo}.pub --title 'DEPLOY-KEY' --repo ${GITHUB_ORG}/$repo; then
        RUN_INFRASTRUCTURE="true"
        break
      else
        ((attempts++))
        if (( attempts < max_attempts )); then
          echo "Retrying in $retry_interval seconds..."
          sleep $retry_interval
        fi
      fi
    done

    secret_key=$(cat $HOME/.ssh/id_ed25519-$repo)
    normalized_repo=$(echo "$repo" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set ${normalized_repo}_SSH_PRIVATE_KEY -b "$secret_key" --repo ${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME; then
        RUN_INFRASTRUCTURE="true"
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret ${normalized_repo}_ssh_private_key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret ${normalized_repo}_ssh_private_key after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done

  done
}

update_docs_builder_variables() {
  local max_retries=3
  local retry_interval=5
  local attempt=1

  # Update variables using a loop
  for variable in \
    "DNS_ZONE:${DNS_ZONE}" \
    "MANIFESTS_APPLICATIONS_REPO_NAME:$MANIFESTS_APPLICATIONS_REPO_NAME" ; do

    key="${variable%%:*}"
    value="${variable#*:}"

    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh variable set "$key" -b "$value" --repo "${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME"; then
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub variable $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub variable $key after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done

  # Set MKDOCS_REPO_NAME as a secret since it's referenced as secrets.mkdocs_repo_name
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if gh secret set "MKDOCS_REPO_NAME" -b "$MKDOCS_REPO_NAME" --repo "${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME"; then
      break
    else
      if [[ $attempt -lt $max_retries ]]; then
        echo "Warning: Failed to set GitHub secret mkdocs_repo_name. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret mkdocs_repo_name after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
  done
}

copy_docs_builder_workflow_to_docs_builder_repo() {
  local tpl_file="${current_dir}/docs-builder.tpl"
  local github_token="$PAT"
  local output_file=".github/workflows/docs-builder.yml"
  local theme_secret_key_name
  theme_secret_key_name="$(echo "$THEME_REPO_NAME" | tr '[:upper:]-' '[:lower:]_')_ssh_private_key"

  # Use a trap to ensure that temporary directories are cleaned up safely
  TEMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TEMP_DIR"' EXIT

  # Check if dispatch.yml tpl_file exists before proceeding
  if [[ ! -f "$tpl_file" ]]; then
    echo "Error: File $tpl_file not found. Please ensure it is present in the current directory."
    exit 1
  fi
  cd "$TEMP_DIR" || exit 1
  if ! git clone "https://$github_token@github.com/${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME"; then
    echo "Error: Failed to clone repository $DOCS_BUILDER_REPO_NAME"
    exit 1
  fi

  cd "$DOCS_BUILDER_REPO_NAME" || exit 1
  mkdir -p "$(dirname "$output_file")"

  # Start building the clone repo commands string
  local clone_commands=""
  local landing_page_secret_key_name
  landing_page_secret_key_name="$(echo "${LANDING_PAGE_REPO_NAME}" | tr '[:upper:]-' '[:lower:]_')_ssh_private_key"
  clone_commands+="      - name: Clone Landing Page\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"
  clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
  clone_commands+="          echo '\${{ secrets.${landing_page_secret_key_name}}}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
  clone_commands+="          mkdir \$TEMP_DIR/landing-page\n"
  clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${LANDING_PAGE_REPO_NAME}.git \$TEMP_DIR/landing-page/docs\n\n"

  clone_commands+="      - name: Link mkdocs.yml\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"
  clone_commands+="          echo 'site_name: \"Hands on Labs\"' > \$TEMP_DIR/landing-page/mkdocs.yml\n"
  clone_commands+="          echo 'INHERIT: docs/theme/mkdocs.yml' > \$TEMP_DIR/landing-page/mkdocs.yml\n\n"

  local theme_secret_key_name
  theme_secret_key_name="$(echo "${THEME_REPO_NAME}" | tr '[:upper:]-' '[:lower:]_')_ssh_private_key"
  clone_commands+="      - name: Clone Theme\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"
  clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
  clone_commands+="          echo '\${{ secrets.${theme_secret_key_name}}}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
  clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${THEME_REPO_NAME}.git \$TEMP_DIR/landing-page/docs/theme\n"
  clone_commands+="          docker run --rm -v \$TEMP_DIR/landing-page:/docs \${{ secrets.mkdocs_repo_name }} build -c -d site/\n"
  clone_commands+="          mkdir -p \$TEMP_DIR/build/\n"
  clone_commands+="          cp -a \$TEMP_DIR/landing-page/site \$TEMP_DIR/build/\n\n"

  clone_commands+="      - name: Clone Content Repos\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"
  local secret_key_name
  for repo in "${CONTENTREPOSONLY[@]}"; do
    secret_key_name="$(echo "$repo" | tr '[:upper:]-' '[:lower:]_')_ssh_private_key"
    clone_commands+="          mkdir -p \$TEMP_DIR/src/${repo}\n"
    clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
    clone_commands+="          echo '\${{ secrets.${secret_key_name} }}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
    clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${repo}.git \$TEMP_DIR/src/${repo}/docs\n"
    clone_commands+="          echo '# Hands on Labs' > \$TEMP_DIR/src/${repo}/docs/index.md\n"
    clone_commands+="          cp -a \$TEMP_DIR/landing-page/docs/theme \$TEMP_DIR/src/${repo}/docs/\n"
    clone_commands+="          echo 'site_name: \"Hands on Labs\"' > \$TEMP_DIR/src/${repo}/mkdocs.yml\n"
    clone_commands+="          echo 'INHERIT: docs/theme/mkdocs.yml' >> \$TEMP_DIR/src/${repo}/mkdocs.yml\n"
    clone_commands+="          docker run --rm -v \$TEMP_DIR/src/${repo}:/docs \${{ secrets.mkdocs_repo_name }} build -d site/\n"
    clone_commands+="          mv \$TEMP_DIR/src/${repo}/site \$TEMP_DIR/build/site/${repo}\n\n"
  done

  echo -e "$clone_commands" | sed -e "/%%INSERTCLONEREPO%%/r /dev/stdin" -e "/%%INSERTCLONEREPO%%/d" "$tpl_file" | awk 'BEGIN { blank=0 } { if (/^$/) { blank++; if (blank <= 1) print; } else { blank=0; print; } }' > "$output_file"

  if [[ -n $(git status --porcelain) ]]; then
    git add $output_file
    if git commit -m "Add or update docs-builder.yml workflow"; then
      git switch -C docs-builder main && git push && gh repo set-default $GITHUB_ORG/docs-builder && gh pr create --title "Initializing repo" --body "Update docs builder" && gh pr merge -m --delete-branch || echo "Warning: Failed to push changes to $repo"
    else
      echo "Warning: No changes to commit for $repo"
    fi
  else
    echo "No changes detected for $repo"
  fi
  cd "$current_dir" || exit 1

}

update_lw_agent_token() {
    local max_retries=3
    local retry_interval=5
    if gh secret list --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME | grep -q '^LW_AGENT_TOKEN\s'; then
        read -rp "Change the FortiCNAPP Agent token ? (N/y): " response
        response=${response:-N}
        if [[ "$response" =~ ^[Yy]$ ]]; then
            read -srp "Enter new value for Laceworks Agent token: " new_LW_AGENT_TOKEN_value
            echo
            if gh secret set LW_AGENT_TOKEN -b "$new_LW_AGENT_TOKEN_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
              echo "Updated Laceworks token"
            else
              if [[ $attempt -lt $max_retries ]]; then
                echo "Warning: Failed to set GitHub secret lw_agent_token. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
                sleep $retry_interval
              else
                echo "Error: Failed to set GitHub secret lw_agent_token after $max_retries attempts. Exiting."
                exit 1
              fi
            fi
        fi
    else
        read -srp "Enter value for Laceworks token: " new_LW_AGENT_TOKEN_value
        echo
        if gh secret set LW_AGENT_TOKEN -b "$new_LW_AGENT_TOKEN_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
          echo "Updated Laceworks Token"
        else
          if [[ $attempt -lt $max_retries ]]; then
            echo "Warning: Failed to set GitHub secret lw_agent_token. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
            sleep $retry_interval
          else
            echo "Error: Failed to set GitHub secret lw_agent_token after $max_retries attempts. Exiting."
            exit 1
          fi
        fi
    fi
}

update_hub_nva_credentials() {
  local max_retries=3
  local retry_interval=5

  if gh secret list --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME" | grep -q '^HUB_NVA_PASSWORD\s' && gh secret list --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME" | grep -q '^HUB_NVA_USERNAME\s'; then
    read -rp "Change the Hub NVA Password? (N/y): " response
    response=${response:-N}
    if [[ "$response" =~ ^[Yy]$ ]]; then
      read -srp "Hub NVA Password: " new_htpasswd_value
      echo
    else
      return 0
    fi
  else
    read -srp "Hub NVA Password: " new_htpasswd_value
    echo
  fi

  local attempt=1
  while (( attempt <= max_retries )); do
    if gh secret set "HUB_NVA_PASSWORD" -b "$new_htpasswd_value" --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME"; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if (( attempt < max_retries )); then
        echo "Warning: Failed to set GitHub secret HUB_NVA_PASSWORD. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret HUB_NVA_PASSWORD after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
    ((attempt++))
  done

  local attempt=1
  while (( attempt <= max_retries )); do
    if gh secret set "HUB_NVA_USERNAME" -b "$GITHUB_ORG" --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME"; then
      break
    else
      if (( attempt < max_retries )); then
        echo "Warning: Failed to set GitHub secret HUB_NVA_USERNAME. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret HUB_NVA_USERNAME after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
    ((attempt++))
  done
}

update_azure_secrets() {
  local max_retries=3
  local retry_interval=5
  for secret in \
    "AZURE_STORAGE_ACCOUNT_NAME:${AZURE_STORAGE_ACCOUNT_NAME}" \
    "TFSTATE_CONTAINER_NAME:${PROJECT_NAME}tfstate" \
    "AZURE_TFSTATE_RESOURCE_GROUP_NAME:${PROJECT_NAME}-tfstate" \
    "ARM_SUBSCRIPTION_ID:${subscriptionId}" \
    "ARM_TENANT_ID:${tenantId}" \
    "ARM_CLIENT_ID:${clientId}" \
    "ARM_CLIENT_SECRET:${clientSecret}" \
    "AZURE_CREDENTIALS:${AZURE_CREDENTIALS}"; do
    key="${secret%%:*}"
    value="${secret#*:}"
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set "$key" -b "$value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
        RUN_INFRASTRUCTURE="true"
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret $key after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done

  for secret in \
    "AZURE_CREDENTIALS:${AZURE_CREDENTIALS}" \
    "ARM_CLIENT_ID:${clientId}" \
    "ARM_CLIENT_SECRET:${clientSecret}" ; do

    key="${secret%%:*}"
    value="${secret#*:}"

    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set "$key" -b "$value" --repo "${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME"; then
        RUN_INFRASTRUCTURE="true"
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret $key after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done
}

update_cloudshell_secrets() {
  local max_retries=3
  local retry_interval=5

  # Check if cloudshell secrets already exist
  local tenant_id_exists=false
  local client_id_exists=false

  if gh secret list --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME" | grep -q '^CLOUDSHELL_DIRECTORY_TENANT_ID\s'; then
    tenant_id_exists=true
  fi

  if gh secret list --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME" | grep -q '^CLOUDSHELL_DIRECTORY_CLIENT_ID\s'; then
    client_id_exists=true
  fi

  # Handle cloudshell_directory_tenant_id
  if $tenant_id_exists; then
    read -rp "Change the CloudShell Directory Tenant ID? (N/y): " response
    response=${response:-N}
    if [[ "$response" =~ ^[Yy]$ ]]; then
      read -rp "Enter CloudShell Directory Tenant ID: " new_tenant_id
    else
      echo "Keeping existing CloudShell Directory Tenant ID"
      new_tenant_id=""
    fi
  else
    read -rp "Enter CloudShell Directory Tenant ID: " new_tenant_id
  fi

  # Set cloudshell_directory_tenant_id if we have a value
  if [[ -n "$new_tenant_id" ]]; then
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set "CLOUDSHELL_DIRECTORY_TENANT_ID" -b "$new_tenant_id" --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME"; then
        RUN_INFRASTRUCTURE="true"
        echo "✓ Set CloudShell Directory Tenant ID"
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret CLOUDSHELL_DIRECTORY_TENANT_ID. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret CLOUDSHELL_DIRECTORY_TENANT_ID after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  fi

  # Handle cloudshell_directory_client_id
  if $client_id_exists; then
    read -rp "Change the CloudShell Directory Client ID? (N/y): " response
    response=${response:-N}
    if [[ "$response" =~ ^[Yy]$ ]]; then
      read -rp "Enter CloudShell Directory Client ID: " new_client_id
    else
      echo "Keeping existing CloudShell Directory Client ID"
      new_client_id=""
    fi
  else
    read -rp "Enter CloudShell Directory Client ID: " new_client_id
  fi

  # Set cloudshell_directory_client_id if we have a value
  if [[ -n "$new_client_id" ]]; then
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set "CLOUDSHELL_DIRECTORY_CLIENT_ID" -b "$new_client_id" --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME"; then
        RUN_INFRASTRUCTURE="true"
        echo "✓ Set CloudShell Directory Client ID"
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret CLOUDSHELL_DIRECTORY_CLIENT_ID. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret CLOUDSHELL_DIRECTORY_CLIENT_ID after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  fi
}

update_management_public_ip() {
  local current_value
  local new_value=""
  local attempts
  local max_attempts=3
  declare -a app_list=("MANAGEMENT_PUBLIC_IP")

  for var_name in "${app_list[@]}"; do
    current_value=$(gh variable list --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME --json name,value | jq -r ".[] | select(.name == \"$var_name\") | .value")

    if [ -z "$current_value" ]; then
      # Variable does not exist, prompt user to create it
      read -p "Set initial $var_name value ('true' or 'false') (default: false)? " new_value
      new_value=${new_value:-false}
    else
      # Variable exists, display the current value and prompt user for change
      if [[ "$current_value" == "true" ]]; then
        opposite_value="false"
      else
        opposite_value="true"
      fi
      read -p "Change current value of \"$var_name=$current_value\" to $opposite_value ? (N/y): " change_choice
      change_choice=${change_choice:-N}
      if [[ "$change_choice" =~ ^[Yy]$ ]]; then
        new_value=$opposite_value
      fi
    fi

    # If there's a new value to be set, attempt to update the variable
    if [[ -n "$new_value" ]]; then
      attempts=0
      while (( attempts < max_attempts )); do
        if gh variable set "$var_name" --body "$new_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
          RUN_INFRASTRUCTURE="true"
          break
        else
          ((attempts++))
          if (( attempts < max_attempts )); then
            echo "Retrying in $retry_interval seconds..."
            sleep $retry_interval
          fi
        fi
      done
    fi
  done
}

update_production_environment_variables() {
  local current_value
  local new_value=""
  local attempts
  local max_attempts=3
  local retry_interval=5
  current_value=$(gh variable list --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME --json name,value | jq -r ".[] | select(.name == \"PRODUCTION_ENVIRONMENT\") | .value")

  if [ -z "$current_value" ]; then
    # Variable does not exist, prompt user to create it
    read -p "Set initial PRODUCTION_ENVIRONMENT value ('true' or 'false') (default: false)? " new_value
    new_value=${new_value:-false}
  else
    # Variable exists, display the current value and prompt user for change
    read -p "Change current value of \"PRODUCTION_ENVIRONMENT=$current_value\": (N/y)? " change_choice
    change_choice=${change_choice:-N}
    if [[ "$change_choice" =~ ^[Yy]$ ]]; then
      if [[ "$current_value" == "true" ]]; then
        new_value="false"
      else
        new_value="true"
      fi
    fi
  fi

  # If there's a new value to be set, attempt to update the variable
  if [[ -n "$new_value" ]]; then
    attempts=0
    while (( attempts < max_attempts )); do
      if gh variable set "PRODUCTION_ENVIRONMENT" --body "$new_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME &&  gh variable set "PRODUCTION_ENVIRONMENT" --body "$new_value" --repo ${GITHUB_ORG}/$MANIFESTS_APPLICATIONS_REPO_NAME ; then
        echo "Successfully updated PRODUCTION_ENVIRONMENT to $new_value"
        RUN_INFRASTRUCTURE="true"
        break
      else
        ((attempts++))
        if (( attempts < max_attempts )); then
          echo "Warning: Failed to update variable \"PRODUCTION_ENVIRONMENT\". Retrying in $retry_interval seconds... (Attempt $attempts of $max_attempts)"
          sleep $retry_interval
        else
          echo "Error: Failed to update variable \"PRODUCTION_ENVIRONMENT\" after $max_attempts attempts."
        fi
      fi
    done
  else
    attempts=0
    while (( attempts < max_attempts )); do
      if gh variable set "PRODUCTION_ENVIRONMENT" --body "$current_value" --repo ${GITHUB_ORG}/$MANIFESTS_APPLICATIONS_REPO_NAME ; then
        echo "Successfully updated PRODUCTION_ENVIRONMENT to $current_value"
        break
      else
        ((attempts++))
        if (( attempts < max_attempts )); then
          echo "Warning: Failed to update variable \"PRODUCTION_ENVIRONMENT\". Retrying in $retry_interval seconds... (Attempt $attempts of $max_attempts)"
          sleep $retry_interval
        else
          echo "Error: Failed to update variable \"PRODUCTION_ENVIRONMENT\" after $max_attempts attempts."
        fi
      fi
    done
  fi

}

update_infrastructure_boolean_variables() {
  local current_value
  local new_value=""
  local attempts
  local max_attempts=3
  local retry_interval=5
  declare -a app_list=("DEPLOYED" "MANAGEMENT_PUBLIC_IP" "APPLICATION_SIGNUP" "APPLICATION_DOCS" "APPLICATION_VIDEO" "APPLICATION_DVWA" "APPLICATION_OLLAMA" "APPLICATION_ARTIFACTS" "APPLICATION_EXTRACTOR" "GPU_NODE_POOL" "PRODUCTION_ENVIRONMENT")

  for var_name in "${app_list[@]}"; do
    # Fetch current variable value
    current_value=$(gh variable list --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME --json name,value | jq -r ".[] | select(.name == \"$var_name\") | .value")

    if [ -z "$current_value" ]; then
      # Variable does not exist, prompt user to create it
      read -p "Set initial $var_name value ('true' or 'false') (default: false)? " new_value
      new_value=${new_value:-false}
    else
      # Variable exists, display the current value and prompt user for change
      read -p "Change current value of \"$var_name=$current_value\": (N/y)? " change_choice
      change_choice=${change_choice:-N}
      if [[ "$change_choice" =~ ^[Yy]$ ]]; then
        if [[ "$current_value" == "true" ]]; then
          new_value="false"
        else
          new_value="true"
        fi
      fi
    fi

    # If there's a new value to be set, attempt to update the variable
    if [[ -n "$new_value" ]]; then
      attempts=0
      while (( attempts < max_attempts )); do
        if gh variable set "$var_name" --body "$new_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
          echo "Successfully updated $var_name to $new_value"
          RUN_INFRASTRUCTURE="true"
          break
        else
          ((attempts++))
          if (( attempts < max_attempts )); then
            echo "Warning: Failed to update variable \"$var_name\". Retrying in $retry_interval seconds... (Attempt $attempts of $max_attempts)"
            sleep $retry_interval
          else
            echo "Error: Failed to update variable \"$var_name\" after $max_attempts attempts."
          fi
        fi
      done
    fi

    # Clear new_value for next iteration
    new_value=""
  done
}

update_infrastructure_variables() {
  local max_retries=3
  local retry_interval=5
  for variable in \
    "PROJECT_NAME:${PROJECT_NAME}" \
    "DNS_ZONE:${DNS_ZONE}" \
    "LOCATION:${LOCATION}" \
    "ORG:${GITHUB_ORG}" \
    "NAME:${NAME}" \
    "LETSENCRYPT_URL:${LETSENCRYPT_URL}" \
    "DOCS_BUILDER_REPO_NAME:${DOCS_BUILDER_REPO_NAME}" \
    "MANIFESTS_APPLICATIONS_REPO_NAME:${MANIFESTS_APPLICATIONS_REPO_NAME}" \
    "MANIFESTS_INFRASTRUCTURE_REPO_NAME:${MANIFESTS_INFRASTRUCTURE_REPO_NAME}" \
    "CLOUDSHELL:${CLOUDSHELL:-false}"; do
    key="${variable%%:*}"
    value="${variable#*:}"
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh variable set "$key" -b "$value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub variable $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub variable $key after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done
}

update_manifests_private_keys() {
  local max_retries=3
  local retry_interval=5
  secret_key=$(cat $HOME/.ssh/id_ed25519-${MANIFESTS_INFRASTRUCTURE_REPO_NAME})
  normalized_repo=$(echo "${MANIFESTS_INFRASTRUCTURE_REPO_NAME}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if gh secret set "${normalized_repo}_SSH_PRIVATE_KEY" -b "$secret_key" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if [[ $attempt -lt $max_retries ]]; then
        echo "Warning: Failed to set GitHub secret ${normalized_repo}_ssh_private_key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret ${normalized_repo}_ssh_private_key after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
  done

  secret_key=$(cat $HOME/.ssh/id_ed25519-${MANIFESTS_APPLICATIONS_REPO_NAME})
  normalized_repo=$(echo "${MANIFESTS_APPLICATIONS_REPO_NAME}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if gh secret set "${normalized_repo}_SSH_PRIVATE_KEY" -b "$secret_key" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if [[ $attempt -lt $max_retries ]]; then
        echo "Warning: Failed to set GitHub secret ${normalized_repo}_ssh_private_key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret ${normalized_repo}_ssh_private_key after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
  done
}

update_htpasswd() {

  # Check if the secret htpasswd exists
  if gh secret list --repo "${GITHUB_ORG}/${INFRASTRUCTURE_REPO_NAME}" | grep -q '^HTPASSWD\s'; then
    read -rp "Change the Docs HTPASSWD? (N/y): " response
    response=${response:-N}
    if [[ "$response" =~ ^[Yy]$ ]]; then
      read -srp "Enter new value for Docs HTPASSWD: " new_htpasswd_value
      echo
    else
      return 0
    fi
  else
    read -srp "Enter value for Docs HTPASSWD: " new_htpasswd_value
    echo
  fi

  local max_retries=3
  local retry_interval=5
  # Attempt to set the htpasswd secret with retries
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if gh secret set HTPASSWD -b "$new_htpasswd_value" --repo "${GITHUB_ORG}/${INFRASTRUCTURE_REPO_NAME}"; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if [[ $attempt -lt $max_retries ]]; then
        echo "Warning: Failed to set GitHub secret htpasswd. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret htpasswd after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
  done

  # Attempt to set the htusername secret with retries
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if gh secret set HTUSERNAME -b "$GITHUB_ORG" --repo "${GITHUB_ORG}/${INFRASTRUCTURE_REPO_NAME}"; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if [[ $attempt -lt $max_retries ]]; then
        echo "Warning: Failed to set GitHub secret htusername. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret htusername after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
  done

}

# Display usage information
show_help() {
    cat << EOF
Usage: $0 [OPTION]

Infrastructure Hydration Control Script
Orchestrates multi-repository documentation and infrastructure platform.

OPTIONS:
  --initialize              Initialize GitHub secrets, variables, and authentication (default)
  --destroy                 Destroy the environment and clean up resources
  --create-azure-resources  Create Azure resources only
  --sync-forks              Synchronize GitHub repository forks
  --deploy-keys             Update SSH deploy keys across repositories
  --htpasswd                Change the documentation password
  --management-ip           Update management IP address
  --hub-passwd              Change Fortiweb password
  --cloudshell-secrets      Update CloudShell directory secrets
  --help                    Display this help message

EXAMPLES:
  $0                        # Run initialization (default)
  $0 --sync-forks          # Sync all repository forks
  $0 --deploy-keys         # Regenerate SSH deploy keys

For more information, see the repository documentation.
EOF
}

# Main execution functions
#

# Full initialization workflow
initialize() {
    echo "Starting infrastructure initialization..."

    update_github_auth_login
    # update_github_forks  # Uncommented when needed
    update_azure_auth_login
    update_owner_email
    update_azure_subscription_selection
    update_azure_tfstate_resources
    update_azure_credentials "$SUBSCRIPTION_ID"
    update_azure_secrets
    update_cloudshell_secrets
    update_pat
    update_content_repos_variables
    # update_deploy_keys  # Uncommented when needed
    update_docs_builder_variables
    # copy_docs_builder_workflow_to_docs_builder_repo  # Uncommented when needed
    # copy_dispatch_workflow_to_content_repos  # Uncommented when needed
    update_infrastructure_boolean_variables
    update_production_environment_variables
    update_lw_agent_token
    update_hub_nva_credentials
    update_htpasswd
    update_infrastructure_variables
    # update_manifests_private_keys  # Uncommented when needed
    update_manifests_applications_variables

    echo "Infrastructure initialization complete."
}

# Environment destruction
destroy() {
    echo "Starting environment destruction..."
    # Add destruction logic here
    echo "Environment destruction complete."
}

# Azure resource creation only
create_azure_resources() {
    echo "Creating Azure resources..."

    update_github_auth_login
    update_azure_auth_login
    update_OWNER_EMAIL
    update_AZURE_SUBSCRIPTION_SELECTION
    update_AZURE_TFSTATE_RESOURCES
    update_AZURE_CREDENTIALS "$SUBSCRIPTION_ID"
    update_AZURE_SECRETS
    update_cloudshell_secrets

    echo "Azure resource creation complete."
}

# Sync GitHub forks
sync_forks() {
    echo "Synchronizing GitHub forks..."

    update_github_auth_login
    update_github_forks

    echo "Fork synchronization complete."
}

# Update deploy keys
deploy_keys() {
    echo "Updating deploy keys..."

    update_github_auth_login
    update_DEPLOY-KEYS

    echo "Deploy keys update complete."
}

# Update htpasswd
htpasswd() {
    echo "Updating htpasswd..."

    update_github_auth_login
    update_HTPASSWD

    echo "Htpasswd update complete."
}

# Update management IP
management_ip() {
    echo "Updating management IP..."

    update_github_auth_login
    update_MANAGEMENT_PUBLIC_IP

    echo "Management IP update complete."
}

# Update hub password
hub_password() {
    echo "Updating hub password..."

    update_github_auth_login
    update_HUB_NVA_CREDENTIALS

    echo "Hub password update complete."
}

# CloudShell secrets update
cloudshell_secrets() {
    echo "Updating CloudShell secrets..."

    update_github_auth_login
    update_cloudshell_secrets

    echo "CloudShell secrets update complete."
}

# Environment variables update
env_vars() {
    echo "Updating environment variables..."

    update_github_auth_login
    update_infrastructure_boolean_variables

    echo "Environment variables update complete."
}

# Main Script Execution
#

# Parse command line arguments
main() {
    local action="--initialize"  # Default action

    # Validate argument count
    if (( $# > 1 )); then
        echo "Error: Only one parameter can be supplied." >&2
        show_help
        exit 1
    fi

    # Set action if argument provided
    if (( $# == 1 )); then
        action="$1"
    fi

    # Execute based on action
    case "$action" in
        --initialize)
            initialize
            ;;
        --destroy)
            destroy
            ;;
        --create-azure-resources)
            create_azure_resources
            ;;
        --sync-forks)
            sync_forks
            ;;
        --env-vars)
            env_vars
            ;;
        --deploy-keys)
            deploy_keys
            ;;
        --htpasswd)
            htpasswd
            ;;
        --management-ip)
            management_ip
            ;;
        --hub-passwd)
            hub_password
            ;;
        --cloudshell-secrets)
            cloudshell_secrets
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$action'" >&2
            show_help
            exit 1
            ;;
    esac

    # Handle infrastructure workflow trigger
    if [[ "$RUN_INFRASTRUCTURE" == "true" ]]; then
        local user_response
        read -r -p "Do you wish to run the infrastructure workflow? [Y/n] " user_response
        user_response="${user_response:-Y}"

        if [[ "$user_response" =~ ^[Yy]$ ]]; then
            echo "Triggering infrastructure workflow..."

            if ! retry_command "$MAX_RETRIES" "$RETRY_INTERVAL" "trigger infrastructure workflow" \
                gh workflow run -R "$GITHUB_ORG/$INFRASTRUCTURE_REPO_NAME" "infrastructure"; then
                echo "Error: Failed to trigger infrastructure workflow." >&2
                exit 1
            fi

            echo "Infrastructure workflow triggered successfully."
        fi
    fi
}

# Execute main function with all arguments
main "$@"
