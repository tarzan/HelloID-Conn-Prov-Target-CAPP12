#################################################
# HelloID-Conn-Prov-Target-CAPP12-Create
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

$script:cappRequestDeadline = [datetime]::UtcNow.AddSeconds(25)

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
    # Initial Assignments
    $outputContext.AccountReference = 'Currently not available'

    $actionMessage = 'creating access token'
    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    # Validate correlation configuration
    $actionMessage = 'validating correlation configuration'
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.AccountField
        $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue

        if ([string]::IsNullOrEmpty($($correlationField)) -or ($correlationField -ne 'code')) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }

        # Determine if a user needs to be [created] or [correlated]
        $actionMessage = 'querying account'

        # Retrieve user details using an API call and store the result in $correlatedAccount
        $splatGetUserParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/users?$correlationField=$([Uri]::EscapeDataString([string] $correlationValue))"
            Headers = $headers
            Method  = 'GET'
        }

        try {
            $correlatedAccount = Invoke-Capp12Request @splatGetUserParams
        }
        catch {
            # 404 Indicates that the account is not Found!
            if ($_.Exception.Response.StatusCode -ne 404) {
                throw $_
            }
        }
    }
    
    # Determine actions
    $actionMessage = 'determining actions'
    if (($correlatedAccount | Measure-Object).Count -eq 0) {
        $lifecycleProcess = 'CreateAccount'
    }
    elseif (($correlatedAccount | Measure-Object).Count -eq 1) {
        $lifecycleProcess = 'CorrelateAccount'
    }
    elseif (($correlatedAccount | Measure-Object).Count -gt 1) {
        throw "Multiple accounts found for person where $correlationField is: [$correlationValue]"
    }

    # Process
    switch ($lifecycleProcess) {
        'CreateAccount' {
            $actionMessage = "creating account with code [$($actionContext.Data.code)]"
            $body = $actionContext.Data | ConvertTo-Json

            $splatWebRequest = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/users"
                Headers = $headers
                Method  = 'POST'
                Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
            }
            
            if (-not($actionContext.DryRun -eq $true)) {
                $null = Invoke-Capp12Request @splatWebRequest -Verbose:$false # Always 204
                
                $outputContext.Data = $body
                $outputContext.AccountReference = $actionContext.Data.code
            }
            else {
                Write-Information '[DryRun] Create and correlate CAPP12 account, will be executed during enforcement'
            }
            $auditLogMessage = "Create account was successful. AccountReference is: [$($outputContext.AccountReference)]"
            break
        }
        'CorrelateAccount' {
            $actionMessage = "correlating account: [$($correlatedAccount.code)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            
            $outputContext.Data = $correlatedAccount
            $outputContext.AccountReference = $correlatedAccount.code
            $outputContext.AccountCorrelated = $true
            $auditLogMessage = "Correlated account: [$($outputContext.AccountReference)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            break
        }
    }

    # Check if auditLogs contains errors, if no errors are found, set success to true
    if (-NOT($outputContext.AuditLogs.IsError -contains $true)) {
        $outputContext.Success = $true
    }

    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $lifecycleProcess
            Message = $auditLogMessage
            IsError = $false
        })
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

    # If the error is about duplicate email, append $auditLogMessage with the email address we tried to update
    if ($errorObj.FriendlyMessage -like "*email already exists*") {
        $auditLogMessage += ". Email address that was attempted to be updated: [$($actionContext.Data.email)]"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}