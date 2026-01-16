# ScreenConnect Migration - Configuration
# Copy this file to config.ps1 and fill in your values
# DO NOT commit config.ps1 to source control

@{
    # HTTP listener settings
    ListenPrefix = "http://+:38080/"
    IntakePath   = "/api/v1/sc/intake"
    DataDir      = "C:\SCMigrate\Data"

    # Test mode: $true = log only, $false = send commands to devices
    TestMode = $true

    # Target ScreenConnect instance (where devices will be migrated TO)
    TargetBaseUrl = "https://new-instance.screenconnect.com"

    # Source instances - map by IP address
    # The webhook will come from these IPs, allowing us to identify which instance sent it
    # Get the IP by resolving: [System.Net.Dns]::GetHostAddresses("your-instance.screenconnect.com")
    SourceInstances = @{
        # "SOURCE_IP_1" = @{
        #     Instance   = "instance1"
        #     BaseUrl    = "https://instance1.screenconnect.com"
        #     ExtGuid    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # RESTful API Manager extension GUID
        #     CtrlSecret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # RESTfulAuthenticationSecret value
        # }
        # "SOURCE_IP_2" = @{
        #     Instance   = "instance2"
        #     BaseUrl    = "https://instance2.screenconnect.com"
        #     ExtGuid    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        #     CtrlSecret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        # }
    }
}
