<#
.SYNOPSIS
    Template: Signed PowerShell script with logging, WhatIf support, and structured main flow.

.DESCRIPTION
    This script is designed as a reusable template for signed scripts.
    It includes:
      - Standard logging to a file (default: same directory, same basename + .log)
      - Admin check
      - WhatIf and Verbose support via CmdletBinding
      - Structured main function
      - A concrete implementation of "patch Windows device" as CUSTOM LOGIC

    Replace the CUSTOM LOGIC region with other automation while keeping the template structure.

.PARAMETER LogPath
    Optional path to the log file. If not specified, a .log file with the same name
    as the script is created in the same directory.

.PARAMETER SkipCleanup
    Skip legacy WSUS/GPO cleanup step.

.PARAMETER SkipUpdateInstall
    Skip installing Windows Updates.

.PARAMETER SkipRestartNotification
    Skip configuring restart notifications.

.EXAMPLE
    .\Patch-WindowsDevice.ps1 -Verbose

.EXAMPLE
    .\Patch-WindowsDevice.ps1 -WhatIf

.NOTES
    Run this script with administrative privileges.

    --- CODE SIGNING EXAMPLE ---
    # Get a code-signing certificate (from your Personal store)
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1

    # Sign the script
    Set-AuthenticodeSignature -FilePath "C:\Scripts\Patch-WindowsDevice.ps1" -Certificate $cert
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$LogPath,
    [switch]$SkipCleanup,
    [switch]$SkipUpdateInstall,
    [switch]$SkipRestartNotification
)

#region Core Template: Logging & Utilities

# Global log file path
$script:LogFile = $null

function Initialize-Log {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if (-not $Path) {
        # Derive log path from script file
        try {
            if ($PSScriptRoot) {
                $scriptDir  = $PSScriptRoot
                $scriptFile = $MyInvocation.MyCommand.Name
            }
            else {
                $scriptPath = $MyInvocation.MyCommand.Path
                $scriptDir  = Split-Path -Parent $scriptPath
                $scriptFile = Split-Path -Leaf   $scriptPath
            }

            $scriptBaseName = [System.IO.Path]::GetFileNameWithoutExtension($scriptFile)
            $Path = Join-Path $scriptDir "$scriptBaseName.log"
        }
        catch {
            $Path = Join-Path $env:TEMP "ScriptTemplate.log"
        }
    }

    $script:LogFile = $Path
    # Ensure directory exists
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    # Start log
    $header = "=== Script run started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    Add-Content -Path $script:LogFile -Value $header
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]   # allow empty, we'll filter ourselves
        [string]$Message,

        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )

    # Ignore null/whitespace messages to avoid pointless logging & binding errors
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line      = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message

    # Console output
    switch ($Level) {
        "INFO"  { Write-Host    $line }
        "WARN"  { Write-Warning $line }
        "ERROR" { Write-Error   $line }
    }

    # File output
    if ($script:LogFile) {
        try {
            Add-Content -Path $script:LogFile -Value $line
        }
        catch {
            Write-Warning "Failed to write to log file '$script:LogFile': $_"
        }
    }
}

function Assert-Admin {
    [CmdletBinding()]
    param()

    $currUser  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "This script must be run as Administrator. Exiting." -Level "ERROR"
        throw "Administrator privileges required."
    }
}

#endregion Core Template: Logging & Utilities

#region CUSTOM LOGIC: Patch Windows Device
# Replace this region with other automation logic in future scripts.
# Keep the function names or rename them consistently with Invoke-Main.

function Test-LegacySettings {
    [CmdletBinding()]
    param()

    Write-Log "Step 1: Checking for legacy Group Policy / WSUS settings..."

    $gpCache1Path        = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\GPCache\CacheSet001\WindowsUpdate"
    $gpCache2Path        = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\GPCache\CacheSet002\WindowsUpdate"
    $wsusGpoPath         = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $markerPath          = "HKLM:\SOFTWARE\Intune_Migration\WUfB Local GPO Reset Complete"

    $gpCache1Exists = Test-Path $gpCache1Path
    $gpCache2Exists = Test-Path $gpCache2Path
    $wsusGpoExists  = Test-Path $wsusGpoPath
    $markerExists   = Test-Path $markerPath

    Write-Log " - GPCache CacheSet001 present: $gpCache1Exists"
    Write-Log " - GPCache CacheSet002 present: $gpCache2Exists"
    Write-Log " - WSUS GPO key present:       $wsusGpoExists"
    Write-Log " - Local GPO reset marker:     $markerExists"

    return ($gpCache1Exists -or $gpCache2Exists -or $wsusGpoExists -or $markerExists)
}

