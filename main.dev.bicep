// main.dev.bicep
//
// Sayyit development environment infrastructure.
//
// Target:
//   Workforce tenant:       sayyitadmin.onmicrosoft.com
//   Resource group:         sayyitadmin_rg1
//   Environment:            dev
//
// This template creates:
//   - App Service plan:      sayyit-dev-asp
//   - Blazor WASM web app:   sayyit-dev-web
//   - ASP.NET Core API:      sayyit-dev-api
//   - Key Vault:             sayyit-dev-kv
//   - Azure SQL server:      sayyit-dev-sqlserver
//   - Azure SQL database:    sayyit-dev-db
//   - Key Vault RBAC assignments
//   - Temporary SQL firewall rule for the administrator IP
//
// This template does NOT:
//   - Create or modify sayyit.onmicrosoft.com External ID.
//   - Create or modify External ID user flows, customer users, or registrations.
//   - Create SQL passwords unless updatePassword is explicitly true.
//
// The GitHub Actions OIDC application/service principal must already exist in
// sayyitadmin.onmicrosoft.com. azure_bootstrap.ps1 creates it.
//
// Required deployment parameters supplied by sayyit-iac-action.yml:
//   env
//   baseName
//   deploymentPrincipalObjectId
//   AZURE_GITHUB_OIDC_SP_ID
//   sqlServerAdministratorPassword
//   updatePassword
//   modifyExternalIdTenant

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

@allowed([
  'dev'
])
param env string = 'dev'

@minLength(1)
param baseName string = 'sayyit'

// Object ID of the service principal that executes the IaC GitHub Actions
// workflow. In sayyit-iac, this is resolved from AZURE_CLIENT_ID:
//
//   az ad sp show --id "${{ secrets.AZURE_CLIENT_ID }}" --query id -o tsv
//
@minLength(1)
param deploymentPrincipalObjectId string

// Service principal object ID supplied through the repository secret
// AZURE_GITHUB_OIDC_SP_ID.
//
// For the current workforce-tenant bootstrap, this is:
//
//   JTNichols/sayyit-iac
//   0c1ad1a3-67ac-45c5-b637-966baf0ccf26
//
// Keep this parameter rather than hard-coding the ID, so it remains explicit
// in the GitHub workflow and can be rotated/recreated safely.
@minLength(1)
param AZURE_GITHUB_OIDC_SP_ID string

// A secure deployment parameter. Only used when updatePassword is true.
@secure()
param sqlServerAdministratorPassword string = ''

// Set true only when initially creating or intentionally rotating the SQL
// logical-server administrator password.
param updatePassword bool = false

// Retained only for workflow compatibility. It must remain false for the new
// workforce subscription: External ID is preserved separately.
param modifyExternalIdTenant bool = false

// The intended Azure Resource Manager region for dev hosting and database.
param locationWebApp string = 'centralus'
param locationSqlServer string = 'centralus'

// By default, put Key Vault in the same location as sayyitadmin_rg1.
param locationKeyVault string = resourceGroup().location

// Current administrator public IP. Temporary development bootstrap access only.
// Replace/remove after private networking is implemented.
param administratorPublicIpAddress string = '174.104.161.188'

// Existing SQL administrator login name. Its password is stored in Key Vault.
param sqlServerAdminLoginName string = 'sqladminuser'

// Non-secret External ID values. They remain in the customer-facing tenant.
// The web app currently uses these values in appsettings.json.
// These settings are defined here for future API/web configuration; no CIAM
// resources are created by this Bicep file.
param externalIdAuthority string = 'https://sayyit.ciamlogin.com'
param externalIdWebClientId string = '0becd0dd-685a-4825-98c1-5ce259fd0ff8'

// -----------------------------------------------------------------------------
// Variables
// -----------------------------------------------------------------------------

var environmentName = env

var appServicePlanName = '${baseName}-${environmentName}-asp'
var webAppName = '${baseName}-${environmentName}-web'
var apiAppName = '${baseName}-${environmentName}-api'
var keyVaultName = '${baseName}-${environmentName}-kv'
var sqlServerName = '${baseName}-${environmentName}-sqlserver'
var sqlDatabaseName = '${baseName}-${environmentName}-db'

