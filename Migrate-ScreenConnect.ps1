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
$requiredKeys = @("ListenPrefix", "IntakePath", "DataDir", "TargetBaseUrl", "SourceInstances")
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
$IntakePath      = $Config.IntakePath
$DataDir         = $Config.DataDir
$TestMode        = $Config.TestMode -eq $true
$TargetBaseUrl   = $Config.TargetBaseUrl.TrimEnd('/')
$ScConfigByIP    = $Config.SourceInstances

# Ensure data directory exists
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$LogFile = Join-Path $DataDir "migration.log"

#region Functions

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
    if ($req.ContentLength64 -gt 1048576) { throw "Body too large" }
    $sr = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
    $body = $sr.ReadToEnd()
    $sr.Close()
    return $body
}

function Is-ValidPayload($p) {
    if (-not ($p.PSObject.Properties.Name -contains "SessionID")) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$p.SessionID)) { return $false }
    return $true
}

function Build-InstallerUrl([string]$baseUrl, [string]$name, [string[]]$customProperties) {
    $url = "$baseUrl/Bin/ScreenConnect.ClientSetup.exe?e=Access&y=Guest"
    $url += "&t=$([uri]::EscapeDataString($name))"
    foreach ($cp in $customProperties) {
        $url += "&c=$([uri]::EscapeDataString($cp))"
    }
    return $url
}

#endregion

# Start listener
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($ListenPrefix)
$listener.Start()

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " ScreenConnect Migration Receiver" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Listening: $ListenPrefix"
Write-Host "Endpoint:  $IntakePath"
Write-Host "Target:    $TargetBaseUrl"
Write-Host "Log:       $LogFile"
Write-Host "Test Mode: $TestMode"
Write-Host "Sources:   $($ScConfigByIP.Keys -join ', ')"
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

        try {
            $raw = Read-Body $req

            # Validate source IP
            $sourceIP = $req.RemoteEndPoint.Address.ToString()
            if (-not $ScConfigByIP.ContainsKey($sourceIP)) {
                $status = 403
                throw "Rejected: Unknown source IP '$sourceIP'"
            }

            # Get config for this source instance
            $cfg = $ScConfigByIP[$sourceIP]
            $instanceKey = $cfg.Instance

            # Route validation
            if ($req.HttpMethod -ne "POST") { $status = 405; throw "Method not allowed" }
            if ($req.Url.AbsolutePath -ne $IntakePath) { $status = 404; throw "Not found" }
            if ([string]::IsNullOrWhiteSpace($raw)) { $status = 400; throw "Empty body" }

            $payload = $raw | ConvertFrom-Json -ErrorAction Stop
            if (-not (Is-ValidPayload $payload)) { $status = 400; throw "Missing required field: SessionID" }

            # Extract session data
            $sessionId   = [string]$payload.SessionID
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
                Sc-SetCustomProperty $scBase $scHeaders $sessionId 7 "MIG:SENT:$(Get-Date -Format 'yyyyMMddHHmmss')"

                # Send install command to device
                $cmd = @"
#!ps #timeout=300000
`$ErrorActionPreference = "Stop"
`$installerUrl = "$installerUrl"
`$installerPath = "`$env:TEMP\ScreenConnect.ClientSetup.exe"
Write-Host "Downloading ScreenConnect installer..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri `$installerUrl -OutFile `$installerPath -UseBasicParsing
Write-Host "Running installer..."
Start-Process -FilePath `$installerPath -ArgumentList "/silent" -Wait
Remove-Item -Path `$installerPath -Force -ErrorAction SilentlyContinue
Write-Host "Migration complete"
"@
                Sc-SendCommand $scBase $scHeaders $sessionId $cmd
                $outObj = @{ ok = $true; action = "sent"; sessionId = $sessionId; instance = $instanceKey }
            }
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ERROR | $errMsg" -ForegroundColor Red
            $outObj = @{ ok = $false; error = $errMsg }
            if ($status -eq 200) { $status = 500 }
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
