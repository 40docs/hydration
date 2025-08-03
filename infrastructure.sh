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

# Security and validation constants
readonly VALID_EMAIL_REGEX='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
readonly VALID_GITHUB_ORG_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$'
readonly MAX_AZURE_STORAGE_NAME_LENGTH=24
readonly MIN_PASSWORD_LENGTH=8

# Common exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_CONFIG_ERROR=2
readonly EXIT_AUTH_ERROR=3
readonly EXIT_NETWORK_ERROR=4

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
  echo "❌ Error: $CONFIG_FILE file not found. Exiting." >&2
  exit 1
fi

# Parse configuration from JSON
# Reads and validates configuration from the JSON config file
# Populates global variables and arrays with configuration values
# Exits with error code if configuration is invalid
#
# Arguments:
#   $1 - Path to configuration file
#
# Globals:
#   Sets: DEPLOYED, PROJECT_NAME, LOCATION, DNS_ZONE, CLOUDSHELL
#   Sets: THEME_REPO_NAME, LANDING_PAGE_REPO_NAME, DOCS_BUILDER_REPO_NAME
#   Sets: INFRASTRUCTURE_REPO_NAME, MANIFESTS_*_REPO_NAME, MKDOCS_REPO_NAME
#   Sets: HELM_CHARTS_REPO_NAME
#   Populates: CONTENTREPOSONLY, CONTENTREPOS, DEPLOYKEYSREPOS, PATREPOS, ALLREPOS
#
# Returns:
#   0 on success, exits on failure
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

