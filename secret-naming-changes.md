# GitHub Secrets Naming Changes Summary

## Changes Mad### .github/workflows/infrastructure.yml:
- Updated all secret references to use proper case
- Azure ARM secrets kept in SCREAMING_CASE (all references now consistent as `secrets.ARM_*`)
- SSH private key secrets updated to snake_case
- PAT secret kept in SCREAMING_CASE (all references now consistent as `secrets.PAT`)l GitHub secrets have been converted to lowercase snake_case, except for Azure ARM secrets and PAT secrets which remain in SCREAMING_CASE as requested.

### Secrets Changed to snake_case:

1. **SSH Private Key Secrets**:
   - `${REPO_NAME}_SSH_PRIVATE_KEY` → `${repo_name}_ssh_private_key`
   - Updated normalization logic: `tr '[:upper:]-' '[:lower:]_'`
   - Affects all content repos, manifests repos, theme, and landing page

2. **General Secrets**:
   - `OWNER_EMAIL` → `owner_email`
   - `LW_AGENT_TOKEN` → `lw_agent_token`
   - `HUB_NVA_PASSWORD` → `hub_nva_password`
   - `HUB_NVA_USERNAME` → `hub_nva_username`
   - `HTPASSWD` → `htpasswd`
   - `HTUSERNAME` → `htusername`
   - `MKDOCS_REPO_NAME` → `mkdocs_repo_name` (when used as secret)

3. **CloudShell Secrets** (NEW):
   - `cloudshell_directory_tenant_id` (snake_case)
   - `cloudshell_directory_client_id` (snake_case)

### Secrets Kept in SCREAMING_CASE:

1. **Azure ARM Secrets**:
   - `ARM_SUBSCRIPTION_ID`
   - `ARM_TENANT_ID`
   - `ARM_CLIENT_ID`
   - `ARM_CLIENT_SECRET`
   - `AZURE_CREDENTIALS`
   - `AZURE_STORAGE_ACCOUNT_NAME`
   - `TFSTATE_CONTAINER_NAME`
   - `AZURE_TFSTATE_RESOURCE_GROUP_NAME`

2. **Personal Access Token**:
   - `PAT` (confirmed SCREAMING_CASE in both script and workflow)

## Files Modified:

### infrastructure.sh:
- Updated all `gh secret set` commands to use new naming
- Fixed normalization logic for SSH private keys
- Updated template generation for workflow files
- Added `mkdocs_repo_name` as a secret instead of variable
- **NEW**: Added `update_CLOUDSHELL_SECRETS()` function to handle CloudShell directory secrets
- **NEW**: Added `cloudshell` variable support with configuration in config.json
- **NEW**: Added `--cloudshell-secrets` command-line option for standalone CloudShell secret management

### config.json:
- **NEW**: Added `CLOUDSHELL` configuration option (defaults to "false")

### .github/workflows/infrastructure.yml:
- Updated all secret references to use proper case
- Azure secrets kept in SCREAMING_CASE
- SSH private key secrets updated to snake_case
- PAT secret kept in SCREAMING_CASE (all references now consistent as `secrets.PAT`)

### Template-generated workflows:
- SSH private key secret references updated to snake_case
- MkDocs repo name updated to snake_case

## Additional Bug Fixes Applied:

1. **Bash Compatibility Issues**:
   - Fixed `declare -g` usage which is not supported in macOS bash - replaced with standard variable declarations
   - Fixed `readarray` usage which is not available in bash 3.x - replaced with `while read` loop
   - Added missing `local max_retries=3` and `local retry_interval=5` declarations to functions:
     - `update_AZURE_SECRETS()`
     - `update_MANIFESTS_APPLICATIONS_VARIABLES()`
     - `update_CONTENT_REPOS_VARIABLES()`
     - `update_DEPLOY-KEYS()`
     - `update_MANIFESTS_PRIVATE_KEYS()`
     - `update_HUB_NVA_CREDENTIALS()`
     - `update_LW_AGENT_TOKEN()`

2. **CloudShell Integration** (NEW):
   - Added CloudShell directory secrets functionality to match workflow references
   - Created `update_CLOUDSHELL_SECRETS()` function with retry logic and user prompts
   - Added `cloudshell` variable support and configuration parsing
   - Added dedicated `--cloudshell-secrets` command-line option
   - CloudShell secrets use snake_case naming convention (not Azure ARM related)

## Impact:

- All existing secrets will need to be recreated with new names
- Workflow files will reference the new secret names
- Template generation creates workflows with consistent naming
- Azure integration maintains required SCREAMING_CASE format
- PAT secrets maintain SCREAMING_CASE for consistency with GitHub conventions
