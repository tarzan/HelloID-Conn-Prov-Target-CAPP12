################################################################
# HelloID-Conn-Prov-Target-CAPP12-SubPermissions-Manager
# PowerShell V2
################################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Script Mapping lookup values
# Lookup values which are used in the mapping to determine the subPermissions
$PrimaryLookupKey = { $_.Custom.ManagerOf } # Mandatory

#region functions
function Get-Capp12Today {
    param([datetime] $UtcNow = [datetime]::UtcNow)
    # CAPP evaluates end dates in Europe/Amsterdam, regardless of the agent timezone.
    try {
        $timeZone = [TimeZoneInfo]::FindSystemTimeZoneById('Europe/Amsterdam')
    }
    catch [System.TimeZoneNotFoundException] {
        $timeZone = [TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time')
    }
    return [TimeZoneInfo]::ConvertTimeFromUtc($UtcNow, $timeZone).Date
}

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

        $accessToken = Invoke-RestMethod @splatInvoke

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
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/users?code=$($actionContext.References.Account)"
        Headers = $headers
        Method  = 'GET'
    }
    $account = Invoke-RestMethod @splatGetUserParams
    if ($account.active -eq $false) {
        foreach ($permission in $actionContext.CurrentPermissions) {
            $outputContext.SubPermissions.Add($permission)
        }
        throw 'The CAPP12 account is inactive. Revoke permissions before account deactivation; existing relationships may still remain.'
    }

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

    if (($actionContext.Operation -eq 'grant') -and ($desiredPermissions.Count -eq 0 )) {
        throw "No departments found for which this person is a manager in person data. Grant permission should not be started for this person."
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
                    $null = Invoke-RestMethod @splatWebRequest -Verbose:$false
                    
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
                    ends_on         = (Get-Capp12Today).AddDays(-1).ToString('dd-MM-yyyy')
                } | ConvertTo-Json -Depth 10

                $splatWebRequest = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/managers"
                    Headers = $headers
                    Method  = 'POST'
                    Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
                }
                if (-not($actionContext.DryRun -eq $true)) {
                    $null = Invoke-RestMethod @splatWebRequest -Verbose:$false
                    
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
            
            # A missing/inactive user or archived resource does not prove the
            # relationship was removed. Preserve it for a later retry.
            Write-Warning $warningMessage
            $outputContext.SubPermissions.Add([PSCustomObject]@{
                    DisplayName = $permission.Value
                    Reference   = [PSCustomObject]@{ Id = $permission.Name }
                })
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'RevokePermission'
                    Message = $auditMessage
                    IsError = $true
                })
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
    #             $null = Invoke-RestMethod @splatWebRequest -Verbose:$false
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