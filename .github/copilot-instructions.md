# 40docs Hydration System - AI Coding Instructions

## System Overview
This is a **hydration control repository** that orchestrates a multi-repository documentation and infrastructure platform. The system manages 8+ interconnected repositories through a single automation script, deploying a Kubernetes-based documentation platform to Azure.

## Core Architecture

### Repository Ecosystem
The system manages three types of repositories defined in `config.json`:

**Content Repositories:**
- `references`: Documentation content
- `theme`: MkDocs theme components
- `landing-page`: Main site landing page

**Infrastructure Repositories:**
- `infrastructure`: Terraform IaC for Azure resources
- `manifests-infrastructure`: Kubernetes infrastructure manifests
- `manifests-applications`: Application deployment manifests

**Build System:**
- `docs-builder`: GitHub Actions workflow orchestrator
- `mkdocs`: Containerized MkDocs image
- `helm-charts`: Kubernetes Helm charts

### Configuration-Driven Design
All system behavior is controlled by `config.json`:
```json
{
  "REPOS": ["references"],
  "PROJECT_NAME": "40docs",
  "LOCATION": "eastus",
  "DNS_ZONE": "40docs.com",
  "DEPLOYED": "true"
}
```

## Critical Workflows

### Master Orchestration Script
`infrastructure.sh` (~2127 lines) is the system's brain, enhanced with industry best practices and cross-platform compatibility:

**Key Features:**
- **Defensive Programming**: Comprehensive input validation and error handling
- **Security-First Design**: Secure temporary file operations and credential management
- **Single Responsibility**: Functions decomposed following SRP principles
- **Comprehensive Documentation**: Full parameter and usage documentation
- **Standardized Error Handling**: Specific exit codes and detailed error messages
- **Cross-Platform Compatibility**: Compatible with macOS system bash (3.2.57+) and modern bash versions
- **Enhanced Logging**: Visual symbols for different message types (❌ ⚠️ ✅ •)

**Initialization (default):**
```bash
./infrastructure.sh --initialize
```
- Authenticates GitHub/Azure with enhanced validation
- Creates Azure service principal & storage with secure operations
- Generates SSH deploy keys with proper permissions
- Sets GitHub secrets/variables with input validation
- Configures CI/CD workflows with error handling

**Other Operations:**
```bash
./infrastructure.sh --sync-forks    # Sync all repository forks
./infrastructure.sh --deploy-keys   # Update SSH deploy keys
./infrastructure.sh --destroy       # Tear down environment
```

### Enhanced Security Features
- **Input Validation**: 8 specialized validation functions for emails, GitHub orgs, Azure resources
- **Secure Temp Files**: All temporary operations use secure creation with restrictive permissions
- **Error Handling**: Standardized exit codes (SUCCESS=0, CONFIG_ERROR=2, AUTH_ERROR=3, NETWORK_ERROR=4)
- **Credential Protection**: Enhanced secret management with repository existence validation

### Enhanced Logging System
The script uses a standardized logging system with visual symbols:
- `log_error()` - ❌ Red error symbol for critical failures
- `log_warning()` - ⚠️ Yellow yield symbol for warnings and retries
- `log_success()` - ✅ Green checkmark for successful operations
- `log_info()` - • Bullet point for informational messages
- `log_progress()` - Plain text for processing status

### Cross-Platform Compatibility
- **Bash Version Support**: Compatible with macOS system bash (3.2.57) and modern versions (4.0+)
- **Portable Syntax**: Uses `tr '[:upper:]' '[:lower:]'` instead of bash-4+ specific `${var,,}` expansion
- **Function Ordering**: All functions defined before execution to prevent "command not found" errors

### Repository Arrays Pattern
The script builds different repository arrays for different purposes:
```bash
CONTENTREPOS=()      # Content + theme + landing-page
DEPLOYKEYSREPOS=()   # Repos needing SSH deploy keys
PATREPOS=()          # Repos needing PAT access
ALLREPOS=()          # All managed repositories
```

### Azure Integration Pattern
**Service Principal Management:**
- Creates SP with name `${PROJECT_NAME}`
- Assigns "User Access Administrator" role
- Stores credentials in GitHub secrets as `ARM_*` variables

