param(
    [Parameter(Mandatory = $true)]
    [string]$Repo, # e.g. "JTNichols/sayyit-iac"

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName, # e.g. "dev" or "prod"

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName # e.g. "sayyit_rg1"
)
# Verify Repo name
$Repo = $Repo.Trim()
if ($Repo -notmatch '^[^/\s]+/[^/\s]+$') {
    throw "Repo must be in the format 'OWNER/REPO', for example 'JTNichols/sayyit-iac'."
}

$Branch = "env/$EnvironmentName"
$AppName = "sayyit-iac-github-actions-$EnvironmentName"
$Subject = "repo:$Repo:ref:refs/heads/$Branch"
Write-Host "Setting up OIDC identity for repo '$Repo' branch '$Branch' on resource group '$ResourceGroupName'..."
Write-Host "Expected federated credential subject: $Subject"
# Get subscription and tenant from current az login context
$SubscriptionId = az account show --query id -o tsv
$TenantId       = az account show --query tenantId -o tsv

# Verify subscription
if (-not $SubscriptionId -or -not $TenantId) {
    throw "Azure CLI is not logged in or unable to read subscription/tenant. Run 'az login' and try again."
}

# Verify resource group
az group show --name $ResourceGroupName --query id -o tsv | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Resource group '$ResourceGroupName' was not found in the current subscription."
}

$RgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

Write-Host "Using subscription: $SubscriptionId"
Write-Host "Using tenant:      $TenantId"
Write-Host "Scope:             $RgScope"

# -----------------------------
# Create app registration
# -----------------------------
Write-Host "Creating Microsoft Entra app registration '$AppName'..."

$AppId = az ad app create `
    --display-name $AppName `
    --query appId -o tsv

if (-not $AppId) {
    throw "Failed to create app registration."
}

$AppObjectId = az ad app show `
    --id $AppId `
    --query id -o tsv

Write-Host "AppId:       $AppId"
Write-Host "AppObjectId: $AppObjectId"

# -----------------------------
# Create service principal
# -----------------------------
Write-Host "Creating service principal for app '$AppId'..."

$SpObjectId = az ad sp create `
    --id $AppId `
    --query id -o tsv

Write-Host "Service principal objectId: $SpObjectId"

# -----------------------------
# Create federated credential JSON
# subject: repo:OWNER/REPO:ref:refs/heads/BRANCH
# -----------------------------
$federatedJson = @"
{
  "name": "github-$($Branch.Replace('/','-'))",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "$Subject",
  "description": "GitHub Actions OIDC for $Repo branch $Branch",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
"@

$fcPath = ".\federated-credential.json"
$federatedJson | Set-Content -Path $fcPath -Encoding UTF8

Write-Host "Creating federated credential on app '$AppObjectId' for subject $Subject ..."

az ad app federated-credential create `
    --id $AppObjectId `
    --parameters "@$fcPath"

# -----------------------------
# Assign Azure RBAC roles at RG scope
# Contributor + User Access Administrator
# -----------------------------
Write-Host "Assigning 'Contributor' role to service principal at scope $RgScope ..."
az role assignment create `
    --assignee-object-id $SpObjectId `
    --assignee-principal-type ServicePrincipal `
    --role "Contributor" `
    --scope $RgScope

Write-Host "Assigning 'User Access Administrator' role to service principal at scope $RgScope ..."
az role assignment create `
    --assignee-object-id $SpObjectId `
    --assignee-principal-type ServicePrincipal `
    --role "User Access Administrator" `
    --scope $RgScope

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