####################################################################
# HelloID-Conn-Prov-Target-CAPP12-ImportSubPermissions-Assignment
# PowerShell V2
####################################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Configure, must be the same as the values used in retrieve permissions
$permissionReference = 'assignment'
$permissionDisplayName = 'Position assignment'

$script:cappRequestDeadline = $null

#region functions
function Get-Capp12AuthorizationTokenAndCreateHeaders {
    [CmdletBinding()]
    param()
    try {
        Write-Information 'Creating Access Token'
        $authorizationBody = @{
            grant_type                = 'client_credentials'
            client_id                 = $actionContext.Configuration.ClientId
            client_secret             = $actionContext.Configuration.ClientSecret
            token_expiration_disabled = $false
        }
        $splatInvoke = @{
            Uri         = "$($actionContext.Configuration.BaseUrl)/oauth2/token"
            Method      = 'POST'
            ContentType = 'application/json'
            Body        = $authorizationBody | ConvertTo-Json -Depth 10
        }

        $accessToken = Invoke-Capp12Request @splatInvoke

        Write-Information 'Adding Authorization headers'
        $headers = [System.Collections.Generic.Dictionary[[String], [String]]]::new()
        $headers.Add('Authorization', "$($accessToken.token_type) $($accessToken.access_token)")
        $headers.Add('Accept', 'application/json')
        $headers.Add('Content-Type', 'application/json')
        Write-Output $headers
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Invoke-Capp12Request {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST')] [string] $Method,
        $Headers,
        $Body,
        [string] $ContentType
    )

    $requestUri = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref] $requestUri) -or
        $requestUri.Scheme -ne 'https' -or -not [string]::IsNullOrEmpty($requestUri.UserInfo)) {
        throw 'CAPP12 requests require an absolute HTTPS URL without embedded credentials.'
    }
    $parameters = @{
        Uri = $requestUri.AbsoluteUri; Method = $Method
        MaximumRedirection = 0; ErrorAction = 'Stop'
    }
    foreach ($name in 'Headers', 'Body', 'ContentType') {
        if ($PSBoundParameters.ContainsKey($name)) { $parameters[$name] = $PSBoundParameters[$name] }
    }

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $parameters.TimeoutSec = 10
        if ($null -ne $script:cappRequestDeadline) {
            $remaining = [Math]::Floor(($script:cappRequestDeadline - [datetime]::UtcNow).TotalSeconds)
            if ($remaining -lt 1) { throw 'CAPP12 account action request budget exhausted; retry the action later.' }
            $parameters.TimeoutSec = [int] [Math]::Min(10, $remaining)
        }
        try {
            return Invoke-RestMethod @parameters
        }
        catch {
            # POST may already have committed when a response fails. Only retry reads.
            $response = $_.Exception.Response
            $status = [int] $response.StatusCode
            if ($Method -ne 'GET' -or $attempt -eq 2 -or $status -notin @(429, 502, 503, 504)) { throw }

            $delay = [Math]::Pow(2, $attempt)
            $retryAfter = $null
            if ($response -is [System.Net.Http.HttpResponseMessage]) {
                $values = $null
                if ($response.Headers.TryGetValues('Retry-After', [ref] $values)) { $retryAfter = @($values)[0] }
            }
            elseif ($null -ne $response.Headers) { $retryAfter = $response.Headers['Retry-After'] }
            $seconds = 0
            $retryDate = [DateTimeOffset]::MinValue
            if ([int]::TryParse($retryAfter, [ref] $seconds)) {
                $delay = [Math]::Max(0, $seconds)
            }
            elseif ([DateTimeOffset]::TryParse($retryAfter, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal, [ref] $retryDate)) {
                $delay = [Math]::Max(0, [Math]::Ceiling(($retryDate - [DateTimeOffset]::UtcNow).TotalSeconds))
            }
            # Do not retry earlier than the server requested, or sleep past the host's deadline.
            if ($delay -gt 10 -or ($null -ne $script:cappRequestDeadline -and
                    ($script:cappRequestDeadline - [datetime]::UtcNow).TotalSeconds -le ($delay + 1))) { throw }
            Start-Sleep -Seconds $delay
        }
    }
}

function Resolve-CAPP12Error {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            if ($null -ne $errorDetailsObject.error) {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.error
            }
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}
#endregion

try {
    Write-Information 'Starting import of assignment sub-permission entitlements'

    $actionMessage = 'creating access token'
    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    $actionMessage = 'querying assignment permissions'

    $splatImportPermissionParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/assignments"
        Headers = $headers
        Method  = 'GET'
    }

    $importedPermissionsCsv = Invoke-Capp12Request @splatImportPermissionParams
    $unfilteredImportedPermissions = $importedPermissionsCsv | ConvertFrom-Csv -Delimiter ';'
    Write-Information "Queried assignment permissions. Result count: $($unfilteredImportedPermissions.Count)"

    $actionMessage = 'filtering assignment permissions'

    $importedPermissions = $unfilteredImportedPermissions | Where-Object {
        # Keep when ends_on is empty or a date in the future
        if ([string]::IsNullOrEmpty($_.ends_on))
        { $true }
        else
        { [datetime]::Parse($_.ends_on) -gt [datetime]::Now }
    }

    $splatImportPositionsParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/positions"
        Headers = $headers
        Method  = 'GET'
    }

    $groupedPermissions = $importedPermissions | Group-Object -Property position_code -AsHashTable

    $importedPositionsCsv = Invoke-Capp12Request @splatImportPositionsParams
    $importedPositions = $importedPositionsCsv | ConvertFrom-Csv -Delimiter ';'
    $importedPositionsByCode = @{}
    foreach ($resource in $importedPositions) {
        if (-not [string]::IsNullOrEmpty($resource.code)) {
            $importedPositionsByCode[$resource.code] = $resource
        }
    }

    $actionMessage = 'importing assignment sub-permission entitlements to HelloID'
    $importedSubPermissions = 0
    foreach ($importedPermission in $groupedPermissions.GetEnumerator()) {
        $permission = @{
            PermissionReference      = @{
                Reference = $permissionReference
            }
            Description              = $permissionDisplayName
            DisplayName              = $permissionDisplayName
            AccountReferences        = $null
            SubPermissionReference   = @{
                Id = $importedPermission.Key
            }
            SubPermissionDisplayName = "$($importedPositionsByCode[$importedPermission.Key].title) ($($importedPermission.Key))"
        }

        # The code below splits a list of permission members into batches of 100
        # Each batch is assigned to $permission.AccountReferences and the permission object will be returned to HelloID for each batch
        # Ensure batching is based on the number of account references to prevent exceeding the maximum limit of 500 account references per batch
        $batchSize = 500
        $members = @($importedPermission.Value.user_code | Where-Object { -not [string]::IsNullOrEmpty($_) })
        for ($i = 0; $i -lt $members.Count; $i += $batchSize) {
            $permission.AccountReferences = $members[$i..([Math]::Min($i + $batchSize - 1, $members.Count - 1))]
            Write-Output $permission
            $importedSubPermissions++
        }
    }
    Write-Information "Assignment sub-permission entitlements import completed. Result count: $($importedSubPermissions)"
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CAPP12Error -ErrorObject $ex
        $auditLogMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
        $warningMessage = "Error at Line [$($errorObj.ScriptLineNumber)]: $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
        $warningMessage = "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    Write-Warning $warningMessage
    Write-Error $auditLogMessage
}