# Enhanced configuration validation
validate_config() {
    local errors=()

    # Check required fields
    if [[ -z "$DEPLOYED" ]]; then
        errors+=("DEPLOYED is not set")
    elif ! validate_boolean "$DEPLOYED"; then
        errors+=("DEPLOYED must be true or false")
    fi

    if ! validate_non_empty "$PROJECT_NAME" "PROJECT_NAME"; then
        errors+=("PROJECT_NAME is required")
    fi

    if ! validate_non_empty "$LOCATION" "LOCATION"; then
        errors+=("LOCATION is required")
    fi

    if ! validate_dns_zone "$DNS_ZONE"; then
        errors+=("DNS_ZONE must be a valid domain name")
    fi

    if (( ${#CONTENTREPOS[@]} == 0 )); then
        errors+=("CONTENTREPOS array is empty")
    fi

    # Validate repository names
    for repo in "${ALLREPOS[@]}"; do
        if ! validate_non_empty "$repo" "repository name"; then
            errors+=("Empty repository name found")
        fi
    done

    # Report all errors
    if (( ${#errors[@]} > 0 )); then
        log_error "Configuration validation failed:"
        for error in "${errors[@]}"; do
            log_error "  - $error"
        done
        exit $EXIT_CONFIG_ERROR
    fi

    log_success "Configuration validation passed"
}

# Initialize derived variables and environment settings
# Sets up derived constants based on detected GitHub organization
# Adjusts naming conventions for fork environments
# Validates GitHub organization detection
#
# Arguments:
#   None
#
# Globals:
#   Uses: PROJECT_NAME, DNS_ZONE
#   Sets: GITHUB_ORG, LETSENCRYPT_URL, DOCS_FQDN, OLLAMA_FQDN, ARTIFACTS_FQDN
#   Sets: AZURE_STORAGE_ACCOUNT_NAME, MKDOCS_REPO_NAME
#
# Returns:
#   0 on success, exits on failure
initialize_environment() {
    local github_org
    github_org=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)/.*#\1#p')

    if [[ -z "$github_org" ]]; then
        echo "❌ Error: Could not detect GitHub organization." >&2
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

# Utility Functions
#

# Input validation functions
validate_email() {
    local email="$1"

    if [[ -z "$email" ]]; then
        return 1
    fi

    if [[ "$email" =~ $VALID_EMAIL_REGEX ]]; then
        return 0
    else
        return 1
    fi
}

validate_github_org() {
    local org="$1"

    if [[ -z "$org" ]]; then
        return 1
    fi

    if [[ "$org" =~ $VALID_GITHUB_ORG_REGEX ]] && (( ${#org} <= 39 )); then
        return 0
    else
        return 1
    fi
}

validate_azure_storage_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        return 1
    fi

    # Azure storage names: 3-24 chars, lowercase letters and numbers only
    if [[ "$name" =~ ^[a-z0-9]{3,24}$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_dns_zone() {
    local zone="$1"

    if [[ -z "$zone" ]]; then
        return 1
    fi

    # Basic DNS validation: contains at least one dot and valid characters
    if [[ "$zone" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && [[ "$zone" == *.* ]]; then
        return 0
    else
        return 1
    fi
}

validate_non_empty() {
    local value="$1"
    local field_name="${2:-field}"

    if [[ -z "$value" ]]; then
        log_error "$field_name cannot be empty"
        return 1
    fi

    return 0
}

validate_boolean() {
    local value="$1"

    # Convert to lowercase using portable method
    value=$(echo "$value" | tr '[:upper:]' '[:lower:]')

    case "$value" in
        true|false|yes|no|y|n|1|0)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Secure temporary file creation
create_secure_temp_file() {
    local prefix="${1:-infratemp}"
    local temp_file

    temp_file=$(mktemp "/tmp/${prefix}.XXXXXX") || {
        log_error "Failed to create secure temporary file"
        return 1
    }

    chmod 600 "$temp_file" || {
        log_error "Failed to set secure permissions on temporary file"
        rm -f "$temp_file"
        return 1
    }

    echo "$temp_file"
}

create_secure_temp_dir() {
    local prefix="${1:-infratemp}"
    local temp_dir

    temp_dir=$(mktemp -d "/tmp/${prefix}.XXXXXX") || {
        log_error "Failed to create secure temporary directory"
        return 1
    }

    chmod 700 "$temp_dir" || {
        log_error "Failed to set secure permissions on temporary directory"
        rm -rf "$temp_dir"
        return 1
    }

    echo "$temp_dir"
}

# Enhanced error handling
handle_error() {
    local exit_code="$1"
    local message="$2"
    local line_number="${3:-unknown}"
    local function_name="${4:-main}"

    log_error "❌ Error in function '$function_name' at line $line_number: $message"

    # Cleanup function if it exists
    if declare -f cleanup_on_error >/dev/null; then
        cleanup_on_error
    fi

    exit "$exit_code"
}

# Standardized message functions
log_error() {
    echo "❌ Error: $*" >&2
}

log_warning() {
    echo "⚠️ Warning: $*" >&2
}

log_success() {
    echo "✅ $*"
}

log_info() {
    echo "• $*"
}

log_progress() {
    echo "Processing: $*"
}

# Enhanced prompt functions with validation
prompt_confirmation() {
    local prompt="$1"
    local default="${2:-N}"
    local response
    local max_attempts=3
    local attempt=1

    while (( attempt <= max_attempts )); do
        if [[ "$default" == "Y" ]]; then
            read -rp "$prompt (Y/n): " response
            response="${response:-Y}"
        else
            read -rp "$prompt (N/y): " response
            response="${response:-N}"
        fi

        case "$(echo "$response" | tr '[:upper:]' '[:lower:]')" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *)
                log_error "Invalid response. Please enter Y or N."
                ((attempt++))
                if (( attempt > max_attempts )); then
                    log_error "Too many invalid attempts. Defaulting to 'N'."
                    return 1
                fi
                ;;
        esac
    done
}

prompt_secret() {
    local prompt="$1"
    local variable_name="$2"
    local min_length="${3:-$MIN_PASSWORD_LENGTH}"
    local value
    local max_attempts=3
    local attempt=1

    while (( attempt <= max_attempts )); do
        read -srp "$prompt: " value
        echo  # New line after hidden input

        if (( ${#value} < min_length )); then
            log_error "Value must be at least $min_length characters long."
            ((attempt++))
            if (( attempt > max_attempts )); then
                log_error "Too many invalid attempts."
                return 1
            fi
            continue
        fi

        # Basic validation for common secret patterns
        if [[ "$prompt" =~ [Pp]assword ]]; then
            # Password should contain at least one letter and one number
            if ! [[ "$value" =~ [A-Za-z] && "$value" =~ [0-9] ]]; then
                log_warning "Password should contain at least one letter and one number."
                if ! prompt_confirmation "Use this password anyway" "N"; then
                    ((attempt++))
                    continue
                fi
            fi
        fi

        # Store value in the specified variable
        printf -v "$variable_name" "%s" "$value"
        return 0
    done

    return 1
}

prompt_text() {
    local prompt="$1"
    local variable_name="$2"
    local default="$3"
    local validation_func="$4"  # Optional validation function
    local value
    local max_attempts=3
    local attempt=1

    while (( attempt <= max_attempts )); do
        if [[ -n "$default" ]]; then
            read -rp "$prompt [$default]: " value
            value="${value:-$default}"
        else
            read -rp "$prompt: " value
        fi

        if [[ -z "$value" ]]; then
            log_error "Value cannot be empty."
            ((attempt++))
            if (( attempt > max_attempts )); then
                log_error "Too many invalid attempts."
                return 1
            fi
            continue
        fi

        # Apply validation function if provided
        if [[ -n "$validation_func" ]] && declare -f "$validation_func" >/dev/null; then
            if ! "$validation_func" "$value"; then
                log_error "Invalid value format."
                ((attempt++))
                if (( attempt > max_attempts )); then
                    log_error "Too many invalid attempts."
                    return 1
                fi
                continue
            fi
        fi

        # Store value in the specified variable
        printf -v "$variable_name" "%s" "$value"
        return 0
    done

    return 1
}

prompt_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice

    echo "$prompt"
    for i in "${!options[@]}"; do
        echo "$((i+1))) ${options[i]}"
    done

    while true; do
        read -rp "Choose an option (1-${#options[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            return $((choice - 1))
        else
            log_error "Invalid choice. Please enter a number between 1 and ${#options[@]}."
        fi
    done
}

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
            log_warning "$description failed. Attempt $attempt of $max_attempts. Retrying in ${delay}s..."
            sleep "$delay"
        else
            log_error "$description failed after $max_attempts attempts."
            return 1
        fi

        ((attempt++))
    done
}

# Get GitHub username from authenticated session
get_github_username() {
    local output

    if ! output=$(gh auth status 2>/dev/null); then
        log_error "Unable to retrieve GitHub authentication status."
        return 1
    fi

    echo "$output" | grep -oE "account [a-zA-Z0-9_\-]+" | awk '{print $2}'
}

# Prompt for GitHub username with default
prompt_github_username() {
    local default_user
    default_user=$(get_github_username) || default_user=""

    prompt_text "Enter your personal GitHub account name" "USER" "${default_user:-no user found}"
}

# DRY Utility Functions - Generic Operations
#

# Generic GitHub secret setter with retry logic and smart behavior
# Sets a GitHub secret with enhanced security and error handling
#
# Arguments:
#   $1 - Secret name
#   $2 - Secret value (will be sanitized)
#   $3 - Repository name
#   $4 - Description (optional)
#
# Security:
#   - Validates input parameters
#   - Uses secure temporary files for large secrets
#   - Implements retry logic with exponential backoff
#
# Returns:
#   0 on success, exits on failure
set_github_secret() {
    local secret_name="$1"
    local secret_value="$2"
    local repo_name="$3"
    local description="${4:-GitHub secret $secret_name}"
    local max_retries="${MAX_RETRIES:-3}"
    local retry_interval="${RETRY_INTERVAL:-5}"

    # Input validation
    if ! validate_non_empty "$secret_name" "secret name"; then
        return 1
    fi

    if ! validate_non_empty "$secret_value" "secret value"; then
        return 1
    fi

    if ! validate_non_empty "$repo_name" "repository name"; then
        return 1
    fi

    # Validate repository exists (optional check)
    if ! gh repo view "${GITHUB_ORG}/$repo_name" &>/dev/null; then
        log_warning "Repository ${GITHUB_ORG}/$repo_name may not exist"
    fi

    for ((attempt=1; attempt<=max_retries; attempt++)); do
        if gh secret set "$secret_name" -b "$secret_value" --repo "${GITHUB_ORG}/$repo_name" &>/dev/null; then
            log_success "Set Actions secret $secret_name for ${GITHUB_ORG}/$repo_name"
            return 0
        else
            if [[ $attempt -lt $max_retries ]]; then
                log_warning "Failed to set $description. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
                sleep $retry_interval
            else
                log_error "Failed to set $description after $max_retries attempts. Exiting."
                exit $EXIT_NETWORK_ERROR
            fi
        fi
    done
}

# Generic GitHub variable getter
get_github_variable() {
    local variable_name="$1"
    local repo_name="$2"

    gh variable list --repo "${GITHUB_ORG}/$repo_name" --json name,value | \
        jq -r ".[] | select(.name == \"$variable_name\") | .value" 2>/dev/null
}

# Generic GitHub variable setter with current value checking and retry logic
set_github_variable() {
    local variable_name="$1"
    local variable_value="$2"
    local repo_name="$3"
    local description="${4:-GitHub variable $variable_name}"
    local max_retries="${MAX_RETRIES:-3}"
    local retry_interval="${RETRY_INTERVAL:-5}"

    # Check current value first
    local current_value
    current_value=$(get_github_variable "$variable_name" "$repo_name")

    # Only update if value is different
    if [[ "$current_value" != "$variable_value" ]]; then
        for ((attempt=1; attempt<=max_retries; attempt++)); do
            if gh variable set "$variable_name" -b "$variable_value" --repo "${GITHUB_ORG}/$repo_name" &>/dev/null; then
                log_success "Successfully set variable $variable_name for ${GITHUB_ORG}/$repo_name"
                return 0
            else
                if [[ $attempt -lt $max_retries ]]; then
                    log_warning "Failed to set $description. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
                    sleep $retry_interval
                else
                    log_error "Failed to set $description after $max_retries attempts. Exiting."
                    exit 1
                fi
            fi
        done
    fi
    # Return success if no update needed (value already correct)
    return 0
}

# Generic GitHub variable setter with --body flag for newer GitHub CLI versions
set_github_variable_body() {
    local variable_name="$1"
    local variable_value="$2"
    local repo_name="$3"
    local description="${4:-GitHub variable $variable_name}"
    local max_retries="${MAX_RETRIES:-3}"
    local retry_interval="${RETRY_INTERVAL:-5}"

    # Check current value first
    local current_value
    current_value=$(get_github_variable "$variable_name" "$repo_name")

    # Only update if value is different
    if [[ "$current_value" != "$variable_value" ]]; then
        for ((attempt=1; attempt<=max_retries; attempt++)); do
            if gh variable set "$variable_name" --body "$variable_value" --repo "${GITHUB_ORG}/$repo_name" &>/dev/null; then
                log_success "Successfully set variable $variable_name for ${GITHUB_ORG}/$repo_name"
                return 0
            else
                if [[ $attempt -lt $max_retries ]]; then
                    log_warning "Failed to set $description. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
                    sleep $retry_interval
                else
                    log_error "Failed to set $description after $max_retries attempts. Exiting."
                    exit 1
                fi
            fi
        done
    fi
    return 0
}

# Generic SSH key generation function with enhanced security
# Generates ED25519 SSH key pairs with secure permissions
#
# Arguments:
#   $1 - Key name identifier
#
# Security:
#   - Creates secure temporary directory
#   - Sets restrictive file permissions (600)
#   - Validates key generation success
#
# Globals:
#   Sets: SSH_PUBLIC_KEY, SSH_PRIVATE_KEY (output variables)
#
# Returns:
#   0 on success, 1 on failure
generate_ssh_key() {
    local key_name="$1"
    local key_path="/tmp/ssh_keys/id_ed25519-$key_name"

    if ! validate_non_empty "$key_name" "key name"; then
        return 1
    fi

    # Create secure SSH keys directory
    if ! mkdir -p "/tmp/ssh_keys"; then
        log_error "Failed to create SSH keys directory"
        return 1
    fi

    # Set secure permissions on directory
    chmod 700 "/tmp/ssh_keys" || {
        log_error "Failed to set secure permissions on SSH keys directory"
        return 1
    }

    # Generate SSH key with secure settings
    if ! ssh-keygen -t ed25519 -N "" -f "$key_path" -q; then
        log_error "Failed to generate SSH key: $key_path"
        return 1
    fi

    # Set secure permissions on generated keys
    chmod 600 "$key_path" || {
        log_error "Failed to set permissions on private key"
        return 1
    }

    chmod 644 "${key_path}.pub" || {
        log_error "Failed to set permissions on public key"
        return 1
    }

    # Validate key files exist and are readable
    if [[ ! -r "$key_path" || ! -r "${key_path}.pub" ]]; then
        log_error "Generated SSH key files are not readable"
        return 1
    fi

    # Return paths via global variables (bash doesn't support returning arrays)
    SSH_PUBLIC_KEY=$(cat "${key_path}.pub") || {
        log_error "Failed to read public key"
        return 1
    }

    SSH_PRIVATE_KEY=$(cat "$key_path") || {
        log_error "Failed to read private key"
        return 1
    }

    log_success "Successfully generated SSH key pair: $key_name"
    return 0
}

# Generic function to set multiple variables from key:value pairs
set_multiple_variables() {
    local repo_name="$1"
    shift
    local variables=("$@")

    for variable in "${variables[@]}"; do
        local key="${variable%%:*}"
        local value="${variable#*:}"
        set_github_variable "$key" "$value" "$repo_name"
    done
}

# Generic function to set multiple secrets from key:value pairs
set_multiple_secrets() {
    local repo_name="$1"
    shift
    local secrets=("$@")

    for secret in "${secrets[@]}"; do
        local key="${secret%%:*}"
        local value="${secret#*:}"
        set_github_secret "$key" "$value" "$repo_name"
    done
}

# Generic deploy key management function
manage_deploy_key() {
    local repo_name="$1"
    local key_title="${2:-DEPLOY-KEY}"
    local key_path="$HOME/.ssh/id_ed25519-$repo_name"
    local max_attempts=3
    local retry_interval=5

    # Generate SSH key if it doesn't exist
    if [ ! -f "$key_path" ]; then
        ssh-keygen -t ed25519 -N "" -f "$key_path" -q
    fi

    # Delete existing deploy key if it exists
    local deploy_key_id
    deploy_key_id=$(gh repo deploy-key list --repo "${GITHUB_ORG}/$repo_name" --json title,id | jq -r ".[] | select(.title == \"$key_title\") | .id")
    if [[ -n "$deploy_key_id" ]]; then
        retry_command "$max_attempts" "$retry_interval" "delete deploy key" \
            gh repo deploy-key delete --repo "${GITHUB_ORG}/$repo_name" "$deploy_key_id"
    fi

    # Add new deploy key
    if retry_command "$max_attempts" "$retry_interval" "add deploy key" \
        gh repo deploy-key add "${key_path}.pub" --title "$key_title" --repo "${GITHUB_ORG}/$repo_name"; then
        RUN_INFRASTRUCTURE="true"
    fi

    # Set SSH private key as secret for docs builder
    local secret_key
    secret_key=$(cat "$key_path")
    local normalized_repo
    normalized_repo=$(echo "$repo_name" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
    set_github_secret "${normalized_repo}_SSH_PRIVATE_KEY" "$secret_key" "$DOCS_BUILDER_REPO_NAME"
    RUN_INFRASTRUCTURE="true"
}

# Advanced DRY Utility Functions - Phase 2
#

# Generic boolean variable management with toggle logic
manage_boolean_variable() {
    local variable_name="$1"
    local repo_name="$2"
    local default_value="${3:-false}"
    local prompt_text="${4:-$variable_name}"

    local current_value new_value=""

    # Get current value
    current_value=$(get_github_variable "$variable_name" "$repo_name")

    if [[ -z "$current_value" ]]; then
        # Variable doesn't exist, prompt for initial value
        prompt_text "Set initial $prompt_text value ('true' or 'false')" "new_value" "$default_value"
    else
        # Variable exists, offer to toggle
        local opposite_value
        if [[ "$current_value" == "true" ]]; then
            opposite_value="false"
        else
            opposite_value="true"
        fi

        if prompt_confirmation "Change current value of \"$variable_name=$current_value\" to $opposite_value" "N"; then
            new_value="$opposite_value"
        fi
    fi

    # Set new value if provided
    if [[ -n "$new_value" ]]; then
        retry_command "$MAX_RETRIES" "$RETRY_INTERVAL" "set variable $variable_name" \
            gh variable set "$variable_name" --body "$new_value" --repo "${GITHUB_ORG}/$repo_name"
        log_success "Successfully set $variable_name to $new_value"
        RUN_INFRASTRUCTURE="true"
    fi
}

# Generic conditional secret management (check existence, prompt for change/creation)
manage_conditional_secret() {
    local secret_name="$1"
    local repo_name="$2"
    local prompt_change="${3:-Change the $secret_name}"
    local prompt_create="${4:-Enter value for $secret_name}"

    local secret_value

    # Check if secret exists
    if gh secret list --repo "${GITHUB_ORG}/$repo_name" --json name | jq -r '.[].name' | grep -q "^$secret_name$"; then
        if prompt_confirmation "$prompt_change" "N"; then
            prompt_secret "$prompt_create" "secret_value"
        else
            return 0
        fi
    else
        prompt_secret "$prompt_create" "secret_value"
    fi

    # Set the secret
    set_github_secret "$secret_name" "$secret_value" "$repo_name"
    RUN_INFRASTRUCTURE="true"
}

# Generic conditional variable management (check existence, prompt for change/creation)
manage_conditional_variable() {
    local variable_name="$1"
    local repo_name="$2"
    local prompt_change="${3:-Change the $variable_name}"
    local prompt_create="${4:-Enter value for $variable_name}"
    local default_value="${5:-}"

    local variable_value current_value

    # Get current value
    current_value=$(get_github_variable "$variable_name" "$repo_name")

    if [[ -n "$current_value" ]]; then
        if prompt_confirmation "$prompt_change (current: $current_value)" "N"; then
            prompt_text "$prompt_create" "variable_value" "$current_value"
        else
            return 0
        fi
    else
        prompt_text "$prompt_create" "variable_value" "$default_value"
    fi

    # Set the variable
    set_github_variable_body "$variable_name" "$variable_value" "$repo_name"
    RUN_INFRASTRUCTURE="true"
}

# Sync variable across multiple repositories
sync_variable_across_repos() {
    local variable_name="$1"
    local source_repo="$2"
    shift 2
    local target_repos=("$@")

    # Get value from source repo
    local source_value
    source_value=$(get_github_variable "$variable_name" "$source_repo")

    if [[ -z "$source_value" ]]; then
        log_error "Variable $variable_name not found in source repo $source_repo"
        return 1
    fi

    # Sync to all target repos
    for target_repo in "${target_repos[@]}"; do
        local current_value
        current_value=$(get_github_variable "$variable_name" "$target_repo")

        if [[ "$current_value" != "$source_value" ]]; then
            log_info "Syncing $variable_name to $target_repo..."
            retry_command "$MAX_RETRIES" "$RETRY_INTERVAL" "sync variable $variable_name to $target_repo" \
                gh variable set "$variable_name" --body "$source_value" --repo "${GITHUB_ORG}/$target_repo"
            log_success "Successfully synced $variable_name to $target_repo"
        fi
    done
}

# Manage multiple boolean variables with consistent logic
manage_multiple_boolean_variables() {
    local repo_name="$1"
    shift
    local variables=("$@")

    for variable_name in "${variables[@]}"; do
        manage_boolean_variable "$variable_name" "$repo_name" "false"
    done
}

# GitHub Authentication and Management
#

# Ensure GitHub CLI is authenticated
update_github_auth_login() {
    export GITHUB_TOKEN=""

    if ! gh auth status &>/dev/null; then
        log_info "GitHub authentication required..."
        if ! gh auth login; then
            log_error "GitHub login failed."
            exit 1
        fi
    fi

    gh auth setup-git
    log_success "Successfully verified GitHub authentication."
}

# Manage GitHub repository forks
update_github_forks() {
    local -r upstream_org="$GITHUB_ORG"
    local -r repo_owner="$GITHUB_ORG"
    local -r max_retries=3
    local -r delay_seconds=5

    log_progress "repository forks..."

    for repo_name in "${ALLREPOS[@]}"; do
        log_info "Processing repository: $repo_name"

        if gh repo view "${repo_owner}/${repo_name}" &>/dev/null; then
            # Repository exists - check if it's a fork
            local repo_info parent
            repo_info=$(gh repo view "$repo_owner/$repo_name" --json parent)
            parent=$(echo "$repo_info" | jq -r '.parent | if type == "object" then (.owner.login + "/" + .name) else "" end')

            if [[ -n "$parent" ]]; then
                # Repository is a fork, sync it
                log_info "  Syncing fork: $repo_name"
                if ! gh repo sync "$repo_owner/$repo_name" --branch main --force; then
                    log_warning "Failed to sync $repo_name"
                fi
            else
                log_info "  Repository $repo_name exists but is not a fork. Skipping."
            fi
        else
            # Repository does not exist, fork it
            log_info "  Forking $upstream_org/$repo_name..."
            if gh repo fork "$upstream_org/$repo_name" --clone=false; then
                log_success "Successfully forked $upstream_org/$repo_name"

                # Retry sync after forking
                if ! retry_command "$max_retries" "$delay_seconds" "sync $repo_name after forking" \
                    gh repo sync "$repo_owner/$repo_name" --branch main --force; then
                    log_warning "Failed to sync $repo_name after forking"
                fi
            else
                log_error "Failed to fork $upstream_org/$repo_name"
            fi
        fi
    done

    log_success "Successfully completed repository fork processing."
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
        echo "❌ Error: Workflow file '$workflow_file' not found in current directory." >&2
        return 1
    fi

    echo "Copying dispatch workflow to content repositories..."

    for repo in "${CONTENTREPOS[@]}"; do
        echo "  Processing repository: $repo"

        # Work in temp directory
        cd "$temp_dir" || {
            echo "❌ Error: Failed to change to temp directory" >&2
            continue
        }

        # Clone repository
        if ! git clone "https://github.com/${GITHUB_ORG}/${repo}"; then
            echo "❌ Error: Failed to clone repository $repo" >&2
            continue
        fi

        cd "$repo" || {
            echo "❌ Error: Failed to change to repository directory" >&2
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
                    echo "⚠️  Warning: Failed to push changes to $repo" >&2
                fi
            else
                echo "⚠️  Warning: No changes to commit for $repo" >&2
            fi
        else
            echo "    No changes detected for $repo"
        fi
    done

    # Return to original directory
    cd "$CURRENT_DIR" || {
        echo "❌ Error: Failed to return to original directory" >&2
        exit 1
    }

    echo "Dispatch workflow copy complete."
}

# Azure Authentication and Management
#

# Comprehensive Azure authentication and subscription setup
update_azure_auth_and_subscription() {
    log_progress "Azure authentication and subscription..."

    local current_sub_name current_sub_id confirm subscription_name needs_login=false

    # Step 1: Check if Azure account is active and token is valid
    if ! az account show &>/dev/null || ! az account get-access-token &>/dev/null; then
        needs_login=true
    else
        # Step 2: Check if subscription is available
        current_sub_name=$(az account show --query "name" --output tsv 2>/dev/null)
        current_sub_id=$(az account show --query "id" --output tsv 2>/dev/null)

        if [[ -z "$current_sub_name" || -z "$current_sub_id" ]]; then
            log_info "Azure authentication is valid, but no subscription is set as default."
            needs_login=true
        fi
    fi

    # Step 3: Perform login if needed
    if [[ "$needs_login" == true ]]; then
        log_info "Azure authentication or subscription setup required..."

        local choice_index
        prompt_choice "Please choose an action:" \
            "Login to Azure and select subscription" \
            "Exit script"
        choice_index=$?

        case "$choice_index" in
          0)
            log_info "Initiating Azure login..."
            if ! az login --use-device-code; then
                log_error "Azure login failed."
                exit 1
            fi
            ;;
          1)
            log_info "Exiting script as requested."
            exit 0
            ;;
        esac

        # Re-check subscription after login
        current_sub_name=$(az account show --query "name" --output tsv 2>/dev/null)
        current_sub_id=$(az account show --query "id" --output tsv 2>/dev/null)
    fi

    # Step 4: Handle subscription selection
    if [[ -z "$current_sub_name" || -z "$current_sub_id" ]]; then
        log_info "No default subscription found. Listing available subscriptions..."
        az account list --query '[].{Name:name, ID:id}' --output table
        prompt_text "Enter the name of the subscription you want to set as default" "subscription_name"
        SUBSCRIPTION_ID=$(az account list --query "[?name=='$subscription_name'].id" --output tsv 2>/dev/null)
        if [[ -z "$SUBSCRIPTION_ID" ]]; then
            log_error "Invalid subscription name. Exiting."
            exit 1
        fi
        az account set --subscription "$SUBSCRIPTION_ID"
        log_success "Successfully set subscription: $subscription_name"
    else
        # Confirm current subscription
        if prompt_confirmation "Use the current default subscription: $current_sub_name (ID: $current_sub_id)" "Y"; then
            SUBSCRIPTION_ID="$current_sub_id"
        else
            az account list --query '[].{Name:name, ID:id}' --output table
            prompt_text "Enter the name of the subscription you want to set as default" "subscription_name"
            SUBSCRIPTION_ID=$(az account list --query "[?name=='$subscription_name'].id" --output tsv 2>/dev/null)
            if [[ -z "$SUBSCRIPTION_ID" ]]; then
                log_error "Invalid subscription name. Exiting."
                exit 1
            fi
            az account set --subscription "$SUBSCRIPTION_ID"
        fi
    fi

    # Step 5: Validate owner email
    OWNER_EMAIL=$(az account show --query user.name -o tsv)
    if [[ -z "$OWNER_EMAIL" || ! "$OWNER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "OWNER_EMAIL is not properly initialized or is not in a valid email format."
        exit 1
    fi

    get_signed_in_user_name
    log_success "Successfully verified Azure authentication and subscription."
}

update_owner_email() {
    set_github_secret "OWNER_EMAIL" "$OWNER_EMAIL" "$INFRASTRUCTURE_REPO_NAME" "GitHub secret OWNER_EMAIL"
    RUN_INFRASTRUCTURE="true"
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
    prompt_text "Please enter your full name" "NAME"
  fi

  # Export the NAME variable for further use if needed
  export NAME
}

# Enhanced Azure resource management functions (following SRP)
#

# Create resource tags
create_resource_tags() {
    local owner_email="$1"
    local name="$2"

    if ! validate_email "$owner_email"; then
        log_error "Invalid email format: $owner_email"
        return 1
    fi

    if ! validate_non_empty "$name" "name"; then
        return 1
    fi

    # Sanitize values by replacing spaces with underscores
    local owner_email_sanitized="${owner_email// /_}"
    local name_sanitized="${name// /_}"

    echo "Username=${owner_email_sanitized} FullName=${name_sanitized}"
}

# Create or verify resource group
create_or_verify_resource_group() {
    local resource_group_name="$1"
    local location="$2"
    local tags="$3"

    if ! validate_non_empty "$resource_group_name" "resource group name"; then
        return 1
    fi

    if ! validate_non_empty "$location" "location"; then
        return 1
    fi

    log_info "Creating or verifying resource group: $resource_group_name"

    if ! az group show -n "$resource_group_name" &>/dev/null; then
        if ! az group create -n "$resource_group_name" -l "$location"; then
            log_error "Failed to create resource group: $resource_group_name"
            return 1
        fi
        log_success "Created resource group: $resource_group_name"
    else
        log_info "Resource group already exists: $resource_group_name"
    fi

    # Update tags
    if [[ -n "$tags" ]]; then
        local resource_id="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${resource_group_name}"
        if ! az tag update --resource-id "$resource_id" --operation merge --tags $tags &>/dev/null; then
            log_warning "Failed to update tags for resource group: $resource_group_name"
        fi
    fi

    return 0
}

# Create or verify storage account
create_or_verify_storage_account() {
    local storage_account_name="$1"
    local resource_group_name="$2"
    local location="$3"
    local tags="$4"

    if ! validate_azure_storage_name "$storage_account_name"; then
        log_error "Invalid storage account name: $storage_account_name"
        return 1
    fi

    log_info "Creating or verifying storage account: $storage_account_name"

    if ! az storage account show -n "$storage_account_name" -g "$resource_group_name" &>/dev/null; then
        if ! az storage account create -n "$storage_account_name" -g "$resource_group_name" -l "$location" --sku Standard_LRS &>/dev/null; then
            log_error "Failed to create storage account: $storage_account_name"
            return 1
        fi
        log_success "Created storage account: $storage_account_name"
    else
        log_info "Storage account already exists: $storage_account_name"
    fi

    # Update tags
    if [[ -n "$tags" ]]; then
        local resource_id="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${resource_group_name}/providers/Microsoft.Storage/storageAccounts/${storage_account_name}"
        if ! az tag update --resource-id "$resource_id" --operation merge --tags $tags &>/dev/null; then
            log_warning "Failed to update tags for storage account: $storage_account_name"
        fi
    fi

    # Add delay to ensure resource is ready
    sleep 10

    return 0
}

# Create or verify storage container with retry logic
create_or_verify_storage_container() {
    local container_name="$1"
    local storage_account_name="$2"
    local owner_email_sanitized="$3"
    local name_sanitized="$4"
    local max_attempts=5
    local attempt=1

    if ! validate_non_empty "$container_name" "container name"; then
        return 1
    fi

    log_info "Creating or verifying storage container: $container_name"

    while (( attempt <= max_attempts )); do
        # Check if container exists
        if az storage container show -n "$container_name" --account-name "$storage_account_name" &>/dev/null; then
            log_info "Storage container already exists: $container_name"
            return 0
        fi

        # Try to create container
        if az storage container create -n "$container_name" \
            --account-name "$storage_account_name" \
            --auth-mode login \
            --metadata Username="$owner_email_sanitized" Name="$name_sanitized" &>/dev/null; then
            log_success "Created storage container: $container_name"
            return 0
        fi

        if (( attempt < max_attempts )); then
            log_warning "Failed to create container (attempt $attempt/$max_attempts). Retrying in 5 seconds..."
            sleep 5
        fi

        ((attempt++))
    done

    log_error "Failed to create storage container after $max_attempts attempts: $container_name"
    return 1
}

# Main function - refactored with better error handling and separation of concerns
update_azure_tfstate_resources() {
    local tags owner_email_sanitized name_sanitized

    # Validate prerequisites
    if ! validate_email "$OWNER_EMAIL"; then
        log_error "OWNER_EMAIL is not properly initialized or invalid: $OWNER_EMAIL"
        return 1
    fi

    if ! validate_non_empty "$NAME" "NAME"; then
        log_error "NAME is not properly initialized"
        return 1
    fi

    if ! validate_non_empty "$SUBSCRIPTION_ID" "SUBSCRIPTION_ID"; then
        log_error "SUBSCRIPTION_ID is not set"
        return 1
    fi

    # Create resource tags
    tags=$(create_resource_tags "$OWNER_EMAIL" "$NAME") || return 1

    # Extract sanitized values for container metadata
    owner_email_sanitized="${OWNER_EMAIL// /_}"
    name_sanitized="${NAME// /_}"

    log_info "Setting up Azure Terraform state resources..."

    # Create or verify resource group
    if ! create_or_verify_resource_group "${PROJECT_NAME}-tfstate" "$LOCATION" "$tags"; then
        return 1
    fi

    # Create or verify storage account
    if ! create_or_verify_storage_account "$AZURE_STORAGE_ACCOUNT_NAME" "${PROJECT_NAME}-tfstate" "$LOCATION" "$tags"; then
        return 1
    fi

    # Create or verify storage container
    if ! create_or_verify_storage_container "${PROJECT_NAME}tfstate" "$AZURE_STORAGE_ACCOUNT_NAME" "$owner_email_sanitized" "$name_sanitized"; then
        return 1
    fi

    log_success "Successfully set up Azure Terraform state resources"
    return 0
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
    echo "❌ Error: Failed to retrieve or create the service principal. Exiting."
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

    # Check if PAT exists in any repository
    for repo in "${PATREPOS[@]}"; do
        if gh secret list --repo "${GITHUB_ORG}/$repo" --json name | jq -r '.[].name' | grep -q "^PAT$"; then
            PAT="exists"
            break
        fi
    done

    # Get PAT value from user
    if [[ -z "$PAT" ]]; then
        prompt_secret "Enter value for GitHub PAT" "new_PAT_value"
    else
        if prompt_confirmation "Change the GitHub PAT" "N"; then
            prompt_secret "Enter new value for GitHub PAT" "new_PAT_value"
        else
            new_PAT_value=""
        fi
    fi

    # Update PAT in repositories if provided
    if [[ -n "$new_PAT_value" ]]; then
        for repo in "${PATREPOS[@]}"; do
            set_github_secret "PAT" "$new_PAT_value" "$repo" "GitHub PAT for repository $repo"
        done
    fi
}

update_manifests_applications_variables() {
    local variables=(
        "OLLAMA_FQDN:$OLLAMA_FQDN"
        "ARTIFACTS_FQDN:$ARTIFACTS_FQDN"
        "DOCS_FQDN:$DOCS_FQDN"
    )
    set_multiple_variables "$MANIFESTS_APPLICATIONS_REPO_NAME" "${variables[@]}"
}

update_content_repos_variables() {
    for repo in "${CONTENTREPOS[@]}"; do
        set_github_variable "DOCS_BUILDER_REPO_NAME" "$DOCS_BUILDER_REPO_NAME" "$repo"
    done
}

update_deploy_keys() {
    if ! prompt_confirmation "Do you want to replace the deploy-keys" "N"; then
        return 0
    fi

    for repo in "${DEPLOYKEYSREPOS[@]}"; do
        manage_deploy_key "$repo"
    done
}

update_docs_builder_variables() {
    local variables=(
        "DNS_ZONE:${DNS_ZONE}"
        "MANIFESTS_APPLICATIONS_REPO_NAME:$MANIFESTS_APPLICATIONS_REPO_NAME"
        "MKDOCS_REPO_NAME:$MKDOCS_REPO_NAME"
    )
    set_multiple_variables "$DOCS_BUILDER_REPO_NAME" "${variables[@]}"
}

# Enhanced workflow management functions (following SRP)
#

# Generate clone commands for workflow template
generate_clone_commands() {
    local clone_commands=""
    local secret_key_name

    # Landing page clone command
    local landing_page_secret_key_name
    landing_page_secret_key_name="$(echo "${LANDING_PAGE_REPO_NAME}" | tr '[:upper:]-' '[:lower:]_')_ssh_private_key"

    clone_commands+="      - name: Clone Landing Page\n"
    clone_commands+="        shell: bash\n"
    clone_commands+="        run: |\n"
    clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
    clone_commands+="          echo '\${{ secrets.${landing_page_secret_key_name}}}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
    clone_commands+="          mkdir \$TEMP_DIR/landing-page\n"
    clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${LANDING_PAGE_REPO_NAME}.git \$TEMP_DIR/landing-page/docs\n\n"

    # MkDocs config setup
    clone_commands+="      - name: Link mkdocs.yml\n"
    clone_commands+="        shell: bash\n"
    clone_commands+="        run: |\n"
    clone_commands+="          echo 'site_name: \"Hands on Labs\"' > \$TEMP_DIR/landing-page/mkdocs.yml\n"
    clone_commands+="          echo 'INHERIT: docs/theme/mkdocs.yml' > \$TEMP_DIR/landing-page/mkdocs.yml\n\n"

    # Theme clone command
    local theme_secret_key_name
    theme_secret_key_name="$(echo "${THEME_REPO_NAME}" | tr '[:upper:]-' '[:lower:]_')_ssh_private_key"

    clone_commands+="      - name: Clone Theme\n"
    clone_commands+="        shell: bash\n"
    clone_commands+="        run: |\n"
    clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
    clone_commands+="          echo '\${{ secrets.${theme_secret_key_name}}}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
    clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${THEME_REPO_NAME}.git \$TEMP_DIR/landing-page/docs/theme\n"
    clone_commands+="          docker run --rm -v \$TEMP_DIR/landing-page:/docs \${{ vars.MKDOCS_REPO_NAME }} build -c -d site/\n"
    clone_commands+="          mkdir -p \$TEMP_DIR/build/\n"
    clone_commands+="          cp -a \$TEMP_DIR/landing-page/site \$TEMP_DIR/build/\n\n"

    # Content repositories clone commands
    clone_commands+="      - name: Clone Content Repos\n"
    clone_commands+="        shell: bash\n"
    clone_commands+="        run: |\n"

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
        clone_commands+="          docker run --rm -v \$TEMP_DIR/src/${repo}:/docs \${{ vars.MKDOCS_REPO_NAME }} build -d site/\n"
        clone_commands+="          mv \$TEMP_DIR/src/${repo}/site \$TEMP_DIR/build/site/${repo}\n\n"
    done

    echo -e "$clone_commands"
}

# Validate template file existence
validate_template_file() {
    local template_file="$1"

    if [[ ! -f "$template_file" ]]; then
        log_error "Template file $template_file not found"
        return 1
    fi

    if [[ ! -r "$template_file" ]]; then
        log_error "Template file $template_file is not readable"
        return 1
    fi

    log_info "Template file validation passed: $template_file"
    return 0
}

# Process workflow template with clone commands
process_workflow_template() {
    local template_file="$1"
    local output_file="$2"
    local clone_commands="$3"

    if ! validate_template_file "$template_file"; then
        return 1
    fi

    # Create output directory if needed
    mkdir -p "$(dirname "$output_file")" || {
        log_error "Failed to create directory for $output_file"
        return 1
    }

    # Process template and insert clone commands
    echo -e "$clone_commands" | \
        sed -e "/%%INSERTCLONEREPO%%/r /dev/stdin" -e "/%%INSERTCLONEREPO%%/d" "$template_file" | \
        awk 'BEGIN { blank=0 } { if (/^$/) { blank++; if (blank <= 1) print; } else { blank=0; print; } }' \
        > "$output_file" || {
        log_error "Failed to process workflow template"
        return 1
    }

    log_success "Successfully processed workflow template"
    return 0
}

# Commit and push workflow changes
commit_and_push_workflow() {
    local output_file="$1"
    local repo_name="$2"

    if [[ ! -n $(git status --porcelain) ]]; then
        log_info "No changes detected for $repo_name"
        return 0
    fi

    git add "$output_file" || {
        log_error "Failed to stage $output_file"
        return 1
    }

    if ! git commit -m "Add or update docs-builder.yml workflow"; then
        log_warning "No changes to commit for $repo_name"
        return 0
    fi

    # Create and merge PR
    if git switch -C docs-builder main && \
       git push && \
       gh repo set-default "$GITHUB_ORG/$repo_name" && \
       gh pr create --title "Initializing repo" --body "Update docs builder" && \
       gh pr merge -m --delete-branch; then
        log_success "Successfully created and merged PR for $repo_name"
    else
        log_warning "Failed to create/merge PR for $repo_name"
        return 1
    fi

    return 0
}

# Main function - refactored for better separation of concerns
copy_docs_builder_workflow_to_docs_builder_repo() {
    local template_file="${CURRENT_DIR}/docs-builder.tpl"
    local github_token="$PAT"
    local output_file=".github/workflows/docs-builder.yml"
    local temp_dir

    # Validate prerequisites
    if [[ -z "$github_token" ]]; then
        log_error "GitHub token (PAT) is not set"
        return 1
    fi

    if ! validate_template_file "$template_file"; then
        return 1
    fi

    # Create secure temporary directory with cleanup
    temp_dir=$(create_secure_temp_dir "docs-builder") || return 1
    trap "rm -rf '$temp_dir'" EXIT

    cd "$temp_dir" || {
        log_error "Failed to change to temporary directory"
        return 1
    }

    # Clone repository
    if ! git clone "https://$github_token@github.com/${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME"; then
        log_error "Failed to clone repository $DOCS_BUILDER_REPO_NAME"
        return 1
    fi

    cd "$DOCS_BUILDER_REPO_NAME" || {
        log_error "Failed to change to repository directory"
        return 1
    }

    # Generate and process workflow
    local clone_commands
    clone_commands=$(generate_clone_commands) || {
        log_error "Failed to generate clone commands"
        return 1
    }

    if ! process_workflow_template "$template_file" "$output_file" "$clone_commands"; then
        return 1
    fi

    # Commit and push changes
    if ! commit_and_push_workflow "$output_file" "$DOCS_BUILDER_REPO_NAME"; then
        return 1
    fi

    # Return to original directory
    cd "$CURRENT_DIR" || {
        log_error "Failed to return to original directory"
        return 1
    }

    log_success "Successfully updated docs builder workflow"
    return 0
}

update_lw_agent_token() {
    manage_conditional_secret "LW_AGENT_TOKEN" "$INFRASTRUCTURE_REPO_NAME" \
        "Change the FortiCNAPP Agent token" "Enter value for Laceworks Agent token"
}

update_hub_nva_credentials() {
    # Manage Hub NVA Password
    manage_conditional_secret "HUB_NVA_PASSWORD" "$INFRASTRUCTURE_REPO_NAME" \
        "Change the Hub NVA Password" "Hub NVA Password"

    # Set Hub NVA Username (always set to GITHUB_ORG)
    set_github_secret "HUB_NVA_USERNAME" "$GITHUB_ORG" "$INFRASTRUCTURE_REPO_NAME"
}

update_azure_secrets() {
    # Infrastructure secrets
    local infrastructure_secrets=(
        "AZURE_STORAGE_ACCOUNT_NAME:${AZURE_STORAGE_ACCOUNT_NAME}"
        "TFSTATE_CONTAINER_NAME:${PROJECT_NAME}tfstate"
        "AZURE_TFSTATE_RESOURCE_GROUP_NAME:${PROJECT_NAME}-tfstate"
        "ARM_SUBSCRIPTION_ID:${subscriptionId}"
        "ARM_TENANT_ID:${tenantId}"
        "ARM_CLIENT_ID:${clientId}"
        "ARM_CLIENT_SECRET:${clientSecret}"
        "AZURE_CREDENTIALS:${AZURE_CREDENTIALS}"
    )
    set_multiple_secrets "$INFRASTRUCTURE_REPO_NAME" "${infrastructure_secrets[@]}"

    # Docs builder secrets
    local docs_builder_secrets=(
        "AZURE_CREDENTIALS:${AZURE_CREDENTIALS}"
        "ARM_CLIENT_ID:${clientId}"
        "ARM_CLIENT_SECRET:${clientSecret}"
    )
    set_multiple_secrets "$DOCS_BUILDER_REPO_NAME" "${docs_builder_secrets[@]}"

    RUN_INFRASTRUCTURE="true"
}

update_cloudshell_secrets() {
    # Manage CloudShell Directory Tenant ID
    manage_conditional_secret "CLOUDSHELL_DIRECTORY_TENANT_ID" "$INFRASTRUCTURE_REPO_NAME" \
        "Change the CloudShell Directory Tenant ID" "Enter CloudShell Directory Tenant ID"

    # Manage CloudShell Directory Client ID
    manage_conditional_secret "CLOUDSHELL_DIRECTORY_CLIENT_ID" "$INFRASTRUCTURE_REPO_NAME" \
        "Change the CloudShell Directory Client ID" "Enter CloudShell Directory Client ID"
}

update_management_public_ip() {
    manage_boolean_variable "MANAGEMENT_PUBLIC_IP" "$INFRASTRUCTURE_REPO_NAME" "false"
}

update_production_environment_variables() {
    local current_value new_value=""

    # Get current value from infrastructure repo
    current_value=$(get_github_variable "PRODUCTION_ENVIRONMENT" "$INFRASTRUCTURE_REPO_NAME")

    if [[ -z "$current_value" ]]; then
        # Variable doesn't exist, prompt for initial value
        prompt_text "Set initial PRODUCTION_ENVIRONMENT value ('true' or 'false')" "new_value" "false"
    else
        # Variable exists, offer to toggle
        if prompt_confirmation "Change current value of \"PRODUCTION_ENVIRONMENT=$current_value\"" "N"; then
            if [[ "$current_value" == "true" ]]; then
                new_value="false"
            else
                new_value="true"
            fi
        fi
    fi

    # Set new value if provided (sync to both repos)
    if [[ -n "$new_value" ]]; then
        retry_command "$MAX_RETRIES" "$RETRY_INTERVAL" "set PRODUCTION_ENVIRONMENT in infrastructure repo" \
            gh variable set "PRODUCTION_ENVIRONMENT" --body "$new_value" --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME"

        retry_command "$MAX_RETRIES" "$RETRY_INTERVAL" "set PRODUCTION_ENVIRONMENT in manifests-applications repo" \
            gh variable set "PRODUCTION_ENVIRONMENT" --body "$new_value" --repo "${GITHUB_ORG}/$MANIFESTS_APPLICATIONS_REPO_NAME"

        log_success "Successfully set PRODUCTION_ENVIRONMENT to $new_value"
        RUN_INFRASTRUCTURE="true"
    else
        # Ensure both repos are synchronized
        sync_variable_across_repos "PRODUCTION_ENVIRONMENT" "$INFRASTRUCTURE_REPO_NAME" "$MANIFESTS_APPLICATIONS_REPO_NAME"
    fi
}

update_infrastructure_boolean_variables() {
    local variables=(
        "DEPLOYED"
        "MANAGEMENT_PUBLIC_IP"
        "APPLICATION_SIGNUP"
        "APPLICATION_DOCS"
        "APPLICATION_VIDEO"
        "APPLICATION_DVWA"
        "APPLICATION_OLLAMA"
        "APPLICATION_ARTIFACTS"
        "APPLICATION_EXTRACTOR"
        "GPU_NODE_POOL"
    )

    manage_multiple_boolean_variables "$INFRASTRUCTURE_REPO_NAME" "${variables[@]}"
}

update_infrastructure_variables() {
    local variables=(
        "PROJECT_NAME:${PROJECT_NAME}"
        "DNS_ZONE:${DNS_ZONE}"
        "LOCATION:${LOCATION}"
        "ORG:${GITHUB_ORG}"
        "NAME:${NAME}"
        "LETSENCRYPT_URL:${LETSENCRYPT_URL}"
        "DOCS_BUILDER_REPO_NAME:${DOCS_BUILDER_REPO_NAME}"
        "MANIFESTS_APPLICATIONS_REPO_NAME:${MANIFESTS_APPLICATIONS_REPO_NAME}"
        "MANIFESTS_INFRASTRUCTURE_REPO_NAME:${MANIFESTS_INFRASTRUCTURE_REPO_NAME}"
        "CLOUDSHELL:${CLOUDSHELL:-false}"
    )
    set_multiple_variables "$INFRASTRUCTURE_REPO_NAME" "${variables[@]}"
}

update_manifests_private_keys() {
    # Set SSH private keys for both manifests repositories
    for repo_name in "$MANIFESTS_INFRASTRUCTURE_REPO_NAME" "$MANIFESTS_APPLICATIONS_REPO_NAME"; do
        local secret_key
        secret_key=$(cat "$HOME/.ssh/id_ed25519-${repo_name}")
        local normalized_repo
        normalized_repo=$(echo "$repo_name" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
        set_github_secret "${normalized_repo}_SSH_PRIVATE_KEY" "$secret_key" "$INFRASTRUCTURE_REPO_NAME"
    done
    RUN_INFRASTRUCTURE="true"
}

update_htpasswd() {
    # Manage HTPASSWD secret
    manage_conditional_secret "HTPASSWD" "$INFRASTRUCTURE_REPO_NAME" \
        "Change the Docs HTPASSWD" "Enter value for Docs HTPASSWD"

    # Set HTUSERNAME (always set to GITHUB_ORG)
    set_github_secret "HTUSERNAME" "$GITHUB_ORG" "$INFRASTRUCTURE_REPO_NAME"
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
    update_azure_auth_and_subscription
    update_owner_email
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
    log_info "Creating Azure resources..."

    update_azure_auth_and_subscription
    update_azure_tfstate_resources

    log_success "Successfully completed Azure resource creation."
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
    update_deploy_keys

    echo "Deploy keys update complete."
}

# Update htpasswd
htpasswd() {
    echo "Updating htpasswd..."

    update_github_auth_login
    update_htpasswd

    echo "Htpasswd update complete."
}

# Update management IP
management_ip() {
    echo "Updating management IP..."

    update_github_auth_login
    update_management_public_ip

    echo "Management IP update complete."
}

# Update hub password
hub_password() {
    echo "Updating hub password..."

    update_github_auth_login
    update_hub_nva_credentials

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

# Initialize the environment
validate_config
initialize_environment

# Parse command line arguments
main() {
    local action="--initialize"  # Default action

    # Validate argument count
    if (( $# > 1 )); then
        echo "❌ Error: Only one parameter can be supplied." >&2
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
            echo "❌ Error: Unknown option '$action'" >&2
            show_help
            exit 1
            ;;
    esac

    # Handle infrastructure workflow trigger
    if [[ "$RUN_INFRASTRUCTURE" == "true" ]]; then
        if prompt_confirmation "Do you wish to run the infrastructure workflow" "Y"; then
            log_info "Triggering infrastructure workflow..."

            if ! retry_command "$MAX_RETRIES" "$RETRY_INTERVAL" "trigger infrastructure workflow" \
                gh workflow run -R "$GITHUB_ORG/$INFRASTRUCTURE_REPO_NAME" "infrastructure"; then
                log_error "Failed to trigger infrastructure workflow."
                exit 1
            fi

            log_success "Successfully triggered infrastructure workflow."
        fi
    fi
}

# Execute main function with all arguments
main "$@"
