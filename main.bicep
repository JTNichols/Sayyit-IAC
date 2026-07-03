// Required params
param env string
param baseName string 
param deploymentPrincipalObjectId string
@secure() 
param sqlServerAdministratorPassword string 
param updatePassword bool 
// Optional params
param locationRG string = resourceGroup().location
param locationWebApp string = 'centralus'
param sqlServerAdminLoginName string = 'sqladminuser'


var commonTags = {
  env: env
  project: baseName
}

var appServicePlanName = '${baseName}-${env}-asp'
var webAppName = '${baseName}-${env}-web'
var keyVaultName = '${baseName}-${env}-kv'
var sqlServerName = '${baseName}-${env}-sql'
var sqlDatabaseName = '${baseName}-${env}-db'
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
  publicNetworkAccess: 'Enabled'
}, updatePassword ? {
  administratorLoginPassword: sqlServerAdministratorPassword
} : {})
// App Service Plan "sayyit-{env}-asp"
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: locationWebApp
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  tags: commonTags
}

// Web App "sayyit-{env}-web"
resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: locationWebApp
  identity: {
      type: 'SystemAssigned'
    }
       properties: {
         serverFarmId: appServicePlan.id
       }
       tags: commonTags
     }
    
    // Key Vault "sayyit-{env}-kv"
    resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
      name: keyVaultName
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
        publicNetworkAccess: 'Enabled'
        networkAcls: {
          defaultAction: 'Allow'
          bypass: 'AzureServices'
        }
      }
    }
    
    // Allow the Web App managed identity to read secret values
    resource webAppKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
      name: guid(keyVault.id, webApp.id, 'KeyVaultSecretsUser')
      scope: keyVault
      properties: {
        roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
        principalId: webApp.identity.principalId
        principalType: 'ServicePrincipal'
      }
    }
    
    // Allow the GitHub deployment identity to create/update secrets in the vault
    resource deploymentPrincipalSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
      name: guid(keyVault.id, deploymentPrincipalObjectId, 'KeyVaultSecretsOfficer')
      scope: keyVault
      properties: {
        roleDefinitionId: keyVaultSecretsOfficerRoleDefinitionId
        principalId: deploymentPrincipalObjectId
        principalType: 'ServicePrincipal'
      }
    }

    resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
      name: sqlServerName
      location: locationRG
      tags: commonTags
      properties: sqlServerProperties
    }

    resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
      parent: sqlServer
      name: sqlDatabaseName
      location: locationRG
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

    resource sqlAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (updatePassword) {
      parent: keyVault
      name: 'sqlServerAdministratorPassword'
      properties: {
        value: sqlServerAdministratorPassword
      }
    }
    
    output keyVaultName string = keyVault.name
    output keyVaultUri string = keyVault.properties.vaultUri
    output webAppPrincipalId string = webApp.identity.principalId
