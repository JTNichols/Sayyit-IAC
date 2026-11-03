#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'prod')]
    [string]$Environment,
    # Optional override for networks where automatic IP detection is unsuitable.
    [string]$ExecutionPublicIpAddress = ''
)

Set-StrictMode -Version Latest

$Environment = $Environment.ToLowerInvariant()
$SqlAdminUsername = 'sqladminuser'
$ResourceGroupName = 'sayyitadmin_rg1'
$ExpectedTenantId = '1fb200ff-be89-44fe-881e-0042193701df'
$ErrorActionPreference = 'Stop'
$SubscriptionId = '988f19e5-f513-485b-8cab-247ba99e2f67'
$ApiAppName = "sayyit-$Environment-apiapp"
$SqlServerName = "sayyit-$Environment-sqlserver"
$DatabaseName = "sayyit-$Environment-db"
$KeyVaultName = "sayyit-$Environment-kv"
$PasswordSecretName = 'sqlServerAdministratorPassword'
$RuntimeRoleName = 'sayyit_api_runtime'

function Invoke-Az {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')`n$($result | Out-String)"
    }

    return ($result | Out-String).Trim()
}

function Get-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $text = Invoke-Az -Arguments ($Arguments + @('--output', 'json', '--only-show-errors'))
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'Azure CLI returned an empty JSON response.'
    }

    return $text | ConvertFrom-Json
}

function ConvertTo-SqlLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return $Value.Replace("'", "''")
}

