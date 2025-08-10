# 40docs Hydration System

> **Enterprise-Grade Multi-Repository Infrastructure & Documentation Platform Orchestrator**

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/40docs/hydration)

The **40docs Hydration System** is the master orchestration engine that manages the entire 40docs multi-repository documentation and infrastructure platform. This sophisticated automation framework coordinates 25+ interconnected repositories through a single 2,100+ line control script, deploying a complete enterprise-grade Kubernetes-based documentation platform to Azure with comprehensive DevOps automation.

## 🏗️ Architecture Overview

This hydration control repository acts as the central orchestrator for an entire ecosystem of 25+ repositories:

| Repository Type | Purpose | Repositories |
|----------------|---------|--------------|
| **Content** | Documentation and theming | `references`, `theme`, `landing-page` |
| **Infrastructure** | Azure resources and K8s manifests | `infrastructure`, `manifests-infrastructure`, `manifests-applications` |
| **Build System** | CI/CD and containerization | `docs-builder`, `mkdocs`, `helm-charts` |
| **Security Labs** | Hands-on security training | `lab-forticnapp-*`, `container-security-demo` |
| **DevContainers** | Development environments | `devcontainer-features`, `devcontainer-templates` |
| **Specialized Tools** | Unique utilities and services | `az-decompile`, `fortiweb-ingress`, `video-*`, `tts-microservices` |

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

## ✨ Key Features

### Industry Best Practices Implementation
- **🛡️ Security-First Design**: Secure temporary file operations, input validation, credential protection
- **🔧 Defensive Programming**: Comprehensive error handling with specific exit codes
- **📝 Single Responsibility**: Functions decomposed following SRP principles
- **📚 Comprehensive Documentation**: Full parameter and usage documentation
- **🔄 Retry Logic**: Standardized retry patterns with exponential backoff
- **🌐 Cross-Platform Compatibility**: Works with macOS system bash (3.2.57) and modern versions
- **📊 Enhanced Logging**: Visual symbols for different message types (❌ ⚠️ ✅ •)
- **🎯 DRY Principle Implementation**: Code consolidation functions eliminate duplication and improve maintainability

### Enhanced Automation Capabilities
- **8 Specialized Validation Functions**: Email, GitHub org, Azure resources, DNS zones
- **Secure Credential Management**: Repository existence validation, enhanced secret handling
- **Intelligent Error Recovery**: Detailed error messages with context and suggestions
- **Multi-Environment Support**: Fork-aware naming and staging/production configurations
- **Portable Bash Syntax**: Uses `tr` commands instead of bash-4+ specific expansions
- **Function Ordering**: All functions defined before execution to prevent runtime errors

## 🚀 Quick Start

### Prerequisites

- **GitHub CLI** (`gh`) - authenticated with appropriate permissions
- **Azure CLI** (`az`) - authenticated with subscription access
- **jq** - JSON processor for configuration parsing
- **Bash 3.2.57+** - compatible with macOS system bash and modern versions (4.0+)

### Basic Usage

```bash
# Initialize the entire platform (default action)
./install.sh

# Or explicitly
./install.sh --initialize
```

This single command will:
- ✅ Authenticate with GitHub and Azure (with enhanced validation)
- ✅ Create Azure service principal and storage account (with secure operations)
- ✅ Generate SSH deploy keys for all 25+ repositories (with proper permissions)
- ✅ Configure GitHub secrets and variables across repositories (with input validation)
- ✅ Set up CI/CD workflows with GitOps deployment (with error handling)
- ✅ Deploy complete Kubernetes infrastructure via Terraform
- ✅ Provide detailed feedback through enhanced logging with visual symbols

## 📋 Available Commands

| Command | Description |
|---------|-------------|
| `--initialize` | **Full platform initialization** (default) |
| `--destroy` | Tear down environment and clean up resources |
| `--create-azure-resources` | Create Azure resources only |
| `--sync-forks` | Synchronize GitHub repository forks |
| `--deploy-keys` | Update SSH deploy keys across all 25+ repositories |
| `--htpasswd` | Change documentation password |
| `--management-ip` | Update management IP address |
| `--hub-passwd` | Change Fortiweb password |
| `--cloudshell-secrets` | Update CloudShell directory secrets |
| `--help` | Display help information |

### Examples

```bash
# Sync all repository forks
./install.sh --sync-forks

# Regenerate SSH deploy keys across all repositories
./install.sh --deploy-keys

# Update documentation password
./install.sh --htpasswd

# Destroy the environment
./install.sh --destroy
```

