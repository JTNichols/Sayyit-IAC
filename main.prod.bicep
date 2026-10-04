// main.prod.bicep
//
// Sayyit production environment infrastructure.
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
//   - App Service plan:      sayyit-prod-asp
//   - Blazor WASM web app:   sayyit-prod-webapp
//   - ASP.NET Core API:      sayyit-prod-apiapp
//   - Key Vault:             sayyit-prod-kv
//   - Azure SQL server:      sayyit-prod-sqlserver
//   - Azure SQL database:    sayyit-prod-db
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
  'prod'
])
param env string = 'prod'

@minLength(1)
param baseName string = 'sayyit'

// Object ID of the service principal that executes the infrastructure workflow.
//
// Repository: JTNichols/Sayyit-IAC
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
// sayyit-iac-action.yml passes this from its
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

// App Service names use webapp/apiapp because old web/api names remain held by
// deleted App Service hostname reservations.
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

var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

var keyVaultSecretsOfficerRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
)

// Temporary production/bootstrap configuration. The database workflow adds a
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
// 1. Shared production App Service plan
// -----------------------------------------------------------------------------

resource prod_AppServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: locationWebApp
  kind: 'app'
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: false
  }
  tags: commonTags
}

// -----------------------------------------------------------------------------
// 2. Blazor WebAssembly web application
// -----------------------------------------------------------------------------

resource prod_WebApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: locationWebApp
  kind: 'app'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: prod_AppServicePlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      alwaysOn: true
      http20Enabled: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
    }
  }
  tags: commonTags
}

// Blazor WebAssembly is client-side. Do not add SQL credentials to this app.
resource prod_WebAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: prod_WebApp
  name: 'appsettings'
  properties: {
    ASPNETCORE_ENVIRONMENT: 'Production'
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

resource prod_WebApi 'Microsoft.Web/sites@2023-12-01' = {
  name: apiAppName
  location: locationWebApp
  kind: 'app'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: prod_AppServicePlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      alwaysOn: true
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
resource prod_WebApiSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: prod_WebApi
  name: 'appsettings'
  properties: {
    ASPNETCORE_ENVIRONMENT: 'Production'
    Sayyit__Environment: env
    Sayyit__KeyVaultUri: prod_KeyVault.properties.vaultUri
    Sayyit__SqlServerName: sqlServerName
    Sayyit__SqlDatabaseName: sqlDatabaseName
    Sayyit__SqlServerFqdn: '${sqlServerName}.database.windows.net'
    Sayyit__WebOrigin: 'https://${webAppName}.azurewebsites.net'
    AzureAd__Authority: externalIdAuthority
    AzureAd__Audience: externalIdWebClientId
    AzureAd__ValidateAuthority: 'true'
  }
}

// Explicitly allow only the production Blazor WebAssembly application to call
// the production API. Add sayyit.com/www.sayyit.com only after DNS and custom
// domain bindings have been configured.
resource prod_WebApiCors 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: prod_WebApi
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

resource prod_KeyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
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

resource prod_WebAppKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(prod_KeyVault.id, prod_WebApp.id, 'WebAppKeyVaultSecretsUser')
  scope: prod_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: prod_WebApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource prod_WebApiKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(prod_KeyVault.id, prod_WebApi.id, 'WebApiKeyVaultSecretsUser')
  scope: prod_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: prod_WebApi.identity.principalId
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
resource prod_ApplicationDeploymentPrincipalKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(
    prod_KeyVault.id,
    applicationDeploymentPrincipalObjectId,
    'ApplicationDeploymentPrincipalKeyVaultSecretsUser'
  )
  scope: prod_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: applicationDeploymentPrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

// IaC repository identity: JTNichols/Sayyit-IAC.
//
// Required when the infrastructure workflow creates or rotates
// sqlServerAdministratorPassword through this Bicep template.
resource prod_IacPrincipalKeyVaultSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(
    prod_KeyVault.id,
    deploymentPrincipalObjectId,
    'IacPrincipalKeyVaultSecretsOfficer'
  )
  scope: prod_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsOfficerRoleDefinitionId
    principalId: deploymentPrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// 7. Azure SQL logical server and administrator firewall rule
// -----------------------------------------------------------------------------

resource prod_SqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: locationSqlServer
  tags: commonTags
  properties: sqlServerProperties
}

// Temporary direct SQL access for the current administrator public IP. Remove
// this rule after private networking has been implemented.
resource prod_SqlServerAllowAdministratorIp 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: prod_SqlServer
  name: 'allow-jason-current-ip'
  properties: {
    startIpAddress: administratorPublicIpAddress
    endIpAddress: administratorPublicIpAddress
  }
}

// -----------------------------------------------------------------------------
// 8. Azure SQL database
// -----------------------------------------------------------------------------

resource prod_SqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: prod_SqlServer
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
resource prod_SqlAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (updatePassword) {
  parent: prod_KeyVault
  name: 'sqlServerAdministratorPassword'
  properties: {
    value: sqlServerAdministratorPassword
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

output prodResourceGroupName string = resourceGroup().name
output prodResourceGroupId string = resourceGroup().id

output prodAppServicePlanName string = prod_AppServicePlan.name

output prodWebAppName string = prod_WebApp.name
output prodWebAppUrl string = 'https://${prod_WebApp.properties.defaultHostName}'
output prodWebAppPrincipalId string = prod_WebApp.identity.principalId

output prodApiAppName string = prod_WebApi.name
output prodApiAppUrl string = 'https://${prod_WebApi.properties.defaultHostName}'
output prodApiAppPrincipalId string = prod_WebApi.identity.principalId

output prodKeyVaultName string = prod_KeyVault.name
output prodKeyVaultUri string = prod_KeyVault.properties.vaultUri

output prodSqlServerName string = prod_SqlServer.name
output prodSqlServerFqdn string = prod_SqlServer.properties.fullyQualifiedDomainName
output prodSqlDatabaseName string = prod_SqlDatabase.name
