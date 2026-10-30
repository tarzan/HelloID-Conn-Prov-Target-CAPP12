# Run with: pwsh -NoProfile -File tests/Test-Requests.ps1
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent

function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock] $Action, [string] $Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}

$helperText = $null
foreach ($file in Get-ChildItem $repository -Filter '*.ps1' -Recurse | Where-Object { $_.Directory.Name -ne 'tests' }) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $errors)
    Assert-True ($errors.Count -eq 0) "Syntax errors in $($file.Name): $errors"
    $helper = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Capp12Request' }, $true)
    Assert-True ($null -ne $helper) "Missing request helper in $($file.FullName)"
    if ($null -eq $helperText) { $helperText = $helper.Extent.Text }
    Assert-True ($helper.Extent.Text -ceq $helperText) "Request helpers diverged in $($file.FullName)"
}
. ([scriptblock]::Create($helperText))

function Reset-Mock {
    $global:CappHttpTest = @{
        Calls = [System.Collections.Generic.List[object]]::new()
        Sleeps = [System.Collections.Generic.List[double]]::new()
        Statuses = @(200); RetryAfter = $null; Mode = 'request'; Csv = ''
    }
    $script:cappRequestDeadline = $null
}
function Start-Sleep { param([double] $Seconds) $global:CappHttpTest.Sleeps.Add($Seconds) }
function Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec, $MaximumRedirection)
    $global:CappHttpTest.Calls.Add(@{ Uri = $Uri; Method = $Method; Body = $Body; Timeout = $TimeoutSec; Redirects = $MaximumRedirection })
    if ($global:CappHttpTest.Mode -eq 'resource') {
        if ($Uri -like '*/oauth2/token') { return @{ token_type = 'Bearer'; access_token = 'test-token' } }
        if ($Method -eq 'GET') { return $global:CappHttpTest.Csv }
        return
    }
    if ($global:CappHttpTest.Mode -eq 'account') {
        if ($Uri -like '*/oauth2/token') { return @{ token_type = 'Bearer'; access_token = 'test-token' } }
        return [PSCustomObject]@{ code = '123'; active = $true }
    }
    $index = [Math]::Min($global:CappHttpTest.Calls.Count - 1, $global:CappHttpTest.Statuses.Count - 1)
    $status = $global:CappHttpTest.Statuses[$index]
    if ($status -ne 200) {
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode] $status)
        if ($null -ne $global:CappHttpTest.RetryAfter) { $null = $response.Headers.TryAddWithoutValidation('Retry-After', [string] $global:CappHttpTest.RetryAfter) }
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Simulated HTTP error', $response)
    }
    return 'ok'
}

foreach ($uri in 'http://example.invalid/users', '/users', 'https://user:secret@example.invalid/users') {
    Reset-Mock
    Assert-Throws { Invoke-Capp12Request -Uri $uri -Method POST -Body 'secret' } 'Unsafe URL must be rejected'
    Assert-True ($global:CappHttpTest.Calls.Count -eq 0) 'Unsafe URL must not receive credentials'
}
foreach ($status in 429, 502, 503, 504) {
    Reset-Mock
    $global:CappHttpTest.Statuses = @($status, 200)
    Assert-True ((Invoke-Capp12Request -Uri 'https://example.invalid/users' -Method GET) -eq 'ok') 'Transient GET must recover'
    Assert-True ($global:CappHttpTest.Calls.Count -eq 2 -and $global:CappHttpTest.Sleeps[0] -eq 1) 'GET must retry with backoff'
    Assert-True ($global:CappHttpTest.Calls[0].Timeout -eq 10 -and $global:CappHttpTest.Calls[0].Redirects -eq 0) 'Requests need timeout and redirect protection'
}
foreach ($status in 301, 400, 401, 403, 404, 422, 500) {
    Reset-Mock
    $global:CappHttpTest.Statuses = @($status)
    Assert-Throws { Invoke-Capp12Request -Uri 'https://example.invalid/users' -Method GET } 'Non-retryable response must fail'
    Assert-True ($global:CappHttpTest.Calls.Count -eq 1) 'Non-retryable response must not retry'
}
Reset-Mock
$global:CappHttpTest.Statuses = @(503)
Assert-Throws { Invoke-Capp12Request -Uri 'https://example.invalid/users' -Method GET } 'Retries must be bounded'
Assert-True ($global:CappHttpTest.Calls.Count -eq 3 -and ($global:CappHttpTest.Sleeps -join ',') -eq '1,2') 'GET must stop after three attempts'
foreach ($status in 429, 503) {
    Reset-Mock
    $global:CappHttpTest.Statuses = @($status)
    Assert-Throws { Invoke-Capp12Request -Uri 'https://example.invalid/users' -Method POST -Body '{}' } 'POST must fail without replay'
    Assert-True ($global:CappHttpTest.Calls.Count -eq 1) 'POST must never retry automatically'
}
foreach ($header in '2', ([DateTimeOffset]::UtcNow.AddSeconds(5).ToString('r'))) {
    Reset-Mock
    $global:CappHttpTest.Statuses = @(429, 200)
    $global:CappHttpTest.RetryAfter = $header
    $null = Invoke-Capp12Request -Uri 'https://example.invalid/users' -Method GET
    Assert-True ($global:CappHttpTest.Sleeps[0] -ge 2 -and $global:CappHttpTest.Sleeps[0] -le 5) 'Retry-After must be honored'
}
Reset-Mock
$global:CappHttpTest.Statuses = @(429)
$global:CappHttpTest.RetryAfter = '120'
Assert-Throws { Invoke-Capp12Request -Uri 'https://example.invalid/users' -Method GET } 'Long Retry-After must fail for a later action retry'
Assert-True ($global:CappHttpTest.Sleeps.Count -eq 0) 'Must not retry before a long Retry-After'
Reset-Mock
$script:cappRequestDeadline = [datetime]::UtcNow.AddSeconds(-1)
Assert-Throws { Invoke-Capp12Request -Uri 'https://example.invalid/users' -Method GET } 'Exhausted account budget must stop requests'
Assert-True ($global:CappHttpTest.Calls.Count -eq 0) 'Exhausted budget must not call the API'
Reset-Mock
$script:cappRequestDeadline = [datetime]::UtcNow.AddSeconds(2)
$global:CappHttpTest.Statuses = @(503)
Assert-Throws { Invoke-Capp12Request -Uri 'https://example.invalid/users' -Method GET } 'Retry must respect the account deadline'
Assert-True ($global:CappHttpTest.Calls.Count -eq 1 -and $global:CappHttpTest.Calls[0].Timeout -le 2) 'Remaining budget must cap request timeout'

