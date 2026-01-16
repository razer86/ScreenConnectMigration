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
Receiver validates source IP, builds installer URL for target instance
         ↓
Pushes install command back to device via RESTful API
         ↓
Device installs target agent with same name and custom properties
```

Authentication works by validating the source IP of incoming webhooks against your configured ScreenConnect server IPs.

## Requirements

**Server (where this script runs):**
- Windows with PowerShell 5.1+
- Port accessible from your ScreenConnect instance(s)

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
    ListenPrefix  = "http://+:38080/"
    IntakePath    = "/api/v1/sc/intake"
    DataDir       = "C:\SCMigrate\Data"
    TestMode      = $true
    TargetBaseUrl = "https://target.screenconnect.com"

    SourceInstances = @{
        "51.161.218.179" = @{
            Instance   = "source1"
            BaseUrl    = "https://source1.screenconnect.com"
            ExtGuid    = "2d558935-686a-4bd0-9991-07539f5fe749"
            CtrlSecret = "your-RESTfulAuthenticationSecret-value"
        }
    }
}
```

To find your ScreenConnect server's public IP:
For Cloud Hosted this is available at **Admin > Overview > Browser URL Check**

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
- URL: `http://YOUR_SERVER_IP:38080/api/v1/sc/intake`
- HTTP Method: `POST`
- Content Type: `application/json`
- Body: `{Session:json}`

### 4. Run the Receiver

```powershell
.\Migrate-ScreenConnect.ps1
```

## Usage

### Test Mode

With `TestMode = $true`, the receiver logs incoming webhooks but doesn't send commands:

```
[23:41:51] TEST | source1 | LAPTOP001 | abc123-def456 | CP1=Acme Corp
```

### Production Mode

With `TestMode = $false`, the receiver:
- Updates CustomProperty8 on the source to `MIG:SENT:timestamp`
- Sends the install command to the device

```
[23:41:51] SENT | source1 | LAPTOP001 | abc123-def456 | CP1=Acme Corp
```

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

Events are logged to `{DataDir}/migration.log` as JSON lines:

```json
{"ts":"2024-01-15T23:41:51.378+10:00","instance":"source1","sessionId":"abc123","sessionName":"LAPTOP001","cp1":"Acme Corp",...}
```

## Troubleshooting

**"Unknown source IP" error**
- Verify the IP in config matches your ScreenConnect server. Cloud instances may resolve to unexpected IPs.

**Commands not executing on devices**
- Check that RESTful API Manager is installed and enabled
- Verify `CtrlSecret` matches your `RESTfulAuthenticationSecret` setting
- Confirm the `ExtGuid` is correct

**Installer download fails**
- Ensure devices can reach the target ScreenConnect URL
- Older machines may need TLS 1.2 enabled

## Security

- Requests are validated by source IP
- API secrets stay on the server, never sent in requests
- Consider using a reverse proxy with HTTPS for production

## License

MIT License - See [LICENSE](LICENSE) for details.
