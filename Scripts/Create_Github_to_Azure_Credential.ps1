# This script bootstraps a Microsoft Entra app registration and service principal for GitHub Actions OIDC authentication.

# It is run once per new GitHub repo/branch combination. 
# It can also be re-run to update the RBAC roles of the Service principal for an existing combination of app+federated credential.
# Prerequisites:
#   1. Must be logged into Azure CLI w/ an account that has permission to create app registrations and service principals
#   2. The resource group must already exist in the current subscription 
#      (therefore main.bicep can't create the RG in param -ResourceGroupName, tho it can modify it)

# This script does the following:
# 1. If not already existing for that repo, it creates a new app registration in EntraID external, and related service principal
#    A. It then assigns the new service principal Contributor + User Access Administrator roles at the resource group scope.
#    B. If a new app registration is created, you must set the GitHub Actions secret "AZURE_CLIENT_ID" for the repo equal to the Application
#    
# 2. If not already existing for that repo/branch, it creates a new federated credential on the app registration for the 
#    repo/branch combination. Note the script checks if the exact Subject identifier already exists on the app registration,
#    NOT the 'Name' of the federated credential. The Name is just a human-readable label & can be duplicated/changed.

 
# example ./Create_Github_to_Azure_Credential.ps1 -OwnerRepo "JTNichols/Sayyit-IAC" -EnvironmentName "dev" -ResourceGroupName "sayyit_rg1"
# Run note: the -OwnerRepo value must exactly match the GitHub repository name (case-sensitive),
#           as the OIDC subject claim preserves the casing of the repository name.
#           Use the exact casing shown in GitHub, e.g. "JTNichols/Sayyit-IAC".
param(
    [Parameter(Mandatory = $true)]
    [string]$OwnerRepo, # e.g. "JTNichols/Sayyit-IAC" or "JTNichols/sayyit"

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName, # e.g. "dev" or "prod"

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName # e.g. "sayyit_rg1"
)
# Verify Repo name
$OwnerRepo = $OwnerRepo.Trim()
if ($OwnerRepo -notmatch '^[^/\s]+/[^/\s]+$') {
    throw "Repo must be in the format 'OWNER/REPO', for example 'JTNichols/sayyit-iac'."
}

# ----------
# SET VARS 
# ----------
$Repo = ($OwnerRepo -split '/', 2)[1]

# Prod builds/deploys from main branch, all other environments from env/{environment name} branch
if ($EnvironmentName -eq 'prod') {
    $Branch = 'main'
}
else {
    $Branch = "env/$EnvironmentName"
}

# -------------------------------------------------------------------------------------------
# Create the EntraId app (if needed)
# -------------------------------------------------------------------------------------------
# Each branch in this app/repo combination has its own federated credential under 
# 'Certificates & secrets' in the $AppName (e.g. 'sayyit-github-actions') app registration. 
#     This is because the OIDC Subject identifier must be unique per federated credential, 
#     and that Subject identifier must have the repo/branch in its name
$AppName = "$Repo-github-actions"
$Subject = "repo:${OwnerRepo}:ref:refs/heads/$Branch"
Write-Host "Setting up OIDC identity for owner/repo '$OwnerRepo' branch '$Branch' on resource group '$ResourceGroupName'..."
Write-Host "Expected federated credential subject: $Subject"
# Get subscription and tenant from current az login context
$SubscriptionId = az account show --query id -o tsv
$TenantId       = az account show --query tenantId -o tsv

# Verify subscription
if (-not $SubscriptionId -or -not $TenantId) {
    throw "Azure CLI is not logged in or unable to read subscription/tenant. Run 'az login' and try again."
}

# Verify resource group already exists in current subscription
az group show --name $ResourceGroupName --query id -o tsv | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Resource group '$ResourceGroupName' was not found in the current subscription."
}

$RgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

Write-Host "Using subscription: $SubscriptionId"
Write-Host "Using tenant:      $TenantId"
Write-Host "Scope:             $RgScope"
 
# Verify/Create app registration. If it already exists the existing one is used to modify Service Principle's scope/roles, if needed.
# If no new scope/roles are needed, the script is idempotent and does nothing.
Write-Host "Checking if Microsoft Entra app registration '$AppName' exists..."

