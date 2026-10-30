##########################################################
# HelloID-Conn-Prov-Target-CAPP12-Resources-Position
# PowerShell V2
##########################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

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
    Write-Information "Processing [$(($resourceContext.SourceData | Measure-Object).Count)] position resources"

    $actionMessage = 'creating access token'
    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    $actionMessage = 'retrieving existing positions'
    $getPositionsSplat = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/positions"
        Headers = $headers
        Method  = 'GET'
    }
    $existingPositions = Invoke-Capp12Request @getPositionsSplat | ConvertFrom-Csv -Delimiter ';'
    $existingPositionsByCode = @{}
    foreach ($existing in $existingPositions) {
        if ([string]::IsNullOrEmpty($existing.code)) { continue }
        if ($existingPositionsByCode.ContainsKey($existing.code)) {
            throw "Multiple existing positions found with code [$($existing.code)]."
        }
        $existingPositionsByCode[$existing.code] = $existing
    }
    
    $actionMessage = 'processing position resources'
    foreach ($resource in $resourceContext.SourceData) {
        try {
            $existingPosition = $existingPositionsByCode[[string] $resource.ExternalId]

            if ($null -eq $existingPosition) {
                $action = 'CreateResource'
            }
            elseif ($existingPosition.title -ne $resource.Name) {
                $action = 'UpdateResource'
            }
            else {
                $action = 'NoChanges'
            }

            switch ($action) {
                { $_ -in @('CreateResource', 'UpdateResource') } {
                    $actionMessage = "$action position [$($resource.ExternalId)]"
                    
                    $body = [PSCustomObject]@{
                        code  = $resource.ExternalId
                        title = $resource.Name
                    }

                    if (-not ($actionContext.DryRun -eq $True)) {
                        Write-Information "$action`: [$($resource.ExternalId)] CAPP12 position"

                        $splatPositions = @{
                            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/positions"
                            Headers = $headers
                            Method  = 'POST'
                            Body    = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 10))
                        }
                        $null = Invoke-Capp12Request @splatPositions
                        $existingPositionsByCode[[string] $resource.ExternalId] = $body
                    }
                    else {
                        Write-Information "[DryRun] $action`: [$($resource.ExternalId)] CAPP12 position, will be executed during enforcement"
                    }

                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Action  = $action
                            Message = if ($action -eq 'UpdateResource') { "Updated position: [$($resource.ExternalId)]" } else { "Created position: [$($resource.ExternalId)]" }
                            IsError = $false
                        })
                    break
                }
                'NoChanges' {
                    Write-Information "Position [$($resource.ExternalId)] already exists with the same display name. No action needed."
                    break
                }
            }
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
            
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = $action
                    Message = $auditLogMessage
                    IsError = $true
                })
        }
    }

    # Check if auditLogs contains errors, if no errors are found, set success to true
    if (-NOT($outputContext.AuditLogs.IsError -contains $true)) {
        $outputContext.Success = $true
    }
}
catch {
    $outputContext.Success = $false
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
    
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}