# Repair-AzVMDisk

Offline Azure VM disk repair and diagnostic script for use on a Hyper-V rescue VM.

Repair-AzVMDisk attaches the OS disk of a broken Azure VM to a Hyper-V rescue VM and performs offline repairs **without booting the guest**. It can mount offline registry hives, run chkdsk/SFC/DISM, rebuild BCD, fix RDP/NLA settings, manage drivers and services, reset credentials, collect diagnostic information, and much more.

> **⚠️ Disclaimer**
>
> The sample scripts are not supported under any Microsoft standard support program or service. The sample scripts are provided AS IS without warranty of any kind. Microsoft further disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose. The entire risk arising out of the use or performance of the sample scripts and documentation remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the scripts be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the sample scripts or documentation, even if Microsoft has been advised of the possibility of such damages.

## Prerequisites

- Must be run **as Administrator** on the Hyper-V rescue VM.
- The broken VM's OS disk must be attached to the rescue VM (either as a disk passthrough or via Hyper-V).
- Tested on Windows Server 2016 / 2019 / 2022 rescue environments.
- PowerShell 5.1 or later.

## Quick Start

Identify the disk number of the attached broken VM disk:

```powershell
Get-Disk
```

Then run a full diagnostic check:

```powershell
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -SysCheck
```

You can also target a Hyper-V VM by name instead of disk number:

```powershell
.\Repair-AzVMDisk.ps1 -VMName "BrokenVM" -SysCheck
```

## Usage Examples

### Diagnostics & Analysis

```powershell
# Full system check — inspects disk health, boot config, RDP/NLA, Windows Update/CBS,
# credential guard, network bindings, Azure VM agent, and more
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -SysCheck

# Check disk health (SMART-like status)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -CheckDiskHealth

# Analyze boot path and report on all boot-critical files
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -AnalyzeCriticalBootFiles

# Get a boot path report showing every component in the boot chain
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -GetBootPathReport

# Analyze BCD store consistency
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -AnalyzeBcdConsistency

# Analyze the component store (WinSxS) for corruption
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -AnalyzeComponentStore

# Analyze Windows servicing state (pending operations, reboot flags)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -AnalyzeServicingState

# Check Hyper-V synthetic drivers (storvsc, netvsc, vmbus, etc.)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -AnalyzeSyntheticDrivers

# Analyze proxy configuration
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -AnalyzeProxyState

# Analyze domain trust state
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -AnalyzeDomainTrustState

# Check registry hive health
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -CheckRegistryHealth
```

### Boot Repair

```powershell
# Rebuild BCD (Boot Configuration Data)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixBoot

# Fix boot sector (MBR/VBR repair)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixBootSector

# Recreate the entire boot partition (Gen1 or Gen2/UEFI)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RecreateBootPartition

# Full Gen2 / UEFI boot repair
# -RecreateBootPartition exits without deleting/recreating if the EFI System Partition already exists.
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RecreateBootPartition
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixBoot
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixSecureBootCodeIntegrity

# Full Gen1 / BIOS-MBR boot repair
# -RecreateBootPartition exits without deleting/recreating if a valid Active boot partition already exists.
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RecreateBootPartition
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixBoot
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixBootSector

# Try Last Known Good Configuration
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -TryLGKC

# Boot into Safe Mode on next start
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -TrySafeMode

# Remove Safe Mode flag (return to normal boot)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RemoveSafeModeFlag

# Enable boot logging (ntbtlog.txt)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableBootLog

# Disable/enable automatic startup repair
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableStartupRepair
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableStartupRepair
```

### File System & Component Store Repair

```powershell
# Run chkdsk on a specific partition (disk stays online for drive letter access)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixNTFS -DriveLetter H: -LeaveDiskOnline

# Run SFC (System File Checker) offline
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RunSFC

# Repair component store (DISM RestoreHealth offline)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RepairComponentStore

# Repair component store using a known-good source image
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RepairComponentStore -RepairSource "D:\sources\install.wim"

# Repair a specific broken system file from the WinSxS store
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RepairSystemFile "ntoskrnl.exe","ci.dll"

# Fix registry corruption
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixRegistryCorruption

# Restore registry from RegBack folder
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RestoreRegistryFromRegBack
```

### RDP & Remote Access

```powershell
# Fix common RDP settings (listener, port, firewall rules)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixRDP

# Disable NLA (Network Level Authentication) — useful when certs/trust are broken
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableNLA

# Re-enable NLA
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableNLA

# Fix RDP certificate issues
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixRDPCert

# Fix RDP private key permissions
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixRDPPermissions

# Fix RDP authentication settings
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixRDPAuth

# Check all RDP-related policies
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -CheckRDPPolicies

# Enable WinRM HTTPS
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableWinRMHTTPS

# Enable Serial Console access
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableSerialConsole
```

### Credentials & User Management

```powershell
# Reset a local administrator password
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -ResetLocalAdminPassword

# Create a temporary admin user for emergency access
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -AddTempUser

# Fix user rights assignments
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixUserRights
```

### Drivers & Services

