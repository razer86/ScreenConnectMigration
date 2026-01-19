<#
.SYNOPSIS
    Compare devices between source and target ScreenConnect instances

.DESCRIPTION
    Queries both source and target instances via RESTful API Manager to identify
    devices that exist in source but not in target.

    Matching is based on a device fingerprint generated from:
    - Name (session name)
    - GuestNetworkAddress
    - GuestClientVersion

    Note: Hardware fields (GuestMachineName, GuestMachineSerialNumber, GuestMachineModel)
    are not available via RESTful API Manager, so we use the above combination which
    provides reliable matching even though SessionIDs differ between instances.

    Optionally, can push installation commands to missing devices that are online.
    This sets CustomProperty8 to "MIG:MANUAL" to track manual migrations.

.PARAMETER SourceInstance
    Branch code of the source instance (must match exactly a key in config.ps1 SourceInstances, e.g., "CAPC", "WBIT")

.PARAMETER OutputFile
    Optional path to export missing devices to CSV

.PARAMETER Push
    Push installation to missing online devices

.PARAMETER RateLimitSeconds
    Seconds to wait between each push (default: 5)

.PARAMETER MaxPushCount
    Maximum devices to push in one session (default: 50)

.EXAMPLE
    .\Compare-Devices.ps1 -SourceInstance CAPC
    Compare devices and show missing list

.EXAMPLE
    .\Compare-Devices.ps1 -SourceInstance WBIT -OutputFile missing.csv
    Compare and export missing devices to CSV

.EXAMPLE
    .\Compare-Devices.ps1 -SourceInstance CAPC -Push
    Compare and push installation to online missing devices

.EXAMPLE
    .\Compare-Devices.ps1 -SourceInstance WBIT -Push -RateLimitSeconds 10 -MaxPushCount 20
    Push with custom rate limiting (10 sec delay, max 20 devices)

.NOTES
    Requires: RESTful API Manager extension on both source AND target instances
    Author: https://github.com/razer86

.LINK
    https://github.com/razer86/ScreenConnectMigration
#>

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.ps1"),
    [string]$SourceInstance,  # Branch code matching config.ps1 key (e.g., "CAPC", "WBIT")
    [string]$OutputFile,      # Optional: export missing devices to CSV
    [switch]$Push,            # Push installation to missing online devices
    [int]$RateLimitSeconds = 5,   # Seconds between each push (rate limiting)
    [int]$MaxPushCount = 50       # Maximum devices to push in one session
)

