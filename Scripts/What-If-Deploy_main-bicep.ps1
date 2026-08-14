# This script performs a "what-if" deployment of the main.bicep template to an Azure resource group.

# .\What-If-Deploy_main-bicep.ps1 -SubscriptionId "<subscription-guid>" -AzureClientId "<app-client-id>" -EnvironmentName dev
# app-client-id is the client id for sayyit-iac-github-actions app registered in EntraID
# subscription id is for the sayyit subscription


param(
	[Parameter(Mandatory = $true)]
	[string]$SubscriptionId,

	[Parameter(Mandatory = $true)]
	[string]$AzureClientId,

	[Parameter(Mandatory = $false)]
	[ValidateSet('dev', 'prod')]
	[string]$EnvironmentName = 'dev',

	[Parameter(Mandatory = $false)]
	[string]$ResourceGroupName = 'sayyit_rg1',

	[Parameter(Mandatory = $false)]
	[string]$BaseName = 'sayyit',

	[Parameter(Mandatory = $false)]
	[bool]$ModifyExternalIdTenant = $false,

	[Parameter(Mandatory = $false)]
	[bool]$UpdatePassword = $false,

	[Parameter(Mandatory = $false)]
	[string]$SqlServerAdministratorPassword = ''
)

$ErrorActionPreference = 'Stop'

# Resolve main.bicep relative to this script, regardless of current working directory.
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$TemplateFile = Join-Path -Path (Split-Path -Path $ScriptDir -Parent) -ChildPath 'main.bicep'

if (-not (Test-Path -Path $TemplateFile)) {
	throw "Could not find template file at '$TemplateFile'."
}

Write-Host "Using template:      $TemplateFile"
Write-Host "Using subscription:  $SubscriptionId"
Write-Host "Using resource group:$ResourceGroupName"
Write-Host "Using env:           $EnvironmentName"

# Set deployment context.
az account set --subscription $SubscriptionId | Out-Null

# Resolve service principal object ID from the provided app/client ID.
$DeploymentPrincipalObjectId = az ad sp show `
	--id $AzureClientId `
	--query id -o tsv

if (-not $DeploymentPrincipalObjectId) {
	throw "Unable to resolve service principal object ID for AzureClientId '$AzureClientId'."
}

Write-Host "Resolved deployment principal object ID: $DeploymentPrincipalObjectId"

$WhatIfArgs = @(
	'deployment', 'group', 'what-if',
	'--resource-group', $ResourceGroupName,
	'--template-file', $TemplateFile,
	'--parameters',
	"env=$EnvironmentName",
	"baseName=$BaseName",
	"deploymentPrincipalObjectId=$DeploymentPrincipalObjectId",
	"modifyExternalIdTenant=$ModifyExternalIdTenant",
	"updatePassword=$UpdatePassword",
	"sqlServerAdministratorPassword=$SqlServerAdministratorPassword"
)

Write-Host "Running what-if deployment..."
az @WhatIfArgs

if ($LASTEXITCODE -ne 0) {
	throw "What-if deployment failed with exit code $LASTEXITCODE."
}

Write-Host "What-if deployment completed successfully."