function Invoke-LegacyCleanup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Log "Step 2: Legacy configuration detected. Removing legacy Group Policy / WSUS settings..."

    $gpCache1Path        = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\GPCache\CacheSet001\WindowsUpdate"
    $gpCache2Path        = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\GPCache\CacheSet002\WindowsUpdate"
    $wsusGpoPath         = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $migrationMarkerPath = "HKLM:\SOFTWARE\Intune_Migration"
    $migrationMarkerName = "WUfB Local GPO Reset Complete"

    try {
        if ($PSCmdlet.ShouldProcess("Group Policy cache", "Remove legacy cache entries")) {
            if (Test-Path $gpCache1Path) {
                Write-Log " - Removing $gpCache1Path"
                Remove-Item -Path $gpCache1Path -Force -Recurse
            }
            if (Test-Path $gpCache2Path) {
                Write-Log " - Removing $gpCache2Path"
                Remove-Item -Path $gpCache2Path -Force -Recurse
            }
        }

        if ($PSCmdlet.ShouldProcess("WSUS GPO key", "Remove WSUS configuration")) {
            if (Test-Path $wsusGpoPath) {
                Write-Log " - Removing $wsusGpoPath"
                Remove-Item -Path $wsusGpoPath -Force -Recurse
            }
        }

        # Reset local GPO registry settings
        $regPol    = Join-Path $env:windir "system32\GroupPolicy\Machine\Registry.pol"
        $regPolOld = Join-Path $env:windir "system32\GroupPolicy\Machine\Registry.old"

        $regPolExists = Test-Path $regPol

        if ($regPolExists -and $PSCmdlet.ShouldProcess("Registry.pol", "Rename to Registry.old")) {
            Write-Log " - Resetting local machine Registry.pol"

            if (Test-Path $regPolOld) {
                Write-Log "   - Removing existing Registry.old"
                Remove-Item $regPolOld -Force
            }

            Rename-Item -Path $regPol -NewName "Registry.old" -Force
        }
        elseif (-not $regPolExists) {
            Write-Log " - Registry.pol not found; skipping rename."
        }

        # Ensure migration key exists
        if ($PSCmdlet.ShouldProcess("Migration marker key", "Create/Update")) {
            if (-not (Test-Path $migrationMarkerPath)) {
                Write-Log " - Creating migration marker key: $migrationMarkerPath"
                New-Item -Path $migrationMarkerPath -Force | Out-Null
            }

            Write-Log " - Setting migration marker value"
            New-ItemProperty -Path $migrationMarkerPath `
                             -Name $migrationMarkerName `
                             -PropertyType String `
                             -Value "Done" `
                             -Force | Out-Null
        }

        # Restart Windows Update service
        if ($PSCmdlet.ShouldProcess("wuauserv", "Restart Windows Update service")) {
            Write-Log " - Restarting Windows Update (wuauserv) service"
            Stop-Service wuauserv -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Start-Service wuauserv
        }

        # Force Group Policy update
        if ($PSCmdlet.ShouldProcess("Group Policy", "gpupdate /force")) {
            Write-Log " - Running gpupdate /force"
            gpupdate /force | Out-Null
        }

        Write-Log "Legacy WSUS/GPO cleanup completed successfully."
    }
    catch {
        Write-Log "An error occurred during legacy configuration cleanup: $_" -Level "ERROR"
        throw
    }
}

