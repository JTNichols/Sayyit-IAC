// Bicep template for Azure IAC.
// Deployed to azure and run by gh action sayyit-iac-action.yml
// All params are passed in from that file, no separate param file is used. 
// The gh action also sets the deployment principal object id and, optionally, a new sql server admin password

// This script does not create the following, which must already exist in the Azure subscription:
// 1. The Azure subscription and related owner account.
// 2. The resource group sayyit_rg1, required by the github action that runs this bicep file.
// 3. The EntraID External ID tenant, which contains #4, a Github OIDC federated identity
// 4. The GitHub Actions OIDC federated identity must already exist for the repo/branch combination. It's created
//      by the script CreateEntraApp-ServPrinc-GhFedCred.ps1. That script creates an app registration and service
//      principal in the Azure ExternalId tenant, which is passed into this bicep file as a parameter.


// This script creates:
// 1. App Service Plans "sayyit-{env}-asp"

// Notes:
// The web app is assigned a system managed identity and granted access to the key vault secrets. 
// The SQL server administrator password is stored in the key vault as a secret.


extension graphV1

// -----------------------------------------
// Parameter configuration
// -----------------------------------------
param env string
param baseName string  
param deploymentPrincipalObjectId string
@secure() 
param sqlServerAdministratorPassword string = ''
param updatePassword bool = false

// If true, GH Service Principal needs higher level directory permissions
param modifyExternalIdTenant bool = false

param externalIdDataLocation string = 'United States'
// CIAM tenant creation currently accepts Base/A0 for this RP operation.
@allowed([
  'Base'
])
param externalIdSkuName string = 'Base'

// Optional params
param locationRG string = resourceGroup().location
param locationWebApp string = 'centralus'
param locationSqlServer string = 'centralus'
param sqlServerAdminLoginName string = 'sqladminuser'
 
var commonTags = {
  env: env
  project: baseName
}

// -----------------------------------------
// Variable configuration
// ----------------------------------------- 
var sqlServerName = '${baseName}-${env}-sqlserver'
var sqlDatabaseName = '${baseName}-${env}-db'
var externalWebAppRegistrationName = 'sayyit-web-${env}'
var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    '4633458b-17de-408a-b874-0445c86b69e6'
    )
var keyVaultSecretsOfficerRoleDefinitionId = subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
    )
var sqlServerProperties = union({
  administratorLogin: sqlServerAdminLoginName
  version: '12.0'
  minimumTlsVersion: '1.2'
  publicNetworkAccess: 'Disabled'
}, updatePassword ? {
  administratorLoginPassword: sqlServerAdministratorPassword
} : {})


// 1a. DEV: App Service Plan "sayyit-dev-asp"
resource dev_AppServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: 'sayyit-dev-asp'
  location: locationWebApp
  sku: {
    name: 'F1'
    tier: 'Free'
  }
  tags: commonTags
}
// 1b. PROD: App Service Plan "sayyit-prod-asp"
resource prod_AppServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: 'sayyit-prod-asp'
  location: locationWebApp
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  tags: commonTags
}
// 2. DEV: Web App
resource dev_WebApp 'Microsoft.Web/sites@2023-12-01' = {
  name: 'sayyit-dev-web'
  location: locationWebApp
  identity: {
      type: 'SystemAssigned'
   }
       properties: {
         serverFarmId: dev_AppServicePlan.id
       }
       tags: commonTags
}
    
// 3. DEV: Key Vault
resource dev_KeyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'sayyit-dev-kv'
  location: locationRG
  tags: commonTags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 30
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}
    
// 4. DEV: Allow the Web App managed identity to read secret values
resource dev_WebAppKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dev_KeyVault.id, dev_WebApp.id, 'KeyVaultSecretsUser')
  scope: dev_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: dev_WebApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
// 5. DEV: Allow the GitHub deployment identity to create/update secrets in the vault
resource dev_GhDeployPrincipalSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dev_KeyVault.id, deploymentPrincipalObjectId, 'KeyVaultSecretsOfficer')
  scope: dev_KeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsOfficerRoleDefinitionId
    principalId: deploymentPrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}
// 6. DEV: SQL Server
resource dev_SqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: locationSqlServer
  tags: commonTags
  properties: sqlServerProperties
}
// 7. DEV: SQL Database
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
// 8. DEV: SQL Server administrator password
resource dev_SqlAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (updatePassword && env == 'dev') {
  parent: dev_KeyVault
  name: 'sqlServerAdministratorPassword'
  properties: {
    value: sqlServerAdministratorPassword
  }
} 
// 9. ALL environments: Entra External ID tenant for public sign-up/sign-in.
resource externalIdTenant 'Microsoft.AzureActiveDirectory/ciamDirectories@2023-05-17-preview' = if (modifyExternalIdTenant) {
  name: 'sayyit.onmicrosoft.com'
  location: externalIdDataLocation
  tags: commonTags
  sku: {
    name: externalIdSkuName
    tier: 'A0'
  }
  properties: {
    createTenantProperties: {
      displayName: 'sayyit'
      countryCode: 'US'
    }
  }
}

// 10. DEV: sayyit-dev-web web app's registration in the external ID tenant
resource dev_ExternalWebAppRegistration 'Microsoft.Graph/applications@v1.0' = if (modifyExternalIdTenant && env == 'dev'){
  uniqueName: externalWebAppRegistrationName
  displayName: externalWebAppRegistrationName
  signInAudience: 'AzureADandPersonalMicrosoftAccount'
}
    
output devKeyVaultName string = dev_KeyVault.name
output devKeyVaultUri string = dev_KeyVault.properties.vaultUri
output devWebAppPrincipalId string = dev_WebApp.identity.principalId
