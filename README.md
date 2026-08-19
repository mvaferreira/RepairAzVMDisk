# Repair-AzVMDisk

Offline Azure VM disk repair and diagnostic script for use on a Hyper-V rescue VM.

Repair-AzVMDisk attaches the OS disk of a broken Azure VM to a Hyper-V rescue VM and performs offline repairs **without booting the guest**. It can mount offline registry hives, run chkdsk/SFC/DISM, rebuild BCD, fix RDP/NLA settings, manage drivers and services, reset credentials, collect diagnostic information, and much more.

> **⚠️ Disclaimer**
>
> The sample scripts are not supported under any Microsoft standard support program or service. The sample scripts are provided AS IS without warranty of any kind. Microsoft further disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose. The entire risk arising out of the use or performance of the sample scripts and documentation remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the scripts be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the sample scripts or documentation, even if Microsoft has been advised of the possibility of such damages.

## Prerequisites

- Must be run **as Administrator** on the Hyper-V rescue VM.
- The broken VM's OS disk must be attached to the rescue VM (either as a disk passthrough or via Hyper-V).
- Rescue host: Windows 10/11 or Windows Server 2016 / 2019 / 2022 / 2025 with the Hyper-V role/feature enabled.
- Supported target (broken) guest OS: Windows Server 2012 R2 and later (2012 R2 / 2016 / 2019 / 2022 / 2025) or Windows 10/11, including Server Core and Gen1/Gen2 disks.
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

# Check and repair boot storage settings for migration/0x7B scenarios
# This checks the active offline ControlSet for boot storage Start and StartOverride values.
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixBootStorageDrivers

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

# Try a different offline ControlSet when the current one is damaged
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -TryOtherBootConfig

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
# Run chkdsk on a specific partition
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixFileSystem -DriveLetter H:

# Repair NTFS metafile attribute list entries that carry a non-canonical name offset.
# Symptom: the volume fails to mount and the guest boot loops with bugcheck
# 0x24 (NTFS_FILE_SYSTEM). chkdsk does not correct this — it discards the whole
# attribute list instead of fixing the field — so -FixFileSystem refuses to run
# chkdsk while these entries are present and points here first.
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixNtfsAttributeList

# Repair a single volume instead of every NTFS volume on the disk.
# The original bytes of every modified region are written to a restore manifest
# next to the action log before anything is changed.
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixNtfsAttributeList -DriveLetter H:

# Run SFC (System File Checker) offline
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RunSFC

# Repair component store (DISM RestoreHealth offline)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RepairComponentStore

# Repair component store using a known-good source image
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RepairComponentStore -RepairSource "D:\sources\install.wim"

# Repair a system file using architecture-validated WinSxS/DriverStore candidates
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RepairSystemFile "ntoskrnl.exe","ci.dll"

# Fix registry corruption
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixRegistryCorruption

# Restore a validated, timestamp-consistent registry hive set from RegBack
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -RestoreRegistryFromRegBack
```

### RDP & Remote Access

```powershell
# Reset RDP to Windows/Azure defaults — listener, port, keep-alive, pinned
# listener certificate, and core networking service startup types
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

# Create a temporary admin user via Setup CmdLine for domain-joined VMs
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -AddTempUser2

# Fix user rights assignments
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixUserRights
```

### Drivers & Services

```powershell
# Disable a named driver or service when directed by diagnostics
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableDriverOrService "driver1","service2"

# Re-enable a previously disabled driver or service
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableDriverOrService "driver1" -DriverStartType System

# Disable all third-party (non-Microsoft) drivers for isolation testing
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableThirdPartyDrivers

# Re-enable previously disabled third-party drivers
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableThirdPartyDrivers

# Get a report of all services and drivers (filter to issues only)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -GetServicesReport -IssuesOnly

# Include Win32 services in the services/drivers report
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -GetServicesReport -IncludeServices

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

# Disable Memory Integrity / HVCI offline for code integrity boot failures
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableMemoryIntegrity

# Disable AppLocker when policy may be interfering with boot or login
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

# Disable or re-enable Base Filtering Engine
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableBFE
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -EnableBFE

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
# Review and repair device class filters (UpperFilters/LowerFilters)
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixDeviceFilters

