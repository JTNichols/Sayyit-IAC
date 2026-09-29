# Sayyit Infrastructure as Code

This repository contains the Azure infrastructure definition and deployment automation for the Sayyit application. The repository is structured around GitHub Actions, Microsoft Entra app registrations, and environment-specific Bicep templates so that infrastructure can be reviewed, validated, and deployed consistently without storing long-lived Azure secrets in source control.

## Repository structure

The current repo includes these key files:

- `main.dev.bicep` - dev environment infrastructure definition
- `main.prod.bicep` - production environment infrastructure definition
- `main.json` - generated ARM/JSON output for the Bicep configuration
- `federated-credential.json` - example payload used to create the GitHub OIDC federated credential
- `.github/workflows/sayyit-iac-action.yml` - GitHub Actions workflow that deploys infrastructure
- `Scripts/GH_to_AZ_credential_PR.ps1` - bootstraps GitHub OIDC for pull request-based deployment
- `Scripts/GH_to_AZ_credential_push.ps1` - bootstraps GitHub OIDC for push-based branch deployment
- `Scripts/What-If-Deploy_main-bicep.ps1` - runs a what-if deployment against the environment-specific template

---

## High-level process

The overall deployment approach follows this flow:

1. Create or validate the GitHub-to-Azure federated credential in Microsoft Entra.
2. Grant the resulting service principal the Azure permissions required to deploy resources.
3. Store the resulting IDs as GitHub repository secrets.
4. Trigger GitHub Actions from a push to the dev branch or a pull request into `main`.
5. Select the appropriate Bicep file for the environment (`main.dev.bicep` or `main.prod.bicep`).
6. Deploy the Azure resources using `az deployment group create`.

The key idea is that the repo is the source of truth for infrastructure, while Azure identity is supplied through OIDC rather than static credentials.

---

## 1. GitHub to Azure federated credentials

The repo contains two related identity bootstrap scripts:

- `Scripts/GH_to_AZ_credential_PR.ps1`
- `Scripts/GH_to_AZ_credential_push.ps1`

These scripts are used to create or update a Microsoft Entra app registration and service principal for GitHub Actions. They do the following:

- Check whether the app registration already exists.
- Create a service principal if it does not exist.
- Create a federated credential using the GitHub OIDC subject format.
- Assign the required RBAC roles at the subscription and resource group scopes.
- Output the Azure values that should be added as GitHub secrets:
  - `AZURE_CLIENT_ID`
  - `AZURE_TENANT_ID`
  - `AZURE_SUBSCRIPTION_ID`

The PR-oriented script uses the pull request OIDC subject pattern:

`repo:JTNichols/Sayyit-IAC:pull_request`

The push-oriented script uses a branch-based subject pattern when deploying from a branch such as `env/dev` or `main`.

The file `federated-credential.json` serves as the payload used to create the federated credential entry.

---

## 2. Bicep templates and environment split

The deployment is split by environment:

- `main.dev.bicep` provisions the development resources.
- `main.prod.bicep` provisions the production resources.

These templates are intentionally separate so dev and prod can evolve independently while staying aligned to the same architecture pattern.

The templates include resources for:

- App Service plan and web app
- Key Vault
- SQL Server and database
- role assignments for both the GitHub deployment identity and app managed identity
- optional External ID tenant setup through Microsoft Graph / Azure Active Directory CIAM resources

The deployment parameters passed from the workflow include:

- `env`
- `baseName`
- `deploymentPrincipalObjectId`
- `sqlServerAdministratorPassword`
- `modifyExternalIdTenant`
- `updatePassword`

`main.json` appears to be the compiled ARM template output generated from the Bicep source and is useful as a generated artifact for review or deployment comparison.

---

## 3. GitHub Actions deployment workflow

The deployment automation is defined in `.github/workflows/sayyit-iac-action.yml`.

### Trigger conditions

The workflow is set up to run for:

- pushes to `env/dev`
- pull requests into `main`
- manual execution via `workflow_dispatch`

This gives the repo a split deployment pattern:

- dev is deployable from a branch push
- production is deployable from a PR into `main`

### Workflow behavior

When the workflow runs, it does the following:

1. Checks out the repo.
2. Verifies the required Azure secrets are present.
3. Logs into Azure using the GitHub OIDC identity.
4. Registers required Azure resource providers.
5. Runs `az bicep lint` against the environment template.
6. Optionally generates a SQL admin password.
7. Deploys the selected template with `az deployment group create`.

The workflow chooses the template path dynamically based on the environment:

- `./main.dev.bicep` for dev
- `./main.prod.bicep` for prod

---

## 4. Pull request driven production deployment

The intended production path is:

1. Developers work in the dev branch flow and validate changes.
2. A pull request is raised targeting `main`.
3. GitHub Actions runs for the PR.
4. The workflow resolves the environment as `prod` and deploys the production Bicep template.
5. Azure resources are updated using the GitHub OIDC identity.

This keeps the production deployment reviewable and controlled while still allowing development and validation to happen in a lower environment first.

---

## 5. Validation and preflight scripts

The repo includes a supporting validation script:

- `Scripts/What-If-Deploy_main-bicep.ps1`

This script performs a `what-if` deployment against the environment-specific template so the infrastructure change can be evaluated before it is applied.

It resolves the correct template from `$EnvironmentName` and runs:

```powershell
az deployment group what-if --template-file ...
```

This helps catch unsafe or unexpected changes before they reach Azure.

---

## 6. Typical end-to-end lifecycle

A common deployment lifecycle for this repo is:

1. Run the OIDC bootstrap script for the repo and environment.
2. Add the returned Azure IDs to GitHub secrets.
3. Update the appropriate Bicep file (`main.dev.bicep` or `main.prod.bicep`).
4. Commit the change.
5. Push to the dev branch for dev validation, or open a PR into `main` for production validation.
6. Run the workflow and inspect the deployment or what-if output.
7. Merge the PR to `main` when the production change is approved.
8. Let GitHub Actions apply the infrastructure changes to Azure.

---

## Why this design works

This architecture provides several advantages:

- no long-lived Azure client secrets are stored in GitHub
- infrastructure is declared in code and version-controlled
- environment-specific templates separate dev and prod concerns
- pull requests provide an approval gate for production changes
- automation makes deployments repeatable and auditable

---

## Summary

This project is a GitHub Actions + Azure OIDC + Bicep deployment pipeline. It begins with creating the GitHub federated credential, proceeds through Azure role assignment and secret configuration, and ends with environment-specific deployments controlled by branch pushes and pull requests into `main`.

The repo is organized so the workflows and scripts are easy to follow: the identity scripts prepare the Azure trust, the Bicep files define the resources, and the GitHub workflow performs the actual deployment.
