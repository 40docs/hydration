# 40docs Hydration System

> **Multi-Repository Infrastructure & Documentation Platform Orchestrator**

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/40docs/hydration)

The **40docs Hydration System** is a sophisticated automation framework that orchestrates a multi-repository documentation and infrastructure platform. It manages 8+ interconnected repositories through a single control script, deploying a complete Kubernetes-based documentation platform to Azure with full CI/CD automation.

## 🏗️ Architecture Overview

This hydration control repository acts as the central orchestrator for an entire ecosystem of repositories:

| Repository Type | Purpose | Repositories |
|----------------|---------|--------------|
| **Content** | Documentation and theming | `references`, `theme`, `landing-page` |
| **Infrastructure** | Azure resources and K8s manifests | `infrastructure`, `manifests-infrastructure`, `manifests-applications` |
| **Build System** | CI/CD and containerization | `docs-builder`, `mkdocs`, `helm-charts` |

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

## 🚀 Quick Start

### Prerequisites

- **GitHub CLI** (`gh`) - authenticated with appropriate permissions
- **Azure CLI** (`az`) - authenticated with subscription access
- **jq** - JSON processor for configuration parsing
- **Bash 4.0+** - for script execution

### Basic Usage

```bash
# Initialize the entire platform (default action)
./infrastructure.sh

# Or explicitly
./infrastructure.sh --initialize
```

This single command will:
- ✅ Authenticate with GitHub and Azure
- ✅ Create Azure service principal and storage account
- ✅ Generate SSH deploy keys for all repositories
- ✅ Configure GitHub secrets and variables across repositories
- ✅ Set up CI/CD workflows
- ✅ Deploy infrastructure via Terraform

## 📋 Available Commands

| Command | Description |
|---------|-------------|
| `--initialize` | **Full platform initialization** (default) |
| `--destroy` | Tear down environment and clean up resources |
| `--create-azure-resources` | Create Azure resources only |
| `--sync-forks` | Synchronize GitHub repository forks |
| `--deploy-keys` | Update SSH deploy keys across repositories |
| `--htpasswd` | Change documentation password |
| `--management-ip` | Update management IP address |
| `--hub-passwd` | Change Fortiweb password |
| `--cloudshell-secrets` | Update CloudShell directory secrets |
| `--help` | Display help information |

### Examples

```bash
# Sync all repository forks
./infrastructure.sh --sync-forks

# Regenerate SSH deploy keys
./infrastructure.sh --deploy-keys

# Update documentation password
./infrastructure.sh --htpasswd

# Destroy the environment
./infrastructure.sh --destroy
```

## 🔐 Security & Authentication

### GitHub Integration
- Generates ED25519 SSH key pairs for secure cross-repository access
- Creates and manages GitHub secrets/variables automatically
- Supports both Personal Access Tokens (PAT) and SSH key authentication

### Azure Integration
- Creates service principal with "User Access Administrator" role
- Manages Terraform state in Azure Storage Account
- Stores all Azure credentials as encrypted GitHub secrets

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

The system implements a sophisticated multi-repository CI/CD pipeline:

### Repository Arrays
```bash
CONTENTREPOS=()      # Content + theme + landing-page
DEPLOYKEYSREPOS=()   # Repos needing SSH deploy keys
PATREPOS=()          # Repos needing PAT access
ALLREPOS=()          # All managed repositories
```

### GitHub Actions Integration
- **Template-driven workflow generation** from `*.yml.tpl` files
- **Multi-repository builds** with SSH key injection
- **Container-based MkDocs builds** with theme inheritance
- **Automated Terraform deployments** with proper state management

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
├── infrastructure.sh           # Main orchestration script (1,641 lines)
├── config.json                # Central configuration
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
./infrastructure.sh --sync-forks
```

### Key Rotation
```bash
# Regenerate all SSH deploy keys
./infrastructure.sh --deploy-keys
```

### Environment Management
```bash
# Create only Azure resources
./infrastructure.sh --create-azure-resources

# Update specific secrets
./infrastructure.sh --cloudshell-secrets
```

---

> **Note**: This is a sophisticated automation system designed for experienced DevOps teams. Ensure you understand the implications of running these commands in your environment before proceeding.

For detailed implementation information, see the [copilot-instructions.md](.github/copilot-instructions.md) file.