$ExistingApp = az ad app list `
    --filter "displayName eq '$AppName'" `
    --query "[0]" `
    -o json | ConvertFrom-Json

if ($ExistingApp) {
    $AppId = $ExistingApp.appId
    $AppObjectId = $ExistingApp.id
    Write-Host "Using existing app registration '$AppName'."
}
else {
    Write-Host "Creating new app registration '$AppName'."
    $AppId = az ad app create `
        --display-name $AppName `
        --query appId -o tsv

    if (-not $AppId) {
        throw "Failed to create app registration."
    }

    $AppObjectId = az ad app show `
        --id $AppId `
        --query id -o tsv

    Write-Host "Created new app registration."
}

Write-Host "AppId (verify Github repo secret AZURE_CLIENT_ID matches this): $AppId"
Write-Host "AppObjectId  $AppObjectId"

# -------------------------------
# Create/verify service principal 
# -------------------------------
Write-Host "Checking if service principal exists for app '$AppId'..."

$ExistingSpObjectId = az ad sp list `
    --filter "appId eq '$AppId'" `
    --query "[0].id" `
    -o tsv

if (-not $ExistingSpObjectId) {
    Write-Host "Creating new service principal for app registration."
    $SpObjectId = az ad sp create `
        --id $AppId `
        --query id -o tsv

    if (-not $SpObjectId) {
        throw "Failed to create service principal."
    }

    Write-Host "Created new service principal."
}
else {
    $SpObjectId = $ExistingSpObjectId
    Write-Host "Using existing service principal: $SpObjectId"
}
 

# ----------------------------------------------
# Create federated credential JSON
# subject: repo:OWNER/REPO:ref:refs/heads/BRANCH
# ($OwnerBranch.Replace('/','-'))
# ----------------------------------------------
$CredentialName = "github-$($OwnerRepo.Replace('/','-'))-$($Branch.Replace('/','-'))"
$federatedJson = @"
{
  "name": "$CredentialName",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "$Subject",
  "description": "GitHub Actions OIDC for $OwnerRepo branch $Branch",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
"@

$fcPath = ".\federated-credential.json"
$federatedJson | Set-Content -Path $fcPath -Encoding UTF8

 $ExistingFederatedCredentials = az ad app federated-credential list `
    --id $AppObjectId `
    -o json | ConvertFrom-Json

$ExistingFederatedCredential = $ExistingFederatedCredentials | Where-Object {
    $_.name -eq $CredentialName -or $_.subject -eq $Subject
} | Select-Object -First 1
    
Write-Host "DEBUG: ExistingFederatedCredential=$($ExistingFederatedCredential.name)"

if (-not $ExistingFederatedCredential) {
    Write-Host "Creating federated credential '$CredentialName' on app '$AppObjectId' for subject $Subject ..."

    az ad app federated-credential create `
        --id $AppObjectId `
        --parameters "@$fcPath"
}
else {
    Write-Host "Federated credential '$CredentialName' already exists; skipping create."
}

# ------------------------------------------------------------------------------------------------------
# Assign Azure RBAC roles at RG scope. This section is why the script continues even
#     if the app registration + federated credential combo already exists, to allow updating RBAC roles.
# Current roles assigned: Contributor + User Access Administrator
# ------------------------------------------------------------------------------------------------------
$ContributorAssignment = az role assignment list `
    --assignee-object-id $SpObjectId `
    --scope $RgScope `
    --query "[?roleDefinitionName=='Contributor'] | [0].id" `
    -o tsv

if (-not $ContributorAssignment) {
    Write-Host "Assigning 'Contributor' role to service principal at scope $RgScope ..."
    az role assignment create `
        --assignee-object-id $SpObjectId `
        --assignee-principal-type ServicePrincipal `
        --role "Contributor" `
        --scope $RgScope
}
else {
    Write-Host "Contributor role assignment already exists; skipping create."
}

$UserAccessAdminAssignment = az role assignment list `
    --assignee-object-id $SpObjectId `
    --scope $RgScope `
    --query "[?roleDefinitionName=='User Access Administrator'] | [0].id" `
    -o tsv

if (-not $UserAccessAdminAssignment) {
    Write-Host "Assigning 'User Access Administrator' role to service principal at scope $RgScope ..."
    az role assignment create `
        --assignee-object-id $SpObjectId `
        --assignee-principal-type ServicePrincipal `
        --role "User Access Administrator" `
        --scope $RgScope
}
else {
    Write-Host "User Access Administrator role assignment already exists; skipping create."
}

# -----------------------------
# Output values for GitHub secrets
# -----------------------------
Write-Host ""
Write-Host "Done. Use these values for GitHub Actions secrets:"
Write-Host "  AZURE_CLIENT_ID      = $AppId"
Write-Host "  AZURE_TENANT_ID      = $TenantId"
Write-Host "  AZURE_SUBSCRIPTION_ID= $SubscriptionId"
Write-Host ""
Write-Host "App object ID:         $AppObjectId"
Write-Host "SP object ID:          $SpObjectId"
Write-Host "Scope used:            $RgScope"
Write-Host ""
Write-Host "Remember to configure your workflow with:"
Write-Host "  permissions:"
Write-Host "    id-token: write"
Write-Host "    contents: read"
Write-Host "and use azure/login@v2 with these secrets."