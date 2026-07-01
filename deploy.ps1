param(
  [string]$Environment = "dev",
  [string]$ResourceGroupName = "sayyit_rg1",
  [string]$LocationWebApp = "centralus"
)

$paramFile = ".\parameters.$Environment.bicepparam"
$deploymentName = "main-$Environment"

az deployment group create `
  --resource-group $ResourceGroupName `
  --template-file .\main.bicep `
  --parameters $paramFile
  locationWebApp = $LocationWebApp