var commonTags = {
  project: baseName
  environment: environmentName
  managedBy: 'Bicep'
  tenant: 'sayyitadmin.onmicrosoft.com'
}

// Built-in Key Vault RBAC role IDs.
// Key Vault Secrets User: read secret values.
// Key Vault Secrets Officer: create, update, and delete secret values.
var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

var keyVaultSecretsOfficerRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
)

// The IaC workflow currently passes this GitHub OIDC service principal object
// ID through AZURE_GITHUB_OIDC_SP_ID.
var githubOidcServicePrincipalObjectId = AZURE_GITHUB_OIDC_SP_ID

// SQL Server properties. Public access is intentionally enabled temporarily
// for dev bootstrap and DACPAC deployment. The database workflow also creates
// a short-lived runner-specific firewall rule and restores network state.
var sqlServerProperties = union({
  administratorLogin: sqlServerAdminLoginName
  version: '12.0'
  minimumTlsVersion: '1.2'
  publicNetworkAccess: 'Enabled'
}, updatePassword ? {
  administratorLoginPassword: sqlServerAdministratorPassword
} : {})

// -----------------------------------------------------------------------------
// 1. App Service plan
// -----------------------------------------------------------------------------

resource dev_AppServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: locationWebApp
  kind: 'app'
  sku: {
    name: 'F1'
    tier: 'Free'
  }
  properties: {
    reserved: false
  }
  tags: commonTags
}

// -----------------------------------------------------------------------------
// 2. Blazor WebAssembly web application
// -----------------------------------------------------------------------------

resource dev_WebApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: locationWebApp
  kind: 'app'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: dev_AppServicePlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      alwaysOn: false
      http20Enabled: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
    }
  }
  tags: commonTags
}

// Web application settings are non-secret. The deployed Blazor application is
// static/client-side, so do not put SQL credentials here.
resource dev_WebAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: dev_WebApp
  name: 'appsettings'
  properties: {
    ASPNETCORE_ENVIRONMENT: 'Development'
    Sayyit__Environment: environmentName
    Sayyit__ApiBaseUrl: 'https://${apiAppName}.azurewebsites.net'
    AzureAd__Authority: externalIdAuthority
    AzureAd__ClientId: externalIdWebClientId
    AzureAd__ValidateAuthority: 'true'
  }
}

// -----------------------------------------------------------------------------
// 3. ASP.NET Core REST API application
// -----------------------------------------------------------------------------

resource dev_WebApi 'Microsoft.Web/sites@2023-12-01' = {
  name: apiAppName
  location: locationWebApp
  kind: 'app'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: dev_AppServicePlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      alwaysOn: false
      http20Enabled: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      netFrameworkVersion: 'v8.0'
    }
  }
  tags: commonTags
}

// API configuration intentionally contains no SQL password. The API should use
// its managed identity to read a connection secret from Key Vault, or use a
// future passwordless Azure SQL/managed-identity design.
resource dev_WebApiSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: dev_WebApi
  name: 'appsettings'
  properties: {
    ASPNETCORE_ENVIRONMENT: 'Development'
    Sayyit__Environment: environmentName
    Sayyit__KeyVaultUri: dev_KeyVault.properties.vaultUri
    Sayyit__SqlServerName: sqlServerName
    Sayyit__SqlDatabaseName: sqlDatabaseName
    Sayyit__SqlServerFqdn: '${sqlServerName}.database.windows.net'
    Sayyit__WebOrigin: 'https://${webAppName}.azurewebsites.net'
    AzureAd__Authority: externalIdAuthority
    AzureAd__Audience: externalIdWebClientId
    AzureAd__ValidateAuthority: 'true'
  }
}

// Explicit CORS configuration for the dev Blazor web app.
// Add future custom-domain origins only when they exist and are verified.
resource dev_WebApiCors 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: dev_WebApi
  name: 'web'
  properties: {
    cors: {
      allowedOrigins: [
        'https://${webAppName}.azurewebsites.net'
      ]
      supportCredentials: true
    }
  }
}

