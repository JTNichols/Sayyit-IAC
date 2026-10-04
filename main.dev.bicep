// main.dev.bicep
//
// Sayyit development environment infrastructure.
//
// Target workforce tenant:
//   sayyitadmin.onmicrosoft.com
//
// Target Azure subscription:
//   sayyitadmin.subscription
//   988f19e5-f513-485b-8cab-247ba99e2f67
//
// Target resource group:
//   sayyitadmin_rg1
//
// This template creates:
//   - App Service plan:      sayyit-dev-asp
//   - Blazor WASM web app:   sayyit-dev-webapp (renamed from -web b/c or soft-deleted name exists in previous tenant. may rename later)
//   - ASP.NET Core API:      sayyit-dev-apiapp (same)
//   - Key Vault:             sayyit-dev-kv
//   - Azure SQL server:      sayyit-dev-sqlserver
//   - Azure SQL database:    sayyit-dev-db
//   - Key Vault RBAC assignments
//   - Temporary SQL firewall rule for the administrator IP
//
// This template does NOT create or modify:
//   - sayyit.onmicrosoft.com External ID.
//   - sayyitusersdev.onmicrosoft.com External ID.
//   - Customer identities, user flows, or CIAM app registrations.
//
// Those remain in the External ID tenant.

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

@allowed([
  'dev'
])
param env string = 'dev'

@minLength(1)
param baseName string = 'sayyit'

// Object ID of the service principal that executes the infrastructure workflow.
//
// Repository: JTNichols/sayyit-iac
// App:        sayyit-iac-github-actions
// Current SP: 0c1ad1a3-67ac-45c5-b637-966baf0ccf26
//
// sayyit-iac-action.yml resolves this from its AZURE_CLIENT_ID at deployment.
@minLength(1)
param deploymentPrincipalObjectId string

// Object ID of the application repository service principal.
//
// Repository: JTNichols/sayyit
// App:        sayyit-github-actions
// Current SP: e0597589-1591-4a96-b1f8-94592bad44d2
//
// sayyit-iac-action.yml must pass this from its
// APPLICATION_GITHUB_OIDC_SP_ID GitHub repository secret.
//
// This identity needs Key Vault Secrets User because sayyit-db-action.yml
// reads sqlServerAdministratorPassword during DACPAC deployment.
@minLength(1)
param applicationDeploymentPrincipalObjectId string

// Used only when updatePassword is true.
@secure()
param sqlServerAdministratorPassword string = ''

// Set true only when creating or intentionally rotating the logical SQL server
// administrator password.
param updatePassword bool = false

// Retained for workflow compatibility. It must remain false because External ID
// is deliberately separate from this workforce subscription.
param modifyExternalIdTenant bool = false

// Intended Azure resource locations.
param locationWebApp string = 'centralus'
param locationSqlServer string = 'centralus'
param locationKeyVault string = resourceGroup().location

// Temporary, tightly scoped developer SQL access. Remove after private
// networking and a private-capable deployment path are established.
param administratorPublicIpAddress string = '174.104.161.188'

// Existing SQL administrator login name. Its password is stored in Key Vault.
param sqlServerAdminLoginName string = 'sqladminuser'

// Existing, preserved customer-facing External ID configuration.
param externalIdAuthority string = 'https://sayyit.ciamlogin.com'
param externalIdWebClientId string = '0becd0dd-685a-4825-98c1-5ce259fd0ff8'

// -----------------------------------------------------------------------------
// Variables
// -----------------------------------------------------------------------------

var appServicePlanName = '${baseName}-${env}-asp'
var webAppName = '${baseName}-${env}-webapp'
var apiAppName = '${baseName}-${env}-apiapp'
var keyVaultName = '${baseName}-${env}-kv'
var sqlServerName = '${baseName}-${env}-sqlserver'
var sqlDatabaseName = '${baseName}-${env}-db'

var commonTags = {
  project: baseName
  environment: env
  managedBy: 'Bicep'
  tenant: 'sayyitadmin.onmicrosoft.com'
}