## 🔐 Security & Authentication

### Enhanced Security Features
- **Input Validation**: 8 specialized validation functions for emails, GitHub orgs, Azure resources
- **Secure Temp Files**: All temporary operations use secure creation with restrictive permissions (600/700)
- **Error Handling**: Standardized exit codes (SUCCESS=0, CONFIG_ERROR=2, AUTH_ERROR=3, NETWORK_ERROR=4)
- **Credential Protection**: Enhanced secret management with repository existence validation

### GitHub Integration
- Generates ED25519 SSH key pairs for secure cross-repository access with enhanced security
- Creates and manages GitHub secrets/variables automatically with validation
- Supports both Personal Access Tokens (PAT) and SSH key authentication
- Repository existence validation before setting secrets

### Azure Integration
- Creates service principal with "User Access Administrator" role with secure operations
- Manages Terraform state in Azure Storage Account with retry logic
- Stores all Azure credentials as encrypted GitHub secrets with validation
- Enhanced resource management with proper error handling
- **Azure EntraID Application Branding**: Automatically uploads logos and configures application settings

### Secret Management Pattern
```bash
# SSH Keys: ${REPO_NAME}_SSH_PRIVATE_KEY
REFERENCES_SSH_PRIVATE_KEY
MANIFESTS_INFRASTRUCTURE_SSH_PRIVATE_KEY

# Azure Credentials: ARM_*
ARM_SUBSCRIPTION_ID
ARM_CLIENT_ID
ARM_TENANT_ID
ARM_CLIENT_SECRET
```

## 🔄 CI/CD Workflow

The system implements a sophisticated multi-repository CI/CD pipeline with enhanced reliability:

### Repository Arrays
```bash
CONTENTREPOS=()      # Content + theme + landing-page
DEPLOYKEYSREPOS=()   # Repos needing SSH deploy keys
PATREPOS=()          # Repos needing PAT access
ALLREPOS=()          # All managed repositories
```

### GitHub Actions Integration
- **Template-driven workflow generation** from `*.yml.tpl` files with validation
- **Multi-repository builds** with SSH key injection and secure operations
- **Container-based MkDocs builds** with theme inheritance and error handling
- **Automated Terraform deployments** with proper state management and retry logic

### Enhanced Automation Features
- **Function Decomposition**: Large functions split following Single Responsibility Principle
- **Comprehensive Documentation**: All functions documented with parameters and return values
- **Retry Logic**: Standardized retry patterns with exponential backoff
- **Defensive Programming**: Input validation and edge case handling throughout
- **Code Consolidation**: DRY principle implementation with reusable functions for common operations
- **Maintainability**: Reduced code duplication through consolidation functions

## 🏭 Infrastructure Components

### Azure Resources
- **Azure Kubernetes Service (AKS)** cluster for application hosting
- **Storage Account** for Terraform state management
- **Service Principal** for automated Azure access
- **Resource Groups** organized by environment and purpose

### Kubernetes Deployment
- **Infrastructure manifests** for cluster configuration
- **Application manifests** for documentation platform
- **Helm charts** for package management
- **Multi-environment support** (dev/staging/production)

## 📁 Repository Structure

```
hydration/
├── install.sh                 # Main orchestration script (~2,100+ lines)
├── config.json                # Central configuration
├── CLAUDE.md                  # Claude Code AI assistance instructions
├── .github/
│   ├── workflows/
│   │   └── infrastructure.yml  # Terraform deployment workflow
│   ├── instructions/           # AI coding guidelines
│   ├── prompts/               # GitHub Copilot prompts
│   └── copilot-instructions.md # System documentation
├── .vscode/
│   ├── mcp.json               # Model Context Protocol config
│   ├── extensions.json        # VS Code extensions
│   └── settings.json          # Editor settings
└── README.md                  # This file
```

## 🔧 Configuration

### Azure EntraID Application Logo Upload

The system automatically configures Azure EntraID application branding, including logo upload functionality:

#### Supported Features:
- **Automatic SVG to PNG conversion** (Azure requirement)
- **Multiple conversion tools support**: ImageMagick, librsvg, Inkscape
- **Optimal sizing**: Automatically resizes to 240x240 pixels (Azure recommended)
- **Format validation**: Ensures JPG, PNG, or GIF format (Azure requirement)
- **Size validation**: Enforces 100KB size limit (Azure requirement)
- **Enhanced error handling**: Provides specific error messages for different failure scenarios