# Strict device filter cleanup: keep only inbox safe-list entries
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixDeviceFilters -KeepDefaultFilters

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
.\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixFileSystem -DriveLetter H: -RunSFC -RepairComponentStore -FixBoot
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

# View a specific session by ID
.\Repair-AzVMDisk.ps1 -ShowLastSession -SessionId "00000000-0000-0000-0000-000000000000"

# Export sessions to HTML
.\Repair-AzVMDisk.ps1 -ShowLastSession -All -ExportTo C:\Temp\repair_log.html
```

## Symptom → Fix mapping

This section maps **what you observe** — an on-screen Windows stop/boot error code, or a behavior such as
"no boot", "black screen", "can't RDP", or "stuck on Windows Update" — to the script actions most likely to
address it. The listed switches *attempt* to repair the condition; they are not guaranteed fixes, and the
underlying fault may have more than one cause.

> **Always diagnose first.** Run `-SysCheck` (and, for boot problems, `-GetBootPathReport`) before applying any
> repair. These read-only scans inspect the offline disk and print the **exact switch to run** for each finding,
> so the tables below are a reference for the recommendations the script already surfaces.
>
> ```powershell
> .\Repair-AzVMDisk.ps1 -DiskNumber 3 -SysCheck
> .\Repair-AzVMDisk.ps1 -DiskNumber 3 -GetBootPathReport
> ```

### By observable behavior

| Symptom / behavior | Likely cause | Try these actions (in order) | Reference |
|---|---|---|---|
| VM never reaches the sign-in screen; cause unknown | Mixed boot/registry/driver fault | `-SysCheck` → `-GetBootPathReport` → the specific suggested fix | [Boot errors][be] |
| Stop **0x7B** / inaccessible boot device after migration or disk swap | Boot storage driver `Start` values, missing synthetic/inbox storage drivers, or unsafe class filters | `-SysCheck` → `-FixBootStorageDrivers` → `-EnsureSyntheticDriversEnabled` → `-FixDeviceFilters` → `-FixSanPolicy` | [INACCESSIBLE_BOOT_DEVICE][7b], [After HW change][7bhw] |
| "Checking file system on C:" loop, or **UNMOUNTABLE_BOOT_VOLUME** | NTFS / file-system corruption on the boot volume | `-CheckDiskHealth` → `-FixFileSystem -DriveLetter H:` | [Check-disk boot error][chk], [Disk corruption][dsk] |
| Stuck on **"Getting Windows ready. Don't turn off your computer"** or update reboot loop | Pending CBS / servicing transaction won't complete | `-AnalyzeServicingState` → `-FixPendingUpdates` → `-DisableWindowsUpdate` → `-UninstallWindowsUpdate <KB>` → `-RepairComponentStore` | [Stuck updating][upd], [Getting Windows ready][gwr] |
| Continuous reboot / automatic-repair loop | Failed update, bad driver, or startup-repair churn | `-SysCheck` → `-FixPendingUpdates` → `-DisableStartupRepair` → `-TrySafeMode` | [Reboot loop][rbl] |
| Black screen after logon (no desktop) | Winlogon Shell/Userinit changed, or `explorer.exe` missing | `-FixWinlogon` → `-RepairSystemFile explorer.exe` | [Critical service failed][csf] |
| **"CRITICAL SERVICE FAILED"** blue screen | Boot-critical driver/service disabled or missing binary | `-SysCheck` → `-GetServicesReport -IssuesOnly` → `-EnsureSyntheticDriversEnabled` → `-FixBootStorageDrivers` | [Critical service failed][csf] |
| Random driver blue screens (0x7E, 0xD1, 0x50, 0x1E) or Driver Verifier crashes | Faulty third-party driver or active Driver Verifier | `-CollectMinidumps` → `-DisableDriverVerifier` → `-DisableThirdPartyDrivers` / `-DisableDriverOrService <name>` → `-TrySafeMode` | [Common blue screen][bsod] |
| Boot blocked after enabling HVCI / Memory Integrity, or unsigned-driver block | Code-integrity / Secure Boot policy rejects a driver | `-DisableMemoryIntegrity` → `-FixSecureBootCodeIntegrity` → `-RepairSystemFile <driver>` | [Invalid image hash][cih], [Disabling Secure Boot][sb] |
| Can't RDP — connection reaches the VM but authentication fails | NLA / certificate / auth-policy or RDP listener misconfig | `-FixRDP` → `-DisableNLA` → `-FixRDPAuth` → `-FixRDPCert` → `-FixRDPPermissions` | [Can't RDP][rdp], [RDP connection][rdpc], [Detailed RDP][rdpd] |
| RDP "internal error" / "general error" | Broken RDP self-signed cert or key permissions | `-FixRDPCert` → `-FixRDPPermissions` → `-FixRDP` | [Internal error][rdpi], [General error][rdpg] |
| No network after boot / NIC bindings broken | Orphaned network bindings, missing `netvsc`, or stuck stack | `-ScanNetBindings` → `-FixNetBindings` → `-EnsureSyntheticDriversEnabled` → `-ResetNetworkStack` → `-ResetInterfacesToDHCP` | [Boot errors][be] |
| Locked out / forgot the local admin password | Lost credentials | `-ResetLocalAdminPassword` → `-AddTempUser` (or `-AddTempUser2` for domain-joined) | [Reset password offline][rpw], [Reset RDP][reset], [VMAccess][vma] |
| Boot or logon blocked by policy | AppLocker, Credential Guard / LSA, or bad Group Policy | `-DisableAppLocker` → `-DisableCredentialGuard` → `-ResetGroupPolicy` → `-FixUserRights` | [Boot errors][be] |
| Corrupted / temporary user profile | `.bak` profile keys or temp-profile flag | `-FixProfileLoad` | [Boot errors][be] |
| Azure VM Agent shows **"Not ready"** / extensions fail | Guest Agent broken or missing | `-FixAzureGuestAgent` → `-InstallAzureVMAgent` | [Guest Agent][aga], [VM assist][vmw], [Slow start / failed ext.][sext] |
| Corrupted system files (general) | WinSxS / component-store damage | `-RunSFC` → `-RepairComponentStore` (add `-RepairSource <wim>` if offline store is broken) | [Boot errors][be] |
| Need live triage from outside the OS | No console access | `-EnableSerialConsole` → `-EnableBootLog` → `-SetFullMemDump` → `-PrepareRecoveryDiagnostics` → `-CollectEventLogs` | [Serial Console][sac] |

### By Windows stop code / boot error code

The codes below are the on-screen values shown in **boot diagnostics** screenshots or on the SAC/Serial Console.
"Try these actions" lists the switches that *attempt* to repair the most common cause; confirm with `-SysCheck`
first.

| Code | Name / on-screen text | Likely cause | Try these actions | Reference |
|---|---|---|---|---|
| **0xC0000001** | STATUS_UNSUCCESSFUL — generic boot failure | Missing/corrupt boot files, BCD, or boot-critical hive | `-SysCheck` → `-FixBoot` → `-RecreateBootPartition` → `-RestoreRegistryFromRegBack` | [Boot errors][be] |
| **0xC000000F** | "couldn't read the Boot Configuration Data" | BCD or a required boot file missing/unreadable | `-FixBoot` → `-RecreateBootPartition` → `-FixBootSector` (Gen1) | [0xC000000F][c00f] |
| **0xC0000011** | Boot error 0xC0000011 | Boot file/BCD read error | `-FixBoot` → `-RecreateBootPartition` | [0xC0000011][c011] |
| **0xC0000034** | STATUS_OBJECT_NAME_NOT_FOUND | Pending update left a missing BCD/registry object | `-FixPendingUpdates` → `-FixBoot` | [Stuck updating][upd] |
| **0xC0000098** | "BCD file doesn't contain a valid OS entry" | BCD has no/invalid Windows loader entry | `-FixBoot` → `-RecreateBootPartition` | [0xC0000098][c098] |
| **0xC0000102** | STATUS_FILE_CORRUPT | Corrupt file or hive on the boot volume | `-FixFileSystem` → `-RunSFC` → `-RepairComponentStore` → `-RestoreRegistryFromRegBack` | [0xC0000102][c102] |
| **0xC0000225** | "boot selection failed; a required device is inaccessible" | Missing boot partition / BCD device mismatch | `-FixBoot` → `-RecreateBootPartition` → `-FixBootSector` | [Boot errors][be] |
| **0xC0000359** | "Critical system driver is missing or corrupt" | A 32-bit system driver was installed on the x64 Windows guest | `-RepairSystemFile <driver.sys>` | [0xC0000359][c359] |
| "An operating system wasn't found" / **0xC000000E** | Boot manager finds no bootable OS | Inactive/missing boot partition or empty BCD | `-FixBoot` → `-RecreateBootPartition` → `-FixBootSector` | [OS not found][osnf] |
| **0x0000007B** | INACCESSIBLE_BOOT_DEVICE | Storage driver `Start`/filters/SAN policy after migration | `-FixBootStorageDrivers` → `-EnsureSyntheticDriversEnabled` → `-FixDeviceFilters` → `-FixSanPolicy` | [INACCESSIBLE_BOOT_DEVICE][7b], [Server 2012 R2 / platform update][2012] |
| **0x000000ED** | UNMOUNTABLE_BOOT_VOLUME | File-system corruption on boot volume | `-CheckDiskHealth` → `-FixFileSystem` | [Check-disk boot error][chk] |
| **0x00000074** / **0xC000014C** | BAD_SYSTEM_CONFIG_INFO / STATUS_REGISTRY_CORRUPT | Corrupt SYSTEM/SOFTWARE hive | `-CheckRegistryHealth` → `-FixRegistryCorruption` → `-RestoreRegistryFromRegBack` | [Fix corrupted hive][hive] |
| **0xC0000218** | STATUS_CANNOT_LOAD_REGISTRY_FILE | Registry hive missing, 0-byte, or unreadable | `-RestoreRegistryFromRegBack` → `-FixRegistryCorruption` | [0xC0000218][c218], [Fix corrupted hive][hive] |
| **0xC000021A** | STATUS_SYSTEM_PROCESS_TERMINATED | winlogon/csrss/lsass crash after bad update or file/registry mismatch | `-FixWinlogon` → `-RestoreRegistryFromRegBack` → `-FixPendingUpdates` → `-RunSFC` → `-RepairComponentStore` | [0xC000021A][c21a] |
| **0x000000EF** | CRITICAL_PROCESS_DIED | Critical system process missing/corrupt | `-RepairSystemFile <proc>.exe` → `-FixWinlogon` → `-RunSFC` → `-RepairComponentStore` | [Critical service failed][csf] |
| **0x00000067** | CONFIG_INITIALIZATION_FAILED | Stale IMC hive entries in BCD | `-FixBoot` | [Boot errors][be] |
| **0xC0000428** | "Windows cannot verify the digital signature" / Invalid Image Hash | Unsigned/corrupt boot driver, or HVCI/Secure Boot block | `-FixSecureBootCodeIntegrity` → `-DisableMemoryIntegrity` → `-RepairSystemFile <driver>` → `-EnableTestSigning` (temporary) | [Invalid image hash][cih], [Disabling Secure Boot][sb] |
| **0xc0430001** | winload.efi Code Integrity error (Gen2) | Stale EFI boot manager / Code-Integrity policy payloads | `-FixSecureBootCodeIntegrity` (optionally `-CodeIntegrityPolicySourcePath`) | [Invalid image hash][cih] |
| Directory Service init failure (DC) | "directory service initialization failure" | AD DS database (ntds.dit) / boot dependency | `-SysCheck` → `-RestoreRegistryFromRegBack` (DC database repair is out of scope) | [DS init failure][dsi] |

## References — Microsoft Learn

All links are public Microsoft documentation.

- [Troubleshoot Azure VM boot errors (hub)][be]
- [INACCESSIBLE_BOOT_DEVICE in an Azure VM][7b]
- [Stop 0x7B after reconfiguring hardware devices][7bhw]
- [Windows Server 2012 R2 startup failure after platform update][2012]
- [Boot error 0xC000000F][c00f]
- [Boot error 0xC0000011][c011]
- [Boot error 0xc0000098][c098]
- [Boot error 0xc0000359][c359]
- [Stop error 0xC0000102 (Status File Corrupt)][c102]
- [Windows boot error: an operating system wasn't found][osnf]
- [Repair the boot configuration data (BCD)][bcd]
- [Check-disk boot error ("checking file system")][chk]
- [Data corruption and disk errors guidance][dsk]
- [VM startup stuck at Windows update][upd]
- [Stuck on "Getting Windows ready"][gwr]
- [Windows reboot loop on an Azure VM][rbl]
- [Fix registry hive corruption][hive]
- [Bug Check 0xC0000218: STATUS_CANNOT_LOAD_REGISTRY_FILE][c218]
- [Stop error 0xC000021A (Status System Process Terminated)][c21a]
- [CRITICAL SERVICE FAILED blue screen][csf]
- [Common blue screen errors when booting an Azure VM][bsod]
- [Boot manager error 0xC0000428 (Invalid Image Hash)][cih]
- [Disabling Secure Boot][sb]
- [Directory service initialization failure][dsi]
- [Can't connect via RDP to an Azure VM][rdp]
- [Troubleshoot RDP connections][rdpc]
- [Detailed RDP troubleshooting][rdpd]
- [RDP internal error][rdpi]
- [RDP general error][rdpg]
- [Reset local Windows password offline][rpw]
- [Reset Remote Desktop Services / admin password][reset]
- [VMAccess extension for Windows][vma]
- [Troubleshoot Azure Windows VM Agent issues][aga]
- [VM assist (guest agent tool)][vmw]
- [Slow VM start when extensions are failed][sext]
- [Azure Serial Console overview][sac]
- [Windows Server doesn't start after updates (disk corruption)][wsd]

[be]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/boot-error-troubleshoot
[7b]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/windows-boot-failure
[7bhw]: https://learn.microsoft.com/troubleshoot/windows-server/performance/inaccessible-boot-device-stop-error
[2012]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/windows-server-2012r2-boot-failure-platform-update
[c00f]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/boot-error-0xc000000f
[c011]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/boot-error-0xc0000011
[c098]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/boot-error-0xc0000098
[c359]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/boot-error-0xc0000359
[c102]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/error-code-0xc0000102-status-file-corrupt
[osnf]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/os-not-found
[bcd]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/virtual-machines-windows-repair-boot-configuration-data
[chk]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/troubleshoot-check-disk-boot-error
[dsk]: https://learn.microsoft.com/troubleshoot/windows-server/backup-and-storage/troubleshoot-data-corruption-and-disk-errors
[upd]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/troubleshoot-stuck-updating-boot-error
[gwr]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/troubleshoot-vm-boot-configure-update
[rbl]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/troubleshoot-reboot-loop
[hive]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/virtual-machines-windows-fix-corrupted-hive
[c218]: https://learn.microsoft.com/windows-hardware/drivers/debugger/bug-check-0xc0000218--status-cannot-load-registry-file
[c21a]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/windows-stop-error-system-process-terminated
[csf]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/troubleshoot-critical-service-failed-boot-error
[bsod]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/troubleshoot-common-blue-screen-error
[cih]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/windows-boot-error-invalid-image-hash
[sb]: https://learn.microsoft.com/windows-hardware/manufacture/desktop/disabling-secure-boot
[dsi]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/troubleshoot-directory-service-initialization-failure
[rdp]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/cannot-connect-rdp-azure-vm
[rdpc]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/troubleshoot-rdp-connection
[rdpd]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/detailed-troubleshoot-rdp
[rdpi]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/troubleshoot-rdp-internal-error
[rdpg]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/troubleshoot-rdp-general-error
[rpw]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-local-password-without-agent
[reset]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp
[vma]: https://learn.microsoft.com/azure/virtual-machines/extensions/vmaccess-windows
[aga]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/windows-azure-guest-agent
[vmw]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/windows-azure-guest-agent-tools-vmassist
[sext]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/slow-vm-start-extensions-troubleshooting
[sac]: https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/serial-console-overview
[wsd]: https://learn.microsoft.com/troubleshoot/windows-server/performance/disk-corruption-prevents-windows-server-update-restart

## Author

Marcus Ferreira — marcus.ferreira[at]microsoft[dot]com
