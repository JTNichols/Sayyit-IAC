param env string
param baseName string
param locationRG string = resourceGroup().location
param locationWebApp string = 'centralus'

var commonTags = {
  env: env
  project: baseName
}

var appServicePlanName = '${baseName}-${env}-asp'
var webAppName = '${baseName}-${env}-web'

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
  properties: {
    serverFarmId: appServicePlan.id
  }
  tags: commonTags
}