#### File Requirements:
- **Logo file**: `platform-FortiCloud.svg` (source file)
- **Converted file**: `platform-FortiCloud.png` (automatically generated)
- **Maximum size**: 100KB
- **Supported formats**: JPG, PNG, GIF (SVG will be converted to PNG)
- **Recommended dimensions**: 240x240 pixels

#### Installation Requirements:
For automatic SVG to PNG conversion, install one of these tools:
```bash
# macOS (recommended)
brew install imagemagick

# Alternative options
brew install librsvg    # For rsvg-convert
brew install inkscape   # For inkscape
```

#### Troubleshooting Logo Upload:
- **SVG not supported**: Logo is automatically converted to PNG format
- **File too large**: Reduce image complexity or resize to smaller dimensions
- **Permission errors**: Ensure Azure account has Application.ReadWrite.All permissions
- **Network timeouts**: Logo upload includes retry logic with timeout handling

### Recent Script Optimizations (Latest Release)

The `install.sh` script has been significantly enhanced with comprehensive optimizations:

#### ✅ **Code Quality Improvements**
- **Unused Function Removal**: Eliminated 3 unused functions to reduce script size and complexity
- **DRY Principle Implementation**: Added 3 new consolidation functions to eliminate code duplication:
  - `set_github_variable_multiple_repos()` - Consolidates GitHub variable setting across repositories
  - `get_azure_app_object_id()` - Standardizes Azure AD app object ID retrieval with timeout handling
  - `set_github_secret_multiple_repos()` - Centralizes GitHub secret management operations

#### ✅ **Maintainability Enhancements**
- **Single Point of Modification**: Changes to GitHub/Azure operations now require updates in only one location
- **Standardized Error Handling**: Consistent retry logic and error messages across all operations
- **Code Reduction**: Eliminated ~16 lines of duplicated code while maintaining full functionality
- **Reusable Functions**: New consolidation functions can be leveraged for future similar operations

#### ✅ **Quality Assurance**
- **Syntax Validation**: Full script syntax validation with bash compatibility checks
- **No Breaking Changes**: All existing functionality preserved during optimization
- **Enhanced Testing**: Easier to test and debug with centralized function patterns

### Environment Variables
The script automatically manages environment variables and GitHub secrets:

```bash
# Project Configuration
PROJECT_NAME="40docs"
LOCATION="eastus"
DNS_ZONE="40docs.com"
DEPLOYED="true"

# Repository Names
DOCS_BUILDER_REPO_NAME="docs-builder"
INFRASTRUCTURE_REPO_NAME="infrastructure"
MANIFESTS_INFRASTRUCTURE_REPO_NAME="manifests-infrastructure"
# ... and more
```

### Customization
1. **Fork this repository** to your organization
2. **Update `config.json`** with your project settings
3. **Run initialization** to set up your environment

## 🛠️ Development

### VS Code Integration
The repository includes comprehensive VS Code configuration:
- **Extensions** for Terraform, GitHub Actions, Azure, and more
- **Settings** optimized for multi-language development
- **MCP integration** for enhanced AI assistance

### AI-Powered Development
- **GitHub Copilot instructions** for consistent code generation
- **Chat modes** for specialized development scenarios
- **Prompt engineering** templates for common tasks

## 🌐 Multi-Environment Support

The system supports multiple deployment environments:

```bash
# Development
PRODUCTION_ENVIRONMENT="false"

# Production
PRODUCTION_ENVIRONMENT="true"
```

Variables are automatically synchronized across:
- Infrastructure repository
- Manifests repositories
- Application configurations

## 🧪 Kubernetes Access

After successful deployment, access your cluster:

```bash
# Get kubeconfig
az aks get-credentials \
  --resource-group ${PROJECT_NAME} \
  --name ${PROJECT_NAME}_k8s-cluster_${LOCATION} \
  --overwrite-existing
```

## 🤝 Contributing

### Pull Request Workflow
```bash
# Set upstream repository
gh repo set-default 40docs/hydration

# Create pull request
gh pr create --title "Your changes" --body "Description"
```

### Development Guidelines
- Follow established naming conventions (snake_case functions, SCREAMING_CASE secrets)
- Test changes in a fork environment before submitting
- Update documentation for new features
- Ensure GitHub Actions workflows pass

## 📚 Advanced Usage

### Fork Synchronization
```bash
# Sync all repository forks with upstream
./install.sh --sync-forks
```

### Key Rotation
```bash
# Regenerate all SSH deploy keys across 25+ repositories
./install.sh --deploy-keys
```

