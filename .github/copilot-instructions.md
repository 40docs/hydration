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
`infrastructure.sh` (1287 lines) is the system's brain. Key functions:

**Initialization (default):**
```bash
./infrastructure.sh --initialize
```
- Authenticates GitHub/Azure
- Creates Azure service principal & storage
- Generates SSH deploy keys for all repos
- Sets GitHub secrets/variables across repositories
- Configures CI/CD workflows

**Other Operations:**
```bash
./infrastructure.sh --sync-forks    # Sync all repository forks
./infrastructure.sh --deploy-keys   # Update SSH deploy keys
./infrastructure.sh --destroy       # Tear down environment
```

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
    docker run --rm -v /tmp/src/references:/docs ${{ secrets.MKDOCS_REPO_NAME }} build
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