function Invoke-UpdateInstall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Log "Step 3: Installing Windows updates..."

    try {
        if ($PSCmdlet.ShouldProcess("ExecutionPolicy", "Set to Bypass (Process scope)")) {
            Write-Log " - Setting execution policy to Bypass (Process scope)"
            Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
        }

        # Install NuGet provider if needed
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            if ($PSCmdlet.ShouldProcess("NuGet Provider", "Install")) {
                Write-Log " - Installing NuGet package provider"
                Install-PackageProvider -Name NuGet -Force -Confirm:$false
            }
        }
        else {
            Write-Log " - NuGet package provider already installed"
        }

        # Install PSWindowsUpdate module if needed
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            if ($PSCmdlet.ShouldProcess("PSWindowsUpdate module", "Install")) {
                Write-Log " - Installing PSWindowsUpdate module"
                Install-Module PSWindowsUpdate -Force -Confirm:$false
            }
        }
        else {
            Write-Log " - PSWindowsUpdate module already installed"
        }

        Write-Log " - Importing PSWindowsUpdate module"
        Import-Module PSWindowsUpdate -Force

        # Show available updates
        Write-Log " - Checking for available updates (Get-WindowsUpdate)"
        $updates = Get-WindowsUpdate
        $updatesText = $updates | Out-String
        Write-Log "Get-WindowsUpdate output:`n$updatesText"

        # Install software updates
        if ($PSCmdlet.ShouldProcess("Windows Updates", "Install software updates")) {
            Write-Log " - Installing software updates (Install-WindowsUpdate -UpdateType Software -AcceptAll -IgnoreReboot)"
            $installResult = Install-WindowsUpdate -UpdateType Software -AcceptAll -IgnoreReboot
            $installText   = $installResult | Out-String
            Write-Log "Install-WindowsUpdate output:`n$installText"
        }

        Write-Log "Windows updates installation step completed."
    }
    catch {
        Write-Log "An error occurred during update installation: $_" -Level "ERROR"
        throw
    }
}

function Enable-RestartNotification {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Log "Step 4: Enabling restart notifications..."

    try {
        $registryPath  = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
        $propertyName  = "RestartNotificationsAllowed2"
        $propertyValue = 1

        if ($PSCmdlet.ShouldProcess("Restart notification registry", "Create/Update")) {
            if (-not (Test-Path $registryPath)) {
                Write-Log " - Creating registry key: $registryPath"
                New-Item -Path $registryPath -Force | Out-Null
            }

            Write-Log " - Setting $propertyName to $propertyValue"
            Set-ItemProperty -Path $registryPath -Name $propertyName -Value $propertyValue -Type DWord
        }

        Write-Log "Restart notification setting enabled successfully."
    }
    catch {
        Write-Log "An error occurred while configuring restart notifications: $_" -Level "ERROR"
        throw
    }
}

#endregion CUSTOM LOGIC: Patch Windows Device

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    try {
        Initialize-Log -Path $LogPath
        Write-Log "=== Script Template Starting ==="
        Write-Log "Log file: $script:LogFile"

        Assert-Admin

        # 1. Test for legacy settings
        if (-not $SkipCleanup) {
            $needsCleanup = Test-LegacySettings
            if ($needsCleanup) {
                Invoke-LegacyCleanup
            }
            else {
                Write-Log "Step 2: No legacy WSUS/GPO settings detected. Skipping cleanup."
            }
        }
        else {
            Write-Log "SkipCleanup flag set. Skipping legacy WSUS/GPO cleanup."
        }

        # 2. Install updates
        if (-not $SkipUpdateInstall) {
            Invoke-UpdateInstall
        }
        else {
            Write-Log "SkipUpdateInstall flag set. Skipping update installation."
        }

        # 3. Enable restart notifications
        if (-not $SkipRestartNotification) {
            Enable-RestartNotification
        }
        else {
            Write-Log "SkipRestartNotification flag set. Skipping restart notification configuration."
        }

        Write-Log "=== Script Template Completed Successfully ==="
    }
    catch {
        Write-Log "Script terminated with error: $_" -Level "ERROR"
        throw
    }
}

# Entry point
Invoke-Main

