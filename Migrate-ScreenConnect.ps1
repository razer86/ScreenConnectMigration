<#
.SYNOPSIS
    ScreenConnect Migration Webhook Receiver

.DESCRIPTION
    Listens for webhook calls from ScreenConnect automation triggers and pushes
    installation commands back to devices via the RESTful API Manager extension.

    This enables automated migration of devices from one ScreenConnect instance
    to another, preserving session name and custom properties.

.NOTES
    Requires: PowerShell 5.1+, RESTful API Manager extension on source instances
    Author: https://github.com/razer86
    License: MIT

.LINK
    https://github.com/razer86/ScreenConnectMigration
#>

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.ps1")
)

# Load configuration
if (-not (Test-Path $ConfigPath)) {
    Write-Host "Configuration file not found: $ConfigPath" -ForegroundColor Red
    Write-Host "Copy config.example.ps1 to config.ps1 and fill in your values." -ForegroundColor Yellow
    exit 1
}

$Config = & $ConfigPath

# Validate required config
$requiredKeys = @("ListenPrefix", "IntakeBasePath", "ResultBasePath", "CallbackBaseUrl", "DataDir", "TargetBaseUrl", "SourceInstances")
foreach ($key in $requiredKeys) {
    if (-not $Config.ContainsKey($key)) {
        Write-Host "Missing required config key: $key" -ForegroundColor Red
        exit 1
    }
}

if ($Config.SourceInstances.Count -eq 0) {
    Write-Host "No source instances configured. Add at least one to SourceInstances in config.ps1" -ForegroundColor Red
    exit 1
}

# Extract config values
$ListenPrefix    = $Config.ListenPrefix
$IntakeBasePath  = $Config.IntakeBasePath.TrimEnd('/')
$ResultBasePath  = $Config.ResultBasePath.TrimEnd('/')
$CallbackBaseUrl = $Config.CallbackBaseUrl.TrimEnd('/')
$DataDir         = $Config.DataDir
$TestMode        = $Config.TestMode -eq $true
$TargetBaseUrl   = $Config.TargetBaseUrl.TrimEnd('/')
$SourceInstances = $Config.SourceInstances

# Ensure data directory exists
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$LogFile = Join-Path $DataDir "migration.log"
$ResultLogFile = Join-Path $DataDir "results.log"
$ErrorLogFile = Join-Path $DataDir "errors.log"

#region Functions

function Write-ErrorLog {
    param(
        [string]$Instance,
        [string]$Reason,
        [string]$SourceIP,
        [string]$Path,
        [string]$SessionId,
        [string]$RawBody
    )

    $entry = [ordered]@{
        ts        = (Get-Date).ToString("o")
        instance  = $Instance
        reason    = $Reason
        sourceIP  = $SourceIP
        path      = $Path
        sessionId = $SessionId
        rawBody   = if ($RawBody.Length -gt 1000) { $RawBody.Substring(0, 1000) + "..." } else { $RawBody }
    } | ConvertTo-Json -Depth 10 -Compress

    Add-Content -Path $ErrorLogFile -Value $entry
}

function Write-ResultLog {
    param(
        [string]$Instance,
        [string]$SessionId,
        [bool]$Success,
        [string]$Message,
        [string]$SourceIP
    )

    $entry = [ordered]@{
        ts        = (Get-Date).ToString("o")
        instance  = $Instance
        sessionId = $SessionId
        success   = $Success
        message   = $Message
        sourceIP  = $SourceIP
    } | ConvertTo-Json -Depth 10 -Compress

    Add-Content -Path $ResultLogFile -Value $entry
}

