# Run with: pwsh -NoProfile -File tests/Test-AccountLifecycle.ps1
# API calls are mocked; no HelloID tenant or CAPP credentials are used.
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent

function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Method, $Headers, $Body, $ContentType)

    if ($Uri -like '*/oauth2/token') {
        return @{ token_type = 'Bearer'; access_token = 'test-token' }
    }
    if ($Method -eq 'GET') {
        if ($global:CappTestLookupStatus -eq 0) {
            throw [System.Net.WebException]::new('Simulated connection failure')
        }
        if ($global:CappTestLookupStatus -ne 200) {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode] $global:CappTestLookupStatus)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Simulated API failure', $response)
        }
        return [PSCustomObject]@{
            code = '123'; first_name = 'Test'; last_name = 'Person'
            email = 'test@example.com'; active = $true; ends_on = $null
        }
    }
    $global:CappTestWrites.Add(([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json))
}

function Invoke-Lifecycle([string] $Name, [int] $Status, [bool] $DryRun = $false) {
    $global:CappTestLookupStatus = $Status
    $global:CappTestWrites = [System.Collections.Generic.List[object]]::new()
    $actionContext = [PSCustomObject]@{
        Configuration = @{ BaseUrl = 'https://example.invalid'; ClientId = 'test'; ClientSecret = 'test' }
        References = @{ Account = '123' }
        CorrelationConfiguration = @{ Enabled = $true; AccountField = 'code'; PersonFieldValue = '123' }
        Data = [PSCustomObject]@{
            code = '123'; first_name = 'Test'; last_name = 'Person'
            email = 'test@example.com'; adfs_login = 'new-login@example.com'
        }
        DryRun = $DryRun
        Origin = 'enforcement'
    }
    $outputContext = [PSCustomObject]@{
        Success = $false; AccountReference = $null; AccountCorrelated = $false
        Data = $null; PreviousData = $null
        AuditLogs = [System.Collections.Generic.List[object]]::new()
    }
    $WarningPreference = 'SilentlyContinue'
    & (Join-Path $repository "$Name.ps1")
    return $outputContext
}

foreach ($file in Get-ChildItem $repository -Filter '*.ps1' -Recurse) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "Syntax errors in $($file.Name): $parseErrors"
}

foreach ($name in 'create', 'update', 'delete') {
    foreach ($status in 0, 401, 403, 429, 500) {
        $result = Invoke-Lifecycle $name $status
        Assert-True (-not $result.Success) "$name must fail when lookup returns $status"
        Assert-True ($result.AuditLogs.IsError -contains $true) "$name must report lookup error $status"
        Assert-True ($global:CappTestWrites.Count -eq 0) "$name must not write after lookup failure $status"
    }
}

$result = Invoke-Lifecycle 'create' 404
Assert-True ($result.Success -and $global:CappTestWrites.Count -eq 1) 'Create must create a missing account'
$result = Invoke-Lifecycle 'create' 200
Assert-True ($result.Success -and $result.AccountCorrelated -and $global:CappTestWrites.Count -eq 0) 'Create must correlate an existing account'
$result = Invoke-Lifecycle 'delete' 404
Assert-True ($result.Success -and $global:CappTestWrites.Count -eq 0) 'Delete must accept an already missing account'
$result = Invoke-Lifecycle 'update' 404
Assert-True (-not $result.Success -and $global:CappTestWrites.Count -eq 0) 'Update must report a missing account'
$result = Invoke-Lifecycle 'update' 200
Assert-True ($result.Success -and $global:CappTestWrites.Count -eq 1) 'A login-only update must write the mapped login'
Assert-True ($global:CappTestWrites[0].adfs_login -eq 'new-login@example.com') 'The update must contain the mapped login'
$result = Invoke-Lifecycle 'update' 200 $true
Assert-True ($result.Success -and $global:CappTestWrites.Count -eq 0) 'An update dry run must not write'

Write-Output 'Account lifecycle regression checks passed.'

Remove-Variable CappTestLookupStatus, CappTestWrites -Scope Global