**Storage Account Naming:**
```bash
AZURE_STORAGE_ACCOUNT_NAME=$(echo "rmmuap{$PROJECT_NAME}account" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z' | cut -c 1-24)
```

### SSH Deploy Key Automation
For each repository requiring access:
1. Generates ED25519 key pairs: `id_ed25519-${repo}`
2. Adds public key as deploy key to target repo
3. Stores private key as GitHub secret: `${REPO_NAME}_SSH_PRIVATE_KEY`
4. Keys enable cross-repo cloning in GitHub Actions

## GitHub Actions Pattern

### Template-Driven Workflow Generation
The system generates workflows from templates:
- `docs-builder.yml.tpl` → customized per environment
- SSH key injection for cross-repo access
- Container-based MkDocs builds with theme inheritance

### Multi-Repository Build Process
```yaml
# Pattern: Clone all content repos with SSH keys
- name: Clone Content Repos
  run: |
    echo '${{ secrets.REFERENCES_SSH_PRIVATE_KEY }}' > ~/.ssh/id_ed25519
    git clone git@github.com:${{ github.repository_owner }}/references.git
    docker run --rm -v /tmp/src/references:/docs ${{ vars.MKDOCS_REPO_NAME }} build
```

## Project-Specific Conventions

### Naming Patterns
- Repository secrets: `${REPO_NAME}_SSH_PRIVATE_KEY` (uppercase, hyphens→underscores)
- Azure resources: `${PROJECT_NAME}-${purpose}` (e.g., `40docs-tfstate`)
- DNS: `${service}.${DNS_ZONE}` (e.g., `docs.40docs.com`)

### Environment Variable Management
**GitHub Organization Detection:**
```bash
GITHUB_ORG=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)/.*#\1#p')
if [ "$GITHUB_ORG" != "$PROJECT_NAME" ]; then
  PROJECT_NAME="${GITHUB_ORG}-${PROJECT_NAME}"  # Prefix for forks
  DNS_ZONE="${GITHUB_ORG}.${DNS_ZONE}"
fi
```

### Retry & Error Handling Pattern
Critical operations use standardized retry logic:
```bash
max_retries=3
for ((attempt=1; attempt<=max_retries; attempt++)); do
  if command; then break; fi
  if [[ $attempt -lt $max_retries ]]; then
    sleep $retry_interval
  fi
done
```

### Boolean Variable Management
Infrastructure boolean vars (DEPLOYED, APPLICATION_*) are managed through interactive prompts with GitHub CLI integration.

## Development Workflow

### Making Changes
1. Modify `config.json` for repository/configuration changes
2. Update `infrastructure.sh` for new automation features
3. Test with `--initialize` in a fork environment
4. Use `--sync-forks` to pull upstream changes

### Debugging Common Issues
- **Failed deployments**: Check `RUN_INFRASTRUCTURE` flag and GitHub secrets
- **SSH key issues**: Regenerate with `--deploy-keys`
- **Fork sync problems**: Verify GitHub authentication and repo permissions
- **Bash compatibility errors**: Script now compatible with macOS bash 3.2.57+ and modern versions
- **Function not found errors**: Fixed by proper function definition ordering

### Shell Compatibility Guidelines
When generating or executing complex CLI commands, especially those involving:
- Advanced bash features (arrays, parameter expansion, process substitution)
- Multiple chained commands with pipes or redirections
- Complex variable manipulations or string operations
- Script execution or sourcing operations

**Always prefer explicit bash execution** when the user's default shell is zsh:

```bash
# Instead of running directly in zsh (which may fail):
./infrastructure.sh --initialize

# Use explicit bash execution:
bash ./infrastructure.sh --initialize

# For complex command sequences:
bash -c 'command1 && command2 | command3'

# For scripts with bash-specific syntax:
bash -euo pipefail script.sh
```

**Rationale**:
- macOS defaults to zsh, but the infrastructure script requires bash-specific features
- zsh has different array handling, parameter expansion, and built-in behaviors
- Explicit bash execution ensures consistent behavior across different user environments
- Prevents subtle compatibility issues that may not be immediately apparent

### Troubleshooting Script Execution
**Common Error Patterns:**
- `${var,,}: bad substitution` - Fixed with portable `tr` commands for case conversion
- `command not found` - Fixed with proper function ordering before execution
- Authentication failures - Run `gh auth login` and `az login`
- Repository access denied - Check deploy keys and PAT configuration

