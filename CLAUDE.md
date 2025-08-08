# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the **hydration** directory of the 40docs platform - the master orchestration system that manages the entire multi-repository documentation and infrastructure platform. The main `install.sh` script (2,100+ lines) is the central control system that automates GitHub/Azure authentication, SSH deploy key generation, secrets management, and CI/CD workflow deployment across 8+ interconnected repositories.

## Common Development Commands

### Primary Operations
```bash
# Full platform initialization (default action)
./install.sh
./install.sh --initialize

# Destroy entire environment
./install.sh --destroy

# Repository management
./install.sh --sync-forks       # Synchronize GitHub repository forks
./install.sh --deploy-keys      # Update SSH deploy keys across repositories

# Secrets and configuration management
./install.sh --cloudshell-secrets  # Update CloudShell directory secrets
./install.sh --htpasswd           # Change documentation password
./install.sh --management-ip      # Update management IP address
./install.sh --hub-passwd         # Change Fortiweb password

# Azure resource management
./install.sh --create-azure-resources  # Create only Azure resources
```

### Development and Testing
```bash
# Configuration validation
jq '.' config.json              # Validate JSON syntax
./install.sh --help             # Display all available options

# Authentication verification
gh auth status                  # Verify GitHub API access
az account show                 # Verify Azure API access
```

## Architecture Overview

### Core Components
- **install.sh**: Master orchestration script with 60+ functions
- **config.json**: Central configuration file driving all operations
- **Enhanced Security**: Comprehensive validation, retry logic, secure temporary files

### Repository Management Arrays
The script manages repositories through categorized arrays:
- **CONTENTREPOS**: Content + theme + landing-page repositories
- **DEPLOYKEYSREPOS**: Repositories requiring SSH deploy keys
- **PATREPOS**: Repositories requiring Personal Access Token access
- **ALLREPOS**: All managed repositories in the ecosystem

### Multi-Environment Support
- **Fork Detection**: Automatically adjusts naming for development forks
- **Environment Variables**: Production vs staging configurations
- **DNS Management**: Automatic domain adjustments for fork environments

## Key Configuration Patterns

### config.json Structure
```json
{
  "REPOS": ["references"],
  "PROJECT_NAME": "40docs",
  "LOCATION": "eastus", 
  "DNS_ZONE": "40docs.com",
  "DEPLOYED": "true",
  "CLOUDSHELL": "false"
}
```

### Critical Constants
```bash
# Exit codes
EXIT_SUCCESS=0
EXIT_FAILURE=1
EXIT_CONFIG_ERROR=2
EXIT_AUTH_ERROR=3
EXIT_NETWORK_ERROR=4

# Security validation patterns
VALID_EMAIL_REGEX='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
VALID_GITHUB_ORG_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$'
MAX_AZURE_STORAGE_NAME_LENGTH=24
```

## Function Categories and Key Operations

### Input Validation Functions
- `validate_email()` - Email address format validation
- `validate_github_org()` - GitHub organization naming rules (39 chars max)
- `validate_azure_storage_name()` - Azure storage naming (3-24 chars, alphanumeric)
- `validate_dns_zone()` - Domain format validation
- `validate_boolean()` - Boolean value acceptance (true/false/yes/no/y/n/1/0)

### Security and Authentication
- `create_secure_temp_dir()` - Secure temporary file operations (600/700 permissions)
- `prompt_secret()` - Secure password input with validation
- `set_github_secret()` - GitHub secret management with repository validation
- `generate_ssh_key()` - ED25519 SSH key generation with enhanced security

### Azure Integration Functions
- `create_or_verify_resource_group()` - Azure resource group management
- `create_or_verify_storage_account()` - Terraform state storage setup
- `configure_entraid_application()` - Azure EntraID app configuration with logo upload
- `upload_entraid_application_logo()` - Automatic SVG to PNG conversion for Azure branding

### Repository Management
- `manage_deploy_key()` - SSH deploy key management across repositories
- `sync_variable_across_repos()` - Variable synchronization across repositories
- `update_github_forks()` - Fork synchronization with upstream repositories

### Consolidation Functions (DRY Principle)
- `set_github_variable_multiple_repos()` - Centralized GitHub variable setting
- `get_azure_app_object_id()` - Azure AD app object ID retrieval with timeout handling
- `set_github_secret_multiple_repos()` - Centralized GitHub secret management

## Security Best Practices

### File Operations
- All temporary files created with restrictive permissions (600/700)
- Secure directory creation with proper validation
- Input sanitization applied to all user inputs

### Secret Management Pattern
```bash
# SSH Keys follow this pattern: ${REPO_NAME}_SSH_PRIVATE_KEY
REFERENCES_SSH_PRIVATE_KEY
MANIFESTS_INFRASTRUCTURE_SSH_PRIVATE_KEY

# Azure Credentials follow ARM_* pattern
ARM_SUBSCRIPTION_ID
ARM_CLIENT_ID  
ARM_TENANT_ID
ARM_CLIENT_SECRET
```

### Repository Validation
- Repository existence checked before setting secrets
- GitHub API access validated before operations
- Error handling with specific exit codes and context

## Error Handling and Logging

### Enhanced Logging System
- `❌ Error:` - Critical failures requiring immediate attention
- `⚠️ Warning:` - Non-critical issues or retry attempts  
- `✅` - Successful operations
- `•` - Informational messages

### Retry Logic Patterns
- Standardized retry patterns with exponential backoff
- Maximum 3 retry attempts for network operations
- Context-specific error messages with suggestions

### Cross-Platform Compatibility
- Compatible with macOS system bash (3.2.57) and modern versions (4.0+)
- Uses portable `tr` commands instead of bash-4+ specific expansions
- POSIX-compliant command usage throughout

## Common Troubleshooting

### Authentication Errors (Exit Code 3)
```bash
gh auth login                    # Re-authenticate GitHub CLI
az login --use-device-code      # Re-authenticate Azure CLI
```

### Configuration Errors (Exit Code 2)  
```bash
jq '.' config.json              # Validate JSON syntax
# Verify GitHub organization exists and accessible
gh org view YOUR_ORG            # Check organization access
```

### Network/API Errors (Exit Code 4)
```bash
curl -I https://api.github.com   # Test GitHub API connectivity
curl -I https://management.azure.com  # Test Azure API connectivity
```

## Development Guidelines

### Function Design Principles
- Single Responsibility Principle - functions decomposed for specific tasks
- Comprehensive documentation - all functions documented with parameters/returns
- Defensive programming - input validation and edge case handling
- Code consolidation - DRY principle implementation with reusable functions

### Naming Conventions
- Functions: `snake_case`
- Variables: `SCREAMING_SNAKE_CASE` for globals, `snake_case` for locals
- Secret names: `${REPO_NAME}_SECRET_TYPE` pattern

### Testing Approach
- Test changes in fork environment before submitting to main
- Use secure operations for all temporary file handling
- Validate all inputs before processing
- Provide detailed error context for debugging

## Integration Points

### GitHub Actions Integration
- Template-driven workflow generation from `*.yml.tpl` files
- Multi-repository builds with SSH key injection
- Automated Terraform deployments with state management

### Azure Integration
- Service Principal creation with "User Access Administrator" role
- Terraform state management in Azure Storage Account
- EntraID Application branding with automatic logo upload
- Workload Identity configuration for secure authentication

### Certificate and DNS Management
- Let's Encrypt certificate automation (production/staging)
- Azure DNS integration for domain validation
- Automatic CNAME record management

This hydration system represents a sophisticated automation framework implementing industry best practices for security, reliability, and maintainability in a multi-repository DevOps environment.