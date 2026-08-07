// Bicep template to deploy a web app, key vault, and SQL server with database. 
// The web app is assigned a system managed identity and granted access to the key vault secrets. 
// The SQL server administrator password is stored in the key vault as a secret.
// This bicep file executes via GitHub Action.

extension graphV1

// Required params
param env string
param baseName string 
param deploymentPrincipalObjectId string
@secure() 
param sqlServerAdministratorPassword string = ''
param updatePassword bool = false

// External ID (Entra External ID for customers) params
// Must be explicitly enabled by a privileged principal; default false keeps CI idempotent and non-privileged.
param deployExternalIdTenant bool = false
// Must be explicitly enabled and requires directory permissions in the external tenant.
param deployExternalAppRegistration bool = false
@minLength(1)
@maxLength(10)
param externalIdTenantName string = 'sayyit'
@allowed([
  'onmicrosoft.com'
])
param externalIdTenantDomainSuffix string = 'onmicrosoft.com'
param externalIdTenantDisplayName string = 'sayyit-external-id'
@minLength(2)
@maxLength(2)
param externalIdCountryCode string = 'US'
@allowed([
  'United States'
  'Europe'
  'Asia Pacific'
  'Australia'
])
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

// Variable declarations
var appServicePlanName = '${baseName}-${env}-asp'
var webAppName = '${baseName}-${env}-web'
var keyVaultName = '${baseName}-${env}-kv'
var sqlServerName = '${baseName}-${env}-sqlserver'
var sqlDatabaseName = '${baseName}-${env}-db'
var externalIdTenantDomainName = '${externalIdTenantName}.${externalIdTenantDomainSuffix}'
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
    // Runs each time, idempotent if environment variables are the same.
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
// SQL Server "sayyit-{env}-sqlserver" and Database
    resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
      name: sqlServerName
      location: locationSqlServer
      tags: commonTags
      properties: sqlServerProperties
    }

    resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
      parent: sqlServer
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

    resource sqlAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (updatePassword) {
      parent: keyVault
      name: 'sqlServerAdministratorPassword'
      properties: {
        value: sqlServerAdministratorPassword
      }
    }

    // Entra External ID tenant for public sign-up/sign-in.
    // Idempotency: this is keyed by externalIdTenantName, so repeat deployments reconcile the same tenant resource.
    resource externalIdTenant 'Microsoft.AzureActiveDirectory/ciamDirectories@2023-05-17-preview' = if (deployExternalIdTenant) {
      name: externalIdTenantDomainName
      location: externalIdDataLocation
      tags: commonTags
      sku: {
        name: externalIdSkuName
        tier: 'A0'
      }
      properties: {
        createTenantProperties: {
          displayName: externalIdTenantDisplayName
          countryCode: externalIdCountryCode
        }
      }
    }

    // App registration for sayyit.web in the tenant context used for this deployment.
    resource externalWebAppRegistration 'Microsoft.Graph/applications@v1.0' = if (deployExternalAppRegistration) {
      uniqueName: externalWebAppRegistrationName
      displayName: externalWebAppRegistrationName
      signInAudience: 'AzureADandPersonalMicrosoftAccount'
    }
    
    output keyVaultName string = keyVault.name
    output keyVaultUri string = keyVault.properties.vaultUri
    output webAppPrincipalId string = webApp.identity.principalId  