**Validation Functions:**
- `validate_email()` - Email format validation with regex
- `validate_github_org()` - GitHub organization name validation
- `validate_azure_storage_name()` - Azure storage account naming rules (3-24 chars, alphanumeric)
- `validate_dns_zone()` - DNS zone format validation
- `validate_non_empty()` - Non-empty field validation with custom error messages
- `validate_boolean()` - Boolean value validation (true/false/yes/no/y/n/1/0)

### Key Files to Understand
- `config.json`: System configuration
- `infrastructure.sh`: Master automation (focus on functions like `update_AZURE_SECRETS`, `update_DEPLOY-KEYS`)
- `.github/workflows/infrastructure.yml`: Terraform deployment workflow
- `dispatch.yml.tpl` and `docs-builder.yml.tpl`: Workflow templates

## Integration Points
- **Azure**: Service principals, storage accounts, Kubernetes clusters
- **GitHub**: Actions workflows, secrets, deploy keys, repository management
- **Docker**: MkDocs containers, theme building, site generation
- **Terraform**: Infrastructure as Code via GitHub Actions
- **Kubernetes**: Application deployment via manifests repositories

### Repository Arrays Pattern
The script builds different repository arrays for different purposes:
```bash
CONTENTREPOS=()      # Content + theme + landing-page
DEPLOYKEYSREPOS=()   # Repos needing SSH deploy keys
PATREPOS=()          # Repos needing PAT access
ALLREPOS=()          # All managed repositories
```

### Azure Integration Pattern
**Service Principal Management:**
- Creates SP with name `${PROJECT_NAME}`
- Assigns "User Access Administrator" role
- Stores credentials in GitHub secrets as `ARM_*` variables

**Storage Account Naming:**
```bash
AZURE_STORAGE_ACCOUNT_NAME=$(echo "rmmuap{$PROJECT_NAME}account" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z' | cut -c 1-24)
```

### SSH Deploy Key Automation
For each repository requiring access:
1. Generates ED25519 key pairs: `id_ed25519-${repo}`
2. Adds public key as deploy key to target repo
3. Stores private key as GitHub secret: `${REPO_NAME}_SSH_PRIVATE_KEY`
4. Keys enable cross-repo cloning in GitHub Actions

## GitHub Actions Pattern

### Template-Driven Workflow Generation
The system generates workflows from templates:
- `docs-builder.yml.tpl` → customized per environment
- SSH key injection for cross-repo access
- Container-based MkDocs builds with theme inheritance

### Multi-Repository Build Process
```yaml
# Pattern: Clone all content repos with SSH keys
- name: Clone Content Repos
  run: |
    echo '${{ secrets.REFERENCES_SSH_PRIVATE_KEY }}' > ~/.ssh/id_ed25519
    git clone git@github.com:${{ github.repository_owner }}/references.git
    docker run --rm -v /tmp/src/references:/docs ${{ vars.MKDOCS_REPO_NAME }} build
```

## Project-Specific Conventions

### Naming Patterns
- Repository secrets: `${REPO_NAME}_SSH_PRIVATE_KEY` (uppercase, hyphens→underscores)
- Azure resources: `${PROJECT_NAME}-${purpose}` (e.g., `40docs-tfstate`)
- DNS: `${service}.${DNS_ZONE}` (e.g., `docs.40docs.com`)

### Environment Variable Management
**GitHub Organization Detection:**
```bash
GITHUB_ORG=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)/.*#\1#p')
if [ "$GITHUB_ORG" != "$PROJECT_NAME" ]; then
  PROJECT_NAME="${GITHUB_ORG}-${PROJECT_NAME}"  # Prefix for forks
  DNS_ZONE="${GITHUB_ORG}.${DNS_ZONE}"
fi
```

### Retry & Error Handling Pattern
Critical operations use standardized retry logic:
```bash
max_retries=3
for ((attempt=1; attempt<=max_retries; attempt++)); do
  if command; then break; fi
  if [[ $attempt -lt $max_retries ]]; then
    sleep $retry_interval
  fi
done
```

### Boolean Variable Management
Infrastructure boolean vars (DEPLOYED, APPLICATION_*) are managed through interactive prompts with GitHub CLI integration.