// Built-in Key Vault RBAC role IDs.
//
// Key Vault Secrets User:
//   Reads secret values.
//
// Key Vault Secrets Officer:
//   Creates, updates, deletes, and manages secret values.
//   It does not grant Key Vault management-plane access.
var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

var keyVaultSecretsOfficerRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
)

// Temporary development/bootstrap configuration. The database workflow adds a
// short-lived GitHub-hosted runner firewall rule and restores the original
// public-network setting after deployment.
var sqlServerProperties = union({
  administratorLogin: sqlServerAdminLoginName
  version: '12.0'
  minimumTlsVersion: '1.2'
  publicNetworkAccess: 'Enabled'
}, updatePassword ? {
  administratorLoginPassword: sqlServerAdministratorPassword
} : {})

// -----------------------------------------------------------------------------
// 1. Shared development App Service plan
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

// Blazor WebAssembly is client-side. Do not add SQL credentials to this app.
resource dev_WebAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: dev_WebApp
  name: 'appsettings'
  properties: {
    ASPNETCORE_ENVIRONMENT: 'Development'
    Sayyit__Environment: env
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
    }
  }
  tags: commonTags
}

// No SQL password is stored in App Service configuration. The API should use
// its system-assigned managed identity to retrieve a connection secret from
// Key Vault, or later use passwordless Azure SQL authentication.
resource dev_WebApiSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: dev_WebApi
  name: 'appsettings'
  properties: {
    ASPNETCORE_ENVIRONMENT: 'Development'
    Sayyit__Environment: env
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

// Explicitly allow only the dev Blazor WebAssembly application to call the API.
// Add a custom-domain origin only after it exists and has been verified.
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
    // Resolves to sayyitadmin.onmicrosoft.com because the deployment targets
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

    // Temporary bootstrap setting. Harden after private network access for
    // deployments has been designed and tested.
    publicNetworkAccess: 'Enabled'

    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// -----------------------------------------------------------------------------
// 5. Key Vault RBAC for application managed identities
// -----------------------------------------------------------------------------

resource dev_WebAppKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dev_KeyVault.id, dev_WebApp.id, 'WebAppKeyVaultSecretsUser')
  scope: dev_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: dev_WebApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource dev_WebApiKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dev_KeyVault.id, dev_WebApi.id, 'WebApiKeyVaultSecretsUser')
  scope: dev_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: dev_WebApi.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// 6. Key Vault RBAC for GitHub Actions deployment identities
// -----------------------------------------------------------------------------

// Application repository identity: JTNichols/sayyit.
//
// Required because sayyit-db-action.yml retrieves:
//   sqlServerAdministratorPassword
//
// from the vault before using SqlPackage to deploy the DACPAC.
resource dev_ApplicationDeploymentPrincipalKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(
    dev_KeyVault.id,
    applicationDeploymentPrincipalObjectId,
    'ApplicationDeploymentPrincipalKeyVaultSecretsUser'
  )
  scope: dev_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: applicationDeploymentPrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

// IaC repository identity: JTNichols/sayyit-iac.
//
// Required when the infrastructure workflow creates or rotates
// sqlServerAdministratorPassword through this Bicep template.
resource dev_IacPrincipalKeyVaultSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(
    dev_KeyVault.id,
    deploymentPrincipalObjectId,
    'IacPrincipalKeyVaultSecretsOfficer'
  )
  scope: dev_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsOfficerRoleDefinitionId
    principalId: deploymentPrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// 7. Azure SQL logical server and administrator firewall rule
// -----------------------------------------------------------------------------

resource dev_SqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: locationSqlServer
  tags: commonTags
  properties: sqlServerProperties
}

// Temporary direct SQL access for the current administrator public IP. Remove
// this rule after private networking has been implemented.
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
// 9. SQL administrator password secret
// -----------------------------------------------------------------------------

// This resource is created only when updatePassword=true. The value comes from
// the secure deployment parameter and is never returned as a Bicep output.
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