function Get-DeviceFingerprint {
    param($Session)

    # Combine available identifiers into a consistent string
    # Note: Hardware fields (GuestMachineName, GuestMachineSerialNumber, GuestMachineModel)
    # are not available via RESTful API Manager, so we use Name + Network + ClientVersion
    $parts = @(
        ($Session.Name ?? "").Trim().ToLower()
        ($Session.GuestNetworkAddress ?? "").Trim().ToLower()
        ($Session.GuestClientVersion ?? "").Trim().ToLower()
    )

    $combined = $parts -join "|"

    # Generate MD5 hash as fingerprint
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    $hash = $md5.ComputeHash($bytes)
    $fingerprint = [System.BitConverter]::ToString($hash) -replace '-', ''

    return $fingerprint.ToLower()
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

function Test-SessionOnline([string]$scBase, [hashtable]$scHeaders, [string]$SessionId) {
    $details = Sc-GetDetails $scBase $scHeaders $SessionId
    return $details.Session.GuestConnectedCount -gt 0
}

# Load configuration
if (-not (Test-Path $ConfigPath)) {
    Write-Host "Configuration file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}

$Config = & $ConfigPath

# Validate source instance
if (-not $SourceInstance) {
    Write-Host "Available source instances:" -ForegroundColor Cyan
    foreach ($inst in $Config.SourceInstances.Keys) {
        Write-Host "  - $inst"
    }
    Write-Host ""
    Write-Host "Usage: .\Compare-Devices.ps1 -SourceInstance <name> [-OutputFile <path.csv>]" -ForegroundColor Yellow
    exit 1
}

if (-not $Config.SourceInstances.ContainsKey($SourceInstance)) {
    Write-Host "Unknown source instance: $SourceInstance" -ForegroundColor Red
    Write-Host "Available: $($Config.SourceInstances.Keys -join ', ')"
    exit 1
}

# Check if target has RESTful API config
if (-not $Config.TargetExtGuid -or -not $Config.TargetCtrlSecret) {
    Write-Host "Target instance RESTful API not configured." -ForegroundColor Red
    Write-Host "Add TargetExtGuid and TargetCtrlSecret to config.ps1" -ForegroundColor Yellow
    exit 1
}

$sourceCfg = $Config.SourceInstances[$SourceInstance]
$targetUrl = $Config.TargetBaseUrl.TrimEnd('/')

# Build API endpoints
$sourceBase = "$($sourceCfg.BaseUrl.TrimEnd('/'))/App_Extensions/$($sourceCfg.ExtGuid)/Service.ashx"
$sourceHeaders = @{
    "CTRLAuthHeader" = $sourceCfg.CtrlSecret
    "Origin"         = $sourceCfg.BaseUrl.TrimEnd('/')
}

$targetBase = "$targetUrl/App_Extensions/$($Config.TargetExtGuid)/Service.ashx"
$targetHeaders = @{
    "CTRLAuthHeader" = $Config.TargetCtrlSecret
    "Origin"         = $targetUrl
}

function Get-AllSessions {
    param(
        [string]$ApiBase,
        [hashtable]$Headers,
        [string]$Label
    )

    Write-Host "Fetching sessions from $Label..." -ForegroundColor Cyan

    try {
        # GetSessionsByFilter with filter for Access sessions
        # Parameters: sessionFilter (string) - SQL-like filter expression
        $body = '["SessionType = ''Access''"]'
        $sessions = Invoke-RestMethod -Method Get -Uri "$ApiBase/GetSessionsByFilter" -Headers $Headers -ContentType "application/json" -Body $body -ErrorAction Stop

        Write-Host "  Found $($sessions.Count) sessions" -ForegroundColor Green

        <# Debug: show first session's fields
        if ($sessions.Count -gt 0) {
            Write-Host "  Sample session fields:" -ForegroundColor Magenta
            $first = $sessions[0]
            $first.PSObject.Properties | ForEach-Object {
                $val = if ($_.Value) { $_.Value.ToString().Substring(0, [Math]::Min(50, $_.Value.ToString().Length)) } else { "(null)" }
                Write-Host "    $($_.Name): $val" -ForegroundColor DarkGray
            }
        }#>

        return $sessions
    }
    catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

# Fetch sessions from both instances
$sourceSessions = Get-AllSessions -ApiBase $sourceBase -Headers $sourceHeaders -Label "source ($SourceInstance)"
$targetSessions = Get-AllSessions -ApiBase $targetBase -Headers $targetHeaders -Label "target"

if ($sourceSessions.Count -eq 0) {
    Write-Host "No sessions found in source instance." -ForegroundColor Yellow
    exit 0
}

# Build lookup of target devices by fingerprint
Write-Host "Building device fingerprints..." -ForegroundColor Cyan
$targetFingerprints = @{}
foreach ($session in $targetSessions) {
    $fp = Get-DeviceFingerprint $session
    $targetFingerprints[$fp] = $session
}

# Find missing devices
$missing = @()
$found = 0

foreach ($session in $sourceSessions) {
    $fp = Get-DeviceFingerprint $session

    if ($targetFingerprints.ContainsKey($fp)) {
        $found++
    }
    else {
        $missing += [PSCustomObject]@{
            SessionID              = $session.SessionID
            Name                   = $session.Name
            GuestNetworkAddress    = $session.GuestNetworkAddress
            GuestClientVersion     = $session.GuestClientVersion
            CustomProperty1        = $session.CustomPropertyValues[0]
            CustomProperty2        = $session.CustomPropertyValues[1]
            CustomProperty8        = $session.CustomPropertyValues[7]
            LastConnected          = $session.GuestLastActivityTime
            Fingerprint            = $fp
        }
    }
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Comparison Results" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Source sessions:  $($sourceSessions.Count)"
Write-Host "Target sessions:  $($targetSessions.Count)"
Write-Host "Already migrated: $found" -ForegroundColor Green
Write-Host "Missing:          $($missing.Count)" -ForegroundColor $(if ($missing.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "----------------------------------------"

if ($missing.Count -gt 0) {
    # Show first 20 missing
    $showCount = [Math]::Min(20, $missing.Count)
    Write-Host ""
    Write-Host "Missing devices (first $showCount):" -ForegroundColor Yellow

    foreach ($device in $missing | Select-Object -First $showCount) {
        $cp1 = if ($device.CustomProperty1) { " | $($device.CustomProperty1)" } else { "" }
        Write-Host "  $($device.Name)$cp1"
    }

    if ($missing.Count -gt 20) {
        Write-Host "  ... and $($missing.Count - 20) more"
    }

    # Export to CSV if requested
    if ($OutputFile) {
        $missing | Export-Csv -Path $OutputFile -NoTypeInformation
        Write-Host ""
        Write-Host "Exported to: $OutputFile" -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "Tip: Use -OutputFile to export full list to CSV" -ForegroundColor DarkGray
    }

    # Push installation to missing devices if requested
    if ($Push) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Magenta
        Write-Host " Manual Push Mode" -ForegroundColor Magenta
        Write-Host "========================================" -ForegroundColor Magenta
        Write-Host "Rate limit: 1 device per $RateLimitSeconds seconds"
        Write-Host "Max devices: $MaxPushCount"
        Write-Host "----------------------------------------"

        $targetUrl = $Config.TargetBaseUrl.TrimEnd('/')
        $pushCount = 0
        $skippedOffline = 0
        $skippedAlreadyMigrating = 0
        $errors = 0

        foreach ($device in $missing) {
            if ($pushCount -ge $MaxPushCount) {
                Write-Host ""
                Write-Host "Reached maximum push count ($MaxPushCount). Stopping." -ForegroundColor Yellow
                break
            }

            $sessionId = $device.SessionID
            $sessionName = $device.Name
            $cp1 = $device.CustomProperty1
            $cp8 = $device.CustomProperty8
            $timeShort = (Get-Date).ToString("HH:mm:ss")

            # Skip if already marked as migrating
            if ($cp8 -like "MIG:*") {
                $skippedAlreadyMigrating++
                $line = "[$timeShort] " + "SKIP".PadRight(8) + "| " + $sessionName.PadRight(24) + "| Already migrating: $cp8"
                Write-Host $line -ForegroundColor DarkGray
                continue
            }

            try {
                # Check if device is online
                $isOnline = Test-SessionOnline $sourceBase $sourceHeaders $sessionId
                if (-not $isOnline) {
                    $skippedOffline++
                    $line = "[$timeShort] " + "OFFLINE".PadRight(8) + "| " + $sessionName.PadRight(24) + "| $cp1"
                    Write-Host $line -ForegroundColor DarkGray
                    continue
                }

                # Build installer URL with session name and custom properties
                # CP1=Company, CP2=Site, CP3=Name, CP4=empty, CP5=SourceBranch, CP6-8=empty
                $details = Sc-GetDetails $sourceBase $sourceHeaders $sessionId
                $cp = @($details.Session.CustomPropertyValues)
                $installerUrl = "$targetUrl/Bin/ScreenConnect.ClientSetup.exe?e=Access&y=Guest"
                $installerUrl += "&c=$([Uri]::EscapeDataString($cp[0]))"   # CP1 - Company
                $installerUrl += "&c=$([Uri]::EscapeDataString($cp[1]))"   # CP2 - Site
                $installerUrl += "&c=$([Uri]::EscapeDataString($sessionName))"  # CP3 - Name
                $installerUrl += "&c="                                      # CP4 - empty
                $installerUrl += "&c=$([Uri]::EscapeDataString($SourceInstance))" # CP5 - Source branch
                $installerUrl += "&c=&c=&c="                               # CP6-8 - empty

                # Mark as manual migration
                Sc-SetCustomProperty $sourceBase $sourceHeaders $sessionId 7 "MIG:MANUAL"

                # Build and send the install command
                $cmd = @"
#!ps
#timeout=900000
`$ErrorActionPreference = "Stop"
`$installerUrl = "$installerUrl"
`$installerPath = "`$env:TEMP\ScreenConnect.ClientSetup.exe"

try {
    Write-Host "Downloading ScreenConnect installer..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri `$installerUrl -OutFile `$installerPath -UseBasicParsing

    Write-Host "Running installer..."
    `$process = Start-Process -FilePath `$installerPath -ArgumentList "/silent" -Wait -PassThru

    Remove-Item -Path `$installerPath -Force -ErrorAction SilentlyContinue

    if (`$process.ExitCode -eq 0) {
        Write-Host "Migration complete"
    } else {
        Write-Host "Installer exited with code: `$(`$process.ExitCode)"
    }
} catch {
    Write-Host "Migration failed: `$(`$_.Exception.Message)"
}
"@
                Sc-SendCommand $sourceBase $sourceHeaders $sessionId $cmd

                $pushCount++
                $line = "[$timeShort] " + "PUSHED".PadRight(8) + "| " + $sessionName.PadRight(24) + "| $cp1"
                Write-Host $line -ForegroundColor Green

                # Rate limit - wait before next push (unless this was the last one)
                if ($pushCount -lt $MaxPushCount -and $pushCount -lt ($missing.Count - $skippedOffline - $skippedAlreadyMigrating)) {
                    Start-Sleep -Seconds $RateLimitSeconds
                }
            }
            catch {
                $errors++
                $line = "[$timeShort] " + "ERROR".PadRight(8) + "| " + $sessionName.PadRight(24) + "| $($_.Exception.Message)"
                Write-Host $line -ForegroundColor Red
            }
        }

        # Push summary
        Write-Host ""
        Write-Host "----------------------------------------"
        Write-Host "Push Summary:" -ForegroundColor Cyan
        Write-Host "  Pushed:           $pushCount" -ForegroundColor Green
        Write-Host "  Skipped (offline): $skippedOffline" -ForegroundColor DarkGray
        Write-Host "  Skipped (already): $skippedAlreadyMigrating" -ForegroundColor DarkGray
        Write-Host "  Errors:           $errors" -ForegroundColor $(if ($errors -gt 0) { "Red" } else { "DarkGray" })
    }
    else {
        Write-Host ""
        Write-Host "Tip: Use -Push to send installation to online missing devices" -ForegroundColor DarkGray
    }
}
else {
    Write-Host ""
    Write-Host "All devices have been migrated!" -ForegroundColor Green
}