# SIG # Begin signature block
# MIIQngYJKoZIhvcNAQcCoIIQjzCCEIsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDq1jd2Vs/ONez0
# Xg4Y08OQKDhO/FoERLMDkTCJ5lP0/aCCDcswggbUMIIEvKADAgECAhNIAAAAA9i5
# mZgo+AJfAAAAAAADMA0GCSqGSIb3DQEBCwUAMBYxFDASBgNVBAMTC1lNVVMgUm9v
# dENBMB4XDTI0MDgwNjE3MjcyM1oXDTM0MDgwNjE3MzcyM1owYDETMBEGCgmSJomT
# 8ixkARkWA2NvbTEcMBoGCgmSJomT8ixkARkWDHlhbWFoYS1tb3RvcjEUMBIGCgmS
# JomT8ixkARkWBHltdXMxFTATBgNVBAMTDElzc3VpbmdDQUtTVzCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBANaIqWNxuGRQHMJ5IYAIXa8GntL6Tgbxb2bk
# WMZ9umS8iP0mV4G1HTIQQnCerNFXmonPoeABpzX2sby4Lb9dB4qMN33B5p84vSFx
# /EOxRVFF4o7p56SnMkyLYQQjh5POSLTd3C/LheTXFbIuh5d3Ht39KJNSERT5VC9y
# UMApif2ra5n+Njmv91N96E0bFkqOz7fhuDHq6hZzncXMO6uudaj4/x25lKpCMz/F
# rsvt5bdbNf+1VtMeP7xQ7fP/mqkmuw+4XYizS6b85+gDiDsxYm9CJkTM8ezdsUm9
# g8qQKx06Z5HwINSAqJHKw+VuO1/soG7c3NiSgX8qoxcnd21GTyxftMycKRW1tF1O
# amokzVsZD8GRj9AummP88Lxzt0gtUO8zS+Msi9UNxMLUGTdPYJa+iyVJcBeHQhJn
# T2WwXhWd2b1z8kBIXhz9NYKGMGpxnwNyGxQl96nSMS6B5z0GiA7BZOqCMudtsN4N
# q3PiCNUy/KEBdP8q1kofQ5MGN0SuPnxeH9/snl42t4DTuaLuzzisnlyVmykPwtIl
# fQWL+VVCi3orm3Igvt8YZZyvnbwgZqE7ZW98t37/mtdI1fId/lRZDYa2e6PJu+x+
# GTBGQIn0JJ/UBsG8R/d+wXBLFuwVXOgeMrOcgJgDjokPeIyK29rOyWGP1b6sgPXR
# /RNiTWLpAgMBAAGjggHPMIIByzAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQU
# 4SnXlPXeSJTcFrdI9iczjQ9ZNigwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEw
# CwYDVR0PBAQDAgGGMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUIKBO
# qNKMXjyjjvq/qCfb9VJEHeswgZEGA1UdHwSBiTCBhjCBg6CBgKB+hj1odHRwOi8v
# cGtpMDEueW11cy55YW1haGEtbW90b3IuY29tL2NlcnRkYXRhL1lNVVMlMjBSb290
# Q0EuY3Jshj1odHRwOi8vUGtpMDIueW11cy55YW1haGEtbW90b3IuY29tL2NlcnRk
# YXRhL1lNVVMlMjBSb290Q0EuY3JsMIGmBggrBgEFBQcBAQSBmTCBljBJBggrBgEF
# BQcwAoY9aHR0cDovL3BraTAxLnltdXMueWFtYWhhLW1vdG9yLmNvbS9jZXJ0ZGF0
# YS9ZTVVTJTIwUm9vdENBLmNydDBJBggrBgEFBQcwAoY9aHR0cDovL3BraTAyLnlt
# dXMueWFtYWhhLW1vdG9yLmNvbS9jZXJ0ZGF0YS9ZTVVTJTIwUm9vdENBLmNydDAN
# BgkqhkiG9w0BAQsFAAOCAgEAKFjio6XwJvcevrwmiPrGig2QZxWTm+xGE9myNo/i
# soBm0QT4Bh6QZ8r0OcGJPeF+TVRxALaeyyGs7sbXXktbwwxUeVFY4eR7rKNWBgVC
# xwi2HVc7rO4hlh/cwz1JGHZWAr7CwCrQOmCBtZxStKZ0bOf5W+P9M29bXJ8ST5nr
# BEMHe6nKByIj7HKWaICTDmhE01tbFo+KSuPcvJkseTiF7BJZj8svsvZIo3PKT2YW
# Bbfv/w7n6OsiV1Q+xlqdo357NXyjcsXlhCtwl9YbzYdr0sdm5jSOgG350rZ9JF/F
# PHsgu3FD8bh9YE0+LIYmUAC4xgE+YJix9jtPQSsD4U6CmvVdI+m0TnziqSs1+fk4
# EciBwp9Vsy5iAM1kloJZ2CU1/J9ySXHjVZOETeiOs/c62K12ZdJAE2BzZ4oBLTII
# SbG2fOTWy4quKtma12FpdS3xg0XfrDeJeql8PKUdDyGHD8WmcqMK1ud/Nn4Z7/xM
# /N7CgbXntxz/ykYlDsGEJMnsEy56Lstlnpmt1oyNg0NMwsGxP8GDxGphkgXPmNdS
# 35OLCNKly8bMC8lU3cQ+EsLTWQwWFSaeK9fif/hIt+ihl8SGcYPXoQJJ6CcuFARh
# D1n853reQgCX0GLLoHahY+Lq3p+PRzO2ADlx/MaAjOUlcYTMCm8xCa8vbClR9C9k
# CnwwggbvMIIE16ADAgECAhM0AAAE3iDxSpjedubvAAAAAATeMA0GCSqGSIb3DQEB
# CwUAMGAxEzARBgoJkiaJk/IsZAEZFgNjb20xHDAaBgoJkiaJk/IsZAEZFgx5YW1h
# aGEtbW90b3IxFDASBgoJkiaJk/IsZAEZFgR5bXVzMRUwEwYDVQQDEwxJc3N1aW5n
# Q0FLU1cwHhcNMjUwNTE0MTkzMTA5WhcNMzAwNTEzMTkzMTA5WjB7MRMwEQYKCZIm
# iZPyLGQBGRYDY29tMRwwGgYKCZImiZPyLGQBGRYMeWFtYWhhLW1vdG9yMRQwEgYK
# CZImiZPyLGQBGRYEeW11czEXMBUGA1UECxMOQm9hdCBDb21wYW5pZXMxFzAVBgNV
# BAMTDk1pY2hhZWwgTmV3bWFuMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
# AQEA0ihY/Xnqf1a+1J3IU47WZQ/K9PS8eGBv/+kFM486+ao4hQLHTK+KGvGu7PSU
# 117OsV1fBLCfFkhmvIa+RyrauSkldSp2E0WzH+l4/ORxpw/VCJo4vtK9eVrVnw3Q
# hptEoOEBZWWBX7Yj477FNQBaE0Vy3qSuHcjheiCFk7yHfcO9Bt5DRvr+cId4Kyz9
# nd+LveLMjx2WCA4EowvM1T97E/KHt9zmejX21qjFHWBIX74aX8ZLcHXvLRyEupX1
# 8lHdXom2VuPIhi/0Y2BGXRPXe3ZrV0zD3R5auzR8+HVf1uFzl/r3Z8d+WhX9nUwB
# 8Za7pACWxx4U8NgT+k0cC6pk3QIDAQABo4IChTCCAoEwPAYJKwYBBAGCNxUHBC8w
# LQYlKwYBBAGCNxUIg7aiaYGEtgCBpZ0thMWbMYfhwBg+gp3FRsG2GQIBZAIBBTAT
# BgNVHSUEDDAKBggrBgEFBQcDAzAOBgNVHQ8BAf8EBAMCB4AwGwYJKwYBBAGCNxUK
# BA4wDDAKBggrBgEFBQcDAzAdBgNVHQ4EFgQUCtw6XwdeUueSxZSwwXz7q3zU89Iw
# HwYDVR0jBBgwFoAU4SnXlPXeSJTcFrdI9iczjQ9ZNigwgY4GA1UdHwSBhjCBgzCB
# gKB+oHyGPGh0dHA6Ly9wa2kwMS55bXVzLnlhbWFoYS1tb3Rvci5jb20vY2VydGRh
# dGEvSXNzdWluZ0NBS1NXLmNybIY8aHR0cDovL3BraTAyLnltdXMueWFtYWhhLW1v
# dG9yLmNvbS9jZXJ0ZGF0YS9Jc3N1aW5nQ0FLU1cuY3JsMIGkBggrBgEFBQcBAQSB
# lzCBlDBIBggrBgEFBQcwAoY8aHR0cDovL3BraTAxLnltdXMueWFtYWhhLW1vdG9y
# LmNvbS9DZXJ0RGF0YS9Jc3N1aW5nQ0FLU1cuY3J0MEgGCCsGAQUFBzAChjxodHRw
# Oi8vcGtpMDIueW11cy55YW1haGEtbW90b3IuY29tL0NlcnREYXRhL0lzc3VpbmdD
# QUtTVy5jcnQwOAYDVR0RBDEwL6AtBgorBgEEAYI3FAIDoB8MHXNrdG1hbjFAeW11
# cy55YW1haGEtbW90b3IuY29tME0GCSsGAQQBgjcZAgRAMD6gPAYKKwYBBAGCNxkC
# AaAuBCxTLTEtNS0yMS0zOTM0MzAzNy04MTY1MzQwMDktMTI0Njg0NTQ2NS01NjM0
# NTANBgkqhkiG9w0BAQsFAAOCAgEAa9Jy9KY5TaMKp1zz/Dz78+1fl/oHX3TSvkZ8
# eSUxa99PFvbcy4f0ZF2f1ALeiswGAAxlcIYLasilVRqo0akfZ//AIbiX1Ot/yIvV
# O+5fYR/3mgpYHPyQOk9ErVG4jiljy+nCDHvPoZJmSwLa64G2FCLKOe862b75koD2
# codvAjhCwNeV0HVMNAVMs0HbtoqewPLvCU6OfowXrsvofMqZwgxAzvEthz8YG6Ag
# 3nSSgzbpwpHzRPqNWpeNKDH2c8tWL7oFEjZn5fnu2NbasDGxha2NIEn9lpfXykxf
# Yr4jUIZNY7r4seCvCQaEwH5BUkb6Y6vH4q9quiY4/tNXxjPH9fQPlhLOVCUpygxn
# KTHUp90OvoZhuRBiRLJaUcr1pdh0aTqTBUDbzk55GUX2X5BJyrwB3iPskg2QiH9e
# SHQlBO8MHaXMjbJOGmPq34jqTdEDmZ9GSCx5EyDIPqpMXsEIhwAyNLShKM7Aw1qI
# 2n8Qfh6egC2f5XsrkC8crmKAYkVVvdS+0lUKcSXge1B88EwiDO4za25FAtAdZdwi
# FYep43FVhgH4Hu4ezdAGc/k73hMvdT4tDtgwC+Wninlfz48rppX6rJ2OGmfiJU/J
# QMutzzk4QjEhWODSBCSDj2an9vO1W120bgW8QWhs6Frgi05VqhgnfWI4RMEzIG3H
# NbanqysxggIpMIICJQIBATB3MGAxEzARBgoJkiaJk/IsZAEZFgNjb20xHDAaBgoJ
# kiaJk/IsZAEZFgx5YW1haGEtbW90b3IxFDASBgoJkiaJk/IsZAEZFgR5bXVzMRUw
# EwYDVQQDEwxJc3N1aW5nQ0FLU1cCEzQAAATeIPFKmN525u8AAAAABN4wDQYJYIZI
# AWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0B
# CQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAv
# BgkqhkiG9w0BCQQxIgQgokHdgRBNMR5iX+ep6gXvkt5YhIKEATb4rpWupU/hlRUw
# DQYJKoZIhvcNAQEBBQAEggEAscksj8vJ9Q9auukGBumR+OxsHk5fjbIHAyke6Ia0
# F0oLx8/YRRMx+stNrHRCuVyd1Jf+yeGhbfUj33A5BiYLVAoEBbthiOsRDvHk10/o
# +DMArTiXqSTRB/V7cki1gxcFuURve7BVVxfHTip40Qr3VSvKvWWtQHbCkJRLWJWI
# 5k/WlPh3zGqSJxD/VZ3LEmjF2GEZKtVwOo2sTkodWXH7Z861NB3vPjQFiG9C6zrm
# CiMCPQDd+0KzUICotFzn1cJF/q+J5TGxBVX49RNyD0fFRI8wtrR3bgrcoquVa9uJ
# mOwVoPQ6gm4N+dMSe8UbR8svzbE0rcof/ART2kN87KQ6Og==
# SIG # End signature block