function Get-PublicIPv4Address {
    [CmdletBinding()]
    param(
        [int]$MaxAttempts = 3,
        [int]$TimeoutSeconds = 15
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Invoke-RestMethod `
                -Uri 'https://api.ipify.org' `
                -TimeoutSec $TimeoutSeconds `
                -ErrorAction Stop
        }
        catch [System.Net.WebException] {
            Write-Warning "Public IP lookup attempt $attempt/$MaxAttempts failed (network error): $($_.Exception.Message)"
            if ($attempt -eq $MaxAttempts) {
                throw "Could not determine the public IP address after $MaxAttempts attempts: $($_.Exception.Message)"
            }

            Start-Sleep -Seconds ([math]::Pow(2, $attempt - 1) * 2)
            continue
        }
        catch [System.Net.Http.HttpRequestException] {
            Write-Warning "Public IP lookup attempt $attempt/$MaxAttempts failed (HTTP request error): $($_.Exception.Message)"
            if ($attempt -eq $MaxAttempts) {
                throw "Could not determine the public IP address after $MaxAttempts attempts: $($_.Exception.Message)"
            }

            Start-Sleep -Seconds ([math]::Pow(2, $attempt - 1) * 2)
            continue
        }
        catch [System.TimeoutException] {
            Write-Warning "Public IP lookup attempt $attempt/$MaxAttempts failed (timeout): $($_.Exception.Message)"
            if ($attempt -eq $MaxAttempts) {
                throw "Could not determine the public IP address after $MaxAttempts attempts: $($_.Exception.Message)"
            }

            Start-Sleep -Seconds ([math]::Pow(2, $attempt - 1) * 2)
            continue
        }
        catch [System.Threading.Tasks.TaskCanceledException] {
            Write-Warning "Public IP lookup attempt $attempt/$MaxAttempts failed (request canceled or timed out): $($_.Exception.Message)"
            if ($attempt -eq $MaxAttempts) {
                throw "Could not determine the public IP address after $MaxAttempts attempts: $($_.Exception.Message)"
            }

            Start-Sleep -Seconds ([math]::Pow(2, $attempt - 1) * 2)
            continue
        }

        $addressText = if ($null -eq $response) { '' } else { $response.ToString().Trim() }
        $parsedAddress = $null
        if (
            [string]::IsNullOrWhiteSpace($addressText) -or
            -not [System.Net.IPAddress]::TryParse($addressText, [ref]$parsedAddress) -or
            $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork
        ) {
            throw "Public IP service returned an invalid IPv4 address: '$addressText'."
        }

        return $parsedAddress.ToString()
    }

    throw 'Could not determine the public IP address.'
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required.'
}

Import-Module SqlServer -ErrorAction Stop

foreach ($name in @($ApiAppName, $RuntimeRoleName)) {
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 128) {
        throw 'SQL principal names must contain between 1 and 128 characters.'
    }
}

$null = Invoke-Az -Arguments @('account', 'set', '--subscription', $SubscriptionId)
$context = Get-AzJson -Arguments @('account', 'show')

if ($context.id -ne $SubscriptionId -or $context.tenantId -ne $ExpectedTenantId) {
    throw 'Azure CLI is not using the expected workforce tenant and subscription.'
}

$identity = Get-AzJson -Arguments @(
    'webapp', 'identity', 'show',
    '--resource-group', $ResourceGroupName,
    '--name', $ApiAppName
)

if ($identity.type -notlike '*SystemAssigned*' -or -not $identity.principalId) {
    throw "System-assigned managed identity is not enabled on '$ApiAppName'."
}

if ($identity.tenantId -ne $ExpectedTenantId) {
    throw 'The API managed identity belongs to an unexpected tenant.'
}

$principalId = [guid]$identity.principalId

$servicePrincipal = Get-AzJson -Arguments @(
    'ad', 'sp', 'show',
    '--id', $principalId.ToString()
)

if ([guid]$servicePrincipal.id -ne $principalId) {
    throw 'Resolved service principal does not match the API identity.'
}

if ($servicePrincipal.servicePrincipalType -ne 'ManagedIdentity') {
    throw 'Resolved service principal is not a managed identity.'
}

$clientId = [guid]$servicePrincipal.appId

$server = Get-AzJson -Arguments @(
    'sql', 'server', 'show',
    '--resource-group', $ResourceGroupName,
    '--name', $SqlServerName
)

if ($server.publicNetworkAccess -ne 'Enabled') {
    throw 'SQL public network access must already be Enabled for this provisioning path.'
}

if ([string]::IsNullOrWhiteSpace($ExecutionPublicIpAddress)) {
    $ExecutionPublicIpAddress = Get-PublicIPv4Address
}

$parsedIp = [System.Net.IPAddress]::Parse($ExecutionPublicIpAddress)
if ($parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'An IPv4 execution address is required.'
}

$ExecutionPublicIpAddress = $parsedIp.ToString()
$ruleName = "sql-access-bootstrap-$([guid]::NewGuid().ToString('N'))"
$sqlRuleAdded = $false
$vaultRuleAdded = $false
$password = $null
$builder = $null
$failure = $null

$vault = Get-AzJson -Arguments @(
    'keyvault', 'show',
    '--resource-group', $ResourceGroupName,
    '--name', $KeyVaultName
)

$existingVaultIps = @()
$networkAclsProperty = $vault.properties.PSObject.Properties['networkAcls']
if ($null -ne $networkAclsProperty -and $null -ne $networkAclsProperty.Value) {
    $ipRulesProperty = $networkAclsProperty.Value.PSObject.Properties['ipRules']
    if ($null -ne $ipRulesProperty -and $null -ne $ipRulesProperty.Value) {
        $existingVaultIps = @(
            $ipRulesProperty.Value |
                ForEach-Object { $_.value }
        )
    }
}

$vaultAlreadyAllowsExactIp =
    ($existingVaultIps -contains $ExecutionPublicIpAddress) -or
    ($existingVaultIps -contains "$ExecutionPublicIpAddress/32")

try {
    $null = Invoke-Az -Arguments @(
        'sql', 'server', 'firewall-rule', 'create',
        '--resource-group', $ResourceGroupName,
        '--server', $SqlServerName,
        '--name', $ruleName,
        '--start-ip-address', $ExecutionPublicIpAddress,
        '--end-ip-address', $ExecutionPublicIpAddress
    )
    $sqlRuleAdded = $true

    if (-not $vaultAlreadyAllowsExactIp) {
        $null = Invoke-Az -Arguments @(
            'keyvault', 'network-rule', 'add',
            '--resource-group', $ResourceGroupName,
            '--name', $KeyVaultName,
            '--ip-address', "$ExecutionPublicIpAddress/32"
        )
        $vaultRuleAdded = $true
    }

    # Allow time for network-rule propagation.
    Start-Sleep -Seconds 30

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $password = Invoke-Az -Arguments @(
                'keyvault', 'secret', 'show',
                '--vault-name', $KeyVaultName,
                '--name', $PasswordSecretName,
                '--query', 'value',
                '--output', 'tsv',
                '--only-show-errors'
            )
            break
        }
        catch {
            if ($attempt -eq 6) { throw }
            Start-Sleep -Seconds 10
        }
    }

    if ([string]::IsNullOrWhiteSpace($password)) {
        throw 'Key Vault returned an empty SQL administrator password.'
    }

    if ($env:GITHUB_ACTIONS -eq 'true') {
        $masked = $password.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
        Write-Output "::add-mask::$masked"
    }

    $builder = [System.Data.Common.DbConnectionStringBuilder]::new()
    $builder['Data Source'] = "tcp:$SqlServerName.database.windows.net,1433"
    $builder['Initial Catalog'] = $DatabaseName
    $builder['User ID'] = $SqlAdminUsername
    $builder['Password'] = $password
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $false
    $builder['Connect Timeout'] = 30

    $userLiteral = ConvertTo-SqlLiteral $ApiAppName
    $roleLiteral = ConvertTo-SqlLiteral $RuntimeRoleName

    $query = @"
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @userName sysname = N'$userLiteral';
DECLARE @roleName sysname = N'$roleLiteral';
DECLARE @clientId uniqueidentifier = '$clientId';
DECLARE @expectedSid varbinary(16) = CONVERT(varbinary(16), @clientId);
DECLARE @sidText varchar(34) = CONVERT(varchar(34), @expectedSid, 1);
DECLARE @sql nvarchar(max);

IF OBJECT_ID(N'auth.Users', N'U') IS NULL
    THROW 51000, 'auth.Users does not exist. Deploy the database schema first.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    IF EXISTS (
        SELECT 1
        FROM sys.database_principals
        WHERE name = @userName
          AND (type <> 'E' OR sid <> @expectedSid)
    )
        THROW 51001, 'Existing API database user has a different type or SID. No automatic replacement was performed.', 1;

    IF EXISTS (
        SELECT 1
        FROM sys.database_principals
        WHERE sid = @expectedSid AND name <> @userName
    )
        THROW 51002, 'The identity already exists under a different database user name.', 1;

    IF DATABASE_PRINCIPAL_ID(@userName) IS NULL
    BEGIN
        SET @sql = N'CREATE USER ' + QUOTENAME(@userName)
                 + N' WITH SID = ' + @sidText + N', TYPE = E;';
        EXEC sys.sp_executesql @sql;
    END;

    IF EXISTS (
        SELECT 1
        FROM sys.database_principals
        WHERE name = @roleName AND type <> 'R'
    )
        THROW 51003, 'The requested runtime role name is occupied by a non-role principal.', 1;

    IF DATABASE_PRINCIPAL_ID(@roleName) IS NULL
    BEGIN
        SET @sql = N'CREATE ROLE ' + QUOTENAME(@roleName)
                 + N' AUTHORIZATION [dbo];';
        EXEC sys.sp_executesql @sql;
    END;

    SET @sql = N'GRANT CONNECT TO ' + QUOTENAME(@userName) + N';'
             + N'GRANT SELECT, INSERT, UPDATE ON OBJECT::[auth].[Users] TO '
             + QUOTENAME(@roleName) + N';';
    EXEC sys.sp_executesql @sql;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.database_role_members
        WHERE role_principal_id = DATABASE_PRINCIPAL_ID(@roleName)
          AND member_principal_id = DATABASE_PRINCIPAL_ID(@userName)
    )
    BEGIN
        SET @sql = N'ALTER ROLE ' + QUOTENAME(@roleName)
                 + N' ADD MEMBER ' + QUOTENAME(@userName) + N';';
        EXEC sys.sp_executesql @sql;
    END;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

SELECT
    DB_NAME() AS DatabaseName,
    name AS DatabaseUser,
    type_desc AS PrincipalType,
    CONVERT(uniqueidentifier, CONVERT(binary(16), sid)) AS MappedClientId
FROM sys.database_principals
WHERE name = @userName;
"@

    $null = Invoke-Sqlcmd -ConnectionString $builder.ConnectionString -Query 'SELECT 1 AS ConnectionCheck;' -AbortOnError -DisableVariables -DisableCommands -ErrorAction Stop
    $result = Invoke-Sqlcmd -ConnectionString $builder.ConnectionString -Query $query -QueryTimeout 120 -AbortOnError -DisableVariables -DisableCommands -ErrorAction Stop
    $result | Format-Table -AutoSize | Out-Host

    Write-Host "Provisioned '$ApiAppName' with role '$RuntimeRoleName' in '$DatabaseName'."
    Write-Host "API object ID: $principalId"
    Write-Host "API client ID: $clientId"
}
catch {
    $failure = $_
}
finally {
    $password = $null
    if ($null -ne $builder) { $builder.Clear() }

    if ($sqlRuleAdded) {
        try {
            $null = Invoke-Az -Arguments @(
                'sql', 'server', 'firewall-rule', 'delete',
                '--resource-group', $ResourceGroupName,
                '--server', $SqlServerName,
                '--name', $ruleName
            )
        }
        catch {
            Write-Warning "Could not remove temporary SQL rule '$ruleName'."
            if ($null -eq $failure) { $failure = $_ }
        }
    }

    if ($vaultRuleAdded) {
        try {
            $null = Invoke-Az -Arguments @(
                'keyvault', 'network-rule', 'remove',
                '--resource-group', $ResourceGroupName,
                '--name', $KeyVaultName,
                '--ip-address', "$ExecutionPublicIpAddress/32"
            )
        }
        catch {
            Write-Warning "Could not remove temporary Key Vault rule for '$ExecutionPublicIpAddress/32'."
            if ($null -eq $failure) { $failure = $_ }
        }
    }
}

if ($null -ne $failure) {
    throw $failure
}