# Run with: pwsh -NoProfile -File tests/Test-Permissions.ps1
# All HTTP calls are mocked; no tenant or credentials are required.
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent

function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

foreach ($file in Get-ChildItem (Join-Path $repository 'permissions') -Filter '*.ps1' -Recurse) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $errors)
    Assert-True ($errors.Count -eq 0) "Syntax errors in $($file.FullName): $errors"
}

$source = Get-Content (Join-Path $repository 'permissions/manager/importSubPermissions.ps1') -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref] $null, [ref] $null)
$todayFunction = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-Capp12Today' }, $true)
. ([scriptblock]::Create($todayFunction.Extent.Text))
foreach ($case in @(
    @{ Utc = '2026-01-01T23:30:00Z'; Expected = '2026-01-02' },
    @{ Utc = '2026-07-01T22:30:00Z'; Expected = '2026-07-02' },
    @{ Utc = '2026-03-29T00:30:00Z'; Expected = '2026-03-29' },
    @{ Utc = '2026-10-25T01:30:00Z'; Expected = '2026-10-25' }
)) {
    $utc = [datetime]::Parse($case.Utc).ToUniversalTime()
    Assert-True ((Get-Capp12Today $utc).ToString('yyyy-MM-dd') -eq $case.Expected) "Wrong CAPP date for $($case.Utc)"
}

$global:CappPermissionTestState = @{}
function Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec, $MaximumRedirection)
    if ($Uri -like '*/oauth2/token') { return @{ token_type = 'Bearer'; access_token = 'test-token' } }
    if ($Uri -like '*/users?code=*') {
        return [PSCustomObject]@{ code = '123'; active = ($global:CappPermissionTestState.Mode -ne 'inactive') }
    }
    if ($Method -eq 'POST') {
        $global:CappPermissionTestState.Writes++
        $global:CappPermissionTestState.Body = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        if ($global:CappPermissionTestState.Mode -eq 'failed-revoke') {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::UnprocessableEntity)
            $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Simulated API failure', $response)
            $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, 'CappFailure', 'InvalidOperation', $null)
            $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":"Can''t find user with code `123` or department with code `D1`."}')
            throw $errorRecord
        }
        return
    }
    if ($Uri -match '/(departments|positions)$') { return "code;title`nD1;Resource" }
    $today = Get-Capp12Today
    $csv = "user_code;department_code;position_code;ends_on`nexpired;D1;D1;$($today.AddDays(-1).ToString('yyyy-MM-dd'))"
    if ($global:CappPermissionTestState.Mode -ne 'empty') {
        $csv += "`nforever;D1;D1;`ntoday;D1;D1;$($today.ToString('yyyy-MM-dd'))`nfuture;D1;D1;$($today.AddDays(1).ToString('yyyy-MM-dd'))"
    }
    return $csv
}

foreach ($kind in 'assignment', 'employment', 'manager') {
    foreach ($mode in 'import', 'empty') {
        $global:CappPermissionTestState.Mode = $mode
        $actionContext = [PSCustomObject]@{
            Configuration = @{ BaseUrl = 'https://example.invalid'; ClientId = 'test'; ClientSecret = 'test' }
        }
        $result = @(& (Join-Path $repository "permissions/$kind/importSubPermissions.ps1"))
        if ($mode -eq 'empty') {
            Assert-True ($result.Count -eq 0) "$kind must accept an export containing only expired relationships"
        }
        else {
            $members = @($result.AccountReferences | Sort-Object)
            Assert-True (($members -join ',') -eq 'forever,future,today') "$kind must retain today and exclude yesterday"
        }
    }
}

function Invoke-PermissionChange([string] $Kind, [string] $Mode, [string] $Operation = 'revoke', [bool] $DryRun = $false) {
    $global:CappPermissionTestState.Mode = $Mode
    $global:CappPermissionTestState.Writes = 0
    $actionContext = [PSCustomObject]@{
        Configuration = @{ BaseUrl = 'https://example.invalid'; ClientId = 'test'; ClientSecret = 'test' }
        References = @{ Account = '123' }
        CurrentPermissions = @([PSCustomObject]@{ DisplayName = 'Resource'; Reference = [PSCustomObject]@{ Id = 'D1' } })
        Operation = $Operation
        DryRun = $DryRun
    }
    $personContext = [PSCustomObject]@{ Person = [PSCustomObject]@{ Contracts = @() } }
    $outputContext = [PSCustomObject]@{
        Success = $false
        AuditLogs = [System.Collections.Generic.List[object]]::new()
        SubPermissions = [System.Collections.Generic.List[object]]::new()
    }
    $WarningPreference = 'SilentlyContinue'
    & (Join-Path $repository "permissions/$Kind/subPermissions.ps1")
    return $outputContext
}

foreach ($kind in 'assignment', 'employment', 'manager') {
    $result = Invoke-PermissionChange $kind 'failed-revoke'
    Assert-True (-not $result.Success -and $result.AuditLogs.IsError -contains $true) "$kind must fail an unconfirmed revoke"
    Assert-True ($result.SubPermissions.Reference.Id -contains 'D1') "$kind must retain a failed revoke for retry"
    $result = Invoke-PermissionChange $kind 'inactive'
    Assert-True (-not $result.Success -and $global:CappPermissionTestState.Writes -eq 0) "$kind must reject writes for an inactive user"
    Assert-True ($result.SubPermissions.Reference.Id -contains 'D1') "$kind must retain permissions for an inactive user"
    $result = Invoke-PermissionChange $kind 'success'
    Assert-True ($result.Success -and $global:CappPermissionTestState.Writes -eq 1) "$kind must revoke an active user's permission"
    Assert-True ($global:CappPermissionTestState.Body.ends_on -eq (Get-Capp12Today).AddDays(-1).ToString('dd-MM-yyyy')) "$kind must use yesterday in CAPP's timezone"
    $result = Invoke-PermissionChange $kind 'success' 'revoke' $true
    Assert-True ($result.Success -and $global:CappPermissionTestState.Writes -eq 0) "$kind dry run must not write"
}
$result = Invoke-PermissionChange 'manager' 'success' 'update'
Assert-True ($result.Success -and $global:CappPermissionTestState.Writes -eq 1) 'An empty manager update must revoke the final permission'

Remove-Variable CappPermissionTestState -Scope Global
Write-Output 'Permission regression checks passed.'