// -----------------------------------------------------------------------------
// 4. Key Vault
// -----------------------------------------------------------------------------

resource dev_KeyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: locationKeyVault
  tags: commonTags
  properties: {
    // Resolves to sayyitadmin.onmicrosoft.com because this deployment targets
    // sayyitadmin.subscription.
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 30

    // Temporary development bootstrap setting. The GitHub-hosted database
    // deployment workflow needs to read sqlServerAdministratorPassword.
    // Harden this after a private deployment path is established.
    publicNetworkAccess: 'Enabled'

    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// -----------------------------------------------------------------------------
// 5. Key Vault RBAC: application managed identities
// -----------------------------------------------------------------------------

resource dev_WebAppKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dev_KeyVault.id, dev_WebApp.id, 'KeyVaultSecretsUser')
  scope: dev_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: dev_WebApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource dev_WebApiKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dev_KeyVault.id, dev_WebApi.id, 'KeyVaultSecretsUser')
  scope: dev_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: dev_WebApi.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// 6. Key Vault RBAC: GitHub Actions deployment identity
// -----------------------------------------------------------------------------

// The application-repository OIDC principal needs this data-plane role because
// sayyit-db-action.yml retrieves sqlServerAdministratorPassword using:
//
// az keyvault secret show --vault-name sayyit-dev-kv
//
resource dev_GitHubOidcPrincipalKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dev_KeyVault.id, githubOidcServicePrincipalObjectId, 'GitHubOidcKeyVaultSecretsUser')
  scope: dev_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: githubOidcServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

// The infrastructure deployment principal can create/update secrets when
// updatePassword=true, including sqlServerAdministratorPassword.
resource dev_IacPrincipalKeyVaultSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dev_KeyVault.id, deploymentPrincipalObjectId, 'IacKeyVaultSecretsOfficer')
  scope: dev_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsOfficerRoleDefinitionId
    principalId: deploymentPrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// 7. Azure SQL logical server and temporary developer firewall rule
// -----------------------------------------------------------------------------

resource dev_SqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: locationSqlServer
  tags: commonTags
  properties: sqlServerProperties
}

// Temporary, tightly scoped direct SQL access for the current administrator.
// This rule should be removed once private networking is implemented.
resource dev_SqlServerAllowAdministratorIp 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: dev_SqlServer
  name: 'allow-jason-current-ip'
  properties: {
    startIpAddress: administratorPublicIpAddress
    endIpAddress: administratorPublicIpAddress
  }
}

// -----------------------------------------------------------------------------
// 8. Azure SQL database
// -----------------------------------------------------------------------------

resource dev_SqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: dev_SqlServer
  name: sqlDatabaseName
  location: locationSqlServer
  tags: commonTags
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648
  }
}

// -----------------------------------------------------------------------------
// 9. SQL server administrator password secret
// -----------------------------------------------------------------------------

// Created only when updatePassword is explicitly true. The value comes from a
// secure deployment parameter and is never output by this template.
resource dev_SqlAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (updatePassword) {
  parent: dev_KeyVault
  name: 'sqlServerAdministratorPassword'
  properties: {
    value: sqlServerAdministratorPassword
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

output devResourceGroupName string = resourceGroup().name
output devResourceGroupId string = resourceGroup().id

output devAppServicePlanName string = dev_AppServicePlan.name

output devWebAppName string = dev_WebApp.name
output devWebAppUrl string = 'https://${dev_WebApp.properties.defaultHostName}'
output devWebAppPrincipalId string = dev_WebApp.identity.principalId

output devApiAppName string = dev_WebApi.name
output devApiAppUrl string = 'https://${dev_WebApi.properties.defaultHostName}'
output devApiAppPrincipalId string = dev_WebApi.identity.principalId

output devKeyVaultName string = dev_KeyVault.name
output devKeyVaultUri string = dev_KeyVault.properties.vaultUri

output devSqlServerName string = dev_SqlServer.name
output devSqlServerFqdn string = dev_SqlServer.properties.fullyQualifiedDomainName
output devSqlDatabaseName string = dev_SqlDatabase.name
