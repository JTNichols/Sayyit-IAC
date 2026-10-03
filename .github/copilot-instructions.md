# Copilot Instructions for Sayyit Infrastructure

## Repository purpose
This repository manages Azure infrastructure for Sayyit using Bicep, GitHub Actions, and PowerShell helper scripts.

## Secrets and keys
- Refer to `.github/copilot-secrets.md` for each request. It contains both secrets and sensitive values like Azure subscription IDs, client secrets, and other credentials. Ensure they are handled securely and not exposed in source control.
- `.github/copilot-secrets.md` is on the `.gitignore` to prevent it from being committed to source control, so remember to keep it updated locally with relevant secrets or sensitive values as needed.
- When working on changes that touch authentication, app registrations, Key Vault, GitHub secrets, or connection strings, follow `.github/copilot-secrets.md` in addition to these repo instructions.

## Key repo conventions
- Use `main.dev.bicep` for development infrastructure changes.
- Use `main.prod.bicep` for production infrastructure changes.
- Keep dev and prod templates aligned unless there is a deliberate environment-specific difference.
- Prefer small, explicit Bicep changes over broad refactors.
- Preserve existing resource naming patterns such as `sayyit-dev-*` and `sayyit-prod-*`.
- Do not remove or rename existing parameters, outputs, or resources unless the change explicitly requires it.

## Deployment workflow assumptions
- Infrastructure is deployed by `.github/workflows/sayyit-iac-action.yml`.
- Dev deploys are driven by pushes to `env/dev`.
- Prod deploys are driven by closed pull requests into `main`.
- The workflow selects `main.dev.bicep` or `main.prod.bicep` based on environment.
- The resource group `sayyit_rg1` is expected to already exist.
- Azure identity for deployment is provided through GitHub OIDC, not long-lived secrets.

## Bicep guidance
- Keep parameter names and meanings consistent across dev and prod templates.
- When adding a resource to one environment, consider whether the corresponding resource should exist in the other environment too.
- Prefer Azure RBAC-based access patterns already used in this repo.
- Do not switch existing networking, Key Vault, SQL, or App Service patterns unless requested.
- Treat `Microsoft.AzureActiveDirectory/ciamDirectories` as External ID customer tenant configuration, not a standard workforce Entra tenant.
- If adding Azure SQL Entra administrator support, model it explicitly through SQL server administrator resources instead of replacing unrelated SQL configuration.

## PowerShell guidance
- Follow the style used in the `Scripts` directory: explicit prerequisites, clear `Write-Host` progress messages, and defensive validation.
- Write idempotent scripts where possible.
- Assume scripts are run manually by an operator who is already authenticated with Azure CLI.
- Avoid interactive prompts unless the task explicitly calls for them.

## Validation expectations
- For Bicep changes, prefer validating with `az bicep lint` on the touched template.
- For deployment-impacting changes, prefer a targeted `az deployment group what-if` when inputs are available.
- For PowerShell changes, keep scripts syntactically valid and compatible with the Azure CLI-based workflow used in this repo.

## Change boundaries
- Do not introduce unrelated infrastructure services.
- Do not convert this repo to Terraform or another IaC system.
- Do not add secrets to source control; follow `.github/copilot-secrets.md` for secret-handling rules.
- Do not assume the compiled `.json` templates are the source of truth; the `.bicep` files are authoritative unless the user says otherwise.

## Documentation expectations
- Update `README.md` when a change affects operator workflow, prerequisites, or deployment behavior.