Reset-Mock
$global:CappHttpTest.Mode = 'account'
$code = 'A&B+C #/é'
$actionContext = [PSCustomObject]@{
    Configuration = @{ BaseUrl = 'https://example.invalid'; ClientId = 'test'; ClientSecret = 'test' }
    CorrelationConfiguration = @{ Enabled = $true; AccountField = 'code'; PersonFieldValue = $code }
    Data = [PSCustomObject]@{ code = $code }; DryRun = $true
}
$outputContext = [PSCustomObject]@{
    Success = $false; AccountReference = $null; AccountCorrelated = $false; Data = $null
    AuditLogs = [System.Collections.Generic.List[object]]::new()
}
& (Join-Path $repository 'create.ps1')
$lookup = @($global:CappHttpTest.Calls | Where-Object Method -eq 'GET')[0]
Assert-True ($lookup.Uri -ceq "https://example.invalid/api/v1/users?code=$([Uri]::EscapeDataString($code))") 'Account codes must be encoded as one query value'

foreach ($kind in 'Departments', 'Positions') {
    Reset-Mock
    $global:CappHttpTest.Mode = 'resource'
    $global:CappHttpTest.Csv = "code;title`nexisting;Old"
    $actionContext = [PSCustomObject]@{
        Configuration = @{ BaseUrl = 'https://example.invalid'; ClientId = 'test'; ClientSecret = 'test' }
        DryRun = $false
    }
    $resourceContext = [PSCustomObject]@{
        SourceData = @(
            [PSCustomObject]@{ ExternalId = 'existing'; Name = 'New'; DisplayName = 'New' },
            [PSCustomObject]@{ ExternalId = 'existing'; Name = 'New'; DisplayName = 'New' },
            [PSCustomObject]@{ ExternalId = 'created'; Name = 'Created'; DisplayName = 'Created' },
            [PSCustomObject]@{ ExternalId = 'created'; Name = 'Created'; DisplayName = 'Created' }
        )
    }
    $outputContext = [PSCustomObject]@{ Success = $false; AuditLogs = [System.Collections.Generic.List[object]]::new() }
    & (Join-Path $repository "resources/$kind/resources.ps1")
    $writes = @($global:CappHttpTest.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -notlike '*/oauth2/token' })
    Assert-True ($outputContext.Success -and $writes.Count -eq 2) "$kind must update its index after successful writes"

    Reset-Mock
    $global:CappHttpTest.Mode = 'resource'
    $global:CappHttpTest.Csv = "code;title`nexisting;One`nEXISTING;Two"
    $outputContext = [PSCustomObject]@{ Success = $false; AuditLogs = [System.Collections.Generic.List[object]]::new() }
    $WarningPreference = 'SilentlyContinue'
    & (Join-Path $repository "resources/$kind/resources.ps1")
    Assert-True (-not $outputContext.Success) "$kind must reject duplicate codes without silently picking one"
    Assert-True ($global:CappHttpTest.Calls.Count -eq 2) "$kind must reject duplicate codes before writes"
}

Remove-Variable CappHttpTest -Scope Global
Write-Output 'Request and resource regression checks passed.'
