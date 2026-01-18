# ScreenConnect Migration Tool

Migrate devices between ConnectWise ScreenConnect instances while preserving session names and custom properties.

## Background

ScreenConnect's automation system has limitations that make bulk migrations tricky:

- **No custom HTTP headers** - Automations can set URL, method, and body, but not headers for authentication
- **No direct installer execution** - PowerShell works, but running a downloaded `.exe` requires extra steps
- **No session context in scripts** - Devices don't have access to their own session metadata

This tool works around these by reversing the flow: instead of devices pulling config, the server pushes commands to them.

## How It Works

```
Device connects to source ScreenConnect
         ↓
Automation sends session data (webhook) to this receiver
         ↓
Receiver identifies instance from URL path, validates payload
         ↓
Pushes install command back to device via RESTful API
         ↓
Device installs target agent, reports success/failure back
         ↓
Receiver updates CustomProperty8 with final status
```

Each source instance gets its own endpoint (e.g., `/api/v1/sc/intake/instance1`), so you configure the webhook URL in ScreenConnect to identify which instance it's coming from.

## Requirements

**Server (where this script runs):**
- Windows with PowerShell 5.1+
- Port accessible from your ScreenConnect instance(s) AND from devices being migrated

**Source ScreenConnect instance(s):**
- RESTful API Manager extension installed
- Automation configured to send webhooks

**Target ScreenConnect instance:**
- Standard instance where devices will migrate to

## Setup

### 1. Install RESTful API Manager Extension

On each source instance:

1. Go to **Admin > Extensions > Browse Extensions**
2. Install **RESTful API Manager** by ConnectWise Labs
3. Set `RESTfulAuthenticationSecret` in extension settings to a secure value (e.g., a new GUID)
4. Note the extension GUID:
   - **Self-hosted:** Find it in the URL: `/App_Extensions/{GUID}/...`
   - **Cloud-hosted:** The URL isn't accessible, use the standard GUID:
     ```
     2d558935-686a-4bd0-9991-07539f5fe749
     ```

### 2. Configure This Tool

```powershell
git clone https://github.com/razer86/ScreenConnectMigration.git
cd ScreenConnectMigration

cp config.example.ps1 config.ps1
notepad config.ps1
```

Configuration:

```powershell
@{
    ListenPrefix    = "http://+:38080/"
    IntakeBasePath  = "/api/v1/sc/intake"   # Intake: /api/v1/sc/intake/{instance}
    ResultBasePath  = "/api/v1/sc/result"   # Result: /api/v1/sc/result/{instance}
    DataDir         = "C:\SCMigrate\Data"
    CallbackBaseUrl = "http://YOUR_PUBLIC_IP:38080"  # Devices call back here
    TestMode        = $true
    TargetBaseUrl   = "https://target.screenconnect.com"

    SourceInstances = @{
        "source1" = @{
            BaseUrl    = "https://source1.screenconnect.com"
            ExtGuid    = "2d558935-686a-4bd0-9991-07539f5fe749"
            CtrlSecret = "your-RESTfulAuthenticationSecret-value"
        }
    }
}
```

**Important:** `CallbackBaseUrl` must be reachable from the devices being migrated. This is the URL devices use to report installation success/failure.

### 3. Create ScreenConnect Automation

On each source instance, create an automation:

**Trigger:**
- Event Type: `Session Event`
- Event Filter:
  ```
  Event.EventType = 'Connected'
  AND Connection.ProcessType = 'Guest'
  AND Session.GuestOperatingSystemName LIKE '%Windows%'
  ```

**Action:**
- Type: `HTTP Request`
- URL: `http://YOUR_SERVER_IP:38080/api/v1/sc/intake/source1`  ← Use your instance name
- HTTP Method: `POST`
- Content Type: `application/json`
- Body: `{Session:json}`

### 4. Run the Receiver

```powershell
.\Migrate-ScreenConnect.ps1
```

On startup you'll see the configured endpoints:

```
========================================
 ScreenConnect Migration Receiver
========================================
Listening:   http://+:38080/
Callback:    http://111.220.28.125:38080
Target:      https://target.screenconnect.com
Test Mode:   False

Endpoints:
  Intake: /api/v1/sc/intake/source1
  Result: /api/v1/sc/result/source1

Logs:
  Migration: C:\SCMigrate\Data\migration.log
  Results:   C:\SCMigrate\Data\results.log
  Errors:    C:\SCMigrate\Data\errors.log
----------------------------------------
```

## Usage

### Test Mode

With `TestMode = $true`, the receiver logs incoming webhooks but doesn't send commands:

```
[23:41:51] TEST | source1 | LAPTOP001 | abc123-def456 | CP1=Acme Corp
```

### Production Mode

With `TestMode = $false`, the receiver:

1. Updates CustomProperty8 to `MIG:SENT:timestamp`
2. Sends install command to device
3. Device downloads and runs installer
4. Device reports result back to receiver
5. Receiver updates CustomProperty8 to final status

```
[23:41:51] SENT    | source1 | LAPTOP001 | abc123-def456 | CP1=Acme Corp
[23:42:15] SUCCESS | source1 | abc123-def456
```

### Migration Status (CustomProperty8)

The receiver tracks migration progress in CustomProperty8:

| Status | Meaning |
|--------|---------|
| `MIG:SENT` | Install command sent, waiting for result |
| `MIG:SUCCESS` | Installation completed successfully |
| `MIG:FAILED` | Installation failed (check results.log for details) |

These values work well for ScreenConnect Session Groups to organize devices by migration status.

### Filtering Devices

Control which devices get migrated using the automation filter:

```
# Only devices tagged for migration
Session.CustomProperty8 = 'MIGRATE'

# Only a specific company
Session.CustomProperty1 = 'Acme Corp'

# Exclude already-migrated devices
Session.CustomProperty8 NOT LIKE 'MIG:%'
```

## Logs

Three log files are maintained in the data directory:

| File | Contents |
|------|----------|
| `migration.log` | All intake requests (successful migrations initiated) |
| `results.log` | Device callback results (success/failure) |
| `errors.log` | Failed requests (validation errors, unknown instances, etc.) |

All logs are JSON lines format:

```json
{"ts":"2024-01-15T23:41:51.378+10:00","instance":"source1","sessionId":"abc123","success":true,"message":"Installation completed successfully"}
```

## Troubleshooting

**"Unknown instance" error**
- Check the URL path matches an instance key in your config (case-insensitive)
- Verify the automation URL includes the instance name: `/api/v1/sc/intake/yourinstance`

**Commands not executing on devices**
- Check that RESTful API Manager is installed and enabled
- Verify `CtrlSecret` matches your `RESTfulAuthenticationSecret` setting
- Confirm the `ExtGuid` is correct

**Installer download fails**
- Ensure devices can reach the target ScreenConnect URL
- Older machines may need TLS 1.2 enabled

**No callback received (stuck at MIG:SENT)**
- Verify `CallbackBaseUrl` is reachable from the device's network
- Check firewall rules allow inbound connections on your port
- Review the ScreenConnect command output for errors

## Security

- Each instance has its own endpoint, reducing misconfiguration risk
- API secrets stay on the server, never sent in requests
- Payload validation ensures only valid ScreenConnect session data is processed
- Consider using a reverse proxy with HTTPS for production

## License

MIT License - See [LICENSE](LICENSE) for details.
