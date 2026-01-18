# ScreenConnect Migration - Configuration
# Copy this file to config.ps1 and fill in your values
# DO NOT commit config.ps1 to source control

@{
    # HTTP listener settings
    ListenPrefix   = "http://+:38080/"
    IntakeBasePath = "/api/v1/sc/intake"  # Endpoints will be /api/v1/sc/intake/{instance}
    DataDir        = "C:\SCMigrate\Data"

    # Test mode: $true = log only, $false = send commands to devices
    TestMode = $true

    # Target ScreenConnect instance (where devices will be migrated TO)
    TargetBaseUrl = "https://new-instance.screenconnect.com"

    # Source instances - keyed by instance name (used in URL path)
    # Each instance gets its own endpoint: /api/v1/sc/intake/{instance}
    # Configure your ScreenConnect automation to POST to that URL
    SourceInstances = @{
        # "instance1" = @{
        #     BaseUrl    = "https://instance1.screenconnect.com"
        #     ExtGuid    = "2d558935-686a-4bd0-9991-07539f5fe749"  # RESTful API Manager extension GUID
        #     CtrlSecret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # RESTfulAuthenticationSecret value
        # }
        # "instance2" = @{
        #     BaseUrl    = "https://instance2.screenconnect.com"
        #     ExtGuid    = "2d558935-686a-4bd0-9991-07539f5fe749"
        #     CtrlSecret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        # }
    }
}
