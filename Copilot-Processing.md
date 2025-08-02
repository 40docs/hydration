# Copilot Processing - Convert GitHub Secrets/Variables to SCREAMING_CASE

## User Request
Change all the GitHub variables and secrets to SCREAMING_CASE in both the infrastructure.sh and .github/workflows/infrastructure.yml

## Current Analysis
- Need to reverse previous snake_case changes
- Convert all GitHub secrets and variables to SCREAMING_CASE
- Update both infrastructure.sh script and workflow file
- Maintain consistency across both files

## Action Plan

### Phase 1: Planning - ✓ COMPLETE
- [x] Identify all secrets and variables to convert
- [x] Plan systematic conversion approach

### Phase 2: Script Updates - ✓ COMPLETE
- [x] Update infrastructure.sh secret creation to use SCREAMING_CASE
- [x] Update function calls and variable references
- [x] Update normalization logic for SSH keys (tr '[:lower:]' '[:upper:]')

### Phase 3: Workflow Updates - ✓ COMPLETE
- [x] Update .github/workflows/infrastructure.yml
- [x] Convert all secret and variable references to SCREAMING_CASE
- [x] Verify consistency between script and workflow

### Phase 4: Summary - ✓ COMPLETE
- [x] Verify all references use SCREAMING_CASE
- [x] Document changes made
- [x] Confirm functionality intact

### Phase 3: Generation - ✓ COMPLETE
- [x] Create comprehensive `.github/copilot-instructions.md`
- [x] Include specific examples from codebase
- [x] Focus on project-specific patterns and conventions
- [x] Document critical workflows and commands

### Phase 4: Review & Finalize
- [x] Validate completeness of instructions
- [x] Add summary to processing file
- [x] Present to user for feedback

## Analysis Results

### Core Architecture
This is a **hydration control repository** that orchestrates a multi-repository documentation and infrastructure system:

**Repository Types:**
- Content repos (references, theme, landing-page)
- Infrastructure (infrastructure, manifests-infrastructure, manifests-applications)
- Build system (docs-builder, mkdocs, helm-charts)

**Key Components:**
- `config.json`: Central configuration defining all repository names and settings
- `infrastructure.sh`: Master orchestration script (1287 lines) handling entire system lifecycle
- Multi-stage deployment to Azure with Kubernetes
- Automated docs building with MkDocs and containerized workflows

### Key Patterns Discovered
1. **JSON-driven configuration** - All repo names, settings centralized in config.json
2. **Multi-repository orchestration** - Single script manages 8+ related repositories
3. **SSH deploy key management** - Automated key generation/distribution for repo access
4. **Azure integration** - Service principal creation, storage account management, secrets injection
5. **GitHub Actions automation** - Template-driven workflow generation across repositories
6. **Container-based docs building** - MkDocs containerization with theme inheritance

## Summary

Successfully created `.github/copilot-instructions.md` with comprehensive guidance for AI coding agents working in this hydration system. The instructions focus on the unique multi-repository orchestration patterns, Azure integration specifics, and the critical `infrastructure.sh` automation script that drives the entire system.

Key sections covered:
- System overview and repository ecosystem
- Configuration-driven design patterns
- Critical workflow commands and operations
- Project-specific naming conventions
- Development workflow and debugging guidance
- Integration points with Azure, GitHub, Docker, and Kubernetes

The instructions are immediately actionable and focus on this project's specific patterns rather than generic advice.