function Sc-GetDetails([string]$scBase, [hashtable]$scHeaders, [string]$SessionId) {
    $body = "[`"$SessionId`"]"
    Invoke-RestMethod -Method Get -Uri "$scBase/GetSessionDetailsBySessionID" -Headers $scHeaders -ContentType "application/json" -Body $body
}

function Sc-SetCustomProperty([string]$scBase, [hashtable]$scHeaders, [string]$SessionId, [int]$PropertyIndex, [string]$NewValue) {
    $details = Sc-GetDetails $scBase $scHeaders $SessionId
    $cp = @($details.Session.CustomPropertyValues)
    if ($cp.Count -lt ($PropertyIndex + 1)) { throw "Expected at least $($PropertyIndex + 1) CustomPropertyValues; got $($cp.Count)" }
    $cp[$PropertyIndex] = $NewValue
    $bodySet = @($SessionId, $cp) | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "$scBase/UpdateSessionCustomProperties" -Headers $scHeaders -ContentType "application/json" -Body $bodySet | Out-Null
}

function Sc-SendCommand([string]$scBase, [hashtable]$scHeaders, [string]$SessionId, [string]$Command) {
    $body = @($SessionId, $Command) | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "$scBase/SendCommandToSession" -Headers $scHeaders -ContentType "application/json" -Body $body | Out-Null
}

function Read-Body([System.Net.HttpListenerRequest]$req) {
    if ($req.ContentLength64 -gt 1048576) { throw "Body too large (max 1MB)" }
    $sr = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
    $body = $sr.ReadToEnd()
    $sr.Close()
    return $body
}

function Test-PayloadValid {
    param($Payload, [ref]$MissingFields)

    $required = @("SessionID", "Name", "SessionType")
    $missing = @()

    foreach ($field in $required) {
        if (-not ($Payload.PSObject.Properties.Name -contains $field)) {
            $missing += "$field (missing)"
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$Payload.$field)) {
            $missing += "$field (empty)"
        }
    }

    # SessionType must be "Access" for migration candidates
    if ($missing.Count -eq 0 -and [string]$Payload.SessionType -ne "Access") {
        $missing += "SessionType (must be 'Access', got '$($Payload.SessionType)')"
    }

    $MissingFields.Value = $missing
    return ($missing.Count -eq 0)
}

function Test-ResultPayloadValid {
    param($Payload, [ref]$MissingFields)

    $required = @("sessionId", "success")
    $missing = @()

    foreach ($field in $required) {
        if (-not ($Payload.PSObject.Properties.Name -contains $field)) {
            $missing += "$field (missing)"
        }
    }

    # sessionId must be non-empty
    if ($Payload.PSObject.Properties.Name -contains "sessionId" -and [string]::IsNullOrWhiteSpace([string]$Payload.sessionId)) {
        $missing += "sessionId (empty)"
    }

    $MissingFields.Value = $missing
    return ($missing.Count -eq 0)
}

function Build-InstallerUrl([string]$baseUrl, [string]$name, [string[]]$customProperties) {
    $url = "$baseUrl/Bin/ScreenConnect.ClientSetup.exe?e=Access&y=Guest"
    $url += "&t=$([uri]::EscapeDataString($name))"
    foreach ($cp in $customProperties) {
        $url += "&c=$([uri]::EscapeDataString($cp))"
    }
    return $url
}

function Get-InstanceFromPath([string]$path, [string]$basePath) {
    # Extract instance name from path like /api/v1/sc/intake/capconn -> capconn
    if ($path.StartsWith($basePath + "/")) {
        $remainder = $path.Substring($basePath.Length + 1)
        # Take only the first segment (in case there's more path after)
        $instance = $remainder.Split('/')[0]
        if (-not [string]::IsNullOrWhiteSpace($instance)) {
            return $instance.ToLower()
        }
    }
    return $null
}

function Get-RouteType([string]$path) {
    # Determine if this is an intake or result request
    if ($path.StartsWith($IntakeBasePath + "/")) {
        return "intake"
    }
    elseif ($path.StartsWith($ResultBasePath + "/")) {
        return "result"
    }
    return $null
}

#endregion

# Start listener
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($ListenPrefix)
$listener.Start()

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " ScreenConnect Migration Receiver" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Listening:   $ListenPrefix"
Write-Host "Callback:    $CallbackBaseUrl"
Write-Host "Target:      $TargetBaseUrl"
Write-Host "Test Mode:   $TestMode"
Write-Host ""
Write-Host "Endpoints:"
foreach ($inst in $SourceInstances.Keys) {
    Write-Host "  Intake: $IntakeBasePath/$inst"
    Write-Host "  Result: $ResultBasePath/$inst"
}
Write-Host ""
Write-Host "Logs:"
Write-Host "  Migration: $LogFile"
Write-Host "  Results:   $ResultLogFile"
Write-Host "  Errors:    $ErrorLogFile"
Write-Host "----------------------------------------"
Write-Host "Press Ctrl+C to stop"
Write-Host ""

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        $status = 200
        $outObj = @{ ok = $true }

        # Capture request info for error logging
        $sourceIP = $req.RemoteEndPoint.Address.ToString()
        $requestPath = $req.Url.AbsolutePath
        $raw = ""
        $instanceKey = $null
        $sessionId = $null

        try {
            # Method check first
            if ($req.HttpMethod -ne "POST") {
                $status = 405
                throw "Method not allowed: $($req.HttpMethod)"
            }

            # Determine route type
            $routeType = Get-RouteType $requestPath

            if ($routeType -eq "intake") {
                # === INTAKE ENDPOINT ===
                $instanceKey = Get-InstanceFromPath $requestPath $IntakeBasePath

                if (-not $instanceKey) {
                    $status = 404
                    throw "Invalid path (expected $IntakeBasePath/{instance})"
                }

                if (-not $SourceInstances.ContainsKey($instanceKey)) {
                    $status = 404
                    throw "Unknown instance: $instanceKey"
                }

                $cfg = $SourceInstances[$instanceKey]

                # Read body
                $raw = Read-Body $req
                if ([string]::IsNullOrWhiteSpace($raw)) {
                    $status = 400
                    throw "Empty request body"
                }

                # Parse JSON
                try {
                    $payload = $raw | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    $status = 400
                    throw "Invalid JSON: $($_.Exception.Message)"
                }

                # Validate required fields
                $missingFields = @()
                if (-not (Test-PayloadValid $payload ([ref]$missingFields))) {
                    $status = 400
                    throw "Missing required fields: $($missingFields -join ', ')"
                }

                $sessionId = [string]$payload.SessionID

                # Extract session data
                $sessionName = [string]$payload.Name
                $cp = @(
                    [string]$payload.CustomProperty1,
                    [string]$payload.CustomProperty2,
                    [string]$payload.CustomProperty3,
                    [string]$payload.CustomProperty4,
                    [string]$payload.CustomProperty5,
                    [string]$payload.CustomProperty6,
                    [string]$payload.CustomProperty7,
                    ""  # CP8 intentionally blank on new instance
                )

                # Build API config for source instance
                $scUrl  = $cfg.BaseUrl.TrimEnd('/')
                $scBase = "$scUrl/App_Extensions/$($cfg.ExtGuid)/Service.ashx"
                $scHeaders = @{
                    "CTRLAuthHeader" = $cfg.CtrlSecret
                    "Origin"         = $scUrl
                }

                # Build installer URL for target instance
                $installerUrl = Build-InstallerUrl $TargetBaseUrl $sessionName $cp

                # Build callback URL for result reporting
                $resultUrl = "$CallbackBaseUrl$ResultBasePath/$instanceKey"

                # Log the request
                $ts = (Get-Date).ToString("o")
                $logEntry = [ordered]@{
                    ts = $ts
                    instance = $instanceKey
                    sessionId = $sessionId
                    sessionName = $sessionName
                    cp1 = $cp[0]; cp2 = $cp[1]; cp3 = $cp[2]; cp4 = $cp[3]
                    cp5 = $cp[4]; cp6 = $cp[5]; cp7 = $cp[6]
                    installerUrl = $installerUrl
                    testMode = $TestMode
                } | ConvertTo-Json -Depth 10 -Compress
                Add-Content -Path $LogFile -Value $logEntry

                # Process the migration
                $timeShort = $ts.Substring(11, 8)
                if ($TestMode) {
                    Write-Host "[$timeShort] TEST | $instanceKey | $sessionName | $sessionId | CP1=$($cp[0])" -ForegroundColor Yellow
                    $outObj = @{ ok = $true; action = "test_logged"; sessionId = $sessionId; instance = $instanceKey }
                }
                else {
                    Write-Host "[$timeShort] SENT | $instanceKey | $sessionName | $sessionId | CP1=$($cp[0])" -ForegroundColor Green

                    # Update CP8 on source to mark as migrating
                    Sc-SetCustomProperty $scBase $scHeaders $sessionId 7 "MIG:SENT"

                    # Send install command to device with callback
                    $cmd = @"
#!ps
#timeout=300000
`$ErrorActionPreference = "Stop"
`$sessionId = "$sessionId"
`$installerUrl = "$installerUrl"
`$resultUrl = "$resultUrl"
`$installerPath = "`$env:TEMP\ScreenConnect.ClientSetup.exe"

function Send-Result {
    param([bool]`$Success, [string]`$Message)
    try {
        `$body = @{ sessionId = `$sessionId; success = `$Success; message = `$Message } | ConvertTo-Json -Compress
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Uri `$resultUrl -Method POST -Body `$body -ContentType "application/json" -UseBasicParsing | Out-Null
    } catch {
        Write-Host "Failed to send result: `$(`$_.Exception.Message)"
    }
}

