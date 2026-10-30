################################################################
# HelloID-Conn-Prov-Target-CAPP12-SubPermissions-Manager
# PowerShell V2
################################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Script Mapping lookup values
# Lookup values which are used in the mapping to determine the subPermissions
$PrimaryLookupKey = { $_.Custom.ManagerOf } # Mandatory

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

# Begin
try {
    # Verify if [accountReference] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    $actionMessage = 'creating access token'
    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    $actionMessage = 'verifying if a CAPP12 account exists'
    Write-Information "Verifying if a CAPP12 account exists"
    $splatGetUserParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/users?code=$([Uri]::EscapeDataString([string] $actionContext.References.Account))"
        Headers = $headers
        Method  = 'GET'
    }
    $null = Invoke-Capp12Request @splatGetUserParams

    $actionMessage = 'collecting current and desired permissions'
    # Collect current permissions
    $currentPermissions = @{}
    foreach ($permission in $actionContext.CurrentPermissions) {
        $currentPermissions[$permission.Reference.Id] = $permission.DisplayName
    }

    # Collect desired permissions
    $desiredPermissions = @{}
    if (-not($actionContext.Operation -eq 'revoke')) {
        foreach ($contract in $personContext.Person.Contracts) {
            if ($contract.Context.InConditions) {
                $primaryKeys = (($contract | ForEach-Object $PrimaryLookupKey) -split ',').Trim('"') | Where-Object { -not [string]::IsNullOrEmpty($_) }
                foreach ($primaryKey in $primaryKeys) {
                    $desiredPermissions[$primaryKey] = $primaryKey
                }
            }
        }
    }

    if (($actionContext.Operation -in @('grant', 'update')) -and ($desiredPermissions.Count -eq 0 )) {
        throw "No departments found for which this person is a manager in person data. Grant/update permission should not be started for this person."
    }

    Write-Information ("Desired Permissions: {0}" -f ($desiredPermissions.Values | ConvertTo-Json))
    Write-Information ("Existing Permissions: {0}" -f ($actionContext.CurrentPermissions.DisplayName | ConvertTo-Json))

    $actionMessage = "granting manager departments to account [$($actionContext.References.Account)]"
    # Process desired permissions to grant
    foreach ($permission in $desiredPermissions.GetEnumerator()) {
        # try catch within the loop to handle errors for each permission
        try {
            $outputContext.SubPermissions.Add([PSCustomObject]@{
                    DisplayName = $permission.Value
                    Reference   = [PSCustomObject]@{
                        Id = $permission.Name
                    }
                })

            if (-not $currentPermissions.ContainsKey($permission.Name)) {
                $actionMessage = "granting manager department [$($permission.Value)] to account with AccountReference: [$($actionContext.References.Account)]"
                
                $body = [PSCustomObject]@{
                    user_code       = $actionContext.References.Account
                    department_code = $permission.Key
                    ends_on         = $null
                } | ConvertTo-Json -Depth 10

                $splatWebRequest = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/managers"
                    Headers = $headers
                    Method  = 'POST'
                    Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
                }
                if (-not($actionContext.DryRun -eq $true)) {
                    $null = Invoke-Capp12Request @splatWebRequest -Verbose:$false
                    
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Action  = 'GrantPermission'
                            Message = "Granted manager department [$($permission.Value)] to account with AccountReference: [$($actionContext.References.Account)]"
                            IsError = $false
                        })
                }
                else {
                    Write-Information "[DryRun] Would grant manager department [$($permission.Value)] to account with AccountReference: [$($actionContext.References.Account)]"
                }
            }
        }
        catch {
            $ex = $PSItem
            if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
                $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObj = Resolve-CAPP12Error -ErrorObject $ex
                $auditMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                $warningMessage = "Error at Line [$($errorObj.ScriptLineNumber)]: $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
            }
            else {
                $auditMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                $warningMessage = "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
            }
            Write-Warning $warningMessage
            
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'GrantPermission'
                    Message = $auditMessage
                    IsError = $true
                })
        }
    }

    $actionMessage = "revoking manager departments from account [$($actionContext.References.Account)]"
    # Process current permissions to revoke
    $newCurrentPermissions = @{}
    foreach ($permission in $currentPermissions.GetEnumerator()) {
        # try catch within the loop to handle errors for each permission
        try {
            if (-not $desiredPermissions.ContainsKey($permission.Name)) {
                $actionMessage = "revoking manager department [$($permission.Value)] from account with AccountReference: [$($actionContext.References.Account)]"
                
                $body = [PSCustomObject]@{
                    user_code       = $actionContext.References.Account
                    department_code = $permission.Key
                    ends_on         = (Get-Date).AddDays(-1).ToString('dd-MM-yyyy')
                } | ConvertTo-Json -Depth 10

                $splatWebRequest = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/managers"
                    Headers = $headers
                    Method  = 'POST'
                    Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
                }
                if (-not($actionContext.DryRun -eq $true)) {
                    $null = Invoke-Capp12Request @splatWebRequest -Verbose:$false
                    
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Action  = 'RevokePermission'
                            Message = "Revoked manager department [$($permission.Value)] from account with AccountReference: [$($actionContext.References.Account)]"
                            IsError = $false
                        })
                }
                else {
                    Write-Information "[DryRun] Would revoke manager department [$($permission.Value)] from account with AccountReference: [$($actionContext.References.Account)]"
                }
            }
            else {
                $newCurrentPermissions[$permission.Name] = $permission.Value
            }
        }
        catch {
            $ex = $PSItem
            if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
                $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObj = Resolve-CAPP12Error -ErrorObject $ex
                $auditMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
                $warningMessage = "Error at Line [$($errorObj.ScriptLineNumber)]: $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
            }
            else {
                $auditMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
                $warningMessage = "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
            }
            
            # Check if the error is because user or department doesn't exist (already revoked)
            if ($auditMessage -like "*Can't find user with code*" -or $auditMessage -like "*department with code*") {
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Action  = 'RevokePermission'
                        Message = "Skipped revoking manager department [$($permission.Value)] for user [$($actionContext.References.Account)]. Reason: User or department no longer exist."
                        IsError = $false
                    })
            }
            else {
                Write-Warning $warningMessage
                
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Action  = 'RevokePermission'
                        Message = $auditMessage
                        IsError = $true
                    })
            }
        }
    }

    # Process permissions to update
    # if ($actionContext.Operation -eq 'update') {
    #     foreach ($permission in $newCurrentPermissions.GetEnumerator()) {
    #         $body = [PSCustomObject]@{
    #             user_code       = $actionContext.References.Account
    #             department_code = $permission.Key
    #             ends_on         = $null
    #         } | ConvertTo-Json -Depth 10

    #         $splatWebRequest = @{
    #             Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/managers"
    #             Headers = $headers
    #             Method  = 'POST'
    #             Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
    #         }
    #         if (-not($actionContext.DryRun -eq $true)) {
    #             $null = Invoke-Capp12Request @splatWebRequest -Verbose:$false
    #         }

    #         $outputContext.AuditLogs.Add([PSCustomObject]@{
    #                 Action  = 'UpdatePermission'
    #                 Message = "Updated access to permission $($permission.Value)"
    #                 IsError = $false
    #             })
    #     }
    # }

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