### Environment Management
```bash
# Create only Azure resources
./install.sh --create-azure-resources

# Update specific secrets
./install.sh --cloudshell-secrets
```

## � Troubleshooting

### Common Error Patterns and Solutions

#### Authentication Errors
```bash
# Exit Code 3 (AUTH_ERROR)
ERROR: GitHub authentication failed
ERROR: Azure authentication failed

# Solutions
gh auth login                    # Re-authenticate GitHub CLI
az login --use-device-code      # Re-authenticate Azure CLI
gh auth status                  # Verify GitHub API access
az account show                 # Verify Azure API access
```

#### Configuration Errors
```bash
# Exit Code 2 (CONFIG_ERROR)
ERROR: Configuration validation failed
ERROR: DNS_ZONE must be a valid domain name
ERROR: Invalid GitHub organization name
ERROR: Invalid Azure storage account name

# Solutions
jq '.' config.json              # Validate JSON syntax
# Check GitHub organization exists
gh org view YOUR_ORG            # Check organization access
# Verify all required fields are properly set in config.json
```

#### Network/API Errors
```bash
# Exit Code 4 (NETWORK_ERROR)
ERROR: Failed to set GitHub secret after 3 attempts
ERROR: Failed to create Azure resource group
ERROR: Failed to connect to GitHub API
ERROR: Azure CLI operation timed out

# Solutions
# Check internet connectivity
curl -I https://api.github.com   # Test GitHub API
curl -I https://management.azure.com  # Test Azure API
# Check firewall/proxy settings and retry operations
```

#### Bash Compatibility Issues
```bash
# Error: ${var,,}: bad substitution
# Solution: Script now uses portable tr commands for case conversion
# Compatible with macOS system bash (3.2.57) and modern versions

# If you see this error, the script has been updated to use:
tr '[:upper:]' '[:lower:]'  # Instead of ${var,,}
```

#### Function Ordering Errors
```bash
# Error: command not found (for validation functions)
# Solution: All functions now properly defined before execution
# Ensure you're running the updated script version
```

#### SSH Key Issues
```bash
# Deploy key already exists or invalid permissions
ERROR: Key already exists on repository
ERROR: Permission denied (publickey)

# Solutions
./install.sh --deploy-keys  # Regenerate all deploy keys across repositories

# Manual key inspection
ls -la ~/.ssh/id_ed25519-*
```

#### Repository Access Problems
```bash
# Verify repository existence and permissions
gh repo view YOUR_ORG/REPO_NAME
# Sync forks if using forked repositories
./install.sh --sync-forks
```

#### Enhanced Logging System
The script provides visual feedback through standardized logging:
- `❌ Error:` - Critical failures requiring immediate attention
- `⚠️ Warning:` - Non-critical issues or retry attempts
- `✅` - Successful operations
- `•` - Informational messages
- `Processing:` - Status updates

#### Exit Codes Reference
- `0` - Success
- `1` - General failure
- `2` - Configuration error
- `3` - Authentication error
- `4` - Network error

### Validation & Debugging

#### Input Validation Errors
The system includes comprehensive validation for:
- **Email addresses**: Must match standard email regex pattern
- **GitHub organizations**: Must follow GitHub naming rules (39 chars max)
- **Azure storage names**: Must be 3-24 chars, lowercase letters/numbers only
- **DNS zones**: Must be valid domain format with at least one dot
- **Boolean values**: Accepts true/false/yes/no/y/n/1/0 (case-insensitive)

#### Cross-Platform Compatibility
- **Bash Version Detection**: Script automatically works with different bash versions
- **Portable Syntax**: All operations use POSIX-compliant commands
- **Function Definition Order**: All functions defined before execution
- **Error Handling**: Enhanced error messages with context and suggestions

#### Logging & Error Context
- All functions provide detailed error messages with context
- Error messages include function name and line number when available
- Specific exit codes help identify the type of error encountered
- Visual symbols make it easy to identify message types at a glance

#### Security Validation
- Repository existence checked before setting secrets
- File permissions validated for temporary files (600/700)
- Input sanitization applied to all user inputs

---

> **Note**: This is a sophisticated automation system designed for experienced DevOps teams. The script features industry-standard error handling, cross-platform bash compatibility (3.2.57+), and comprehensive input validation. The enhanced logging system with visual symbols provides clear feedback to help troubleshoot issues quickly. The system has been thoroughly tested for reliability and security, but ensure you understand the implications of running these commands in your environment before proceeding.

For detailed implementation information, see the [copilot-instructions.md](.github/copilot-instructions.md) file.