```powershell
# Disable a specific problematic driver or service
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableDriverOrService "driver1","service2"

# Re-enable a previously disabled driver or service
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableDriverOrService "driver1" -DriverStartType System

# Disable all third-party (non-Microsoft) drivers
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableThirdPartyDrivers

# Re-enable previously disabled third-party drivers
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableThirdPartyDrivers

# Get a report of all services and drivers (filter to issues only)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -GetServicesReport -IssuesOnly

# Ensure Hyper-V synthetic drivers are enabled (storvsc, netvsc, etc.)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnsureSyntheticDriversEnabled

# Disable/enable Driver Verifier
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableDriverVerifier
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableDriverVerifier "nt*"
```

### Security & Policy

```powershell
# Disable Credential Guard
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableCredentialGuard

# Enable Credential Guard
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableCredentialGuard

# Disable AppLocker (if it's blocking boot or login)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableAppLocker

# Get AppLocker configuration report
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -GetAppLockerReport

# Reset Group Policy to defaults
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -ResetGroupPolicy

# Disable Windows Firewall
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableFirewall

# Enable/disable test signing
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableTestSigning
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableTestSigning
```

### Networking

```powershell
# Scan network adapter bindings for orphaned entries
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -ScanNetBindings

# Fix orphaned network bindings
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixNetBindings

# Reset the full network stack
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -ResetNetworkStack

# Reset all interfaces to DHCP
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -ResetInterfacesToDHCP

# Clear proxy settings
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -ClearProxyState
```

### Azure-Specific

```powershell
# Fix Azure Guest Agent configuration
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixAzureGuestAgent

# Install Azure VM Agent offline
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -InstallAzureVMAgent

# Fix SAN policy (make attached disks online)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixSanPolicy

# Copy ACPI settings from rescue VM to broken disk
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -CopyACPISettings
```

### Windows Update

```powershell
# Fix pending/stuck Windows Updates
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixPendingUpdates

# Disable Windows Update service
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableWindowsUpdate

# List installed updates
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -ListInstalledUpdates

# Uninstall a specific update by KB number
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -UninstallWindowsUpdate "KB5012345"
```

### Miscellaneous

```powershell
# Fix device class filters (UpperFilters/LowerFilters)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixDeviceFilters

# Fix Session Manager boot execute entries
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixSessionManager

# Fix Winlogon shell/userinit
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixWinlogon

# Fix broken user profile loading
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixProfileLoad

# Configure full memory dump for crash analysis
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -SetFullMemDump

# Collect event logs from the broken disk
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -CollectEventLogs

# Collect minidump files
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -CollectMinidumps

# List startup programs
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -ListStartupPrograms

# Disable all startup programs
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableStartupPrograms

# Enable RegBack automatic backups
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableRegBackup

# Prepare recovery diagnostics package
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -PrepareRecoveryDiagnostics
```

### Combining Multiple Fixes

Multiple switches can be combined in a single run:

```powershell
# Rebuild BCD, fix RDP, and disable NLA in one pass
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixBoot -FixRDP -DisableNLA

# Full repair pass: chkdsk + SFC + DISM + BCD rebuild
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixNTFS -DriveLetter H: -RunSFC -RepairComponentStore -FixBoot -LeaveDiskOnline
```

### Manually Loading Registry Hives

For advanced troubleshooting, you can load offline registry hives to inspect them manually:

```powershell
# Load SYSTEM and SOFTWARE hives (mounted as HKLM\BROKENSYSTEM and HKLM\BROKENSOFTWARE)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -LoadHive SYSTEM,SOFTWARE -LeaveDiskOnline

# When done, unload them
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -UnloadHive SYSTEM,SOFTWARE
```

### Session Logging

All actions are logged to a JSON-line audit file (`Repair-AzVMDisk_actions.log`) alongside the script.

```powershell
# Review the last repair session
.\Repair-AzVMDisk.ps1 -ShowLastSession

# Detailed view of the last session
.\Repair-AzVMDisk.ps1 -ShowLastSession -Detailed

# View all sessions
.\Repair-AzVMDisk.ps1 -ShowLastSession -All

# Export sessions to HTML
.\Repair-AzVMDisk.ps1 -ShowLastSession -All -ExportTo C:\Temp\repair_log.html
```

## Common Scenarios

| Scenario | Command |
|---|---|
| VM won't boot | `-SysCheck` then `-FixBoot` |
| RDP not working | `-FixRDP -DisableNLA` |
| Blue screen from bad driver | `-DisableDriverOrService "drivername"` |
| Locked out of VM | `-ResetLocalAdminPassword` or `-AddTempUser` |
| Stuck on Windows Update | `-FixPendingUpdates` |
| EDR/filter driver blocking boot | `-DisableDriverOrService "drivername"` |
| Azure VM agent broken | `-FixAzureGuestAgent` or `-InstallAzureVMAgent` |
| Corrupted system files | `-RunSFC` then `-RepairComponentStore` |

## Author

Marcus Ferreira — marcus.ferreira[at]microsoft[dot]com