try {
    Write-Host "Downloading ScreenConnect installer..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri `$installerUrl -OutFile `$installerPath -UseBasicParsing

    Write-Host "Running installer..."
    `$process = Start-Process -FilePath `$installerPath -ArgumentList "/silent" -Wait -PassThru

    Remove-Item -Path `$installerPath -Force -ErrorAction SilentlyContinue

    if (`$process.ExitCode -eq 0) {
        Write-Host "Migration complete"
        Send-Result -Success `$true -Message "Installation completed successfully"
    } else {
        Write-Host "Installer exited with code: `$(`$process.ExitCode)"
        Send-Result -Success `$false -Message "Installer exited with code: `$(`$process.ExitCode)"
    }
} catch {
    `$errorMsg = `$_.Exception.Message
    Write-Host "Migration failed: `$errorMsg"
    Send-Result -Success `$false -Message `$errorMsg
}
"@
                    Sc-SendCommand $scBase $scHeaders $sessionId $cmd
                    $outObj = @{ ok = $true; action = "sent"; sessionId = $sessionId; instance = $instanceKey }
                }
            }
            elseif ($routeType -eq "result") {
                # === RESULT ENDPOINT ===
                $instanceKey = Get-InstanceFromPath $requestPath $ResultBasePath

                if (-not $instanceKey) {
                    $status = 404
                    throw "Invalid path (expected $ResultBasePath/{instance})"
                }

                if (-not $SourceInstances.ContainsKey($instanceKey)) {
                    $status = 404
                    throw "Unknown instance: $instanceKey"
                }

                $cfg = $SourceInstances[$instanceKey]

                # Read body
                $raw = Read-Body $req
                if ([string]::IsNullOrWhiteSpace($raw)) {
                    $status = 400
                    throw "Empty request body"
                }

                # Parse JSON
                try {
                    $payload = $raw | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    $status = 400
                    throw "Invalid JSON: $($_.Exception.Message)"
                }

                # Validate required fields
                $missingFields = @()
                if (-not (Test-ResultPayloadValid $payload ([ref]$missingFields))) {
                    $status = 400
                    throw "Missing required fields: $($missingFields -join ', ')"
                }

                $sessionId = [string]$payload.sessionId
                $success = [bool]$payload.success
                $message = if ($payload.PSObject.Properties.Name -contains "message") { [string]$payload.message } else { "" }

                # Build API config for source instance
                $scUrl  = $cfg.BaseUrl.TrimEnd('/')
                $scBase = "$scUrl/App_Extensions/$($cfg.ExtGuid)/Service.ashx"
                $scHeaders = @{
                    "CTRLAuthHeader" = $cfg.CtrlSecret
                    "Origin"         = $scUrl
                }

                # Update CP8 based on result
                $ts = (Get-Date).ToString("o")
                $timeShort = $ts.Substring(11, 8)

                if ($success) {
                    Sc-SetCustomProperty $scBase $scHeaders $sessionId 7 "MIG:SUCCESS"
                    Write-Host "[$timeShort] SUCCESS | $instanceKey | $sessionId" -ForegroundColor Green
                }
                else {
                    Sc-SetCustomProperty $scBase $scHeaders $sessionId 7 "MIG:FAILED"
                    Write-Host "[$timeShort] FAILED  | $instanceKey | $sessionId | $message" -ForegroundColor Red
                }

                # Log the result
                Write-ResultLog -Instance $instanceKey -SessionId $sessionId -Success $success -Message $message -SourceIP $sourceIP

                $outObj = @{ ok = $true; action = "result_recorded"; sessionId = $sessionId; success = $success }
            }
            else {
                $status = 404
                throw "Unknown endpoint: $requestPath"
            }
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ERROR | $errMsg" -ForegroundColor Red
            $outObj = @{ ok = $false; error = $errMsg }
            if ($status -eq 200) { $status = 500 }

            # Log to error file
            Write-ErrorLog -Instance $instanceKey -Reason $errMsg -SourceIP $sourceIP -Path $requestPath -SessionId $sessionId -RawBody $raw
        }

        # Send response
        $json = $outObj | ConvertTo-Json -Depth 10 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)

        $res.StatusCode = $status
        $res.ContentType = "application/json"
        $res.ContentEncoding = [Text.Encoding]::UTF8
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
    }
}
finally {
    Write-Host ""
    Write-Host "Shutting down..." -ForegroundColor Yellow
    $listener.Stop()
    $listener.Close()
}
