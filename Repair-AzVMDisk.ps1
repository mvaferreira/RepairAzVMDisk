<#
    Disclaimer
        The sample scripts are not supported under any Microsoft standard support program or service.
        The sample scripts are provided AS IS without warranty of any kind.
        Microsoft further disclaims all implied warranties including, without limitation, any implied
        warranties of merchantability or of fitness for a particular purpose.
        The entire risk arising out of the use or performance of the sample scripts and documentation
        remains with you. In no event shall Microsoft, its authors, or anyone else involved in the
        creation, production, or delivery of the scripts be liable for any damages whatsoever
        (including, without limitation, damages for loss of business profits, business interruption,
        loss of business information, or other pecuniary loss) arising out of the use of or inability
        to use the sample scripts or documentation, even if Microsoft has been advised of the
        possibility of such damages.

    .SYNOPSIS
        Offline Azure VM disk repair and diagnostic script for use on a Hyper-V rescue VM.
        Author: Marcus Ferreira marcus.ferreira[at]microsoft[dot]com
        Version: 0.3.9

    .DESCRIPTION
        Repair-AzVMDisk.ps1 attaches the OS disk of a broken Azure VM to a Hyper-V rescue VM and performs
        offline repairs without booting the guest. It can mount offline registry hives
        (BROKENSYSTEM / BROKENSOFTWARE), run chkdsk/SFC/DISM, rebuild BCD, fix RDP/NLA settings,
        manage drivers and services, reset credentials, and collect diagnostic information.

        A built-in system check (-SysCheck) inspects the offline disk for common issues across
        disk health, boot configuration, RDP/NLA policy, Windows Update/CBS state, credential guard,
        network bindings, Azure VM agent presence, and more - and prints actionable fix suggestions.

        All actions are logged to a JSON-line audit file (Repair-AzVMDisk_actions.log) alongside the script.
        Previous sessions can be reviewed with -ShowLastSession.

    .NOTES
        - Must be run as Administrator on the Hyper-V rescue VM.
        - The broken VM's OS disk must be attached to the rescue VM.
        - Tested on Windows Server 2016 / 2019 / 2022 rescue environments.
        - Use -LeaveDiskOnline to keep the disk online after repair (required for chkdsk via -FixNTFS).

    .PARAMETER DiskNumber
        Disk number of the attached broken VM disk (from Get-Disk). Use instead of -VMName.

    .PARAMETER VMName
        Name of the Hyper-V VM whose disk should be attached automatically. Use instead of -DiskNumber.

    .EXAMPLE
        # Run a full diagnostic check on disk 3
        PS> .\Repair-AzVMDisk.ps1 -DiskNumber 3 -SysCheck

    .EXAMPLE
        # Rebuild BCD and fix RDP settings on disk 3
        PS> .\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixBoot -FixRDP

    .EXAMPLE
        # Run chkdsk on a specific partition (disk must stay online for the drive letter to be available)
        PS> .\Repair-AzVMDisk.ps1 -DiskNumber 3 -FixNTFS -DriveLetter H: -LeaveDiskOnline

    .EXAMPLE
        # Reset a forgotten local admin password
        PS> .\Repair-AzVMDisk.ps1 -DiskNumber 3 -ResetLocalAdminPassword

    .EXAMPLE
        # Disable a problematic third-party driver (or several)
        PS> .\Repair-AzVMDisk.ps1 -DiskNumber 3 -DisableDriverOrService driver1,driver2

    .EXAMPLE
        # Show the last repair session log
        PS> .\Repair-AzVMDisk.ps1 -ShowLastSession -Detailed

    .EXAMPLE
        # Export all sessions to HTML
        PS> .\Repair-AzVMDisk.ps1 -ShowLastSession -All -ExportTo C:\Temp\repair_log.html
#>
[CmdletBinding(DefaultParameterSetName = 'Repair')]
param (
    [Parameter(ParameterSetName = 'Repair')][string]$VMName = "",
    [Parameter(ParameterSetName = 'Repair')][int]$DiskNumber = -1,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixNTFS,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixBoot,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixBootSector,
    [Parameter(ParameterSetName = 'Repair')][switch]$RecreateBootPartition,
    [Parameter(ParameterSetName = 'Repair')][switch]$RepairComponentStore,
    [Parameter(ParameterSetName = 'Repair')][switch]$AnalyzeComponentStore,
    [Parameter(ParameterSetName = 'Repair')][switch]$TryLGKC,
    [Parameter(ParameterSetName = 'Repair')][switch]$TryOtherBootConfig,
    [Parameter(ParameterSetName = 'Repair')][switch]$TrySafeMode,
    [Parameter(ParameterSetName = 'Repair')][switch]$RemoveSafeModeFlag,
    [Parameter(ParameterSetName = 'Repair')][switch]$RunSFC,
    [Parameter(ParameterSetName = 'Repair')][switch]$EnableBootLog,
    [Parameter(ParameterSetName = 'Repair')][switch]$DisableStartupRepair,
    [Parameter(ParameterSetName = 'Repair')][switch]$EnableStartupRepair,
    [Parameter(ParameterSetName = 'Repair')][switch]$DisableBFE,
    [Parameter(ParameterSetName = 'Repair')][switch]$EnableBFE,
    [Parameter(ParameterSetName = 'Repair')][switch]$AddTempUser,
    [Parameter(ParameterSetName = 'Repair')][switch]$AddTempUser2,
    [Parameter(ParameterSetName = 'Repair')][switch]$ResetLocalAdminPassword,
    [Parameter(ParameterSetName = 'Repair')][switch]$SetFullMemDump,
    [Parameter(ParameterSetName = 'Repair')][switch]$DisableNLA,
    [Parameter(ParameterSetName = 'Repair')][switch]$EnableNLA,
    [Parameter(ParameterSetName = 'Repair')][switch]$EnableWinRMHTTPS,
    [Parameter(ParameterSetName = 'Repair')][switch]$CheckRDPPolicies,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixRDP,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixRDPCert,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixRDPPermissions,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixRDPAuth,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixUserRights,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixPendingUpdates,
    [Parameter(ParameterSetName = 'Repair')][switch]$DisableWindowsUpdate,
    [Parameter(ParameterSetName = 'Repair')][switch]$RestoreRegistryFromRegBack,
    [Parameter(ParameterSetName = 'Repair')][switch]$EnableRegBackup,
    [Parameter(ParameterSetName = 'Repair')][switch]$DisableThirdPartyDrivers,
    [Parameter(ParameterSetName = 'Repair')][switch]$EnableThirdPartyDrivers,
    [Parameter(ParameterSetName = 'Repair')][switch]$GetServicesReport,
    [Parameter(ParameterSetName = 'Repair')][string[]]$DisableDriverOrService = @(),
    [Parameter(ParameterSetName = 'Repair')][string[]]$EnableDriverOrService = @(),
    [Parameter(ParameterSetName = 'Repair')][switch]$DisableCredentialGuard,
    [Parameter(ParameterSetName = 'Repair')][switch]$EnableCredentialGuard,
    [Parameter(ParameterSetName = 'Repair')][switch]$DisableAppLocker,
    [Parameter(ParameterSetName = 'Repair')][switch]$GetAppLockerReport,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixSanPolicy,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixAzureGuestAgent,
    [Parameter(ParameterSetName = 'Repair')][switch]$InstallAzureVMAgent,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixDeviceFilters,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixSessionManager,
    [Parameter(ParameterSetName = 'Repair')][switch]$CopyACPISettings,
    [Parameter(ParameterSetName = 'Repair')][switch]$ScanNetBindings,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixNetBindings,
    [Parameter(ParameterSetName = 'Repair')][switch]$SysCheck,
    [Parameter(ParameterSetName = 'Repair')][switch]$ResetNetworkStack,
    [Parameter(ParameterSetName = 'Repair')][switch]$EnableTestSigning,
    [Parameter(ParameterSetName = 'Repair')][switch]$DisableTestSigning,
    [Parameter(ParameterSetName = 'Repair')][switch]$CheckDiskHealth,
    [Parameter(ParameterSetName = 'Repair')][switch]$CollectEventLogs,
    [Parameter(ParameterSetName = 'Repair')][switch]$CollectMinidumps,
    [Parameter(ParameterSetName = 'Repair')][switch]$AnalyzeCriticalBootFiles,
    [Parameter(ParameterSetName = 'Repair')][string[]]$RepairSystemFile = @(),
    [Parameter(ParameterSetName = 'Repair')][switch]$AnalyzeSyntheticDrivers,
    [Parameter(ParameterSetName = 'Repair')][switch]$EnsureSyntheticDriversEnabled,
    [Parameter(ParameterSetName = 'Repair')][switch]$ResetInterfacesToDHCP,
    [Parameter(ParameterSetName = 'Repair')][switch]$AnalyzeProxyState,
    [Parameter(ParameterSetName = 'Repair')][switch]$ClearProxyState,
    [Parameter(ParameterSetName = 'Repair')][switch]$GetBootPathReport,
    [Parameter(ParameterSetName = 'Repair')][switch]$AnalyzeBcdConsistency,
    [Parameter(ParameterSetName = 'Repair')][switch]$AnalyzeServicingState,
    [Parameter(ParameterSetName = 'Repair')][switch]$AnalyzeDomainTrustState,
    [Parameter(ParameterSetName = 'Repair')][switch]$PrepareRecoveryDiagnostics,
    [Parameter(ParameterSetName = 'Repair')][switch]$DisableDriverVerifier,
    [Parameter(ParameterSetName = 'Repair')][string]$EnableDriverVerifier = '',
    [Parameter(ParameterSetName = 'Repair')][switch]$ResetGroupPolicy,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixWinlogon,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixProfileLoad,
    [Parameter(ParameterSetName = 'Repair')][switch]$CheckRegistryHealth,
    [Parameter(ParameterSetName = 'Repair')][switch]$FixRegistryCorruption,
    [Parameter(ParameterSetName = 'Repair')][switch]$EnableSerialConsole,
    [Parameter(ParameterSetName = 'Repair')][switch]$ListInstalledUpdates,
    [Parameter(ParameterSetName = 'Repair')][string]$UninstallWindowsUpdate = '',
    [Parameter(ParameterSetName = 'Repair')][switch]$ListStartupPrograms,
    [Parameter(ParameterSetName = 'Repair')][switch]$DisableStartupPrograms,
    [Parameter(ParameterSetName = 'Repair')][switch]$DisableFirewall,
    [Parameter(ParameterSetName = 'Repair')][switch]$LeaveDiskOnline,
    [Parameter(ParameterSetName = 'Repair')][ValidateSet('SYSTEM', 'SOFTWARE', 'COMPONENTS', 'SAM', 'SECURITY')][string[]]$LoadHive = @(),
    [Parameter(ParameterSetName = 'Repair')][ValidateSet('SYSTEM', 'SOFTWARE', 'COMPONENTS', 'SAM', 'SECURITY')][string[]]$UnloadHive = @(),
    [Parameter(ParameterSetName = 'ShowSession')][switch]$ShowLastSession
)

# Dynamic sub-parameters: only appear in tab completion when the parent switch is present.
# This prevents clutter like -DriveLetter showing without -FixNTFS, or -All without -ShowLastSession.
dynamicparam {
    $dict = [System.Management.Automation.RuntimeDefinedParameterDictionary]::new()

    # Helper: register a dynamic parameter
    $addParam = {
        param([string]$Name, [type]$Type, [string]$SetName, $Default, [System.Attribute[]]$ExtraAttribs)
        $pa = [System.Management.Automation.ParameterAttribute]@{ ParameterSetName = $SetName }
        $col = [System.Collections.ObjectModel.Collection[System.Attribute]]::new()
        $col.Add($pa)
        if ($ExtraAttribs) { foreach ($a in $ExtraAttribs) { $col.Add($a) } }
        $p = [System.Management.Automation.RuntimeDefinedParameter]::new($Name, $Type, $col)
        if ($null -ne $Default) { $p.Value = $Default }
        $dict.Add($Name, $p)
    }

    # -DriveLetter: sub-option of -FixNTFS
    if ($PSBoundParameters.ContainsKey('FixNTFS')) {
        & $addParam 'DriveLetter' ([string]) 'Repair' ''
    }
    # -RepairSource: sub-option of -RepairComponentStore
    if ($PSBoundParameters.ContainsKey('RepairComponentStore')) {
        & $addParam 'RepairSource' ([string]) 'Repair' ''
    }
    # -IncludeServices, -IssuesOnly: sub-options of -GetServicesReport
    if ($PSBoundParameters.ContainsKey('GetServicesReport')) {
        & $addParam 'IncludeServices' ([switch]) 'Repair' $null
        & $addParam 'IssuesOnly'      ([switch]) 'Repair' $null
    }
    # -KeepDefaultFilters: sub-option of -FixDeviceFilters
    if ($PSBoundParameters.ContainsKey('FixDeviceFilters')) {
        & $addParam 'KeepDefaultFilters' ([switch]) 'Repair' $null
    }
    # -DriverStartType: sub-option of -EnableDriverOrService
    if ($PSBoundParameters.ContainsKey('EnableDriverOrService')) {
        $vs = [System.Management.Automation.ValidateSetAttribute]::new(
            'Boot', 'System', 'Automatic', 'Manual', 'Disabled')
        & $addParam 'DriverStartType' ([string]) 'Repair' 'Manual' @($vs)
    }
    # -Detailed, -All, -SessionId, -ExportTo: sub-options of -ShowLastSession
    if ($PSBoundParameters.ContainsKey('ShowLastSession')) {
        & $addParam 'Detailed'  ([switch]) 'ShowSession' $null
        & $addParam 'All'       ([switch]) 'ShowSession' $null
        & $addParam 'SessionId' ([string]) 'ShowSession' ''
        & $addParam 'ExportTo'  ([string]) 'ShowSession' ''
    }

    return $dict
}

end {
    ################################################################################
    # Helper functions
    ################################################################################

    # Helper: builds a unique backup file path if the primary .bak exists
    function New-UniqueBackupPath {
        param(
            [Parameter(Mandatory = $true)][string]$BasePath, # e.g. E:\Boot\BCD or H:\EFI\Microsoft\Boot\BCD
            [string]$BakSuffix = ".bak"
        )
        $bak = "$BasePath$BakSuffix"
        if (-not (Test-Path -LiteralPath $bak)) { return $bak }
        $ts = (Get-Date -Format "yyyyMMddHHmmss")
        return "$BasePath.$ts$BakSuffix"
    }

    # Helper: Get BCD store path based on VM generation
    function Get-BcdStorePath {
        param(
            [Parameter(Mandatory = $true)][int]$Generation,
            [Parameter(Mandatory = $true)][string]$BootDrive
        )
        $BootDrive = $BootDrive.TrimEnd('\')
        if ($Generation -eq 1) {
            return "$BootDrive\Boot\BCD"
        }
        else {
            return "$BootDrive\EFI\Microsoft\Boot\BCD"
        }
    }

    # Helper: Extract Windows Boot Loader identifier from BCD
    function Get-BcdBootLoaderId {
        param(
            [Parameter(Mandatory = $true)][string]$StorePath
        )
        if (-not (Test-Path -LiteralPath $StorePath)) {
            Write-Warning "BCD not found at $StorePath."
            return $null
        }
    
        $cmd = "bcdedit /store `"$StorePath`" /enum"
        $raw = & cmd.exe /c $cmd
        $identifier = (($raw -join "`n") -replace '(?s).*Windows Boot Loader.*?identifier\s+([^\r\n]+).*', '$1').Trim()
    
        if ([string]::IsNullOrWhiteSpace($identifier)) {
            Write-Warning "Could not extract boot loader identifier from $StorePath"
            return $null
        }
        return $identifier
    }

    # Helper: Execute bcdedit command with validation
    function Invoke-BcdEdit {
        param(
            [Parameter(Mandatory = $true)][string]$StorePath,
            [Parameter(Mandatory = $true)][string]$Command
        )
        $fullCmd = "bcdedit /store `"$StorePath`" $Command"
        Write-Host "  [exec] $fullCmd" -ForegroundColor DarkGray
        Invoke-Logged -Description "bcdedit" -Details @{ StorePath = $StorePath; Command = $Command } -ScriptBlock { & cmd.exe /c $fullCmd }
    }

    ################################################################################
    # Action logging helpers
    ################################################################################

    # Path to the action log (JSON line entries)
    if (-not $env:RepairActionLog) {
        $script:ActionLogPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'Repair-AzVMDisk_actions.log'
    }
    else {
        # Validate that the env override is a simple file path (no UNC, no alternate data streams)
        $envPath = $env:RepairActionLog
        if ($envPath -match '^\\\\' -or $envPath -match ':.*:') {
            Write-Warning "RepairActionLog path '$envPath' looks unsafe; using default log location."
            $script:ActionLogPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'Repair-AzVMDisk_actions.log'
        }
        else {
            $script:ActionLogPath = $envPath
        }
    }

    # Restrict the log file to Administrators and SYSTEM only (no other local users)
    if (-not (Test-Path -LiteralPath $script:ActionLogPath)) {
        $null = New-Item -Path $script:ActionLogPath -ItemType File -Force
    }
    try {
        $acl = Get-Acl -LiteralPath $script:ActionLogPath
        $acl.SetAccessRuleProtection($true, $false)   # disable inheritance, remove inherited entries
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
        $adminRule = [System.Security.AccessControl.FileSystemAccessRule]::new('BUILTIN\Administrators', 'FullControl', 'Allow')
        $systemRule = [System.Security.AccessControl.FileSystemAccessRule]::new('NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')
        $acl.AddAccessRule($adminRule)
        $acl.AddAccessRule($systemRule)
        Set-Acl -LiteralPath $script:ActionLogPath -AclObject $acl
    }
    catch {
        Write-Warning "Could not restrict log file permissions: $_"
    }

    # Unique identifier for this script execution - stamped on every log entry
    $script:CurrentSessionId = [guid]::NewGuid().ToString()

    function Start-ActionLog {
        param([string]$HeaderMessage = "Repair actions log")
        $entry = @{
            SessionId  = $script:CurrentSessionId
            Time       = (Get-Date).ToString('o')
            Event      = 'SessionStart'
            Message    = $HeaderMessage
            GuestName  = if ($script:GuestComputerName) { $script:GuestComputerName } else { '' }
            DiskNumber = if ($null -ne $script:DiskNumber -and $script:DiskNumber -ge 0) { $script:DiskNumber } else { '' }
            Parameters = ($PSBoundParameters.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
        }
        $entry | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $script:ActionLogPath -Encoding UTF8 -Append
    }

    function Write-ActionLog {
        param(
            [Parameter(Mandatory = $true)][string]$Event,
            [Parameter(Mandatory = $true)][hashtable]$Details
        )
        $payload = @{
            SessionId  = $script:CurrentSessionId
            Time       = (Get-Date).ToString('o')
            Event      = $Event
            GuestName  = if ($script:GuestComputerName) { $script:GuestComputerName } else { '' }
            DiskNumber = if ($null -ne $script:DiskNumber -and $script:DiskNumber -ge 0) { $script:DiskNumber } else { '' }
            Details    = $Details
        }
        $payload | ConvertTo-Json -Depth 10 -Compress | Out-File -FilePath $script:ActionLogPath -Encoding UTF8 -Append
    }

    # Execute a scriptblock and log start/end, success/failure and outputs
    function Invoke-Logged {
        param(
            [Parameter(Mandatory = $true)][string]$Description,
            [hashtable]$Details = @{},
            [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
        )

        $start = Get-Date
        try {
            $output = & $ScriptBlock 2>&1 | Out-String
            $end = Get-Date
            Write-ActionLog -Event 'ActionExecuted' -Details @{ Description = $Description; Start = $start.ToString('o'); End = $end.ToString('o'); Success = $true; Details = $Details; Output = $output }
            return $output
        }
        catch {
            $end = Get-Date
            Write-ActionLog -Event 'ActionExecuted' -Details @{ Description = $Description; Start = $start.ToString('o'); End = $end.ToString('o'); Success = $false; Details = $Details; Error = $_.ToString() }
            throw
        }
    }

    # Display all log entries from the most recent session (or a specific session by GUID)
    function Get-LastRepairSession {
        param(
            [string]$LogPath = $script:ActionLogPath,
            [string]$SessionId = '',        # leave blank for the most recent session
            [switch]$All,                   # show all sessions
            [switch]$Detailed,              # show full details (paths, output, registry changes, etc.)
            [string]$ExportTo = ''          # optional path to export HTML (.html) or CSV (.csv)
        )

        if (-not (Test-Path $LogPath)) {
            Write-Warning "Log file not found: $LogPath"
            return
        }

        $entries = Get-Content $LogPath | ForEach-Object {
            try { $_ | ConvertFrom-Json } catch { $null }
        } | Where-Object { $_ }

        if ($All) {
            # When -All and -ExportTo are combined, export all entries; otherwise print them
            if ($ExportTo) {
                # fall through: $entries already contains everything, export block below handles it
            }
            else {
                $entries | Format-List
                return
            }
        }
        elseif ($SessionId) {
            $entries = $entries | Where-Object { $_.SessionId -eq $SessionId }
        }
        else {
            # Pick the most recent SessionStart entry and filter by its GUID
            $lastSession = ($entries | Where-Object { $_.Event -eq 'SessionStart' } | Select-Object -Last 1).SessionId
            if (-not $lastSession) {
                Write-Warning "No session start marker found in log."
                return
            }
            Write-Host "Showing session: $lastSession" -ForegroundColor Cyan
            $entries = $entries | Where-Object { $_.SessionId -eq $lastSession }
        }

        # Print to console (skip when -All -ExportTo is used - too verbose for hundreds of entries)
        if (-not ($All -and $ExportTo)) {
            foreach ($e in $entries) {
                $entryTime = $e.Time
                $entryType = $e.Event
                $guest = if ($e.GuestName) { $e.GuestName } else { '' }
                $diskNum = if ($null -ne $e.DiskNumber -and $e.DiskNumber -ne '') { "Disk$($e.DiskNumber)" } else { '' }
                $target = (@($guest, $diskNum) | Where-Object { $_ }) -join '/'
                $targetCol = if ($target) { "[$target]  " } else { '' }
                $success = if ($null -ne $e.Details.Success) { if ($e.Details.Success) { '[OK]' } else { '[FAIL]' } } else { '' }
                $desc = if ($e.Details.Description) { $e.Details.Description } elseif ($e.Message) { $e.Message } else { '' }
                $color = if ($e.Details.Success -eq $false) { 'Red' } elseif ($entryType -eq 'SessionStart') { 'Cyan' } else { 'White' }
                Write-Host "$entryTime  $targetCol$entryType  $success  $desc" -ForegroundColor $color
                if ($e.Details.Error) { Write-Host "  ERROR: $($e.Details.Error)" -ForegroundColor Red }

                if ($Detailed -and $entryType -ne 'SessionStart') {
                    # Duration
                    if ($e.Details.Start -and $e.Details.End) {
                        $duration = ([datetime]$e.Details.End - [datetime]$e.Details.Start).TotalSeconds
                        Write-Host ("    Duration: {0:N3}s" -f $duration) -ForegroundColor DarkGray
                    }
                    # Operation-specific fields stored in the nested Details sub-object
                    if ($e.Details.Details) {
                        $e.Details.Details.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Value -ne '' } | ForEach-Object {
                            Write-Host "    $($_.Name): $($_.Value)" -ForegroundColor DarkCyan
                        }
                    }
                    # Command / tool output
                    if ($e.Details.Output -and ([string]$e.Details.Output).Trim()) {
                        Write-Host "    Output:" -ForegroundColor DarkGray
                        ([string]$e.Details.Output).Trim() -split "`n" | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }
                    }
                }
            } # end foreach
        } # end if not (All+ExportTo)

        # --- Export to file if requested ---
        if ($ExportTo) {
            $ext = [System.IO.Path]::GetExtension($ExportTo).ToLower()

            if ($ext -eq '.csv') {
                $rows = foreach ($e in $entries) {
                    $duration = ''
                    if ($e.Details.Start -and $e.Details.End) {
                        $duration = '{0:N3}s' -f ([datetime]$e.Details.End - [datetime]$e.Details.Start).TotalSeconds
                    }
                    $detailFields = if ($e.Details.Details) {
                        ($e.Details.Details.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Value -ne '' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
                    }
                    else { '' }
                    [PSCustomObject]@{
                        Time        = $e.Time
                        GuestName   = if ($e.GuestName) { $e.GuestName } else { '' }
                        DiskNumber  = if ($null -ne $e.DiskNumber -and $e.DiskNumber -ne '') { $e.DiskNumber } else { '' }
                        Event       = $e.Event
                        Success     = if ($null -ne $e.Details.Success) { $e.Details.Success } else { '' }
                        Description = if ($e.Details.Description) { $e.Details.Description } elseif ($e.Message) { $e.Message } else { '' }
                        Duration    = $duration
                        Details     = $detailFields
                        Error       = if ($e.Details.Error) { $e.Details.Error } else { '' }
                        Output      = if ($e.Details.Output) { ([string]$e.Details.Output).Trim() } else { '' }
                    }
                }
                $rows | Export-Csv -Path $ExportTo -NoTypeInformation -Encoding UTF8
                Write-Host "Session exported to CSV: $ExportTo" -ForegroundColor Green

            }
            elseif ($ext -eq '.html') {
                $htmlRows = foreach ($e in $entries) {
                    $entryType = $e.Event
                    $success = if ($null -ne $e.Details.Success) { if ($e.Details.Success) { '<span style="color:green">[OK]</span>' } else { '<span style="color:red">[FAIL]</span>' } } else { '' }
                    $desc = [System.Web.HttpUtility]::HtmlEncode($(if ($e.Details.Description) { $e.Details.Description } elseif ($e.Message) { $e.Message } else { '' }))
                    $rowStyle = if ($e.Details.Success -eq $false) { 'background:#ffe0e0' } elseif ($entryType -eq 'SessionStart') { 'background:#e0f0ff' } else { '' }
                    $duration = ''
                    if ($e.Details.Start -and $e.Details.End) {
                        $duration = '{0:N3}s' -f ([datetime]$e.Details.End - [datetime]$e.Details.Start).TotalSeconds
                    }
                    $detailHtml = ''
                    if ($e.Details.Details) {
                        $detailHtml = '<ul style="margin:2px 0;padding-left:16px;font-size:0.85em;color:#555">' +
                        (($e.Details.Details.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Value -ne '' } | ForEach-Object {
                                "<li><b>$([System.Web.HttpUtility]::HtmlEncode($_.Name)):</b> $([System.Web.HttpUtility]::HtmlEncode([string]$_.Value))</li>"
                            }) -join '') + '</ul>'
                    }
                    $outputHtml = ''
                    if ($e.Details.Output -and ([string]$e.Details.Output).Trim()) {
                        $outputHtml = '<pre style="margin:2px 0;font-size:0.8em;background:#f5f5f5;padding:4px;white-space:pre-wrap">' +
                        [System.Web.HttpUtility]::HtmlEncode(([string]$e.Details.Output).Trim()) + '</pre>'
                    }
                    $errorHtml = ''
                    if ($e.Details.Error) {
                        $errorHtml = '<div style="color:red;font-size:0.85em">ERROR: ' + [System.Web.HttpUtility]::HtmlEncode($e.Details.Error) + '</div>'
                    }
                    $guestHtml = [System.Web.HttpUtility]::HtmlEncode($(if ($e.GuestName) { $e.GuestName } else { '' }))
                    $diskHtml = if ($null -ne $e.DiskNumber -and $e.DiskNumber -ne '') { $e.DiskNumber } else { '' }
                    "<tr style='$rowStyle'><td style='white-space:nowrap'>$($e.Time)</td><td>$guestHtml</td><td>$diskHtml</td><td>$entryType</td><td>$success</td><td>$desc</td><td>$duration</td><td>$detailHtml$errorHtml$outputHtml</td></tr>"
                }
                $sessionLabel = if ($All) { 'AllSessions' } elseif ($SessionId) { $SessionId } else { ($entries | Where-Object { $_.Event -eq 'SessionStart' } | Select-Object -First 1).SessionId }
                $html = @"
<!DOCTYPE html>
<html><head><meta charset='utf-8'>
<title>Repair-AzVMDisk Session $sessionLabel</title>
<style>
  body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; margin: 20px; }
  h2 { color: #1a5276; }
  table { border-collapse: collapse; width: 100%; }
  th { background: #1a5276; color: white; padding: 6px 10px; text-align: left; }
  td { border: 1px solid #ddd; padding: 5px 10px; vertical-align: top; }
  tr:hover { background: #f0f7ff; }
</style>
</head><body>
<h2>Repair-AzVMDisk Session Report</h2>
<p><b>Session ID:</b> $sessionLabel<br><b>Log:</b> $LogPath<br><b>Generated:</b> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<table>
<tr><th>Time</th><th>Guest</th><th>Disk</th><th>Event</th><th>Result</th><th>Description</th><th>Duration</th><th>Details / Output</th></tr>
$($htmlRows -join "`n")
</table></body></html>
"@
                $html | Out-File -FilePath $ExportTo -Encoding UTF8
                Write-Host "Session exported to HTML: $ExportTo" -ForegroundColor Green

            }
            else {
                Write-Warning "Unknown export format '$ext'. Use .html or .csv"
            }
        }
    }

    # File operation wrappers
    function Move-Item-Logged {
        param([Parameter(Mandatory = $true)]$LiteralPath, [Parameter(Mandatory = $true)]$Destination, [switch]$Force)
        $details = @{ Operation = 'Move-Item'; Path = $LiteralPath; Destination = $Destination }
        Invoke-Logged -Description 'Move-Item' -Details $details -ScriptBlock { Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force }
    }

    function Remove-Item-Logged {
        param([Parameter(Mandatory = $true)]$Path, [switch]$Recurse, [switch]$Force)
        $recurseStr = if ($Recurse) { ' -Recurse' } else { '' }
        Write-Host "  [exec] Remove-Item$recurseStr '$Path'" -ForegroundColor DarkGray
        $details = @{ Operation = 'Remove-Item'; Path = $Path }
        Invoke-Logged -Description 'Remove-Item' -Details $details -ScriptBlock { Remove-Item -Path $Path -Recurse:$Recurse -Force:$Force -ErrorAction SilentlyContinue }
    }

    function Rename-Item-Logged {
        param([Parameter(Mandatory = $true)]$Path, [Parameter(Mandatory = $true)]$NewName)
        Write-Host "  [exec] Rename-Item '$Path' -> '$NewName'" -ForegroundColor DarkGray
        $details = @{ Operation = 'Rename-Item'; Path = $Path; NewName = $NewName }
        Invoke-Logged -Description 'Rename-Item' -Details $details -ScriptBlock { Rename-Item -Path $Path -NewName $NewName -Force }
    }

    # Registry helper that logs before/after values
    function Set-ItemProperty-Logged {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)]$Value,
            [Alias('Type')][string]$PropertyType = 'DWord',
            [switch]$Force
        )
        $before = $null
        try { $before = (Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue).$Name } catch { $before = $null }
        $displayValue = if ($Value -is [byte[]]) { "0x$(($Value | ForEach-Object { $_.ToString('X2') }) -join '')" } else { $Value }
        $displayBefore = if ($null -eq $before) { '(not set)' } elseif ($before -is [byte[]]) { "0x$(($before | ForEach-Object { $_.ToString('X2') }) -join '')" } else { $before }
        Write-Host "  [exec] Set-ItemProperty '$Path' -Name '$Name' -Value $displayValue ($PropertyType)  [was: $displayBefore]" -ForegroundColor DarkGray
        $details = @{ Operation = 'Set-ItemProperty'; Path = $Path; Name = $Name; Before = $before; After = $Value }
        Invoke-Logged -Description 'Set-ItemProperty' -Details $details -ScriptBlock { if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }; New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force | Out-Null }
    }

    # Create item wrapper (files/directories/registry keys)
    function New-Item-Logged {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [string]$Name = '',
            [string]$ItemType = '',
            $Value = $null,
            [switch]$Force,
            [switch]$RedactValue   # when set, logs '***REDACTED***' instead of the actual value
        )
        $logValue = if ($RedactValue) { '***REDACTED***' } else { $Value }
        $displayParts = @("'$Path'")
        if ($Name) { $displayParts += "-Name '$Name'" }
        if ($ItemType) { $displayParts += "-ItemType '$ItemType'" }
        if ($null -ne $logValue -and $logValue -ne '') { $displayParts += "-Value '$logValue'" }
        Write-Host "  [exec] New-Item $($displayParts -join ' ')" -ForegroundColor DarkGray
        $details = @{ Operation = 'New-Item'; Path = $Path; Name = $Name; ItemType = $ItemType; Value = $logValue }
        Invoke-Logged -Description 'New-Item' -Details $details -ScriptBlock {
            if ($Name -and $ItemType -and $null -ne $Value) {
                New-Item -Path $Path -Name $Name -ItemType $ItemType -Value $Value -Force:$Force | Out-Null
            }
            elseif ($Name -and $ItemType) {
                New-Item -Path $Path -Name $Name -ItemType $ItemType -Force:$Force | Out-Null
            }
            elseif ($ItemType) {
                New-Item -Path $Path -ItemType $ItemType -Force:$Force | Out-Null
            }
            else {
                New-Item -Path $Path -Force:$Force | Out-Null
            }
        }
    }

    # Remove-ItemProperty wrapper (registry)
    function Remove-ItemProperty-Logged {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Name,
            [switch]$Force
        )
        Write-Host "  [exec] Remove-ItemProperty '$Path' -Name '$Name'" -ForegroundColor DarkGray
        $details = @{ Operation = 'Remove-ItemProperty'; Path = $Path; Name = $Name }
        Invoke-Logged -Description 'Remove-ItemProperty' -Details $details -ScriptBlock { Remove-ItemProperty -Path $Path -Name $Name -Force:$Force }
    }

    # Copy (file/directory) wrapper
    function Copy-Item-Logged {
        param(
            [Parameter(Mandatory = $true)]$Path,
            [Parameter(Mandatory = $true)]$Destination,
            [switch]$Recurse,
            [switch]$Force
        )
        $recurseStr = if ($Recurse) { ' -Recurse' } else { '' }
        Write-Host "  [exec] Copy-Item$recurseStr '$Path' -> '$Destination'" -ForegroundColor DarkGray
        $details = @{ Operation = 'Copy-Item'; Path = $Path; Destination = $Destination }
        Invoke-Logged -Description 'Copy-Item' -Details $details -ScriptBlock {
            Copy-Item -Path $Path -Destination $Destination -Recurse:$Recurse -Force:$Force -ErrorAction SilentlyContinue
        }
    }


    # Helper: Detect partition role (Windows, Boot, or Unknown)
    function Get-PartitionRole {
        param(
            [Parameter(Mandatory = $true)][string]$AccessPath,
            [Parameter(Mandatory = $true)]$PartitionInfo
        )
    
        $role = @()
    
        # Check for Windows partition
        $winPath = Join-Path $AccessPath "Windows\System32\ntdll.dll"
        if (Test-Path $winPath) {
            $role += "Windows"
        }
    
        # Check for UEFI/GPT Boot partition.
        # Primary check: BCD file present. Secondary: GPT System partition with EFI folder tree
        # (covers the case where BCD was deleted but the partition structure is intact).
        $efiPathBcd = Join-Path $AccessPath "EFI\Microsoft\Boot\BCD"
        $efiPathDir = Join-Path $AccessPath "EFI\Microsoft\Boot"
        $isEfiPartition = $PartitionInfo.Type -eq 'System'
        if ($isEfiPartition -and (Test-Path $efiPathBcd)) {
            $role += "Boot (UEFI)"
        }
        elseif ($isEfiPartition -and (Test-Path $efiPathDir)) {
            $role += "Boot (UEFI - BCD missing)"
        }
        elseif ($isEfiPartition) {
            $role += "Boot (UEFI - EFI folder missing)"
        }
    
        # Check for BIOS/MBR Boot partition
        $biosPathBcd = Join-Path $AccessPath "Boot\BCD"
        $biosPathDir = Join-Path $AccessPath "Boot"
        $isActivePartition = $PartitionInfo.IsActive
        if ($isActivePartition -and (Test-Path $biosPathBcd)) {
            $role += "Boot (BIOS)"
        }
        elseif ($isActivePartition -and (Test-Path $biosPathDir)) {
            $role += "Boot (BIOS - BCD missing)"
        }
        elseif ($isActivePartition) {
            $role += "Boot (BIOS - Boot folder missing)"
        }
    
        if ($role.Count -eq 0) {
            return "Unknown"
        }
        return $role -join " + "
    }

    # Helper: Detect disk generation (BIOS vs UEFI) based on partitions
    function Get-DiskGeneration {
        param(
            [Parameter(Mandatory = $true)]$Disk
        )
    
        # Check partition table style
        $partStyle = $Disk.PartitionStyle
    
        if ($partStyle -eq 'GPT') {
            return 2  # UEFI/GPT = Gen2
        }
        elseif ($partStyle -eq 'MBR') {
            return 1  # BIOS/MBR = Gen1
        }
    
        return $null
    }

    # Helper: Executes a PowerShell command as the SYSTEM account using a temporary scheduled task.
    function ExecuteAsSystem($cmd) {
        Write-Host "  [exec] ExecuteAsSystem: $cmd" -ForegroundColor DarkGray
        Try {
            $taskName = "TempSystemTask_$([guid]::NewGuid().ToString())"
            # Encode the command as Base64 and use -EncodedCommand so that special
            # characters in the command string (e.g. quotes, spaces in paths) cannot
            # break out of the argument and inject arbitrary code.
            $encodedCmd = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
            $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -EncodedCommand $encodedCmd"
            $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)

            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal | Out-Null

            Start-ScheduledTask -TaskName $taskName

            While ((Get-ScheduledTask -TaskName $taskName).State -eq "Running" -Or (Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime -notmatch (Get-Date).ToString("yyyy")) {
                Start-Sleep -Seconds 1
            }

            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        }
        Catch {
            Write-Error "Failed to execute command as SYSTEM: $_"
        }
    }

    function MountOffHive {
        param(
            [string] $WinPath,
            [string] $Hive
        )

        if ($Hive -eq "SYSTEM") {
            $OffHive = Join-Path $WinPath 'System32\Config\SYSTEM'
        }
        elseif ($Hive -eq "SOFTWARE") {
            $OffHive = Join-Path $WinPath 'System32\Config\SOFTWARE'
        }
        elseif ($Hive -eq "COMPONENTS") {
            $OffHive = Join-Path $WinPath 'System32\Config\COMPONENTS'
        }
        elseif ($Hive -eq "SAM") {
            $OffHive = Join-Path $WinPath 'System32\Config\SAM'
        }
        elseif ($Hive -eq "SECURITY") {
            $OffHive = Join-Path $WinPath 'System32\Config\SECURITY'
        }

        if (-not (Test-Path $OffHive)) { throw "$Hive hive not found: $OffHive" }

        # If the hive is already loaded (e.g. from a previous failed unload), skip the load
        if (Test-Path "HKLM:\BROKEN$Hive") {
            Write-Host "HKLM\BROKEN$Hive is already loaded - reusing existing mount." -ForegroundColor DarkGray
            return
        }

        Write-Host "reg load HKLM\BROKEN$($Hive) `"$OffHive`""
        $out = reg.exe load HKLM\BROKEN$($Hive) "$OffHive" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            if ($out -match 'being used by another process|locked') {
                # The hive file is already loaded under a different key name.
                # Scan HKLM for non-standard keys to help the user identify it.
                $stdKeys = @('BCD00000000', 'HARDWARE', 'SAM', 'SECURITY', 'SOFTWARE', 'SYSTEM',
                    'BROKENSYSTEM', 'BROKENSOFTWARE', 'BROKENCOMPONENTS', 'BROKENSAM', 'BROKENSECURITY')
                $foreign = reg.exe query HKLM 2>&1 | ForEach-Object {
                    if ($_ -match '^HKEY_LOCAL_MACHINE\\(.+)$') { $Matches[1] }
                } | Where-Object { $_ -notin $stdKeys }
                $hint = if ($foreign) {
                    "Found non-standard HKLM keys that may be the loaded hive: $($foreign -join ', '). Unload them first (reg unload HKLM\<keyname>)."
                }
                else {
                    "Check if the hive file is loaded under a different key name (reg query HKLM) and unload it first."
                }
                throw "Cannot load $Hive hive - the file is already in use by another process. $hint"
            }
            throw "Failed to load offline $Hive hive: $($out.Trim())"
        }
    }

    function UnmountOffHive {
        param(
            [string] $Hive
        )

        $hiveKey = "HKLM\BROKEN$Hive"

        # Pre-check: verify the hive is actually loaded before attempting to unload.
        # Use reg.exe query (separate process, no .NET handles) instead of Test-Path.
        $null = reg.exe query $hiveKey /ve 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  $hiveKey is not currently loaded - nothing to unload."
            return
        }

        # Release cached .NET RegistryKey handles held by PowerShell's registry provider.
        # DO NOT call Test-Path/Get-Item on the hive path here - those open NEW handles.
        # Clear $Error to drop any ErrorRecord objects that may reference provider context.
        $Error.Clear()
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        Start-Sleep -Milliseconds 500

        Write-Host "reg unload $hiveKey"
        $maxAttempts = 6
        for ($i = 1; $i -le $maxAttempts; $i++) {
            $out = reg.exe unload $hiveKey 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) { return }
            if ($out -match 'unable to find|parameter is incorrect') { return }
            if ($i -lt $maxAttempts) {
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                [GC]::Collect()
                Start-Sleep -Milliseconds (500 + ($i * 500))
            }
        }
        Write-Warning "Failed to unload $hiveKey after $maxAttempts attempts: $($out.Trim()). The hive may still be loaded; use -UnloadHive $Hive before retrying."
    }

    function Invoke-WithHive {
        # Mounts one or more offline registry hives, executes the given script block,
        # and guarantees the hives are unmounted in the finally block (reverse order).
        # Usage:  Invoke-WithHive 'SYSTEM' { <body> }
        #         Invoke-WithHive 'SYSTEM','SOFTWARE' { <body> }
        param(
            [Parameter(Mandatory)][string[]]$Hive,
            [Parameter(Mandatory)][scriptblock]$ScriptBlock
        )
        $wp = Join-Path $script:WinDriveLetter "Windows"
        foreach ($h in $Hive) { MountOffHive -WinPath $wp -Hive $h }
        try {
            # Opportunistically capture the guest computer name the first time
            # the SYSTEM hive is loaded for any reason (avoids a dedicated load).
            if ($Hive -contains 'SYSTEM' -and -not $script:GuestComputerName) {
                try {
                    $sysRoot = Get-SystemRootPath
                    $script:GuestComputerName = (Get-ItemProperty "$sysRoot\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue).ComputerName
                    if ($script:GuestComputerName) {
                        Write-Host "[OK] Guest name   : $($script:GuestComputerName)" -ForegroundColor Green
                        Write-Host ""
                    }
                }
                catch { <# non-critical #> }
            }
            & $ScriptBlock
        }
        finally {
            for ($i = $Hive.Count - 1; $i -ge 0; $i--) { UnmountOffHive -Hive $Hive[$i] }
        }
    }

    # Resolves an offline guest ImagePath (\SystemRoot\, %SystemRoot%, system32\, C:\, etc.)
    # to a local path on the attached drive letter. Strips the trailing extension match too.
    function Resolve-GuestImagePath {
        param([string]$ImagePath)
        $drive = $script:WinDriveLetter.TrimEnd('\')
        $resolved = $ImagePath `
            -replace '(?i)\\SystemRoot\\', "$drive\Windows\" `
            -replace '(?i)%SystemRoot%', "$drive\Windows" `
            -replace '(?i)\\\?\?\\', '' `
            -replace '(?i)^system32\\', "$drive\Windows\System32\" `
            -replace '(?i)^"?[A-Z]:\\', "$drive\"
        if ($resolved -match '^(.+?\.(?:sys|exe|dll))') { $resolved = $Matches[1] }
        return $resolved
    }

    # Helper: Verify a binary on the offline disk carries a valid Microsoft Authenticode signature.
    # Returns a PSCustomObject with .IsSigned, .IsMicrosoft, .Status, and .Subject.
    # Uses Get-AuthenticodeSignature which works on offline (non-running) files.
    # Performance note: signature verification involves reading the PE embedded catalog
    # or catalog lookup, which takes ~10-40 ms per file. Callers should batch results
    # or limit checks to high-value targets (boot binaries, session init, synthetic drivers).
    function Test-MicrosoftSignature {
        param(
            [Parameter(Mandatory)][string]$FilePath
        )

        $result = [PSCustomObject]@{
            Path        = $FilePath
            IsSigned    = $false
            IsMicrosoft = $false
            Status      = 'FileNotFound'
            Subject     = ''
        }

        if (-not (Test-Path -LiteralPath $FilePath)) { return $result }
        if ((Get-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue).Length -eq 0) {
            $result.Status = 'ZeroByte'
            return $result
        }

        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $FilePath -ErrorAction Stop
        }
        catch {
            $result.Status = 'Error'
            return $result
        }

        $result.Status = [string]$sig.Status
        $result.Subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }

        if ($sig.Status -eq 'Valid') {
            $result.IsSigned = $true
            # Match on Microsoft certificate subject  -  covers:
            #   CN=Microsoft Windows, O=Microsoft Corporation
            #   CN=Microsoft Corporation, O=Microsoft Corporation
            #   CN=Microsoft Windows Publisher, O=Microsoft Corporation
            #   CN=Microsoft Code Signing PCA ... (intermediate)
            if ($result.Subject -match 'O=Microsoft Corporation') {
                $result.IsMicrosoft = $true
            }
        }
        else {
            # Catalog-signed files (most Windows inbox binaries) show NotSigned when
            # checked on an offline disk because the catalog store is not available.
            # Boot manager files (bootmgr, bootmgfw.efi) are compressed stubs that
            # return UnknownError because they aren't standard PE executables.
            # Fall back to checking the file's VersionInfo for Microsoft vendor strings.
            $vi = (Get-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue).VersionInfo
            if ($vi -and $vi.CompanyName -match 'Microsoft') {
                $result.IsSigned = $true
                $result.IsMicrosoft = $true
                $result.Status = 'CatalogSigned'
                $result.Subject = $vi.CompanyName
            }
            elseif ($sig.Status -in @('UnknownError', 'NotSupportedFileFormat')) {
                # File format not parseable by Authenticode (compressed boot stub, etc.)
                # and no VersionInfo available  -  mark as inconclusive rather than suspect.
                $result.Status = 'NotVerifiable'
                $result.IsSigned = $true
                $result.IsMicrosoft = $true
            }
        }

        return $result
    }

    # Validate user-supplied service/driver names before using them in registry paths.
    # Allowed characters: letters, digits, underscore, dot, hyphen.
    function Assert-ValidServiceOrDriverName {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [string]$ParameterName = 'ServiceName'
        )

        $trimmed = $Name.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            throw "Invalid ${ParameterName}: value cannot be empty."
        }
        if ($trimmed.Length -gt 128 -or $trimmed -notmatch '^[A-Za-z0-9_.-]+$') {
            throw "Invalid $ParameterName '$Name'. Allowed characters: A-Z, a-z, 0-9, underscore (_), dot (.), hyphen (-)."
        }
        return $trimmed
    }

    # Helper: Disable service or driver
    function Disable-ServiceOrDriver {
        param(
            [Parameter(Mandatory = $true)][string]$ServiceName
        )

        $ServiceName = Assert-ValidServiceOrDriverName -Name $ServiceName -ParameterName 'DisableDriverOrService'

        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath
            $ServiceFullPath = "$SystemRoot\Services\$ServiceName"

            if (Test-Path $ServiceFullPath) {
                $CurrentValue = (Get-ItemProperty -Path $ServiceFullPath -Name Start).Start
                Write-Host "Current $ServiceName Start -> $CurrentValue`r`nSetting to 4."
                Set-ItemProperty-Logged -Path $ServiceFullPath -Name Start -Value 4 -Type DWord -Force
            }
            else {
                Write-Host "Service path $ServiceFullPath not found."
            }

            # Warn if the driver is listed in UpperFilters or LowerFilters of critical device classes.
            # Disabling a filter driver (Start=4) does NOT remove it from the class filter list.
            # On next boot the class manager will attempt to load it, fail, and likely cause:
            #   - stop error 0x7B (INACCESSIBLE_BOOT_DEVICE) for disk/SCSI/volume classes
            #   - complete loss of network connectivity for the Net class
            $csName = ($SystemRoot -replace '^HKLM:\\BROKENSYSTEM\\', '') -replace '\\.*', ''
            $classRoot = "HKLM:\BROKENSYSTEM\$csName\Control\Class"
            $critClasses = @(
                @{ GUID = '{4d36e967-e325-11ce-bfc1-08002be10318}'; Name = 'DiskDrive' }
                @{ GUID = '{4d36e96a-e325-11ce-bfc1-08002be10318}'; Name = 'SCSIAdapter' }
                @{ GUID = '{4d36e97b-e325-11ce-bfc1-08002be10318}'; Name = 'SCSIController' }
                @{ GUID = '{71a27cdd-812a-11d0-bec7-08002be2092f}'; Name = 'Volume' }
                @{ GUID = '{4d36e972-e325-11ce-bfc1-08002be10318}'; Name = 'Net' }
            )
            $filterHits = [System.Collections.Generic.List[string]]::new()
            foreach ($cls in $critClasses) {
                $cp = "$classRoot\$($cls.GUID)"
                if (-not (Test-Path $cp)) { continue }
                foreach ($ft in @('UpperFilters', 'LowerFilters')) {
                    $raw = (Get-ItemProperty $cp -ErrorAction SilentlyContinue).$ft
                    $entries = @($raw | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
                    if ($entries -icontains $ServiceName) {
                        $filterHits.Add("$($cls.Name) $ft")
                    }
                }
            }
            if ($filterHits.Count -gt 0) {
                Write-Warning ""
                Write-Warning "*** FILTER REGISTRATION DETECTED - ACTION REQUIRED ***"
                Write-Warning "'$ServiceName' is still registered as a device class filter in:"
                foreach ($hit in $filterHits) {
                    Write-Warning "    $hit"
                }
                Write-Warning ""
                Write-Warning "Setting Start=4 does NOT remove the driver from the filter list."
                Write-Warning "On next boot, Windows will attempt to load '$ServiceName' as a filter,"
                Write-Warning "fail (driver disabled), and likely cause stop error 0x7B"
                Write-Warning "(INACCESSIBLE_BOOT_DEVICE) or total loss of network connectivity."
                Write-Warning ""
                Write-Warning "Recommended actions (choose one):"
                Write-Warning "  1. Run  -FixDeviceFilters  to automatically remove unsafe filter entries."
                Write-Warning "  2. Manually remove '$ServiceName' from the UpperFilters/LowerFilters"
                Write-Warning "     registry value in the listed class key(s) before booting the VM."
            }
        }
    }

    # Helper: Enable service or driver
    function Enable-ServiceOrDriver {
        param(
            [Parameter(Mandatory = $true)][string]$ServiceName,
            [Parameter(Mandatory = $true)]$StartValue
        )

        $ServiceName = Assert-ValidServiceOrDriverName -Name $ServiceName -ParameterName 'EnableDriverOrService'

        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath
            $ServiceFullPath = "$SystemRoot\Services\$ServiceName"

            if (Test-Path $ServiceFullPath) {
                $CurrentValue = (Get-ItemProperty -Path $ServiceFullPath -Name Start -ErrorAction SilentlyContinue).Start
                if ($null -ne $CurrentValue -and [int]$CurrentValue -eq [int]$StartValue) {
                    Write-Host "  $ServiceName Start = $CurrentValue (already correct, no change needed)." -ForegroundColor DarkGray
                }
                else {
                    Write-Host "  $ServiceName Start: $CurrentValue -> $StartValue" -ForegroundColor Cyan
                    Set-ItemProperty-Logged -Path $ServiceFullPath -Name Start -Value $StartValue -Type DWord -Force
                }
            }
            else {
                Write-Host "Service path $ServiceFullPath not found." -ForegroundColor Yellow
            }
        }
    }

    # Helper: Enable registry periodic backups (regback)
    function EnableRegBackup {
        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath

            Write-Host "Enabling registry backup feature..." #https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/system-registry-no-backed-up-regback-folder
            Set-ItemProperty-Logged -Path "$SystemRoot\Control\Session Manager\Configuration Manager" -Name EnablePeriodicBackup -Value 1 -Type DWord -Force
        }
    }

    # Helper to create key + set DWORD value (uses Set-ItemProperty-Logged for full audit trail)
    function Set-DwordValue {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][int]$Value
        )
        Set-ItemProperty-Logged -Path $Path -Name $Name -Value $Value -Type DWord -Force

        [PSCustomObject]@{
            RegistryPath = $Path
            Name         = $Name
            Value        = $Value
        }
    }

    ################################################################################
    #+ Operational functions (moved from previous inline flow)
    ################################################################################

    # Helper: Asks the user to confirm before running an operation that makes
    # significant changes (large file deletions, hive overwrites, bulk driver changes).
    # Returns $true if the user types 'Y', $false to skip with no changes made.
    function Confirm-CriticalOperation {
        param(
            [Parameter(Mandatory)][string]$Operation,
            [Parameter(Mandatory)][string]$Details
        )

        Write-Host ""
        Write-Host "  $Operation" -ForegroundColor Cyan
        Write-Host "  What this will do:" -ForegroundColor DarkGray
        $Details -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host "  Note: the live hives / files are backed up first where possible, but" -ForegroundColor DarkGray
        Write-Host "  having a VM snapshot before running this is always a good idea." -ForegroundColor DarkGray
        Write-Host ""

        $answer = Read-Host "  Continue? [Y] Yes  [N] No (default: No)"
        if ($answer -ne 'Y' -and $answer -ne 'y') {
            Write-Host "  Skipped. No changes were made." -ForegroundColor DarkGray
            return $false
        }
        return $true
    }

    function Get-SystemRootPath {
        # Returns the active ControlSet path in the mounted BROKENSYSTEM hive.
        # Falls back to ControlSet001 when the Select key is absent (e.g. offline WinPE disks).
        $current = (Get-ItemProperty 'HKLM:\BROKENSYSTEM\Select' -ErrorAction SilentlyContinue).Current
        if ($current) { return 'HKLM:\BROKENSYSTEM\ControlSet{0:d3}' -f $current }
        return 'HKLM:\BROKENSYSTEM\ControlSet001'
    }

    function Ensure-GuestTempDir {
        # Creates the \Temp directory on the offline guest disk if it does not already exist.
        if (-not (Test-Path -Path "$script:WinDriveLetter\Temp")) {
            New-Item-Logged -Path "$script:WinDriveLetter\Temp" -ItemType Directory -Force | Out-Null
        }
    }

    function FixDiskCorruption {
        param([string]$DriveLetter = '')
        $target = if ($DriveLetter) { $DriveLetter.TrimEnd('\') } else { $script:WinDriveLetter.TrimEnd('\') }
        Write-Host "Running chkdsk on $target ..." -ForegroundColor Yellow
        try {
            & chkdsk $target /F /X
        }
        catch {
            Write-Error "FixDiskCorruption failed: $_"
        }
    }

    function RunDismHealth {
        param([string]$RepairSource = '')

        Write-Host "Repairing component store (DISM ScanHealth + RestoreHealth)..." -ForegroundColor Yellow
        try {
            if (-not (Test-Path "C:\temp")) { mkdir C:\temp | Out-Null }

            # Detect guest OS build to warn about version mismatch with host
            $guestBuild = $null
            try {
                Invoke-WithHive 'SOFTWARE' {
                    $cv = Get-ItemProperty 'HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
                    if ($cv) { $script:_guestBuild = $cv.CurrentBuildNumber }
                }
                $guestBuild = $script:_guestBuild
            }
            catch {}
            $hostBuild = [System.Environment]::OSVersion.Version.Build

            # Determine repair source
            $sourceArg = ''
            $mountedIso = $null
            $extractedCab = $null

            if ($RepairSource) {
                if (-not (Test-Path $RepairSource)) {
                    Write-Error "RepairSource file not found: $RepairSource"
                    return
                }

                $ext = [System.IO.Path]::GetExtension($RepairSource).ToLower()
                switch ($ext) {
                    '.iso' {
                        Write-Host "Mounting ISO: $RepairSource" -ForegroundColor Cyan
                        $mountResult = Mount-DiskImage -ImagePath (Resolve-Path $RepairSource).Path -PassThru
                        $mountedIso = (Resolve-Path $RepairSource).Path
                        $isoDrive = ($mountResult | Get-Volume).DriveLetter
                        $wimPath = "$($isoDrive):\sources\install.wim"
                        if (-not (Test-Path $wimPath)) {
                            Write-Error "install.wim not found at $wimPath inside the ISO."
                            return
                        }
                        Write-Host "Available images in WIM:" -ForegroundColor Cyan
                        & dism /Get-WimInfo /WimFile:"$wimPath" | Out-Host
                        $wimIndex = Read-Host "Enter the image index to use as repair source (e.g. 1, 2, 3)"
                        $sourceArg = "/Source:wim:$($wimPath):$wimIndex /LimitAccess"
                        Write-Host "Using ISO source: wim:$($wimPath):$wimIndex" -ForegroundColor Green
                    }
                    '.wim' {
                        Write-Host "Available images in WIM:" -ForegroundColor Cyan
                        & dism /Get-WimInfo /WimFile:"$RepairSource" | Out-Host
                        $wimIndex = Read-Host "Enter the image index to use as repair source (e.g. 1, 2, 3)"
                        $sourceArg = "/Source:wim:$($RepairSource):$wimIndex /LimitAccess"
                        Write-Host "Using WIM source: wim:$($RepairSource):$wimIndex" -ForegroundColor Green
                    }
                    '.msu' {
                        Write-Host "Extracting .msu to C:\temp\RepairSource_msu ..." -ForegroundColor Cyan
                        $msuExtract = 'C:\temp\RepairSource_msu'
                        if (Test-Path $msuExtract) { Remove-Item $msuExtract -Recurse -Force }
                        New-Item $msuExtract -ItemType Directory -Force | Out-Null
                        & expand.exe -F:* $RepairSource $msuExtract | Out-Null
                        $cabFile = Get-ChildItem $msuExtract -Filter '*.cab' | Where-Object { $_.Name -ne 'WSUSSCAN.cab' } | Select-Object -First 1
                        if (-not $cabFile) {
                            Write-Error "No payload .cab found inside the .msu."
                            return
                        }
                        Write-Host "Extracted cab: $($cabFile.Name)" -ForegroundColor Cyan
                        $sourceArg = "/Source:$($cabFile.FullName) /LimitAccess"
                        $extractedCab = $msuExtract
                        Write-Host "Using MSU/CAB source: $($cabFile.FullName)" -ForegroundColor Green
                    }
                    '.cab' {
                        $sourceArg = "/Source:$RepairSource /LimitAccess"
                        Write-Host "Using CAB source: $RepairSource" -ForegroundColor Green
                    }
                    default {
                        Write-Error "Unsupported RepairSource format '$ext'. Accepted: .wim, .iso, .msu, .cab"
                        return
                    }
                }
            }
            else {
                # No explicit source - check version match
                if ($guestBuild -and $hostBuild -and $guestBuild -ne "$hostBuild") {
                    Write-Warning "Guest OS build ($guestBuild) differs from host OS build ($hostBuild)."
                    Write-Warning "DISM /RestoreHealth will use the host's WinSxS as source, which may not have"
                    Write-Warning "matching components for the guest OS - this typically causes CBS_E_SOURCE_MISSING."
                    Write-Warning ""
                    Write-Warning "To provide a matching source, use one of:"
                    Write-Warning "  -RepairComponentStore -RepairSource <path-to-install.wim>"
                    Write-Warning "  -RepairComponentStore -RepairSource <path-to-.iso>"
                    Write-Warning "  -RepairComponentStore -RepairSource <path-to-cumulative-update.msu>"
                    Write-Warning ""
                    Write-Warning "Tip: Run -AnalyzeComponentStore first to identify exactly which components are"
                    Write-Warning "corrupt and which KB/update you need to download."
                    Write-Warning ""
                    $answer = Read-Host "Continue anyway with host WinSxS as source? [Y/N] (default: N)"
                    if ($answer -ne 'Y' -and $answer -ne 'y') {
                        Write-Host "Skipped. Run -AnalyzeComponentStore to identify the needed update." -ForegroundColor DarkGray
                        return
                    }
                }
                $sourceArg = "/Source:C:\Windows\WinSxS /LimitAccess"
            }

            Write-Host "Step 1/2: ScanHealth" -ForegroundColor Cyan
            & dism /Image:$script:WinDriveLetter /Cleanup-Image /ScanHealth /ScratchDir:C:\Temp

            Write-Host "Step 2/2: RestoreHealth" -ForegroundColor Cyan
            $restoreCmd = "dism /Image:$($script:WinDriveLetter) /Cleanup-Image /RestoreHealth $sourceArg /ScratchDir:C:\Temp"
            Write-Host "  [exec] $restoreCmd" -ForegroundColor DarkGray
            & cmd.exe /c $restoreCmd
        }
        catch {
            Write-Error "RepairComponentStore failed: $_"
            throw
        }
        finally {
            if ($mountedIso -and (Get-DiskImage -ImagePath $mountedIso -ErrorAction SilentlyContinue).Attached) {
                Write-Host "Dismounting ISO..." -ForegroundColor Cyan
                Dismount-DiskImage -ImagePath $mountedIso | Out-Null
            }
            if ($extractedCab -and (Test-Path $extractedCab)) {
                Remove-Item $extractedCab -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    function RunSFC {
        Write-Host "Executing SFC /scannow"
        try {
            $sfcCmd = "sfc /SCANNOW /OFFBOOTDIR=$script:WinDriveLetter /OFFWINDIR=$($script:WinDriveLetter)windows"
            Write-Host "  [exec] $sfcCmd" -ForegroundColor DarkGray
            & sfc /SCANNOW /OFFBOOTDIR=$script:WinDriveLetter /OFFWINDIR=$($script:WinDriveLetter)windows
        }
        catch {
            Write-Error "RunSFC failed: $_"
        }
    }

    function SetLKGC {
        Invoke-WithHive 'SYSTEM' {
            $CurrentBoot = (Get-ItemProperty -Path "HKLM:\BROKENSYSTEM\Select" -Name Current).Current
            $LastKnownGood = (Get-ItemProperty -Path "HKLM:\BROKENSYSTEM\Select" -Name LastKnownGood).LastKnownGood
            Write-Host "Current HKLM: $CurrentBoot`r`nLast Known Good: $LastKnownGood" -ForegroundColor Green
            Write-Host "`r`nSetting next boot to LKGD: $LastKnownGood" -ForegroundColor Yellow
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Select" -Name Current -Value $LastKnownGood -Type DWord -Force
        }
    }

    function RevertLKGC {
        Invoke-WithHive 'SYSTEM' {
            & {
                $CurrentBoot = (Get-ItemProperty -Path "HKLM:\BROKENSYSTEM\Select" -Name Current).Current
                Write-Host "Current HKLM: $CurrentBoot" -ForegroundColor Green

                $NextSetting = Get-ChildItem 'HKLM:\BROKENSYSTEM' |
                Where-Object { $_.PSChildName -like 'ControlSet*' } |
                ForEach-Object {
                    [int]($_.PSChildName -replace 'ControlSet00', '')
                } |
                Where-Object { $_ -ne $CurrentBoot } |
                Select-Object -First 1

                Write-Host "`r`nSetting boot registry to: $NextSetting" -ForegroundColor Yellow
                Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Select" -Name Current -Value $NextSetting -Type DWord -Force
            }
        }
    }

    function SetBootLog {
        $storePath = Get-BcdStorePath -Generation $script:VMGen -BootDrive $script:BootDriveLetter
        $identifier = Get-BcdBootLoaderId -StorePath $storePath
    
        if (-not $identifier) { return }
    
        Write-Host "Enabling boot logging..." -ForegroundColor Green

        $NtBtLog = Join-Path $script:WinDriveLetter "Windows\ntbtlog.txt"
        if (Test-Path $NtBtLog) {
            Write-Host "Deleting existing ntbtlog.txt..." -ForegroundColor Yellow
            Remove-Item-Logged -Path $NtBtLog -Force
        }

        Invoke-BcdEdit -StorePath $storePath -Command "/set $identifier bootlog yes"
    }

    function SetSafeMode {
        $storePath = Get-BcdStorePath -Generation $script:VMGen -BootDrive $script:BootDriveLetter
        $identifier = Get-BcdBootLoaderId -StorePath $storePath
    
        if (-not $identifier) { return }
    
        Write-Host "Setting Safe Mode minimal flag..." -ForegroundColor Green
        Invoke-BcdEdit -StorePath $storePath -Command "/set $identifier safeboot minimal"
    }

    function RemoveSafeMode {
        $storePath = Get-BcdStorePath -Generation $script:VMGen -BootDrive $script:BootDriveLetter
        $identifier = Get-BcdBootLoaderId -StorePath $storePath
    
        if (-not $identifier) { return }
    
        Write-Host "Removing Safe Mode flag..."
        Invoke-BcdEdit -StorePath $storePath -Command "/deletevalue $identifier safeboot"
    }

    function ConfigureFullMemDump {
        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath

            Write-Host "Configuring full memory dump settings..." -ForegroundColor Yellow
            Set-ItemProperty-Logged -Path "$SystemRoot\Control\CrashControl" -Name CrashDumpEnabled -Value 1 -Type DWord -Force
            Set-ItemProperty-Logged -Path "$SystemRoot\Control\CrashControl" -Name DumpFile -Value "C:\Windows\MEMORY.dmp" -Type ExpandString -Force
            Set-ItemProperty-Logged -Path "$SystemRoot\Control\CrashControl" -Name DedicatedDumpFile -Value "C:\DD.sys" -Type String -Force
            Set-ItemProperty-Logged -Path "$SystemRoot\Control\CrashControl" -Name Overwrite -Value 1 -Type DWord -Force
            Set-ItemProperty-Logged -Path "$SystemRoot\Control\CrashControl" -Name NMICrashDump -Value 1 -Type DWord -Force
            Set-ItemProperty-Logged -Path "$SystemRoot\Control\CrashControl" -Name AutoReboot -Value 1 -Type DWord -Force

            Write-Host "Check for dump as 'C:\Windows\MEMORY.dmp'." -ForegroundColor Green

            $CurrentPagefile = (Get-ItemProperty -Path "$SystemRoot\Control\Session Manager\Memory Management" -Name PagingFiles).PagingFiles
            if ($CurrentPagefile -notmatch "C:") {
                Write-Host "Configuring pagefile to C: drive..." -ForegroundColor Yellow
                Set-ItemProperty-Logged -Path "$SystemRoot\Control\Session Manager\Memory Management" -Name PagingFiles -Value "C:\pagefile.sys 0 0" -Type MultiString -Force
            }
        }
    }

    function RebuildBCD {
        try {
            # Guard: verify the boot partition exists before trying to write to it
            $rbcPartitions = Get-Partition -DiskNumber $script:DiskNumber -ErrorAction SilentlyContinue
            if ($script:VMGen -eq 2) {
                $rbcEsp = $rbcPartitions | Where-Object { $_.Type -eq 'System' }
                if (-not $rbcEsp) {
                    Write-Error "EFI System Partition does not exist on disk $($script:DiskNumber). Run -RecreateBootPartition first to create the ESP, then -FixBoot if needed."
                    return
                }
            }
            else {
                $rbcWinTrimmed = $script:WinDriveLetter.TrimEnd('\')
                $rbcBootTrimmed = $script:BootDriveLetter.TrimEnd('\')
                if ($rbcWinTrimmed -eq $rbcBootTrimmed) {
                    # Boot and Windows are the same drive - check it's Active
                    $rbcWinPart = $rbcPartitions | Where-Object {
                        $_.AccessPaths | Where-Object { $_ -and $_.TrimEnd('\') -eq $rbcWinTrimmed }
                    }
                    if ($rbcWinPart -and -not $rbcWinPart.IsActive) {
                        Write-Warning "Windows partition is not Active. Setting Active flag so BIOS can find the boot sector..."
                        Set-Partition -DiskNumber $script:DiskNumber -PartitionNumber $rbcWinPart.PartitionNumber -IsActive $true
                    }
                }
            }

            $storePath = Get-BcdStorePath -Generation $script:VMGen -BootDrive $script:BootDriveLetter

            # Backup existing BCD if present
            if (Test-Path -LiteralPath $storePath) {
                $bakPath = New-UniqueBackupPath -BasePath $storePath -BakSuffix ".bak"
                Write-Host "Renaming BCD: $storePath -> $bakPath"
                Move-Item-Logged -LiteralPath $storePath -Destination $bakPath -Force
            }
            else {
                Write-Warning "BCD not found at $storePath; will still run bcdboot to create a fresh store."
            }

            # Prepare drive letters (strip trailing backslashes for bcdboot syntax)
            $WinDrive = $script:WinDriveLetter.TrimEnd('\')
            $SysDrive = $script:BootDriveLetter.TrimEnd('\')

            # Rebuild BCD from scratch
            $format = if ($script:VMGen -eq 1) { "BIOS" } else { "UEFI" }
            $rebuildCmd = "bcdboot $WinDrive\Windows /s $SysDrive /v /f $format"
            Write-Host "Rebuilding BCD (Gen$script:VMGen): $rebuildCmd"
            & cmd.exe /c $rebuildCmd

            # Verify rebuild
            $verifyCmd = "bcdedit /store `"$storePath`" /enum"
            Write-Host "Verifying: $verifyCmd"
            & cmd.exe /c $verifyCmd | Out-Host

            # Get boot loader identifier
            $identifier = Get-BcdBootLoaderId -StorePath $storePath
            if (-not $identifier) { return }

            # Apply additional boot configuration flags (same for both Gen1 and Gen2)
            $extraCmds = @(
                "/set $identifier integrityservices enable",
                "/set $identifier recoveryenabled Off",
                "/set $identifier bootstatuspolicy IgnoreAllFailures",
                "/set {bootmgr} displaybootmenu yes",
                "/set {bootmgr} timeout 5",
                "/set {bootmgr} bootems yes",
                "/ems $identifier on",
                "/emssettings EMSPORT:1 EMSBAUDRATE:115200"
            )

            foreach ($cmd in $extraCmds) {
                Write-Host "Applying extra setting: $cmd" -ForegroundColor Yellow
                Invoke-BcdEdit -StorePath $storePath -Command $cmd
            }

            # Gen1 (BIOS/MBR): ensure the boot partition is marked as Active.
            # Without the Active flag the BIOS has no way to find the boot sector
            # and the VM fails with a black screen / "No bootable device".
            if ($script:VMGen -eq 1) {
                $bootPartition = Get-Partition -DiskNumber $script:DiskNumber -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.AccessPaths | Where-Object {
                        $_ -and $script:BootDriveLetter.TrimEnd('\') -eq $_.TrimEnd('\')
                    }
                }
                if ($bootPartition -and -not $bootPartition.IsActive) {
                    Write-Host "Boot partition (Partition $($bootPartition.PartitionNumber)) is not marked Active - setting Active flag..." -ForegroundColor Yellow
                    Set-Partition -DiskNumber $script:DiskNumber -PartitionNumber $bootPartition.PartitionNumber -IsActive $true
                    Write-ActionLog -Event 'SetBootPartitionActive' -Details @{
                        DiskNumber      = $script:DiskNumber
                        PartitionNumber = $bootPartition.PartitionNumber
                    }
                    Write-Host "Boot partition is now marked as Active." -ForegroundColor Green
                }
                elseif ($bootPartition) {
                    Write-Host "Boot partition Active flag: OK" -ForegroundColor Green
                }
            }
        }
        catch {
            Write-Error "RebuildBCD failed: $_"
            throw
        }
    }

    function RecreateBootPartition {
        Write-Host "Checking boot partition status..." -ForegroundColor Yellow
        try {
            $partitions = Get-Partition -DiskNumber $script:DiskNumber -ErrorAction SilentlyContinue
            $disk = Get-Disk -Number $script:DiskNumber

            if ($script:VMGen -eq 2) {
                # -- Gen2 (UEFI/GPT): EFI System Partition ----
                $existingEsp = $partitions | Where-Object { $_.Type -eq 'System' }
                if ($existingEsp) {
                    Write-Host "EFI System Partition already exists (Partition $($existingEsp.PartitionNumber)). No action needed." -ForegroundColor Green
                    Write-Host "If the BCD is missing or corrupt, use -FixBoot to rebuild it." -ForegroundColor DarkCyan
                    return
                }

                $idealSize = 100MB
                $minSize = 80MB
                $freeSpace = $disk.LargestFreeExtent
                if ($freeSpace -lt $minSize) {
                    Write-Error "Not enough unallocated space on disk $($script:DiskNumber). Need at least 80 MB, available: $([math]::Round($freeSpace / 1MB, 1)) MB."
                    return
                }
                $useSize = if ($freeSpace -ge $idealSize) { $idealSize } else { $freeSpace }
                $sizeMB = [math]::Round($useSize / 1MB, 0)

                $confirmed = Confirm-CriticalOperation -Operation "Recreate EFI System Partition (Gen2/UEFI)" -Details @"
- Create a $sizeMB MB FAT32 partition with GPT type 'EFI System Partition'
- Run bcdboot to populate it with EFI boot files and a fresh BCD store
- The Windows partition at $($script:WinDriveLetter) will be referenced as the OS source
"@
                if (-not $confirmed) { return }

                Write-Host "Creating $sizeMB MB EFI System Partition..." -ForegroundColor Cyan
                $newPart = New-Partition -DiskNumber $script:DiskNumber -Size $useSize `
                    -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter
                $newLetter = $newPart.DriveLetter
                if (-not $newLetter -or $newLetter -eq "`0") {
                    $newPart | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
                    $newPart = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $newPart.PartitionNumber
                    $newLetter = $newPart.DriveLetter
                }

                Write-Host "Formatting as FAT32 (label: SYSTEM)..." -ForegroundColor Cyan
                Format-Volume -Partition $newPart -FileSystem FAT32 -NewFileSystemLabel "SYSTEM" -Confirm:$false | Out-Null

                $bootDrive = "$($newLetter):"
                $WinDrive = $script:WinDriveLetter.TrimEnd('\')
                $rebuildCmd = "bcdboot $WinDrive\Windows /s $bootDrive /v /f UEFI"
                Write-Host "Running: $rebuildCmd" -ForegroundColor Cyan
                Invoke-Logged -Description "bcdboot (recreate ESP)" -Details @{ Command = $rebuildCmd } -ScriptBlock {
                    & cmd.exe /c $rebuildCmd
                } | Out-Host

                $script:BootDriveLetter = "$bootDrive\"

                Write-ActionLog -Event 'RecreateBootPartition' -Details @{
                    Generation      = 2
                    DiskNumber      = $script:DiskNumber
                    PartitionNumber = $newPart.PartitionNumber
                    DriveLetter     = $bootDrive
                    FileSystem      = 'FAT32'
                    Size            = "${sizeMB}MB"
                }

                Write-Host "EFI System Partition created and boot files populated successfully." -ForegroundColor Green
                Write-Host "Boot drive is now: $bootDrive" -ForegroundColor Green
            }
            else {
                # -- Gen1 (BIOS/MBR): System Reserved partition ----
                $winTrimmed = $script:WinDriveLetter.TrimEnd('\')
                $separateBootPart = $partitions | Where-Object {
                    $_.IsActive -and ($_.AccessPaths | Where-Object { $_ -and $_.TrimEnd('\') -ne $winTrimmed })
                }
                if ($separateBootPart) {
                    Write-Host "An Active boot partition already exists (Partition $($separateBootPart.PartitionNumber)). No action needed." -ForegroundColor Green
                    Write-Host "If the BCD is missing or corrupt, use -FixBoot to rebuild it." -ForegroundColor DarkCyan
                    return
                }

                $winPartition = $partitions | Where-Object {
                    $_.AccessPaths | Where-Object { $_ -and $_.TrimEnd('\') -eq $winTrimmed }
                }

                $idealSize = 500MB
                $minSize = 350MB
                $freeSpace = $disk.LargestFreeExtent
                if ($freeSpace -lt $minSize) {
                    if ($winPartition -and $winPartition.IsActive) {
                        Write-Host "No separate boot partition and not enough free space, but the Windows partition is Active." -ForegroundColor Green
                        Write-Host "This is a valid single-partition layout. Use -FixBoot to rebuild BCD on the Windows partition if needed." -ForegroundColor DarkCyan
                    }
                    else {
                        Write-Error "Not enough unallocated space on disk $($script:DiskNumber). Need at least 350 MB, available: $([math]::Round($freeSpace / 1MB, 1)) MB."
                    }
                    return
                }
                $useSize = if ($freeSpace -ge $idealSize) { $idealSize } else { $freeSpace }
                $sizeMB = [math]::Round($useSize / 1MB, 0)

                $confirmed = Confirm-CriticalOperation -Operation "Recreate System Reserved Partition (Gen1/BIOS)" -Details @"
- Create a $sizeMB MB NTFS partition and mark it as Active
- Run bcdboot to populate it with boot files and a fresh BCD store
- The Windows partition at $($script:WinDriveLetter) will be referenced as the OS source
- The current Windows partition Active flag (if set) will be cleared
"@
                if (-not $confirmed) { return }

                Write-Host "Creating $sizeMB MB System Reserved partition..." -ForegroundColor Cyan
                $newPart = New-Partition -DiskNumber $script:DiskNumber -Size $useSize -AssignDriveLetter
                $newLetter = $newPart.DriveLetter
                if (-not $newLetter -or $newLetter -eq "`0") {
                    $newPart | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
                    $newPart = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $newPart.PartitionNumber
                    $newLetter = $newPart.DriveLetter
                }

                Write-Host "Formatting as NTFS (label: System Reserved)..." -ForegroundColor Cyan
                Format-Volume -Partition $newPart -FileSystem NTFS -NewFileSystemLabel "System Reserved" -Confirm:$false | Out-Null

                Write-Host "Setting Active flag on new partition (Partition $($newPart.PartitionNumber))..." -ForegroundColor Cyan
                Set-Partition -DiskNumber $script:DiskNumber -PartitionNumber $newPart.PartitionNumber -IsActive $true

                if ($winPartition -and $winPartition.IsActive) {
                    Write-Host "Clearing Active flag from Windows partition (Partition $($winPartition.PartitionNumber))..." -ForegroundColor Cyan
                    Set-Partition -DiskNumber $script:DiskNumber -PartitionNumber $winPartition.PartitionNumber -IsActive $false
                }

                $bootDrive = "$($newLetter):"
                $WinDrive = $script:WinDriveLetter.TrimEnd('\')
                $rebuildCmd = "bcdboot $WinDrive\Windows /s $bootDrive /v /f BIOS"
                Write-Host "Running: $rebuildCmd" -ForegroundColor Cyan
                Invoke-Logged -Description "bcdboot (recreate System Reserved)" -Details @{ Command = $rebuildCmd } -ScriptBlock {
                    & cmd.exe /c $rebuildCmd
                } | Out-Host

                $script:BootDriveLetter = "$bootDrive\"

                Write-ActionLog -Event 'RecreateBootPartition' -Details @{
                    Generation      = 1
                    DiskNumber      = $script:DiskNumber
                    PartitionNumber = $newPart.PartitionNumber
                    DriveLetter     = $bootDrive
                    FileSystem      = 'NTFS'
                    Size            = "${sizeMB}MB"
                }

                Write-Host "System Reserved partition created and boot files populated successfully." -ForegroundColor Green
                Write-Host "Boot drive is now: $bootDrive" -ForegroundColor Green
            }
        }
        catch {
            Write-Error "RecreateBootPartition failed: $_"
            throw
        }
    }

    function AddNewUser {
        Param (
            [Parameter(Mandatory = $True)][string]$WinDrive,
            [Parameter(Mandatory = $True)][pscredential]$Credential
        )

        If ($WinDrive) {
            If (-Not $WinDrive.Contains(":")) {
                $WinDrive += ":"
            }

            If (-Not $WinDrive.EndsWith("\")) {
                $WinDrive += "\"
            }
        }

        If (-Not $Credential) {
            $Credential = Get-Credential
        }

        $Username = $Credential.GetNetworkCredential().UserName
        $Password = $Credential.GetNetworkCredential().Password

        $GptIni = @"
[General]
gPCFunctionalityVersion=2
gPCMachineExtensionNames=[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]
Version=1    
"@

        $FixAzureVM = @"
net user Username "Password" /add /Y
net localgroup administrators Username /add
net localgroup "Remote Desktop Users" Username /add
del /F C:\Windows\System32\GroupPolicy\Machine\Scripts\scripts.ini
del /F C:\Windows\System32\GroupPolicy\gpt.ini
del /F C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup\FixAzureVM.cmd
"@

        $ScriptsIni = @"
[Startup]
0CmdLine=FixAzureVM.cmd
0Parameters=
"@

        $System32Path = Join-Path $WinDrive "Windows\System32"

        If (-Not (Test-Path -Path "$System32Path\GroupPolicy")) {
            New-Item-Logged -Path "$System32Path\GroupPolicy" -ItemType Directory -Force
        }

        If (-Not (Test-Path -Path "$System32Path\GroupPolicy\Scripts")) {
            New-Item-Logged -Path "$System32Path\GroupPolicy\Scripts" -ItemType Directory -Force
        }

        If (-Not (Test-Path -Path "$System32Path\GroupPolicy\Scripts\Startup")) {
            New-Item-Logged -Path "$System32Path\GroupPolicy\Scripts\Startup" -ItemType Directory -Force
        }

        #Create gpt.ini
        New-Item-Logged -Path "$System32Path\GroupPolicy" -Name "gpt.ini" -ItemType File -Value $GptIni.ToString().Trim() -Force
        #Create scripts.ini
        New-Item-Logged -Path "$System32Path\GroupPolicy\Machine\Scripts" -Name "scripts.ini" -ItemType File -Value $ScriptsIni.ToString().Trim() -Force
        #Create FixAzureVM.cmd
        New-Item-Logged -Path "$System32Path\GroupPolicy\Machine\Scripts\Startup" -Name "FixAzureVM.cmd" -ItemType File -Value $FixAzureVM.ToString().Trim().Replace("Username", $Username).Replace("Password", $Password) -Force -RedactValue

        Write-Host "If the VM is domain joined, local GPO may not apply, try -AddTempUser2 if this doesn't work."
    }

    function AddNewUser2 {
        param (
            [Parameter(Mandatory = $True)][pscredential]$Credential
        )

        Invoke-WithHive 'SYSTEM' {
            Write-Host "Configuring setup and adding script..." -ForegroundColor Green
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name SetupType -Value 2 -Type DWord -Force
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name CmdLine -Value "cmd.exe /c c:\temp\adduser.cmd" -Type String -Force

            If (-Not $Credential) {
                $Credential = Get-Credential
            }

            $Username = $Credential.GetNetworkCredential().UserName
            $Password = $Credential.GetNetworkCredential().Password

            $NewUserScript = @"
@echo off
net user Username "Password" /add /Y
net localgroup administrators Username /add
net localgroup "Remote Desktop Users" Username /add
reg add "HKLM\SYSTEM\Setup" /v SetupType /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\Setup" /v CmdLine /t REG_SZ /d "" /f
del /F C:\Temp\adduser.cmd > NUL
"@

            Ensure-GuestTempDir
            New-Item-Logged -Path "$script:WinDriveLetter\Temp" -Name "adduser.cmd" -ItemType File -Value $NewUserScript.ToString().Trim().Replace("Username", $Username).Replace("Password", $Password) -Force -RedactValue

            Write-Host "A script to add the user $Username will run at next boot. If the VM is domain joined, this should work even if local GPO is blocked." -ForegroundColor Green
        }
    }


    function GetRdpAuthPolicySnapshot {
        Invoke-WithHive 'SYSTEM', 'SOFTWARE' {
            $SystemRoot = Get-SystemRootPath
            $SoftwareRoot = "HKLM:\BROKENSOFTWARE"

            $checks = @(
                # --- RDP listener ---
                @{ Path = "$SystemRoot\Control\Terminal Server\WinStations\RDP-Tcp"; Name = "SecurityLayer" },
                @{ Path = "$SystemRoot\Control\Terminal Server\WinStations\RDP-Tcp"; Name = "UserAuthentication" },
                @{ Path = "$SystemRoot\Control\Terminal Server\WinStations\RDP-Tcp"; Name = "SSLCertificateSHA1Hash" },

                # --- NTLM restrictions ---
                @{ Path = "$SystemRoot\Control\Lsa\MSV1_0"; Name = "RestrictReceivingNTLMTraffic" },
                @{ Path = "$SystemRoot\Control\Lsa\MSV1_0"; Name = "RestrictSendingNTLMTraffic" },
                @{ Path = "$SystemRoot\Control\Lsa"; Name = "LmCompatibilityLevel" },

                # --- CredSSP / Encryption Oracle ---
                @{ Path = "$SoftwareRoot\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters"; Name = "AllowEncryptionOracle" }
            )

            foreach ($c in $checks) {
                $val = $null
                $status = "Missing"

                try {
                    if (Test-Path $c.Path) {
                        $p = Get-ItemProperty -Path $c.Path -ErrorAction Stop
                        if ($null -ne $p.($c.Name)) {
                            $val = $p.($c.Name)
                            $status = "Present"
                        }
                    }

                    # Special handling: SSLCertificateSHA1Hash is REG_BINARY -> show as hex string
                    if ($status -eq "Present" -and $c.Name -eq "SSLCertificateSHA1Hash" -and $val -is [byte[]]) {
                        $val = ([BitConverter]::ToString($val) -replace '-', '')
                    }
                }
                catch {
                    $status = "Error: $($_.Exception.Message)"
                }

                [PSCustomObject]@{
                    RegistryPath = $c.Path
                    Name         = $c.Name
                    Value        = $val
                    Status       = $status
                }
            }
        }
    }

    function SetRdpAuthPolicyOptimal {
        Invoke-WithHive 'SYSTEM', 'SOFTWARE' {
            $SystemRoot = Get-SystemRootPath
            $SoftwareRoot = "HKLM:\BROKENSOFTWARE"

            # --- Define the changes to apply: Path, Name, new Value ---
            $rdpTcp = "$SystemRoot\Control\Terminal Server\WinStations\RDP-Tcp"
            $msv10 = "$SystemRoot\Control\Lsa\MSV1_0"
            $lsa = "$SystemRoot\Control\Lsa"
            $credssp = "$SoftwareRoot\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters"

            $changes = @(
                @{ Path = $rdpTcp; Name = "SecurityLayer"; Value = 2 },
                @{ Path = $rdpTcp; Name = "UserAuthentication"; Value = 0 },
                @{ Path = $msv10; Name = "RestrictReceivingNTLMTraffic"; Value = 0 },
                @{ Path = $msv10; Name = "RestrictSendingNTLMTraffic"; Value = 0 },
                @{ Path = $lsa; Name = "LmCompatibilityLevel"; Value = 3 },
                @{ Path = $credssp; Name = "AllowEncryptionOracle"; Value = 2 }
            )

            # --- Snapshot current values before making any changes ---
            $snapshots = foreach ($c in $changes) {
                $before = $null
                $existed = $false
                if (Test-Path $c.Path) {
                    $prop = Get-ItemProperty -Path $c.Path -Name $c.Name -ErrorAction SilentlyContinue
                    if ($null -ne $prop.($c.Name)) {
                        $before = $prop.($c.Name)
                        $existed = $true
                    }
                }
                [PSCustomObject]@{
                    Path     = $c.Path
                    Name     = $c.Name
                    NewValue = $c.Value
                    Before   = $before
                    Existed  = $existed
                }
            }

            # --- Apply changes ---
            $results = @()
            foreach ($c in $changes) {
                $results += Set-DwordValue -Path $c.Path -Name $c.Name -Value $c.Value
            }

            Write-Host "`nApplied the following RDP auth policy changes:" -ForegroundColor Green
            $results | Format-Table -AutoSize

            Write-Host "RDP will use TLS security layer but allow fallback to non-NLA auth, NTLM auth will be allowed with NTLMv2-only responses, and CredSSP will allow vulnerable encryption oracle for compatibility." -ForegroundColor Yellow
            Write-Host "These settings are for recovery purposes only. After the VM is accessible again, restore the original values using the commands below." -ForegroundColor Yellow

            # --- Print restore commands based on the captured snapshots ---
            Write-Host "`n--- REVERT COMMANDS (run these on the VM after recovery to restore original settings) ---" -ForegroundColor Cyan
            Write-Host "# Mount the offline hives first if reverting via the repair host, or run directly on the live VM." -ForegroundColor DarkCyan
            foreach ($s in $snapshots) {
                # Convert the BROKEN hive path back to the live registry path for the restore commands
                $livePath = $s.Path -replace '^HKLM:\\BROKENSYSTEM\\', 'HKLM:\SYSTEM\' `
                    -replace '^HKLM:\\BROKENSOFTWARE\\', 'HKLM:\SOFTWARE\'
                if ($s.Existed) {
                    Write-Host "Set-ItemProperty -Path '$livePath' -Name '$($s.Name)' -Value $($s.Before) -Type DWord -Force" -ForegroundColor White
                }
                else {
                    Write-Host "Remove-ItemProperty -Path '$livePath' -Name '$($s.Name)' -ErrorAction SilentlyContinue  # value did not exist before" -ForegroundColor DarkGray
                }
            }
            Write-Host "-------------------------------------------------------------------------------------`n" -ForegroundColor Cyan
        }
    }

    function ResetRDPSettings {
        Invoke-WithHive 'SYSTEM', 'SOFTWARE' {
            $SystemRoot = Get-SystemRootPath
            $SoftwareRoot = "HKLM:\BROKENSOFTWARE"
            $TSKeyPath = "$SystemRoot\Control\Terminal Server"
            $WinStationsPath = "$SystemRoot\Control\Terminal Server\Winstations"
            $RdpTcpPath = "$SystemRoot\Control\Terminal Server\Winstations\RDP-Tcp"
            $TSPolicyPath = "$SoftwareRoot\Policies\Microsoft\Windows NT\Terminal Services"
            Write-Host "Setting RDP to default configuration..." -ForegroundColor Yellow

            # -- Enable RDP at the canonical registry key --------------------------
            # fDenyTSConnections=0 must be set on the Terminal Server key itself,
            # not only on the policy path, otherwise RDP remains blocked.
            Set-ItemProperty-Logged -Path $TSKeyPath -Name fDenyTSConnections -Value 0 -Type Dword -Force

            # -- RDP-dependent services --------------------------------------------
            # TermService (Remote Desktop Services) - must not be disabled.
            # SessionEnv  (Remote Desktop Config)   - required for TermService to start.
            # UmRdpService (Remote Desktop UserMode Port Redirector) - required for redirectors.
            # All three default to Manual (3); set to Auto (2) so they survive reboots reliably.
            $rdpServices = @(
                @{ Name = 'TermService'; DefaultStart = 2 }
                @{ Name = 'SessionEnv'; DefaultStart = 2 }
                @{ Name = 'UmRdpService'; DefaultStart = 2 }
            )
            foreach ($svc in $rdpServices) {
                $svcPath = "$SystemRoot\Services\$($svc.Name)"
                if (Test-Path $svcPath) {
                    $current = (Get-ItemProperty $svcPath -ErrorAction SilentlyContinue).Start
                    if ($current -eq 4 -or $null -eq $current) {
                        Write-Host "  $($svc.Name): Start was $(if ($null -eq $current) {'(not set)'} else {'Disabled (4)'}) -> setting to Auto (2)" -ForegroundColor Yellow
                        Set-ItemProperty-Logged -Path $svcPath -Name Start -Value $svc.DefaultStart -Type DWord -Force
                    }
                    else {
                        Write-Host "  $($svc.Name): Start=$current (no change needed)" -ForegroundColor DarkGray
                    }
                }
                else {
                    Write-Host "  $($svc.Name): service key not found - skipping" -ForegroundColor DarkGray
                }
            }

            Set-ItemProperty-Logged -Path $WinStationsPath -Name SelfSignedCertStore -Value 'Remote Desktop' -Type String -Force

            Set-ItemProperty-Logged -Path $RdpTcpPath -Name PortNumber -Value 3389 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name fInheritReconnectSame -Value 1 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name fReconnectSame -Value 1 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name fInheritMaxSessionTime -Value 1 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name fInheritMaxDisconnectionTime -Value 1 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name MaxDisconnectionTime -Value 0 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name MaxConnectionTime -Value 0 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name fInheritMaxIdleTime -Value 1 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name MaxIdleTime -Value 0 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name MaxInstanceCount -Value 4294967295 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name LanAdapter -Value 0 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name TSServerDrainMode -Value 0 -Type Dword -Force
            Set-ItemProperty-Logged -Path $RdpTcpPath -Name fQueryUserConfigFromLocalMachine -Value 1 -Type Dword -Force

            Set-ItemProperty-Logged -Path $TSPolicyPath -Name KeepAliveEnable -Value 1 -Type Dword -Force
            Set-ItemProperty-Logged -Path $TSPolicyPath -Name KeepAliveInterval -Value 1 -Type Dword -Force
            Set-ItemProperty-Logged -Path $TSPolicyPath -Name KeepAliveTimeout -Value 1 -Type Dword -Force
            Set-ItemProperty-Logged -Path $TSPolicyPath -Name fDenyTSConnections -Value 0 -Type Dword -Force
            Set-ItemProperty-Logged -Path $TSPolicyPath -Name fDisableAutoReconnect -Value 0 -Type Dword -Force

            $SSLPolicyPath = "HKLM:\BROKENSOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002"
            Write-Host "Clearing SSL 00010002 'Functions'..." -ForegroundColor Yellow
            if (Test-Path -Path $SSLPolicyPath) {
                Remove-ItemProperty-Logged -Path $SSLPolicyPath -Name Functions -Force -ErrorAction SilentlyContinue
            }
            else {
                New-Item-Logged -Path $SSLPolicyPath -Force
            }

            $tls12Paths = @(
                "$SystemRoot\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client",
                "$SystemRoot\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"
            )

            foreach ($tls12Path in $tls12Paths) {
                if (-not (Test-Path $tls12Path)) {
                    New-Item-Logged -Path $tls12Path -Force
                }

                Set-ItemProperty-Logged -Path $tls12Path -Name Enabled -Value 1 -Type DWord -Force | Out-Null
                Set-ItemProperty-Logged -Path $tls12Path -Name DisabledByDefault -Value 0 -Type DWord -Force | Out-Null
            }
        }
    }

    function ResetRDPPrivKeyPermissions {
        Write-Host "Resetting Windows RSA MachineKeys permissions..." -ForegroundColor Green
        $machineKeysPath = "$($script:WinDriveLetter)ProgramData\Microsoft\Crypto\RSA\MachineKeys"
        Write-Host "  [exec] takeown /f '$machineKeysPath' /a /r" -ForegroundColor DarkGray
        & takeown /f $machineKeysPath /a /r | Out-Null
        Write-Host "  [exec] icacls '$machineKeysPath' /t /c /grant 'NT AUTHORITY\SYSTEM:(F)'" -ForegroundColor DarkGray
        & icacls $machineKeysPath /t /c /grant "NT AUTHORITY\SYSTEM:(F)" | Out-Null
        Write-Host "  [exec] icacls '$machineKeysPath' /t /c /grant 'NT AUTHORITY\NETWORK SERVICE:(R)'" -ForegroundColor DarkGray
        & icacls $machineKeysPath /t /c /grant "NT AUTHORITY\NETWORK SERVICE:(R)" | Out-Null
        Write-Host "  [exec] icacls '$machineKeysPath' /t /c /grant 'BUILTIN\Administrators:(F)'" -ForegroundColor DarkGray
        & icacls $machineKeysPath /t /c /grant "BUILTIN\Administrators:(F)" | Out-Null

        $PrivKeys = Get-ChildItem -Path "$($script:WinDriveLetter)ProgramData\Microsoft\Crypto\RSA\MachineKeys\f686aace6942fb7f7ceb231212eef4a4*"

        Write-Host "Resetting RDP certificate private key permissions..." -ForegroundColor Green

        ForEach ($PrivKey in $PrivKeys) {
            $pkPath = $PrivKey.FullName
            Write-Host "  [exec] takeown /f '$pkPath'" -ForegroundColor DarkGray
            & takeown.exe /f $pkPath | Out-Null
            Write-Host "  [exec] icacls '$pkPath' /c /grant 'NT AUTHORITY\SYSTEM:(F)'" -ForegroundColor DarkGray
            & icacls.exe $pkPath /c /grant "NT AUTHORITY\SYSTEM:(F)" | Out-Null
            Write-Host "  [exec] icacls '$pkPath' /c /grant 'NT AUTHORITY\NETWORK SERVICE:(R)'" -ForegroundColor DarkGray
            & icacls.exe $pkPath /c /grant "NT AUTHORITY\NETWORK SERVICE:(R)" | Out-Null
            Write-Host "  [exec] icacls '$pkPath' /c /grant 'NT Service\SessionEnv:(F)'" -ForegroundColor DarkGray
            & icacls.exe $pkPath /c /grant "NT Service\SessionEnv:(F)" | Out-Null
            Write-Host "  [exec] icacls '$pkPath' (display current ACL)" -ForegroundColor DarkGray
            & icacls.exe $pkPath

            ExecuteAsSystem "icacls.exe `"$pkPath`" /setowner 'NT AUTHORITY\SYSTEM'"
        }

        Write-Host "Setting certificate services to default: CertPropSvc, KeyIso, CryptSvc, SessionEnv" -ForegroundColor Yellow
        Enable-ServiceOrDriver -ServiceName CertPropSvc -StartValue 3
        Enable-ServiceOrDriver -ServiceName KeyIso -StartValue 3
        Enable-ServiceOrDriver -ServiceName CryptSvc -StartValue 2
        Enable-ServiceOrDriver -ServiceName SessionEnv -StartValue 3
    }

    function RecreateRDPCertificate {
        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath

            Write-Host "Configuring setup and adding script..." -ForegroundColor Green
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name SetupType -Value 2 -Type DWord -Force
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name CmdLine -Value "cmd.exe /c c:\temp\newrdscert.cmd" -Type String -Force

            $newrdscert = @"
@echo off
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File C:\temp\rdscert.ps1
reg add "HKLM\SYSTEM\Setup" /v SetupType /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\Setup" /v CmdLine /t REG_SZ /d "" /f
del /F C:\temp\rdscert.ps1 > NUL
del /F C:\temp\newrdscert.cmd > NUL
"@

            $RecreateRDPCert = @'
$Passwd =  "REPLACE_WITH_PASSWORD"
$CertPasswd = ConvertTo-SecureString -String $Passwd -Force -AsPlainText
 
#Import certificate into 'Remote Desktop' and 'My' stores
Import-PfxCertificate -FilePath C:\temp\rds.pfx -CertStoreLocation 'Cert:\LocalMachine\Remote Desktop\' -Password $CertPasswd
Import-PfxCertificate -FilePath C:\temp\rds.pfx -CertStoreLocation 'Cert:\LocalMachine\My\' -Password $CertPasswd
 
#Set RDP protocol to use that just imported certificate
wmic /namespace:\\root\cimv2\TerminalServices PATH Win32_TSGeneralSetting Set SSLCertificateSHA1Hash="REPLACE_WITH_THUMBPRINT"

$bytes = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp").SSLCertificateSHA1Hash

$expected = "REPLACE_WITH_THUMBPRINT"
$actual = ([BitConverter]::ToString($bytes) -replace '-', '')
$certbinary = ([byte[]]([regex]::Matches($expected,"..") | % { [Convert]::ToByte($_.Value,16) }))

$expected = $expected.ToUpper()
$actual   = $actual.ToUpper()

    if ($actual -ne $expected) {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name SSLCertificateSHA1Hash -Type Binary -Force -Value $certbinary
    }
 
#Restart RDP service (try to restart twice)
Restart-Service TermService -Force
Restart-Service TermService -Force

#Enable RDP and SMB rules in Windows Firewall
Enable-NetFirewallRule FPS-SMB-In-TCP
Enable-NetFirewallRule RemoteDesktop-UserMode-In-TCP

#Clean up
Remove-Item -Path C:\temp\rds.pfx -Force
'@

            Ensure-GuestTempDir
            $guestName = (Get-ItemProperty "$SystemRoot\Control\ComputerName\ComputerName").ComputerName

            Write-Host "Generating new certificate to guest $guestname locally..." -ForegroundColor Green
            $cert = New-SelfSignedCertificate -Type Custom -KeySpec Signature -Subject "CN=$($guestName)" -KeyExportPolicy Exportable -HashAlgorithm sha256 -KeyLength 2048 `
                -CertStoreLocation "Cert:\LocalMachine\My" -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.1") -NotAfter (Get-Date).AddYears(5)

            # Generate a cryptographically random one-time PFX transport password (never hardcoded)
            $rngBytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
            $PfxPassword = [System.Convert]::ToBase64String($rngBytes) -replace '[^A-Za-z0-9]', 'x'
            $certpwd = ConvertTo-SecureString $PfxPassword -AsPlainText -Force

            $hostPfx = Join-Path $WinDriveLetter "Temp\rds.pfx"
            Write-Host "Exporting new cert with thumbprint $($cert.Thumbprint) to $hostPfx..." -ForegroundColor Green
            Export-PfxCertificate -Cert $cert -FilePath $hostPfx -Password $certpwd | Out-Null
            Remove-Item-Logged -Path "Cert:\LocalMachine\My\$($cert.Thumbprint)" -Force

            New-Item-Logged -Path "$WinDriveLetter\Temp" -Name "newrdscert.cmd" -ItemType File -Value $newrdscert.ToString().Trim() -Force
            New-Item-Logged -Path "$WinDriveLetter\Temp" -Name "rdscert.ps1" -ItemType File -Value $RecreateRDPCert.ToString().Trim().Replace("REPLACE_WITH_PASSWORD", $PfxPassword).Replace("REPLACE_WITH_THUMBPRINT", $cert.Thumbprint) -Force -RedactValue

            Write-Host "A script to recreate the RDP certificate will run at next boot. If the RDP service fails to restart after that, you may need to restart the VM." -ForegroundColor Green
        }
    }

    function SetNLA {
        param([bool]$Enable)
        Invoke-WithHive 'SYSTEM', 'SOFTWARE' {
            $SystemRoot = Get-SystemRootPath
            $SoftwareRoot = "HKLM:\BROKENSOFTWARE"

            $RdpTcpPath = "$SystemRoot\Control\Terminal Server\Winstations\RDP-Tcp"
            $TSPolicyPath = "$SoftwareRoot\Policies\Microsoft\Windows NT\Terminal Services"

            if ($Enable) {
                Write-Host "Enabling NLA..." -ForegroundColor Green

                Set-ItemProperty-Logged -Path $RdpTcpPath -Name UserAuthentication -Value 1 -Type Dword -Force
                Set-ItemProperty-Logged -Path $RdpTcpPath -Name SecurityLayer -Value 2 -Type Dword -Force
                Set-ItemProperty-Logged -Path $RdpTcpPath -Name fAllowSecProtocolNegotiation -Value 1 -Type Dword -Force
                Set-ItemProperty-Logged -Path $RdpTcpPath -Name MinEncryptionLevel -Value 2 -Type Dword -Force

                # Clear any policy overrides that would re-disable NLA after reboot.
                # These values may not exist (e.g. on a clean VM), so suppress the error.
                if (Test-Path $TSPolicyPath) {
                    foreach ($val in @('UserAuthentication', 'SecurityLayer', 'fAllowSecProtocolNegotiation', 'MinEncryptionLevel')) {
                        Remove-ItemProperty-Logged -Path $TSPolicyPath -Name $val -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            else {
                Write-Host "Disabling NLA..." -ForegroundColor Green

                Set-ItemProperty-Logged -Path $RdpTcpPath -Name UserAuthentication -Value 0 -Type Dword -Force
                Set-ItemProperty-Logged -Path $RdpTcpPath -Name SecurityLayer -Value 0 -Type Dword -Force
                Set-ItemProperty-Logged -Path $RdpTcpPath -Name fAllowSecProtocolNegotiation -Value 0 -Type Dword -Force
                Set-ItemProperty-Logged -Path $RdpTcpPath -Name MinEncryptionLevel -Value 1 -Type Dword -Force
 
                Set-ItemProperty-Logged -Path $TSPolicyPath -Name UserAuthentication -Value 0 -Type Dword -Force
                Set-ItemProperty-Logged -Path $TSPolicyPath -Name SecurityLayer -Value 0 -Type Dword -Force
                Set-ItemProperty-Logged -Path $TSPolicyPath -Name fAllowSecProtocolNegotiation -Value 0 -Type Dword -Force
                Set-ItemProperty-Logged -Path $TSPolicyPath -Name MinEncryptionLevel -Value 1 -Type Dword -Force
            }
        }
    }

    function ClearPendingUpdates {
        if (-not (Confirm-CriticalOperation -Operation 'Fix Pending Updates (-FixPendingUpdates)' -Details @"
Runs DISM /RevertPendingActions to undo in-progress servicing operations.
Removes pending update packages found by DISM /Get-Packages.
Removes TxR and SMI transaction log files (.blf/.regtrans-ms).
Renames pending.xml in WinSxS.
Clears CBS registry keys (PackagesPending, RebootPending, SessionsPending).
Runs DISM /StartComponentCleanup to reclaim disk space from superseded components.
"@)) { return }

        $OfflineWindowsPath = Join-Path $WinDriveLetter "Windows"
        if (-not (Test-Path "C:\temp")) { mkdir C:\temp | Out-Null }

        Write-Host "Saving pending Windows Update packages..." -ForegroundColor Yellow
        $dismText = & dism /Image:$WinDriveLetter /Get-Packages /format:list 2>$null | Out-String -Width 9999
        $blocks = $dismText -split "(\r\n){2,}"

        $packages = foreach ($b in $blocks) {
            $h = @{}
            foreach ($line in ($b -split "`r`n")) {
                if ($line -match '^\s*([^:]+)\s*:\s*(.+)\s*$') {
                    $h[$matches[1].Trim()] = $matches[2].Trim()
                }
            }
            if ($h.ContainsKey('Package Identity')) {
                [pscustomobject]$h
            }
        }

        $pendingUpdates = $packages | Where-Object { $_.State -eq 'Pending' } | Select-Object -ExpandProperty 'Package Identity'
        $pendingUpdates | Set-Content -Path C:\Temp\PendingUpdatePackages.txt

        Write-Host "Running DISM /Cleanup-Image /RevertPendingActions (undo in-progress servicing)" -ForegroundColor Yellow
        & dism /Image:$WinDriveLetter /Cleanup-Image /RevertPendingActions /ScratchDir:C:\Temp

        $pendingUpdates | ForEach-Object {
            Write-Host "Running package uninstall: $($_)" -ForegroundColor Yellow
            & dism /Image:$WinDriveLetter /Remove-Package /PackageName:$_
        }

        Write-Host "Clearing transactions from TxR folder..." -ForegroundColor Yellow
        $TxRFolder = Join-Path $WinDriveLetter "Windows\system32\config\TxR"
        if (Test-Path $TxRFolder) {
            $BackupFolder = Join-Path $TxRFolder "Backup"
            Get-ChildItem -Path $TxRFolder -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
            New-Item-Logged -Path $TxRFolder -Name "Backup" -ItemType Directory -Force
            Copy-Item-Logged -Path (Join-Path $TxRFolder '*') -Destination $BackupFolder -Force
            Invoke-Logged -Description 'Remove TxR blf/regtrans files' -Details @{ Path = $TxRFolder } -ScriptBlock {
                Get-ChildItem -Path $TxRFolder -File -Filter *.blf -Force | Remove-Item -Force -ErrorAction SilentlyContinue
                Get-ChildItem -Path $TxRFolder -File -Filter *.regtrans-ms -Force | Remove-Item -Force -ErrorAction SilentlyContinue
            }

            # Remove any leftover TxR_OLD from a previous run before renaming
            $TxROld = Join-Path $WinDriveLetter "Windows\system32\config\TxR_OLD"
            if (Test-Path $TxROld) {
                Remove-Item -Path $TxROld -Recurse -Force -ErrorAction SilentlyContinue
            }
            Rename-Item-Logged -Path $TxRFolder -NewName "TxR_OLD"
            New-Item-Logged -Path (Join-Path $WinDriveLetter "Windows\system32\config") -Name "TxR" -ItemType Directory -Force
        }
        else {
            Write-Host "  TxR folder not found, skipping." -ForegroundColor DarkGray
        }

        Write-Host "Clearing transactions from Config folder..." -ForegroundColor Yellow
        $ConfigFolder = Join-Path $WinDriveLetter "Windows\system32\config"
        $BackupFolder = Join-Path $ConfigFolder "BackupCfg"
        Get-ChildItem -Path $ConfigFolder -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'BackupCfg' } | ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
        if (Test-Path $BackupFolder) {
            Remove-Item -Path $BackupFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item-Logged -Path $ConfigFolder -Name "BackupCfg" -ItemType Directory -Force
        Copy-Item-Logged -Path (Join-Path $ConfigFolder '*') -Destination $BackupFolder -Force
        Invoke-Logged -Description 'Remove Config blf/regtrans files' -Details @{ Path = $ConfigFolder } -ScriptBlock {
            Get-ChildItem -Path $ConfigFolder -File -Filter *.blf -Force | Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -Path $ConfigFolder -File -Filter *.regtrans-ms -Force | Remove-Item -Force -ErrorAction SilentlyContinue
        }

        Write-Host "Clearing transactions from SMI folder..." -ForegroundColor Yellow
        $SMIFolder = Join-Path $WinDriveLetter "Windows\System32\SMI\Store\Machine"
        if (Test-Path $SMIFolder) {
            $BackupFolder = Join-Path $SMIFolder "Backup"
            Get-ChildItem -Path $SMIFolder -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Backup' } | ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
            if (Test-Path $BackupFolder) {
                Remove-Item -Path $BackupFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item-Logged -Path $SMIFolder -Name "Backup" -ItemType Directory -Force
            Copy-Item-Logged -Path (Join-Path $SMIFolder '*') -Destination $BackupFolder -Force
            Invoke-Logged -Description 'Remove SMI blf/regtrans files' -Details @{ Path = $SMIFolder } -ScriptBlock {
                Get-ChildItem -Path $SMIFolder -File -Filter *.blf -Force | Remove-Item -Force -ErrorAction SilentlyContinue
                Get-ChildItem -Path $SMIFolder -File -Filter *.regtrans-ms -Force | Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-Host "  SMI folder not found, skipping." -ForegroundColor DarkGray
        }

        Write-Host "Renaming pending.xml..." -ForegroundColor Yellow
        $pendingXmlPath = Join-Path $WinDriveLetter "Windows\WinSxS\pending.xml"
        if (Test-Path $pendingXmlPath) {
            # Remove stale pending.old from a previous run
            $pendingOld = Join-Path $WinDriveLetter "Windows\WinSxS\pending.old"
            if (Test-Path $pendingOld) {
                Remove-Item -Path $pendingOld -Force -ErrorAction SilentlyContinue
            }
            Rename-Item-Logged -Path $pendingXmlPath -NewName "pending.old"
        }
        else {
            Write-Host "  pending.xml not present, skipping." -ForegroundColor DarkGray
        }

        Write-Host "Deleting registry keys..." -ForegroundColor Yellow
        Invoke-WithHive 'SOFTWARE', 'COMPONENTS' {
            $ComponentsReg = "HKLM:\BROKENCOMPONENTS"
            $CbsSoftwareReg = "HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing"

            Write-Host "Deleting COMPONENTS registry keys..." -ForegroundColor Yellow
            Remove-ItemProperty-Logged -Path $ComponentsReg -Name "ExecutionState" -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty-Logged -Path $ComponentsReg -Name "PendingXmlIdentifier" -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty-Logged -Path $ComponentsReg -Name "NextQueueEntryIndex" -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty-Logged -Path $ComponentsReg -Name "NextQueueEntryIndexBCDB" -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty-Logged -Path $ComponentsReg -Name "AdvancedInstallersNeedResolving" -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty-Logged -Path $ComponentsReg -Name "StoreDirty" -Force -ErrorAction SilentlyContinue

            Write-Host "Deleting SOFTWARE registry keys..." -ForegroundColor Yellow
            Remove-Item-Logged -Path (Join-Path $CbsSoftwareReg "PackagesPending") -Recurse -Force
            Remove-Item-Logged -Path (Join-Path $CbsSoftwareReg "RebootPending") -Recurse -Force
            Remove-Item-Logged -Path (Join-Path $CbsSoftwareReg "SessionsPending") -Recurse -Force
        }

        Write-Host "Running DISM /Cleanup-Image /StartComponentCleanup (reclaim space from superseded components)" -ForegroundColor Yellow
        & dism /Image:$WinDriveLetter /Cleanup-Image /StartComponentCleanup

        Write-Host "You may want to run SFC and Dism /RestoreHealth with script parameters: -RunSFC -RepairComponentStore." -ForegroundColor Green
    }

    function SetWinRMHTTPSEnabled {
        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath

            Write-Host "Configuring setup and adding script..." -ForegroundColor Green
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name SetupType -Value 2 -Type DWord -Force
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name CmdLine -Value "cmd.exe /c c:\temp\installwinrmhttps.cmd" -Type String -Force

            $installwinrmhttps = @"
@echo off
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File C:\temp\configwinrmhttps.ps1
reg add "HKLM\SYSTEM\Setup" /v SetupType /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\Setup" /v CmdLine /t REG_SZ /d "" /f
del /F C:\temp\configwinrmhttps.ps1 > NUL
del /F C:\temp\winrm_https.pfx > NUL
del /F C:\temp\installwinrmhttps.cmd > NUL
"@

            $scriptContent = @'
$pwd = ConvertTo-SecureString "REPLACE_WITH_PASSWORD" -AsPlainText -Force

# 1) Import machine certificate (LocalMachine\My) and capture thumbprint
$imported = Import-PfxCertificate -FilePath "C:\temp\winrm_https.pfx" -CertStoreLocation "Cert:\LocalMachine\My" -Password $pwd
$thumb = $imported.Thumbprint

# 2) Enable WinRM for remoting + CredSSP (server)
Enable-PSRemoting -Force
Enable-WSManCredSSP -Role Server -Force

# 3) Firewall rule for 5986 (HTTPS)
New-NetFirewallRule -DisplayName "Windows Remote Management (HTTPS-In)" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow -Program "System" | Out-Null

# 4) Create HTTPS listener (remove any existing HTTPS listener first)
Get-ChildItem -Path WSMan:\localhost\Listener | Where-Object { $_.Keys -match "Transport=HTTPS" } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -Hostname $env:COMPUTERNAME -CertificateThumbprint $thumb -Port 5986 -Force | Out-Null

# 5) Ensure WinRM service is Auto + started
Set-Service -Name WinRM -StartupType Automatic
Restart-Service -Name WinRM -Force
'@

            Ensure-GuestTempDir
            $guestName = (Get-ItemProperty "$SystemRoot\Control\ComputerName\ComputerName").ComputerName

            $cert = New-SelfSignedCertificate -DnsName $guestName -CertStoreLocation 'Cert:\LocalMachine\My' -KeyExportPolicy Exportable
            # Generate a cryptographically random one-time PFX transport password (never hardcoded)
            $rngBytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
            $PfxPassword = [System.Convert]::ToBase64String($rngBytes) -replace '[^A-Za-z0-9]', 'x'
            $certpwd = ConvertTo-SecureString $PfxPassword -AsPlainText -Force

            $hostPfx = Join-Path $WinDriveLetter "Temp\winrm_https.pfx"
            Export-PfxCertificate -Cert $cert -FilePath $hostPfx -Password $certpwd | Out-Null
            #Clean up locally
            Remove-Item-Logged -Path "Cert:\LocalMachine\My\$($cert.Thumbprint)" -Force

            New-Item-Logged -Path "$WinDriveLetter\Temp" -Name "installwinrmhttps.cmd" -ItemType File -Value $installwinrmhttps.ToString().Trim() -Force
            New-Item-Logged -Path "$WinDriveLetter\Temp" -Name "configwinrmhttps.ps1" -ItemType File -Value $scriptContent.ToString().Trim().Replace("REPLACE_WITH_PASSWORD", $PfxPassword) -Force -RedactValue
        }

        Write-Host "Now start the VM and wait for the script to configure WinRM over HTTPS. (DO NO CONNECT WITH ENHANCED SESSION)." -ForegroundColor Yellow
        Write-Host "VM will restart after completing the WinRM configuration." -ForegroundColor Yellow

        if ($VMIPAddress) {
            Write-Host "Connect with: Enter-PSSession -ConnectionUri 'https://$($VMIPAddress):5986' -Credential (Get-Credential) -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck)" -ForegroundColor Yellow
        }
        else {
            Write-Host "Connect with: Enter-PSSession -ConnectionUri 'https://<VMIP>:5986' -Credential (Get-Credential) -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck)" -ForegroundColor Yellow
        }
    }

    ################################################################################
    # New repair functions
    ################################################################################

    function FixBootSector {
        Write-Host "Fixing MBR/VBR boot sector..." -ForegroundColor Yellow
        try {
            if ($script:VMGen -ne 1) {
                Write-Warning "Gen2 (UEFI/GPT) VMs do not use MBR/VBR. Use -FixBoot to rebuild the EFI BCD store instead."
                return
            }

            $WinDrive = $script:WinDriveLetter.TrimEnd('\')
            $SysDrive = $script:BootDriveLetter.TrimEnd('\')

            # bootrec.exe only exists in WinRE/WinPE - not available on a regular Hyper-V host.
            # Use bootsect.exe (ships with Windows ADK) if present, otherwise fall back to bcdboot
            # which also rewrites the VBR as a side effect of recreating the boot files.
            $bootsect = $null
            $adkPaths = @(
                "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\BCDBoot\bootsect.exe",
                "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\BCDBoot\bootsect.exe",
                "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\x86\BCDBoot\bootsect.exe"
            )
            foreach ($p in $adkPaths) {
                if (Test-Path $p) { $bootsect = $p; break }
            }
            if (-not $bootsect) {
                $inPath = Get-Command bootsect.exe -ErrorAction SilentlyContinue
                if ($inPath) { $bootsect = $inPath.Source }
            }

            if ($bootsect) {
                Write-Host "Using bootsect.exe: $bootsect" -ForegroundColor Cyan
                # /nt60 = Windows Vista+ compatible VBR; /mbr = also rewrite MBR
                Invoke-Logged -Description "bootsect /nt60 /mbr" -Details @{ SysDrive = $SysDrive; Tool = $bootsect } -ScriptBlock {
                    & $bootsect /nt60 $SysDrive /mbr /force
                }
                Write-Host "MBR and VBR repaired via bootsect. If boot still fails, try -FixBoot." -ForegroundColor Green
            }
            else {
                Write-Warning "bootsect.exe not found. It is only available via the Windows ADK (not installed) or inside WinRE."
                Write-Warning "Falling back to bcdboot, which rewrites the VBR and rebuilds boot files (equivalent to /fixboot)."
                Write-Warning "For a full MBR repair (/fixmbr equivalent), install the Windows ADK and re-run -FixBootSector."
                $rebuildCmd = "bcdboot $WinDrive\Windows /s $SysDrive /v /f BIOS"
                Invoke-Logged -Description "bcdboot fallback (VBR repair)" -Details @{ Command = $rebuildCmd } -ScriptBlock {
                    & cmd.exe /c $rebuildCmd
                }
                Write-Host "VBR repaired via bcdboot. BCD entries also rebuilt as part of this operation." -ForegroundColor Green
            }
        }
        catch {
            Write-Error "FixBootSector failed: $_"
            throw
        }
    }

    function DisableStartupRepair {
        Write-Host "Disabling automatic startup repair loop..." -ForegroundColor Yellow
        try {
            $storePath = Get-BcdStorePath -Generation $script:VMGen -BootDrive $script:BootDriveLetter
            $identifier = Get-BcdBootLoaderId -StorePath $storePath
            if (-not $identifier) { return }

            Invoke-BcdEdit -StorePath $storePath -Command "/set $identifier recoveryenabled No"
            Invoke-BcdEdit -StorePath $storePath -Command "/set $identifier bootstatuspolicy IgnoreAllFailures"
            Invoke-BcdEdit -StorePath $storePath -Command "/set {bootmgr} displaybootmenu no"
            Write-Host "Startup repair disabled. The VM will skip WinRE on next failed boot." -ForegroundColor Green
            Write-Host "To re-enable: use -EnableStartupRepair" -ForegroundColor DarkCyan
        }
        catch {
            Write-Error "DisableStartupRepair failed: $_"
            throw
        }
    }

    function EnableStartupRepair {
        Write-Host "Enabling automatic startup repair..." -ForegroundColor Yellow
        try {
            $storePath = Get-BcdStorePath -Generation $script:VMGen -BootDrive $script:BootDriveLetter
            $identifier = Get-BcdBootLoaderId -StorePath $storePath
            if (-not $identifier) { return }

            Invoke-BcdEdit -StorePath $storePath -Command "/set $identifier recoveryenabled Yes"
            Invoke-BcdEdit -StorePath $storePath -Command "/deletevalue $identifier bootstatuspolicy"
            Invoke-BcdEdit -StorePath $storePath -Command "/set {bootmgr} displaybootmenu no"
            Write-Host "Startup repair re-enabled. Windows will enter WinRE on boot failure." -ForegroundColor Green
        }
        catch {
            Write-Error "EnableStartupRepair failed: $_"
            throw
        }
    }

    function ResetLocalAdminPassword {
        Write-Host "Resetting local administrator account password via startup script..." -ForegroundColor Yellow
        Write-Host "Please provide the new credentials (username = existing local admin account, no .\ prefix):" -ForegroundColor Yellow
        $Credential = Get-Credential

        $Username = $Credential.GetNetworkCredential().UserName
        $Password = $Credential.GetNetworkCredential().Password

        Invoke-WithHive 'SYSTEM' {
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name SetupType -Value 2 -Type DWord -Force
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name CmdLine -Value "cmd.exe /c c:\temp\resetpwd.cmd" -Type String -Force

            $resetScript = @"
@echo off
net user Username "Password" /Y
reg add "HKLM\SYSTEM\Setup" /v SetupType /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\Setup" /v CmdLine /t REG_SZ /d "" /f
del /F C:\Temp\resetpwd.cmd > NUL
"@
            Ensure-GuestTempDir
            New-Item-Logged -Path "$script:WinDriveLetter\Temp" -Name "resetpwd.cmd" -ItemType File -Value $resetScript.Trim().Replace("Username", $Username).Replace("Password", $Password) -Force -RedactValue

            Write-Host "Password reset script placed. The password for '$Username' will be changed on next VM boot." -ForegroundColor Green
        }
    }

    function DisableThirdPartyDrivers {
        if (-not (Confirm-CriticalOperation -Operation 'Disable Third-Party Drivers (-DisableThirdPartyDrivers)' -Details @"
Sets Start=4 (Disabled) for all non-Microsoft Boot and System kernel drivers.
Revert commands are printed after completion, or use -EnableThirdPartyDrivers.
"@)) { return }

        Write-Host "Enumerating and disabling non-Microsoft kernel drivers..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            & {
                $SystemRoot = Get-SystemRootPath
                $ServicesRoot = "$SystemRoot\Services"

                # Kernel-mode start types: 0=Boot, 1=System, 2=Auto, 3=Manual, 4=Disabled
                # Target Boot(0) and System(1) drivers that are third-party

                # Azure-safe vendors: drivers from these companies may be required on Azure
                # VMs (accelerated networking, GPU, NVMe, storage). Do NOT disable them.
                $azureSafeVendors = @(
                    'Mellanox',                  # Accelerated networking (MANA/mlx5/ConnectX)
                    'NVIDIA',                    # GPU compute (NCv3, NDv2, etc.)
                    'Intel',                     # LPSS GPIO/I2C, iaStorAV, NVMe
                    'Advanced Micro Devices',    # CPU microcode, storage
                    'AMD',                       # CPU microcode, storage (short name variant)
                    'Chelsio',                   # iWARP RDMA (HPC SKUs)
                    'Marvell',                   # NVMe controllers on some hardware
                    'Broadcom'                   # Network/storage (Emulex rebranded)
                )
                $azureSafePattern = ($azureSafeVendors | ForEach-Object { [regex]::Escape($_) }) -join '|'

                $disabled = @()
                $skippedAzure = @()
                Get-ChildItem $ServicesRoot -ErrorAction SilentlyContinue | ForEach-Object {
                    $svcPath = $_.PSPath
                    $props = Get-ItemProperty -Path $svcPath -ErrorAction SilentlyContinue
                    # Only kernel/filesystem drivers (Type 1=kernel, 2=filesystem)
                    if ($props.Type -notin @(1, 2)) { return }
                    # Only Boot and System start drivers
                    if ($props.Start -notin @(0, 1)) { return }
                    # Skip if already disabled
                    if ($props.Start -eq 4) { return }

                    $imagePathRaw = $props.ImagePath
                    if (-not $imagePathRaw) { return }
                    $imagePath = Resolve-GuestImagePath $imagePathRaw

                    # Read the binary to check the company name in version info.
                    # If the binary is missing, treat the driver as third-party - a missing
                    # Boot/System binary will cause a BSOD on next boot regardless of vendor.
                    $isMicrosoft = $false
                    $isAzureSafe = $false
                    $binaryMissing = $false
                    $vendorName = ''
                    if (Test-Path $imagePath) {
                        $vi = (Get-Item $imagePath -ErrorAction SilentlyContinue).VersionInfo
                        $vendorName = if ($vi -and $vi.CompanyName) { $vi.CompanyName.Trim() } else { '' }
                        if ($vendorName -match 'Microsoft') { $isMicrosoft = $true }
                        elseif ($vendorName -and $vendorName -match $azureSafePattern) { $isAzureSafe = $true }
                    }
                    else {
                        $binaryMissing = $true   # missing binary -> will BSOD -> must disable
                    }

                    if ($isAzureSafe -and -not $binaryMissing) {
                        $skippedAzure += [PSCustomObject]@{ Service = $_.PSChildName; Vendor = $vendorName }
                        return
                    }

                    if (-not $isMicrosoft) {
                        $svcName = $_.PSChildName
                        $tag = if ($binaryMissing) { ' [binary missing - will BSOD on boot]' } else { '' }
                        Write-Host "  Disabling: $svcName$tag  ($imagePathRaw)" -ForegroundColor Yellow
                        Set-ItemProperty-Logged -Path $svcPath -Name Start -Value 4 -Type DWord -Force
                        $disabled += [PSCustomObject]@{ Service = $svcName; ImagePath = $imagePathRaw; PreviousStart = $props.Start }
                    }
                }

                if ($disabled.Count -eq 0) {
                    Write-Host "No non-Microsoft Boot/System drivers found to disable." -ForegroundColor Green
                }
                else {
                    Write-Host "`nDisabled $($disabled.Count) third-party driver(s)." -ForegroundColor Green
                    Write-Host "`n--- TO RE-ENABLE (run -EnableThirdPartyDrivers or run on the VM after recovery) ---" -ForegroundColor Cyan
                    foreach ($d in $disabled) {
                        $livePath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($d.Service)"
                        Write-Host "Set-ItemProperty -Path '$livePath' -Name Start -Value $($d.PreviousStart) -Type DWord -Force" -ForegroundColor White
                    }
                    Write-Host "----------------------------------------------------`n" -ForegroundColor Cyan
                }

                if ($skippedAzure.Count -gt 0) {
                    Write-Host "  Azure-safe drivers kept enabled (may be needed for accelerated networking/GPU/NVMe):" -ForegroundColor DarkCyan
                    foreach ($s in $skippedAzure) {
                        Write-Host "    $($s.Service)  ($($s.Vendor))" -ForegroundColor DarkCyan
                    }
                    Write-Host ""
                }
            }
        }
    }

    function GetServicesReport {
        param(
            [switch]$IncludeServices,
            [switch]$IssuesOnly
        )
        # Enumerates every entry under Services in the active ControlSet and produces a
        # grouped, colour-coded report. Each row shows:
        #   Name | [Pres] | ErCtl | Vendor | ImagePath
        # By default only kernel/filesystem drivers are shown (Type 1/2/4/8).
        # Pass -IncludeServices to include Win32 services as well.
        # Pass -IssuesOnly to suppress healthy Microsoft rows and display only:
        #   - Missing binaries
        #   - Non-Microsoft vendors
        #   - ErrorControl >= 2 (Severe/Critical)
        # Rows are sorted by Start value (Boot -> System -> Automatic -> Manual -> Disabled)
        # then alphabetically within each group.

        $reportLabel = if ($IncludeServices) { 'services/drivers' } else { 'drivers' }
        $modeLabel = if ($IssuesOnly) { ' (issues only)' } else { '' }
        Write-Host "`nBuilding offline $reportLabel report$modeLabel..." -ForegroundColor Cyan
        Invoke-WithHive 'SYSTEM' {
            & {
                $SystemRoot = Get-SystemRootPath
                $ServicesRoot = "$SystemRoot\Services"

                $startNames = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
                $typeNames = @{ 1 = 'KernelDriver'; 2 = 'FileSystemDriver'; 4 = 'Adapter'; 8 = 'Recognizer';
                    16 = 'Win32Own'; 32 = 'Win32Share'; 256 = 'Interactive' 
                }

                $rows = [System.Collections.Generic.List[PSCustomObject]]::new()

                Get-ChildItem $ServicesRoot -ErrorAction SilentlyContinue | ForEach-Object {
                    $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
                    if (-not $props) { return }

                    $startVal = $props.Start
                    $typeVal = $props.Type
                    # Skip entries with no Start or no Type (e.g. sub-keys that are not real services)
                    if ($null -eq $startVal -or $null -eq $typeVal) { return }

                    $startLabel = if ($startNames.ContainsKey([int]$startVal)) { $startNames[[int]$startVal] } else { "Unknown($startVal)" }
                    $typeLabel = if ($typeNames.ContainsKey([int]$typeVal)) { $typeNames[[int]$typeVal] } else { "Type($typeVal)" }

                    $imgRaw = $props.ImagePath
                    $imgPath = $null
                    $present = $null    # $null = no ImagePath registered
                    $vendor = 'N/A'

                    if ($imgRaw) {
                        $imgPath = Resolve-GuestImagePath $imgRaw

                        if (Test-Path $imgPath) {
                            $present = $true
                            $vi = (Get-Item $imgPath -ErrorAction SilentlyContinue).VersionInfo
                            $vendor = if ($vi -and $vi.CompanyName) { $vi.CompanyName.Trim() } else { '(no version info)' }
                        }
                        else {
                            $present = $false
                            $vendor = '(binary missing)'
                        }
                    }

                    $rows.Add([PSCustomObject]@{
                            Name          = $_.PSChildName
                            Start         = $startLabel
                            StartVal      = [int]$startVal
                            TypeVal       = [int]$typeVal
                            Type          = $typeLabel
                            Group         = if ($props.Group) { $props.Group } else { '' }
                            Vendor        = $vendor
                            BinaryPresent = $present
                            ImagePath     = if ($imgRaw) { $imgRaw } else { '' }
                            ErrorControl  = if ($null -ne $props.ErrorControl) { [int]$props.ErrorControl } else { $null }
                        })
                }

                # Filter to drivers only unless -IncludeServices was given.
                # Driver types: 1=KernelDriver, 2=FileSystemDriver, 4=Adapter, 8=Recognizer
                if (-not $IncludeServices) {
                    $rows = [System.Collections.Generic.List[PSCustomObject]]($rows | Where-Object { $_.TypeVal -in @(1, 2, 4, 8) })
                }

                # Filter to issue rows only when -IssuesOnly is given.
                # An issue row is one that warrants attention:
                #   - Missing binary (any vendor)
                #   - Non-Microsoft vendor with a binary present
                #   - ErrorControl >= 2 (Severe/Critical) AND non-Microsoft vendor
                #     (Microsoft inbox drivers legitimately carry CRIT/Sev ErrorControl - that is normal)
                if ($IssuesOnly) {
                    $rows = [System.Collections.Generic.List[PSCustomObject]]($rows | Where-Object {
                            $isMsVendor = $_.Vendor -match 'Microsoft'
                            $_.BinaryPresent -eq $false -or
                            ($_.BinaryPresent -eq $true -and -not $isMsVendor) -or
                            ($null -ne $_.ErrorControl -and $_.ErrorControl -ge 2 -and -not $isMsVendor)
                        })
                }

                if ($rows.Count -eq 0) {
                    $noneMsg = if ($IssuesOnly) { "No issues found in the offline $reportLabel ControlSet - all entries look healthy." } else { "No $reportLabel entries found in the offline ControlSet." }
                    Write-Host "  $noneMsg" -ForegroundColor $(if ($IssuesOnly) { 'Green' } else { 'DarkGray' })
                    return
                }

                # Group by Start value, then sort alphabetically within each group
                $grouped = $rows | Sort-Object StartVal, Name

                $currentStart = $null
                foreach ($r in $grouped) {
                    if ($r.Start -ne $currentStart) {
                        $currentStart = $r.Start
                        $headerColor = switch ($r.Start) {
                            'Boot' { 'Red' }
                            'System' { 'Yellow' }
                            'Automatic' { 'Cyan' }
                            'Manual' { 'White' }
                            'Disabled' { 'DarkGray' }
                            default { 'Gray' }
                        }
                        Write-Host "`n  == $($r.Start.ToUpper()) =========================================" -ForegroundColor $headerColor
                        Write-Host ("  {0,-30} {1,-28} {2,-6} {3,-6} {4}" -f 'Name', 'Vendor', '[Pres]', 'ErCtl', 'ImagePath') -ForegroundColor DarkGray
                        Write-Host ("  {0,-30} {1,-28} {2,-6} {3,-6} {4}" -f ('-' * 30), ('-' * 28), '------', '------', ('-' * 40)) -ForegroundColor DarkGray
                    }

                    # Colour logic: missing binary = Red, non-Microsoft = Yellow, Microsoft = Green, N/A = Gray
                    $isMicrosoft = $r.Vendor -match 'Microsoft'
                    $isMissing = $r.BinaryPresent -eq $false
                    $noPath = $null -eq $r.BinaryPresent

                    $rowColor = if ($isMissing) { 'Red' }
                    elseif ($noPath) { 'DarkGray' }
                    elseif ($isMicrosoft) { 'Green' }
                    else { 'Yellow' }

                    $presTag = if ($isMissing) { 'MISS' } elseif ($noPath) { ' -- ' } else { ' OK ' }
                    $vendorShort = if ($r.Vendor.Length -gt 28) { $r.Vendor.Substring(0, 25) + '...' } else { $r.Vendor }

                    # ErrorControl: 0=Ignore, 1=Normal, 2=Severe (LKGC fallback), 3=Critical (boot failure)
                    $errCtlLabel = if ($null -eq $r.ErrorControl) { '    ' } else {
                        switch ($r.ErrorControl) { 0 { 'Ign' } 1 { 'Norm' } 2 { 'Sev!' } 3 { 'CRIT' } default { "EC$($r.ErrorControl)" } }
                    }

                    Write-Host ("  {0,-30} {1,-28} [{2}] {3,-6} {4}" -f $r.Name, $vendorShort, $presTag, $errCtlLabel, $r.ImagePath) -ForegroundColor $rowColor
                }

                # Summary
                $total = $rows.Count
                $missing = @($rows | Where-Object { $_.BinaryPresent -eq $false }).Count
                $nonMS = @($rows | Where-Object { $_.BinaryPresent -eq $true -and $_.Vendor -notmatch 'Microsoft' }).Count
                $boot_sys = @($rows | Where-Object { $_.StartVal -in @(0, 1) }).Count
                # ErrorControl Severe/Critical only matters for kernel drivers (Type 1/2/4/8);
                # Win32 services (Type 16/32/256) do not BSOD on failure regardless of ErrorControl.
                $isKernelDriver = @(1, 2, 4, 8)
                $sevCritDrivers = @($rows | Where-Object { $_.TypeVal -in $isKernelDriver -and $null -ne $_.ErrorControl -and $_.ErrorControl -ge 2 }).Count
                $missingBootSys = @($rows | Where-Object { $_.BinaryPresent -eq $false -and $_.StartVal -in @(0, 1) -and $_.TypeVal -in $isKernelDriver }).Count

                Write-Host "`n  ===========================================================" -ForegroundColor Cyan
                Write-Host ("  Total {0}: {1}  |  Boot/System: {2}  |  Missing binary: {3}  |  Non-Microsoft: {4}  |  Severe/Critical EC (drivers): {5}" `
                        -f $reportLabel, $total, $boot_sys, $missing, $nonMS, $sevCritDrivers) -ForegroundColor Cyan
                if ($missingBootSys -gt 0) {
                    Write-Host "  [!] $missingBootSys missing-binary Boot/System kernel driver(s) detected - may cause BSOD (e.g. INACCESSIBLE_BOOT_DEVICE)." -ForegroundColor Red
                    Write-Host "      Run -RepairBrokenSystemFile <driver.sys> to restore from WinSxS, or -DisableThirdPartyDrivers if the driver is non-Microsoft." -ForegroundColor Red
                }
                if ($missing -gt 0 -and $missing -ne $missingBootSys) {
                    $missingSvc = $missing - $missingBootSys
                    Write-Host "  [i] $missingSvc service(s)/non-boot driver(s) have missing binaries - the service will fail to start but will not BSOD." -ForegroundColor Yellow
                }
                if ($nonMS -gt 0) {
                    Write-Host "  [!] Non-Microsoft drivers present - verify each is expected for this guest OS." -ForegroundColor Yellow
                }
                if ($sevCritDrivers -gt 0) {
                    Write-Host "  [!] $sevCritDrivers kernel driver(s) with ErrorControl Sev!(2) or CRIT(3) - failure at boot will trigger LKGC fallback or halt." -ForegroundColor Yellow
                }
                Write-Host "  ===========================================================`n" -ForegroundColor Cyan
            }
        }
    }

    function EnableThirdPartyDrivers {
        Write-Host "Re-enabling previously disabled third-party kernel drivers..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            & {
                $SystemRoot = Get-SystemRootPath
                $ServicesRoot = "$SystemRoot\Services"

                $reEnabled = @()
                Get-ChildItem $ServicesRoot -ErrorAction SilentlyContinue | ForEach-Object {
                    $svcPath = $_.PSPath
                    $props = Get-ItemProperty -Path $svcPath -ErrorAction SilentlyContinue
                    # Only disabled kernel/filesystem drivers
                    if ($props.Type -notin @(1, 2)) { return }
                    if ($props.Start -ne 4) { return }

                    $imagePathRaw = $props.ImagePath
                    if (-not $imagePathRaw) { return }
                    $imagePath = Resolve-GuestImagePath $imagePathRaw

                    $isMicrosoft = $false
                    if (Test-Path $imagePath) {
                        $vi = (Get-Item $imagePath -ErrorAction SilentlyContinue).VersionInfo
                        if ($vi -and $vi.CompanyName -match 'Microsoft') { $isMicrosoft = $true }
                    }
                    else {
                        # Binary is missing - warn and skip re-enabling (re-enabling a driver with a
                        # missing binary will cause a BSOD on boot).
                        Write-Warning "Skipping $($_.PSChildName) - binary is missing ($imagePath). Restore the driver file before re-enabling."
                        return
                    }

                    if (-not $isMicrosoft) {
                        $svcName = $_.PSChildName
                        # Restore to System (1) start - safest default for a previously Boot/System driver
                        Write-Host "  Re-enabling: $svcName" -ForegroundColor Yellow
                        Set-ItemProperty-Logged -Path $svcPath -Name Start -Value 1 -Type DWord -Force
                        $reEnabled += $svcName
                    }
                }

                if ($reEnabled.Count -eq 0) {
                    Write-Host "No disabled third-party Boot/System drivers found to re-enable." -ForegroundColor Green
                }
                else {
                    Write-Host "`nRe-enabled $($reEnabled.Count) driver(s): $($reEnabled -join ', ')" -ForegroundColor Green
                    Write-Warning "Start value restored to 1 (System). If a driver was originally Boot (0), adjust manually after verifying VM boots." 
                }
            }
        }
    }

    # Remove the Credential Guard UEFI firmware variable that persists when CG is enabled with UEFI lock.
    # Registry changes alone (zeroing LsaCfgFlags) are insufficient because the EFI NVRAM variable
    # survives reboots independently of the registry.
    # This script repairs offline disks that are later reattached to their Azure VM, so the only
    # viable offline method is injecting a SecConfig.efi one-time BCD boot entry: on the VM's next
    # boot (on Azure) the EFI application runs and clears the UEFI variable inside the guest firmware.
    # NOTE: -FixBoot (RebuildBCD) only recreates the BCD store and does NOT clear this EFI variable.
    function Remove-CredentialGuardUefiLock {
        # ------------------------------------------------------------------
        # bcdedit + SecConfig.efi one-time-boot entry
        # Copies the Microsoft-supplied SecConfig.efi tool to the guest's EFI
        # partition on the offline disk and adds a one-time BCD bootsequence
        # entry. When the disk is reattached to the Azure VM and it boots,
        # SecConfig.efi runs inside the VM and clears the UEFI NVRAM variable.
        # Azure Gen2/Trusted Launch VMs auto-accept the confirmation (no
        # physical key press required).
        # ------------------------------------------------------------------
        if ($script:VMGen -ne 2 -or [string]::IsNullOrWhiteSpace($script:BootDriveLetter)) {
            Write-Warning "  SecConfig.efi method requires a mounted Gen2/UEFI EFI partition - skipping."
            Write-Error "UEFI lock could not be cleared: EFI partition not available."
            return
        }

        $efiVolume = $script:BootDriveLetter.TrimEnd('\')
        $storePath = "$efiVolume\EFI\Microsoft\Boot\BCD"
        $secDest = "$efiVolume\EFI\Microsoft\Boot\SecConfig.efi"
        $secSrc = "$env:SystemRoot\System32\SecConfig.efi"

        if (-not (Test-Path $secSrc)) {
            Write-Warning "  SecConfig.efi not found at '$secSrc' on this host."
            Write-Error "UEFI lock could not be cleared: SecConfig.efi unavailable."
            return
        }

        if (-not (Test-Path $storePath)) {
            Write-Warning "  Offline BCD not found at '$storePath'."
            Write-Error "UEFI lock could not be cleared: offline BCD not found."
            return
        }

        try {
            Write-Host "  Configuring SecConfig.efi one-time boot entry in offline BCD..." -ForegroundColor Cyan
            Copy-Item-Logged -Path $secSrc -Destination $secDest -Force

            # Well-known GUID defined by Microsoft for the CG disable tool boot entry
            $cgGuid = '{0cb3b571-2f2e-4343-a879-d86a476d7215}'

            # Remove any pre-existing entry with this GUID to ensure a clean state
            $deleteBcdCmd = "bcdedit /store `"$storePath`" /delete $cgGuid /cleanup"
            Write-Host "  [exec] $deleteBcdCmd" -ForegroundColor DarkGray
            & cmd.exe /c $deleteBcdCmd 2>&1 | Out-Null

            # Create the one-time boot sequence entry
            $bcdCmds = @(
                "/create $cgGuid /d `"CredentialGuard UEFI Disable Tool`" /application osloader",
                "/set $cgGuid path `"\EFI\Microsoft\Boot\SecConfig.efi`"",
                "/set {bootmgr} bootsequence $cgGuid",
                "/set $cgGuid loadoptions DISABLE-LSA-ISO",
                "/set $cgGuid device partition=${efiVolume}:"
            )
            foreach ($cmd in $bcdCmds) {
                Invoke-BcdEdit -StorePath $storePath -Command $cmd
            }

            Write-Host "  [OK] SecConfig.efi one-time boot entry added to offline BCD." -ForegroundColor Green
            Write-Host ("  On the VM's first boot back on Azure, SecConfig.efi will run inside the VM " +
                "and clear the Credential Guard EFI NVRAM variable automatically.") -ForegroundColor Cyan
        }
        catch {
            Write-Warning "  bcdedit SecConfig.efi setup failed: $_"
            Write-Error "UEFI lock could not be cleared."
        }
    }

    function DisableCredentialGuard {
        Write-Host "Disabling Credential Guard and LSA protection..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM', 'SOFTWARE' {
            $SystemRoot = Get-SystemRootPath

            $lsaPath = "$SystemRoot\Control\Lsa"
            $cgPath = "HKLM:\BROKENSOFTWARE\Policies\Microsoft\Windows\DeviceGuard"
            $cgSysPath = "$SystemRoot\Control\DeviceGuard"

            # Snapshot for restore
            $beforeRunAsPPL = (Get-ItemProperty $lsaPath   -ErrorAction SilentlyContinue).RunAsPPL
            $beforeLsaCfg = (Get-ItemProperty $cgSysPath -ErrorAction SilentlyContinue).LsaCfgFlags
            $beforeCGEnabled = (Get-ItemProperty $cgPath    -ErrorAction SilentlyContinue).EnableVirtualizationBasedSecurity

            # Detect UEFI lock: LsaCfgFlags=1 in Control\Lsa means CG was enabled WITH UEFI lock.
            # The EFI NVRAM variable survives registry changes and must be cleared separately.
            # LsaCfgFlags=2 means enabled WITHOUT lock - registry zeroing is sufficient.
            $lsaLsaCfgFlags = (Get-ItemProperty $lsaPath -ErrorAction SilentlyContinue).LsaCfgFlags
            if ($lsaLsaCfgFlags -eq 1) {
                $uefiLockWasActive = $true
                Write-Warning ("Credential Guard was enabled WITH UEFI lock (Control\Lsa\LsaCfgFlags=1). " +
                    "An EFI NVRAM variable is also set - registry changes alone are not sufficient. " +
                    "The UEFI firmware variable will be cleared after applying registry changes.")
            }
            elseif ($lsaLsaCfgFlags -eq 2) {
                Write-Host "  Credential Guard mode: WITHOUT UEFI lock - registry changes are sufficient." -ForegroundColor Cyan
            }

            # Zero all registry knobs (both paths that can enforce CG)
            Set-ItemProperty-Logged -Path $lsaPath   -Name RunAsPPL    -Value 0 -Type DWord -Force
            Set-ItemProperty-Logged -Path $lsaPath   -Name LsaCfgFlags -Value 0 -Type DWord -Force
            Set-ItemProperty-Logged -Path $cgSysPath -Name LsaCfgFlags -Value 0 -Type DWord -Force
            if (Test-Path $cgPath) {
                Set-ItemProperty-Logged -Path $cgPath -Name EnableVirtualizationBasedSecurity -Value 0 -Type DWord -Force
                Set-ItemProperty-Logged -Path $cgPath -Name LsaCfgFlags                       -Value 0 -Type DWord -Force
            }

            Write-Host "Credential Guard registry settings cleared. Use -EnableCredentialGuard to revert." -ForegroundColor Green
            Write-Host "`n--- REVERT COMMANDS (run on the VM after recovery) ---" -ForegroundColor Cyan
            $lsaLive = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
            $cgSysLive = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"
            $cgLive = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard"
            Write-Host "Set-ItemProperty -Path '$lsaLive'   -Name RunAsPPL    -Value $(if ($null -ne $beforeRunAsPPL) { $beforeRunAsPPL } else { '1 # (was not set)' }) -Type DWord -Force" -ForegroundColor White
            Write-Host "Set-ItemProperty -Path '$cgSysLive' -Name LsaCfgFlags -Value $(if ($null -ne $beforeLsaCfg)  { $beforeLsaCfg  } else { '1 # (was not set)' }) -Type DWord -Force" -ForegroundColor White
            if ($null -ne $beforeCGEnabled) {
                Write-Host "Set-ItemProperty -Path '$cgLive' -Name EnableVirtualizationBasedSecurity -Value $beforeCGEnabled -Type DWord -Force" -ForegroundColor White
            }
            Write-Host "------------------------------------------------------`n" -ForegroundColor Cyan
        }

        # Hives are now safely unmounted. Clear the EFI NVRAM variable if UEFI lock was active.
        if ($uefiLockWasActive) {
            Write-Host "`nClearing Credential Guard EFI NVRAM variable (UEFI lock)..." -ForegroundColor Yellow
            Remove-CredentialGuardUefiLock
        }
    }

    function EnableCredentialGuard {
        Write-Host "Re-enabling Credential Guard and LSA protection..." -ForegroundColor Yellow

        # ----------------------------------------------------------------
        # Safety gate 1: Credential Guard requires UEFI Secure Boot (Gen2/GPT).
        # Writing the registry flags on a Gen1/MBR VM causes a no-boot scenario
        # because Windows cannot satisfy the Secure Boot requirement at startup.
        # $script:VMGen is already set by Repair-OfflineDisk via Get-DiskGeneration
        # (GPT -> 2, MBR -> 1), so this check is reliable even when -DiskNumber
        # is used instead of -VMName.
        # ----------------------------------------------------------------
        if ($script:VMGen -eq 1) {
            Write-Error ("BLOCKED: This disk uses MBR/BIOS (Gen1). Credential Guard requires UEFI Secure Boot " +
                "(Gen2/GPT). Enabling it on a Gen1 VM writes flags that prevent Windows from booting. Aborting.")
            return
        }
        if ($null -eq $script:VMGen) {
            Write-Error ("BLOCKED: Disk partition style could not be determined (expected MBR=Gen1 or GPT=Gen2). " +
                "Credential Guard requires UEFI/GPT (Gen2). Aborting to prevent a potential no-boot scenario.")
            return
        }

        Invoke-WithHive 'SYSTEM', 'SOFTWARE' {
            $SystemRoot = Get-SystemRootPath

            # ----------------------------------------------------------------
            # Safety gate 2: Credential Guard is only supported on Enterprise,
            # Education, and Server editions. Enabling it on Home/Pro/Core writes
            # the same registry flags but Windows will fail a boot-time licence
            # check resulting in an unbootable VM.
            # ----------------------------------------------------------------
            $winVer = Get-ItemProperty "HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
            $editionId = $winVer.EditionID
            $productName = $winVer.ProductName
            $unsupportedEditions = @('Home', 'Pro', 'CoreSingleLanguage', 'Core', 'ProWorkstation', 'ProfessionalWorkstation')
            $editionBlocked = $unsupportedEditions | Where-Object { $editionId -match $_ }
            if ($editionBlocked) {
                Write-Error ("BLOCKED: Windows edition '$editionId' ($productName) does not support Credential Guard. " +
                    "Only Enterprise, Education, and Server editions are supported. Aborting.")
                return
            }
            if ($editionId) {
                Write-Host "  Windows edition: $editionId ($productName) - supported." -ForegroundColor Cyan
            }
            else {
                Write-Warning "  Could not read Windows edition from offline hive; proceeding with caution."
            }

            $lsaPath = "$SystemRoot\Control\Lsa"
            $cgSysPath = "$SystemRoot\Control\DeviceGuard"
            $cgPath = "HKLM:\BROKENSOFTWARE\Policies\Microsoft\Windows\DeviceGuard"

            Set-ItemProperty-Logged -Path $lsaPath   -Name RunAsPPL     -Value 1 -Type DWord -Force
            Set-ItemProperty-Logged -Path $cgSysPath -Name LsaCfgFlags  -Value 1 -Type DWord -Force
            if (Test-Path $cgPath) {
                Set-ItemProperty-Logged -Path $cgPath -Name EnableVirtualizationBasedSecurity -Value 1 -Type DWord -Force
                Set-ItemProperty-Logged -Path $cgPath -Name LsaCfgFlags                       -Value 1 -Type DWord -Force
            }

            Write-Host "Credential Guard and LSA protection re-enabled." -ForegroundColor Green
            Write-Warning ("Before starting the VM, verify in Hyper-V settings that: " +
                "(1) Secure Boot is enabled, (2) Virtualization Based Security (VBS) is enabled. " +
                "If either is missing the VM will fail to boot. Use -DisableCredentialGuard to revert.")
        }
    }

    function DisableAppLocker {
        # AppLocker can prevent Windows from booting when an Enforce-mode policy incorrectly
        # blocks a system binary, service DLL, or startup script. The fix has two parts:
        #
        #  1. Set all AppLocker rule collection EnforcementMode values to 0 (Not Configured)
        #     in both the GPO-policy path (SOFTWARE\Policies) and the local policy path.
        #     This is non-destructive: the rules are preserved but not enforced, so the
        #     admin can re-enable them once the VM is healthy.
        #
        #  2. Disable the Application Identity service (AppIDSvc). AppLocker relies on this
        #     service at runtime; disabling it prevents enforcement even if the policy paths
        #     are re-applied by GPO refresh before an admin can investigate.
        #
        # EnforcementMode values:
        #   0 = Not Configured (rules ignored)
        #   1 = Enforce rules
        #   2 = Audit only

        Write-Host "Disabling AppLocker enforcement..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM', 'SOFTWARE' {
            $SystemRoot = Get-SystemRootPath

            # Rule collection names that AppLocker enforces
            $ruleCollections = @('Exe', 'Dll', 'Script', 'Msi', 'Appx')

            # Two registry paths can carry AppLocker policy:
            #   - GPO/MDM-applied:  SOFTWARE\Policies\Microsoft\Windows\SrpV2
            #   - Local policy:     SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\AppV (rare)
            # The GPO path is by far the most common source of broken policies on Azure VMs.
            $srpPaths = @(
                'HKLM:\BROKENSOFTWARE\Policies\Microsoft\Windows\SrpV2',
                'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\AppV\SrpV2'
            )

            # --- Pass 1: scan for any actively-enforced collections (mode 1 or 2) ---
            $enforced = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($srpBase in $srpPaths) {
                if (-not (Test-Path $srpBase)) { continue }
                foreach ($collection in $ruleCollections) {
                    $collPath = "$srpBase\$collection"
                    if (-not (Test-Path $collPath)) { continue }
                    $current_mode = (Get-ItemProperty $collPath -ErrorAction SilentlyContinue).EnforcementMode
                    if ($null -ne $current_mode -and $current_mode -ne 0) {
                        $modeLabel = if ($current_mode -eq 1) { 'Enforce' } else { 'Audit' }
                        Write-Host "  [$collection] EnforcementMode = $current_mode ($modeLabel) - will disable." -ForegroundColor Yellow
                        $enforced.Add(@{ Path = $collPath; Collection = $collection; Mode = $current_mode })
                    }
                }
            }

            # --- Check AppIDSvc start value ---
            $appIdPath = "$SystemRoot\Services\AppIDSvc"
            $appIdStart = if (Test-Path $appIdPath) { (Get-ItemProperty $appIdPath -ErrorAction SilentlyContinue).Start } else { $null }
            # Service runs if Start is 2 (Auto) or 3 (Manual/demand); 4 = Disabled, 1 = Boot (unlikely)
            $appIdRunning = $null -ne $appIdStart -and $appIdStart -in @(1, 2, 3)

            # --- Early exit if nothing is active ---
            if ($enforced.Count -eq 0 -and -not $appIdRunning) {
                Write-Host "  AppLocker is not enforced (no active rule collections, AppIDSvc not running). No changes made." -ForegroundColor Green
                return
            }

            # --- Pass 2: disable only what is active ---
            foreach ($item in $enforced) {
                Write-Host "  [$($item.Collection)] EnforcementMode: $($item.Mode) -> 0 (Not Configured)" -ForegroundColor Cyan
                Set-ItemProperty-Logged -Path $item.Path -Name EnforcementMode -Value 0 -Type DWord -Force
            }

            # Disable Application Identity service so AppLocker cannot enforce at runtime
            # even if GPO refreshes the policy keys before an admin can intervene.
            if ($appIdRunning) {
                Write-Host "  AppIDSvc Start: $appIdStart -> 4 (Disabled)" -ForegroundColor Cyan
                Set-ItemProperty-Logged -Path $appIdPath -Name Start -Value 4 -Type DWord -Force
            }
            elseif (-not (Test-Path $appIdPath)) {
                Write-Host "  AppIDSvc registry key not found - service not installed on this image." -ForegroundColor DarkGray
            }

            Write-Host "AppLocker enforcement disabled." -ForegroundColor Green
            Write-Host ("  NOTE: AppLocker rules are preserved (EnforcementMode=0). " +
                "To re-enable, set EnforcementMode=1 under SOFTWARE\Policies\Microsoft\Windows\SrpV2\<Collection> " +
                "and set AppIDSvc Start back to 2 (Automatic) on the live VM.") -ForegroundColor Cyan
            Write-Warning ("If AppLocker policy is delivered by Intune/MDM, the offline registry path will be empty " +
                "and policy will reapply on next MDM sync. Resolve via Intune before starting the VM.")
        }
    }

    function GetAppLockerReport {
        # Reads AppLocker configuration from the offline SOFTWARE and SYSTEM hives and
        # produces a human-readable report:
        #   - Per-collection enforcement mode
        #   - AppIDSvc service start type
        #   - Parsed rule details (Name, Action, Type, Conditions)
        Write-Host "`n========== AppLocker Report ==========" -ForegroundColor Cyan

        Invoke-WithHive 'SYSTEM', 'SOFTWARE' {
            & {
                # --- AppIDSvc from SYSTEM hive ---
                $sel = Get-ItemProperty 'HKLM:\BROKENSYSTEM\Select' -ErrorAction SilentlyContinue
                $curSet = $sel.Current
                $csName = if ($curSet) { 'ControlSet{0:d3}' -f $curSet } else { 'ControlSet001' }
                $svcRoot = "HKLM:\BROKENSYSTEM\$csName\Services"

                $appIdPath = "$svcRoot\AppIDSvc"
                $appIdStart = if (Test-Path $appIdPath) { (Get-ItemProperty $appIdPath -ErrorAction SilentlyContinue).Start } else { $null }
                $startLabels = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
                $startLabel = if ($null -ne $appIdStart -and $startLabels.ContainsKey([int]$appIdStart)) { $startLabels[[int]$appIdStart] } else { "Unknown($appIdStart)" }

                Write-Host "`n--- Application Identity Service (AppIDSvc) ---" -ForegroundColor Yellow
                if ($null -eq $appIdStart) {
                    Write-Host "  AppIDSvc registry key not found - service not installed." -ForegroundColor DarkGray
                }
                elseif ($appIdStart -eq 2) {
                    Write-Host "  Start = $appIdStart ($startLabel)" -ForegroundColor Red
                    Write-Host "  AppIDSvc is set to AUTO - AppLocker WILL enforce rules at boot." -ForegroundColor Red
                }
                elseif ($appIdStart -eq 3) {
                    Write-Host "  Start = $appIdStart ($startLabel)" -ForegroundColor Yellow
                    Write-Host "  AppIDSvc is Manual - may be trigger-started if AppLocker policy exists." -ForegroundColor Yellow
                }
                elseif ($appIdStart -eq 4) {
                    Write-Host "  Start = $appIdStart ($startLabel)" -ForegroundColor Green
                    Write-Host "  AppIDSvc is Disabled - AppLocker rules will NOT be enforced at runtime." -ForegroundColor Green
                }
                else {
                    Write-Host "  Start = $appIdStart ($startLabel)" -ForegroundColor Yellow
                }

                # --- AppLocker policy from SOFTWARE hive ---
                $srpPaths = @(
                    @{ Label = 'GPO/MDM Policy'; Path = 'HKLM:\BROKENSOFTWARE\Policies\Microsoft\Windows\SrpV2' },
                    @{ Label = 'Local Policy';   Path = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\AppV\SrpV2' }
                )
                $modeLabels = @{ 0 = 'Not Configured'; 1 = 'Enforce'; 2 = 'Audit Only' }
                $collections = @('Exe', 'Dll', 'Script', 'Msi', 'Appx')

                $anyFound = $false
                foreach ($srp in $srpPaths) {
                    if (-not (Test-Path $srp.Path)) { continue }

                    Write-Host "`n--- $($srp.Label): $($srp.Path -replace '^HKLM:\\BROKENSOFTWARE\\', 'SOFTWARE\') ---" -ForegroundColor Yellow

                    foreach ($col in $collections) {
                        $colPath = "$($srp.Path)\$col"
                        if (-not (Test-Path $colPath)) { continue }

                        $mode = (Get-ItemProperty $colPath -ErrorAction SilentlyContinue).EnforcementMode
                        $modeLabel = if ($null -ne $mode -and $modeLabels.ContainsKey([int]$mode)) { $modeLabels[[int]$mode] } else { "Unknown($mode)" }

                        $modeColor = switch ([int]$mode) { 1 { 'Red' } 2 { 'Yellow' } default { 'Green' } }
                        Write-Host "`n  [$col] EnforcementMode = $mode ($modeLabel)" -ForegroundColor $modeColor

                        # Enumerate GUID rule subkeys
                        $ruleKeys = @(Get-ChildItem $colPath -ErrorAction SilentlyContinue |
                            Where-Object { $_.PSChildName -match '^\{[0-9a-f-]{36}\}$' })

                        if ($ruleKeys.Count -eq 0) {
                            Write-Host "    No rules found." -ForegroundColor DarkGray
                            continue
                        }

                        $anyFound = $true
                        Write-Host "    Rules ($($ruleKeys.Count)):" -ForegroundColor White

                        foreach ($rk in $ruleKeys) {
                            $ruleId = $rk.PSChildName
                            $valueData = (Get-ItemProperty $rk.PSPath -ErrorAction SilentlyContinue).Value
                            if (-not $valueData) {
                                Write-Host "      $ruleId - (no Value data)" -ForegroundColor DarkGray
                                continue
                            }

                            # Parse the XML rule
                            try {
                                [xml]$ruleXml = $valueData
                                $ruleNode = $ruleXml.DocumentElement
                                $ruleName   = $ruleNode.Name
                                $ruleAction = $ruleNode.Action
                                $ruleDesc   = $ruleNode.Description
                                $ruleType   = $ruleNode.LocalName   # e.g. FilePublisherRule, FileHashRule, FilePathRule
                                $ruleSid    = $ruleNode.UserOrGroupSid

                                # Determine action colour
                                $actionColor = if ($ruleAction -eq 'Deny') { 'Red' } elseif ($ruleAction -eq 'Allow') { 'Green' } else { 'Yellow' }

                                Write-Host "      $ruleId" -ForegroundColor DarkGray
                                Write-Host "        Name   : $ruleName" -ForegroundColor White
                                Write-Host "        Type   : $ruleType" -ForegroundColor White
                                Write-Host "        Action : " -NoNewline; Write-Host $ruleAction -ForegroundColor $actionColor
                                if ($ruleDesc) { Write-Host "        Desc   : $ruleDesc" -ForegroundColor White }
                                Write-Host "        SID    : $ruleSid" -ForegroundColor DarkGray

                                # Extract condition details based on rule type
                                $conditions = $ruleNode.Conditions
                                if ($conditions) {
                                    foreach ($child in $conditions.ChildNodes) {
                                        switch ($child.LocalName) {
                                            'FilePublisherCondition' {
                                                Write-Host "        Publisher  : $($child.PublisherName)" -ForegroundColor Cyan
                                                Write-Host "        Product   : $($child.ProductName)" -ForegroundColor Cyan
                                                Write-Host "        Binary    : $($child.BinaryName)" -ForegroundColor Cyan
                                                $vr = $child.BinaryVersionRange
                                                if ($vr) { Write-Host "        Version   : $($vr.LowSection) - $($vr.HighSection)" -ForegroundColor DarkGray }
                                            }
                                            'FileHashCondition' {
                                                foreach ($fh in $child.ChildNodes) {
                                                    if ($fh.LocalName -eq 'FileHash') {
                                                        Write-Host "        Hash Type : $($fh.Type)" -ForegroundColor Cyan
                                                        Write-Host "        Hash      : $($fh.Data)" -ForegroundColor Cyan
                                                        Write-Host "        Source    : $($fh.SourceFileName) ($($fh.SourceFileLength) bytes)" -ForegroundColor DarkGray
                                                    }
                                                }
                                            }
                                            'FilePathCondition' {
                                                Write-Host "        Path      : $($child.Path)" -ForegroundColor Cyan
                                            }
                                        }
                                    }
                                }

                                # Exceptions
                                $exceptions = $ruleNode.Exceptions
                                if ($exceptions -and $exceptions.HasChildNodes) {
                                    Write-Host "        Exceptions:" -ForegroundColor Yellow
                                    foreach ($exc in $exceptions.ChildNodes) {
                                        switch ($exc.LocalName) {
                                            'FilePublisherCondition' { Write-Host "          Publisher: $($exc.PublisherName) / $($exc.ProductName) / $($exc.BinaryName)" -ForegroundColor Yellow }
                                            'FileHashCondition'      { foreach ($fh in $exc.ChildNodes) { if ($fh.LocalName -eq 'FileHash') { Write-Host "          Hash: $($fh.SourceFileName) ($($fh.Type))" -ForegroundColor Yellow } } }
                                            'FilePathCondition'      { Write-Host "          Path: $($exc.Path)" -ForegroundColor Yellow }
                                        }
                                    }
                                }
                            }
                            catch {
                                Write-Host "      $ruleId - failed to parse XML: $_" -ForegroundColor Red
                            }
                        }
                    }
                }

                if (-not $anyFound) {
                    Write-Host "`n  No AppLocker rule subkeys found in any collection." -ForegroundColor Green
                }
            }
        }

        Write-Host "`n========================================`n" -ForegroundColor Cyan
    }

    function FixSanPolicy {
        Write-Host "Setting SAN policy to OnlineAll so all disks come online on boot..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath
            $sanPath = "$SystemRoot\Services\partmgr\Parameters"

            $before = (Get-ItemProperty $sanPath -ErrorAction SilentlyContinue).SanPolicy
            Set-ItemProperty-Logged -Path $sanPath -Name SanPolicy -Value 1 -Type DWord -Force  # 1 = OnlineAll

            Write-Host "SAN policy set to OnlineAll (1). Previous value: $(if ($null -ne $before) { $before } else { 'not set' })." -ForegroundColor Green
            Write-Host "Revert: Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\partmgr\Parameters' -Name SanPolicy -Value $(if ($null -ne $before) { $before } else { 4 }) -Type DWord -Force" -ForegroundColor DarkCyan
        }
    }

    function FixAzureGuestAgent {
        Write-Host "Enabling Azure Guest Agent and RdAgent services..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath

            $agents = @(
                @{ Name = 'WindowsAzureGuestAgent'; StartValue = 2 },
                @{ Name = 'RdAgent'; StartValue = 2 },
                @{ Name = 'WindowsAzureTelemetryService'; StartValue = 3 }
            )

            foreach ($agent in $agents) {
                $svcPath = "$SystemRoot\Services\$($agent.Name)"
                if (Test-Path $svcPath) {
                    $before = (Get-ItemProperty $svcPath -ErrorAction SilentlyContinue).Start
                    Set-ItemProperty-Logged -Path $svcPath -Name Start -Value $agent.StartValue -Type DWord -Force
                    Write-Host "  $($agent.Name): Start set to $($agent.StartValue) (was $before)" -ForegroundColor Green
                }
                else {
                    Write-Warning "  $($agent.Name) not found in registry - agent may not be installed."
                }
            }
            Write-Host "Azure Guest Agent services configured. Boot the VM for them to start." -ForegroundColor Green
        }
    }

    function InstallAzureVMAgentOffline {
        # Implements the offline VM Agent installation procedure from:
        # https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/install-vm-agent-offline
        #
        # Source: this Hyper-V rescue VM (must have Azure VM Agent installed locally).
        # Steps:
        #   1. Validate the host has the required service registry keys and GuestAgent files.
        #   2. Backup any existing WindowsAzure folder on the offline disk.
        #   3. Copy GuestAgent_* folder(s) from C:\WindowsAzure on the host to the offline disk.
        #   4. Mount the offline SYSTEM hive and copy the service registry keys into it.
        #   5. Set service Start values to Auto so the agent starts on next boot.

        Write-Host "Installing Azure VM Agent in offline mode..." -ForegroundColor Yellow

        # ------------------------------------------------------------------
        # Step 1: Validate host sources
        # ------------------------------------------------------------------
        $requiredSvcs = @('WindowsAzureGuestAgent', 'RdAgent')
        foreach ($svc in $requiredSvcs) {
            $hostKey = "HKLM:\SYSTEM\ControlSet001\Services\$svc"
            if (-not (Test-Path $hostKey)) {
                Write-Error ("SKIPPED: Host registry key '$hostKey' not found. " +
                    "Azure VM Agent must be installed on this Hyper-V rescue VM to use -InstallAzureVMAgent. " +
                    "Download and install the agent from https://aka.ms/vmagentwin first.")
                return
            }
        }

        $hostWaFolder = 'C:\WindowsAzure'
        if (-not (Test-Path $hostWaFolder)) {
            Write-Error ("SKIPPED: '$hostWaFolder' not found on this host. " +
                "Azure VM Agent must be installed on this Hyper-V rescue VM to use -InstallAzureVMAgent.")
            return
        }

        $agentFolders = Get-ChildItem -Path $hostWaFolder -Directory -Filter 'GuestAgent_*' -ErrorAction SilentlyContinue |
        Sort-Object Name
        if (-not $agentFolders) {
            # Fallback: check ImagePath in the host registry to find the folder
            $imgPath = (Get-ItemProperty 'HKLM:\SYSTEM\ControlSet001\Services\WindowsAzureGuestAgent' `
                    -ErrorAction SilentlyContinue).ImagePath
            $imgDir = if ($imgPath) { Split-Path $imgPath -Parent } else { $null }
            if ($imgDir -and (Test-Path $imgDir)) {
                Write-Host "  No GuestAgent_* folder found; using ImagePath directory: $imgDir" -ForegroundColor Cyan
                $agentFolders = @(Get-Item $imgDir)
            }
            else {
                Write-Error ("SKIPPED: No GuestAgent_* folders found under '$hostWaFolder' and ImagePath resolution failed. " +
                    "Cannot copy agent binaries to the offline disk.")
                return
            }
        }

        # ------------------------------------------------------------------
        # Step 2: Backup existing WindowsAzure folder on the offline disk
        # ------------------------------------------------------------------
        $offlineWaRoot = Join-Path $script:WinDriveLetter 'WindowsAzure'
        if (Test-Path $offlineWaRoot) {
            $bakPath = New-UniqueBackupPath -BasePath $offlineWaRoot -BakSuffix '.old'
            Write-Host "  Renaming existing WindowsAzure folder -> $bakPath" -ForegroundColor Yellow
            Move-Item-Logged -LiteralPath $offlineWaRoot -Destination $bakPath -Force
        }
        New-Item-Logged -Path $offlineWaRoot -ItemType Directory -Force

        # ------------------------------------------------------------------
        # Step 3: Copy GuestAgent folder(s) to the offline disk
        # ------------------------------------------------------------------
        foreach ($folder in $agentFolders) {
            $dest = Join-Path $offlineWaRoot $folder.Name
            Write-Host "  Copying $($folder.Name) -> $dest" -ForegroundColor Cyan
            Copy-Item-Logged -Path $folder.FullName -Destination $dest -Recurse -Force
        }

        # ------------------------------------------------------------------
        # Step 4 + 5: Import service registry keys into the offline SYSTEM hive
        # ------------------------------------------------------------------
        Invoke-WithHive 'SYSTEM' {
            $currentSet = (Get-ItemProperty 'HKLM:\BROKENSYSTEM\Select' -ErrorAction SilentlyContinue).Current
            $csName = if ($currentSet) { 'ControlSet{0:d3}' -f $currentSet } else { 'ControlSet001' }

            foreach ($svc in $requiredSvcs) {
                $srcReg = "HKLM\SYSTEM\ControlSet001\Services\$svc"
                $dstReg = "HKLM\BROKENSYSTEM\$csName\Services\$svc"

                Write-Host "  Copying registry: $svc -> offline $csName..." -ForegroundColor Cyan
                $out = reg.exe copy $srcReg $dstReg /s /f 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "reg.exe copy failed for '$svc': $out"
                }

                # If the active control set is not ControlSet001, also stamp ControlSet001
                # in the offline hive so both are consistent (Windows reconciles them on boot).
                if ($csName -ne 'ControlSet001') {
                    $dstReg001 = "HKLM\BROKENSYSTEM\ControlSet001\Services\$svc"
                    if (Test-Path "HKLM:\BROKENSYSTEM\ControlSet001") {
                        $out = reg.exe copy $srcReg $dstReg001 /s /f 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            Write-Warning "  Could not stamp ControlSet001 for '$svc' (may not exist): $out"
                        }
                    }
                }

                # Ensure Start = 2 (Automatic) - the copied key may have a different value
                Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\$csName\Services\$svc" `
                    -Name Start -Value 2 -Type DWord -Force
            }

            # RdAgent depends on TermService; make sure it isn't hard-disabled
            $termSvcPath = "HKLM:\BROKENSYSTEM\$csName\Services\TermService"
            if (Test-Path $termSvcPath) {
                $tsBefore = (Get-ItemProperty $termSvcPath -ErrorAction SilentlyContinue).Start
                if ($tsBefore -eq 4) {
                    Write-Host "  TermService was Disabled - re-enabling to Auto." -ForegroundColor Yellow
                    Set-ItemProperty-Logged -Path $termSvcPath -Name Start -Value 2 -Type DWord -Force
                }
            }

            Write-Host "`nAzure VM Agent installed offline successfully." -ForegroundColor Green
            Write-Host "  Agent binaries : $offlineWaRoot" -ForegroundColor Green
            Write-Host "  Registry keys  : BROKENSYSTEM\$csName\Services\{WindowsAzureGuestAgent,RdAgent}" -ForegroundColor Green
            Write-Host "  After booting the VM, verify the agent with: Get-Service WindowsAzureGuestAgent" -ForegroundColor Cyan
        }
    }

    function FixDeviceClassFilters {
        param([switch]$KeepDefaultFilters)
        # Scans UpperFilters and LowerFilters for key device class GUIDs identified by Microsoft
        # as critical for boot and network connectivity on Azure VMs.
        #
        # Classes checked (from MS troubleshooting docs):
        #   {4d36e967} DiskDrive  - extra filters  -> stop error 0x7B
        #   {4d36e96a} SCSI/RAID  - extra filters  -> stop error 0x7B
        #   {4d36e97b} SCSIAdapter - extra filters -> stop error 0x7B
        #   {71a27cdd} Volume     - extra filters  -> boot/access failures
        #   {4d36e972} Net        - extra filters  -> complete network loss
        #
        # Decision logic per filter entry (in order of precedence):
        #   1. Binary is missing from offline disk              -> REMOVE (dangling filter will BSOD/hang on boot)
        #   2. Name is in the known-safe list for that class    -> KEEP
        #   3. (skipped when -KeepDefaultFilters) Same entry exists in the host's live class key -> KEEP
        #   4. (skipped when -KeepDefaultFilters) Binary found on offline disk and CompanyName matches Microsoft or an allowed vendor -> KEEP
        #   5. Anything else                                    -> REMOVE and log
        #
        # Special allowances:
        #   Network class: Mellanox/NVIDIA drivers are expected on Azure VMs (Mellanox VF/MANA).
        #
        # GUIDs:
        #   Disk drive     : {4d36e967-e325-11ce-bfc1-08002be10318}
        #   SCSI/RAID      : {4d36e96a-e325-11ce-bfc1-08002be10318}
        #   SCSI Controller: {4d36e97b-e325-11ce-bfc1-08002be10318}
        #   Volume         : {71a27cdd-812a-11d0-bec7-08002be2092f}
        #   Net adapter    : {4d36e972-e325-11ce-bfc1-08002be10318}

        Write-Host "Scanning device class UpperFilters/LowerFilters for unsafe entries..." -ForegroundColor Yellow
        if ($KeepDefaultFilters) {
            Write-Host "  Mode: strict (-KeepDefaultFilters) - only inbox safe-list entries will be kept; Microsoft-signed non-defaults will be removed." -ForegroundColor Cyan
        }
        Invoke-WithHive 'SYSTEM' {
            $currentSet = (Get-ItemProperty "HKLM:\BROKENSYSTEM\Select" -ErrorAction SilentlyContinue).Current
            $csName = if ($currentSet) { "ControlSet{0:d3}" -f $currentSet } else { "ControlSet001" }
            $classRoot = "HKLM:\BROKENSYSTEM\$csName\Control\Class"

            # Class definitions.
            # SafeFilters  : Known Windows inbox / Azure-expected filter names (case-insensitive). Always kept.
            # AllowVendors : Additional vendor substrings matched against binary CompanyName (beyond Microsoft).
            $classChecks = @(
                [PSCustomObject]@{
                    GUID         = '{4d36e967-e325-11ce-bfc1-08002be10318}'
                    Name         = 'DiskDrive'
                    Risk         = 'CRITICAL'
                    Description  = 'Extra filters in this class cause stop error 0x7B (INACCESSIBLE_BOOT_DEVICE) on boot'
                    # PartMgr     - partition manager (required)
                    # fvevol      - BitLocker FVE
                    # iorate      - Storage I/O rate limiting (Azure)
                    # storqosflt  - Storage QoS filter (Azure)
                    # wcifs       - Windows Container Isolation
                    # ehstorclass - Enhanced Storage class filter (Microsoft)
                    SafeFilters  = [string[]]@('partmgr', 'fvevol', 'iorate', 'storqosflt', 'wcifs', 'ehstorclass')
                    AllowVendors = [string[]]@()
                },
                [PSCustomObject]@{
                    GUID         = '{4d36e96a-e325-11ce-bfc1-08002be10318}'
                    Name         = 'SCSIAdapter'
                    Risk         = 'CRITICAL'
                    Description  = 'Extra filters on SCSI/RAID adapters cause stop error 0x7B (INACCESSIBLE_BOOT_DEVICE)'
                    # iasf / iastorf - Intel RST RAID filter (expected on some guest SKUs)
                    SafeFilters  = [string[]]@('iasf', 'iastorf')
                    AllowVendors = [string[]]@()
                },
                [PSCustomObject]@{
                    GUID         = '{4d36e97b-e325-11ce-bfc1-08002be10318}'
                    Name         = 'SCSIController'
                    Risk         = 'CRITICAL'
                    Description  = 'Extra filters on SCSI controller adapters cause stop error 0x7B (INACCESSIBLE_BOOT_DEVICE)'
                    SafeFilters  = [string[]]@()
                    AllowVendors = [string[]]@()
                },
                [PSCustomObject]@{
                    GUID         = '{71a27cdd-812a-11d0-bec7-08002be2092f}'
                    Name         = 'Volume'
                    Risk         = 'HIGH'
                    Description  = 'Extra filters in this class can cause boot failures or prevent volume access'
                    # volsnap    - Volume Shadow Copy (required)
                    # fvevol     - BitLocker FVE
                    # rdyboost   - ReadyBoost (server: harmless)
                    # spldr      - Security processor loader
                    # volmgrx    - Volume manager extension
                    # iorate / storqosflt - Azure storage filters
                    SafeFilters  = [string[]]@('volsnap', 'fvevol', 'rdyboost', 'spldr', 'volmgrx', 'iorate', 'storqosflt')
                    AllowVendors = [string[]]@()
                },
                [PSCustomObject]@{
                    GUID         = '{4d36e972-e325-11ce-bfc1-08002be10318}'
                    Name         = 'Net'
                    Risk         = 'HIGH'
                    Description  = 'Extra filters in this class can break all network connectivity'
                    # WfpLwf                 - Windows Filtering Platform lightweight filter
                    # NdisCap                - NDIS capture (Microsoft Network Monitor)
                    # NdisImPlatformMpFilter - NDIS IM platform MP filter
                    # VmsProxyHNICFilter     - Hyper-V virtual switch proxy
                    # vms3cap                - Hyper-V S3 capture filter
                    # mslldp                 - Microsoft LLDP Protocol Driver
                    # psched                 - QoS Packet Scheduler
                    # bridge                 - Network Bridge
                    SafeFilters  = [string[]]@('wfplwf', 'ndiscap', 'ndisimplatformmpfilter', 'vmsproxyhnicfilter', 'vms3cap', 'mslldp', 'psched', 'bridge')
                    # Mellanox: Azure VMs use Mellanox ConnectX VF / MANA network adapters.
                    # NVIDIA acquired Mellanox; some binaries show either company name.
                    AllowVendors = [string[]]@('Mellanox', 'NVIDIA')
                }
            )

            $anyChanges = $false

            foreach ($classDef in $classChecks) {
                $classPath = "$classRoot\$($classDef.GUID)"
                if (-not (Test-Path $classPath)) {
                    Write-Host "  [$($classDef.Name) $($classDef.GUID)] Class key not found in offline hive - skipping." -ForegroundColor DarkGray
                    continue
                }

                $riskColor = if ($classDef.Risk -eq 'CRITICAL') { 'Red' } else { 'Yellow' }
                Write-Host "`n  [$($classDef.Name)] $($classDef.Description)" -ForegroundColor Cyan

                # Build host reference path (compare against healthy running system)
                $hostClassPath = "HKLM:\SYSTEM\$csName\Control\Class\$($classDef.GUID)"
                if (-not (Test-Path $hostClassPath)) {
                    $hostClassPath = "HKLM:\SYSTEM\ControlSet001\Control\Class\$($classDef.GUID)"
                }

                foreach ($filterType in @('UpperFilters', 'LowerFilters')) {
                    $raw = (Get-ItemProperty $classPath -ErrorAction SilentlyContinue).$filterType
                    # Normalise: remove nulls/blanks, trim whitespace
                    $currentFilters = @($raw | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })

                    if ($currentFilters.Count -eq 0) {
                        Write-Host "    $filterType : (empty)" -ForegroundColor DarkGray
                        continue
                    }

                    $hostFilters = @()
                    if (Test-Path $hostClassPath) {
                        $hostRaw = (Get-ItemProperty $hostClassPath -ErrorAction SilentlyContinue).$filterType
                        $hostFilters = @($hostRaw | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
                    }

                    Write-Host "    $filterType (offline) : $($currentFilters -join ', ')" -ForegroundColor White
                    if ($hostFilters.Count -gt 0) {
                        Write-Host "    $filterType (host ref): $($hostFilters -join ', ')" -ForegroundColor DarkGray
                    }

                    $toKeep = [System.Collections.Generic.List[string]]::new()
                    $removed = [System.Collections.Generic.List[string]]::new()

                    foreach ($filter in $currentFilters) {
                        # Resolve the binary path for all checks
                        $svcRegPath = "HKLM:\BROKENSYSTEM\$csName\Services\$filter"
                        $imgPathRaw = (Get-ItemProperty $svcRegPath -ErrorAction SilentlyContinue).ImagePath
                        $imgResolved = $null
                        $company = $null
                        if ($imgPathRaw) {
                            $imgResolved = Resolve-GuestImagePath $imgPathRaw
                            if (Test-Path $imgResolved) {
                                $company = (Get-Item $imgResolved -ErrorAction SilentlyContinue).VersionInfo.CompanyName
                            }
                        }

                        # Priority 1: binary missing or 0 bytes on offline disk -> dangling filter, will BSOD/hang on boot
                        $binaryMissing = ($null -eq $imgPathRaw) -or ($null -ne $imgResolved -and -not (Test-Path $imgResolved))
                        $binaryZero = (-not $binaryMissing -and $null -ne $imgResolved -and (Test-Path $imgResolved) -and (Get-Item -LiteralPath $imgResolved -ErrorAction SilentlyContinue).Length -eq 0)
                        if ($binaryMissing -or $binaryZero) {
                            $reason = if ($null -eq $imgPathRaw) { 'no ImagePath in registry' } elseif ($binaryZero) { "binary is 0 bytes (corrupt): $imgResolved" } else { "binary not found: $imgResolved" }
                            Write-Host "      [REMOVE] $filter - DANGLING FILTER ($reason) - will cause BSOD/hang on boot" -ForegroundColor Red
                            Write-ActionLog -Event 'DeviceFilterRemoved' -Details @{
                                Class      = $classDef.Name
                                GUID       = $classDef.GUID
                                FilterType = $filterType
                                Filter     = $filter
                                Company    = $null
                                Risk       = $classDef.Risk
                                Reason     = 'DanglingFilter'
                            }
                            $removed.Add($filter)
                            $anyChanges = $true
                            continue
                        }

                        # Priority 2: known-safe list (case-insensitive)
                        if ($classDef.SafeFilters -icontains $filter) {
                            $toKeep.Add($filter)
                            Write-Host "      [KEEP  ] $filter - known safe default" -ForegroundColor Green
                            continue
                        }

                        # Priority 3: present on healthy host reference (skipped in strict mode)
                        if (-not $KeepDefaultFilters -and $hostFilters -icontains $filter) {
                            $toKeep.Add($filter)
                            Write-Host "      [KEEP  ] $filter - present on host reference system" -ForegroundColor Green
                            continue
                        }

                        # Priority 4: binary company name matches an allowed vendor (skipped in strict mode)
                        $isMicrosoftBinary = $company -match 'Microsoft'
                        $isAllowedVendor = $classDef.AllowVendors | Where-Object { $_ -and $company -match $_ }

                        if (-not $KeepDefaultFilters -and ($isMicrosoftBinary -or $isAllowedVendor)) {
                            $toKeep.Add($filter)
                            Write-Host "      [KEEP  ] $filter - company: '$company'" -ForegroundColor Green
                        }
                        else {
                            # Remove: either strict mode (non-safe-list) or non-Microsoft third-party
                            $vendorInfo = if ($company) { "company: '$company'" } else { 'no version info' }
                            $removeReason = if ($KeepDefaultFilters -and ($isMicrosoftBinary -or $isAllowedVendor)) {
                                "not in safe-list (strict mode)"
                            }
                            else {
                                "non-Microsoft third-party filter ($vendorInfo)"
                            }
                            Write-Host "      [REMOVE] $filter - $removeReason" -ForegroundColor $riskColor
                            Write-ActionLog -Event 'DeviceFilterRemoved' -Details @{
                                Class      = $classDef.Name
                                GUID       = $classDef.GUID
                                FilterType = $filterType
                                Filter     = $filter
                                Company    = $company
                                Risk       = $classDef.Risk
                                Reason     = if ($KeepDefaultFilters) { 'StrictMode-NotInSafeList' } else { 'NonMicrosoftVendor' }
                            }
                            $removed.Add($filter)
                            $anyChanges = $true
                        }
                    }

                    if ($removed.Count -gt 0) {
                        if ($toKeep.Count -gt 0) {
                            Set-ItemProperty-Logged -Path $classPath -Name $filterType `
                                -Value ([string[]]$toKeep) -Type MultiString -Force
                        }
                        else {
                            # No entries remain - remove the value entirely rather than leaving an empty MultiString
                            Remove-ItemProperty-Logged -Path $classPath -Name $filterType -Force
                        }
                        Write-Host "      Removed: $($removed -join ', ')  |  Kept: $(if ($toKeep.Count) { $toKeep -join ', ' } else { '(none)' })" -ForegroundColor Yellow
                    }
                }
            }

            if ($anyChanges) {
                Write-Host "`nDevice class filter cleanup complete." -ForegroundColor Green
                Write-Warning ("If a legitimate product (backup agent, endpoint security, storage appliance) " +
                    "requires a removed filter, restore it from the action log and re-evaluate.")
            }
            else {
                Write-Host "`nNo unsafe device class filters found. No changes made." -ForegroundColor Green
            }
        }
    }

    function FixSessionManagerBootEntries {
        # Scans the Session Manager registry key for known boot-blocking issues:
        #   1. BootExecute  - Native NT executables run by Smss.exe before Win32 starts.
        #      Default: "autocheck autochk *". Third-party entries whose binaries are missing
        #      from the offline disk will hang the system at a black screen (pre-Win32, no recovery).
        #   2. SetupExecute - Same execution context as BootExecute. Should be empty in normal
        #      operation; non-empty entries with missing binaries are equally fatal.
        #   3. ExcludeFromKnownDlls - Forces the loader to skip the KnownDlls section for listed
        #      DLLs, loading them from the application directory instead. Legitimate uses exist
        #      (app compat shims) but this is also a common DLL hijack/preloading vector.
        #
        # Decision logic for BootExecute / SetupExecute entries:
        #   - "autocheck autochk *" is the only default BootExecute entry (always kept).
        #   - For every other entry, the first token is the native executable name.
        #     Resolve it to <offline>\Windows\System32\<name>.exe and check existence.
        #   - Missing binary  -> REMOVE (will hang boot at black screen, no error message)
        #   - Present binary  -> KEEP but flag as third-party informational

        Write-Host "Scanning Session Manager boot entries for unsafe/dangling programs..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            $currentSet = (Get-ItemProperty "HKLM:\BROKENSYSTEM\Select" -ErrorAction SilentlyContinue).Current
            $csName = if ($currentSet) { "ControlSet{0:d3}" -f $currentSet } else { "ControlSet001" }
            $smPath = "HKLM:\BROKENSYSTEM\$csName\Control\Session Manager"

            if (-not (Test-Path $smPath)) {
                Write-Host "  Session Manager key not found at $smPath - skipping." -ForegroundColor DarkGray
                return
            }

            $smProps = Get-ItemProperty $smPath -ErrorAction SilentlyContinue
            $anyChanges = $false

            # -- BootExecute ------------------------------------------------------
            $bootExec = @($smProps.BootExecute | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
            Write-Host "`n  BootExecute entries ($($bootExec.Count)):" -ForegroundColor Cyan
            if ($bootExec.Count -eq 0) {
                Write-Host "    (empty) - WARNING: missing default 'autocheck autochk *' entry" -ForegroundColor Yellow
            }

            $toKeep = [System.Collections.Generic.List[string]]::new()
            $removed = [System.Collections.Generic.List[string]]::new()
            $sys32 = Join-Path $script:WinDriveLetter 'Windows\System32'

            foreach ($entry in $bootExec) {
                # The default entry: always keep
                if ($entry -match '^autocheck\s+autochk') {
                    $toKeep.Add($entry)
                    Write-Host "    [KEEP  ] $entry - Windows default" -ForegroundColor Green
                    continue
                }

                # Extract the native executable name (first token)
                $tokens = $entry -split '\s+', 2
                $nativeName = $tokens[0]
                $nativePath = Join-Path $sys32 "$nativeName.exe"

                if (-not (Test-Path $nativePath) -or (Get-Item -LiteralPath $nativePath -ErrorAction SilentlyContinue).Length -eq 0) {
                    $reason = if (-not (Test-Path $nativePath)) { "binary not found: $nativePath" } else { "binary is 0 bytes (corrupt): $nativePath" }
                    Write-Host "    [REMOVE] $entry - $reason (will hang boot at black screen)" -ForegroundColor Red
                    Write-ActionLog -Event 'SessionManagerEntryRemoved' -Details @{
                        ValueName = 'BootExecute'
                        Entry     = $entry
                        Expected  = $nativePath
                        Reason    = 'DanglingNativeExecutable'
                    }
                    $removed.Add($entry)
                    $anyChanges = $true
                }
                else {
                    $company = (Get-Item $nativePath -ErrorAction SilentlyContinue).VersionInfo.CompanyName
                    $vendorInfo = if ($company) { "company: '$company'" } else { 'no version info' }
                    $toKeep.Add($entry)
                    Write-Host "    [KEEP  ] $entry - third-party ($vendorInfo)" -ForegroundColor Yellow
                    Write-Host "             Binary: $nativePath" -ForegroundColor DarkGray
                }
            }

            if ($removed.Count -gt 0) {
                if ($toKeep.Count -gt 0) {
                    Set-ItemProperty-Logged -Path $smPath -Name 'BootExecute' `
                        -Value ([string[]]$toKeep) -Type MultiString -Force
                }
                else {
                    # Restore the default rather than leaving empty (empty = no autochk = potential FS corruption)
                    Set-ItemProperty-Logged -Path $smPath -Name 'BootExecute' `
                        -Value ([string[]]@('autocheck autochk *')) -Type MultiString -Force
                }
                Write-Host "    Removed $($removed.Count) dangling BootExecute entry/entries." -ForegroundColor Yellow
            }

            # -- SetupExecute -----------------------------------------------------
            $setupExec = @($smProps.SetupExecute | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
            if ($setupExec.Count -gt 0) {
                Write-Host "`n  SetupExecute entries ($($setupExec.Count)):" -ForegroundColor Cyan
                $setupKeep = [System.Collections.Generic.List[string]]::new()
                $setupRemoved = [System.Collections.Generic.List[string]]::new()

                foreach ($entry in $setupExec) {
                    $tokens = $entry -split '\s+', 2
                    $nativeName = $tokens[0]
                    $nativePath = Join-Path $sys32 "$nativeName.exe"

                    if (-not (Test-Path $nativePath) -or (Get-Item -LiteralPath $nativePath -ErrorAction SilentlyContinue).Length -eq 0) {
                        $reason = if (-not (Test-Path $nativePath)) { "binary not found: $nativePath" } else { "binary is 0 bytes (corrupt): $nativePath" }
                        Write-Host "    [REMOVE] $entry - $reason (will hang boot)" -ForegroundColor Red
                        Write-ActionLog -Event 'SessionManagerEntryRemoved' -Details @{
                            ValueName = 'SetupExecute'
                            Entry     = $entry
                            Expected  = $nativePath
                            Reason    = 'DanglingNativeExecutable'
                        }
                        $setupRemoved.Add($entry)
                        $anyChanges = $true
                    }
                    else {
                        $company = (Get-Item $nativePath -ErrorAction SilentlyContinue).VersionInfo.CompanyName
                        $vendorInfo = if ($company) { "company: '$company'" } else { 'no version info' }
                        $setupKeep.Add($entry)
                        Write-Host "    [KEEP  ] $entry - third-party ($vendorInfo)" -ForegroundColor Yellow
                    }
                }

                if ($setupRemoved.Count -gt 0) {
                    if ($setupKeep.Count -gt 0) {
                        Set-ItemProperty-Logged -Path $smPath -Name 'SetupExecute' `
                            -Value ([string[]]$setupKeep) -Type MultiString -Force
                    }
                    else {
                        Remove-ItemProperty-Logged -Path $smPath -Name 'SetupExecute' -Force
                    }
                    Write-Host "    Removed $($setupRemoved.Count) dangling SetupExecute entry/entries." -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "`n  SetupExecute: (empty - normal)" -ForegroundColor DarkGray
            }

            # -- ExcludeFromKnownDlls ---------------------------------------------
            $knownDllExcl = @($smProps.ExcludeFromKnownDlls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
            if ($knownDllExcl.Count -gt 0) {
                Write-Host "`n  ExcludeFromKnownDlls ($($knownDllExcl.Count) entries):" -ForegroundColor Cyan
                foreach ($dll in $knownDllExcl) {
                    Write-Host "    [FLAG  ] $dll - DLL excluded from KnownDlls (app compat or potential DLL hijack vector)" -ForegroundColor Yellow
                }
                Write-Warning "ExcludeFromKnownDlls entries are not auto-removed (may be required by legitimate software). Review manually."
            }
            else {
                Write-Host "`n  ExcludeFromKnownDlls: (empty - normal)" -ForegroundColor DarkGray
            }

            if ($anyChanges) {
                Write-Host "`nSession Manager boot entry cleanup complete." -ForegroundColor Green
                Write-Warning "Removed entries were native executables with missing binaries that would have caused the VM to hang during boot (pre-Win32, no error screen)."
            }
            else {
                Write-Host "`nNo unsafe Session Manager entries found. No changes made." -ForegroundColor Green
            }
        }
    }

    function ScanNetAdapterBindings {
        # Read-only diagnostic: enumerates all installed network binding components
        # (protocols, services, clients) in the offline disk and flags third-party ones.
        # A component is considered third-party when its ComponentId does not start with "ms_".
        # This mirrors the live-system command:
        #   Get-NetAdapterBinding -AllBindings -IncludeHidden | Where ComponentID -notmatch '^ms_'

        Write-Host "Scanning offline disk for third-party network binding components..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            & {
                $currentSet = (Get-ItemProperty "HKLM:\BROKENSYSTEM\Select" -ErrorAction SilentlyContinue).Current
                $csName = if ($currentSet) { "ControlSet{0:d3}" -f $currentSet } else { "ControlSet001" }

                # -- Adapter inventory ----------------------------------------------------
                # Friendly-name lookup: {GUID} -> adapter name (e.g. "Ethernet")
                $adapterNames = @{}
                $netNetKey = "HKLM:\BROKENSYSTEM\$csName\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}"
                if (Test-Path $netNetKey) {
                    Get-ChildItem $netNetKey -ErrorAction SilentlyContinue | ForEach-Object {
                        $connName = (Get-ItemProperty "$($_.PSPath)\Connection" -ErrorAction SilentlyContinue).Name
                        if ($connName) { $adapterNames[$_.PSChildName.ToUpper()] = $connName }
                    }
                }

                # Hardware-description lookup: {GUID} -> DriverDesc (e.g. "Mellanox VF")
                $adapterDescs = @{}
                $netClassKey = "HKLM:\BROKENSYSTEM\$csName\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}"
                if (Test-Path $netClassKey) {
                    Get-ChildItem $netClassKey -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match '^\d{4}$' } |
                    ForEach-Object {
                        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                        if ($p.NetCfgInstanceId) {
                            $adapterDescs[$p.NetCfgInstanceId.ToUpper()] = $p.DriverDesc
                        }
                    }
                }

                # Print adapter table
                Write-Host "`nNetwork adapters found in offline disk:" -ForegroundColor Cyan
                $adapterRows = foreach ($guid in ($adapterDescs.Keys | Sort-Object)) {
                    $friendlyGuid = $guid   # already upper, with braces or without - normalise
                    $cleanGuid = $friendlyGuid.Trim('{', '}')
                    [PSCustomObject]@{
                        FriendlyName = $adapterNames[$cleanGuid]
                        Description  = $adapterDescs[$guid]
                        GUID         = "{$cleanGuid}"
                    }
                }
                if ($adapterRows) {
                    $adapterRows | Format-Table FriendlyName, Description, GUID -AutoSize | Out-String | Write-Host
                }
                else {
                    Write-Host "  (none found)" -ForegroundColor DarkGray
                }

                # -- Component enumeration -------------------------------------------------
                # Network protocol/service/client software components each live under a
                # numbered instance key inside their Class GUID.
                $componentClasses = @(
                    [PSCustomObject]@{ GUID = '{4D36E973-E325-11CE-BFC1-08002BE10318}'; Type = 'Client' }
                    [PSCustomObject]@{ GUID = '{4D36E974-E325-11CE-BFC1-08002BE10318}'; Type = 'Service' }
                    [PSCustomObject]@{ GUID = '{4D36E975-E325-11CE-BFC1-08002BE10318}'; Type = 'Protocol' }
                )

                $allComponents = [System.Collections.Generic.List[PSCustomObject]]::new()

                foreach ($classInfo in $componentClasses) {
                    $classKey = "HKLM:\BROKENSYSTEM\$csName\Control\Class\$($classInfo.GUID)"
                    if (-not (Test-Path $classKey)) { continue }

                    Get-ChildItem $classKey -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match '^\d{4}$' } |
                    ForEach-Object {
                        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                        # ComponentId casing varies across Windows versions
                        $componentId = $props.ComponentId
                        if (-not $componentId) { $componentId = $props.ComponentID }
                        if (-not $componentId) { return }

                        # Service name: prefer explicit Ndi\Service, fall back to stripping 'ms_' prefix
                        $ndiProps = Get-ItemProperty "$($_.PSPath)\Ndi" -ErrorAction SilentlyContinue
                        $serviceName = if ($ndiProps -and $ndiProps.Service) { $ndiProps.Service }
                        else { $componentId -replace '^ms_', '' }

                        # Bound-adapter list from Services\<svc>\Linkage\Bind
                        $boundAdapters = @()
                        $linkagePath = "HKLM:\BROKENSYSTEM\$csName\Services\$serviceName\Linkage"
                        if (Test-Path $linkagePath) {
                            $linkage = Get-ItemProperty $linkagePath -ErrorAction SilentlyContinue
                            $disabledList = @($linkage.Disabled | Where-Object { $_ })
                            foreach ($b in @($linkage.Bind | Where-Object { $_ })) {
                                # Bind entries look like: \Device\{GUID} or \Device\{GUID}_N
                                if ($b -match '\{([0-9A-Fa-f\-]+)\}') {
                                    $g = $Matches[1].ToUpper()
                                    $name = $adapterNames[$g]
                                    $desc = $adapterDescs["{$g}"]
                                    $label = if ($name) { $name } elseif ($desc) { $desc } else { "{$g}" }
                                    $boundAdapters += if ($disabledList -icontains $b) { "$label [disabled]" } else { $label }
                                }
                            }
                        }

                        # Binary presence on the offline disk
                        $imgPathRaw = (Get-ItemProperty "HKLM:\BROKENSYSTEM\$csName\Services\$serviceName" -ErrorAction SilentlyContinue).ImagePath
                        $binaryFound = $null
                        if ($imgPathRaw) {
                            $imgResolved = Resolve-GuestImagePath $imgPathRaw
                            $binaryFound = Test-Path $imgResolved
                        }

                        $allComponents.Add([PSCustomObject]@{
                                ComponentId   = $componentId
                                Type          = $classInfo.Type
                                DisplayName   = $props.DriverDesc
                                ServiceName   = $serviceName
                                IsThirdParty  = ($componentId -notmatch '^ms_')
                                BoundAdapters = ($boundAdapters -join '; ')
                                BinaryFound   = $binaryFound
                            })
                    }
                }

                # Deduplicate in case the same ComponentId appears in multiple class GUIDs
                $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                $components = $allComponents | Where-Object { $seen.Add($_.ComponentId) }

                $firstParty = @($components | Where-Object { -not $_.IsThirdParty })
                $thirdParty = @($components | Where-Object { $_.IsThirdParty } | Sort-Object ComponentId)

                # -- Report ----------------------------------------------------------------
                Write-Host "First-party binding components (ms_*): $($firstParty.Count)" -ForegroundColor DarkGray

                if ($thirdParty.Count -eq 0) {
                    Write-Host "`nNo third-party network binding components found." -ForegroundColor Green
                }
                else {
                    Write-Host "`nThird-party network binding components: $($thirdParty.Count)" -ForegroundColor Yellow
                    Write-Host "  ComponentId does not start with 'ms_' - these extend the network stack at boot." -ForegroundColor DarkYellow
                    Write-Host ""

                    foreach ($c in $thirdParty) {
                        if ($c.BinaryFound -eq $false) {
                            $presenceTag = 'BINARY MISSING'
                            $color = 'Red'
                        }
                        elseif ($c.BinaryFound -eq $true) {
                            $presenceTag = 'binary present'
                            $color = 'Yellow'
                        }
                        else {
                            $presenceTag = 'no ImagePath registered'
                            $color = 'DarkYellow'
                        }

                        Write-Host "  [$($c.Type.PadRight(8))] $($c.ComponentId.PadRight(32)) $($c.DisplayName)" -ForegroundColor $color
                        Write-Host "             Service : $($c.ServiceName)  |  $presenceTag" -ForegroundColor $color
                        if ($c.BoundAdapters) {
                            Write-Host "             Bound to: $($c.BoundAdapters)" -ForegroundColor DarkYellow
                        }
                        else {
                            Write-Host "             Bound to: (linkage not cached offline - resolved at boot)" -ForegroundColor DarkGray
                        }
                        Write-Host ""
                    }

                    Write-Warning ("Third-party network components extend the network stack. " +
                        "If the VM has no network connectivity after boot, these components " +
                        "may be interfering. Use -FixDeviceFilters to scan NDIS UpperFilters/LowerFilters.")
                }

                Write-ActionLog -Event 'ScanNetAdapterBindings' -Details @{
                    AdapterCount    = $adapterRows.Count
                    FirstPartyCount = $firstParty.Count
                    ThirdPartyCount = $thirdParty.Count
                    ThirdPartyIds   = ($thirdParty | ForEach-Object ComponentId) -join ', '
                }
            }
        }
    }

    function RemoveOrphanedNetBindings {
        # Removes third-party network binding components whose driver binary is missing on the offline disk.
        # A dangling binding component causes ndis.sys initialisation to fail on boot, leading to complete
        # loss of network connectivity even when the NIC driver itself is healthy.
        #
        # This is the destructive counterpart to -ScanNetBindings. Run that first to preview.
        # Only components with an explicit ImagePath that resolves to a non-existent file are acted on;
        # components with no ImagePath at all are left untouched (they may be imageless by design).
        #
        # For each orphaned component:
        #   1. Removes the class instance key (Control\Class\{type-GUID}\NNNN)
        #   2. Disables the service (Services\<svc> Start = 4) to prevent any load attempt
        #   3. Clears Services\<svc>\Linkage\{Bind, Export, Route} to detach from all adapters

        Write-Host "Scanning for orphaned third-party network binding components (missing binary)..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            & {
                $currentSet = (Get-ItemProperty "HKLM:\BROKENSYSTEM\Select" -ErrorAction SilentlyContinue).Current
                $csName = if ($currentSet) { "ControlSet{0:d3}" -f $currentSet } else { "ControlSet001" }

                $componentClasses = @(
                    [PSCustomObject]@{ GUID = '{4D36E973-E325-11CE-BFC1-08002BE10318}'; Type = 'Client' }
                    [PSCustomObject]@{ GUID = '{4D36E974-E325-11CE-BFC1-08002BE10318}'; Type = 'Service' }
                    [PSCustomObject]@{ GUID = '{4D36E975-E325-11CE-BFC1-08002BE10318}'; Type = 'Protocol' }
                )

                $orphans = [System.Collections.Generic.List[PSCustomObject]]::new()
                $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

                foreach ($classInfo in $componentClasses) {
                    $classKey = "HKLM:\BROKENSYSTEM\$csName\Control\Class\$($classInfo.GUID)"
                    if (-not (Test-Path $classKey)) { continue }

                    Get-ChildItem $classKey -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match '^\d{4}$' } |
                    ForEach-Object {
                        $instPath = $_.PSPath
                        $props = Get-ItemProperty $instPath -ErrorAction SilentlyContinue
                        $componentId = if ($props.ComponentId) { $props.ComponentId } else { $props.ComponentID }
                        if (-not $componentId) { return }
                        # Deduplicate across class GUIDs
                        if (-not $seen.Add($componentId)) { return }
                        # Never touch first-party ms_ components
                        if ($componentId -match '^ms_') { return }

                        $ndiProps = Get-ItemProperty "$instPath\Ndi" -ErrorAction SilentlyContinue
                        $serviceName = if ($ndiProps -and $ndiProps.Service) { $ndiProps.Service }
                        else { $componentId -replace '^ms_', '' }

                        $imgPathRaw = (Get-ItemProperty "HKLM:\BROKENSYSTEM\$csName\Services\$serviceName" -ErrorAction SilentlyContinue).ImagePath
                        # No ImagePath -> skip; component may be imageless by design
                        if ($null -eq $imgPathRaw) { return }

                        $imgResolved = Resolve-GuestImagePath $imgPathRaw
                        # Binary present -> nothing to do
                        if (Test-Path $imgResolved) { return }

                        $orphans.Add([PSCustomObject]@{
                                ComponentId   = $componentId
                                Type          = $classInfo.Type
                                DisplayName   = $props.DriverDesc
                                ServiceName   = $serviceName
                                ClassKeyPath  = $instPath
                                MissingBinary = $imgResolved
                            })
                    }
                }

                if ($orphans.Count -eq 0) {
                    Write-Host "`nNo orphaned network binding components found. No changes made." -ForegroundColor Green
                    return
                }

                Write-Host "`nFound $($orphans.Count) orphaned network binding component(s) with missing binaries:" -ForegroundColor Red
                Write-Host ""

                foreach ($c in $orphans) {
                    Write-Host "  [$($c.Type.PadRight(8))] $($c.ComponentId)  --  $($c.DisplayName)" -ForegroundColor Red
                    Write-Host "             Service : $($c.ServiceName)" -ForegroundColor DarkRed
                    Write-Host "             Missing : $($c.MissingBinary)" -ForegroundColor DarkRed
                    Write-Host ""

                    # Step 1: Remove class instance key - de-registers the component from Windows
                    Write-Host "    [1/3] Removing class instance key..." -ForegroundColor Yellow
                    Remove-Item-Logged -Path $c.ClassKeyPath -Recurse -Force

                    # Step 2: Disable the service to prevent any load attempt at boot
                    $svcPath = "HKLM:\BROKENSYSTEM\$csName\Services\$($c.ServiceName)"
                    if (Test-Path $svcPath) {
                        Write-Host "    [2/3] Disabling service '$($c.ServiceName)' (Start -> 4)..." -ForegroundColor Yellow
                        Set-ItemProperty-Logged -Path $svcPath -Name Start -Value 4 -Type DWord -Force
                    }
                    else {
                        Write-Host "    [2/3] Service key '$($c.ServiceName)' not found - skipping." -ForegroundColor DarkGray
                    }

                    # Step 3: Clear Linkage Bind/Export/Route to detach from all adapters
                    $linkPath = "HKLM:\BROKENSYSTEM\$csName\Services\$($c.ServiceName)\Linkage"
                    if (Test-Path $linkPath) {
                        Write-Host "    [3/3] Clearing Linkage bind entries..." -ForegroundColor Yellow
                        foreach ($val in @('Bind', 'Export', 'Route')) {
                            if ($null -ne (Get-ItemProperty $linkPath -ErrorAction SilentlyContinue).$val) {
                                Remove-ItemProperty-Logged -Path $linkPath -Name $val -Force
                            }
                        }
                    }
                    else {
                        Write-Host "    [3/3] No Linkage key found - nothing to clear." -ForegroundColor DarkGray
                    }

                    Write-ActionLog -Event 'OrphanedNetBindingRemoved' -Details @{
                        ComponentId   = $c.ComponentId
                        Type          = $c.Type
                        DisplayName   = $c.DisplayName
                        ServiceName   = $c.ServiceName
                        MissingBinary = $c.MissingBinary
                    }

                    Write-Host "    Done: $($c.ComponentId) removed." -ForegroundColor Green
                    Write-Host ""
                }

                Write-Host "Orphaned network binding cleanup complete. $($orphans.Count) component(s) removed." -ForegroundColor Green
                Write-Warning ("A full network-stack reset may still be needed. " +
                    "Consider also running -ResetNetworkStack to clear TCP/IP and Winsock state.")
            }
        }
    }

    function CopyACPISettings {
        # Copies legacy Hyper-V ACPI Enum entries to the newer ACPI device IDs.
        # Some Windows versions do not include the newer MSFT* keys, preventing
        # Hyper-V synthetic devices from being detected. This copies from the
        # legacy entries when they exist:
        #   VMBus                  -> MSFT1000
        #   Hyper_V_Gen_Counter_V1 -> MSFT1002

        Write-Host "Copying Hyper-V ACPI device entries to newer device IDs..." -ForegroundColor Cyan

        Invoke-WithHive 'SYSTEM' {
            $sysRoot = Get-SystemRootPath   # e.g. HKLM:\BROKENSYSTEM\ControlSet001
            # Convert PowerShell path to reg.exe syntax (no colon after HKLM)
            $regRoot = $sysRoot -replace '^HKLM:', 'HKLM'

            $copies = @(
                @{ SrcPs = "$sysRoot\Enum\ACPI\VMBus"; DstPs = "$sysRoot\Enum\ACPI\MSFT1000"; SrcReg = "$regRoot\Enum\ACPI\VMBus"; DstReg = "$regRoot\Enum\ACPI\MSFT1000"; Label = 'VMBus -> MSFT1000' }
                @{ SrcPs = "$sysRoot\Enum\ACPI\Hyper_V_Gen_Counter_V1"; DstPs = "$sysRoot\Enum\ACPI\MSFT1002"; SrcReg = "$regRoot\Enum\ACPI\Hyper_V_Gen_Counter_V1"; DstReg = "$regRoot\Enum\ACPI\MSFT1002"; Label = 'Hyper_V_Gen_Counter_V1 -> MSFT1002' }
            )

            $copied = 0
            foreach ($c in $copies) {
                if (-not (Test-Path $c.SrcPs)) {
                    Write-Warning "  Source key not found: $($c.SrcReg) - skipping $($c.Label)"
                    continue
                }
                # Run as SYSTEM to bypass ACL restrictions on the mounted offline hive
                ExecuteAsSystem "reg.exe copy `"$($c.SrcReg)`" `"$($c.DstReg)`" /s /f"
                # Verify the destination key was created
                if (Test-Path $c.DstPs) {
                    Write-Host "  [OK] Copied $($c.Label)" -ForegroundColor Green
                    $copied++
                }
                else {
                    Write-Warning "  reg copy $($c.Label) may have failed - destination key not found after copy"
                }
            }

            if ($copied -gt 0) {
                Write-Host "ACPI settings copied ($copied of $($copies.Count) pair(s))." -ForegroundColor Green
            }
            else {
                Write-Warning "No ACPI entries were copied - source keys may not exist on this disk."
            }

            Write-ActionLog -Event 'CopyACPISettings' -Details @{ RegRoot = $regRoot; Copied = $copied }
        }
    }

    function RunSystemCheck {
        # -------------------------------------------------------------------------
        # Read-only offline health scan. Checks BCD, registry, services, device
        # filters, networking, RDP, Azure Agent, security settings, crash
        # artifacts and Gen2 UEFI/Trusted Launch readiness (Secure Boot, vTPM,
        # VBS/HVCI, BitLocker, EarlyLaunch). No changes are made. At the end a
        # prioritised summary is printed with the exact -Parameter to run for
        # each finding.
        # -------------------------------------------------------------------------

        # Reuse guest computer name resolved earlier (stored in $script:GuestComputerName)
        $guestComputerName = $script:GuestComputerName
        $guestLabel = if ($guestComputerName) { "  Guest: $guestComputerName" } else { '' }

        Write-Host "`n===================================================================" -ForegroundColor Cyan
        Write-Host "  Offline System Health Check" -ForegroundColor Cyan
        Write-Host "  Disk $script:DiskNumber  |  Windows: $script:WinDriveLetter  |  Boot: $script:BootDriveLetter  |  Gen$script:VMGen$guestLabel" -ForegroundColor Cyan
        Write-Host "===================================================================`n" -ForegroundColor Cyan

        $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
        $scriptFile = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { 'Repair-AzVMDisk.ps1' }

        # Inline helper: emit one finding to the console and add it to $findings.
        # Called as: & $emit 'Category' 'CRIT|WARN|INFO|OK' 'Message' '-FixParam'
        $emit = {
            param([string]$Cat, [string]$Sev, [string]$Desc, [string]$Fix = '')
            $findings.Add([PSCustomObject]@{ Category = $Cat; Severity = $Sev; Description = $Desc; Fix = $Fix })
            $color = switch ($Sev) { 'CRIT' { 'Red' } 'WARN' { 'Yellow' } 'INFO' { 'Cyan' } default { 'Green' } }
            $prefix = switch ($Sev) { 'CRIT' { '[CRIT]' } 'WARN' { '[WARN]' } 'INFO' { '[INFO]' } default { '[ OK ]' } }
            Write-Host "  $prefix [$Cat] $Desc" -ForegroundColor $color
            if ($Fix) { Write-Host "         Suggestion: $Fix" -ForegroundColor DarkCyan }
        }

        # -- SysCheck severity configuration --------------------------------------
        # Controls how each finding is surfaced when it fires.
        # Values: 0 = INFO  |  1 = WARN  |  2 = CRIT
        # Change a value here to promote or demote any test without touching its logic.

        # Disk & Filesystem
        $sevDiskHealth = 2   # Disk HealthStatus is not Healthy
        $sevDiskRawFs = 2   # Partition has RAW filesystem (unreadable)
        $sevDiskFsHealth = 1   # Partition filesystem is unhealthy

        # Crash & Boot artefacts
        $sevCrashMinidumps = 1   # Minidump (.dmp) files found
        $sevBootNtbtlog = 0   # ntbtlog.txt present (check for DIDNOTLOAD)
        $sevUpdatePendingXml = 1   # pending.xml found (update boot loop risk)
        $sevUpdateTxRLogs = 1   # TxR transaction log files found
        $sevUpdateSmiLogs = 1   # SMI Store transaction log files found
        $sevSetupMode = 0   # SetupType active (Setup CmdLine will run at boot)

        # BCD / Boot Configuration
        $sevBcdMissing = 2   # BCD store not found
        $sevBcdNoBootLoader = 2   # No Windows Boot Loader entry in BCD
        $sevBcdSafeMode = 1   # Safe Mode flag active in BCD
        $sevBcdBootStatusPolicy = 0   # bootstatuspolicy IgnoreAllFailures set
        $sevBcdRecoveryDisabled = 0   # recoveryenabled Off
        $sevBcdTestSigning = 1   # Test signing ON
        $sevBcdUnknownDevice = 2   # BCD contains unknown device/path entries
        $sevBcdImcHive = 2   # BCD has imcdevice/imchivename entries (BSOD 0x67 CONFIG_INITIALIZATION_FAILED)
        $sevBootPartitionNotActive = 2   # Gen1 (MBR) boot partition not flagged as Active (BIOS cannot find boot sector)
        $sevBootPartitionMissing = 2   # Separate boot partition (System Reserved / EFI SP) not found on disk

        # Registry
        $sevControlSetMismatch = 1   # Current ControlSet != Default
        $sevRegBackEmpty = 1   # RegBack\SYSTEM is 0 bytes
        $sevRegBackMissing = 0   # RegBack\SYSTEM not found

        # Critical Services
        $sevCriticalSvcDisabled = 2   # A critical boot/system driver is disabled

        # RDP
        $sevRdpDenied = 2   # fDenyTSConnections=1 (RDP explicitly disabled)
        $sevRdpDenyUnknown = 1   # fDenyTSConnections key missing
        $sevRdpSvcDisabledCrit = 2   # TermService/SessionEnv disabled
        $sevRdpSvcDisabledWarn = 1   # UmRdpService disabled
        $sevRdpNonDefaultPort = 1   # RDP port is not 3389
        $sevRdpSecurityLayerWeak = 1   # SecurityLayer=0 (RDP native, no SSL)
        $sevRdpNLADisabled = 1   # NLA/UserAuthentication disabled
        $sevRdpSecProtoNeg = 1   # fAllowSecProtocolNegotiation=0
        $sevRdpMinEncLevel = 1   # MinEncryptionLevel below 2
        $sevRdpTcpKeyMissing = 1   # RDP-Tcp WinStation key not found
        $sevRdpMaxInstanceZero = 2   # MaxInstanceCount=0 (RDP refuses all connections)
        $sevRdpCryptoSvcDisabled = 1   # KeyIso/CryptSvc/CertPropSvc disabled
        $sevRdpTlsDisabled = 1   # TLS 1.2 explicitly disabled in SCHANNEL
        $sevRdpNtlmRestrict = 1   # NTLM restrictions may block RDP auth
        $sevRdpLmCompat = 1   # LmCompatibilityLevel > 5
        $sevCredSspOracle = 1   # CredSSP AllowEncryptionOracle != 2
        $sevGpRdpBlocked = 2   # Group Policy is blocking RDP
        $sevGpNlaDisabled = 0   # Group Policy has disabled NLA
        $sevSslCipherPolicy = 1   # SSL cipher suite policy configured
        $sevRdpKeySystemAcl = 1   # RDP private key: SYSTEM missing FullControl
        $sevRdpKeyNetSvcAcl = 1   # RDP private key: NETWORK SERVICE missing Read
        $sevRdpKeySessionEnvAcl = 0   # RDP private key: SessionEnv missing FullControl
        $sevRdpKeyFileMissing = 1   # RDP private key file not found in MachineKeys
        $sevRdpKeyZeroLength = 1   # Zero-length files in MachineKeys
        $sevMachineKeysMissing = 1   # MachineKeys folder missing

        # Security
        $sevCredentialGuard = 1   # Credential Guard is enabled
        $sevLsaPPL = 0   # LSA RunAsPPL=1 active
        $sevAppLockerConfigured = 0  # AppLocker EnforcementMode != 0 only (no service, no rules)
        $sevAppLockerEnforcing = 1   # AppLocker EnforcementMode != 0 + AppIDSvc auto-start
        $sevAppLockerActive   = 2   # AppLocker EnforcementMode != 0 + AppIDSvc auto-start + rules exist
        $sevAppIdSvc = 0   # AppIDSvc (Application Identity) is running

        # Azure Guest Agent
        $sevAzureAgentDisabled = 2   # Agent service is disabled
        $sevAzureAgentWrongStart = 1   # Agent service has unexpected start type
        $sevAzureAgentMissing = 1   # Agent not found in registry or on disk

        # Networking
        $sevBfeDisabled = 1   # BFE (Base Filtering Engine) disabled
        $sevTcpipDisabled = 2   # Tcpip service disabled
        $sevNetSvcDisabled = 1   # Secondary networking services disabled (DNS/DHCP/NLA/SMB)
        $sevNsiDisabled = 2   # nsi (Network Store Interface) disabled - total networking loss
        $sevStaticIpNoAzureDhcp = 2   # EnableDHCP=0 on NIC - VM gets no Azure IP assignment
        $sevNetProviderOrphaned = 2   # NetworkProvider\Order lists a provider whose DLL is missing - logon hangs forever
        $sevSanPolicy = 0   # SAN policy is not OnlineAll
        $sevOrphanedNdis = 2   # Orphaned NDIS bindings with missing binary

        # Drivers
        $sevMissingDriverBinaries = 2  # Boot/System driver registered but binary missing

        # Device class filters
        $sevDeviceFiltersCrit = 2   # Non-standard entries in DiskDrive/SCSI class filters
        $sevDeviceFiltersWarn = 1   # Non-standard entries in Volume/Net class filters

        # Windows Update
        $sevUpdateWuDisabled = 0   # WU services (wuauserv/UsoSvc/WaaSMedicSvc) disabled
        $sevCbsPendingWarn = 1   # CBS RebootPending/PackagesPending/exclusive SessionsPending
        $sevCbsPendingInfo = 0   # CBS SessionsPending without exclusive lock (stale, usually benign)

        # ACPI
        $sevACPISettings = 0   # Hyper-V ACPI entries (MSFT1000/MSFT1002) missing

        # Disk space
        $sevDiskSpaceLow = 1   # Volume has less than 10% free space
        $sevDiskSpaceCritical = 2   # Volume has less than 500 MB free space

        # Driver Verifier
        $sevDriverVerifier = 2   # Driver Verifier is enabled (will BSOD on any violation)

        # Winlogon
        $sevWinlogonShell = 2   # Shell is not explorer.exe (black screen on logon)
        $sevWinlogonUserinit = 2   # Userinit is not the default (logon failure)

        # User Profiles
        $sevProfileBak = 1   # ProfileList has .bak duplicate (profile load failure)
        $sevProfileTempFlag = 1   # Profile has temporary flag set

        # Firewall
        $sevFirewallEnabled = 0   # Firewall is enabled (normal; INFO only)
        $sevFirewallRdpBlocked = 1   # No inbound RDP rule enabled in firewall

        # Image File Execution Options (IFEO)
        $sevIFEODebugger = 2   # IFEO Debugger set on critical service binary (prevents service from starting)
        $sevIFEODebuggerNonCritical = 1   # IFEO Debugger set on non-critical executable
        $sevIFEOGlobalFlag = 2   # IFEO GlobalFlag on critical exe (page heap/app verifier can crash or OOM services)
        $sevIFEOGlobalFlagNonCritical = 1   # IFEO GlobalFlag on non-critical executable

        # Startup Programs
        $sevStartupPrograms = 0   # Third-party auto-start programs found

        # Serial Console / EMS
        $sevEmsDisabled = 0   # EMS/Serial Console not configured

        # Static DNS
        $sevStaticDns = 1   # Static DNS servers configured (may break after migration)

        # Gen2 / UEFI / Trusted Launch (only evaluated when $script:VMGen -eq 2)
        $sevBootmgfwMissing = 2   # bootmgfw.efi missing from EFI System Partition
        $sevBootx64Missing = 1   # EFI\Boot\bootx64.efi fallback loader missing
        $sevBcdWinloadMismatch = 2   # BCD points to winload.exe on a Gen2 (UEFI) disk
        $sevBcdNoIntegrityChecks = 2   # nointegritychecks ON - fatal with Secure Boot
        $sevSecureBootConflict = 2   # testsigning/nointegritychecks ON while guest had Secure Boot
        $sevSecureBootState = 0   # Secure Boot was previously enabled (informational)
        $sevSecureBootCertNotUpdated = 1   # Secure Boot enabled but 2023 certs not applied (expires Jun-Oct 2026)
        $sevSecureBootCertError = 1   # Error during Secure Boot certificate update process
        $sevDeviceGuardVbs = 0   # VBS is enabled (informational)
        $sevDeviceGuardPlatReq = 1   # RequirePlatformSecurityFeatures=3 (requires DMA protection)
        $sevHvciEnabled = 0   # HVCI is enabled (informational)
        $sevEarlyLaunchPolicy = 1   # EarlyLaunch DriverLoadPolicy is restrictive
        $sevTpmDriverDisabled = 1   # TPM driver is disabled (vTPM-dependent features will fail)
        $sevBitLockerActive = 1   # BitLocker FVE active - recovery key needed after disk move

        # Session Manager / BootExecute
        $sevBootExecDangling = 2   # BootExecute entry references missing native binary (boot hang)
        $sevBootExecThirdParty = 1   # BootExecute has non-default third-party entries (binary exists)
        $sevSetupExecDangling = 2   # SetupExecute entry references missing native binary
        $sevSetupExecPresent = 1   # SetupExecute is non-empty (unusual outside servicing)
        $sevKnownDllExclude = 1   # ExcludeFromKnownDlls populated (DLL hijack vector or app compat)

        # Critical boot files (on-disk binary presence checks)
        $sevCriticalBootFileMissing = 2   # Core boot binary (winload/bootmgr/hal/ntdll/kernel32) missing or 0-byte
        $sevSyntheticDriverBroken = 2   # Azure synthetic driver (vmbus/storvsc/netvsc) wrong Start value or binary missing
        $sevSessionInitMissing = 2   # Session init executable (smss/wininit/services/lsass/winlogon/logonui) missing or 0-byte
        $sevBinarySignatureBad = 2   # Critical boot/session binary is not Microsoft-signed (possible tampering)

        # Hyper-V integration services
        $sevIntegrationSvcMissing = 1  # Hyper-V integration service key missing from registry
        $sevIntegrationSvcDisabled = 1 # Hyper-V integration service disabled (Start=4)
        $sevIntegrationSvcBinMissing = 1 # Hyper-V integration service binary missing or 0-byte

        # Proxy
        $sevProxyConfigured = 1   # Machine-level proxy/PAC is configured (may block Azure connectivity)

        # Domain trust
        $sevNetlogonDisabled = 1   # Domain-joined VM has Netlogon disabled

        # Inline converter: integer level -> severity string used by $emit
        $toSev = { param([int]$L) switch ($L) { 0 { 'INFO' } 1 { 'WARN' } 2 { 'CRIT' } default { 'INFO' } } }

        # -- 1. Disk & Filesystem -------------------------------------------------
        Write-Host "--- Disk & Filesystem" -ForegroundColor DarkGray
        try {
            $disk = Get-Disk -Number $script:DiskNumber -ErrorAction SilentlyContinue
            if ($disk) {
                if ($disk.HealthStatus -ne 'Healthy') {
                    & $emit 'Disk' (& $toSev $sevDiskHealth) "Disk health: $($disk.HealthStatus)" "-CheckDiskHealth"
                }
                else {
                    & $emit 'Disk' 'OK' "Disk health: Healthy"
                }
            }
            foreach ($p in (Get-Partition -DiskNumber $script:DiskNumber -ErrorAction SilentlyContinue)) {
                $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue
                if ($vol) {
                    $fs = $vol.FileSystemType
                    $pLetter = if ($p.DriveLetter -and $p.DriveLetter -ne "`0") { "$($p.DriveLetter):" } else { $script:WinDriveLetter.TrimEnd('\') }
                    if ([string]::IsNullOrEmpty($fs) -or $fs -eq 'Unknown') {
                        & $emit 'Disk' (& $toSev $sevDiskRawFs) "Partition $($p.PartitionNumber) ($pLetter): RAW filesystem - data may be inaccessible" "-FixNTFS -DriveLetter $pLetter -LeaveDiskOnline"
                    }
                    elseif ($vol.HealthStatus -ne 'Healthy') {
                        & $emit 'Disk' (& $toSev $sevDiskFsHealth) "Partition $($p.PartitionNumber) ($pLetter) ($fs): health=$($vol.HealthStatus)" "-FixNTFS -DriveLetter $pLetter -LeaveDiskOnline"
                    }
                }
            }
        }
        catch { Write-Warning "Disk check failed: $_" }

        # -- 1b. Disk Space (Windows partition only) ------------------------------
        # Only check the Windows partition; small boot/EFI/recovery partitions are expected to be nearly full.
        try {
            $winLetter = $script:WinDriveLetter.TrimEnd('\')
            $winPart = Get-Partition -DiskNumber $script:DiskNumber -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter -and "$($_.DriveLetter):" -eq $winLetter }
            if ($winPart) {
                $vol = Get-Volume -Partition $winPart -ErrorAction SilentlyContinue
                if ($vol -and $vol.Size -gt 0) {
                    $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 2)
                    $totalGB = [math]::Round($vol.Size / 1GB, 2)
                    $freePct = [math]::Round(($vol.SizeRemaining / $vol.Size) * 100, 1)
                    $freeMB = [math]::Round($vol.SizeRemaining / 1MB, 0)
                    $label = "Windows partition ($winLetter): $freeGB GB free of $totalGB GB ($freePct%)"
                    if ($freeMB -lt 500) {
                        & $emit 'DiskSpace' (& $toSev $sevDiskSpaceCritical) "$label - CRITICALLY LOW, VM may fail to boot (no space for pagefile/logs)"
                    }
                    elseif ($freePct -lt 10) {
                        & $emit 'DiskSpace' (& $toSev $sevDiskSpaceLow) "$label - low free space may cause issues"
                    }
                    else {
                        & $emit 'DiskSpace' 'OK' $label
                    }
                }
            }
        }
        catch { Write-Warning "Disk space check failed: $_" }

        # -- 2. Crash & Boot Artefacts --------------------------------------------
        Write-Host "--- Crash & Boot Artefacts" -ForegroundColor DarkGray
        $minidumpDir = Join-Path $script:WinDriveLetter 'Windows\Minidump'
        if (Test-Path $minidumpDir) {
            $dumps = @(Get-ChildItem $minidumpDir -Filter '*.dmp' -ErrorAction SilentlyContinue)
            if ($dumps.Count -gt 0) {
                $newest = $dumps | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                & $emit 'Crash' (& $toSev $sevCrashMinidumps) "$($dumps.Count) minidump(s) found - latest: $($newest.Name) [$($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))]" "-CollectEventLogs"
            }
            else { & $emit 'Crash' 'OK' 'No minidump files' }
        }
        else { & $emit 'Crash' 'OK' 'No Minidump folder' }

        if (Test-Path (Join-Path $script:WinDriveLetter 'Windows\ntbtlog.txt')) {
            & $emit 'Boot' (& $toSev $sevBootNtbtlog) 'ntbtlog.txt present - check for DIDNOTLOAD entries' "-CollectEventLogs"
        }

        if (Test-Path (Join-Path $script:WinDriveLetter 'Windows\WinSxS\pending.xml')) {
            & $emit 'WindowsUpdate' (& $toSev $sevUpdatePendingXml) 'Pending Windows Update transaction (pending.xml) - may cause boot loop on Configuring Updates screen' "-FixPendingUpdates"
        }

        # TxR transaction log files (leftover .blf/.regtrans-ms cause stuck update processing)
        $txrFolder = Join-Path $script:WinDriveLetter 'Windows\System32\config\TxR'
        if (Test-Path $txrFolder) {
            $txrFiles = @(Get-ChildItem $txrFolder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.blf', '.regtrans-ms') })
            if ($txrFiles.Count -gt 0) {
                & $emit 'WindowsUpdate' (& $toSev $sevUpdateTxRLogs) "$($txrFiles.Count) TxR transaction log file(s) found in config\TxR (.blf/.regtrans-ms) - may cause update processing to hang at boot" "-FixPendingUpdates"
            }
        }

        # SMI Store transaction files
        $smiFolder = Join-Path $script:WinDriveLetter 'Windows\System32\SMI\Store\Machine'
        if (Test-Path $smiFolder) {
            $smiFiles = @(Get-ChildItem $smiFolder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.blf', '.regtrans-ms') })
            if ($smiFiles.Count -gt 0) {
                & $emit 'WindowsUpdate' (& $toSev $sevUpdateSmiLogs) "$($smiFiles.Count) SMI Store transaction log file(s) found (.blf/.regtrans-ms) - may cause update boot loop" "-FixPendingUpdates"
            }
        }

        # -- 3. BCD ---------------------------------------------------------------
        Write-Host "--- BCD / Boot Configuration" -ForegroundColor DarkGray

        # Check for missing boot partition (System Reserved on Gen1, EFI System Partition on Gen2)
        $scPartitions = Get-Partition -DiskNumber $script:DiskNumber -ErrorAction SilentlyContinue
        $bootPartMissing = $false
        if ($script:VMGen -eq 2) {
            $espExists = $scPartitions | Where-Object { $_.Type -eq 'System' }
            if (-not $espExists) {
                & $emit 'BCD' (& $toSev $sevBootPartitionMissing) "EFI System Partition is MISSING - Gen2 (UEFI) VM cannot boot without it" "-RecreateBootPartition"
                $bootPartMissing = $true
            }
            else {
                & $emit 'BCD' 'OK' "EFI System Partition present (Partition $($espExists.PartitionNumber))"
            }
        }
        else {
            # Gen1: check if a separate boot partition exists (Active partition != Windows partition)
            $winTrimmed = $script:WinDriveLetter.TrimEnd('\')
            $separateBootPart = $scPartitions | Where-Object {
                $_.IsActive -and ($_.AccessPaths | Where-Object { $_ -and $_.TrimEnd('\') -ne $winTrimmed })
            }
            if (-not $separateBootPart) {
                # Check if Windows partition is Active (single-partition layout)
                $winIsActive = $scPartitions | Where-Object {
                    $_.AccessPaths | Where-Object { $_ -and $_.TrimEnd('\') -eq $winTrimmed }
                } | Where-Object { $_.IsActive }
                if ($winIsActive) {
                    & $emit 'BCD' 'OK' "No separate System Reserved partition - Windows partition is Active (single-partition layout)"
                }
                else {
                    & $emit 'BCD' (& $toSev $sevBootPartitionMissing) "No bootable partition found - System Reserved partition is missing and Windows partition is not Active" "-RecreateBootPartition"
                    $bootPartMissing = $true
                }
            }
            else {
                & $emit 'BCD' 'OK' "System Reserved partition present (Partition $($separateBootPart.PartitionNumber), Active)"
            }
        }

        # When the boot partition itself is missing, all BCD/boot-file findings are symptoms
        # of that root cause - redirect fix suggestions to -RecreateBootPartition
        $bcdFix = if ($bootPartMissing) { '-RecreateBootPartition' } else { '-FixBoot' }

        $bcdPath = Get-BcdStorePath -Generation $script:VMGen -BootDrive $script:BootDriveLetter.TrimEnd('\')
        if (-not (Test-Path $bcdPath)) {
            & $emit 'BCD' (& $toSev $sevBcdMissing) "BCD store not found at $bcdPath - VM will fail to boot" $bcdFix
        }
        elseif ((Get-Item -LiteralPath $bcdPath -ErrorAction SilentlyContinue).Length -eq 0) {
            & $emit 'BCD' (& $toSev $sevBcdMissing) "BCD store is 0 bytes (corrupt) at $bcdPath - VM will fail to boot" $bcdFix
        }
        else {
            & $emit 'BCD' 'OK' "BCD store present: $bcdPath"
            try {
                $bcdText = (& bcdedit.exe /store "$bcdPath" /enum all 2>&1) | Out-String
                if ($bcdText -notmatch 'Windows Boot Loader|osloader') {
                    & $emit 'BCD' (& $toSev $sevBcdNoBootLoader) 'No Windows Boot Loader entry found in BCD' "-FixBoot"
                }
                else {
                    & $emit 'BCD' 'OK' 'Windows Boot Loader entry present'
                }
                if ($bcdText -match 'safeboot\s+(\S+)') {
                    & $emit 'BCD' (& $toSev $sevBcdSafeMode) "Safe Mode boot flag is active (safeboot $($Matches[1])) - VM will boot into Safe Mode" "-RemoveSafeModeFlag"
                }
                if ($bcdText -match 'bootstatuspolicy\s+ignoreallfailures') {
                    & $emit 'BCD' (& $toSev $sevBcdBootStatusPolicy) 'bootstatuspolicy IgnoreAllFailures is set - startup repair is suppressed'
                }
                if ($bcdText -match 'recoveryenabled\s+no') {
                    & $emit 'BCD' (& $toSev $sevBcdRecoveryDisabled) 'recoveryenabled is Off - WinRE recovery disabled'
                }
                if ($bcdText -match 'testsigning\s+yes') {
                    & $emit 'BCD' (& $toSev $sevBcdTestSigning) 'Test signing is ON - unsigned drivers are permitted to load' "-DisableTestSigning"
                }
                if ($bcdText -match 'nointegritychecks\s+yes') {
                    & $emit 'BCD' (& $toSev $sevBcdNoIntegrityChecks) 'nointegritychecks is ON - code integrity checks are bypassed; FATAL if Secure Boot is enabled' "-FixBoot"
                }
                if ($bcdText -match '\bunknown\b') {
                    & $emit 'BCD' (& $toSev $sevBcdUnknownDevice) 'BCD contains entries with unknown device/path - may point to wrong or missing partition' "-FixBoot"
                }
                if ($bcdText -match 'imcdevice|imchivename') {
                    & $emit 'BCD' (& $toSev $sevBcdImcHive) 'BCD contains imcdevice/imchivename entries (IMC.hiv) - causes BSOD 0x67 CONFIG_INITIALIZATION_FAILED; rebuild BCD to remove' "-FixBoot"
                }
                # Gen2 UEFI-specific BCD checks
                if ($script:VMGen -eq 2) {
                    # winload path mismatch: Gen2 must use winload.efi, not winload.exe
                    if ($bcdText -match 'path\s+.*\\winload\.exe') {
                        & $emit 'BCD' (& $toSev $sevBcdWinloadMismatch) 'BCD Boot Loader path references winload.exe on a Gen2 (UEFI) disk - must be winload.efi' "-FixBoot"
                    }
                }
            }
            catch { & $emit 'BCD' 'WARN' "Could not enumerate BCD: $_" }
        }

        # Gen2 UEFI: verify EFI System Partition boot files
        if ($script:VMGen -eq 2) {
            $efiBootmgfw = Join-Path $script:BootDriveLetter 'EFI\Microsoft\Boot\bootmgfw.efi'
            $efiBootx64 = Join-Path $script:BootDriveLetter 'EFI\Boot\bootx64.efi'
            if (-not (Test-Path $efiBootmgfw)) {
                & $emit 'BCD' (& $toSev $sevBootmgfwMissing) "bootmgfw.efi missing from EFI System Partition ($efiBootmgfw) - UEFI firmware cannot start Windows Boot Manager" $bcdFix
            }
            elseif ((Get-Item -LiteralPath $efiBootmgfw -ErrorAction SilentlyContinue).Length -eq 0) {
                & $emit 'BCD' (& $toSev $sevBootmgfwMissing) "bootmgfw.efi is 0 bytes (corrupt) on EFI System Partition ($efiBootmgfw) - UEFI firmware cannot start Windows Boot Manager" $bcdFix
            }
            else {
                $efiMgfwSig = Test-MicrosoftSignature -FilePath $efiBootmgfw
                if (-not $efiMgfwSig.IsMicrosoft) {
                    & $emit 'Security' (& $toSev $sevBinarySignatureBad) "bootmgfw.efi is NOT Microsoft-signed (status=$($efiMgfwSig.Status), subject='$($efiMgfwSig.Subject)') - possible tampering" $bcdFix
                }
                else {
                    & $emit 'BCD' 'OK' 'bootmgfw.efi present on EFI System Partition'
                }
            }
            if (-not (Test-Path $efiBootx64)) {
                & $emit 'BCD' (& $toSev $sevBootx64Missing) "EFI\\Boot\\bootx64.efi fallback loader missing - some UEFI firmware relies on this path" $bcdFix
            }
            elseif ((Get-Item -LiteralPath $efiBootx64 -ErrorAction SilentlyContinue).Length -eq 0) {
                & $emit 'BCD' (& $toSev $sevBootx64Missing) "EFI\\Boot\\bootx64.efi is 0 bytes (corrupt) - some UEFI firmware relies on this path" $bcdFix
            }
            else {
                $efiX64Sig = Test-MicrosoftSignature -FilePath $efiBootx64
                if (-not $efiX64Sig.IsMicrosoft) {
                    & $emit 'Security' (& $toSev $sevBinarySignatureBad) "bootx64.efi is NOT Microsoft-signed (status=$($efiX64Sig.Status), subject='$($efiX64Sig.Subject)') - possible tampering" $bcdFix
                }
            }
        }

        # Gen1 BIOS: verify boot partition has the Active flag set
        if ($script:VMGen -eq 1) {
            $bootPartition = Get-Partition -DiskNumber $script:DiskNumber -ErrorAction SilentlyContinue |
            Where-Object {
                $_.AccessPaths | Where-Object {
                    $_ -and $script:BootDriveLetter.TrimEnd('\') -eq $_.TrimEnd('\')
                }
            }
            if ($bootPartition) {
                if (-not $bootPartition.IsActive) {
                    & $emit 'BCD' (& $toSev $sevBootPartitionNotActive) "Gen1 boot partition (Partition $($bootPartition.PartitionNumber)) is NOT marked as Active - BIOS cannot locate the boot sector; VM will fail to boot (black screen)" "-FixBoot"
                }
                else {
                    & $emit 'BCD' 'OK' "Gen1 boot partition (Partition $($bootPartition.PartitionNumber)) is marked as Active"
                }
            }
        }

        # -- 3b. Critical boot/system binaries ------------------------------------
        Write-Host "--- Critical Boot Files" -ForegroundColor DarkGray
        $winloadFile = if ($script:VMGen -eq 2) { 'winload.efi' } else { 'winload.exe' }
        $bootBinaries = @(
            @{ Name = $winloadFile; Path = (Join-Path $script:WinDriveLetter "Windows\System32\$winloadFile"); Fix = "-RepairSystemFile $winloadFile" }
            @{ Name = 'ntdll.dll'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\ntdll.dll'); Fix = '-RepairSystemFile ntdll.dll' }
            @{ Name = 'kernel32.dll'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\kernel32.dll'); Fix = '-RepairSystemFile kernel32.dll' }
            @{ Name = 'hal.dll'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\hal.dll'); Fix = '-RepairSystemFile hal.dll' }
            @{ Name = 'ntoskrnl.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\ntoskrnl.exe'); Fix = '-RepairSystemFile ntoskrnl.exe' }
            @{ Name = 'ci.dll'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\ci.dll'); Fix = '-RepairSystemFile ci.dll' }
        )
        if ($script:VMGen -eq 1) {
            $bootBinaries += @{ Name = 'bootmgr'; Path = (Join-Path $script:BootDriveLetter 'bootmgr'); Fix = '-FixBoot' }
        }
        $bootFileIssues = 0
        $sigIssues = 0
        foreach ($bf in $bootBinaries) {
            $bfExists = Test-Path -LiteralPath $bf.Path
            $bfSize = if ($bfExists) { (Get-Item -LiteralPath $bf.Path -Force -ErrorAction SilentlyContinue).Length } else { 0 }
            if (-not $bfExists) {
                & $emit 'Boot' (& $toSev $sevCriticalBootFileMissing) "$($bf.Name) is MISSING ($($bf.Path)) - VM will fail to boot" $bf.Fix
                $bootFileIssues++
            }
            elseif ($bfSize -eq 0) {
                & $emit 'Boot' (& $toSev $sevCriticalBootFileMissing) "$($bf.Name) is 0 bytes (corrupt) ($($bf.Path)) - VM will fail to boot" $bf.Fix
                $bootFileIssues++
            }
            else {
                # Binary exists and is non-zero  -  verify Microsoft signature
                $sigCheck = Test-MicrosoftSignature -FilePath $bf.Path
                if (-not $sigCheck.IsMicrosoft) {
                    & $emit 'Security' (& $toSev $sevBinarySignatureBad) "$($bf.Name) is NOT Microsoft-signed (status=$($sigCheck.Status), subject='$($sigCheck.Subject)') - possible tampering or corruption" $bf.Fix
                    $sigIssues++
                }
            }
        }
        if ($bootFileIssues -eq 0 -and $sigIssues -eq 0) {
            & $emit 'Boot' 'OK' "All critical boot binaries present, non-empty, and Microsoft-signed"
        }
        elseif ($bootFileIssues -eq 0) {
            & $emit 'Boot' 'OK' "All critical boot binaries present and non-empty"
        }

        # -- 3c. Session initialization executables --------------------------------
        # These run early in the Windows boot chain after ntoskrnl hands off to user mode.
        # Missing or tampered copies cause boot loops, black screens, or automatic repair loops.
        Write-Host "--- Session Init Executables" -ForegroundColor DarkGray
        $sessionBinaries = @(
            @{ Name = 'smss.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\smss.exe'); Desc = 'Session Manager - first user-mode process; missing = immediate boot failure' }
            @{ Name = 'csrss.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\csrss.exe'); Desc = 'Client/Server Runtime - Win32 subsystem; missing = BSOD STOP 0xEF' }
            @{ Name = 'wininit.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\wininit.exe'); Desc = 'Windows Init - starts services.exe and lsass.exe' }
            @{ Name = 'services.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\services.exe'); Desc = 'Service Control Manager - without it no services start' }
            @{ Name = 'lsass.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\lsass.exe'); Desc = 'Local Security Authority - auth/logon; missing = boot loop' }
            @{ Name = 'winlogon.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\winlogon.exe'); Desc = 'Winlogon - interactive logon handler; missing = black screen' }
            @{ Name = 'logonui.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\logonui.exe'); Desc = 'Logon UI - credential provider host; missing = black screen at logon' }
        )
        $sessIssues = 0
        $sessSigIssues = 0
        foreach ($sb in $sessionBinaries) {
            $sbExists = Test-Path -LiteralPath $sb.Path
            $sbSize = if ($sbExists) { (Get-Item -LiteralPath $sb.Path -Force -ErrorAction SilentlyContinue).Length } else { 0 }
            if (-not $sbExists) {
                & $emit 'Boot' (& $toSev $sevSessionInitMissing) "$($sb.Name) is MISSING - $($sb.Desc)" "-RepairSystemFile $($sb.Name)"
                $sessIssues++
            }
            elseif ($sbSize -eq 0) {
                & $emit 'Boot' (& $toSev $sevSessionInitMissing) "$($sb.Name) is 0 bytes (corrupt) - $($sb.Desc)" "-RepairSystemFile $($sb.Name)"
                $sessIssues++
            }
            else {
                $sigCheck = Test-MicrosoftSignature -FilePath $sb.Path
                if (-not $sigCheck.IsMicrosoft) {
                    & $emit 'Security' (& $toSev $sevBinarySignatureBad) "$($sb.Name) is NOT Microsoft-signed (status=$($sigCheck.Status), subject='$($sigCheck.Subject)') - possible tampering" "-RepairSystemFile $($sb.Name)"
                    $sessSigIssues++
                }
            }
        }
        if ($sessIssues -eq 0 -and $sessSigIssues -eq 0) {
            & $emit 'Boot' 'OK' "All session init executables present, non-empty, and Microsoft-signed"
        }
        elseif ($sessIssues -eq 0) {
            & $emit 'Boot' 'OK' "All session init executables present and non-empty"
        }

        # -- 4. SYSTEM hive -------------------------------------------------------
        Write-Host "--- Registry / Services (SYSTEM hive)" -ForegroundColor DarkGray
        Invoke-WithHive 'SYSTEM' {
            # Run all SYSTEM hive checks in a child scope so .NET RegistryKey objects
            # go out of scope (and become GC-collectible) before the finally block
            # calls UnmountOffHive. Without this, cached handles prevent reg.exe unload.
            & {
                $sel = Get-ItemProperty 'HKLM:\BROKENSYSTEM\Select' -ErrorAction SilentlyContinue
                $curSet = $sel.Current
                $lkgcSet = $sel.LastKnownGood
                $defSet = $sel.Default
                $csName = if ($curSet) { 'ControlSet{0:d3}' -f $curSet } else { 'ControlSet001' }
                $svcRoot = "HKLM:\BROKENSYSTEM\$csName\Services"
                $ctrlRoot = "HKLM:\BROKENSYSTEM\$csName\Control"

                # ControlSet mismatch
                if ($null -ne $curSet -and $null -ne $defSet -and $curSet -ne $defSet) {
                    & $emit 'Registry' (& $toSev $sevControlSetMismatch) "ControlSet mismatch: Current=$curSet Default=$defSet - LKGC switch may help" "-TryLGKC"
                }
                else {
                    & $emit 'Registry' 'OK' "ControlSet: Current=ControlSet$("{0:d3}" -f $curSet)  LKGC=ControlSet$("{0:d3}" -f $lkgcSet)"
                }

                # RegBack
                $rbSystem = Join-Path $script:WinDriveLetter 'Windows\System32\config\RegBack\SYSTEM'
                if (Test-Path $rbSystem) {
                    $rbSize = (Get-Item $rbSystem).Length
                    if ($rbSize -eq 0) {
                        & $emit 'Registry' (& $toSev $sevRegBackEmpty) 'RegBack\SYSTEM is 0 bytes - no registry backup is available' "-EnableRegBackup"
                    }
                    else {
                        & $emit 'Registry' 'OK' "RegBack\SYSTEM is $([math]::Round($rbSize/1MB, 1)) MB"
                    }
                }
                else {
                    & $emit 'Registry' (& $toSev $sevRegBackMissing) 'RegBack\SYSTEM not found - registry backups not configured' "-EnableRegBackup"
                }

                # Pending Setup CmdLine
                $setupProps = Get-ItemProperty 'HKLM:\BROKENSYSTEM\Setup' -ErrorAction SilentlyContinue
                if ($setupProps.SetupType -and $setupProps.SetupType -ne 0) {
                    & $emit 'Boot' (& $toSev $sevSetupMode) "Setup mode active (SetupType=$($setupProps.SetupType)) - VM will run: '$($setupProps.CmdLine)' on next boot"
                }

                # -- Critical boot services ------------------------------------------
                # These disabled = guaranteed BSOD 0x7B or non-boot
                $critical = @(
                    @{ N = 'disk'; ExpStart = 0; Desc = 'storage bus driver (0x7B if disabled)' }
                    @{ N = 'volmgr'; ExpStart = 0; Desc = 'volume manager (0x7B if disabled)' }
                    @{ N = 'partmgr'; ExpStart = 1; Desc = 'partition manager (0x7B if disabled)' }
                    @{ N = 'storport'; ExpStart = 0; Desc = 'storage port driver (0x7B if disabled)' }
                    @{ N = 'NTFS'; ExpStart = 1; Desc = 'NTFS filesystem driver (0x7B if disabled)' }
                    @{ N = 'volsnap'; ExpStart = 1; Desc = 'volume shadow copy filter' }
                    @{ N = 'msrpc'; ExpStart = 2; Desc = 'RPC subsystem' }
                    @{ N = 'rpcss'; ExpStart = 2; Desc = 'RPC Endpoint Mapper' }
                    @{ N = 'LSM'; ExpStart = 2; Desc = 'Local Session Manager' }
                )
                foreach ($s in $critical) {
                    $sp = "$svcRoot\$($s.N)"
                    if (Test-Path $sp) {
                        $start = (Get-ItemProperty $sp -ErrorAction SilentlyContinue).Start
                        if ($start -eq 4) {
                            & $emit 'Services' (& $toSev $sevCriticalSvcDisabled) "$($s.N) is DISABLED (Start=4) - $($s.Desc) [ re-enable: Set Start=$($s.ExpStart) ]" "-EnableDriverOrService $($s.N)"
                        }
                    }
                }

                # -- Azure/Hyper-V synthetic drivers ---------------------------------
                $synBad = 0
                foreach ($sd in (Get-SyntheticDriverSpec)) {
                    $sdSvcPath = "$svcRoot\$($sd.Name)"
                    $sdExists = Test-Path $sdSvcPath
                    $sdStart = if ($sdExists) { (Get-ItemProperty $sdSvcPath -ErrorAction SilentlyContinue).Start } else { $null }
                    $sdBinPath = Join-Path $script:WinDriveLetter "Windows\System32\drivers\$($sd.Bin)"
                    $sdBinExists = Test-Path -LiteralPath $sdBinPath
                    $sdBinZero = $sdBinExists -and (Get-Item -LiteralPath $sdBinPath -Force -ErrorAction SilentlyContinue).Length -eq 0
                    if (-not $sdExists) {
                        & $emit 'Drivers' (& $toSev $sevSyntheticDriverBroken) "$($sd.Name) service key missing - $($sd.Desc) will not load" "-EnsureSyntheticDriversEnabled"
                        $synBad++
                    }
                    elseif (-not $sdBinExists -or $sdBinZero) {
                        $state = if (-not $sdBinExists) { 'missing' } else { '0-byte' }
                        & $emit 'Drivers' (& $toSev $sevSyntheticDriverBroken) "$($sd.Name) binary $($sd.Bin) is $state - $($sd.Desc)" "-RepairSystemFile $($sd.Bin)"
                        $synBad++
                    }
                    elseif ($null -ne $sdStart -and [int]$sdStart -ne [int]$sd.Start) {
                        & $emit 'Drivers' (& $toSev $sevSyntheticDriverBroken) "$($sd.Name) Start=$sdStart (expected $($sd.Start)) - $($sd.Desc)" "-EnsureSyntheticDriversEnabled"
                        $synBad++
                    }
                    else {
                        # Binary exists, non-zero, start value correct  -  verify signature
                        $sdSig = Test-MicrosoftSignature -FilePath $sdBinPath
                        if (-not $sdSig.IsMicrosoft) {
                            & $emit 'Security' (& $toSev $sevBinarySignatureBad) "$($sd.Bin) is NOT Microsoft-signed (status=$($sdSig.Status), subject='$($sdSig.Subject)') - possible tampering" "-RepairSystemFile $($sd.Bin)"
                            $synBad++
                        }
                    }
                }
                if ($synBad -eq 0) {
                    & $emit 'Drivers' 'OK' "Azure synthetic drivers (vmbus/storvsc/netvsc) healthy"
                }

                # -- Hyper-V integration services ------------------------------------
                # These don't block boot but missing/broken ones cause "VM running but
                # unusable" states on Azure (no heartbeat, no graceful shutdown, no time
                # sync, no KVP metadata exchange, no VSS backup).
                $intSvcs = @(
                    @{ Name = 'vmicheartbeat'; Desc = 'Heartbeat (host knows OS is alive)' }
                    @{ Name = 'vmicshutdown'; Desc = 'Graceful shutdown from host/portal' }
                    @{ Name = 'vmictimesync'; Desc = 'Time synchronisation with host' }
                    @{ Name = 'vmickvpexchange'; Desc = 'KVP data exchange (Azure metadata/hostname)' }
                    @{ Name = 'vmicvss'; Desc = 'VSS integration (Azure Backup snapshots)' }
                )
                $intBad = 0
                foreach ($ic in $intSvcs) {
                    $icPath = "$svcRoot\$($ic.Name)"
                    $icExists = Test-Path $icPath
                    if (-not $icExists) {
                        & $emit 'HyperV' (& $toSev $sevIntegrationSvcMissing) "$($ic.Name) service key missing - $($ic.Desc)" "-EnableDriverOrService $($ic.Name)"
                        $intBad++
                        continue
                    }
                    $icProps = Get-ItemProperty $icPath -ErrorAction SilentlyContinue
                    $icStart = $icProps.Start
                    if ($icStart -eq 4) {
                        & $emit 'HyperV' (& $toSev $sevIntegrationSvcDisabled) "$($ic.Name) is DISABLED (Start=4) - $($ic.Desc)" "-EnableDriverOrService $($ic.Name)"
                        $intBad++
                        continue
                    }
                    # Check binary exists and signature
                    if ($icProps.ImagePath) {
                        $icBinPath = Resolve-GuestImagePath $icProps.ImagePath
                        $icBinExists = Test-Path -LiteralPath $icBinPath
                        $icBinZero = $icBinExists -and (Get-Item -LiteralPath $icBinPath -Force -ErrorAction SilentlyContinue).Length -eq 0
                        if (-not $icBinExists -or $icBinZero) {
                            $bState = if (-not $icBinExists) { 'missing' } else { '0-byte' }
                            & $emit 'HyperV' (& $toSev $sevIntegrationSvcBinMissing) "$($ic.Name) binary is $bState ($icBinPath) - $($ic.Desc)"
                            $intBad++
                        }
                        elseif ($icBinExists) {
                            $icSig = Test-MicrosoftSignature -FilePath $icBinPath
                            if (-not $icSig.IsMicrosoft) {
                                & $emit 'Security' (& $toSev $sevBinarySignatureBad) "$($ic.Name) binary is NOT Microsoft-signed (status=$($icSig.Status), subject='$($icSig.Subject)') - possible tampering" "-RepairSystemFile $(Split-Path $icBinPath -Leaf)"
                                $intBad++
                            }
                        }
                    }
                }
                if ($intBad -eq 0) {
                    & $emit 'HyperV' 'OK' 'Hyper-V integration services present and enabled (heartbeat/shutdown/timesync/kvp/vss)'
                }

                # -- Domain trust / Netlogon -----------------------------------------
                $tcpipParams = "$svcRoot\Tcpip\Parameters"
                $domainVal = (Get-ItemProperty $tcpipParams -ErrorAction SilentlyContinue).Domain
                $netlogonSt = (Get-ItemProperty "$svcRoot\Netlogon" -ErrorAction SilentlyContinue).Start
                $isDomainJoined = $domainVal -and $domainVal -notmatch '^(WORKGROUP|LOCALDOMAIN)?$'
                if ($isDomainJoined -and $netlogonSt -eq 4) {
                    & $emit 'Networking' (& $toSev $sevNetlogonDisabled) "Domain-joined (domain='$domainVal') but Netlogon is DISABLED (Start=4) - domain auth and RDP will fail" "-EnableDriverOrService Netlogon"
                }

                # -- RDP ------------------------------------------------------------
                $tsPath = "$ctrlRoot\Terminal Server"
                $rdpTcpPath = "$ctrlRoot\Terminal Server\WinStations\RDP-Tcp"
                $fDeny = (Get-ItemProperty $tsPath -ErrorAction SilentlyContinue).fDenyTSConnections
                if ($fDeny -eq 1) {
                    & $emit 'RDP' (& $toSev $sevRdpDenied) 'fDenyTSConnections=1 - RDP is disabled at canonical key' "-FixRDP"
                }
                elseif ($null -eq $fDeny) {
                    & $emit 'RDP' (& $toSev $sevRdpDenyUnknown) 'fDenyTSConnections not found - RDP state unclear' "-FixRDP"
                }
                else {
                    & $emit 'RDP' 'OK' 'fDenyTSConnections=0 - RDP is enabled'
                }

                # TermService, SessionEnv, UmRdpService
                foreach ($rdpSvc in @(
                        @{ N = 'TermService'; Desc = 'Remote Desktop Services'; Crit = $true }
                        @{ N = 'SessionEnv'; Desc = 'Remote Desktop Config'; Crit = $true }
                        @{ N = 'UmRdpService'; Desc = 'RDP UserMode Port Redirector'; Crit = $false }
                    )) {
                    $svcStart = (Get-ItemProperty "$svcRoot\$($rdpSvc.N)" -ErrorAction SilentlyContinue).Start
                    if ($svcStart -eq 4) {
                        $sev = if ($rdpSvc.Crit) { (& $toSev $sevRdpSvcDisabledCrit) } else { (& $toSev $sevRdpSvcDisabledWarn) }
                        & $emit 'RDP' $sev "$($rdpSvc.N) ($($rdpSvc.Desc)) is DISABLED (Start=4) - RDP will not work" "-FixRDP"
                    }
                    elseif ($null -ne $svcStart) {
                        & $emit 'RDP' 'OK' "$($rdpSvc.N) Start=$svcStart"
                    }
                }

                if (Test-Path $rdpTcpPath) {
                    $rdpP = Get-ItemProperty $rdpTcpPath -ErrorAction SilentlyContinue

                    # Port number
                    $rdpPort = $rdpP.PortNumber
                    if ($null -ne $rdpPort -and $rdpPort -ne 3389) {
                        & $emit 'RDP' (& $toSev $sevRdpNonDefaultPort) "RDP-Tcp port is $rdpPort (not the default 3389) - ensure firewall allows this port or run -FixRDP to reset" "-FixRDP"
                    }
                    else {
                        & $emit 'RDP' 'OK' "RDP-Tcp port: $(if ($null -eq $rdpPort) { '(not set, default 3389)' } else { $rdpPort })"
                    }

                    # Security layer
                    $sl = $rdpP.SecurityLayer
                    if ($null -ne $sl) {
                        $slDesc = switch ($sl) { 0 { 'RDP native (no SSL) - weakest encryption' } 1 { 'Negotiate' } 2 { 'SSL/TLS required' } default { "Unknown ($sl)" } }
                        $slSev = if ($sl -eq 0) { (& $toSev $sevRdpSecurityLayerWeak) } else { 'INFO' }
                        & $emit 'RDP' $slSev "SecurityLayer=$sl ($slDesc)"
                    }

                    # NLA / UserAuthentication
                    $ua = $rdpP.UserAuthentication
                    if ($ua -eq 0) {
                        & $emit 'RDP' (& $toSev $sevRdpNLADisabled) 'NLA is DISABLED (UserAuthentication=0) - any user can attempt login without pre-auth; run -EnableNLA to restore' "-EnableNLA"
                    }
                    elseif ($ua -eq 1) {
                        & $emit 'RDP' 'OK' 'NLA is enabled (UserAuthentication=1)'
                    }
                    else {
                        & $emit 'RDP' 'INFO' 'NLA/UserAuthentication not set on RDP-Tcp key (policy may control this)'
                    }

                    # fAllowSecProtocolNegotiation (also touched by -DisableNLA)
                    $aspn = $rdpP.fAllowSecProtocolNegotiation
                    if ($aspn -eq 0) {
                        & $emit 'RDP' (& $toSev $sevRdpSecProtoNeg) 'fAllowSecProtocolNegotiation=0 - security protocol negotiation disabled; run -EnableNLA or -FixRDP to reset' "-EnableNLA"
                    }

                    # MinEncryptionLevel (1=Low was set by -DisableNLA; default is typically 2)
                    $mel = $rdpP.MinEncryptionLevel
                    if ($null -ne $mel -and $mel -lt 2) {
                        & $emit 'RDP' (& $toSev $sevRdpMinEncLevel) "MinEncryptionLevel=$mel (below recommended 2) - may indicate NLA was disabled" "-EnableNLA"
                    }

                    # SSL certificate thumbprint - absence is normal (Windows generates one on first RDP connection)
                    $cert = $rdpP.SSLCertificateSHA1Hash
                    if ($null -ne $cert -and -not ($cert -is [byte[]] -and $cert.Count -eq 0)) {
                        & $emit 'RDP' 'OK' 'RDP SSL certificate thumbprint is present'
                    }
                    # No thumbprint = not flagged; Windows auto-generates one at first RDP connection

                    # MaxInstanceCount - if 0, RDP refuses every connection attempt
                    $maxInst = $rdpP.MaxInstanceCount
                    if ($null -ne $maxInst -and $maxInst -eq 0) {
                        & $emit 'RDP' (& $toSev $sevRdpMaxInstanceZero) "MaxInstanceCount=0 on RDP-Tcp - RDP will refuse ALL connections; run -FixRDP to reset" "-FixRDP"
                    }
                }
                else {
                    & $emit 'RDP' (& $toSev $sevRdpTcpKeyMissing) 'RDP-Tcp WinStation key not found - RDP listener may be misconfigured' "-FixRDP"
                }

                # RDP-related crypto services (required for certificate/key operations)
                foreach ($cryptSvc in @(
                        @{ N = 'KeyIso'; DefStart = 3; Desc = 'CNG Key Isolation (needed for RDP private key)' }
                        @{ N = 'CryptSvc'; DefStart = 2; Desc = 'Cryptographic Services (needed for cert store)' }
                        @{ N = 'CertPropSvc'; DefStart = 3; Desc = 'Certificate Propagation (needed for user certs)' }
                    )) {
                    $cs = (Get-ItemProperty "$svcRoot\$($cryptSvc.N)" -ErrorAction SilentlyContinue).Start
                    if ($cs -eq 4) {
                        & $emit 'RDP' (& $toSev $sevRdpCryptoSvcDisabled) "$($cryptSvc.N) ($($cryptSvc.Desc)) is DISABLED - RDP certificate operations will fail" "-FixRDPPermissions"
                    }
                }

                # TLS 1.2 explicitly disabled in SCHANNEL
                foreach ($tlsRole in @('Client', 'Server')) {
                    $tlsPath = "$ctrlRoot\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\$tlsRole"
                    if (Test-Path $tlsPath) {
                        $tlsProps = Get-ItemProperty $tlsPath -ErrorAction SilentlyContinue
                        if ($tlsProps.Enabled -eq 0 -or $tlsProps.DisabledByDefault -eq 1) {
                            & $emit 'RDP' (& $toSev $sevRdpTlsDisabled) "TLS 1.2 $tlsRole is explicitly DISABLED in SCHANNEL - RDP SSL handshake may fail" "-FixRDP"
                        }
                    }
                }

                # NTLM restrictions
                $msv1 = Get-ItemProperty "$ctrlRoot\Lsa\MSV1_0" -ErrorAction SilentlyContinue
                if ($msv1) {
                    if ($msv1.RestrictSendingNTLMTraffic -ge 2 -or $msv1.RestrictReceivingNTLMTraffic -ge 1) {
                        & $emit 'RDP' (& $toSev $sevRdpNtlmRestrict) "NTLM restrictions: RestrictSending=$($msv1.RestrictSendingNTLMTraffic) RestrictReceiving=$($msv1.RestrictReceivingNTLMTraffic) - may block RDP auth" "-FixRDPAuth"
                    }
                }

                # LmCompatibilityLevel (too restrictive blocks older clients)
                $lsaProps = Get-ItemProperty "$ctrlRoot\Lsa" -ErrorAction SilentlyContinue
                $lmCompat = $lsaProps.LmCompatibilityLevel
                if ($null -ne $lmCompat -and $lmCompat -gt 5) {
                    & $emit 'RDP' (& $toSev $sevRdpLmCompat) "LmCompatibilityLevel=$lmCompat (>5) - may block NTLM-based RDP auth from some clients" "-FixRDPAuth"
                }

                # -- Credential Guard ------------------------------------------------
                $cgLsa = $lsaProps.LsaCfgFlags
                if ($cgLsa -and $cgLsa -ne 0) {
                    $lockType = if ($cgLsa -eq 1) { 'UEFI lock - registry change alone is insufficient' } else { 'software lock' }
                    & $emit 'Security' (& $toSev $sevCredentialGuard) "Credential Guard is enabled (LsaCfgFlags=$cgLsa, $lockType)" "-DisableCredentialGuard"
                }
                $runAsPPL = $lsaProps.RunAsPPL
                if ($runAsPPL -eq 1) {
                    & $emit 'Security' (& $toSev $sevLsaPPL) 'LSA Protected Process (RunAsPPL=1) is active - may affect some security tools'
                }

                # -- Azure Guest Agent ------------------------------------------------
                foreach ($ag in @('WindowsAzureGuestAgent', 'RdAgent')) {
                    $ap = "$svcRoot\$ag"
                    if (Test-Path $ap) {
                        $aStart = (Get-ItemProperty $ap -ErrorAction SilentlyContinue).Start
                        if ($aStart -eq 4) {
                            & $emit 'AzureAgent' (& $toSev $sevAzureAgentDisabled) "$ag is DISABLED (Start=4) - VM will not respond to Azure platform operations" "-FixAzureGuestAgent"
                        }
                        elseif ($aStart -ne 2) {
                            & $emit 'AzureAgent' (& $toSev $sevAzureAgentWrongStart) "$ag Start=$aStart (expected 2/Auto)" "-FixAzureGuestAgent"
                        }
                        else {
                            & $emit 'AzureAgent' 'OK' "$ag Start=2 (Auto)"
                        }
                    }
                    else {
                        & $emit 'AzureAgent' (& $toSev $sevAzureAgentMissing) "$ag not found in registry - agent may not be installed" "-InstallAzureVMAgent"
                    }
                }

                # -- Networking: BFE & TCP/IP -----------------------------------------
                $bfeStart = (Get-ItemProperty "$svcRoot\BFE" -ErrorAction SilentlyContinue).Start
                if ($bfeStart -eq 4) {
                    & $emit 'Networking' (& $toSev $sevBfeDisabled) 'BFE (Base Filtering Engine) is DISABLED - Windows Firewall and IPSec/network policy will not function' "-EnableBFE"
                }
                elseif ($null -ne $bfeStart) {
                    & $emit 'Networking' 'OK' "BFE Start=$bfeStart (enabled)"
                }
                $tcpStart = (Get-ItemProperty "$svcRoot\Tcpip" -ErrorAction SilentlyContinue).Start
                if ($tcpStart -eq 4) {
                    & $emit 'Networking' (& $toSev $sevTcpipDisabled) 'Tcpip service is DISABLED - no network will be available' "-ResetNetworkStack"
                }

                # nsi (Network Store Interface) - core TCP/IP dependency; if disabled, zero networking
                $nsiStart = (Get-ItemProperty "$svcRoot\nsi" -ErrorAction SilentlyContinue).Start
                if ($nsiStart -eq 4) {
                    & $emit 'Networking' (& $toSev $sevNsiDisabled) "nsi (Network Store Interface) is DISABLED - TCP/IP stack is non-functional; all networking will fail" "-EnableDriverOrService nsi"
                }

                # Additional networking services
                foreach ($netSvc in @(
                        @{ N = 'Dnscache'; Desc = 'DNS Client - name resolution will fail' }
                        @{ N = 'NlaSvc'; Desc = 'Network Location Awareness - network profile detection will fail' }
                        @{ N = 'Dhcp'; Desc = 'DHCP Client - automatic IP configuration will not work' }
                        @{ N = 'LanmanWorkstation'; Desc = 'Workstation service (SMB client) - file sharing access will fail' }
                        @{ N = 'LanmanServer'; Desc = 'Server service (SMB server) - file sharing hosting will fail' }
                    )) {
                    $ns = (Get-ItemProperty "$svcRoot\$($netSvc.N)" -ErrorAction SilentlyContinue).Start
                    if ($ns -eq 4) {
                        & $emit 'Networking' (& $toSev $sevNetSvcDisabled) "$($netSvc.N) is DISABLED - $($netSvc.Desc)" "-ResetNetworkStack"
                    }
                }

                # SAN policy (partmgr)
                $sanPolicy = (Get-ItemProperty "$svcRoot\partmgr\Parameters" -ErrorAction SilentlyContinue).SanPolicy
                if ($null -ne $sanPolicy -and $sanPolicy -ne 1 -and $sanPolicy -ne 0) {
                    $sanDesc = switch ($sanPolicy) { 2 { 'OfflineShared - shared disks stay offline' } 3 { 'OfflineAll - all SAN disks stay offline' } 4 { 'OfflineInternal - internal SAN disks offline' } default { "Value=$sanPolicy" } }
                    & $emit 'Networking' (& $toSev $sevSanPolicy) "SAN policy is set to $sanDesc - data disks may not come online after migration; run -FixSanPolicy to set OnlineAll" "-FixSanPolicy"
                }
                elseif ($null -ne $sanPolicy) {
                    & $emit 'Networking' 'OK' "SAN policy: OnlineAll ($sanPolicy)"
                }

                # -- Boot/System drivers with missing binaries -------------------------
                # We only flag drivers that are registered to load at boot/system start
                # but whose binary is ABSENT on the offline disk - these WILL cause a
                # BSOD or hang on next boot. Inbox hardware drivers (LSI, Intel RST,
                # Broadcom HBA, etc.) ship with Windows but carry vendor company names;
                # they are NOT flagged here because they are safe and present on disk.
                # Use -DisableThirdPartyDrivers to intentionally suppress all non-MS
                # drivers when troubleshooting a clean-boot scenario.
                $missingDrivers = [System.Collections.Generic.List[string]]::new()
                $unsignedDrivers = [System.Collections.Generic.List[string]]::new()
                Get-ChildItem $svcRoot -ErrorAction SilentlyContinue | ForEach-Object {
                    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                    # Only kernel/filesystem drivers (Type 1/2) at Boot(0) or System(1) start
                    if ($p.Type -notin @(1, 2) -or $p.Start -notin @(0, 1) -or -not $p.ImagePath) { return }
                    $imgR = Resolve-GuestImagePath $p.ImagePath
                    # Flag if binary is missing or 0 bytes (corrupt/truncated)
                    if (-not (Test-Path $imgR)) { $missingDrivers.Add("$($_.PSChildName) ($($p.ImagePath))") }
                    elseif ((Get-Item -LiteralPath $imgR -ErrorAction SilentlyContinue).Length -eq 0) { $missingDrivers.Add("$($_.PSChildName) ($($p.ImagePath)) [0 bytes]") }
                    else {
                        # Verify Microsoft signature on present boot/system drivers
                        $drvSig = Test-MicrosoftSignature -FilePath $imgR
                        if (-not $drvSig.IsMicrosoft) {
                            $unsignedDrivers.Add("$($_.PSChildName) ($($p.ImagePath)) [status=$($drvSig.Status)]")
                        }
                    }
                }
                if ($missingDrivers.Count -gt 0) {
                    & $emit 'Drivers' (& $toSev $sevMissingDriverBinaries) "$($missingDrivers.Count) Boot/System driver(s) registered but binary MISSING or 0-byte - will BSOD on boot: $($missingDrivers -join ', ')" "-RepairSystemFile <name.sys> or -DisableThirdPartyDrivers"
                }
                else {
                    & $emit 'Drivers' 'OK' 'All Boot/System drivers have binaries present on disk'
                }
                if ($unsignedDrivers.Count -gt 0) {
                    & $emit 'Security' (& $toSev $sevBinarySignatureBad) "$($unsignedDrivers.Count) Boot/System driver(s) NOT Microsoft-signed (possible tampering or third-party): $($unsignedDrivers -join ', ')" "-GetServicesReport -IssuesOnly"
                }

                # -- Device class filters ---------------------------------------------
                $classRoot = "HKLM:\BROKENSYSTEM\$csName\Control\Class"
                $safeFilters = @{
                    '{4d36e967-e325-11ce-bfc1-08002be10318}' = [string[]]@('partmgr', 'fvevol', 'iorate', 'storqosflt', 'wcifs', 'ehstorclass')
                    '{4d36e96a-e325-11ce-bfc1-08002be10318}' = [string[]]@('iasf', 'iastorf')
                    '{4d36e97b-e325-11ce-bfc1-08002be10318}' = [string[]]@()
                    '{71a27cdd-812a-11d0-bec7-08002be2092f}' = [string[]]@('volsnap', 'fvevol', 'rdyboost', 'spldr', 'volmgrx', 'iorate', 'storqosflt')
                    '{4d36e972-e325-11ce-bfc1-08002be10318}' = [string[]]@('wfplwf', 'ndiscap', 'ndisimplatformmpfilter', 'vmsproxyhnicfilter', 'vms3cap', 'mslldp', 'psched', 'bridge')
                }
                $filterClasses = @(
                    @{ GUID = '{4d36e967-e325-11ce-bfc1-08002be10318}'; Name = 'DiskDrive'; Sev = (& $toSev $sevDeviceFiltersCrit) }
                    @{ GUID = '{4d36e96a-e325-11ce-bfc1-08002be10318}'; Name = 'SCSIAdapter'; Sev = (& $toSev $sevDeviceFiltersCrit) }
                    @{ GUID = '{4d36e97b-e325-11ce-bfc1-08002be10318}'; Name = 'SCSIController'; Sev = (& $toSev $sevDeviceFiltersCrit) }
                    @{ GUID = '{71a27cdd-812a-11d0-bec7-08002be2092f}'; Name = 'Volume'; Sev = (& $toSev $sevDeviceFiltersWarn) }
                    @{ GUID = '{4d36e972-e325-11ce-bfc1-08002be10318}'; Name = 'Net'; Sev = (& $toSev $sevDeviceFiltersWarn) }
                )
                foreach ($fc in $filterClasses) {
                    $cp = "$classRoot\$($fc.GUID)"
                    if (-not (Test-Path $cp)) { continue }
                    $safe = $safeFilters[$fc.GUID]
                    foreach ($ft in @('UpperFilters', 'LowerFilters')) {
                        $raw = (Get-ItemProperty $cp -ErrorAction SilentlyContinue).$ft
                        $active = @($raw | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
                        $suspect = @($active | Where-Object { $safe -inotcontains $_ })
                        if ($suspect.Count -gt 0) {
                            & $emit 'DeviceFilters' $fc.Sev "$($fc.Name) $ft contains non-standard entries: $($suspect -join ', ')" "-FixDeviceFilters"
                        }
                    }
                }

                # -- Orphaned NDIS bindings --------------------------------------------
                $orphanIds = [System.Collections.Generic.List[string]]::new()
                $seenComp = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($cg in @('{4D36E973-E325-11CE-BFC1-08002BE10318}', '{4D36E974-E325-11CE-BFC1-08002BE10318}', '{4D36E975-E325-11CE-BFC1-08002BE10318}')) {
                    $ck = "HKLM:\BROKENSYSTEM\$csName\Control\Class\$cg"
                    if (-not (Test-Path $ck)) { continue }
                    Get-ChildItem $ck -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
                        $pp = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                        $cid = if ($pp.ComponentId) { $pp.ComponentId } else { $pp.ComponentID }
                        if (-not $cid -or $cid -match '^ms_' -or -not $seenComp.Add($cid)) { return }
                        $sn = $cid -replace '^ms_', ''
                        $ipp = (Get-ItemProperty "$svcRoot\$sn" -ErrorAction SilentlyContinue).ImagePath
                        if ($null -eq $ipp) { return }
                        $ir = Resolve-GuestImagePath $ipp
                        if (-not (Test-Path $ir) -or (Test-Path $ir) -and (Get-Item -LiteralPath $ir -ErrorAction SilentlyContinue).Length -eq 0) { $orphanIds.Add($cid) }
                    }
                }
                if ($orphanIds.Count -gt 0) {
                    & $emit 'Networking' (& $toSev $sevOrphanedNdis) "Orphaned NDIS binding(s) with missing binary: $($orphanIds -join ', ') - will prevent network initialisation at boot" "-FixNetBindings"
                }
                else {
                    & $emit 'Networking' 'OK' 'No orphaned NDIS binding components'
                }

                # -- Windows Update services ------------------------------------------
                foreach ($wu in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
                    $wuS = (Get-ItemProperty "$svcRoot\$wu" -ErrorAction SilentlyContinue).Start
                    if ($wuS -eq 4) {
                        & $emit 'WindowsUpdate' (& $toSev $sevUpdateWuDisabled) "$wu is disabled (Start=4) - intentionally stopped via -DisableWindowsUpdate; re-enable on the live VM with: Set-Service -Name $wu -StartupType Automatic"
                    }
                }

                # AppIDSvc (AppLocker enforcement service)
                $appIdSvc = (Get-ItemProperty "$svcRoot\AppIDSvc" -ErrorAction SilentlyContinue).Start
                $script:_sysCheckAppIdSvcStart = $appIdSvc
                if ($null -ne $appIdSvc -and $appIdSvc -ne 4) {
                    & $emit 'Security' (& $toSev $sevAppIdSvc) "AppIDSvc (Application Identity) Start=$appIdSvc - this service is required for AppLocker to enforce rules"
                }

                # -- Hyper-V ACPI device IDs -----------------------------------------
                $enumAcpiRoot = "HKLM:\BROKENSYSTEM\$csName\Enum\ACPI"
                $msft1000Present = Test-Path "$enumAcpiRoot\MSFT1000"
                $msft1002Present = Test-Path "$enumAcpiRoot\MSFT1002"
                if (-not $msft1000Present -or -not $msft1002Present) {
                    $missing = @()
                    if (-not $msft1000Present) { $missing += 'MSFT1000 (VMBus)' }
                    if (-not $msft1002Present) { $missing += 'MSFT1002 (Hyper-V Gen Counter)' }
                    & $emit 'ACPI' (& $toSev $sevACPISettings) "Hyper-V ACPI device $(if ($missing.Count -gt 1){'entries'}else{'entry'}) missing: $($missing -join ', ') - newer ACPI IDs needed for full Hyper-V synthetic device support" "-CopyACPISettings"
                }
                else {
                    & $emit 'ACPI' 'OK' 'Hyper-V ACPI device entries present (MSFT1000, MSFT1002)'
                }

                # -- Driver Verifier --------------------------------------------------
                $mmPath = "$ctrlRoot\Session Manager\Memory Management"
                if (Test-Path $mmPath) {
                    $vDrivers = (Get-ItemProperty $mmPath -ErrorAction SilentlyContinue).VerifyDrivers
                    $vLevel = (Get-ItemProperty $mmPath -ErrorAction SilentlyContinue).VerifyDriverLevel
                    if ($vDrivers -or $vLevel) {
                        $targets = if ($vDrivers -eq '*') { 'ALL drivers' } elseif ($vDrivers) { "drivers: $vDrivers" } else { "level=$vLevel" }
                        & $emit 'Drivers' (& $toSev $sevDriverVerifier) "Driver Verifier is ENABLED ($targets) - will BSOD on any verification failure; disable with -DisableDriverVerifier" "-DisableDriverVerifier"
                    }
                    else {
                        & $emit 'Drivers' 'OK' 'Driver Verifier is not configured'
                    }
                }

                # -- Firewall state ---------------------------------------------------
                $fwBase = "$SystemRoot\Services\SharedAccess\Parameters\FirewallPolicy"
                $fwAllDisabled = $true
                foreach ($fwProf in @('DomainProfile', 'StandardProfile', 'PublicProfile')) {
                    $fwPath = "$fwBase\$fwProf"
                    if (Test-Path $fwPath) {
                        $fwEnabled = (Get-ItemProperty $fwPath -ErrorAction SilentlyContinue).EnableFirewall
                        if ($fwEnabled -ne 0) { $fwAllDisabled = $false }
                    }
                }
                if (-not $fwAllDisabled) {
                    & $emit 'Firewall' (& $toSev $sevFirewallEnabled) 'Windows Firewall is enabled - verify RDP (TCP 3389) is allowed inbound; use -DisableFirewall to disable for troubleshooting' "-DisableFirewall"
                }
                else {
                    & $emit 'Firewall' 'OK' 'Windows Firewall is disabled on all profiles'
                }

                # -- Gen2 UEFI / Trusted Launch security (registry-based) ------------
                if ($script:VMGen -eq 2) {
                    Write-Host "--- Gen2 UEFI / Trusted Launch Security" -ForegroundColor DarkGray

                    # Secure Boot state: did the guest OS previously boot with Secure Boot?
                    $sbStatePath = "$ctrlRoot\SecureBoot\State"
                    $sbEnabled = $null
                    if (Test-Path $sbStatePath) {
                        $sbEnabled = (Get-ItemProperty $sbStatePath -ErrorAction SilentlyContinue).UEFISecureBootEnabled
                    }
                    if ($sbEnabled -eq 1) {
                        & $emit 'UEFI' (& $toSev $sevSecureBootState) 'Guest was previously running with Secure Boot enabled (UEFISecureBootEnabled=1)'
                        # Cross-reference: testsigning or nointegritychecks in BCD would be fatal
                        try {
                            $bcdPathSb = Get-BcdStorePath -Generation $script:VMGen -BootDrive $script:BootDriveLetter.TrimEnd('\')
                            if (Test-Path $bcdPathSb) {
                                $bcdSbText = (& bcdedit.exe /store "$bcdPathSb" /enum all 2>&1) | Out-String
                                if ($bcdSbText -match 'testsigning\s+yes') {
                                    & $emit 'UEFI' (& $toSev $sevSecureBootConflict) 'CONFLICT: Test signing is ON but guest had Secure Boot enabled - VM will fail to boot with Secure Boot; disable test signing first' "-DisableTestSigning"
                                }
                                if ($bcdSbText -match 'nointegritychecks\s+yes') {
                                    & $emit 'UEFI' (& $toSev $sevSecureBootConflict) 'CONFLICT: nointegritychecks is ON but guest had Secure Boot enabled - VM will fail to boot with Secure Boot' "-FixBoot"
                                }
                            }
                        }
                        catch { <# BCD already checked above; non-fatal here #> }
                    }
                    elseif ($null -ne $sbEnabled) {
                        & $emit 'UEFI' 'OK' 'Secure Boot was not active on guest (UEFISecureBootEnabled=0)'
                    }
                    else {
                        & $emit 'UEFI' 'INFO' 'SecureBoot\\State key not found - guest may not have booted with UEFI Secure Boot awareness'
                    }

                    # Secure Boot 2023 certificate update status (registry snapshot from last boot on real firmware)
                    $sbServicingPath = "$ctrlRoot\SecureBoot\Servicing"
                    $sbMainPath = "$ctrlRoot\SecureBoot"
                    $hvCaveat = '(Note: these registry values reflect the last boot environment; if this VM was previously booted as nested on Hyper-V, these values may reflect Hyper-V firmware, not the original Azure VM)'
                    if ($sbEnabled -eq 1) {
                        # UEFICA2023Status
                        if (Test-Path $sbServicingPath) {
                            $sbServProps = Get-ItemProperty $sbServicingPath -ErrorAction SilentlyContinue
                            $certStatus = $sbServProps.UEFICA2023Status
                            if ($certStatus -eq 'Updated') {
                                & $emit 'UEFI' 'INFO' 'Secure Boot 2023 certificates were applied (UEFICA2023Status=Updated)'
                            }
                            elseif ($null -ne $certStatus) {
                                & $emit 'UEFI' (& $toSev $sevSecureBootCertNotUpdated) "Secure Boot 2023 certificates not yet applied (UEFICA2023Status=$certStatus) - certificates expire Jun-Oct 2026. $hvCaveat"
                            }
                            else {
                                & $emit 'UEFI' (& $toSev $sevSecureBootCertNotUpdated) "Secure Boot enabled but UEFICA2023Status not set - 2023 certificate update may not have started. $hvCaveat"
                            }
                            # UEFICA2023Error
                            $certError = $sbServProps.UEFICA2023Error
                            if ($null -ne $certError) {
                                $certErrorEvent = $sbServProps.UEFICA2023ErrorEvent
                                $errorDetail = "Secure Boot certificate update error detected (UEFICA2023Error=$certError)"
                                if ($null -ne $certErrorEvent) { $errorDetail += " (ErrorEvent=$certErrorEvent)" }
                                $errorDetail += ". $hvCaveat"
                                & $emit 'UEFI' (& $toSev $sevSecureBootCertError) $errorDetail
                            }
                        }
                        else {
                            & $emit 'UEFI' (& $toSev $sevSecureBootCertNotUpdated) "Secure Boot enabled but SecureBoot\Servicing key absent - 2023 certificate update status unknown. $hvCaveat"
                        }
                        # AvailableUpdates bitmask (informational)
                        if (Test-Path $sbMainPath) {
                            $availUpdates = (Get-ItemProperty $sbMainPath -ErrorAction SilentlyContinue).AvailableUpdates
                            if ($null -ne $availUpdates) {
                                $availHex = '0x{0:X}' -f [int]$availUpdates
                                if ($availUpdates -eq 0 -or $availUpdates -eq 0x4000) {
                                    & $emit 'UEFI' 'INFO' "Secure Boot AvailableUpdates=$availHex - all certificate update steps completed"
                                }
                                else {
                                    & $emit 'UEFI' 'INFO' "Secure Boot AvailableUpdates=$availHex - certificate update steps still pending (0x40=DB, 0x800/0x1000=3P certs, 0x4=KEK, 0x100=boot mgr)"
                                }
                            }
                        }
                    }

                    # VBS / DeviceGuard configuration
                    $dgPath = "$ctrlRoot\DeviceGuard"
                    if (Test-Path $dgPath) {
                        $dgProps = Get-ItemProperty $dgPath -ErrorAction SilentlyContinue
                        $vbsEnabled = $dgProps.EnableVirtualizationBasedSecurity
                        if ($vbsEnabled -eq 1) {
                            & $emit 'UEFI' (& $toSev $sevDeviceGuardVbs) 'Virtualization-Based Security (VBS) is enabled in DeviceGuard registry'
                        }
                        $platReq = $dgProps.RequirePlatformSecurityFeatures
                        if ($null -ne $platReq -and $platReq -ge 3) {
                            & $emit 'UEFI' (& $toSev $sevDeviceGuardPlatReq) "DeviceGuard RequirePlatformSecurityFeatures=$platReq (requires Secure Boot + DMA protection) - not all Azure VM sizes support DMA protection; may prevent VBS from starting"
                        }
                        elseif ($null -ne $platReq -and $platReq -ge 1) {
                            & $emit 'UEFI' 'OK' "DeviceGuard RequirePlatformSecurityFeatures=$platReq (Secure Boot only)"
                        }
                    }

                    # HVCI (Hypervisor-enforced Code Integrity)
                    $hvciPath = "$ctrlRoot\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
                    if (Test-Path $hvciPath) {
                        $hvciEnabled = (Get-ItemProperty $hvciPath -ErrorAction SilentlyContinue).Enabled
                        if ($hvciEnabled -eq 1) {
                            & $emit 'UEFI' (& $toSev $sevHvciEnabled) 'HVCI (Hypervisor-enforced Code Integrity) is enabled - unsigned kernel drivers will be blocked at runtime'
                        }
                    }

                    # Early Launch Anti-Malware driver load policy
                    $elamPath = "$ctrlRoot\EarlyLaunch"
                    if (Test-Path $elamPath) {
                        $driverLoadPolicy = (Get-ItemProperty $elamPath -ErrorAction SilentlyContinue).DriverLoadPolicy
                        if ($null -ne $driverLoadPolicy) {
                            $policyDesc = switch ([int]$driverLoadPolicy) {
                                1 { 'Good only - unknown/bad boot drivers will be blocked' }
                                3 { 'Good and unknown' }
                                7 { 'Good, unknown, and bad (but not malicious)' }
                                8 { 'All drivers allowed' }
                                default { "Value=$driverLoadPolicy" }
                            }
                            if ([int]$driverLoadPolicy -eq 1) {
                                & $emit 'UEFI' (& $toSev $sevEarlyLaunchPolicy) "EarlyLaunch DriverLoadPolicy=$driverLoadPolicy ($policyDesc) - restrictive policy may block third-party boot drivers"
                            }
                            else {
                                & $emit 'UEFI' 'OK' "EarlyLaunch DriverLoadPolicy=$driverLoadPolicy ($policyDesc)"
                            }
                        }
                    }

                    # TPM driver state (relevant for vTPM-dependent features)
                    $tpmSvcPath = "$svcRoot\TPM"
                    if (Test-Path $tpmSvcPath) {
                        $tpmStart = (Get-ItemProperty $tpmSvcPath -ErrorAction SilentlyContinue).Start
                        if ($tpmStart -eq 4) {
                            & $emit 'UEFI' (& $toSev $sevTpmDriverDisabled) 'TPM service is DISABLED (Start=4) - vTPM-dependent features (BitLocker auto-unlock, Windows Hello, attestation) will not function'
                        }
                    }
                }

                # -- Session Manager (BootExecute / SetupExecute) -----------------
                $smPath = "$ctrlRoot\Session Manager"
                if (Test-Path $smPath) {
                    $smProps = Get-ItemProperty $smPath -ErrorAction SilentlyContinue
                    $sys32Path = Join-Path $script:WinDriveLetter 'Windows\System32'

                    # BootExecute
                    $bootExec = @($smProps.BootExecute | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
                    $danglingBoot = @()
                    $thirdPartyBoot = @()
                    foreach ($entry in $bootExec) {
                        if ($entry -match '^autocheck\s+autochk') { continue }
                        $nativeName = ($entry -split '\s+', 2)[0]
                        $nativePath = Join-Path $sys32Path "$nativeName.exe"
                        if (-not (Test-Path $nativePath) -or (Test-Path $nativePath) -and (Get-Item -LiteralPath $nativePath -ErrorAction SilentlyContinue).Length -eq 0) {
                            $danglingBoot += $entry
                        }
                        else {
                            $thirdPartyBoot += $entry
                        }
                    }
                    # Signature check on third-party BootExecute entries
                    $unsignedBoot = @()
                    foreach ($entry in $thirdPartyBoot) {
                        $tpName = ($entry -split '\s+', 2)[0]
                        $tpPath = Join-Path $sys32Path "$tpName.exe"
                        $tpSig = Test-MicrosoftSignature -FilePath $tpPath
                        if (-not $tpSig.IsMicrosoft) { $unsignedBoot += $entry }
                    }
                    if ($danglingBoot.Count -gt 0) {
                        & $emit 'Boot' (& $toSev $sevBootExecDangling) "BootExecute has $($danglingBoot.Count) entry/entries with missing binaries (will hang boot at black screen): $($danglingBoot -join '; ')" "-FixSessionManager"
                    }
                    elseif ($unsignedBoot.Count -gt 0) {
                        & $emit 'Security' (& $toSev $sevBinarySignatureBad) "BootExecute has $($unsignedBoot.Count) non-Microsoft-signed entry/entries (possible tampering): $($unsignedBoot -join '; ')" "-FixSessionManager"
                    }
                    elseif ($thirdPartyBoot.Count -gt 0) {
                        & $emit 'Boot' (& $toSev $sevBootExecThirdParty) "BootExecute has $($thirdPartyBoot.Count) third-party entry/entries (binaries present): $($thirdPartyBoot -join '; ')" "-FixSessionManager"
                    }
                    else {
                        & $emit 'Boot' 'OK' 'BootExecute: default (autocheck autochk *)'
                    }

                    # SetupExecute
                    $setupExec = @($smProps.SetupExecute | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
                    if ($setupExec.Count -gt 0) {
                        $danglingSetup = @()
                        $unsignedSetup = @()
                        foreach ($entry in $setupExec) {
                            $nativeName = ($entry -split '\s+', 2)[0]
                            $nativePath = Join-Path $sys32Path "$nativeName.exe"
                            if (-not (Test-Path $nativePath) -or (Test-Path $nativePath) -and (Get-Item -LiteralPath $nativePath -ErrorAction SilentlyContinue).Length -eq 0) {
                                $danglingSetup += $entry
                            }
                            else {
                                $seSig = Test-MicrosoftSignature -FilePath $nativePath
                                if (-not $seSig.IsMicrosoft) { $unsignedSetup += $entry }
                            }
                        }
                        if ($danglingSetup.Count -gt 0) {
                            & $emit 'Boot' (& $toSev $sevSetupExecDangling) "SetupExecute has $($danglingSetup.Count) entry/entries with missing binaries (will hang boot): $($danglingSetup -join '; ')" "-FixSessionManager"
                        }
                        elseif ($unsignedSetup.Count -gt 0) {
                            & $emit 'Security' (& $toSev $sevBinarySignatureBad) "SetupExecute has $($unsignedSetup.Count) non-Microsoft-signed entry/entries (possible tampering): $($unsignedSetup -join '; ')" "-FixSessionManager"
                        }
                        else {
                            & $emit 'Boot' (& $toSev $sevSetupExecPresent) "SetupExecute is non-empty ($($setupExec.Count) entries) - unusual outside servicing: $($setupExec -join '; ')" "-FixSessionManager"
                        }
                    }

                    # ExcludeFromKnownDlls
                    $knownDllExcl = @($smProps.ExcludeFromKnownDlls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
                    if ($knownDllExcl.Count -gt 0) {
                        & $emit 'Security' (& $toSev $sevKnownDllExclude) "ExcludeFromKnownDlls has $($knownDllExcl.Count) entry/entries (app compat or DLL hijack vector): $($knownDllExcl -join ', ')"
                    }
                }

                # -- Static DNS -------------------------------------------------------
                $ifBase = "$SystemRoot\Services\Tcpip\Parameters\Interfaces"
                if (Test-Path $ifBase) {
                    $staticDns = [System.Collections.Generic.List[string]]::new()
                    Get-ChildItem $ifBase -ErrorAction SilentlyContinue | ForEach-Object {
                        $ns = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).NameServer
                        if ($ns) { $staticDns.Add("$($_.PSChildName): $ns") }
                    }
                    $globalNs = (Get-ItemProperty "$SystemRoot\Services\Tcpip\Parameters" -ErrorAction SilentlyContinue).NameServer
                    if ($globalNs) { $staticDns.Add("Global: $globalNs") }
                    if ($staticDns.Count -gt 0) {
                        & $emit 'Networking' (& $toSev $sevStaticDns) "Static DNS server(s) configured on $($staticDns.Count) interface(s) - may not resolve after migration; -ResetNetworkStack clears them" "-ResetNetworkStack"
                    }
                }

                # -- Static IP / DHCP disabled ----------------------------------------
                # Azure requires DHCP for IP assignment. EnableDHCP=0 means the VM
                # keeps a stale on-prem IP and gets zero Azure connectivity.
                if (Test-Path $ifBase) {
                    $staticIpIfs = [System.Collections.Generic.List[string]]::new()
                    Get-ChildItem $ifBase -ErrorAction SilentlyContinue | ForEach-Object {
                        $dhcpVal = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).EnableDHCP
                        if ($null -ne $dhcpVal -and $dhcpVal -eq 0) {
                            $staticIpIfs.Add($_.PSChildName)
                        }
                    }
                    if ($staticIpIfs.Count -gt 0) {
                        & $emit 'Networking' (& $toSev $sevStaticIpNoAzureDhcp) "EnableDHCP=0 on $($staticIpIfs.Count) interface(s) - Azure requires DHCP for IP assignment; VM will have NO connectivity; run -ResetInterfacesToDHCP" "-ResetInterfacesToDHCP"
                    }
                }

                # -- NetworkProvider\Order orphan check --------------------------------
                # If a provider is listed in ProviderOrder but its DLL is missing,
                # Windows hangs indefinitely at logon ("Please wait..." forever).
                # Common after uninstalling VPN software (Cisco AnyConnect, GlobalProtect, Zscaler).
                $npOrderPath = "$ctrlRoot\NetworkProvider\Order"
                if (Test-Path $npOrderPath) {
                    $providerOrder = (Get-ItemProperty $npOrderPath -ErrorAction SilentlyContinue).ProviderOrder
                    if ($providerOrder) {
                        $providers = $providerOrder -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                        $orphanedProviders = [System.Collections.Generic.List[string]]::new()
                        foreach ($prov in $providers) {
                            $provSvcPath = "$svcRoot\$prov\NetworkProvider"
                            if (-not (Test-Path $provSvcPath)) {
                                $orphanedProviders.Add("$prov (service key missing)")
                                continue
                            }
                            $provDllRaw = (Get-ItemProperty $provSvcPath -ErrorAction SilentlyContinue).ProviderPath
                            if (-not $provDllRaw) { continue }
                            # Resolve %SystemRoot% and map to offline drive
                            $provDll = $provDllRaw -replace '(?i)%SystemRoot%', (Join-Path $script:WinDriveLetter 'Windows')
                            $provDll = $provDll -replace '(?i)\\SystemRoot\\', (Join-Path $script:WinDriveLetter 'Windows\')
                            if (-not (Test-Path -LiteralPath $provDll)) {
                                $orphanedProviders.Add("$prov ($provDllRaw -> not found)")
                            }
                        }
                        if ($orphanedProviders.Count -gt 0) {
                            & $emit 'Networking' (& $toSev $sevNetProviderOrphaned) "NetworkProvider\Order lists $($orphanedProviders.Count) provider(s) with missing DLL - logon will hang indefinitely: $($orphanedProviders -join '; ')" "-FixNetBindings"
                        }
                    }
                }

                # -- EMS / Serial Console ---------------------------------------------
                # Check BCD for EMS (done outside hive, but while we're still here)
            } # end & { } child scope - all registry variables die here
        }

        # EMS / Serial Console check (reads BCD store; no hive needed)
        try {
            $bcdPathEms = Get-BcdStorePath -Generation $script:VMGen -BootDrive $script:BootDriveLetter.TrimEnd('\')
            if (Test-Path $bcdPathEms) {
                $emsOut = & bcdedit.exe /store $bcdPathEms /enum "{emssettings}" 2>&1 | Out-String
                if ($emsOut -notmatch 'emsport' -and $emsOut -notmatch 'emsbaudrate') {
                    & $emit 'Boot' (& $toSev $sevEmsDisabled) 'EMS/Serial Console is not configured - enable with -EnableSerialConsole for Azure Serial Console access' "-EnableSerialConsole"
                }
                else {
                    & $emit 'Boot' 'OK' 'EMS/Serial Console is configured'
                }
            }
        }
        catch { <# non-critical #> }

        # -- 5. SOFTWARE hive -----------------------------------------------------
        Write-Host "--- Registry (SOFTWARE hive)" -ForegroundColor DarkGray
        Invoke-WithHive 'SOFTWARE' {
            # Child scope: all variables holding registry data die when this block returns,
            # releasing .NET RegistryKey handles before the finally block calls UnmountOffHive.
            & {
                # OS edition & build
                $ntCv = Get-ItemProperty 'HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
                if ($ntCv) {
                    $build = if ($ntCv.CurrentBuildNumber) { "Build $($ntCv.CurrentBuildNumber).$($ntCv.UBR)" } else { '' }
                    & $emit 'OS' 'INFO' "$($ntCv.ProductName)  |  Edition: $($ntCv.EditionID)  |  $build"
                }

                # CredSSP AllowEncryptionOracle
                $credSsp = (Get-ItemProperty 'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' -ErrorAction SilentlyContinue).AllowEncryptionOracle
                if ($null -ne $credSsp -and $credSsp -ne 2) {
                    $oDesc = switch ($credSsp) { 0 { 'Force Updated Clients (most restrictive)' } 1 { 'Mitigated' } default { "Value=$credSsp" } }
                    & $emit 'RDP' (& $toSev $sevCredSspOracle) "CredSSP AllowEncryptionOracle=$credSsp ($oDesc) - may block RDP from clients without latest patches" "-FixRDPAuth"
                }

                # -- Gen2: BitLocker / FVE policy (SOFTWARE hive side) ----------------
                if ($script:VMGen -eq 2) {
                    $fvePath = 'HKLM:\BROKENSOFTWARE\Policies\Microsoft\FVE'
                    if (Test-Path $fvePath) {
                        $fveProps = Get-ItemProperty $fvePath -ErrorAction SilentlyContinue
                        $useTPM = $fveProps.UseTPM
                        $useTPMPIN = $fveProps.UseTPMPIN
                        $useTPMKey = $fveProps.UseTPMKey
                        $fveDetail = [System.Collections.Generic.List[string]]::new()
                        if ($null -ne $useTPM) { $fveDetail.Add("UseTPM=$useTPM") }
                        if ($null -ne $useTPMPIN) { $fveDetail.Add("UseTPMPIN=$useTPMPIN") }
                        if ($null -ne $useTPMKey) { $fveDetail.Add("UseTPMKey=$useTPMKey") }
                        if ($fveDetail.Count -gt 0) {
                            & $emit 'UEFI' (& $toSev $sevBitLockerActive) "BitLocker FVE policy configured ($($fveDetail -join ', ')) - if BitLocker is active with TPM protector, the disk CANNOT auto-unlock on a different VM; a recovery key is required"
                        }
                    }
                    # Check if BitLocker volume encryption was active via SYSTEM hive marker
                    # FVE filter driver at boot-start is a strong indicator
                    # (fvevol is already tracked in device class filters; emit a targeted Gen2 warning here)
                    $fveVolPath = 'HKLM:\BROKENSOFTWARE\Microsoft\BitLocker'
                    if (Test-Path $fveVolPath) {
                        & $emit 'UEFI' (& $toSev $sevBitLockerActive) 'BitLocker configuration key found (SOFTWARE\\Microsoft\\BitLocker) - if volume is encrypted with vTPM protector, moving the disk or recreating the VM will require the BitLocker recovery key'
                    }
                }

                # AppLocker enforced collections
                $srpBase = 'HKLM:\BROKENSOFTWARE\Policies\Microsoft\Windows\SrpV2'
                $enforcedCols   = @()  # collections with EnforcementMode != 0
                $colsWithRules  = @()  # subset that also contain GUID rule subkeys
                foreach ($col in @('Exe', 'Dll', 'Script', 'Msi', 'Appx')) {
                    $colPath = "$srpBase\$col"
                    if (-not (Test-Path $colPath)) { continue }
                    $mode = (Get-ItemProperty $colPath -ErrorAction SilentlyContinue).EnforcementMode
                    if ($null -eq $mode -or $mode -eq 0) { continue }
                    $enforcedCols += $col
                    # Check for GUID subkeys (each AppLocker rule is stored as a GUID-named subkey)
                    $ruleKeys = @(Get-ChildItem $colPath -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSChildName -match '^\{[0-9a-f-]{36}\}$' })
                    if ($ruleKeys.Count -gt 0) { $colsWithRules += $col }
                }
                $appIdAutoStart = ($script:_sysCheckAppIdSvcStart -eq 2)
                if ($enforcedCols.Count -gt 0) {
                    if ($appIdAutoStart -and $colsWithRules.Count -gt 0) {
                        # CRIT: enforcement configured + service will auto-start + rules exist
                        & $emit 'Security' (& $toSev $sevAppLockerActive) "AppLocker ACTIVE for: $($colsWithRules -join ', ') - EnforcementMode on, AppIDSvc=Auto, rules present - will block processes" "-DisableAppLocker"
                    }
                    elseif ($appIdAutoStart) {
                        # WARN: enforcement configured + service will auto-start (but no rule subkeys found)
                        & $emit 'Security' (& $toSev $sevAppLockerEnforcing) "AppLocker enforcement configured for: $($enforcedCols -join ', ') with AppIDSvc=Auto, but no rule subkeys found - may still enforce default-deny" "-DisableAppLocker"
                    }
                    else {
                        # OK/INFO: enforcement configured but AppIDSvc is not auto-start
                        & $emit 'Security' (& $toSev $sevAppLockerConfigured) "AppLocker EnforcementMode set for: $($enforcedCols -join ', ') but AppIDSvc is not auto-start (Start=$($script:_sysCheckAppIdSvcStart)) - rules will not be enforced at runtime"
                    }
                }
                else {
                    & $emit 'Security' 'OK' 'AppLocker is not enforcing any rule collections'
                }

                # AppIDSvc - if enforcing above, check service state
                # (service state is in SYSTEM hive, checked there; this just notes correlation)

                # NLA policy via Group Policy / TS Policy path (SOFTWARE side)
                $tsPolicyBase = 'HKLM:\BROKENSOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
                if (Test-Path $tsPolicyBase) {
                    $tsPol = Get-ItemProperty $tsPolicyBase -ErrorAction SilentlyContinue
                    if ($null -ne $tsPol.fDenyTSConnections -and $tsPol.fDenyTSConnections -eq 1) {
                        & $emit 'RDP' (& $toSev $sevGpRdpBlocked) 'Group Policy is BLOCKING RDP: Software\Policies\...\Terminal Services fDenyTSConnections=1 - -FixRDP clears this' "-FixRDP"
                    }
                    if ($null -ne $tsPol.UserAuthentication -and $tsPol.UserAuthentication -eq 0) {
                        & $emit 'RDP' (& $toSev $sevGpNlaDisabled) 'Group Policy has disabled NLA (Software\Policies UserAuthentication=0) - this overrides the listener setting'
                    }
                    $sslFuncPath = 'HKLM:\BROKENSOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002'
                    if (Test-Path $sslFuncPath) {
                        $sslFunc = (Get-ItemProperty $sslFuncPath -ErrorAction SilentlyContinue).Functions
                        if ($null -ne $sslFunc) {
                            & $emit 'RDP' (& $toSev $sevSslCipherPolicy) "SSL cipher suite policy (SSL\00010002 Functions) is configured - may restrict TLS cipher suites available to RDP; run -FixRDP to clear" "-FixRDP"
                        }
                    }
                }

                # CBS / Component Based Servicing pending state
                $cbsBase = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
                $cbsIssues = [System.Collections.Generic.List[string]]::new()
                foreach ($cbsKey in @('RebootPending', 'PackagesPending', 'SessionsPending')) {
                    $cbsKeyPath = "$cbsBase\$cbsKey"
                    if (-not (Test-Path $cbsKeyPath)) { continue }

                    # Collect detail: subkey names + any values on the key itself
                    $subkeys = @(Get-ChildItem $cbsKeyPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName)
                    $vals = Get-ItemProperty $cbsKeyPath -ErrorAction SilentlyContinue
                    $valNames = @($vals.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | Select-Object -ExpandProperty Name)

                    $detail = switch ($cbsKey) {
                        'RebootPending' {
                            # Values here are package names pending reboot
                            if ($valNames.Count -gt 0) { "pending package(s): $($valNames[0..([Math]::Min(2,$valNames.Count-1))] -join ', ')$(if ($valNames.Count -gt 3){ " (+$($valNames.Count-3) more)" })" }
                            else { 'key exists (no values)' }
                        }
                        'PackagesPending' {
                            # Subkeys are package names
                            if ($subkeys.Count -gt 0) { "$($subkeys.Count) package(s) pending: $($subkeys[0..([Math]::Min(1,$subkeys.Count-1))] -join ', ')$(if ($subkeys.Count -gt 2){ " (+$($subkeys.Count-2) more)" })" }
                            else { 'key exists (no subkeys)' }
                        }
                        'SessionsPending' {
                            # Each subkey is a CBS session; the Exclusive value indicates a locked session
                            $exclusive = @($subkeys | Where-Object {
                                    $sv = (Get-ItemProperty "$cbsKeyPath\$_" -ErrorAction SilentlyContinue).Exclusive
                                    $null -ne $sv -and $sv -ne 0
                                })
                            if ($exclusive.Count -gt 0) {
                                "EXCLUSIVE session lock(s) present - a CBS operation was interrupted mid-flight; session ID(s): $($exclusive -join ', ')"
                            }
                            elseif ($subkeys.Count -gt 0) {
                                "$($subkeys.Count) session entry(s) - likely a previous CBS transaction that did not complete cleanly; session ID(s): $($subkeys -join ', ')"
                            }
                            else {
                                'key exists (no subkeys) - stale CBS session marker'
                            }
                        }
                    }
                    $cbsIssues.Add("$cbsKey ($detail)")
                }
                if ($cbsIssues.Count -gt 0) {
                    foreach ($issue in $cbsIssues) {
                        # SessionsPending without Exclusive locks is normal on healthy systems - emit INFO only
                        $isSessionInfo = ($issue -match '^SessionsPending' -and $issue -notmatch 'EXCLUSIVE')
                        $level = if ($isSessionInfo) { (& $toSev $sevCbsPendingInfo) } else { (& $toSev $sevCbsPendingWarn) }
                        $suffix = if ($isSessionInfo) { ' (stale entries, no exclusive lock - normal on healthy systems)' } else { " - may cause 'Configuring Windows Updates' boot loop" }
                        $fix = if ($isSessionInfo) { $null } else { '-FixPendingUpdates' }
                        & $emit 'WindowsUpdate' $level "CBS pending state: $issue$suffix" $fix
                    }
                }
                else {
                    & $emit 'WindowsUpdate' 'OK' 'No CBS pending state keys detected'
                }

                # -- Winlogon Shell / Userinit ----------------------------------------
                $wlPath = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                if (Test-Path $wlPath) {
                    $wlProps = Get-ItemProperty $wlPath -ErrorAction SilentlyContinue
                    $wlShell = $wlProps.Shell
                    $wlUserinit = $wlProps.Userinit
                    if ($wlShell -and $wlShell -ne 'explorer.exe') {
                        & $emit 'Security' (& $toSev $sevWinlogonShell) "Winlogon Shell is '$wlShell' (expected 'explorer.exe') - will cause black screen or wrong shell on logon" "-FixWinlogon"
                    }
                    $expectedUi = 'C:\Windows\system32\userinit.exe,'
                    if ($wlUserinit -and $wlUserinit -ne $expectedUi -and $wlUserinit -ne 'C:\Windows\system32\userinit.exe') {
                        & $emit 'Security' (& $toSev $sevWinlogonUserinit) "Winlogon Userinit is '$wlUserinit' (expected default) - may cause logon failure or malware execution" "-FixWinlogon"
                    }
                }

                # -- User Profile List ------------------------------------------------
                $plBase = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
                if (Test-Path $plBase) {
                    $profEntries = Get-ChildItem $plBase -ErrorAction SilentlyContinue
                    foreach ($pf in $profEntries) {
                        $sid = $pf.PSChildName
                        if ($sid -notmatch '^S-1-5-21-') { continue }
                        $bakProfPath = "$plBase\$sid.bak"
                        if (Test-Path $bakProfPath) {
                            $pfPath = (Get-ItemProperty $pf.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
                            & $emit 'UserProfile' (& $toSev $sevProfileBak) "Profile SID $sid has .bak duplicate (path: $pfPath) - user will get 'The User Profile Service failed the sign-in' error" "-FixProfileLoad"
                        }
                        $pfState = (Get-ItemProperty $pf.PSPath -ErrorAction SilentlyContinue).State
                        if ($null -ne $pfState -and ($pfState -band 0x8)) {
                            & $emit 'UserProfile' (& $toSev $sevProfileTempFlag) "Profile SID $sid has temporary profile flag (State=$pfState) - user gets temporary profile on each logon" "-FixProfileLoad"
                        }
                    }
                }

                # -- Image File Execution Options (IFEO) ------------------------------------
                # IFEO keys can contain values that prevent or break process execution:
                #   Debugger     - replaces the process entirely with a debugger; if that binary
                #                  is missing (procdump uninstalled), the service silently fails.
                #   GlobalFlag   - gflags.exe settings. Dangerous flags include:
                #                  0x02000000 = page heap (massive memory, OOM crashes)
                #                  0x00000100 = Application Verifier (crashes if verifier DLLs removed)
                #                  0x00000040 = validate all heap (extreme slowdown -> SCM timeout)
                #   MitigationOptions - forces DEP/ASLR/CFG/SEHOP on binaries that may not
                #                  be compiled for them, causing access violations.
                $ifeoRoot = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
                if (Test-Path $ifeoRoot) {
                    # Critical executables whose IFEO entries would prevent boot or core services
                    $ifeoCriticalExes = @(
                        'svchost.exe', 'services.exe', 'lsass.exe', 'smss.exe', 'csrss.exe',
                        'wininit.exe', 'winlogon.exe', 'logonui.exe', 'dwm.exe',
                        'spoolsv.exe', 'lsm.exe', 'userinit.exe', 'explorer.exe',
                        'rdpclip.exe', 'rdpinit.exe', 'mstsc.exe', 'termsrv.dll',
                        'WaAppAgent.exe', 'WindowsAzureGuestAgent.exe',
                        'WaSecAgentProv.exe'
                    )
                    # GlobalFlag bits that are known to crash or OOM services
                    $dangerousGFlags = @(
                        @{ Mask = 0x02000000; Name = 'FLG_HEAP_PAGE_ALLOCS (page heap)'; Risk = 'massive memory overhead - causes OOM on constrained services' }
                        @{ Mask = 0x00000100; Name = 'FLG_APPLICATION_VERIFIER'; Risk = 'crashes if Application Verifier provider DLLs are missing' }
                        @{ Mask = 0x00000040; Name = 'FLG_HEAP_VALIDATE_ALL'; Risk = 'validates every heap operation - extreme slowdown causes SCM timeout' }
                        @{ Mask = 0x00001000; Name = 'FLG_USER_STACK_TRACE_DB'; Risk = 'stack trace database - significant memory overhead' }
                    )
                    $ifeoCount = 0
                    foreach ($ifeoKey in (Get-ChildItem $ifeoRoot -ErrorAction SilentlyContinue)) {
                        $ifeoProps = Get-ItemProperty $ifeoKey.PSPath -ErrorAction SilentlyContinue
                        $exeName = $ifeoKey.PSChildName
                        $isCritical = $ifeoCriticalExes -contains $exeName

                        # 1. Debugger redirect (most severe - process never runs)
                        $ifeoDebugger = $ifeoProps.Debugger
                        if ($ifeoDebugger) {
                            $dbgBin = ($ifeoDebugger -split '\s+', 2)[0].Trim('"')
                            $dbgResolved = if ($dbgBin -match '^[A-Z]:\\') {
                                $dbgBin -replace '^[A-Z]:\\', "$($script:WinDriveLetter)"
                            } else { $null }
                            $dbgExists = $dbgResolved -and (Test-Path -LiteralPath $dbgResolved)
                            $existsTag = if ($dbgResolved) { if ($dbgExists) { 'binary exists' } else { 'BINARY MISSING' } } else { 'path not resolvable' }
                            $sev = if ($isCritical) { (& $toSev $sevIFEODebugger) } else { (& $toSev $sevIFEODebuggerNonCritical) }
                            $impact = if ($isCritical) { 'CRITICAL - service/process will not start' } else { 'process will launch debugger instead of running normally' }
                            & $emit 'IFEO' $sev "IFEO Debugger on $exeName -> '$ifeoDebugger' ($existsTag) - $impact"
                            $ifeoCount++
                        }

                        # 2. GlobalFlag (second most common - gflags/page heap/app verifier leftovers)
                        $gfValue = $ifeoProps.GlobalFlag
                        if ($null -ne $gfValue -and [int]$gfValue -ne 0) {
                            $gfInt = [int]$gfValue
                            $gfHex = '0x{0:X8}' -f $gfInt
                            $hitFlags = @()
                            foreach ($df in $dangerousGFlags) {
                                if ($gfInt -band $df.Mask) { $hitFlags += "$($df.Name) - $($df.Risk)" }
                            }
                            if ($hitFlags.Count -gt 0) {
                                $sev = if ($isCritical) { (& $toSev $sevIFEOGlobalFlag) } else { (& $toSev $sevIFEOGlobalFlagNonCritical) }
                                foreach ($hf in $hitFlags) {
                                    & $emit 'IFEO' $sev "IFEO GlobalFlag on $exeName ($gfHex): $hf"
                                }
                                $ifeoCount++
                            }
                        }

                    }
                    if ($ifeoCount -eq 0) {
                        & $emit 'IFEO' 'OK' 'No IFEO debugger redirects or GlobalFlag overrides found'
                    }
                }

                # -- Startup Programs (Run/RunOnce) -----------------------------------
                $runPaths = @(
                    'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Run'
                    'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
                )
                $startupEntries = [System.Collections.Generic.List[string]]::new()
                foreach ($rp in $runPaths) {
                    if (-not (Test-Path $rp)) { continue }
                    $rpProps = Get-ItemProperty $rp -ErrorAction SilentlyContinue
                    foreach ($rpv in ($rpProps.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                        $startupEntries.Add("$($rpv.Name)")
                    }
                }
                if ($startupEntries.Count -gt 0) {
                    & $emit 'Startup' (& $toSev $sevStartupPrograms) "$($startupEntries.Count) auto-start entry(s) in HKLM Run/RunOnce: $($startupEntries -join ', ') - use -ListStartupPrograms to review" "-ListStartupPrograms"
                }

                # -- Machine proxy/PAC ------------------------------------------------
                $inetPath = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
                if (Test-Path $inetPath) {
                    $inetProps = Get-ItemProperty $inetPath -ErrorAction SilentlyContinue
                    if ($inetProps.ProxyEnable -eq 1 -or $inetProps.ProxyServer -or $inetProps.AutoConfigURL) {
                        $proxyDetail = @()
                        if ($inetProps.ProxyServer) { $proxyDetail += "ProxyServer='$($inetProps.ProxyServer)'" }
                        if ($inetProps.AutoConfigURL) { $proxyDetail += "AutoConfigURL='$($inetProps.AutoConfigURL)'" }
                        if ($inetProps.ProxyEnable -eq 1) { $proxyDetail += 'ProxyEnable=1' }
                        & $emit 'Networking' (& $toSev $sevProxyConfigured) "Machine-level proxy configured: $($proxyDetail -join ', ') - may block Azure agent and remote management" "-ClearProxyState"
                    }
                }
            } # end & { } child scope - all registry variables die here
        }

        # -- 6. Azure Agent binaries on disk --------------------------------------
        Write-Host "--- Azure VM Agent" -ForegroundColor DarkGray
        $azureDir = Join-Path $script:WinDriveLetter 'WindowsAzure'
        if (Test-Path $azureDir) {
            $gaDirs = @(Get-ChildItem $azureDir -Filter 'GuestAgent_*' -Directory -ErrorAction SilentlyContinue)
            if ($gaDirs.Count -gt 0) {
                & $emit 'AzureAgent' 'OK' "Agent binaries present: $($gaDirs[-1].Name)"
            }
            else {
                & $emit 'AzureAgent' (& $toSev $sevAzureAgentMissing) 'WindowsAzure folder exists but no GuestAgent_* subfolder found' "-InstallAzureVMAgent"
            }
        }
        else {
            & $emit 'AzureAgent' (& $toSev $sevAzureAgentMissing) "WindowsAzure folder not found on $script:WinDriveLetter - VM Agent may not be installed" "-InstallAzureVMAgent"
        }

        # -- 7. RDP private key / MachineKeys -------------------------------------
        Write-Host "--- RDP Certificate & MachineKeys" -ForegroundColor DarkGray
        $machineKeysPath = Join-Path $script:WinDriveLetter 'ProgramData\Microsoft\Crypto\RSA\MachineKeys'
        if (Test-Path $machineKeysPath) {
            # The RDP private key file has a well-known name prefix f686aace6942fb7f7ceb231212eef4a4
            $rdpKeyFiles = @(Get-ChildItem $machineKeysPath -Filter 'f686aace6942fb7f7ceb231212eef4a4*' -ErrorAction SilentlyContinue)
            if ($rdpKeyFiles.Count -gt 0) {
                & $emit 'RDP' 'OK' "RDP private key file present ($($rdpKeyFiles[0].Name))"

                # Check ACLs on the key file. Required principals (matched by well-known SID):
                #   S-1-5-18  = NT AUTHORITY\SYSTEM        -> needs FullControl
                #   S-1-5-20  = NT AUTHORITY\NETWORK SERVICE -> needs at least Read (TermService runs as this)
                #   S-1-5-80-* matching SessionEnv service  -> needs FullControl (checked by display name)
                try {
                    $keyAcl = Get-Acl -Path $rdpKeyFiles[0].FullName -ErrorAction Stop
                    $rules = $keyAcl.Access

                    $sidSystem = [System.Security.Principal.SecurityIdentifier]'S-1-5-18'
                    $sidNetSvc = [System.Security.Principal.SecurityIdentifier]'S-1-5-20'

                    $systemOk = $rules | Where-Object {
                        try { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $sidSystem } catch { $false }
                    } | Where-Object { $_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl }

                    $netSvcOk = $rules | Where-Object {
                        try { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $sidNetSvc } catch { $false }
                    } | Where-Object { $_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Read }

                    # SessionEnv runs as NT Service\SessionEnv - no fixed SID, match by identity string
                    $sessionEnvOk = $rules | Where-Object {
                        $_.IdentityReference.Value -match 'SessionEnv'
                    } | Where-Object { $_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl }

                    if (-not $systemOk) {
                        & $emit 'RDP' (& $toSev $sevRdpKeySystemAcl) "RDP private key: NT AUTHORITY\SYSTEM does not have FullControl - RDP service may fail to use the certificate" "-FixRDPPermissions"
                    }
                    if (-not $netSvcOk) {
                        & $emit 'RDP' (& $toSev $sevRdpKeyNetSvcAcl) "RDP private key: NT AUTHORITY\NETWORK SERVICE does not have Read access - TermService will fail to load the RDP certificate" "-FixRDPPermissions"
                    }
                    else {
                        & $emit 'RDP' 'OK' 'RDP private key ACLs: SYSTEM and NETWORK SERVICE have required permissions'
                    }
                    if (-not $sessionEnvOk) {
                        & $emit 'RDP' (& $toSev $sevRdpKeySessionEnvAcl) 'RDP private key: NT Service\SessionEnv FullControl not found - may cause RDP session issues on some Windows versions' "-FixRDPPermissions"
                    }
                }
                catch {
                    & $emit 'RDP' 'INFO' "Could not read ACLs on RDP private key file: $_"
                }
            }
            else {
                & $emit 'RDP' (& $toSev $sevRdpKeyFileMissing) 'RDP private key file (f686aace...) not found in MachineKeys - RDP certificate will need to be regenerated' "-FixRDPCert"
            }
            # Check for zero-length or suspiciously small key files (corrupted)
            $emptyKeys = @(Get-ChildItem $machineKeysPath -ErrorAction SilentlyContinue | Where-Object { $_.Length -eq 0 })
            if ($emptyKeys.Count -gt 0) {
                & $emit 'RDP' (& $toSev $sevRdpKeyZeroLength) "$($emptyKeys.Count) zero-length file(s) found in MachineKeys - may indicate corrupted key store; run -FixRDPPermissions" "-FixRDPPermissions"
            }
        }
        else {
            & $emit 'RDP' (& $toSev $sevMachineKeysMissing) 'MachineKeys folder missing - RDP certificate operations will fail on boot' "-FixRDPPermissions"
        }

        # -- Summary --------------------------------------------------------------
        $crits = @($findings | Where-Object Severity -eq 'CRIT')
        $warns = @($findings | Where-Object Severity -eq 'WARN')
        $infos = @($findings | Where-Object Severity -eq 'INFO')
        $oks = @($findings | Where-Object Severity -eq 'OK')

        Write-Host "`n===================================================================" -ForegroundColor Cyan
        Write-Host "  System Check Summary  -  $($crits.Count) critical  /  $($warns.Count) warnings  /  $($infos.Count) info  /  $($oks.Count) ok" -ForegroundColor Cyan
        Write-Host "===================================================================" -ForegroundColor Cyan

        if ($crits.Count -gt 0) {
            Write-Host "`nCRITICAL - likely preventing boot or connectivity:" -ForegroundColor Red
            foreach ($f in $crits) {
                Write-Host "  [$($f.Category)] $($f.Description)" -ForegroundColor Red
                if ($f.Fix) { Write-Host "    > .\$scriptFile -DiskNumber $script:DiskNumber $($f.Fix)" -ForegroundColor DarkCyan }
            }
        }
        if ($warns.Count -gt 0) {
            Write-Host "`nWARNINGS - should be investigated:" -ForegroundColor Yellow
            foreach ($f in $warns) {
                Write-Host "  [$($f.Category)] $($f.Description)" -ForegroundColor Yellow
                if ($f.Fix) { Write-Host "    > .\$scriptFile -DiskNumber $script:DiskNumber $($f.Fix)" -ForegroundColor DarkCyan }
            }
        }
        if ($crits.Count -eq 0 -and $warns.Count -eq 0) {
            Write-Host "`nNo critical issues or warnings detected." -ForegroundColor Green
        }

        Write-Host ""
        Write-ActionLog -Event 'RunSystemCheck' -Details @{
            Critical = $crits.Count
            Warnings = $warns.Count
            Findings = ($findings | ForEach-Object { "$($_.Severity)[$($_.Category)] $($_.Description)" }) -join ' | '
        }
    }

    function ResetNetworkStack {
        Write-Host "Placing network stack reset script to run at next boot..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name SetupType -Value 2 -Type DWord -Force
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name CmdLine -Value "cmd.exe /c c:\temp\resetnet.cmd" -Type String -Force

            # Also reset DNS client settings to DHCP defaults across all interfaces offline
            $SystemRoot = Get-SystemRootPath
            $ifBase = "$SystemRoot\Services\Tcpip\Parameters\Interfaces"
            if (Test-Path $ifBase) {
                $ifCount = 0
                Get-ChildItem $ifBase -ErrorAction SilentlyContinue | ForEach-Object {
                    $ifProps = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                    $changed = $false
                    # Remove statically configured DNS servers (NameServer); leave DhcpNameServer untouched
                    if ($ifProps.NameServer) {
                        Write-Host "  Interface $($_.PSChildName): clearing static DNS ($($ifProps.NameServer))" -ForegroundColor Yellow
                        Set-ItemProperty-Logged -Path $_.PSPath -Name NameServer -Value '' -Type String -Force
                        $changed = $true
                    }
                    if ($changed) { $ifCount++ }
                }
                # Also clear the global NameServer override
                $tcpParams = "$SystemRoot\Services\Tcpip\Parameters"
                $globalNs = (Get-ItemProperty $tcpParams -ErrorAction SilentlyContinue).NameServer
                if ($globalNs) {
                    Write-Host "  Global Tcpip\Parameters: clearing static DNS ($globalNs)" -ForegroundColor Yellow
                    Set-ItemProperty-Logged -Path $tcpParams -Name NameServer -Value '' -Type String -Force
                }
                if ($ifCount -gt 0 -or $globalNs) {
                    Write-Host "  DNS settings reset to DHCP defaults on $ifCount interface(s)." -ForegroundColor Green
                }
                else {
                    Write-Host "  No static DNS settings found (already using DHCP)." -ForegroundColor DarkGray
                }
            }

            $netScript = @"
@echo off
netsh int ip reset C:\temp\netsh_ip_reset.log
netsh winsock reset
netsh advfirewall reset
rem Re-enable critical inbound rules that advfirewall reset disables by default
netsh advfirewall firewall set rule group="remote desktop" new enable=yes
netsh advfirewall firewall set rule group="file and printer sharing" new enable=yes
netsh advfirewall firewall set rule group="windows remote management" new enable=yes
ipconfig /flushdns
reg add "HKLM\SYSTEM\Setup" /v SetupType /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\Setup" /v CmdLine /t REG_SZ /d "" /f
del /F C:\Temp\resetnet.cmd > NUL
shutdown /r /t 10 /c "Network stack reset complete - rebooting"
"@
            Ensure-GuestTempDir
            New-Item-Logged -Path "$script:WinDriveLetter\Temp" -Name "resetnet.cmd" -ItemType File -Value $netScript.Trim() -Force

            Write-Host "Network stack reset script placed. On next boot: IP stack, Winsock, firewall and DNS cache will be reset, then VM will reboot automatically." -ForegroundColor Green
        }
    }

    function DisableWindowsUpdate {
        Write-Host "Disabling Windows Update services to prevent boot loops from update processing..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath

            $services = @('wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'UpdateOrchestrator')
            foreach ($svc in $services) {
                $svcPath = "$SystemRoot\Services\$svc"
                if (Test-Path $svcPath) {
                    $before = (Get-ItemProperty $svcPath -ErrorAction SilentlyContinue).Start
                    Set-ItemProperty-Logged -Path $svcPath -Name Start -Value 4 -Type DWord -Force
                    Write-Host "  $svc disabled (was $before)" -ForegroundColor Yellow
                }
            }

            Write-Host "Windows Update services disabled. Re-enable them after recovery." -ForegroundColor Green
            Write-Host "`n--- REVERT COMMANDS (run on the VM after recovery) ---" -ForegroundColor Cyan
            Write-Host "Set-Service wuauserv -StartupType Automatic" -ForegroundColor White
            Write-Host "Set-Service UsoSvc   -StartupType Automatic" -ForegroundColor White
            Write-Host "# Or use: sc.exe config wuauserv start= auto" -ForegroundColor DarkGray
            Write-Host "------------------------------------------------------`n" -ForegroundColor Cyan
        }
    }

    function RestoreRegistryFromRegBack {
        if (-not (Confirm-CriticalOperation -Operation 'Restore Registry from RegBack (-RestoreRegistryFromRegBack)' -Details @"
Replaces the live SYSTEM and SOFTWARE hives with the RegBack copies.
The current hives and their transaction log files (.LOG/.LOG1/.LOG2) are renamed to *.bak before overwriting.
"@)) { return }

        Write-Host "Attempting to restore SYSTEM and SOFTWARE hives from RegBack..." -ForegroundColor Yellow
        $regBackPath = Join-Path $script:WinDriveLetter "Windows\System32\config\RegBack"
        $configPath = Join-Path $script:WinDriveLetter "Windows\System32\config"

        if (-not (Test-Path $regBackPath)) {
            Write-Warning "RegBack folder not found at $regBackPath. Cannot restore."
            return
        }

        $hives = @('SYSTEM', 'SOFTWARE')
        foreach ($hive in $hives) {
            $backupFile = Join-Path $regBackPath $hive
            $liveFile = Join-Path $configPath  $hive

            if (-not (Test-Path $backupFile)) {
                Write-Warning "  RegBack copy of $hive not found - skipping."
                continue
            }

            $backupSize = (Get-Item $backupFile).Length
            if ($backupSize -lt 1MB) {
                Write-Warning "  RegBack $hive is suspiciously small ($backupSize bytes) - skipping to avoid overwriting with empty hive."
                continue
            }

            Write-Host "  Restoring $hive ($([math]::Round($backupSize/1MB,1)) MB)..." -ForegroundColor Yellow
            $bakPath = New-UniqueBackupPath -BasePath $liveFile -BakSuffix ".bak"
            Move-Item-Logged -LiteralPath $liveFile -Destination $bakPath -Force
            Copy-Item-Logged -Path $backupFile -Destination $liveFile -Force
            Write-Host "  $hive restored. Previous live hive backed up to $bakPath" -ForegroundColor Green

            # Rename stale transaction logs so Windows starts fresh logging against the restored hive.
            # Leaving old logs risks Windows replaying stale transactions from the previous (newer) hive
            # onto the restored snapshot, which can silently re-corrupt it.
            foreach ($logSuffix in @('.LOG', '.LOG1', '.LOG2')) {
                $logPath = Join-Path $configPath "$hive$logSuffix"
                if (Test-Path -LiteralPath $logPath) {
                    $logBak = New-UniqueBackupPath -BasePath $logPath -BakSuffix '.bak'
                    Move-Item-Logged -LiteralPath $logPath -Destination $logBak -Force
                    Write-Host "    Renamed $hive$logSuffix -> $(Split-Path $logBak -Leaf)" -ForegroundColor DarkGray
                }
            }
        }
        Write-Host "RegBack restore complete. Boot the VM to verify." -ForegroundColor Green
    }

    function SetTestSigning {
        param([bool]$Enable)
        $action = if ($Enable) { "Enabling" } else { "Disabling" }
        Write-Host "$action test signing mode..." -ForegroundColor Yellow
        try {
            $storePath = Get-BcdStorePath -Generation $script:VMGen -BootDrive $script:BootDriveLetter
            $identifier = Get-BcdBootLoaderId -StorePath $storePath
            if (-not $identifier) { return }

            $val = if ($Enable) { "on" } else { "off" }
            Invoke-BcdEdit -StorePath $storePath -Command "/set $identifier testsigning $val"

            if ($Enable) {
                Write-Warning "Test signing is now ENABLED. This reduces security by allowing unsigned drivers. Disable after recovery with -DisableTestSigning."
            }
            else {
                Write-Host "Test signing disabled." -ForegroundColor Green
            }
        }
        catch {
            Write-Error "SetTestSigning failed: $_"
            throw
        }
    }

    function CheckDiskHealth {
        Write-Host "`nDisk Health Report" -ForegroundColor Cyan
        Write-Host "==================" -ForegroundColor Cyan

        $targetDisk = Get-Disk -Number $script:DiskNumber -ErrorAction SilentlyContinue
        if (-not $targetDisk) { Write-Warning "Could not retrieve disk info."; return }

        Write-Host "Disk $script:DiskNumber: $($targetDisk.FriendlyName)"
        Write-Host "  Style      : $($targetDisk.PartitionStyle)"
        Write-Host "  Size       : $([math]::Round($targetDisk.Size/1GB,2)) GB"
        Write-Host "  Health     : $($targetDisk.HealthStatus)"
        Write-Host "  Operational: $($targetDisk.OperationalStatus)"

        $partitions = Get-Partition -DiskNumber $script:DiskNumber -ErrorAction SilentlyContinue
        Write-Host "`nPartitions:" -ForegroundColor Cyan
        foreach ($p in $partitions) {
            $sizeMB = [math]::Round($p.Size / 1MB)
            $letter = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { "(no letter)" }
            $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue
            $fs = if ($vol) { $vol.FileSystemType } else { "N/A" }
            $health = if ($vol) { $vol.HealthStatus } else { "N/A" }
            $raw = if ($fs -eq 'Unknown' -or $fs -eq '') { " !!! RAW FILESYSTEM - data may be inaccessible" } else { "" }

            $color = if ($raw) { 'Red' } elseif ($health -ne 'Healthy' -and $health -ne 'N/A') { 'Yellow' } else { 'White' }
            Write-Host ("  Partition {0,2}: {1,-10} | {2,-12} | {3} MB | FS: {4,-8} | Health: {5}{6}" -f `
                    $p.PartitionNumber, $letter, $p.Type, $sizeMB, $fs, $health, $raw) -ForegroundColor $color
        }
        Write-Host ""
        Write-Host "Windows drive : $script:WinDriveLetter"  -ForegroundColor Green
        Write-Host "Boot drive    : $script:BootDriveLetter" -ForegroundColor Green
        Write-Host "VM Generation : Gen$script:VMGen"        -ForegroundColor Green
        Write-Host ""

        Invoke-Logged -Description "CheckDiskHealth" -Details @{ Disk = $script:DiskNumber; PartitionCount = $partitions.Count } -ScriptBlock { "OK" } | Out-Null
    }

    function CollectEventLogs {
        $destBase = if (Test-Path "C:\temp") { "C:\temp" } else { New-Item "C:\temp" -ItemType Directory -Force | Select-Object -ExpandProperty FullName }
        $destFolder = Join-Path $destBase "GuestEventLogs_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -Path $destFolder -ItemType Directory -Force | Out-Null

        Write-Host "Collecting guest event logs to $destFolder ..." -ForegroundColor Yellow

        $logSources = @(
            @{ Src = "$script:WinDriveLetter\Windows\System32\winevt\Logs\System.evtx"; Dst = "System.evtx" },
            @{ Src = "$script:WinDriveLetter\Windows\System32\winevt\Logs\Application.evtx"; Dst = "Application.evtx" },
            @{ Src = "$script:WinDriveLetter\Windows\System32\winevt\Logs\Security.evtx"; Dst = "Security.evtx" },
            @{ Src = "$script:WinDriveLetter\Windows\inf\setupapi.dev.log"; Dst = "setupapi.dev.log" },
            @{ Src = "$script:WinDriveLetter\Windows\inf\setupapi.setup.log"; Dst = "setupapi.setup.log" },
            @{ Src = "$script:WinDriveLetter\Windows\ntbtlog.txt"; Dst = "ntbtlog.txt" },
            @{ Src = "$script:WinDriveLetter\Windows\Minidump"; Dst = "Minidump" }
        )

        foreach ($log in $logSources) {
            if (Test-Path $log.Src) {
                $dstPath = Join-Path $destFolder $log.Dst
                Copy-Item-Logged -Path $log.Src -Destination $dstPath -Recurse -Force
                Write-Host "  Copied: $($log.Dst)" -ForegroundColor Green
            }
            else {
                Write-Host "  Not found (skipped): $($log.Dst)" -ForegroundColor DarkGray
            }
        }

        Write-Host "Event logs collected to: $destFolder" -ForegroundColor Green
        Write-Host "Tip: Use 'Get-WinEvent -Path <.evtx>' or Event Viewer to open .evtx files from the host." -ForegroundColor DarkCyan
    }

    function ResetUserRights {
        Invoke-WithHive 'SYSTEM' {
            Write-Host "Configuring setup and adding script..." -ForegroundColor Green
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name SetupType -Value 2 -Type DWord -Force
            Set-ItemProperty-Logged -Path "HKLM:\BROKENSYSTEM\Setup" -Name CmdLine -Value "cmd.exe /c c:\temp\resetuserrights.cmd" -Type String -Force

            $resetuserrights = @"
@echo off
secedit /export /areas USER_RIGHTS /cfg C:\temp\UserRightsBefore.txt
secedit /configure /cfg C:\Windows\inf\defltbase.inf /db defltbase.sdb /verbose
secedit /export /areas USER_RIGHTS /cfg C:\temp\UserRightsAfter.txt
reg add "HKLM\SYSTEM\Setup" /v SetupType /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\Setup" /v CmdLine /t REG_SZ /d "" /f
del /F C:\temp\resetuserrights.cmd > NUL
"@

            Ensure-GuestTempDir
            New-Item-Logged -Path "$WinDriveLetter\Temp" -Name "resetuserrights.cmd" -ItemType File -Value $resetuserrights.ToString().Trim() -Force
        }
    }

    function DisableDriverVerifier {
        Write-Host "Disabling Driver Verifier on offline guest..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath
            $mmPath = "$SystemRoot\Control\Session Manager\Memory Management"
            $verifyPath = "$SystemRoot\Services\VeriDrv"

            if (Test-Path $mmPath) {
                $verifyDrivers = (Get-ItemProperty $mmPath -ErrorAction SilentlyContinue).VerifyDrivers
                $verifyLevel = (Get-ItemProperty $mmPath -ErrorAction SilentlyContinue).VerifyDriverLevel
                if ($verifyDrivers -or $verifyLevel) {
                    Write-Host "  Current VerifyDrivers : $verifyDrivers" -ForegroundColor White
                    Write-Host "  Current VerifyDriverLevel : $verifyLevel" -ForegroundColor White
                    Set-ItemProperty-Logged -Path $mmPath -Name VerifyDrivers -Value '' -Type String -Force
                    Remove-ItemProperty-Logged -Path $mmPath -Name VerifyDriverLevel -ErrorAction SilentlyContinue
                    Write-Host "  [OK] Driver Verifier settings cleared." -ForegroundColor Green
                }
                else {
                    Write-Host "  Driver Verifier is not configured (VerifyDrivers and VerifyDriverLevel not set)." -ForegroundColor DarkGray
                }
            }

            # Also clear the verifier service if it is set to start
            if (Test-Path $verifyPath) {
                $vStart = (Get-ItemProperty $verifyPath -ErrorAction SilentlyContinue).Start
                if ($null -ne $vStart -and $vStart -ne 4) {
                    Set-ItemProperty-Logged -Path $verifyPath -Name Start -Value 4 -Type DWord -Force
                    Write-Host "  VeriDrv service disabled (Start=4)." -ForegroundColor Green
                }
            }

            Write-Host "Driver Verifier disabled. The VM will no longer enforce verification on boot." -ForegroundColor Green
        }
    }

    function EnableDriverVerifier {
        param([string]$DriverList)
        Write-Host "Enabling Driver Verifier on offline guest..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath
            $mmPath = "$SystemRoot\Control\Session Manager\Memory Management"
            $verifyPath = "$SystemRoot\Services\VeriDrv"

            if (-not (Test-Path $mmPath)) {
                throw "Memory Management key not found: $mmPath"
            }

            # Determine driver list to verify
            $drivers = if (-not [string]::IsNullOrWhiteSpace($DriverList)) {
                # User supplied specific drivers
                ($DriverList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
            }
            else {
                # Default: verify all drivers
                '*'
            }

            # Standard verification level 0x209BB = standard flags
            # (Pool Tracking + Force IRQL Checking + Deadlock Detection + I/O Verification +
            #  DMA Checking + Security Checks + Miscellaneous Checks + DDI compliance)
            $standardLevel = 0x209BB

            # Show current state
            $currentDrivers = (Get-ItemProperty $mmPath -ErrorAction SilentlyContinue).VerifyDrivers
            $currentLevel = (Get-ItemProperty $mmPath -ErrorAction SilentlyContinue).VerifyDriverLevel
            if ($currentDrivers -or $currentLevel) {
                Write-Host "  Current VerifyDrivers     : $currentDrivers" -ForegroundColor DarkGray
                Write-Host "  Current VerifyDriverLevel : $currentLevel" -ForegroundColor DarkGray
            }

            # Set verifier settings
            Set-ItemProperty-Logged -Path $mmPath -Name VerifyDrivers -Value $drivers -Type String -Force
            Set-ItemProperty-Logged -Path $mmPath -Name VerifyDriverLevel -Value $standardLevel -Type DWord -Force
            Write-Host "  [OK] VerifyDrivers set to: $drivers" -ForegroundColor Green
            Write-Host "  [OK] VerifyDriverLevel set to: 0x$($standardLevel.ToString('X'))" -ForegroundColor Green

            # Enable the VeriDrv service (Start=3 = Manual/Demand)
            if (Test-Path $verifyPath) {
                $vStart = (Get-ItemProperty $verifyPath -ErrorAction SilentlyContinue).Start
                if ($null -eq $vStart -or $vStart -eq 4) {
                    Set-ItemProperty-Logged -Path $verifyPath -Name Start -Value 3 -Type DWord -Force
                    Write-Host "  VeriDrv service enabled (Start=3)." -ForegroundColor Green
                }
            }

            Write-Host "Driver Verifier enabled. The VM will enforce standard verification on next boot." -ForegroundColor Green
            if ($drivers -eq '*') {
                Write-Warning "All drivers will be verified. This may cause significant performance impact. Use -EnableDriverVerifier 'driver1.sys,driver2.sys' to target specific drivers."
            }
        }
    }

    function CollectMinidumps {
        $destBase = if (Test-Path "C:\temp") { "C:\temp" } else { New-Item "C:\temp" -ItemType Directory -Force | Select-Object -ExpandProperty FullName }
        $destFolder = Join-Path $destBase "Minidumps_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

        Write-Host "Collecting crash dump files from guest disk..." -ForegroundColor Yellow

        $sources = @(
            @{ Path = Join-Path $script:WinDriveLetter 'Windows\Minidump'; Desc = 'Minidump folder' }
            @{ Path = Join-Path $script:WinDriveLetter 'Windows\MEMORY.DMP'; Desc = 'Full memory dump (MEMORY.DMP)' }
            @{ Path = Join-Path $script:WinDriveLetter 'Windows\LiveKernelReports'; Desc = 'Live Kernel Reports' }
        )

        $anyFound = $false
        foreach ($src in $sources) {
            if (Test-Path $src.Path) {
                if (-not $anyFound) {
                    New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
                    $anyFound = $true
                }
                $dstPath = Join-Path $destFolder (Split-Path $src.Path -Leaf)
                Copy-Item-Logged -Path $src.Path -Destination $dstPath -Recurse -Force
                $size = if ((Get-Item $src.Path).PSIsContainer) {
                    $files = @(Get-ChildItem $src.Path -Recurse -File -ErrorAction SilentlyContinue)
                    "$($files.Count) file(s), $([math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 1)) MB"
                }
                else {
                    "$([math]::Round((Get-Item $src.Path).Length / 1MB, 1)) MB"
                }
                Write-Host "  Copied: $($src.Desc) ($size)" -ForegroundColor Green
            }
            else {
                Write-Host "  Not found (skipped): $($src.Desc)" -ForegroundColor DarkGray
            }
        }

        if ($anyFound) {
            Write-Host "Crash dumps collected to: $destFolder" -ForegroundColor Green
            Write-Host "Tip: Use WinDbg or 'dumpchk.exe <file.dmp>' to analyse crash dumps." -ForegroundColor DarkCyan
        }
        else {
            Write-Host "No crash dump files found on the guest disk." -ForegroundColor DarkGray
        }
    }

    function ResetGroupPolicy {
        if (-not (Confirm-CriticalOperation -Operation 'Reset Group Policy (-ResetGroupPolicy)' -Details @"
Deletes the local Group Policy cache folders:
  \Windows\System32\GroupPolicy\*
  \Windows\System32\GroupPolicyUsers\*
And clears cached HKLM\SOFTWARE\Policies keys.
On next boot, local policies will revert to defaults.
Domain-joined VMs will re-download GPOs on next gpupdate cycle.
"@)) { return }

        Write-Host "Resetting local Group Policy..." -ForegroundColor Yellow

        $gpPaths = @(
            (Join-Path $script:WinDriveLetter 'Windows\System32\GroupPolicy')
            (Join-Path $script:WinDriveLetter 'Windows\System32\GroupPolicyUsers')
        )
        foreach ($gp in $gpPaths) {
            if (Test-Path $gp) {
                $items = @(Get-ChildItem $gp -Recurse -Force -ErrorAction SilentlyContinue)
                Remove-Item-Logged -Path "$gp\*" -Recurse -Force
                Write-Host "  Cleared: $gp ($($items.Count) items)" -ForegroundColor Green
            }
            else {
                Write-Host "  Not found (skipped): $gp" -ForegroundColor DarkGray
            }
        }

        # Clear cached policy keys in SOFTWARE hive
        Invoke-WithHive 'SOFTWARE' {
            & {
                $polPath = 'HKLM:\BROKENSOFTWARE\Policies'
                if (Test-Path $polPath) {
                    $subKeys = @(Get-ChildItem $polPath -ErrorAction SilentlyContinue)
                    if ($subKeys.Count -gt 0) {
                        foreach ($sk in $subKeys) {
                            Remove-Item-Logged -Path $sk.PSPath -Recurse -Force
                        }
                        Write-Host "  Cleared SOFTWARE\Policies ($($subKeys.Count) top-level keys)" -ForegroundColor Green
                    }
                }
            }
        }

        Write-Host "Group Policy reset complete. On next boot, local policies will be factory defaults." -ForegroundColor Green
        Write-Host "  Domain-joined VMs will re-apply domain GPOs on next Group Policy refresh." -ForegroundColor DarkCyan
    }

    function FixWinlogon {
        Write-Host "Resetting Winlogon shell and Userinit to Windows defaults..." -ForegroundColor Yellow
        Invoke-WithHive 'SOFTWARE' {
            $wlPath = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            if (-not (Test-Path $wlPath)) {
                Write-Warning "Winlogon key not found at $wlPath."
                return
            }

            $currentShell = (Get-ItemProperty $wlPath -ErrorAction SilentlyContinue).Shell
            $currentUserinit = (Get-ItemProperty $wlPath -ErrorAction SilentlyContinue).Userinit

            Write-Host "  Current Shell   : $currentShell" -ForegroundColor White
            Write-Host "  Current Userinit: $currentUserinit" -ForegroundColor White

            $changed = $false
            if ($currentShell -ne 'explorer.exe') {
                Set-ItemProperty-Logged -Path $wlPath -Name Shell -Value 'explorer.exe' -Type String -Force
                Write-Host "  [FIXED] Shell -> explorer.exe" -ForegroundColor Green
                $changed = $true
            }
            # Standard Userinit value (must end with comma)
            $expectedUserinit = 'C:\Windows\system32\userinit.exe,'
            if ($currentUserinit -ne $expectedUserinit) {
                Set-ItemProperty-Logged -Path $wlPath -Name Userinit -Value $expectedUserinit -Type String -Force
                Write-Host "  [FIXED] Userinit -> $expectedUserinit" -ForegroundColor Green
                $changed = $true
            }

            if (-not $changed) {
                Write-Host "  Winlogon Shell and Userinit are already at default values." -ForegroundColor DarkGray
            }
        }
    }

    function FixProfileLoad {
        Write-Host "Scanning user profile list for corrupted entries..." -ForegroundColor Yellow
        Invoke-WithHive 'SOFTWARE' {
            $plBase = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
            if (-not (Test-Path $plBase)) {
                Write-Warning "ProfileList key not found."
                return
            }

            $profiles = Get-ChildItem $plBase -ErrorAction SilentlyContinue
            $fixCount = 0

            foreach ($prof in $profiles) {
                $sid = $prof.PSChildName
                # Only process user SIDs (S-1-5-21-*)
                if ($sid -notmatch '^S-1-5-21-') { continue }

                $bakPath = "$plBase\$sid.bak"
                $hasBak = Test-Path $bakPath

                if ($hasBak) {
                    # The .bak duplicate is the corrupt one; the primary has the wrong profile
                    # Fix: rename primary to .old, rename .bak to primary
                    $props = Get-ItemProperty $prof.PSPath -ErrorAction SilentlyContinue
                    $bakProps = Get-ItemProperty $bakPath -ErrorAction SilentlyContinue
                    Write-Host "  [FIX] SID $sid has a .bak duplicate (profile load failure pattern)" -ForegroundColor Yellow
                    Write-Host "        Primary ProfileImagePath: $($props.ProfileImagePath)" -ForegroundColor White
                    Write-Host "        .bak    ProfileImagePath: $($bakProps.ProfileImagePath)" -ForegroundColor White

                    # Rename primary -> .old
                    $oldPath = "$plBase\$sid.old"
                    if (Test-Path $oldPath) { Remove-Item-Logged -Path $oldPath -Recurse -Force }
                    Rename-Item-Logged -Path $prof.PSPath -NewName "$sid.old" -Force
                    # Rename .bak -> primary
                    Rename-Item-Logged -Path $bakPath -NewName $sid -Force

                    # Fix the State value (remove temporary profile flag)
                    $newPrimary = "$plBase\$sid"
                    $state = (Get-ItemProperty $newPrimary -ErrorAction SilentlyContinue).State
                    if ($null -ne $state -and ($state -band 0x8)) {
                        $newState = $state -band (-bnot 0x8)  # Clear bit 3 (temporary profile)
                        Set-ItemProperty-Logged -Path $newPrimary -Name State -Value $newState -Type DWord -Force
                        Write-Host "        Cleared temporary profile flag (State: $state -> $newState)" -ForegroundColor Green
                    }
                    # Set RefCount to 0 if present
                    $refCount = (Get-ItemProperty $newPrimary -ErrorAction SilentlyContinue).RefCount
                    if ($null -ne $refCount -and $refCount -ne 0) {
                        Set-ItemProperty-Logged -Path $newPrimary -Name RefCount -Value 0 -Type DWord -Force
                    }
                    $fixCount++
                }
                else {
                    # Check for corrupt State (bit 3 = temporary profile)
                    $state = (Get-ItemProperty $prof.PSPath -ErrorAction SilentlyContinue).State
                    if ($null -ne $state -and ($state -band 0x8)) {
                        Write-Host "  [FIX] SID $sid has temporary profile flag set (State=$state)" -ForegroundColor Yellow
                        $newState = $state -band (-bnot 0x8)
                        Set-ItemProperty-Logged -Path $prof.PSPath -Name State -Value $newState -Type DWord -Force
                        Write-Host "        Cleared temporary profile flag (State: $state -> $newState)" -ForegroundColor Green
                        $fixCount++
                    }
                }
            }

            if ($fixCount -gt 0) {
                Write-Host "Fixed $fixCount profile entry(s). Users should be able to log on normally." -ForegroundColor Green
            }
            else {
                Write-Host "  No corrupted profile entries found. All profiles appear healthy." -ForegroundColor DarkGray
            }
        }
    }

    function CheckRepairRegistryHives {
        param([switch]$Repair)
        # Downloads Microsoft's chkreg.exe utility and runs it against copies of the
        # offline VM's SYSTEM and SOFTWARE registry hives.
        #
        # Without -Repair: read-only check - reports corruption without modifying anything.
        # With    -Repair: repairs in-place (/R) and compacts (/C).  If any fixes were
        #                   applied, the original hives are backed up and the repaired
        #                   versions are copied back to the guest disk.
        #
        # chkreg.exe source: https://github.com/Azure/repair-script-library
        # (Microsoft Corporation, x64, used by Azure VM repair extensions)

        $mode = if ($Repair) { 'Repair' } else { 'Check' }
        Write-Host "Registry hive integrity $mode (using chkreg.exe)..." -ForegroundColor Yellow

        # -- 1. Download chkreg.exe -----------------------------------------------
        $toolDir = Join-Path $env:TEMP 'chkreg'
        $chkregPath = Join-Path $toolDir 'chkreg.exe'
        if (-not (Test-Path $toolDir)) { New-Item -Path $toolDir -ItemType Directory -Force | Out-Null }

        if (-not (Test-Path $chkregPath)) {
            $downloadUrl = 'https://github.com/Azure/repair-script-library/raw/main/src/windows/common/tools/chkreg.exe'
            Write-Host "  Downloading chkreg.exe from Azure repair-script-library..." -ForegroundColor Cyan
            try {
                $prevPref = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $downloadUrl -OutFile $chkregPath -UseBasicParsing -ErrorAction Stop
                $ProgressPreference = $prevPref
            }
            catch {
                $ProgressPreference = $prevPref
                Write-Error "Failed to download chkreg.exe: $_"
                return
            }
            if (-not (Test-Path $chkregPath) -or (Get-Item $chkregPath).Length -lt 1024) {
                Write-Error "chkreg.exe download appears corrupt or incomplete."
                return
            }
            Write-Host "  Downloaded: $chkregPath" -ForegroundColor Green
        }
        else {
            Write-Host "  Using cached chkreg.exe: $chkregPath" -ForegroundColor DarkGray
        }

        # -- 2. Process each hive -------------------------------------------------
        $configDir = Join-Path $script:WinDriveLetter 'Windows\System32\config'
        $hivesToCheck = @('SYSTEM', 'SOFTWARE')
        $anyRepaired = $false

        foreach ($hiveName in $hivesToCheck) {
            $originalHive = Join-Path $configDir $hiveName
            if (-not (Test-Path $originalHive)) {
                Write-Warning "$hiveName hive not found at $originalHive - skipping."
                continue
            }
            if ((Get-Item $originalHive).Length -eq 0) {
                Write-Warning "$hiveName hive is 0 bytes (empty/corrupt) at $originalHive - chkreg cannot process an empty file."
                continue
            }

            Write-Host "`n  -- $hiveName hive --" -ForegroundColor Cyan

            # Copy hive to temp location to work on a copy, not the live file
            $tempHive = Join-Path $toolDir $hiveName
            Write-Host "  Copying $originalHive -> $tempHive" -ForegroundColor DarkGray
            Copy-Item -LiteralPath $originalHive -Destination $tempHive -Force

            # Also copy .LOG files if present (chkreg may need them for replay)
            foreach ($logSuffix in @('.LOG', '.LOG1', '.LOG2')) {
                $logFile = "$originalHive$logSuffix"
                if (Test-Path $logFile) {
                    Copy-Item -LiteralPath $logFile -Destination "$tempHive$logSuffix" -Force
                }
            }

            # -- 3. Run chkreg ----------------------------------------------------
            # chkreg.exe writes informational messages to stderr; capture both
            # streams and coerce ErrorRecord objects to plain strings so
            # PowerShell does not display red NativeCommandError noise.
            if ($Repair) {
                Write-Host "  Running: chkreg /F `"$tempHive`" /R /C" -ForegroundColor White
                $output = & $chkregPath /F "$tempHive" /R /C 2>&1 | ForEach-Object { "$_" } | Out-String
            }
            else {
                Write-Host "  Running: chkreg /F `"$tempHive`"" -ForegroundColor White
                $output = & $chkregPath /F "$tempHive" 2>&1 | ForEach-Object { "$_" } | Out-String
            }

            # Display the output
            $output.Trim().Split("`n") | ForEach-Object {
                $line = $_.TrimEnd()
                if ($line -match 'fixed') {
                    Write-Host "    $line" -ForegroundColor Yellow
                }
                elseif ($line -match 'SUMMARY|Total Hive|Bins') {
                    Write-Host "    $line" -ForegroundColor Cyan
                }
                elseif ($line -match 'successfully|no errors found') {
                    Write-Host "    $line" -ForegroundColor Green
                }
                elseif ($line -match 'error|corrupt|invalid' -and $line -notmatch 'fixed') {
                    Write-Host "    $line" -ForegroundColor Red
                }
                elseif (-not [string]::IsNullOrWhiteSpace($line)) {
                    Write-Host "    $line" -ForegroundColor DarkGray
                }
            }

            # -- 4. If repair mode and fixes were applied, copy back --------------
            $wasFixed = $output -match '\.\.\.\s*fixed'
            if ($Repair -and $wasFixed) {
                $anyRepaired = $true
                Write-Host "`n  [FIXED] $hiveName hive had corruption that was repaired." -ForegroundColor Yellow

                # Determine the best repaired file: /C writes compacted version to .BAK
                $compactedHive = "$tempHive.BAK"
                $repairedSource = if (Test-Path $compactedHive) {
                    Write-Host "  Using compacted version: $compactedHive" -ForegroundColor DarkGray
                    $compactedHive
                }
                else {
                    $tempHive
                }

                # Backup the original hive on the guest disk
                $bakPath = New-UniqueBackupPath -BasePath $originalHive -BakSuffix '.chkreg.bak'
                Write-Host "  Backing up original: $originalHive -> $bakPath" -ForegroundColor DarkGray
                Copy-Item -LiteralPath $originalHive -Destination $bakPath -Force

                # Copy repaired hive back
                Write-Host "  Copying repaired hive back: $repairedSource -> $originalHive" -ForegroundColor Green
                Copy-Item -LiteralPath $repairedSource -Destination $originalHive -Force

                Write-ActionLog -Event 'RegistryHiveRepaired' -Details @{
                    Hive           = $hiveName
                    OriginalBackup = $bakPath
                    RepairedFrom   = $repairedSource
                    ChkregOutput   = ($output.Trim() -replace "`r?`n", ' | ')
                }
            }
            elseif ($Repair) {
                Write-Host "`n  [OK] $hiveName hive: no corruption found." -ForegroundColor Green
            }
            else {
                # Check-only mode
                if ($wasFixed) {
                    # chkreg reports what WOULD be fixed even without /R
                    Write-Host "`n  [WARN] $hiveName hive has corruption. Run -FixRegistryCorruption to repair." -ForegroundColor Yellow
                }
                else {
                    Write-Host "`n  [OK] $hiveName hive: no corruption detected." -ForegroundColor Green
                }
            }
        }

        # -- 5. Summary -----------------------------------------------------------
        if ($Repair -and $anyRepaired) {
            Write-Host "`nRegistry hive repair complete. Original hives backed up with .chkreg.bak suffix." -ForegroundColor Green
            Write-Warning "If the VM still fails to boot after repair, the backup hives can be restored manually."
        }
        elseif (-not $Repair -and $anyRepaired) {
            Write-Host "`nCorruption detected. Use -FixRegistryCorruption to repair the hives." -ForegroundColor Yellow
        }
        else {
            Write-Host "`nNo registry hive corruption detected." -ForegroundColor Green
        }
    }

    function EnableSerialConsole {
        Write-Host "Enabling Emergency Management Services (EMS) / Serial Console..." -ForegroundColor Yellow
        try {
            $storePath = Get-BcdStorePath -Generation $script:VMGen -BootDrive $script:BootDriveLetter
            $identifier = Get-BcdBootLoaderId -StorePath $storePath
            if (-not $identifier) { return }

            # Enable EMS on the boot manager
            Invoke-BcdEdit -StorePath $storePath -Command "/bootems $identifier on"
            # Set EMS port (port 1) and baud rate (115200 is Azure Serial Console standard)
            Invoke-BcdEdit -StorePath $storePath -Command "/emssettings emsport:1 emsbaudrate:115200"
            # Enable EMS on the OS loader
            Invoke-BcdEdit -StorePath $storePath -Command "/set $identifier ems on"
            # Enable boot debugging output to serial
            Invoke-BcdEdit -StorePath $storePath -Command "/set $identifier bootems on"

            Write-Host "[OK] EMS / Serial Console enabled (port 1, baud 115200)." -ForegroundColor Green
            Write-Host "  On Azure, use: az serial-console connect --name <vm-name> --resource-group <rg>" -ForegroundColor DarkCyan
            Write-Host "  Or via Azure Portal -> VM -> Serial Console (under Help)" -ForegroundColor DarkCyan
        }
        catch {
            Write-Error "EnableSerialConsole failed: $_"
            throw
        }
    }

    function ListInstalledUpdates {
        Write-Host "Enumerating installed Windows Updates from offline guest disk..." -ForegroundColor Yellow
        Invoke-WithHive 'SOFTWARE' {
            $cbsBase = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
            if (-not (Test-Path $cbsBase)) {
                Write-Warning "CBS Packages key not found."
                return
            }

            $packages = Get-ChildItem $cbsBase -ErrorAction SilentlyContinue | Where-Object {
                $_.PSChildName -match 'KB\d+'
            }

            # Extract KB numbers and deduplicate
            $kbList = [System.Collections.Generic.SortedDictionary[string, PSCustomObject]]::new()
            foreach ($pkg in $packages) {
                if ($pkg.PSChildName -match '(KB\d+)') {
                    $kb = $Matches[1]
                    if ($kbList.ContainsKey($kb)) { continue }
                    $props = Get-ItemProperty $pkg.PSPath -ErrorAction SilentlyContinue
                    $state = switch ($props.CurrentState) {
                        0 { 'Absent' }
                        5 { 'Uninstall Pending' }
                        16 { 'Resolving' }
                        32 { 'Resolved' }
                        48 { 'Staging' }
                        64 { 'Staged' }
                        80 { 'Superseded' }
                        96 { 'Install Pending' }
                        101 { 'partially Installed' }
                        112 { 'Installed' }
                        128 { 'Permanent' }
                        default { "State=$($props.CurrentState)" }
                    }
                    $installDate = $null
                    if ($props.InstallTimeHigh -and $props.InstallTimeLow) {
                        try {
                            $ft = ([long]$props.InstallTimeHigh -shl 32) -bor [long]$props.InstallTimeLow
                            if ($ft -gt 0) { $installDate = [datetime]::FromFileTimeUtc($ft).ToString('yyyy-MM-dd HH:mm') }
                        }
                        catch {}
                    }
                    $kbList[$kb] = [PSCustomObject]@{
                        KB      = $kb
                        State   = $state
                        Date    = if ($installDate) { $installDate } else { 'N/A' }
                        Package = $pkg.PSChildName
                    }
                }
            }

            if ($kbList.Count -eq 0) {
                Write-Host "  No KB packages found in CBS." -ForegroundColor DarkGray
                return
            }

            Write-Host "`n  $($kbList.Count) unique KB(s) found:`n" -ForegroundColor Cyan
            Write-Host ("  {0,-12} {1,-22} {2,-20} {3}" -f 'KB', 'State', 'Install Date', 'Package') -ForegroundColor DarkGray
            Write-Host ("  {0,-12} {1,-22} {2,-20} {3}" -f '----', '-----', '------------', '-------') -ForegroundColor DarkGray
            foreach ($entry in $kbList.Values) {
                $color = switch -Wildcard ($entry.State) {
                    'Installed' { 'Green' }
                    'Permanent' { 'Green' }
                    'Superseded' { 'DarkGray' }
                    'Staged' { 'Cyan' }
                    'Staging' { 'Cyan' }
                    '*Pending*' { 'Yellow' }
                    'Absent' { 'DarkGray' }
                    default { 'White' }
                }
                Write-Host ("  {0,-12} {1,-22} {2,-20} {3}" -f $entry.KB, $entry.State, $entry.Date, $entry.Package) -ForegroundColor $color
            }

            $staged = @($kbList.Values | Where-Object { $_.State -in @('Staged', 'Staging') })
            $pending = @($kbList.Values | Where-Object { $_.State -match 'Pending' })
            if ($pending.Count -gt 0) {
                Write-Host "  $($pending.Count) package(s) in pending state - these may cause boot loops. Consider -FixPendingUpdates." -ForegroundColor Yellow
            }
            if ($staged.Count -gt 0) {
                Write-Host "  $($staged.Count) package(s) in staged state (downloaded but not installed - harmless, no action needed)." -ForegroundColor DarkCyan
            }
            Write-Host ""
        }
    }

    function UninstallWindowsUpdate {
        param([Parameter(Mandatory = $true)][string]$KBNumber)

        # Normalise: accept "KB5001234" or just "5001234"
        $KBNumber = $KBNumber.Trim()
        if ($KBNumber -notmatch '^KB') { $KBNumber = "KB$KBNumber" }

        if (-not (Confirm-CriticalOperation -Operation "Uninstall Windows Update $KBNumber (-UninstallWindowsUpdate)" -Details @"
Marks the CBS package for $KBNumber as Absent (CurrentState=0) in the offline SOFTWARE hive.
Also clears any pending state for this package in CBS SessionsPending/PackagesPending.
On next boot, CBS should skip this update. This is an offline best-effort operation;
not all updates can be cleanly reversed this way.
"@)) { return }

        Write-Host "Attempting offline uninstall of $KBNumber..." -ForegroundColor Yellow
        Invoke-WithHive 'SOFTWARE' {
            $cbsBase = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
            $packages = Get-ChildItem $cbsBase -ErrorAction SilentlyContinue | Where-Object {
                $_.PSChildName -match $KBNumber
            }

            if ($packages.Count -eq 0) {
                Write-Warning "No CBS packages matching $KBNumber found."
                return
            }

            $modified = 0
            foreach ($pkg in $packages) {
                $props = Get-ItemProperty $pkg.PSPath -ErrorAction SilentlyContinue
                $curState = $props.CurrentState
                if ($null -ne $curState -and $curState -ne 0) {
                    Write-Host "  $($pkg.PSChildName): CurrentState $curState -> 0 (Absent)" -ForegroundColor Yellow
                    Set-ItemProperty-Logged -Path $pkg.PSPath -Name CurrentState -Value 0 -Type DWord -Force
                    $modified++
                }
                else {
                    Write-Host "  $($pkg.PSChildName): already Absent" -ForegroundColor DarkGray
                }
            }

            # Clear pending state referencing this KB
            foreach ($pendKey in @('PackagesPending', 'SessionsPending')) {
                $pendPath = "HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\$pendKey"
                if (-not (Test-Path $pendPath)) { continue }
                Get-ChildItem $pendPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match $KBNumber } | ForEach-Object {
                    Remove-Item-Logged -Path $_.PSPath -Recurse -Force
                    Write-Host "  Removed pending entry: $pendKey\$($_.PSChildName)" -ForegroundColor Green
                }
            }

            Write-Host "$modified package(s) for $KBNumber marked as Absent." -ForegroundColor Green
            Write-Host "Boot the VM to verify. If the update was mid-install, also run -FixPendingUpdates." -ForegroundColor DarkCyan
        }
    }

    function ListStartupPrograms {
        Write-Host "Enumerating auto-start programs from offline guest registry..." -ForegroundColor Yellow
        $OfflineWindowsPath = Join-Path $script:WinDriveLetter "Windows"

        $allEntries = [System.Collections.Generic.List[PSCustomObject]]::new()

        # SOFTWARE hive (HKLM Run/RunOnce)
        Invoke-WithHive 'SOFTWARE' {
            $swPaths = @(
                @{ Key = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Scope = 'HKLM Run' }
                @{ Key = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Scope = 'HKLM RunOnce' }
            )
            foreach ($sp in $swPaths) {
                if (-not (Test-Path $sp.Key)) { continue }
                $props = Get-ItemProperty $sp.Key -ErrorAction SilentlyContinue
                foreach ($p in ($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                    $allEntries.Add([PSCustomObject]@{ Scope = $sp.Scope; Name = $p.Name; Command = $p.Value })
                }
            }
        }

        # SYSTEM hive: check SetupType/CmdLine (setup-mode startup script)
        Invoke-WithHive 'SYSTEM' {
            $setupType = (Get-ItemProperty 'HKLM:\BROKENSYSTEM\Setup' -ErrorAction SilentlyContinue).SetupType
            $cmdLine = (Get-ItemProperty 'HKLM:\BROKENSYSTEM\Setup' -ErrorAction SilentlyContinue).CmdLine
            if ($setupType -and $setupType -ne 0 -and $cmdLine) {
                $allEntries.Add([PSCustomObject]@{ Scope = 'Setup CmdLine'; Name = "(SetupType=$setupType)"; Command = $cmdLine })
            }
        }

        # Startup folders on disk
        $startupFolders = @(
            @{ Path = Join-Path $script:WinDriveLetter 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup'; Scope = 'All Users Startup Folder' }
        )
        # Also scan per-user startup folders
        $usersDir = Join-Path $script:WinDriveLetter 'Users'
        if (Test-Path $usersDir) {
            Get-ChildItem $usersDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $userStartup = Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
                if (Test-Path $userStartup) {
                    $startupFolders += @{ Path = $userStartup; Scope = "User Startup ($($_.Name))" }
                }
            }
        }
        foreach ($sf in $startupFolders) {
            if (-not (Test-Path $sf.Path)) { continue }
            Get-ChildItem $sf.Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
                $allEntries.Add([PSCustomObject]@{ Scope = $sf.Scope; Name = $_.Name; Command = $_.FullName })
            }
        }

        if ($allEntries.Count -eq 0) {
            Write-Host "  No auto-start entries found." -ForegroundColor DarkGray
            return
        }

        Write-Host "`n  $($allEntries.Count) auto-start entry(s) found:`n" -ForegroundColor Cyan
        Write-Host ("  {0,-25} {1,-28} {2}" -f 'Source', 'Name', 'Command') -ForegroundColor DarkGray
        Write-Host ("  {0,-25} {1,-28} {2}" -f '------', '----', '-------') -ForegroundColor DarkGray
        foreach ($e in $allEntries) {
            Write-Host ("  {0,-25} {1,-28} {2}" -f $e.Scope, $e.Name, $e.Command) -ForegroundColor White
        }
        Write-Host ""
    }

    function DisableStartupPrograms {
        if (-not (Confirm-CriticalOperation -Operation 'Disable Startup Programs (-DisableStartupPrograms)' -Details @"
Clears all entries from:
  HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run
  HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce
And renames .exe/.bat/.cmd/.lnk/.vbs files in:
  All Users Startup folder
  Per-user Startup folders
to .disabled extension. Does NOT remove them; they can be re-enabled by renaming back.
"@)) { return }

        Write-Host "Disabling auto-start programs on offline guest..." -ForegroundColor Yellow
        Invoke-WithHive 'SOFTWARE' {
            $swPaths = @(
                'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Run'
                'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
            )
            foreach ($regPath in $swPaths) {
                if (-not (Test-Path $regPath)) { continue }
                $props = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
                $cleared = 0
                foreach ($p in ($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                    Remove-ItemProperty-Logged -Path $regPath -Name $p.Name
                    $cleared++
                }
                $keyLabel = ($regPath -split '\\')[-1]
                if ($cleared -gt 0) {
                    Write-Host "  Cleared $cleared entry(s) from HKLM\...\$keyLabel" -ForegroundColor Green
                }
                else {
                    Write-Host "  ${keyLabel}: already empty" -ForegroundColor DarkGray
                }
            }
        }

        # Rename startup folder items
        $disableExts = @('.exe', '.bat', '.cmd', '.lnk', '.vbs', '.vbe', '.js', '.wsf', '.wsh')
        $startupFolders = @(
            (Join-Path $script:WinDriveLetter 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup')
        )
        $usersDir = Join-Path $script:WinDriveLetter 'Users'
        if (Test-Path $usersDir) {
            Get-ChildItem $usersDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $userStartup = Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
                if (Test-Path $userStartup) { $startupFolders += $userStartup }
            }
        }
        foreach ($folder in $startupFolders) {
            if (-not (Test-Path $folder)) { continue }
            Get-ChildItem $folder -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -ne 'desktop.ini' -and $disableExts -contains $_.Extension.ToLower()
            } | ForEach-Object {
                $newName = "$($_.Name).disabled"
                Rename-Item-Logged -Path $_.FullName -NewName $newName -Force
                Write-Host "  Disabled: $($_.Name) -> $newName" -ForegroundColor Green
            }
        }

        Write-Host "Startup programs disabled. Run -ListStartupPrograms to review." -ForegroundColor Green
    }

    function DisableFirewall {
        Write-Host "Disabling Windows Firewall for all profiles on offline guest..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            $SystemRoot = Get-SystemRootPath
            $fwBase = "$SystemRoot\Services\SharedAccess\Parameters\FirewallPolicy"

            $profiles = @(
                @{ Name = 'DomainProfile'; Desc = 'Domain' }
                @{ Name = 'StandardProfile'; Desc = 'Private' }
                @{ Name = 'PublicProfile'; Desc = 'Public' }
            )

            foreach ($prof in $profiles) {
                $profPath = "$fwBase\$($prof.Name)"
                if (-not (Test-Path $profPath)) {
                    Write-Host "  $($prof.Desc) profile key not found - skipping." -ForegroundColor DarkGray
                    continue
                }
                $current = (Get-ItemProperty $profPath -ErrorAction SilentlyContinue).EnableFirewall
                if ($current -eq 0) {
                    Write-Host "  $($prof.Desc): already disabled" -ForegroundColor DarkGray
                }
                else {
                    Set-ItemProperty-Logged -Path $profPath -Name EnableFirewall -Value 0 -Type DWord -Force
                    Write-Host "  $($prof.Desc): DISABLED (was $current)" -ForegroundColor Green
                }
            }

            Write-Host "`nWindows Firewall disabled for all profiles." -ForegroundColor Green
            Write-Warning "Remember to re-enable the firewall after recovery:"
            Write-Warning "  Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True"
        }
    }

    function AnalyzeCriticalBootFiles {
        Write-Host "Analyzing critical boot/system files on offline guest..." -ForegroundColor Yellow
        $checks = @(
            @{ Name = 'BCD store'; Path = (Get-BcdStorePath -BootDrive $script:BootDriveLetter -Generation $script:VMGen); Category = 'Boot Loader' }
            @{ Name = 'winload'; Path = (Join-Path $script:WinDriveLetter $(if ($script:VMGen -eq 2) { 'Windows\System32\winload.efi' } else { 'Windows\System32\winload.exe' })); Category = 'Boot Loader' }
            @{ Name = 'ntoskrnl.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\ntoskrnl.exe'); Category = 'Kernel & HAL' }
            @{ Name = 'hal.dll'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\hal.dll'); Category = 'Kernel & HAL' }
            @{ Name = 'ci.dll'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\ci.dll'); Category = 'Kernel & HAL' }
            @{ Name = 'ntdll.dll'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\ntdll.dll'); Category = 'Core DLL' }
            @{ Name = 'kernel32.dll'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\kernel32.dll'); Category = 'Core DLL' }
            @{ Name = 'smss.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\smss.exe'); Category = 'Session Init' }
            @{ Name = 'csrss.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\csrss.exe'); Category = 'Session Init' }
            @{ Name = 'wininit.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\wininit.exe'); Category = 'Session Init' }
            @{ Name = 'services.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\services.exe'); Category = 'Session Init' }
            @{ Name = 'lsass.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\lsass.exe'); Category = 'Session Init' }
            @{ Name = 'winlogon.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\winlogon.exe'); Category = 'Session Init' }
            @{ Name = 'logonui.exe'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\logonui.exe'); Category = 'Session Init' }
        )
        # Gen1 BIOS: bootmgr lives at the root of the boot partition
        if ($script:VMGen -eq 1) {
            $checks += @(
                @{ Name = 'bootmgr'; Path = (Join-Path $script:BootDriveLetter 'bootmgr'); Category = 'Boot Loader' }
            )
        }
        # Gen2 UEFI: firmware boot manager and fallback loader
        if ($script:VMGen -eq 2) {
            $checks += @(
                @{ Name = 'bootmgfw.efi'; Path = (Join-Path $script:BootDriveLetter 'EFI\Microsoft\Boot\bootmgfw.efi'); Category = 'Boot Loader' }
                @{ Name = 'bootx64.efi'; Path = (Join-Path $script:BootDriveLetter 'EFI\Boot\bootx64.efi'); Category = 'Boot Loader' }
            )
        }
        # Azure/Hyper-V critical drivers - missing any of these will BSOD or cripple the VM
        # Only includes inbox Hyper-V drivers present on every guest; storflt/vmstorfl are
        # Azure-agent or version-specific and checked conditionally in GetBootPathReport instead.
        $azureCriticalDrivers = @(
            @{ Name = 'vmbus.sys';    Desc = 'Hyper-V VMBus' }
            @{ Name = 'storvsc.sys';  Desc = 'Hyper-V Storage' }
            @{ Name = 'netvsc.sys';   Desc = 'Hyper-V Network' }
        )
        foreach ($drv in $azureCriticalDrivers) {
            $checks += @{ Name = $drv.Name; Path = (Join-Path $script:WinDriveLetter "Windows\System32\drivers\$($drv.Name)"); Category = "Azure Driver ($($drv.Desc))" }
        }

        $rows = foreach ($c in $checks) {
            $exists = Test-Path -LiteralPath $c.Path
            $size = if ($exists) { (Get-Item -LiteralPath $c.Path -Force -ErrorAction SilentlyContinue).Length } else { 0 }
            # Signature check for existing non-zero binaries (skip BCD store  -  it's not a PE)
            $sigStatus = ''
            if ($exists -and $size -gt 0 -and $c.Name -ne 'BCD store') {
                $sig = Test-MicrosoftSignature -FilePath $c.Path
                $sigStatus = if ($sig.IsMicrosoft) { 'Microsoft' } elseif ($sig.IsSigned) { "Signed: $($sig.Subject)" } else { $sig.Status }
            }
            [PSCustomObject]@{
                Category  = $c.Category
                Artifact  = $c.Name
                Exists    = $exists
                Size      = if ($exists) { "{0:N0}" -f $size } else { '' }
                Signature = $sigStatus
                Path      = $c.Path
            }
        }

        $rows | Format-Table Category, Artifact, Exists, Size, Signature, Path -AutoSize
        $missing = @($rows | Where-Object { -not $_.Exists })
        $zeroLen = @($rows | Where-Object { $_.Exists -and $_.Size -eq '0' })
        $notMsSigned = @($rows | Where-Object { $_.Signature -and $_.Signature -ne 'Microsoft' -and $_.Artifact -ne 'BCD store' })
        if ($missing.Count -gt 0) {
            Write-Warning "Missing critical artifact(s): $($missing.Artifact -join ', ')."
        }
        if ($zeroLen.Count -gt 0) {
            Write-Warning "Zero-byte (corrupt) critical artifact(s): $($zeroLen.Artifact -join ', ') - file exists but is empty."
        }
        if ($notMsSigned.Count -gt 0) {
            Write-Warning "Non-Microsoft-signed binary/ies: $($notMsSigned.Artifact -join ', ') - possible tampering or third-party replacement."
        }
        if ($missing.Count -eq 0 -and $zeroLen.Count -eq 0 -and $notMsSigned.Count -eq 0) {
            Write-Host "All checked critical boot/system files are present, non-empty, and Microsoft-signed." -ForegroundColor Green
        }
    }

    function RepairBrokenSystemFile {
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$FileNames
        )
        # Replaces a missing or 0-byte Windows system binary by locating the latest
        # version from the offline disk's WinSxS component store or DriverStore.
        #
        # Search order (picks the largest / newest match):
        #   1. \Windows\WinSxS\<component>\<filename>          (component store - primary)
        #   2. \Windows\System32\DriverStore\FileRepository\*\<filename>  (driver packages)
        #
        # Only Microsoft/Windows binaries are expected targets (e.g. storvsc.sys, ntoskrnl.exe).
        # The original file (if present) is renamed to .broken.bak before replacement.
        #
        # Reference: https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/virtual-machines-windows-repair-replace-system-binary-file

        foreach ($fileName in $FileNames) {
            $fileName = $fileName.Trim()
            if ([string]::IsNullOrWhiteSpace($fileName)) { continue }

            Write-Host "`nProcessing: $fileName" -ForegroundColor Cyan

            # -- 1. Determine the expected target path on the offline disk --------
            $ext = [System.IO.Path]::GetExtension($fileName).ToLower()
            $winRoot = Join-Path $script:WinDriveLetter 'Windows'

            # Decide target directory based on extension/convention
            $targetDir = switch -Wildcard ($ext) {
                '.sys' { Join-Path $winRoot 'System32\drivers' }
                '.dll' { Join-Path $winRoot 'System32' }
                '.exe' { Join-Path $winRoot 'System32' }
                '.efi' {
                    # EFI binaries live on the boot partition
                    if ($fileName -ieq 'bootmgfw.efi') { Join-Path $script:BootDriveLetter 'EFI\Microsoft\Boot' }
                    elseif ($fileName -ieq 'bootx64.efi') { Join-Path $script:BootDriveLetter 'EFI\Boot' }
                    else { Join-Path $winRoot 'System32' }
                }
                default { Join-Path $winRoot 'System32' }
            }
            $targetPath = Join-Path $targetDir $fileName

            # Check current state
            $targetExists = Test-Path -LiteralPath $targetPath
            $targetSize = if ($targetExists) { (Get-Item -LiteralPath $targetPath -ErrorAction SilentlyContinue).Length } else { 0 }
            $isBroken = (-not $targetExists) -or ($targetSize -eq 0)

            if (-not $isBroken) {
                $ver = (Get-Item -LiteralPath $targetPath -ErrorAction SilentlyContinue).VersionInfo
                Write-Host "  $targetPath already exists ($("{0:N0}" -f $targetSize) bytes, version: $($ver.FileVersion))" -ForegroundColor DarkGray
                Write-Host "  File does not appear broken (present and non-zero). Skipping." -ForegroundColor DarkGray
                Write-Host "  To force replacement, rename or delete the file first." -ForegroundColor DarkGray
                continue
            }

            $stateDesc = if (-not $targetExists) { 'MISSING' } else { '0 bytes (corrupt)' }
            Write-Host "  Target: $targetPath [$stateDesc]" -ForegroundColor Yellow

            # -- 2. Search WinSxS and DriverStore for replacement candidates ------
            $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()

            # Search WinSxS
            # Skip \f\ and \r\ subdirectories - these contain forward/reverse
            # delta patches (not usable PE binaries).
            # Also skip tiny files (<1KB) with no version info - these are delta
            # compression stubs that replaced the original binary in superseded
            # component folders.
            $winsxsDir = Join-Path $winRoot 'WinSxS'
            if (Test-Path $winsxsDir) {
                Write-Host "  Searching WinSxS..." -ForegroundColor DarkGray
                Get-ChildItem -Path $winsxsDir -Filter $fileName -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 0 -and $_.DirectoryName -notmatch '\\(f|r)$' } |
                ForEach-Object {
                    $ver = $_.VersionInfo
                    # Filter out delta stubs: no version info + under 1KB = not a real PE binary
                    if ($_.Length -lt 1024 -and -not $ver.FileVersion) { return }
                    $candidates.Add([PSCustomObject]@{
                            Path       = $_.FullName
                            Size       = $_.Length
                            Version    = $ver.FileVersion
                            ProductVer = $ver.ProductVersion
                            Company    = $ver.CompanyName
                            LastWrite  = $_.LastWriteTime
                            Source     = 'WinSxS'
                        })
                }
            }

            # Search DriverStore
            $driverStoreDir = Join-Path $winRoot 'System32\DriverStore\FileRepository'
            if (Test-Path $driverStoreDir) {
                Write-Host "  Searching DriverStore..." -ForegroundColor DarkGray
                Get-ChildItem -Path $driverStoreDir -Filter $fileName -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 0 } |
                ForEach-Object {
                    $ver = $_.VersionInfo
                    $candidates.Add([PSCustomObject]@{
                            Path       = $_.FullName
                            Size       = $_.Length
                            Version    = $ver.FileVersion
                            ProductVer = $ver.ProductVersion
                            Company    = $ver.CompanyName
                            LastWrite  = $_.LastWriteTime
                            Source     = 'DriverStore'
                        })
                }
            }

            if ($candidates.Count -eq 0) {
                Write-Warning "  No replacement candidates found for '$fileName' in WinSxS or DriverStore."
                Write-Warning "  The file may need to be copied from another VM with the same OS version."
                continue
            }

            # Display all candidates
            Write-Host "  Found $($candidates.Count) candidate(s):" -ForegroundColor Green
            $candidates | Sort-Object LastWrite -Descending |
            Format-Table @{L = 'Source'; E = { $_.Source } },
            @{L = 'Version'; E = { $_.Version } },
            @{L = 'Size'; E = { "{0:N0}" -f $_.Size } },
            @{L = 'Date'; E = { $_.LastWrite.ToString('yyyy-MM-dd HH:mm') } },
            @{L = 'Company'; E = { $_.Company } },
            @{L = 'Path'; E = { $_.Path } } -AutoSize

            # -- 3. Pick the best candidate ---------------------------------------
            # Prefer candidates with valid version info (real PE binaries),
            # then largest size (most complete), then newest date.
            # Files without version info are likely delta stubs or placeholders.
            $best = $candidates |
                Sort-Object @{Expression = { if ($_.Version -and $_.Company) { 0 } else { 1 } } },
                            @{Expression = 'Size'; Descending = $true },
                            @{Expression = 'LastWrite'; Descending = $true } |
                Select-Object -First 1

            Write-Host "  Selected: $($best.Path)" -ForegroundColor Cyan
            Write-Host "    Version: $($best.Version)  |  Size: $("{0:N0}" -f $best.Size) bytes  |  Date: $($best.LastWrite.ToString('yyyy-MM-dd HH:mm'))  |  Company: $($best.Company)" -ForegroundColor White

            # Verify it's a Microsoft binary (safety check)
            if ($best.Company -and $best.Company -notmatch 'Microsoft') {
                Write-Warning "  Selected binary is not from Microsoft (Company: '$($best.Company)')."
                Write-Warning "  Proceeding anyway - verify the replacement is correct."
            }

            # -- 4. Backup the broken file (if it exists) ------------------------
            if ($targetExists) {
                $bakPath = New-UniqueBackupPath -BasePath $targetPath -BakSuffix '.broken.bak'
                Write-Host "  Backing up broken file: $targetPath -> $bakPath" -ForegroundColor DarkGray
                try {
                    Rename-Item -LiteralPath $targetPath -NewName (Split-Path $bakPath -Leaf) -Force -ErrorAction Stop
                }
                catch {
                    Write-Warning "  Could not rename broken file: $_"
                    Write-Warning "  Attempting to overwrite directly."
                }
            }

            # Ensure target directory exists
            if (-not (Test-Path $targetDir)) {
                New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
            }

            # -- 5. Copy the replacement -----------------------------------------
            try {
                Copy-Item -LiteralPath $best.Path -Destination $targetPath -Force -ErrorAction Stop
                $newSize = (Get-Item -LiteralPath $targetPath).Length
                Write-Host "  [OK] Replaced: $targetPath ($("{0:N0}" -f $newSize) bytes)" -ForegroundColor Green

                Write-ActionLog -Event 'SystemFileReplaced' -Details @{
                    FileName      = $fileName
                    TargetPath    = $targetPath
                    SourcePath    = $best.Path
                    Source        = $best.Source
                    Version       = $best.Version
                    Size          = $best.Size
                    Company       = $best.Company
                    PreviousState = $stateDesc
                }
            }
            catch {
                Write-Error "  Failed to copy replacement: $_"
            }
        }
    }

    function Get-SyntheticDriverSpec {
        @(
            @{ Name = 'vmbus'; Start = 0; Bin = 'vmbus.sys'; Desc = 'Hyper-V VMBus' }
            @{ Name = 'storvsc'; Start = 0; Bin = 'storvsc.sys'; Desc = 'Hyper-V StorVSC (synthetic storage)' }
            @{ Name = 'netvsc'; Start = 3; Bin = 'netvsc.sys'; Desc = 'Hyper-V NetVSC (synthetic network)' }
        )
    }

    function AnalyzeSyntheticDrivers {
        Write-Host "Analyzing Azure/Hyper-V synthetic driver readiness..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM' {
            $sysRoot = Get-SystemRootPath
            $rows = foreach ($d in (Get-SyntheticDriverSpec)) {
                $svcPath = "$sysRoot\Services\$($d.Name)"
                $exists = Test-Path $svcPath
                $start = if ($exists) { (Get-ItemProperty $svcPath -ErrorAction SilentlyContinue).Start } else { $null }
                $binPath = Join-Path $script:WinDriveLetter "Windows\System32\drivers\$($d.Bin)"
                $binExists = Test-Path -LiteralPath $binPath
                [PSCustomObject]@{
                    Driver       = $d.Name
                    Expected     = $d.Start
                    CurrentStart = if ($null -ne $start) { $start } else { 'MissingKey' }
                    BinaryExists = $binExists
                    Healthy      = ($exists -and $binExists -and [int]$start -eq [int]$d.Start)
                    Notes        = $d.Desc
                }
            }
            $rows | Format-Table -AutoSize
            $bad = @($rows | Where-Object { -not $_.Healthy })
            if ($bad.Count -gt 0) {
                Write-Warning "One or more synthetic drivers are not healthy. Consider -EnsureSyntheticDriversEnabled."
            }
            else {
                Write-Host "Synthetic driver checks look healthy." -ForegroundColor Green
            }
        }
    }

    function EnsureSyntheticDriversEnabled {
        if (-not (Confirm-CriticalOperation -Operation 'Enable Azure synthetic drivers (-EnsureSyntheticDriversEnabled)' -Details @"
Sets Start values for core Hyper-V synthetic drivers when service key and binary are present:
  vmbus=0, storvsc=0, netvsc=2
Skips entries if service key or driver binary is missing.
"@)) { return }

        Invoke-WithHive 'SYSTEM' {
            $sysRoot = Get-SystemRootPath
            foreach ($d in (Get-SyntheticDriverSpec)) {
                $svcPath = "$sysRoot\Services\$($d.Name)"
                $binPath = Join-Path $script:WinDriveLetter "Windows\System32\drivers\$($d.Bin)"
                if (-not (Test-Path $svcPath)) {
                    Write-Host "  $($d.Name): service key missing, skipped." -ForegroundColor Yellow
                    continue
                }
                if (-not (Test-Path -LiteralPath $binPath)) {
                    Write-Host "  $($d.Name): binary missing ($($d.Bin)), skipped." -ForegroundColor Yellow
                    continue
                }
                $cur = (Get-ItemProperty $svcPath -ErrorAction SilentlyContinue).Start
                if ($null -ne $cur -and [int]$cur -eq [int]$d.Start) {
                    Write-Host "  $($d.Name): already Start=$cur" -ForegroundColor DarkGray
                }
                else {
                    Set-ItemProperty-Logged -Path $svcPath -Name Start -Value $d.Start -Type DWord -Force
                    Write-Host "  $($d.Name): Start set to $($d.Start)" -ForegroundColor Green
                }
            }
        }
    }

    function ResetInterfacesToDHCP {
        if (-not (Confirm-CriticalOperation -Operation 'Reset interfaces to DHCP (-ResetInterfacesToDHCP)' -Details @"
For all offline NIC interface keys under Tcpip\Parameters\Interfaces:
  - sets EnableDHCP=1
  - removes static IPv4 and static DNS fields (IPAddress, SubnetMask, DefaultGateway, NameServer)
Use this for migrated/cloned VMs stuck with stale static networking.
"@)) { return }

        Invoke-WithHive 'SYSTEM' {
            $sysRoot = Get-SystemRootPath
            $ifRoot = "$sysRoot\Services\Tcpip\Parameters\Interfaces"
            if (-not (Test-Path $ifRoot)) {
                Write-Warning "Interfaces key not found: $ifRoot"
                return
            }
            $changed = 0
            $propsToClear = @('IPAddress', 'SubnetMask', 'DefaultGateway', 'DefaultGatewayMetric', 'NameServer')
            foreach ($if in (Get-ChildItem $ifRoot -ErrorAction SilentlyContinue)) {
                $ifPath = $if.PSPath
                Set-ItemProperty-Logged -Path $ifPath -Name EnableDHCP -Value 1 -Type DWord -Force
                $changed++
                $pnames = (Get-ItemProperty $ifPath -ErrorAction SilentlyContinue).PSObject.Properties.Name
                foreach ($pn in $propsToClear) {
                    if ($pnames -contains $pn) {
                        Remove-ItemProperty-Logged -Path $ifPath -Name $pn
                    }
                }
            }
            Write-Host "Reset DHCP/static settings on $changed interface key(s)." -ForegroundColor Green
        }
    }

    function AnalyzeProxyState {
        Write-Host "Analyzing machine proxy/PAC state..." -ForegroundColor Yellow
        Invoke-WithHive 'SOFTWARE' {
            $paths = @(
                'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
                'HKLM:\BROKENSOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings'
            )
            $rows = foreach ($p in $paths) {
                if (-not (Test-Path $p)) { continue }
                $r = Get-ItemProperty $p -ErrorAction SilentlyContinue
                [PSCustomObject]@{
                    Key           = $p
                    ProxyEnable   = $r.ProxyEnable
                    ProxyServer   = $r.ProxyServer
                    AutoConfigURL = $r.AutoConfigURL
                    AutoDetect    = $r.AutoDetect
                }
            }
            if (-not $rows) {
                Write-Host "No proxy keys found." -ForegroundColor DarkGray
                return
            }
            $rows | Format-Table -AutoSize
            if (@($rows | Where-Object { $_.ProxyEnable -eq 1 -or $_.ProxyServer -or $_.AutoConfigURL }).Count -gt 0) {
                Write-Warning "Proxy/PAC settings detected. If remote access is blocked, consider -ClearProxyState."
            }
        }
    }

    function ClearProxyState {
        if (-not (Confirm-CriticalOperation -Operation 'Clear machine proxy state (-ClearProxyState)' -Details @"
Clears ProxyServer/ProxyOverride/AutoConfigURL and sets ProxyEnable=0 in machine Internet Settings.
Use this when stale proxy/PAC settings prevent WinRM/RDP reachability after migration.
"@)) { return }

        Invoke-WithHive 'SOFTWARE' {
            $paths = @(
                'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
                'HKLM:\BROKENSOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings'
            )
            foreach ($p in $paths) {
                if (-not (Test-Path $p)) { continue }
                Set-ItemProperty-Logged -Path $p -Name ProxyEnable -Value 0 -Type DWord -Force
                $pnames = (Get-ItemProperty $p -ErrorAction SilentlyContinue).PSObject.Properties.Name
                foreach ($pn in @('ProxyServer', 'ProxyOverride', 'AutoConfigURL')) {
                    if ($pnames -contains $pn) { Remove-ItemProperty-Logged -Path $p -Name $pn }
                }
                Write-Host "  Cleared proxy settings in $p" -ForegroundColor Green
            }
        }
    }

    function GetBootPathReport {
        <#
        .SYNOPSIS
            Boot Path Health Check  -  traces the full Windows boot chain on the offline disk
            and validates every artifact (file, registry key, driver, service) in load order.

            Phases:
                1  Pre-Boot (BIOS/UEFI firmware + MBR/GPT partition table)
                2  Boot Manager (bootmgr/bootmgfw.efi -> BCD store)
                3  OS Loader (winload.exe/.efi -> kernel, HAL, SYSTEM hive, boot-start drivers)
                4  NTOS Kernel Init (Session Manager, Csrss, Wininit, Services.exe, boot/system drivers)
                5  Logon & Desktop (Winlogon, LogonUI, Lsass, Userinit, Explorer shell)

            For each artifact the report shows:
                * Load order position within its phase
                * Expected file path on the offline disk
                * Exists / Missing / 0-byte status
                * File size and Microsoft signature verification
                * Registry configuration that references it (when applicable)
                * Health verdict:  OK / WARN / FAIL
        #>

        #region -- colour / symbol helpers ----------------------------------------
        $symOK    = [char]0x2714   # check mark
        $symFAIL  = [char]0x2718   # X mark
        $symWARN  = [char]0x26A0   # warning sign
        $symINFO  = [char]0x2139   # info
        $symARROW = [char]0x25B6   # right-pointing triangle
        $symCHAIN = [char]0x2502   # vertical line for chain visual
        $symLINK  = [char]0x251C   # tee connector
        $symEND   = [char]0x2514   # corner connector
        $symEQ    = [char]0x2550   # double horizontal line
        $symVert  = [char]0x2551   # double vertical line
        $symTL    = [char]0x2554   # top-left corner
        $symBL    = [char]0x255A   # bottom-left corner

        function Write-Phase {
            param([int]$Number, [string]$Title, [string]$Description)
            $bar = "  $symTL$("$symEQ" * 76)"
            $end = "  $symBL$("$symEQ" * 76)"
            Write-Host ""
            Write-Host $bar -ForegroundColor DarkCyan
            Write-Host "  $symVert  PHASE $Number - $Title" -ForegroundColor Cyan
            Write-Host "  $symVert  $Description" -ForegroundColor DarkGray
            Write-Host $end -ForegroundColor DarkCyan
        }

        function Write-ChainItem {
            param(
                [string]$Label,
                [string]$Status,        # OK, WARN, FAIL, INFO
                [string]$Detail = '',
                [switch]$IsLast
            )
            $connector = if ($IsLast) { $symEND } else { $symLINK }
            switch ($Status) {
                'OK'   { $icon = $symOK;   $col = 'Green'  }
                'WARN' { $icon = $symWARN; $col = 'Yellow' }
                'FAIL' { $icon = $symFAIL; $col = 'Red'    }
                'INFO' { $icon = $symINFO; $col = 'DarkGray' }
                default { $icon = $symARROW; $col = 'White' }
            }
            Write-Host "  $symCHAIN" -ForegroundColor DarkGray -NoNewline
            Write-Host "  $connector " -ForegroundColor DarkGray -NoNewline
            Write-Host "$icon " -ForegroundColor $col -NoNewline
            Write-Host "$Label" -ForegroundColor White -NoNewline
            if ($Detail) { Write-Host "  $Detail" -ForegroundColor DarkGray }
            else { Write-Host "" }
        }

        function Test-BootFile {
            param([string]$Path, [string]$Label, [switch]$SkipSignature)
            $obj = [PSCustomObject]@{
                Label     = $Label
                Path      = $Path
                Exists    = $false
                Size      = 0
                SizeStr   = ''
                SigStatus = ''
                IsMicrosoft = $false
                Health    = 'FAIL'
                Detail    = ''
            }
            if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
                $obj.Detail = "MISSING  -  $Path"
                return $obj
            }
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            $obj.Exists = $true
            $obj.Size = if ($item) { $item.Length } else { 0 }
            $obj.SizeStr = '{0:N0}' -f $obj.Size

            if ($obj.Size -eq 0) {
                $obj.Health = 'FAIL'
                $obj.Detail = "0 BYTES (corrupt)  -  $Path"
                return $obj
            }

            if (-not $SkipSignature) {
                $sig = Test-MicrosoftSignature -FilePath $Path
                $obj.SigStatus = $sig.Status
                $obj.IsMicrosoft = $sig.IsMicrosoft
                if (-not $sig.IsMicrosoft -and -not $sig.IsSigned) {
                    $obj.Health = 'WARN'
                    $obj.Detail = "Not signed ($($sig.Status))  -  $Path ($($obj.SizeStr) bytes)"
                    return $obj
                }
                elseif (-not $sig.IsMicrosoft -and $sig.IsSigned) {
                    $obj.Health = 'WARN'
                    $obj.Detail = "Signed by '$($sig.Subject)' (not Microsoft)  -  $Path ($($obj.SizeStr) bytes)"
                    return $obj
                }
            }

            $obj.Health = 'OK'
            $obj.Detail = "$Path ($($obj.SizeStr) bytes)"
            return $obj
        }
        #endregion

        # Accumulate issues for the summary
        $issues = [System.Collections.Generic.List[PSCustomObject]]::new()
        $totalChecks = 0

        Write-Host ""
        Write-Host "  $("$symEQ" * 76)" -ForegroundColor Cyan
        Write-Host "                     WINDOWS BOOT PATH HEALTH CHECK" -ForegroundColor White
        Write-Host "  $("$symEQ" * 76)" -ForegroundColor Cyan
        $genLabel = if ($script:VMGen -eq 2) { 'Generation 2 (UEFI / GPT)' } else { 'Generation 1 (BIOS / MBR)' }
        Write-Host "  VM Generation  : $genLabel" -ForegroundColor DarkGray
        Write-Host "  Windows Drive  : $($script:WinDriveLetter)" -ForegroundColor DarkGray
        Write-Host "  Boot Drive     : $($script:BootDriveLetter)" -ForegroundColor DarkGray

        #region ===================================================================
        # PHASE 1  -  PRE-BOOT: Partition Table & Disk Layout
        #=========================================================================
        Write-Phase 1 'PRE-BOOT' 'Firmware POST -> partition table -> identify boot partition'

        $disk = Get-Disk -Number $script:DiskNumber -ErrorAction SilentlyContinue
        $partStyle = if ($disk) { $disk.PartitionStyle } else { 'Unknown' }
        Write-ChainItem -Label "Partition style: $partStyle" -Status 'INFO'

        $partitions = Get-Partition -DiskNumber $script:DiskNumber -ErrorAction SilentlyContinue
        $bootPartFound = $false
        $winPartFound = $false

        foreach ($part in $partitions) {
            $access = ($part.AccessPaths | Where-Object { $_ -match '^[A-Z]:\\$' }) | Select-Object -First 1
            if (-not $access) { continue }
            $accessClean = $access.TrimEnd('\')

            $isBootPart = ($accessClean -eq $script:BootDriveLetter.TrimEnd('\'))
            $isWinPart  = ($accessClean -eq $script:WinDriveLetter.TrimEnd('\'))

            $roles = @()
            if ($isBootPart) { $roles += 'BOOT'; $bootPartFound = $true }
            if ($isWinPart)  { $roles += 'WINDOWS'; $winPartFound = $true }
            if ($roles.Count -eq 0) { continue }

            $roleStr = $roles -join ' + '
            $sizeGB  = '{0:N2} GB' -f ($part.Size / 1GB)

            # Boot partition health checks
            if ($isBootPart) {
                if ($script:VMGen -eq 1) {
                    $actStatus = if ($part.IsActive) { 'OK' } else { 'FAIL' }
                    Write-ChainItem -Label "Partition $($part.PartitionNumber) [$roleStr]  -  $sizeGB" -Status $actStatus -Detail $(if ($part.IsActive) { '(Active flag set)' } else { 'Active flag NOT set  -  firmware cannot find this partition' })
                    if (-not $part.IsActive) {
                        $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 1; Severity = 'FAIL'; Message = "Boot partition $($part.PartitionNumber) missing Active flag"; Fix = '-FixBoot' })
                    }
                }
                else {
                    $typeLabel = if ($part.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') { 'EFI System Partition' } else { $part.GptType }
                    Write-ChainItem -Label "Partition $($part.PartitionNumber) [$roleStr]  -  $sizeGB  -  $typeLabel" -Status 'OK'
                }
            }
            if ($isWinPart -and -not $isBootPart) {
                Write-ChainItem -Label "Partition $($part.PartitionNumber) [$roleStr]  -  $sizeGB" -Status 'OK'
            }
        }

        if (-not $bootPartFound) {
            Write-ChainItem -Label 'Boot partition' -Status 'FAIL' -Detail 'NOT FOUND  -  firmware has no partition to start from' -IsLast
            $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 1; Severity = 'FAIL'; Message = 'No boot partition found'; Fix = '-RecreateBootPartition' })
        }
        if (-not $winPartFound) {
            Write-ChainItem -Label 'Windows partition' -Status 'FAIL' -Detail 'NOT FOUND  -  no partition contains Windows\System32' -IsLast
            $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 1; Severity = 'FAIL'; Message = 'No Windows partition found'; Fix = '' })
        }
        $totalChecks += 2  # boot + win partition

        #endregion

        #region ===================================================================
        # PHASE 2  -  BOOT MANAGER: bootmgr / BCD Store
        #=========================================================================
        Write-Phase 2 'BOOT MANAGER' 'Firmware loads boot manager -> reads BCD -> selects OS entry'

        # 2a. Boot manager binary
        $bootMgrFiles = @()
        if ($script:VMGen -eq 1) {
            $bootMgrFiles += @{ Label = 'bootmgr'; Path = (Join-Path $script:BootDriveLetter 'bootmgr') }
        }
        else {
            $bootMgrFiles += @{ Label = 'bootmgfw.efi'; Path = (Join-Path $script:BootDriveLetter 'EFI\Microsoft\Boot\bootmgfw.efi') }
            $bootMgrFiles += @{ Label = 'bootx64.efi (fallback)'; Path = (Join-Path $script:BootDriveLetter 'EFI\Boot\bootx64.efi') }
        }
        foreach ($bmf in $bootMgrFiles) {
            $r = Test-BootFile -Path $bmf.Path -Label $bmf.Label
            Write-ChainItem -Label "$($bmf.Label)" -Status $r.Health -Detail $r.Detail
            $totalChecks++
            if ($r.Health -ne 'OK') { $issues.Add([PSCustomObject]@{ Phase = 2; Severity = $r.Health; Message = "$($bmf.Label): $($r.Detail)"; Fix = '-FixBoot' }) }
        }

        # 2b. BCD store
        $bcdStore = Get-BcdStorePath -BootDrive $script:BootDriveLetter -Generation $script:VMGen
        $bcdResult = Test-BootFile -Path $bcdStore -Label 'BCD store' -SkipSignature
        Write-ChainItem -Label "BCD store" -Status $bcdResult.Health -Detail $bcdResult.Detail
        $totalChecks++
        if ($bcdResult.Health -ne 'OK') { $issues.Add([PSCustomObject]@{ Phase = 2; Severity = $bcdResult.Health; Message = "BCD store: $($bcdResult.Detail)"; Fix = '-FixBoot' }) }

        # 2c. Parse BCD entries if store exists
        $bcdWinloadPath = $null
        $bcdSystemRoot = '\Windows'
        $bcdFlags = @()
        if ($bcdResult.Exists -and $bcdResult.Size -gt 0) {
            try {
                $bcdText = (& bcdedit.exe /store "$bcdStore" /enum all 2>&1) | Out-String

                # Boot Manager section
                $bmgrTimeout = if ($bcdText -match '(?im)timeout\s+(\d+)') { $Matches[1] + 's' } else { 'default' }
                Write-ChainItem -Label "BCD timeout: $bmgrTimeout" -Status 'INFO'

                # Extract Boot Manager section and validate its path
                $bmgrSection = ''
                $allSections = $bcdText -split '(?m)^-{3,}'
                foreach ($sec in $allSections) {
                    if ($sec -match 'bootmgr|Windows Boot Manager') {
                        $bmgrSection = $sec
                        break
                    }
                }
                if ($bmgrSection) {
                    $bmgrPath = if ($bmgrSection -match '(?im)^\s*path\s+(.+)$') { $Matches[1].Trim() } else { '' }
                    if ($bmgrPath) {
                        $expectedBmgr = if ($script:VMGen -eq 2) { '\EFI\Microsoft\Boot\bootmgfw.efi' } else { '\bootmgr' }
                        Write-ChainItem -Label "Boot Manager path : $bmgrPath" -Status 'INFO'
                        if (-not [string]::Equals($bmgrPath, $expectedBmgr, [System.StringComparison]::OrdinalIgnoreCase)) {
                            Write-ChainItem -Label "Boot Manager path mismatch" -Status 'WARN' -Detail "Expected '$expectedBmgr', found '$bmgrPath'"
                            $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 2; Severity = 'WARN'; Message = "Boot Manager path is '$bmgrPath' (expected '$expectedBmgr')"; Fix = '-FixBoot' })
                        }
                    }
                }

                # Windows Boot Loader section
                $hasLoader = $bcdText -match 'Windows Boot Loader|osloader'
                if (-not $hasLoader) {
                    Write-ChainItem -Label 'Windows Boot Loader entry' -Status 'FAIL' -Detail 'No osloader/Windows Boot Loader entry found in BCD'
                    $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 2; Severity = 'FAIL'; Message = 'No Windows Boot Loader entry in BCD'; Fix = '-FixBoot' })
                }
                else {
                    Write-ChainItem -Label 'Windows Boot Loader entry present' -Status 'OK'

                    # Extract key BCD values from the OS Loader section (not Boot Manager)
                    # Split the full BCD output into sections; find the Windows Boot Loader block
                    $loaderSection = ''
                    $sections = $bcdText -split '(?m)^-{3,}'
                    foreach ($sec in $sections) {
                        if ($sec -match 'osloader|Windows Boot Loader') {
                            $loaderSection = $sec
                            break
                        }
                    }
                    if (-not $loaderSection) { $loaderSection = $bcdText }

                    $bcdDevice   = if ($loaderSection -match '(?im)^\s*device\s+(.+)$') { $Matches[1].Trim() } else { '' }
                    $bcdOsDevice = if ($loaderSection -match '(?im)^\s*osdevice\s+(.+)$') { $Matches[1].Trim() } else { '' }
                    $bcdPath     = if ($loaderSection -match '(?im)^\s*path\s+(.+)$') { $Matches[1].Trim() } else { '' }
                    $bcdSysRoot  = if ($loaderSection -match '(?im)^\s*systemroot\s+(.+)$') { $Matches[1].Trim() } else { '\Windows' }
                    $bcdNx       = if ($loaderSection -match '(?im)^\s*nx\s+(.+)$') { $Matches[1].Trim() } else { '' }

                    $bcdWinloadPath = $bcdPath
                    $bcdSystemRoot = $bcdSysRoot

                    Write-ChainItem -Label "device     : $bcdDevice" -Status 'INFO'
                    Write-ChainItem -Label "osdevice   : $bcdOsDevice" -Status 'INFO'
                    Write-ChainItem -Label "path       : $bcdPath" -Status 'INFO'
                    Write-ChainItem -Label "systemroot : $bcdSysRoot" -Status 'INFO'
                    if ($bcdNx) { Write-ChainItem -Label "nx         : $bcdNx" -Status 'INFO' }

                    # Device pointing to unknown
                    if ($bcdDevice -match '\bunknown\b' -or $bcdOsDevice -match '\bunknown\b') {
                        Write-ChainItem -Label 'BCD device references UNKNOWN partition' -Status 'FAIL' -Detail 'device/osdevice points to missing or wrong partition'
                        $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 2; Severity = 'FAIL'; Message = 'BCD device/osdevice references unknown partition'; Fix = '-FixBoot' })
                    }

                    # Path mismatch for Gen
                    $expectedLoader = if ($script:VMGen -eq 2) { '\Windows\System32\winload.efi' } else { '\Windows\System32\winload.exe' }
                    if ($bcdPath -and -not [string]::Equals($bcdPath, $expectedLoader, [System.StringComparison]::OrdinalIgnoreCase)) {
                        Write-ChainItem -Label "BCD path mismatch" -Status 'WARN' -Detail "Expected '$expectedLoader', found '$bcdPath'"
                        $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 2; Severity = 'WARN'; Message = "BCD loader path is '$bcdPath' (expected '$expectedLoader')"; Fix = '-FixBoot' })
                    }
                }

                # BCD flags that affect boot behaviour
                if ($bcdText -match 'safeboot\s+(\S+)') {
                    $bcdFlags += "SafeMode=$($Matches[1])"
                    Write-ChainItem -Label "Safe Mode flag active ($($Matches[1]))" -Status 'WARN' -Detail 'VM will boot into Safe Mode'
                    $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 2; Severity = 'WARN'; Message = "SafeMode boot flag is set ($($Matches[1]))"; Fix = '-RemoveSafeModeFlag' })
                }
                if ($bcdText -match 'testsigning\s+yes') {
                    $bcdFlags += 'TestSigning'
                    Write-ChainItem -Label 'Test Signing is ON' -Status 'WARN' -Detail 'Unsigned drivers are allowed to load'
                    $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 2; Severity = 'WARN'; Message = 'Test signing is enabled'; Fix = '-DisableTestSigning' })
                }
                if ($bcdText -match 'nointegritychecks\s+yes') {
                    $bcdFlags += 'NoIntegrityChecks'
                    Write-ChainItem -Label 'nointegritychecks is ON' -Status 'WARN' -Detail 'Code integrity checks bypassed; FATAL with Secure Boot'
                    $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 2; Severity = 'WARN'; Message = 'nointegritychecks is ON'; Fix = '-FixBoot' })
                }
                if ($bcdText -match 'recoveryenabled\s+no') {
                    $bcdFlags += 'RecoveryDisabled'
                    Write-ChainItem -Label 'Recovery is disabled' -Status 'WARN' -Detail 'WinRE recovery environment will not launch on failure'
                }
                if ($bcdText -match 'bootstatuspolicy\s+ignoreallfailures') {
                    $bcdFlags += 'IgnoreAllFailures'
                    Write-ChainItem -Label 'bootstatuspolicy: IgnoreAllFailures' -Status 'INFO' -Detail 'Startup repair suppressed on failure'
                }
                if ($bcdText -match 'bootlog\s+yes') {
                    $bcdFlags += 'BootLog'
                    Write-ChainItem -Label 'Boot logging enabled' -Status 'INFO' -Detail 'ntbtlog.txt will be created on boot'
                }
                if ($bcdText -match '(?im)^\s*debug\s+Yes') {
                    $bcdFlags += 'KernelDebug'
                    Write-ChainItem -Label 'Kernel debugging enabled' -Status 'INFO'
                }
                if ($bcdText -match 'imcdevice|imchivename') {
                    $bcdFlags += 'IMC-Hive'
                    Write-ChainItem -Label 'IMC hive (imcdevice/imchivename) in BCD' -Status 'FAIL' -Detail 'Causes BSOD 0x67 CONFIG_INITIALIZATION_FAILED'
                    $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 2; Severity = 'FAIL'; Message = 'BCD contains IMC hive entries  -  causes BSOD 0x67'; Fix = '-FixBoot' })
                }

                # Resume object (hibernate)
                if ($bcdText -match 'resumeobject') {
                    Write-ChainItem -Label 'Resume from Hibernation entry present' -Status 'INFO'
                }
            }
            catch {
                Write-ChainItem -Label "BCD parse error: $_" -Status 'WARN'
            }
        }

        #endregion

        #region ===================================================================
        # PHASE 3  -  OS LOADER: winload -> Kernel + HAL + SYSTEM hive + Boot drivers
        #=========================================================================
        Write-Phase 3 'OS LOADER' 'winload loads kernel, HAL, SYSTEM hive, registry, boot-start drivers (Start=0)'

        # 3a. winload binary
        $winloadPath = if ($script:VMGen -eq 2) { 'Windows\System32\winload.efi' } else { 'Windows\System32\winload.exe' }
        $winloadFull = Join-Path $script:WinDriveLetter $winloadPath
        $winloadName = if ($script:VMGen -eq 2) { 'winload.efi' } else { 'winload.exe' }
        $r = Test-BootFile -Path $winloadFull -Label $winloadName
        Write-ChainItem -Label "$winloadName (OS Loader)" -Status $r.Health -Detail $r.Detail
        $totalChecks++
        if ($r.Health -ne 'OK') { $issues.Add([PSCustomObject]@{ Phase = 3; Severity = $r.Health; Message = "$winloadName : $($r.Detail)"; Fix = '-FixBoot' }) }

        # 3b. Kernel and HAL
        $kernelFiles = @(
            @{ Label = 'ntoskrnl.exe (Windows Kernel)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\ntoskrnl.exe') }
            @{ Label = 'hal.dll (Hardware Abstraction Layer)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\hal.dll') }
            @{ Label = 'ci.dll (Code Integrity)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\ci.dll') }
            @{ Label = 'clfs.sys (Common Log File System)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\drivers\clfs.sys') }
            @{ Label = 'pshed.dll (Platform-Specific HW Error Driver)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\pshed.dll') }
            @{ Label = 'bootvid.dll (Boot Video Driver)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\bootvid.dll') }
        )
        foreach ($kf in $kernelFiles) {
            $r = Test-BootFile -Path $kf.Path -Label $kf.Label
            Write-ChainItem -Label $kf.Label -Status $r.Health -Detail $r.Detail
            $totalChecks++
            if ($r.Health -ne 'OK') { $issues.Add([PSCustomObject]@{ Phase = 3; Severity = $r.Health; Message = "$($kf.Label): $($r.Detail)"; Fix = "-RepairSystemFile $(Split-Path -Leaf $kf.Path)" }) }
        }

        # 3c. SYSTEM registry hive
        $sysHivePath = Join-Path $script:WinDriveLetter 'Windows\System32\config\SYSTEM'
        $sysHiveResult = Test-BootFile -Path $sysHivePath -Label 'SYSTEM registry hive' -SkipSignature
        Write-ChainItem -Label 'SYSTEM registry hive' -Status $sysHiveResult.Health -Detail $sysHiveResult.Detail
        $totalChecks++
        if ($sysHiveResult.Health -ne 'OK') { $issues.Add([PSCustomObject]@{ Phase = 3; Severity = 'FAIL'; Message = "SYSTEM hive: $($sysHiveResult.Detail)"; Fix = '-RestoreRegistryFromRegBack' }) }

        # 3d. Boot-start drivers (Start=0)  -  loaded by winload before kernel takes over
        Write-Host ""
        Write-Host "  $symCHAIN  $symARROW  Boot-Start Drivers (Start=0)  -  loaded by $winloadName before kernel init" -ForegroundColor White

        $bootDriverResults = [System.Collections.Generic.List[PSCustomObject]]::new()
        $bootDriverFail = 0
        $bootDriverWarn = 0

        Invoke-WithHive 'SYSTEM' {
            $sysRoot = Get-SystemRootPath
            $svcPath = "$sysRoot\Services"
            $startNames = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
            $typeNames  = @{ 1 = 'Kernel'; 2 = 'FileSystem'; 4 = 'Adapter'; 8 = 'Recognizer' }
            $errorCtlNames = @{ 0 = 'Ignore'; 1 = 'Normal'; 2 = 'Severe'; 3 = 'Critical' }

            # Drivers that are functionally critical on Azure/Hyper-V regardless of ErrorControl.
            # Missing any of these will BSOD the VM (e.g. 0x7B INACCESSIBLE_BOOT_DEVICE) even
            # though their ErrorControl may be Normal (1).
            $azureCriticalDrivers = @('vmbus', 'storvsc', 'storflt', 'vmstorfl', 'netvsc')

            # Enumerate Start=0 (boot) drivers
            $bootDrivers = @()
            Get-ChildItem $svcPath -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $p -or $null -eq $p.Start -or $null -eq $p.Type) { return }
                if ([int]$p.Start -ne 0) { return }
                if ([int]$p.Type -notin @(1, 2, 4, 8)) { return }  # Drivers only
                $bootDrivers += [PSCustomObject]@{
                    Name         = $_.PSChildName
                    Type         = $typeNames[[int]$p.Type]
                    Group        = if ($p.Group) { $p.Group } else { '(none)' }
                    ErrorControl = if ($null -ne $p.ErrorControl) { [int]$p.ErrorControl } else { 1 }
                    ErrorCtlName = $errorCtlNames[$(if ($null -ne $p.ErrorControl) { [int]$p.ErrorControl } else { 1 })]
                    ImagePath    = $p.ImagePath
                    Tag          = if ($null -ne $p.Tag) { [int]$p.Tag } else { 9999 }
                }
            }

            # Sort by Group then Tag (mimics Windows boot driver load order)
            # Read ServiceGroupOrder from registry for authentic ordering
            $groupOrderPath = "$sysRoot\Control\ServiceGroupOrder"
            $groupList = @()
            if (Test-Path $groupOrderPath) {
                $groupList = @((Get-ItemProperty $groupOrderPath -ErrorAction SilentlyContinue).List)
            }
            # Build group priority map
            $groupPriority = @{}
            for ($i = 0; $i -lt $groupList.Count; $i++) { $groupPriority[$groupList[$i]] = $i }

            $bootDrivers = $bootDrivers | Sort-Object @{
                Expression = { if ($groupPriority.ContainsKey($_.Group)) { $groupPriority[$_.Group] } else { 9999 } }
            }, Tag

            $currentGroup = ''
            foreach ($drv in $bootDrivers) {
                if ($drv.Group -ne $currentGroup) {
                    $currentGroup = $drv.Group
                    Write-Host "  $symCHAIN      -- Group: $currentGroup --" -ForegroundColor DarkCyan
                }
                # Windows default: if ImagePath is absent, the driver file is System32\Drivers\<name>.sys
                $imgResolved = if ($drv.ImagePath) {
                    Resolve-GuestImagePath $drv.ImagePath
                } else {
                    Join-Path $script:WinDriveLetter "Windows\System32\drivers\$($drv.Name).sys"
                }
                $fileExists = if ($imgResolved) { Test-Path -LiteralPath $imgResolved } else { $false }
                $fileSize = if ($fileExists) { (Get-Item -LiteralPath $imgResolved -Force -ErrorAction SilentlyContinue).Length } else { 0 }

                $health = 'OK'
                $detail = ''
                $isAzureCritical = $azureCriticalDrivers -contains $drv.Name
                if (-not $imgResolved -or -not $fileExists) {
                    $health = if ($drv.ErrorControl -ge 2 -or $isAzureCritical) { 'FAIL' } else { 'WARN' }
                    $detail = "MISSING binary  -  ErrorControl=$($drv.ErrorCtlName)"
                    if ($isAzureCritical) { $detail += ' (Azure/Hyper-V critical  -  will BSOD)' }
                    elseif ($drv.ErrorControl -ge 3) { $detail += ' (CRITICAL  -  will BSOD)' }
                    elseif ($drv.ErrorControl -ge 2) { $detail += ' (SEVERE  -  LKGC fallback)' }
                }
                elseif ($fileSize -eq 0) {
                    $health = if ($drv.ErrorControl -ge 2 -or $isAzureCritical) { 'FAIL' } else { 'WARN' }
                    $detail = "0 BYTES (corrupt)  -  ErrorControl=$($drv.ErrorCtlName)"
                    if ($isAzureCritical) { $detail += ' (Azure/Hyper-V critical  -  will BSOD)' }
                }
                else {
                    # Spot-check signature for non-Microsoft drivers
                    $vi = (Get-Item -LiteralPath $imgResolved -Force -ErrorAction SilentlyContinue).VersionInfo
                    $vendor = if ($vi -and $vi.CompanyName) { $vi.CompanyName.Trim() } else { '' }
                    if ($vendor -and $vendor -notmatch 'Microsoft') {
                        $detail = "3rd-party ($vendor)"
                    }
                    else {
                        $detail = if ($imgResolved) { "$('{0:N0}' -f $fileSize) bytes" } else { '' }
                    }
                }

                $label = "$($drv.Name) ($($drv.Type))"
                Write-Host "  $symCHAIN      " -ForegroundColor DarkGray -NoNewline
                switch ($health) {
                    'OK'   { Write-Host "$symOK " -ForegroundColor Green -NoNewline }
                    'WARN' { Write-Host "$symWARN " -ForegroundColor Yellow -NoNewline }
                    'FAIL' { Write-Host "$symFAIL " -ForegroundColor Red -NoNewline }
                }
                Write-Host "$label" -ForegroundColor White -NoNewline
                if ($detail) { Write-Host "  $detail" -ForegroundColor DarkGray } else { Write-Host "" }

                $totalChecks++
                if ($health -eq 'FAIL') {
                    $bootDriverFail++
                    $issues.Add([PSCustomObject]@{ Phase = 3; Severity = 'FAIL'; Message = "Boot driver '$($drv.Name)': $detail"; Fix = "-RepairSystemFile $(Split-Path -Leaf $drv.ImagePath)" })
                }
                elseif ($health -eq 'WARN') {
                    $bootDriverWarn++
                    $issues.Add([PSCustomObject]@{ Phase = 3; Severity = 'WARN'; Message = "Boot driver '$($drv.Name)': $detail"; Fix = '' })
                }
            }

            Write-Host "  $symCHAIN      -- $($bootDrivers.Count) boot-start drivers ($bootDriverFail fail, $bootDriverWarn warn) --" -ForegroundColor DarkGray

            #region ===============================================================
            # PHASE 4  -  NTOS KERNEL INIT: Session Manager, system drivers, services
            #=====================================================================
            Write-Phase 4 'NTOS KERNEL' 'Kernel init -> Session Manager -> Csrss -> Wininit -> Services.exe -> system drivers (Start=1)'

            # 4a. Core kernel-phase executables
            $kernelInitFiles = @(
                @{ Label = 'ntdll.dll (NT Layer DLL)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\ntdll.dll') }
                @{ Label = 'smss.exe (Session Manager)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\smss.exe') }
                @{ Label = 'csrss.exe (Client/Server Runtime)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\csrss.exe') }
                @{ Label = 'wininit.exe (Windows Init Process)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\wininit.exe') }
                @{ Label = 'services.exe (Service Control Manager)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\services.exe') }
                @{ Label = 'lsass.exe (Local Security Authority)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\lsass.exe') }
                @{ Label = 'svchost.exe (Service Host)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\svchost.exe') }
                @{ Label = 'kernel32.dll (Win32 Kernel)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\kernel32.dll') }
                @{ Label = 'KernelBase.dll (Kernel Base)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\KernelBase.dll') }
                @{ Label = 'advapi32.dll (Advanced API)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\advapi32.dll') }
                @{ Label = 'rpcrt4.dll (RPC Runtime)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\rpcrt4.dll') }
            )
            foreach ($kif in $kernelInitFiles) {
                $r = Test-BootFile -Path $kif.Path -Label $kif.Label
                Write-ChainItem -Label $kif.Label -Status $r.Health -Detail $r.Detail
                $totalChecks++
                if ($r.Health -ne 'OK') { $issues.Add([PSCustomObject]@{ Phase = 4; Severity = $r.Health; Message = "$($kif.Label): $($r.Detail)"; Fix = "-RepairSystemFile $(Split-Path -Leaf $kif.Path)" }) }
            }

            # 4b. Session Manager registry configuration
            Write-Host ""
            Write-Host "  $symCHAIN  $symARROW  Session Manager Configuration (BootExecute / SetupExecute)" -ForegroundColor White
            $smPath = "$sysRoot\Control\Session Manager"
            if (Test-Path $smPath) {
                $smProps = Get-ItemProperty $smPath -ErrorAction SilentlyContinue
                $sys32Path = Join-Path $script:WinDriveLetter 'Windows\System32'

                # BootExecute
                $bootExec = @($smProps.BootExecute | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
                if ($bootExec.Count -eq 0) {
                    Write-ChainItem -Label 'BootExecute: (empty)' -Status 'WARN' -Detail 'Missing default autocheck entry'
                    $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 4; Severity = 'WARN'; Message = 'BootExecute is empty (missing autocheck autochk *)'; Fix = '-FixSessionManager' })
                }
                else {
                    foreach ($entry in $bootExec) {
                        $nativeName = ($entry -split '\s+', 2)[0]
                        $nativePath = Join-Path $sys32Path "$nativeName.exe"
                        $isDefault = ($entry -match '^autocheck\s+autochk')
                        if ($isDefault) {
                            $exists = Test-Path -LiteralPath (Join-Path $sys32Path 'autochk.exe')
                            Write-ChainItem -Label "BootExecute: $entry" -Status $(if ($exists) { 'OK' } else { 'FAIL' }) -Detail $(if (-not $exists) { 'autochk.exe MISSING' } else { '' })
                            $totalChecks++
                            if (-not $exists) { $issues.Add([PSCustomObject]@{ Phase = 4; Severity = 'FAIL'; Message = 'autochk.exe missing for BootExecute'; Fix = '-RepairSystemFile autochk.exe' }) }
                        }
                        else {
                            $exists = Test-Path -LiteralPath $nativePath
                            $status = if (-not $exists) { 'WARN' } else { 'INFO' }
                            Write-ChainItem -Label "BootExecute: $entry" -Status $status -Detail $(if (-not $exists) { "Binary $nativeName.exe MISSING (third-party)" } else { '(non-default entry)' })
                            $totalChecks++
                            if (-not $exists) { $issues.Add([PSCustomObject]@{ Phase = 4; Severity = 'WARN'; Message = "BootExecute entry '$entry' references missing binary $nativeName.exe"; Fix = '-FixSessionManager' }) }
                        }
                    }
                }

                # SetupExecute (should be empty after setup completes)
                $setupExec = @($smProps.SetupExecute | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
                if ($setupExec.Count -gt 0) {
                    foreach ($entry in $setupExec) {
                        Write-ChainItem -Label "SetupExecute: $entry" -Status 'WARN' -Detail 'Should be empty on a fully provisioned OS  -  pending setup operation'
                        $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 4; Severity = 'WARN'; Message = "SetupExecute is not empty: '$entry'"; Fix = '-FixSessionManager' })
                    }
                }
                else {
                    Write-ChainItem -Label 'SetupExecute: (empty  -  normal)' -Status 'OK'
                }

                # PendingFileRenameOperations
                $pendRenames = @($smProps.PendingFileRenameOperations | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($pendRenames.Count -gt 0) {
                    Write-ChainItem -Label "PendingFileRenameOperations: $($pendRenames.Count) entries" -Status 'INFO' -Detail 'Pending file renames will execute on boot'
                }

                # SubSystems  -  required for csrss.exe
                $requiredSubsys = $smProps.Required
                if ($requiredSubsys) {
                    Write-ChainItem -Label "Required SubSystems: $($requiredSubsys -join ', ')" -Status 'INFO'
                }
            }
            else {
                Write-ChainItem -Label 'Session Manager key' -Status 'FAIL' -Detail 'Registry key not found'
                $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 4; Severity = 'FAIL'; Message = 'Session Manager registry key not found'; Fix = '-RestoreRegistryFromRegBack' })
            }

            # 4c. System-start drivers (Start=1)  -  loaded by kernel after boot-start drivers
            Write-Host ""
            Write-Host "  $symCHAIN  $symARROW  System-Start Drivers (Start=1)  -  loaded after kernel takes control" -ForegroundColor White

            $sysDriverFail = 0
            $sysDriverWarn = 0
            $sysDrivers = @()
            Get-ChildItem $svcPath -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $p -or $null -eq $p.Start -or $null -eq $p.Type) { return }
                if ([int]$p.Start -ne 1) { return }
                if ([int]$p.Type -notin @(1, 2, 4, 8)) { return }
                $sysDrivers += [PSCustomObject]@{
                    Name         = $_.PSChildName
                    Type         = $typeNames[[int]$p.Type]
                    Group        = if ($p.Group) { $p.Group } else { '(none)' }
                    ErrorControl = if ($null -ne $p.ErrorControl) { [int]$p.ErrorControl } else { 1 }
                    ErrorCtlName = $errorCtlNames[$(if ($null -ne $p.ErrorControl) { [int]$p.ErrorControl } else { 1 })]
                    ImagePath    = $p.ImagePath
                    Tag          = if ($null -ne $p.Tag) { [int]$p.Tag } else { 9999 }
                }
            }

            $sysDrivers = $sysDrivers | Sort-Object @{
                Expression = { if ($groupPriority.ContainsKey($_.Group)) { $groupPriority[$_.Group] } else { 9999 } }
            }, Tag

            $currentGroup = ''
            foreach ($drv in $sysDrivers) {
                if ($drv.Group -ne $currentGroup) {
                    $currentGroup = $drv.Group
                    Write-Host "  $symCHAIN      -- Group: $currentGroup --" -ForegroundColor DarkCyan
                }
                # Windows default: if ImagePath is absent, the driver file is System32\Drivers\<name>.sys
                $imgResolved = if ($drv.ImagePath) {
                    Resolve-GuestImagePath $drv.ImagePath
                } else {
                    Join-Path $script:WinDriveLetter "Windows\System32\drivers\$($drv.Name).sys"
                }
                $fileExists = if ($imgResolved) { Test-Path -LiteralPath $imgResolved } else { $false }
                $fileSize = if ($fileExists) { (Get-Item -LiteralPath $imgResolved -Force -ErrorAction SilentlyContinue).Length } else { 0 }

                $health = 'OK'
                $detail = ''
                $isAzureCritical = $azureCriticalDrivers -contains $drv.Name
                if (-not $imgResolved -or -not $fileExists) {
                    $health = if ($drv.ErrorControl -ge 2 -or $isAzureCritical) { 'FAIL' } else { 'WARN' }
                    $detail = "MISSING binary  -  ErrorControl=$($drv.ErrorCtlName)"
                    if ($isAzureCritical) { $detail += ' (Azure/Hyper-V critical  -  will BSOD)' }
                    elseif ($drv.ErrorControl -ge 3) { $detail += ' (CRITICAL  -  will BSOD)' }
                    elseif ($drv.ErrorControl -ge 2) { $detail += ' (SEVERE  -  LKGC fallback)' }
                }
                elseif ($fileSize -eq 0) {
                    $health = if ($drv.ErrorControl -ge 2 -or $isAzureCritical) { 'FAIL' } else { 'WARN' }
                    $detail = "0 BYTES (corrupt)  -  ErrorControl=$($drv.ErrorCtlName)"
                    if ($isAzureCritical) { $detail += ' (Azure/Hyper-V critical  -  will BSOD)' }
                }
                else {
                    $vi = (Get-Item -LiteralPath $imgResolved -Force -ErrorAction SilentlyContinue).VersionInfo
                    $vendor = if ($vi -and $vi.CompanyName) { $vi.CompanyName.Trim() } else { '' }
                    if ($vendor -and $vendor -notmatch 'Microsoft') {
                        $detail = "3rd-party ($vendor)"
                    }
                    else {
                        $detail = "$('{0:N0}' -f $fileSize) bytes"
                    }
                }

                Write-Host "  $symCHAIN      " -ForegroundColor DarkGray -NoNewline
                switch ($health) {
                    'OK'   { Write-Host "$symOK " -ForegroundColor Green -NoNewline }
                    'WARN' { Write-Host "$symWARN " -ForegroundColor Yellow -NoNewline }
                    'FAIL' { Write-Host "$symFAIL " -ForegroundColor Red -NoNewline }
                }
                Write-Host "$($drv.Name) ($($drv.Type))" -ForegroundColor White -NoNewline
                if ($detail) { Write-Host "  $detail" -ForegroundColor DarkGray } else { Write-Host "" }

                $totalChecks++
                if ($health -eq 'FAIL') {
                    $sysDriverFail++
                    $issues.Add([PSCustomObject]@{ Phase = 4; Severity = 'FAIL'; Message = "System driver '$($drv.Name)': $detail"; Fix = "-RepairSystemFile $(Split-Path -Leaf $drv.ImagePath)" })
                }
                elseif ($health -eq 'WARN') {
                    $sysDriverWarn++
                    $issues.Add([PSCustomObject]@{ Phase = 4; Severity = 'WARN'; Message = "System driver '$($drv.Name)': $detail"; Fix = '' })
                }
            }
            Write-Host "  $symCHAIN      -- $($sysDrivers.Count) system-start drivers ($sysDriverFail fail, $sysDriverWarn warn) --" -ForegroundColor DarkGray

            # 4d. Auto-start services (Start=2)  -  launched by services.exe
            Write-Host ""
            Write-Host "  $symCHAIN  $symARROW  Auto-Start Services (Start=2)  -  launched by services.exe" -ForegroundColor White

            $autoSvcFail = 0
            $autoSvcWarn = 0
            $autoSvcCount = 0
            Get-ChildItem $svcPath -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $p -or $null -eq $p.Start -or $null -eq $p.Type) { return }
                if ([int]$p.Start -ne 2) { return }
                if ([int]$p.Type -notin @(16, 32, 256)) { return }  # Win32 services only

                $imgRaw = $p.ImagePath
                $imgResolved = if ($imgRaw) { Resolve-GuestImagePath $imgRaw } else { $null }
                $fileExists = if ($imgResolved) { Test-Path -LiteralPath $imgResolved } else { $false }
                $fileSize = if ($fileExists) { (Get-Item -LiteralPath $imgResolved -Force -ErrorAction SilentlyContinue).Length } else { 0 }

                $health = 'OK'
                $detail = ''
                if (-not $imgResolved -or -not $fileExists) {
                    # svchost-hosted services may not have their own binary
                    if ($imgRaw -match 'svchost\.exe') {
                        $health = 'OK'
                        $detail = 'svchost-hosted'
                    }
                    else {
                        $health = 'WARN'
                        $detail = "MISSING binary: $imgRaw"
                    }
                }
                elseif ($fileSize -eq 0) {
                    $health = 'WARN'
                    $detail = '0 BYTES (corrupt)'
                }

                # Only show issues or first few OK to keep noise down
                if ($health -ne 'OK') {
                    Write-Host "  $symCHAIN      " -ForegroundColor DarkGray -NoNewline
                    $icon = if ($health -eq 'FAIL') { $symFAIL } else { $symWARN }
                    $col = if ($health -eq 'FAIL') { 'Red' } else { 'Yellow' }
                    Write-Host "$icon " -ForegroundColor $col -NoNewline
                    Write-Host "$($_.PSChildName)" -ForegroundColor White -NoNewline
                    Write-Host "  $detail" -ForegroundColor DarkGray
                    $totalChecks++
                    if ($health -eq 'FAIL') { $autoSvcFail++ }
                    else { $autoSvcWarn++ }
                    $issues.Add([PSCustomObject]@{ Phase = 4; Severity = $health; Message = "Auto-start service '$($_.PSChildName)': $detail"; Fix = '' })
                }
                $autoSvcCount++
            }
            Write-Host "  $symCHAIN      -- $autoSvcCount auto-start services ($autoSvcFail fail, $autoSvcWarn warn) --" -ForegroundColor DarkGray

            # 4e. Critical registry keys checked during kernel init
            Write-Host ""
            Write-Host "  $symCHAIN  $symARROW  Critical Registry Configuration" -ForegroundColor White

            # ControlSet active check
            $current = (Get-ItemProperty 'HKLM:\BROKENSYSTEM\Select' -ErrorAction SilentlyContinue).Current
            $default = (Get-ItemProperty 'HKLM:\BROKENSYSTEM\Select' -ErrorAction SilentlyContinue).Default
            $lastKnown = (Get-ItemProperty 'HKLM:\BROKENSYSTEM\Select' -ErrorAction SilentlyContinue).LastKnownGood
            if ($current) {
                $csMatch = ($current -eq $default)
                $csLabel = "Active ControlSet: ControlSet{0:d3} (Current=$current, Default=$default, LKGC=$lastKnown)" -f $current
                Write-ChainItem -Label $csLabel -Status $(if ($csMatch) { 'OK' } else { 'INFO' }) -Detail $(if (-not $csMatch) { 'Current != Default (LKGC may have been used)' } else { '' })
            }

            # Memory Management  -  paging settings
            $mmPath = "$sysRoot\Control\Session Manager\Memory Management"
            if (Test-Path $mmPath) {
                $mmProps = Get-ItemProperty $mmPath -ErrorAction SilentlyContinue
                $pagingFiles = $mmProps.PagingFiles
                if ($pagingFiles) {
                    Write-ChainItem -Label "PagingFiles: $($pagingFiles -join '; ')" -Status 'INFO'
                }
                # Driver Verifier
                $verifyDrivers = $mmProps.VerifyDrivers
                $verifyLevel = $mmProps.VerifyDriverLevel
                if ($verifyDrivers -or $verifyLevel) {
                    Write-ChainItem -Label "Driver Verifier ACTIVE  -  Targets: $verifyDrivers (Level: $verifyLevel)" -Status 'WARN' -Detail 'Can cause BSODs if misconfigured'
                    $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 4; Severity = 'WARN'; Message = "Driver Verifier is active (targets: $verifyDrivers)"; Fix = '-DisableDriverVerifier' })
                }
            }

            # CrashControl  -  dump settings
            $ccPath = "$sysRoot\Control\CrashControl"
            if (Test-Path $ccPath) {
                $ccProps = Get-ItemProperty $ccPath -ErrorAction SilentlyContinue
                $dumpType = switch ([int]$ccProps.CrashDumpEnabled) { 0 { 'None' }; 1 { 'Complete' }; 2 { 'Kernel' }; 3 { 'Small (minidump)' }; 7 { 'Automatic' }; default { "$($ccProps.CrashDumpEnabled)" } }
                Write-ChainItem -Label "Crash Dump: $dumpType -> $($ccProps.DumpFile)" -Status 'INFO'
            }
        }  # End Invoke-WithHive SYSTEM

        #endregion

        #region ===================================================================
        # PHASE 5  -  LOGON & DESKTOP: Winlogon, LogonUI, credentials, shell
        #=========================================================================
        Write-Phase 5 'LOGON & DESKTOP' 'Winlogon -> LogonUI -> Lsass credential validation -> Userinit -> Explorer shell'

        # 5a. Logon-phase binaries
        $logonFiles = @(
            @{ Label = 'winlogon.exe (Windows Logon)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\winlogon.exe') }
            @{ Label = 'LogonUI.exe (Logon UI)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\LogonUI.exe') }
            @{ Label = 'lsass.exe (Security Authority)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\lsass.exe') }
            @{ Label = 'userinit.exe (User Initialization)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\userinit.exe') }
            @{ Label = 'explorer.exe (Windows Shell)'; Path = (Join-Path $script:WinDriveLetter 'Windows\explorer.exe') }
            @{ Label = 'dwm.exe (Desktop Window Manager)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\dwm.exe') }
            @{ Label = 'consent.exe (UAC Consent UI)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\consent.exe') }
            @{ Label = 'mpssvc.dll (Windows Firewall)'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\mpssvc.dll') }
        )
        foreach ($lf in $logonFiles) {
            $r = Test-BootFile -Path $lf.Path -Label $lf.Label
            Write-ChainItem -Label $lf.Label -Status $r.Health -Detail $r.Detail
            $totalChecks++
            if ($r.Health -ne 'OK') { $issues.Add([PSCustomObject]@{ Phase = 5; Severity = $r.Health; Message = "$($lf.Label): $($r.Detail)"; Fix = "-RepairSystemFile $(Split-Path -Leaf $lf.Path)" }) }
        }

        # 5b. Winlogon registry settings (Shell, Userinit)
        Write-Host ""
        Write-Host "  $symCHAIN  $symARROW  Winlogon & Shell Configuration" -ForegroundColor White

        Invoke-WithHive 'SOFTWARE' {
            $wlPath = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            if (Test-Path $wlPath) {
                $wlProps = Get-ItemProperty $wlPath -ErrorAction SilentlyContinue

                # Shell
                $shell = $wlProps.Shell
                if (-not $shell) {
                    Write-ChainItem -Label 'Winlogon Shell: (not set)' -Status 'FAIL' -Detail 'No shell will launch after logon'
                    $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 5; Severity = 'FAIL'; Message = 'Winlogon Shell is not set'; Fix = '-FixWinlogon' })
                }
                elseif ($shell -ne 'explorer.exe') {
                    Write-ChainItem -Label "Winlogon Shell: $shell" -Status 'WARN' -Detail "Non-default shell (expected 'explorer.exe')"
                    $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 5; Severity = 'WARN'; Message = "Winlogon Shell is '$shell' (expected 'explorer.exe')"; Fix = '-FixWinlogon' })
                }
                else {
                    Write-ChainItem -Label 'Winlogon Shell: explorer.exe' -Status 'OK'
                }

                # Userinit
                $userinit = $wlProps.Userinit
                $expectedUserinit = 'C:\Windows\system32\userinit.exe,'
                if (-not $userinit) {
                    Write-ChainItem -Label 'Winlogon Userinit: (not set)' -Status 'FAIL' -Detail 'Userinit missing  -  logon sequence will fail'
                    $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 5; Severity = 'FAIL'; Message = 'Winlogon Userinit is not set'; Fix = '-FixWinlogon' })
                }
                elseif ($userinit -ne $expectedUserinit) {
                    Write-ChainItem -Label "Winlogon Userinit: $userinit" -Status 'WARN' -Detail "Non-default (expected '$expectedUserinit')"
                    $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 5; Severity = 'WARN'; Message = "Winlogon Userinit is '$userinit' (non-default)"; Fix = '-FixWinlogon' })
                }
                else {
                    Write-ChainItem -Label "Winlogon Userinit: $userinit" -Status 'OK'
                }

                # GpExtensions / AppInit_DLLs  -  potential boot blockers
                $appInitPath = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows'
                if (Test-Path $appInitPath) {
                    $appInitProps = Get-ItemProperty $appInitPath -ErrorAction SilentlyContinue
                    $appInitDlls = $appInitProps.AppInit_DLLs
                    $loadAppInit = $appInitProps.LoadAppInit_DLLs
                    if ($loadAppInit -eq 1 -and $appInitDlls) {
                        Write-ChainItem -Label "AppInit_DLLs ACTIVE: $appInitDlls" -Status 'WARN' -Detail 'Third-party DLLs injected into every process  -  common boot blocker'
                        $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 5; Severity = 'WARN'; Message = "AppInit_DLLs loaded: $appInitDlls"; Fix = '' })
                    }
                }

                # Credential providers
                $cpPath = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers'
                if (Test-Path $cpPath) {
                    $cpCount = (Get-ChildItem $cpPath -ErrorAction SilentlyContinue).Count
                    Write-ChainItem -Label "Credential Providers: $cpCount registered" -Status 'INFO'
                }
            }
            else {
                Write-ChainItem -Label 'Winlogon key' -Status 'FAIL' -Detail 'HKLM:\SOFTWARE\...\Winlogon not found'
                $totalChecks++; $issues.Add([PSCustomObject]@{ Phase = 5; Severity = 'FAIL'; Message = 'Winlogon registry key not found'; Fix = '-RestoreRegistryFromRegBack' })
            }

            # 5c. Other critical SOFTWARE hive checks
            # Run / RunOnce startup programs
            $runPaths = @(
                'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Run'
                'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
            )
            foreach ($rp in $runPaths) {
                if (-not (Test-Path $rp)) { continue }
                $entries = Get-ItemProperty $rp -ErrorAction SilentlyContinue
                $names = $entries.PSObject.Properties | Where-Object { $_.Name -notin @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') }
                if ($names.Count -gt 0) {
                    $keyName = Split-Path -Leaf $rp
                    $preview = ($names | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', '
                    Write-ChainItem -Label "$keyName : $($names.Count) startup entries" -Status 'INFO' -Detail $preview
                }
            }
        }  # End Invoke-WithHive SOFTWARE

        # 5d. Additional registry hive files health (SOFTWARE, SAM, SECURITY)
        Write-Host ""
        Write-Host "  $symCHAIN  $symARROW  Registry Hive Files Health" -ForegroundColor White
        $hiveFiles = @(
            @{ Label = 'SOFTWARE hive'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\config\SOFTWARE') }
            @{ Label = 'SAM hive'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\config\SAM') }
            @{ Label = 'SECURITY hive'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\config\SECURITY') }
            @{ Label = 'DEFAULT hive'; Path = (Join-Path $script:WinDriveLetter 'Windows\System32\config\DEFAULT') }
        )
        foreach ($hf in $hiveFiles) {
            $r = Test-BootFile -Path $hf.Path -Label $hf.Label -SkipSignature
            Write-ChainItem -Label $hf.Label -Status $r.Health -Detail $r.Detail
            $totalChecks++
            if ($r.Health -ne 'OK') { $issues.Add([PSCustomObject]@{ Phase = 5; Severity = $r.Health; Message = "$($hf.Label): $($r.Detail)"; Fix = '-RestoreRegistryFromRegBack' }) }
        }

        #endregion

        #region ===================================================================
        # SUMMARY
        #=========================================================================
        Write-Host ""
        Write-Host "  $("$symEQ" * 76)" -ForegroundColor Cyan
        Write-Host "                          BOOT PATH HEALTH SUMMARY" -ForegroundColor White
        Write-Host "  $("$symEQ" * 76)" -ForegroundColor Cyan

        $fails = @($issues | Where-Object { $_.Severity -eq 'FAIL' })
        $warns = @($issues | Where-Object { $_.Severity -eq 'WARN' })

        Write-Host ""
        Write-Host "  Total checks performed : $totalChecks" -ForegroundColor White
        Write-Host -NoNewline "  Critical failures      : "; Write-Host "$($fails.Count)" -ForegroundColor $(if ($fails.Count -gt 0) { 'Red' } else { 'Green' })
        Write-Host -NoNewline "  Warnings               : "; Write-Host "$($warns.Count)" -ForegroundColor $(if ($warns.Count -gt 0) { 'Yellow' } else { 'Green' })

        if ($fails.Count -eq 0 -and $warns.Count -eq 0) {
            Write-Host ""
            Write-Host "  $symOK  All boot path artifacts verified  -  boot chain looks healthy." -ForegroundColor Green
        }
        else {
            if ($fails.Count -gt 0) {
                Write-Host ""
                Write-Host "  -- CRITICAL Issues (will prevent boot) --" -ForegroundColor Red
                $phaseNames = @{ 1 = 'Pre-Boot'; 2 = 'Boot Manager'; 3 = 'OS Loader'; 4 = 'NTOS Kernel'; 5 = 'Logon & Desktop' }
                foreach ($f in $fails) {
                    $phaseName = $phaseNames[[int]$f.Phase]
                    Write-Host "  $symFAIL  [Phase $($f.Phase) - $phaseName] $($f.Message)" -ForegroundColor Red
                    if ($f.Fix) { Write-Host "           Fix: $($f.Fix)" -ForegroundColor Yellow }
                }
            }
            if ($warns.Count -gt 0) {
                Write-Host ""
                Write-Host "  -- Warnings (may affect boot or indicate risk) --" -ForegroundColor Yellow
                foreach ($w in $warns | Select-Object -First 15) {
                    Write-Host "  $symWARN  [Phase $($w.Phase)] $($w.Message)" -ForegroundColor Yellow
                    if ($w.Fix) { Write-Host "           Fix: $($w.Fix)" -ForegroundColor DarkYellow }
                }
                if ($warns.Count -gt 15) {
                    Write-Host "  ... and $($warns.Count - 15) additional warnings." -ForegroundColor DarkGray
                }
            }
        }

        Write-Host ""
        Write-Host "  Tip: Use -AnalyzeCriticalBootFiles for a quick file-only table, -AnalyzeBcdConsistency for detailed BCD." -ForegroundColor DarkGray
        Write-Host "  $("$symEQ" * 76)" -ForegroundColor Cyan
        Write-Host ""
    }
    # End GetBootPathReport

    function AnalyzeBcdConsistency {
        Write-Host "Analyzing BCD consistency..." -ForegroundColor Yellow
        $store = Get-BcdStorePath -BootDrive $script:BootDriveLetter -Generation $script:VMGen
        if (-not (Test-Path -LiteralPath $store)) {
            Write-Warning "BCD store not found: $store"
            return
        }
        $id = Get-BcdBootLoaderId -StorePath $store
        if (-not $id) {
            Write-Warning "Unable to resolve Windows Boot Loader identifier in BCD."
            return
        }

        $raw = & cmd.exe /c "bcdedit /store `"$store`" /enum $id" 2>&1
        $txt = ($raw -join "`n")
        $device = [regex]::Match($txt, '(?im)^\s*device\s+(.+)$').Groups[1].Value.Trim()
        $osdev = [regex]::Match($txt, '(?im)^\s*osdevice\s+(.+)$').Groups[1].Value.Trim()
        $path = [regex]::Match($txt, '(?im)^\s*path\s+(.+)$').Groups[1].Value.Trim()
        $sysrt = [regex]::Match($txt, '(?im)^\s*systemroot\s+(.+)$').Groups[1].Value.Trim()

        $expectedPath = if ($script:VMGen -eq 2) { '\Windows\System32\winload.efi' } else { '\Windows\System32\winload.exe' }
        $expectedFile = Join-Path $script:WinDriveLetter ($expectedPath.TrimStart('\'))
        $pathOk = [string]::Equals($path, $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)
        $fileOk = Test-Path -LiteralPath $expectedFile

        [PSCustomObject]@{
            BcdStore       = $store
            LoaderId       = $id
            Device         = $device
            OsDevice       = $osdev
            Path           = $path
            SystemRoot     = $sysrt
            ExpectedPath   = $expectedPath
            ExpectedExists = $fileOk
        } | Format-List

        if (-not $pathOk -or -not $fileOk) {
            Write-Warning "BCD entry may be inconsistent (path mismatch or winload file missing). Consider -FixBoot if boot fails."
        }
        else {
            Write-Host "BCD loader path and winload target look consistent." -ForegroundColor Green
        }
    }

    function AnalyzeComponentStore {
        Write-Host "Analyzing component store integrity from offline CBS log..." -ForegroundColor Yellow

        $cbsLogPath = Join-Path $script:WinDriveLetter 'Windows\Logs\CBS\CBS.log'
        if (-not (Test-Path $cbsLogPath)) {
            Write-Warning "CBS.log not found at $cbsLogPath - cannot analyze offline."
            Write-Host "Run -RepairComponentStore to trigger a DISM /ScanHealth which will produce a CBS.log." -ForegroundColor DarkCyan
            return
        }

        # Detect guest OS version for context
        $guestBuild = $null
        $guestProduct = $null
        try {
            Invoke-WithHive 'SOFTWARE' {
                $cv = Get-ItemProperty 'HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
                if ($cv) {
                    $script:_guestBuild = $cv.CurrentBuildNumber
                    $script:_guestUBR = $cv.UBR
                    $script:_guestProduct = $cv.ProductName
                }
            }
            $guestBuild = $script:_guestBuild
            $guestUBR = $script:_guestUBR
            $guestProduct = $script:_guestProduct
        }
        catch {}

        $fullBuild = if ($guestBuild -and $guestUBR) { "$guestBuild.$guestUBR" } elseif ($guestBuild) { $guestBuild } else { 'unknown' }
        Write-Host "Guest OS: $guestProduct (Build $fullBuild)" -ForegroundColor Cyan

        $hostBuild = [System.Environment]::OSVersion.Version.Build
        if ($guestBuild -and $hostBuild -and $guestBuild -ne "$hostBuild") {
            Write-Host "Host OS build: $hostBuild (DIFFERENT from guest - host WinSxS cannot be used as repair source)" -ForegroundColor Yellow
        }

        Write-Host "Parsing CBS.log for corruption entries..." -ForegroundColor Cyan
        $cbsContent = Get-Content $cbsLogPath -ErrorAction SilentlyContinue

        # Pattern 1: CSI Payload Corrupt lines
        # Format: (p)   CSI Payload Corrupt   (n)   <arch>_<component>_<version>\<file>
        $corruptPayloads = @()
        $repairFailures = @()
        $corruptComponents = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($line in $cbsContent) {
            if ($line -match 'CSI Payload Corrupt.*?(\S+_[0-9a-f]{16}_\S+)\\(\S+)') {
                $componentFull = $Matches[1]
                $fileName = $Matches[2]
                $null = $corruptComponents.Add($componentFull)
                $corruptPayloads += [PSCustomObject]@{
                    Component = $componentFull
                    File      = $fileName
                }
            }
            elseif ($line -match 'CSI Manifest Corrupt.*?(\S+_[0-9a-f]{16}_\S+)') {
                $null = $corruptComponents.Add($Matches[1])
                $corruptPayloads += [PSCustomObject]@{
                    Component = $Matches[1]
                    File      = '(manifest)'
                }
            }
            elseif ($line -match 'Repair failed.*Missing replacement') {
                $repairFailures += $line.Trim()
            }
            elseif ($line -match 'CBS_E_SOURCE_MISSING|PSFX_E_MATCHING_BINARY_MISSING|ERROR_SXS_ASSEMBLY_NOT_FOUND') {
                $repairFailures += $line.Trim()
            }
        }

        if ($corruptPayloads.Count -eq 0) {
            # Also check for ScanHealth summary
            $scanResult = $cbsContent | Where-Object { $_ -match 'Total Detected Corruption:\s+(\d+)' }
            if ($scanResult -and $Matches[1] -eq '0') {
                Write-Host "No component corruption detected in CBS.log." -ForegroundColor Green
                return
            }
            elseif ($scanResult) {
                Write-Host "CBS.log reports $($Matches[1]) corruption(s) detected but specific components could not be parsed." -ForegroundColor Yellow
                Write-Host "Run -RepairComponentStore to trigger a fresh scan and check the updated CBS.log." -ForegroundColor DarkCyan
                return
            }

            Write-Host "No corruption entries found in CBS.log." -ForegroundColor Green
            Write-Host "To trigger a fresh scan, run -RepairComponentStore (DISM /ScanHealth)." -ForegroundColor DarkCyan
            return
        }

        # Extract version info from component names to identify required KB
        # Component format: <arch>_<name>_<publickeytoken>_<version>_<locale>_<hash>
        $versionMap = @{}
        foreach ($comp in $corruptComponents) {
            if ($comp -match '_(\d+\.\d+\.\d+\.\d+)_') {
                $ver = $Matches[1]
                if (-not $versionMap.ContainsKey($ver)) { $versionMap[$ver] = [System.Collections.Generic.List[string]]::new() }
                $versionMap[$ver].Add($comp)
            }
        }

        Write-Host ""
        Write-Host "=== Component Store Corruption Report ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Corrupt components: $($corruptComponents.Count)" -ForegroundColor Red
        Write-Host "Corrupt files:" -ForegroundColor Red
        $corruptPayloads | ForEach-Object {
            Write-Host "  $($_.File)  ($($_.Component))" -ForegroundColor Yellow
        }

        if ($repairFailures.Count -gt 0) {
            Write-Host ""
            Write-Host "Previous repair attempts failed ($($repairFailures.Count) errors):" -ForegroundColor Red
            $repairFailures | Select-Object -First 5 | ForEach-Object {
                Write-Host "  $_" -ForegroundColor DarkYellow
            }
        }

        Write-Host ""
        Write-Host "=== Required Update Versions ===" -ForegroundColor Cyan
        foreach ($ver in $versionMap.Keys | Sort-Object) {
            $parts = $ver -split '\.'
            $majorBuild = "$($parts[2]).$($parts[3])"
            Write-Host ""
            Write-Host "  Version: $ver  (build $majorBuild)" -ForegroundColor White
            Write-Host "  Components: $($versionMap[$ver].Count)" -ForegroundColor DarkGray
            # Try to help identify the KB
            if ($parts[2] -match '^\d+$') {
                $buildNum = [int]$parts[2]
                $osName = switch ($buildNum) {
                    { $_ -ge 26100 } { 'Windows Server 2025 / Windows 11 24H2' }
                    { $_ -ge 22631 } { 'Windows 11 23H2' }
                    { $_ -ge 22621 } { 'Windows 11 22H2' }
                    { $_ -ge 22000 } { 'Windows 11 21H2' }
                    { $_ -ge 20348 } { 'Windows Server 2022' }
                    { $_ -ge 19045 } { 'Windows 10 22H2' }
                    { $_ -ge 19044 } { 'Windows 10 21H2' }
                    { $_ -ge 19041 } { 'Windows 10 2004+' }
                    { $_ -ge 17763 } { 'Windows Server 2019 / Windows 10 1809' }
                    { $_ -ge 17134 } { 'Windows 10 1803' }
                    { $_ -ge 16299 } { 'Windows 10 1709' }
                    { $_ -ge 15063 } { 'Windows 10 1703' }
                    { $_ -ge 14393 } { 'Windows Server 2016 / Windows 10 1607' }
                    { $_ -ge 10240 } { 'Windows 10 1507' }
                    { $_ -ge 9600 } { 'Windows Server 2012 R2 / Windows 8.1' }
                    { $_ -ge 9200 } { 'Windows Server 2012 / Windows 8' }
                    default { 'Unknown OS' }
                }
                Write-Host "  OS:      $osName" -ForegroundColor DarkGray
                Write-Host "  Search:  https://www.catalog.update.microsoft.com/Search.aspx?q=$majorBuild" -ForegroundColor DarkCyan
            }
        }

        Write-Host ""
        Write-Host "=== How to Repair ===" -ForegroundColor Cyan
        Write-Host "1. Download the cumulative update (.msu) for build $fullBuild from the Microsoft Update Catalog" -ForegroundColor White
        Write-Host "   (use the search links above or search for the build number)" -ForegroundColor DarkGray
        Write-Host "2. Run:" -ForegroundColor White
        $scriptName = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { 'RepairVM.ps1' }
        Write-Host "   .\$scriptName -DiskNumber $($script:DiskNumber) -RepairComponentStore -RepairSource <path-to-downloaded.msu>" -ForegroundColor Green
        Write-Host "3. Alternatively, use a matching install.wim or .iso as source:" -ForegroundColor White
        Write-Host "   .\$scriptName -DiskNumber $($script:DiskNumber) -RepairComponentStore -RepairSource <path-to-install.wim>" -ForegroundColor Green
        Write-Host ""
        Write-Host "Note: A base ISO may not contain updated components. The cumulative .msu matching" -ForegroundColor DarkGray
        Write-Host "build $fullBuild is the most reliable source for the exact file versions needed." -ForegroundColor DarkGray
    }

    function AnalyzeServicingState {
        Write-Host "Analyzing servicing/CBS pending state..." -ForegroundColor Yellow
        $pendingXml = Join-Path $script:WinDriveLetter 'Windows\WinSxS\pending.xml'
        $hasPendingXml = Test-Path -LiteralPath $pendingXml

        Invoke-WithHive 'SOFTWARE', 'COMPONENTS' {
            $cbs = 'HKLM:\BROKENSOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
            $counts = @{}
            foreach ($k in @('PackagesPending', 'SessionsPending', 'RebootPending')) {
                $p = Join-Path $cbs $k
                $counts[$k] = if (Test-Path $p) { (Get-ChildItem $p -ErrorAction SilentlyContinue | Measure-Object).Count } else { 0 }
            }

            $comp = 'HKLM:\BROKENCOMPONENTS'
            $cp = Get-ItemProperty $comp -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                PendingXmlPresent    = $hasPendingXml
                PackagesPending      = $counts['PackagesPending']
                SessionsPending      = $counts['SessionsPending']
                RebootPending        = $counts['RebootPending']
                ExecutionState       = $cp.ExecutionState
                PendingXmlIdentifier = $cp.PendingXmlIdentifier
                NextQueueEntryIndex  = $cp.NextQueueEntryIndex
                StoreDirty           = $cp.StoreDirty
            } | Format-List

            if ($hasPendingXml -or $counts['PackagesPending'] -gt 0 -or $counts['SessionsPending'] -gt 0 -or $counts['RebootPending'] -gt 0) {
                Write-Warning "Servicing pending markers detected. If boot loops in update stage, consider -FixPendingUpdates."
            }
            else {
                Write-Host "No major pending servicing markers detected." -ForegroundColor Green
            }
        }
    }

    function AnalyzeDomainTrustState {
        Write-Host "Analyzing likely domain-join/trust state signals..." -ForegroundColor Yellow
        Invoke-WithHive 'SYSTEM', 'SOFTWARE' {
            $sysRoot = Get-SystemRootPath
            $tcpip = "$sysRoot\Services\Tcpip\Parameters"
            $domain = (Get-ItemProperty $tcpip -ErrorAction SilentlyContinue).Domain
            $dhcpDomain = (Get-ItemProperty $tcpip -ErrorAction SilentlyContinue).DhcpDomain
            $netlogonStart = (Get-ItemProperty "$sysRoot\Services\Netlogon" -ErrorAction SilentlyContinue).Start
            $defaultDomain = (Get-ItemProperty 'HKLM:\BROKENSOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue).DefaultDomainName
            $joined = (($domain -and $domain -notmatch '^(WORKGROUP|LOCALDOMAIN)$') -or ($dhcpDomain -and $dhcpDomain -notmatch '^(WORKGROUP|LOCALDOMAIN)$') -or ($defaultDomain -and $defaultDomain -notmatch '^(WORKGROUP|LOCALDOMAIN)$'))

            [PSCustomObject]@{
                Domain             = $domain
                DhcpDomain         = $dhcpDomain
                DefaultDomainName  = $defaultDomain
                NetlogonStart      = $netlogonStart
                LikelyDomainJoined = $joined
                NetlogonDisabled   = ($netlogonStart -eq 4)
            } | Format-List

            if ($joined -and $netlogonStart -eq 4) {
                Write-Warning "Domain-join signals found but Netlogon is disabled. This can break domain authentication and RDP."
            }
        }
    }

    function PrepareRecoveryDiagnostics {
        if (-not (Confirm-CriticalOperation -Operation 'Prepare Recovery Diagnostics (-PrepareRecoveryDiagnostics)' -Details @"
Applies a conservative diagnostics bundle for a broken VM:
  - Enable boot logging (ntbtlog.txt)
  - Enable serial console (EMS)
  - Configure full memory dump settings
No destructive file or registry cleanup is performed.
"@)) { return }

        SetBootLog
        EnableSerialConsole
        ConfigureFullMemDump
        Write-Host "Recovery diagnostics bundle applied." -ForegroundColor Green
    }

    ################################################################################
    # Initialize-TargetDisk
    #
    # Resolves a VM name (Hyper-V) or a raw disk number to a physical disk,
    # brings it online, assigns temporary drive letters to unmounted partitions,
    # detects the Windows and Boot partitions, and populates the script-scoped
    # variables consumed by all repair functions:
    #   $script:WinDriveLetter   - e.g. "E:\"
    #   $script:BootDriveLetter  - e.g. "F:\" (may equal WinDriveLetter on Gen1)
    #   $script:VMGen            - 1 (MBR/BIOS) or 2 (GPT/UEFI)
    #
    # Returns $true on success, $false on failure.
    function Initialize-TargetDisk {
        param(
            [string]$VMName = "",
            [int]   $DiskNumber = -1
        )

        # ------------------------------------------------------------------
        # 1. Resolve VMName -> DiskNumber (Hyper-V path)
        # ------------------------------------------------------------------
        $script:AutoMountedVHDPath = $null   # track if we auto-mounted a VHD for cleanup
        if (-not [string]::IsNullOrWhiteSpace($VMName)) {
            Write-Host "Resolving Hyper-V VM '$VMName'..." -ForegroundColor Cyan

            $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
            if (-not $vm) {
                Write-Error "VM '$VMName' not found."
                return $false
            }

            # Stop VM before accessing its disk
            if ($vm.State -ne 'Off') {
                Write-Host "Stopping VM '$VMName'..."
                $script:VMIPAddress = (Get-VM -Name $VMName | Get-VMNetworkAdapter).IPAddresses |
                Where-Object { $_ -match "\." } | Select-Object -First 1
                $vm | Stop-VM -TurnOff -Force
                Start-Sleep -Seconds 2
            }

            # Resolve VM hard drive -> physical disk number
            # Strategy: Get-VHD (authoritative) -> HardDrive.DiskNumber (cross-validated) -> auto-mount
            $osDrive = $vm.HardDrives | Where-Object { $_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq 0 }
            if (-not $osDrive) { $osDrive = $vm.HardDrives | Select-Object -First 1 }
            if (-not $osDrive -or -not $osDrive.Path) {
                Write-Error "VM '$VMName' has no hard drives attached."
                return $false
            }
            $vhdPath = $osDrive.Path
            $DiskNumber = -1

            # 1) Authoritative: Get-VHD tells us the real disk number when the VHD is mounted
            if (Test-Path -LiteralPath $vhdPath) {
                $vhd = Get-VHD -Path $vhdPath -ErrorAction SilentlyContinue
                if ($vhd -and $null -ne $vhd.DiskNumber -and [int]$vhd.DiskNumber -ge 0) {
                    $DiskNumber = [int]$vhd.DiskNumber
                }
            }

            # 2) Cross-validate HardDrive.DiskNumber -- Hyper-V returns 0 as default when
            #    the VHD is not mounted, which would incorrectly point at the host OS disk.
            if ($DiskNumber -lt 0 -and $null -ne $osDrive.DiskNumber -and [int]$osDrive.DiskNumber -ge 0) {
                $rawNum = [int]$osDrive.DiskNumber
                # Reject if it matches the local OS disk (almost certainly a false default)
                if ($null -ne $script:LocalOsDiskNumber -and $rawNum -eq $script:LocalOsDiskNumber) {
                    Write-Host "  Hyper-V reports DiskNumber=$rawNum for this VM, but that is the local OS disk - ignoring." -ForegroundColor DarkYellow
                }
                else {
                    $DiskNumber = $rawNum
                }
            }

            # 3) VHD exists on disk but is not mounted -- auto-mount it
            if ($DiskNumber -lt 0 -and (Test-Path -LiteralPath $vhdPath)) {
                Write-Host "VM disk is not mounted on the host. Mounting VHD: $vhdPath..." -ForegroundColor Cyan
                try {
                    Mount-VHD -Path $vhdPath -ErrorAction Stop
                    Start-Sleep -Seconds 2
                    $vhd = Get-VHD -Path $vhdPath -ErrorAction SilentlyContinue
                    if ($vhd -and $null -ne $vhd.DiskNumber -and [int]$vhd.DiskNumber -ge 0) {
                        $DiskNumber = [int]$vhd.DiskNumber
                        $script:AutoMountedVHDPath = $vhdPath
                        Write-Host "  Mounted as Disk $DiskNumber" -ForegroundColor Green
                    }
                }
                catch {
                    Write-Error "Failed to mount VHD '$vhdPath': $_"
                }
            }
            elseif ($DiskNumber -lt 0 -and -not (Test-Path -LiteralPath $vhdPath)) {
                Write-Error "VM disk path not found: $vhdPath"
                return $false
            }

            if ($null -eq $DiskNumber -or $DiskNumber -lt 0) {
                Write-Error "Could not determine disk number for VM '$VMName'. Attach the disk manually and use -DiskNumber instead."
                return $false
            }

            Write-Host "[OK] VM disk resolved to Disk $DiskNumber`n" -ForegroundColor Green
        }

        if ($DiskNumber -lt 0) {
            Write-Error "No disk specified. Provide -VMName (Hyper-V) or -DiskNumber."
            return $false
        }

        # Guard: never operate on the local OS disk - applies to both -DiskNumber and -VMName paths
        if ($null -ne $script:LocalOsDiskNumber -and $DiskNumber -eq $script:LocalOsDiskNumber) {
            Write-Error "Disk $DiskNumber hosts the local C: drive. Cannot use it as a repair target - this would risk breaking the Hyper-V host."
            return $false
        }

        # ------------------------------------------------------------------
        # 2. Get disk and validate
        # ------------------------------------------------------------------
        $targetDisk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
        if (-not $targetDisk) {
            Write-Error "Disk $DiskNumber not found. Use the script without parameters to list available disks."
            return $false
        }

        Write-Host "Target Disk: Disk $DiskNumber | $($targetDisk.PartitionStyle) | $([math]::Round($targetDisk.Size / 1GB)) GB"

        # ------------------------------------------------------------------
        # 2.5 Check if disk is currently owned by a running VM
        # ------------------------------------------------------------------
        $owningVM = if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
            Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Off' } | ForEach-Object {
                $checkVM = $_
                foreach ($hd in $checkVM.HardDrives) {
                    $resolvedNum = -1
                    if ($null -ne $hd.DiskNumber -and [int]$hd.DiskNumber -ge 0) {
                        $resolvedNum = [int]$hd.DiskNumber
                    }
                    elseif ($hd.Path -match '\.vhdx?$') {
                        $vhd = Get-VHD -Path $hd.Path -ErrorAction SilentlyContinue
                        if ($vhd -and $null -ne $vhd.DiskNumber -and [int]$vhd.DiskNumber -ge 0) {
                            $resolvedNum = [int]$vhd.DiskNumber
                        }
                    }
                    if ($resolvedNum -eq $DiskNumber) {
                        $checkVM.Name
                        return
                    }
                }
            } | Select-Object -First 1
        }
        if ($owningVM) {
            Write-Error "Disk $DiskNumber is currently attached to running VM '$owningVM'. Stop the VM first, or re-run with -VMName '$owningVM' to have the script stop it automatically."
            return $false
        }

        # ------------------------------------------------------------------
        # 3. Bring disk online and writable
        # ------------------------------------------------------------------
        $usedLetters = (Get-Volume).DriveLetter | Where-Object { $_ } | ForEach-Object { ([string]$_).ToUpper() }

        if ($targetDisk.OperationalStatus -eq 'Offline' -or $targetDisk.IsOffline) {
            Write-Host "Bringing disk $DiskNumber online..." -ForegroundColor Cyan
            try {
                $targetDisk | Set-Disk -IsOffline $false
                $targetDisk | Set-Disk -IsReadOnly $false
            }
            catch {
                if ($_ -match 'Access Denied|40001') {
                    Write-Error "Access denied bringing disk $DiskNumber online. The disk is likely in use by a running VM. Stop the VM first, or re-run with -VMName <name> to have the script stop it automatically."
                }
                else {
                    Write-Error "Failed to bring disk $DiskNumber online: $($_.Exception.Message)"
                }
                return $false
            }
            Start-Sleep -Seconds 2
            $targetDisk = Get-Disk -Number $DiskNumber
        }
        elseif ($targetDisk.IsReadOnly) {
            Write-Host "Clearing read-only flag on disk $DiskNumber..." -ForegroundColor Cyan
            try {
                $targetDisk | Set-Disk -IsReadOnly $false
            }
            catch {
                if ($_ -match 'Access Denied|40001') {
                    Write-Error "Access denied clearing read-only flag on disk $DiskNumber. The disk is likely in use by a running VM."
                }
                else {
                    Write-Error "Failed to clear read-only flag on disk ${DiskNumber}: $($_.Exception.Message)"
                }
                return $false
            }
            $targetDisk = Get-Disk -Number $DiskNumber
        }

        # ------------------------------------------------------------------
        # 4. Detect generation (MBR = Gen1, GPT = Gen2)
        # ------------------------------------------------------------------
        $script:VMGen = Get-DiskGeneration -Disk $targetDisk
        Write-Host "Detected Partition Style: $(if ($script:VMGen -eq 1) { 'MBR (BIOS) - Gen1' } else { 'GPT (UEFI) - Gen2' })"

        # ------------------------------------------------------------------
        # 5. Assign drive letters to unmounted useful partitions
        # ------------------------------------------------------------------
        $partitions = $targetDisk | Get-Partition
        foreach ($part in $partitions) {
            if (-not $part.DriveLetter -and ($part.Type -in @('System', 'Basic', 'IFS'))) {
                Write-Host "Assigning drive letter to Partition $($part.PartitionNumber) ($($part.Type))..."
                $part | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
            }
        }

        # ------------------------------------------------------------------
        # 6. Detect Windows and Boot partitions via AccessPaths
        # ------------------------------------------------------------------
        $winDrive = $null
        $bootDrive = $null

        $partitions = $targetDisk | Get-Partition
        Write-Host "`nPartition Analysis:" -ForegroundColor Cyan
        foreach ($part in $partitions) {
            $accessPaths = $part.AccessPaths | Where-Object { $_ -match ":" }
            foreach ($accessPath in $accessPaths) {
                $role = Get-PartitionRole -AccessPath $accessPath -PartitionInfo $part
                Write-Host "  Partition $($part.PartitionNumber) ($accessPath): $role"

                if ((Test-Path (Join-Path $accessPath "Windows\System32\ntdll.dll")) -and -not $winDrive) {
                    $winDrive = $accessPath
                }

                if ($script:VMGen -eq 1) {
                    # Active MBR partition with Boot\BCD present
                    if ($part.IsActive -and (Test-Path (Join-Path $accessPath "Boot\BCD")) -and -not $bootDrive) {
                        $bootDrive = $accessPath
                    }
                    # Fallback: active MBR partition even without BCD (BCD missing/corrupted)
                    elseif ($part.IsActive -and -not $bootDrive) {
                        $bootDrive = $accessPath
                        Write-Host "  ** Boot partition identified by MBR Active flag (BCD file missing - run -FixBoot to rebuild)" -ForegroundColor Yellow
                    }
                }
                elseif ($script:VMGen -eq 2) {
                    # GPT System partition with EFI\Microsoft\Boot\BCD present
                    if ($part.Type -eq 'System' -and (Test-Path (Join-Path $accessPath "EFI\Microsoft\Boot\BCD")) -and -not $bootDrive) {
                        $bootDrive = $accessPath
                    }
                    # Fallback 1: GPT System partition with EFI\Microsoft\Boot folder (BCD deleted)
                    elseif ($part.Type -eq 'System' -and (Test-Path (Join-Path $accessPath "EFI\Microsoft\Boot")) -and -not $bootDrive) {
                        $bootDrive = $accessPath
                        Write-Host "  ** Boot partition identified by GPT System type + EFI folder (BCD missing - run -FixBoot to rebuild)" -ForegroundColor Yellow
                    }
                    # Fallback 2: GPT System partition exists but EFI folder is also gone
                    elseif ($part.Type -eq 'System' -and -not $bootDrive) {
                        $bootDrive = $accessPath
                        Write-Host "  ** Boot partition identified by GPT System partition type only (EFI/BCD missing - run -FixBoot to rebuild)" -ForegroundColor Yellow
                    }
                }
            }
        }

        $newUsedLetters = (Get-Volume).DriveLetter | Where-Object { $_ } | ForEach-Object { ([string]$_).ToUpper() }
        $addedLetters = $newUsedLetters | Where-Object { $usedLetters -notcontains $_ }
        if ($addedLetters) { Write-Host "Added letter(s): $($addedLetters -join ', ')" }

        # ------------------------------------------------------------------
        # 7. Validate and publish script-scoped variables
        # ------------------------------------------------------------------
        if (-not $winDrive) {
            Write-Error "Cannot proceed: Windows partition (containing \Windows\System32\ntdll.dll) not detected on disk $DiskNumber."
            return $false
        }

        if (-not $bootDrive) {
            $bootDrive = $winDrive
            if ($script:VMGen -eq 2) {
                Write-Host "[WARNING] No EFI System Partition found on disk $DiskNumber - Gen2 (UEFI) VMs cannot boot without it." -ForegroundColor Red
                Write-Host "          Use -RecreateBootPartition to create a new ESP and populate it with boot files." -ForegroundColor Yellow
            }
            else {
                Write-Host "No separate boot partition found; using Windows drive as boot drive." -ForegroundColor Yellow
                Write-Host "          If the System Reserved partition was deleted, use -RecreateBootPartition to recreate it." -ForegroundColor Yellow
            }
        }

        # Normalize to trailing backslash
        if ($winDrive -notmatch '\\$') { $winDrive = "$winDrive\" }
        if ($bootDrive -notmatch '\\$') { $bootDrive = "$bootDrive\" }

        $script:WinDriveLetter = $winDrive
        $script:BootDriveLetter = $bootDrive
        $script:DiskNumber = $DiskNumber

        Write-Host ""
        Write-Host "[OK] Windows drive : $script:WinDriveLetter"  -ForegroundColor Green
        Write-Host "[OK] Boot drive    : $script:BootDriveLetter" -ForegroundColor Green
        Write-Host "[OK] VM Generation : Gen$script:VMGen"        -ForegroundColor Green
        Write-Host ""

        return $true
    }

    ################################################################################
    # Consolidated helper: Repair-OfflineDisk
    #
    # Parameters: same as the script-level parameters. Callers may pass the script's
    # bound parameters via `Repair-OfflineDisk @PSBoundParameters`.
    #
    # What it does (summary):
    #  - Initializes the target disk or resolves a VM to a disk
    #  - Brings the disk online and assigns temporary letters as needed
    #  - Detects Windows and Boot partitions
    #  - Executes requested repair actions (chkdsk, DISM, BCD rebuild, RDP fixes,
    #    user additions, registry fixes, etc.) according to the provided switches
    #  - Optionally leaves the disk online or takes it offline when finished
    function Repair-OfflineDisk {
        param (
            [string]$VMName = "",
            [int]$DiskNumber = -1,
            [switch]$FixNTFS,
            [switch]$FixBoot,
            [switch]$FixBootSector,
            [switch]$RecreateBootPartition,
            [switch]$RepairComponentStore,
            [string]$RepairSource = '',
            [switch]$AnalyzeComponentStore,
            [switch]$TryLGKC,
            [switch]$TryOtherBootConfig,        
            [switch]$TrySafeMode,
            [switch]$RemoveSafeModeFlag,
            [switch]$RunSFC,
            [switch]$EnableBootLog,
            [switch]$DisableStartupRepair,
            [switch]$EnableStartupRepair,
            [switch]$DisableBFE,
            [switch]$EnableBFE,
            [switch]$AddTempUser,
            [switch]$AddTempUser2,
            [switch]$ResetLocalAdminPassword,
            [switch]$SetFullMemDump,
            [switch]$DisableNLA,
            [switch]$EnableNLA,
            [switch]$EnableWinRMHTTPS,
            [switch]$CheckRDPPolicies,
            [switch]$FixRDP,
            [switch]$FixRDPCert,
            [switch]$FixRDPPermissions,
            [switch]$FixRDPAuth,
            [switch]$FixUserRights,
            [switch]$FixPendingUpdates,
            [switch]$DisableWindowsUpdate,
            [switch]$RestoreRegistryFromRegBack,
            [switch]$EnableRegBackup,
            [switch]$DisableThirdPartyDrivers,
            [switch]$EnableThirdPartyDrivers,
            [switch]$GetServicesReport,
            [switch]$IncludeServices,
            [switch]$IssuesOnly,
            [string[]]$DisableDriverOrService = @(),
            [string[]]$EnableDriverOrService = @(),
            [ValidateSet('Boot', 'System', 'Automatic', 'Manual', 'Disabled')][string]$DriverStartType = 'Manual',
            [switch]$DisableCredentialGuard,
            [switch]$EnableCredentialGuard,
            [switch]$DisableAppLocker,
            [switch]$GetAppLockerReport,
            [switch]$FixSanPolicy,
            [switch]$FixAzureGuestAgent,
            [switch]$InstallAzureVMAgent,
            [switch]$FixSessionManager,
            [switch]$FixDeviceFilters,
            [switch]$KeepDefaultFilters,
            [switch]$CopyACPISettings,
            [switch]$ScanNetBindings,
            [switch]$FixNetBindings,
            [switch]$SysCheck,
            [switch]$ResetNetworkStack,
            [switch]$EnableTestSigning,
            [switch]$DisableTestSigning,
            [switch]$CheckDiskHealth,
            [switch]$CollectEventLogs,
            [switch]$CollectMinidumps,
            [switch]$AnalyzeCriticalBootFiles,
            [string[]]$RepairSystemFile = @(),
            [switch]$AnalyzeSyntheticDrivers,
            [switch]$EnsureSyntheticDriversEnabled,
            [switch]$ResetInterfacesToDHCP,
            [switch]$AnalyzeProxyState,
            [switch]$ClearProxyState,
            [switch]$GetBootPathReport,
            [switch]$AnalyzeBcdConsistency,
            [switch]$AnalyzeServicingState,
            [switch]$AnalyzeDomainTrustState,
            [switch]$PrepareRecoveryDiagnostics,
            [switch]$DisableDriverVerifier,
            [string]$EnableDriverVerifier = '',
            [switch]$ResetGroupPolicy,
            [switch]$FixWinlogon,
            [switch]$FixProfileLoad,
            [switch]$CheckRegistryHealth,
            [switch]$FixRegistryCorruption,
            [switch]$EnableSerialConsole,
            [switch]$ListInstalledUpdates,
            [string]$UninstallWindowsUpdate = '',
            [switch]$ListStartupPrograms,
            [switch]$DisableStartupPrograms,
            [switch]$DisableFirewall,
            [switch]$LeaveDiskOnline,
            [ValidateSet('SYSTEM', 'SOFTWARE', 'COMPONENTS', 'SAM', 'SECURITY')][string[]]$LoadHive = @(),
            [ValidateSet('SYSTEM', 'SOFTWARE', 'COMPONENTS', 'SAM', 'SECURITY')][string[]]$UnloadHive = @(),
            [string]$DriveLetter = ''
        )

        # Identify the local OS disk (C: drive) to prevent accidental modification of the Hyper-V host
        $script:LocalOsDiskNumber = (Get-Partition -DriveLetter 'C' -ErrorAction SilentlyContinue).DiskNumber

        # Show usage/disk list when called with no actionable parameters
        if ($DiskNumber -lt 0 -and [string]::IsNullOrWhiteSpace($VMName)) {
            Write-Host @"
====================================================================
  Windows Boot Troubleshooting Script - Offline Disk Repair
====================================================================

USAGE:
  .\$(Split-Path -Leaf $PSCommandPath) -DiskNumber <N> [Options]
  .\$(Split-Path -Leaf $PSCommandPath) -VMName <Name> [Options]

PARAMETERS:
  -DiskNumber <int>      Disk number visible in Disk Management
  -VMName <string>       Hyper-V VM name (auto-detects disk, stops VM first)
  -LeaveDiskOnline       Keep disk online after repairs (default: take offline)
  -LoadHive <hive[,...]> Mount one or more offline registry hives and leave them loaded for manual
                           inspection/editing (implies disk stays online). Valid: SYSTEM SOFTWARE COMPONENTS SAM SECURITY
                           Example: -LoadHive SYSTEM  -> HKLM:\BROKENSYSTEM available in regedit
  -UnloadHive <hive[,...]> Unmount previously loaded hives and take the disk offline

--- AZURE AGENT ---------------------------------------------------------------
  -FixAzureGuestAgent    Enable Azure Guest Agent and RdAgent services (registry already present)
  -InstallAzureVMAgent   Install Azure VM Agent fully offline from host files (use when agent is missing)

--- DIAGNOSTICS (read-only) ---------------------------------------------------
  -CheckDiskHealth       Show disk/partition/filesystem health report
  -CheckRDPPolicies      Show current RDP auth policy values
  -CollectEventLogs      Copy guest event logs and crash dumps to C:\temp on the host
  -CollectMinidumps      Copy minidumps, MEMORY.DMP and LiveKernelReports to C:\temp on the host
  -AnalyzeCriticalBootFiles  Validate presence of critical boot/system binaries used during startup
  -AnalyzeSyntheticDrivers  Validate Azure/Hyper-V synthetic drivers (vmbus/storvsc/netvsc)
  -AnalyzeProxyState     Show machine proxy/PAC settings that may block remote management
  -AnalyzeBcdConsistency Validate BCD loader/device/path consistency for current boot mode
  -GetBootPathReport     Full boot chain health check: traces all 5 boot phases (Pre-Boot -> Boot Manager
                           -> OS Loader -> NTOS Kernel -> Logon) validating every file, driver, and registry
                           setting in load order with signature verification and fix suggestions
  -AnalyzeDomainTrustState  Assess likely domain-join/trust indicators from offline registry
  -ListStartupPrograms   List all auto-start programs (Run/RunOnce/Startup folders/Setup CmdLine)
  -ScanNetBindings       Report third-party network binding components (non-ms_ ComponentId)
  -SysCheck              Full offline diagnostic scan: BCD, services, device filters, RDP, networking,
                           Azure Agent, security settings, crash artefacts - with fix suggestions

--- BOOT & BCD ----------------------------------------------------------------
  -DisableStartupRepair  Stop VM from looping into WinRE on failed boot
  -EnableBootLog         Enable ntbtlog.txt boot logging
  -EnableSerialConsole   Enable EMS/Serial Console (Azure Serial Console access via SAC)
  -EnableStartupRepair   Re-enable automatic startup repair / WinRE on boot failure
  -EnableTestSigning     Enable BCD test signing (allow unsigned drivers)
  -DisableTestSigning    Disable BCD test signing
  -FixBoot               Rebuild BCD from scratch
  -FixBootSector         Repair MBR/VBR boot sector (Gen1/BIOS only; bootrec)
  -RecreateBootPartition Recreate missing boot partition (System Reserved for Gen1, EFI SP for Gen2) and run bcdboot
  -RemoveSafeModeFlag    Remove Safe Mode flag
  -TryLGKC               Switch boot to Last Known Good Control Set
  -TryOtherBootConfig    Switch boot to a different HKLM ControlSet
  -FixSessionManager     Remove BootExecute/SetupExecute entries with missing binaries (black screen fix)
  -TrySafeMode           Set boot to Safe Mode (minimal)

--- DISK & FILESYSTEM ---------------------------------------------------------
  -RepairComponentStore   Run DISM ScanHealth + RestoreHealth on the component store
    -RepairSource <path>     (sub-option) .wim, .iso, .msu, or .cab to use as repair source
  -FixNTFS               Run chkdsk on the Windows partition
    -DriveLetter <letter>    (sub-option) target a specific drive letter instead of the auto-detected Windows partition
  -FixSanPolicy          Set SAN policy to OnlineAll (fix offline disks after migration)
  -RepairSystemFile <name[,name,...]>  Replace missing/0-byte system binary from WinSxS or DriverStore
  -RunSFC                Run SFC in offline mode
  -SetFullMemDump        Configure full memory dump + pagefile on C:

--- DRIVERS & DEVICE FILTERS --------------------------------------------------
  -DisableDriverOrService <name[,name,...]>  Disable one or more named services or drivers (sets Start=4)
  -DisableDriverVerifier   Disable Driver Verifier (clears VerifyDrivers/VerifyDriverLevel)
  -EnableDriverVerifier [driver1.sys,...]  Enable Driver Verifier with standard flags; omit value to verify all drivers
  -EnsureSyntheticDriversEnabled  Re-enable core Azure synthetic drivers (vmbus/storvsc/netvsc)
  -EnableDriverOrService  <name[,name,...]>  Re-enable one or more named services or drivers
  -DriverStartType <type>           Start type for -EnableDriverOrService: Boot, System, Automatic, Manual (default), Disabled
  -DisableThirdPartyDrivers    Disable all non-Microsoft Boot/System kernel drivers
  -EnableThirdPartyDrivers     Re-enable previously disabled third-party kernel drivers
  -GetServicesReport           List drivers from the offline ControlSet grouped by start type,
                                 flagging missing binaries and non-Microsoft vendors
    -IncludeServices             (sub-option) also include Win32 services, not just kernel drivers
    -IssuesOnly                  (sub-option) show only rows that need attention: missing binary,
                                   non-Microsoft vendor, or ErrorControl Severe/Critical (>=2)
  -FixDeviceFilters      Scan and remove unsafe UpperFilters/LowerFilters from device classes (disk/net/volume)
    -KeepDefaultFilters    (sub-option) strict mode: only inbox safe-list entries kept; removes Microsoft-signed
                             non-defaults like InDskFlt that are not standard on Azure VMs
  -CopyACPISettings      Copy legacy Hyper-V ACPI Enum entries to newer device IDs (VMBus->MSFT1000,
                           Hyper_V_Gen_Counter_V1->MSFT1002); fixes missing synthetic device detection

--- NETWORKING & FIREWALL -----------------------------------------------------
  -DisableBFE            Disable Base Filtering Engine service
  -DisableFirewall       Disable Windows Firewall for all profiles (Domain/Private/Public)
  -EnableBFE             Re-enable Base Filtering Engine service
  -FixNetBindings        Remove orphaned third-party network binding components (missing binary; prevents NDIS init failure)
  -ResetNetworkStack     Reset TCP/IP stack, Winsock, firewall and DNS at next boot (also clears static DNS offline)
  -ResetInterfacesToDHCP Reset interface IPv4 settings to DHCP and clear static DNS/gateway values
  -ClearProxyState       Clear machine-level proxy/PAC settings in offline SOFTWARE hive

--- RDP & REMOTE ACCESS -------------------------------------------------------
  -DisableNLA            Disable Network Level Authentication
  -EnableNLA             Enable Network Level Authentication
  -EnableWinRMHTTPS      Configure WinRM HTTPS listener via startup script
  -FixRDP                Reset RDP registry settings to defaults
  -FixRDPAuth            Set optimal RDP/NLA/NTLM auth policy for recovery
  -FixRDPCert            Recreate the self-signed RDP certificate
  -FixRDPPermissions     Reset RDP private key and certificate service permissions

--- REGISTRY ------------------------------------------------------------------
  -CheckRegistryHealth         Read-only integrity check of SYSTEM/SOFTWARE hives using chkreg.exe
  -FixRegistryCorruption       Repair corrupted SYSTEM/SOFTWARE hives using chkreg.exe (backs up originals)
  -EnableRegBackup             Enable periodic registry backups to RegBack folder
  -RestoreRegistryFromRegBack  Restore SYSTEM/SOFTWARE hives from RegBack backup
  -ResetGroupPolicy            Delete local Group Policy cache and clear SOFTWARE\Policies

--- SECURITY ------------------------------------------------------------------
  -DisableAppLocker            Disable AppLocker enforcement and AppIDSvc (fixes boot blocked by bad policy)
  -GetAppLockerReport          Show AppLocker enforcement state, AppIDSvc config, and parsed rules per collection
  -DisableCredentialGuard      Disable Credential Guard and LSA protection
  -EnableCredentialGuard       Re-enable Credential Guard and LSA protection
  -FixWinlogon                 Reset Winlogon Shell/Userinit to Windows defaults (fixes black screen)
  -FixProfileLoad              Fix corrupted user profiles (.bak duplicates, temporary profile flags)

--- STARTUP PROGRAMS ----------------------------------------------------------
  -DisableStartupPrograms      Disable all auto-start programs (Run/RunOnce registry + Startup folders)

--- USERS & RIGHTS ------------------------------------------------------------
  -AddTempUser           Add a local admin via Group Policy startup script
  -AddTempUser2          Add a local admin via Setup CmdLine (domain-joined VMs)
  -FixUserRights         Reset user rights assignments to Windows defaults
  -ResetLocalAdminPassword  Reset an existing local admin account password at next boot

--- WINDOWS UPDATE ------------------------------------------------------------
  -AnalyzeComponentStore Analyze CBS.log for corrupt components and identify required update versions
  -AnalyzeServicingState Check pending CBS/servicing markers (pending.xml, SessionsPending, RebootPending)
  -ListInstalledUpdates  List installed Windows Updates (KB numbers) from offline CBS packages
  -DisableWindowsUpdate  Disable Windows Update services to stop boot loops
  -FixPendingUpdates     Remove pending Windows Update transactions
  -UninstallWindowsUpdate <KB>  Mark a KB update as Absent in CBS (offline best-effort uninstall)
  -PrepareRecoveryDiagnostics  Bundle for broken VMs: boot log + serial console + full memory dump config

AVAILABLE DISKS:
"@
            if ($null -ne $script:LocalOsDiskNumber) {
                Write-Host "  (Disk $script:LocalOsDiskNumber excluded - hosts the local C: drive and cannot be a repair target)" -ForegroundColor DarkYellow
            }

            # Build a disk-number -> VM-name map for all non-Off VMs
            # VHD/VHDX-backed drives don't expose DiskNumber on HardDrives directly;
            # resolve via Get-VHD which populates DiskNumber when the VHD is mounted.
            # Include ALL VMs (any state) so the listing is informational for Off VMs too.
            # A running VM tag is appended with its state when not Running.
            $diskToVM = @{}
            if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
                Get-VM -ErrorAction SilentlyContinue | ForEach-Object {
                    $v = $_
                    $stateLabel = if ($v.State -eq 'Running') { $v.Name } else { "$($v.Name) [$($v.State)]" }
                    foreach ($hd in $v.HardDrives) {
                        $resolvedNum = -1
                        if ($null -ne $hd.DiskNumber -and [int]$hd.DiskNumber -ge 0) {
                            $resolvedNum = [int]$hd.DiskNumber
                        }
                        elseif ($hd.Path -match '\.vhdx?$') {
                            $vhd = Get-VHD -Path $hd.Path -ErrorAction SilentlyContinue
                            if ($vhd -and $null -ne $vhd.DiskNumber -and [int]$vhd.DiskNumber -ge 0) {
                                $resolvedNum = [int]$vhd.DiskNumber
                            }
                        }
                        if ($resolvedNum -ge 0) {
                            $diskToVM[$resolvedNum] = $stateLabel
                        }
                    }
                }
            }

            Get-Disk | Sort-Object Number | Where-Object { $null -eq $script:LocalOsDiskNumber -or $_.Number -ne $script:LocalOsDiskNumber } | ForEach-Object {
                $d = $_
                $vmTag = if ($diskToVM.ContainsKey([int]$d.Number)) { " [attached to VM: $($diskToVM[[int]$d.Number])]" } else { '' }
                Write-Host "  Disk $($d.Number): $($d.PartitionStyle) | $([math]::Round($d.Size / 1GB)) GB | $($d.FriendlyName)$vmTag"
                $parts = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue
                if (-not $parts) { Write-Host "    (no partitions)"; return }
                foreach ($p in $parts) {
                    $sz = [math]::Round($p.Size / 1MB)
                    $ltr = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { '(no letter)' }
                    Write-Host "    +- Partition $($p.PartitionNumber): $ltr | $($p.Type) | $($sz) MB"
                }
            }
            Write-Host ""
            return
        }

        # Validate mutual exclusivity
        if ($DiskNumber -ge 0 -and -not [string]::IsNullOrWhiteSpace($VMName)) {
            Write-Error "Specify either -DiskNumber or -VMName, not both."
            return
        }

        # Refuse to operate on the local OS disk when -DiskNumber is supplied directly
        if ($null -ne $script:LocalOsDiskNumber -and $DiskNumber -ge 0 -and $DiskNumber -eq $script:LocalOsDiskNumber) {
            Write-Error "Disk $DiskNumber hosts the local C: drive. Refusing to modify it to prevent breaking the Hyper-V host."
            return
        }

        # Initialize logging and target (resolve VM/disk, bring disk online, detect partitions)
        # Determine if any write/repair action was requested (exclude pure read-only switches)
        $readOnlySwitches = @('SysCheck', 'CheckDiskHealth', 'ScanNetBindings', 'CheckRDPPolicies', 'CollectEventLogs', 'CollectMinidumps', 'ShowLastSession', 'GetServicesReport', 'GetAppLockerReport', 'ListInstalledUpdates', 'ListStartupPrograms', 'AnalyzeCriticalBootFiles', 'AnalyzeSyntheticDrivers', 'AnalyzeProxyState', 'GetBootPathReport', 'AnalyzeBcdConsistency', 'AnalyzeComponentStore', 'AnalyzeServicingState', 'AnalyzeDomainTrustState')
        $hasRepairAction = $PSBoundParameters.Keys | Where-Object { $readOnlySwitches -notcontains $_ -and $_ -notin @('VMName', 'DiskNumber', 'LeaveDiskOnline', 'DriveLetter', 'RepairSource', 'IncludeServices', 'IssuesOnly', 'KeepDefaultFilters', 'DriverStartType', 'LoadHive', 'UnloadHive') }
        if ($hasRepairAction) {
            Write-Host "  Tip: if you haven't already, a VM snapshot or disk backup before making changes is always a safe starting point." -ForegroundColor DarkGray
            Write-Host ""
        }
        if (-not (Initialize-TargetDisk -VMName $VMName -DiskNumber $DiskNumber)) {
            return
        }

        # Guest computer name is captured opportunistically by Invoke-WithHive
        # the first time the SYSTEM hive is loaded for any action.
        $script:GuestComputerName = ''

        # Log session start after disk is resolved so disk info appears in every entry
        Start-ActionLog "Repair-OfflineDisk start"

        try {
            if ($FixNTFS) { FixDiskCorruption -DriveLetter $DriveLetter }
            if ($FixBoot) { RebuildBCD }
            if ($FixBootSector) { FixBootSector }
            if ($RecreateBootPartition) { RecreateBootPartition }
            if ($RepairComponentStore) { RunDismHealth -RepairSource $RepairSource }
            if ($AnalyzeComponentStore) { AnalyzeComponentStore }
            if ($RunSFC) { RunSFC }
            if ($TryLGKC) { SetLKGC }
            if ($TryOtherBootConfig) { RevertLKGC }
            if ($TrySafeMode) { SetSafeMode }
            if ($RemoveSafeModeFlag) { RemoveSafeMode }
            if ($EnableBootLog) { SetBootLog }
            if ($DisableStartupRepair) { DisableStartupRepair }
            if ($EnableStartupRepair) { EnableStartupRepair }
            if ($DisableBFE) { Disable-ServiceOrDriver -ServiceName BFE }
            if ($EnableBFE) { Enable-ServiceOrDriver -ServiceName BFE -StartValue 2 }
            if ($AddTempUser) {
                Write-Host "Please provide the credential (no .\ or domain\user, just user): " -ForegroundColor Yellow
                AddNewUser -WinDrive $script:WinDriveLetter -Credential (Get-Credential)
            }
            if ($AddTempUser2) {
                Write-Host "Please provide the credential (no .\ or domain\user, just user): " -ForegroundColor Yellow
                AddNewUser2 -Credential (Get-Credential)
            }
            if ($ResetLocalAdminPassword) { ResetLocalAdminPassword }
            if ($SetFullMemDump) { ConfigureFullMemDump }
            if ($FixRDP) { ResetRDPSettings }
            if ($FixRDPCert) { RecreateRDPCertificate }
            if ($FixRDPPermissions) { ResetRDPPrivKeyPermissions }
            if ($DisableNLA) { SetNLA -Enable $false }
            if ($EnableNLA) { SetNLA -Enable $true }
            if ($EnableWinRMHTTPS) { SetWinRMHTTPSEnabled }
            if ($FixPendingUpdates) { ClearPendingUpdates }
            if ($DisableWindowsUpdate) { DisableWindowsUpdate }
            if ($FixUserRights) { ResetUserRights }
            if ($RestoreRegistryFromRegBack) { RestoreRegistryFromRegBack }
            if ($EnableRegBackup) { EnableRegBackup }
            if ($DisableThirdPartyDrivers) { DisableThirdPartyDrivers }
            if ($EnableThirdPartyDrivers) { EnableThirdPartyDrivers }
            if ($GetServicesReport) { GetServicesReport -IncludeServices:$IncludeServices -IssuesOnly:$IssuesOnly }
            foreach ($d in $DisableDriverOrService) { if (-not [string]::IsNullOrWhiteSpace($d)) { Disable-ServiceOrDriver -ServiceName $d.Trim() } }
            if ($EnableDriverOrService.Count -gt 0) {
                $startMap = @{ Boot = 0; System = 1; Automatic = 2; Manual = 3; Disabled = 4 }
                $startInt = $startMap[$DriverStartType]
                foreach ($d in $EnableDriverOrService) { if (-not [string]::IsNullOrWhiteSpace($d)) { Enable-ServiceOrDriver -ServiceName $d.Trim() -StartValue $startInt } }
            }
            if ($DisableCredentialGuard) { DisableCredentialGuard }
            if ($EnableCredentialGuard) { EnableCredentialGuard }
            if ($DisableAppLocker) { DisableAppLocker }
            if ($GetAppLockerReport) { GetAppLockerReport }
            if ($FixSanPolicy) { FixSanPolicy }
            if ($FixAzureGuestAgent) { FixAzureGuestAgent }
            if ($InstallAzureVMAgent) { InstallAzureVMAgentOffline }
            if ($FixDeviceFilters) { FixDeviceClassFilters -KeepDefaultFilters:$KeepDefaultFilters }
            if ($FixSessionManager) { FixSessionManagerBootEntries }
            if ($CopyACPISettings) { CopyACPISettings }
            if ($ScanNetBindings) { ScanNetAdapterBindings }
            if ($FixNetBindings) { RemoveOrphanedNetBindings }
            if ($SysCheck) { RunSystemCheck }
            if ($ResetNetworkStack) { ResetNetworkStack }
            if ($EnableTestSigning) { SetTestSigning -Enable $true }
            if ($DisableTestSigning) { SetTestSigning -Enable $false }
            if ($CheckDiskHealth) { CheckDiskHealth }
            if ($CollectEventLogs) { CollectEventLogs }
            if ($AnalyzeCriticalBootFiles) { AnalyzeCriticalBootFiles }
            if ($RepairSystemFile.Count -gt 0) { RepairBrokenSystemFile -FileNames $RepairSystemFile }
            if ($AnalyzeSyntheticDrivers) { AnalyzeSyntheticDrivers }
            if ($EnsureSyntheticDriversEnabled) { EnsureSyntheticDriversEnabled }
            if ($ResetInterfacesToDHCP) { ResetInterfacesToDHCP }
            if ($AnalyzeProxyState) { AnalyzeProxyState }
            if ($ClearProxyState) { ClearProxyState }
            if ($GetBootPathReport) { GetBootPathReport }
            if ($AnalyzeBcdConsistency) { AnalyzeBcdConsistency }
            if ($AnalyzeServicingState) { AnalyzeServicingState }
            if ($AnalyzeDomainTrustState) { AnalyzeDomainTrustState }
            if ($PrepareRecoveryDiagnostics) { PrepareRecoveryDiagnostics }
            if ($CheckRDPPolicies) { GetRdpAuthPolicySnapshot }
            if ($FixRDPAuth) { SetRdpAuthPolicyOptimal }
            if ($DisableDriverVerifier) { DisableDriverVerifier }
            if ($PSBoundParameters.ContainsKey('EnableDriverVerifier')) { EnableDriverVerifier -DriverList $EnableDriverVerifier }
            if ($CollectMinidumps) { CollectMinidumps }
            if ($ResetGroupPolicy) { ResetGroupPolicy }
            if ($FixWinlogon) { FixWinlogon }
            if ($FixProfileLoad) { FixProfileLoad }
            if ($CheckRegistryHealth) { CheckRepairRegistryHives }
            if ($FixRegistryCorruption) { CheckRepairRegistryHives -Repair }
            if ($EnableSerialConsole) { EnableSerialConsole }
            if ($ListInstalledUpdates) { ListInstalledUpdates }
            if (-not [string]::IsNullOrWhiteSpace($UninstallWindowsUpdate)) { UninstallWindowsUpdate -KBNumber $UninstallWindowsUpdate }
            if ($ListStartupPrograms) { ListStartupPrograms }
            if ($DisableStartupPrograms) { DisableStartupPrograms }
            if ($DisableFirewall) { DisableFirewall }

            # -LoadHive: mount requested hives and leave them loaded for manual inspection
            foreach ($hive in $LoadHive) {
                $OfflineWindowsPath = Join-Path $script:WinDriveLetter 'Windows'
                Write-Host "Loading offline $hive hive..." -ForegroundColor Cyan
                MountOffHive -WinPath $OfflineWindowsPath -Hive $hive
                Write-Host "  [OK] HKLM:\BROKEN$hive is now loaded. Use regedit or reg.exe to inspect/edit." -ForegroundColor Green
                $scriptName = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { 'Repair-AzVMDisk.ps1' }
                Write-Host "  [!]  Run: .\$scriptName -DiskNumber $($script:DiskNumber) -UnloadHive $hive  to unload and take the disk offline when done." -ForegroundColor Yellow
            }

            # -UnloadHive: unmount requested hives (before the disk-offline step in finally)
            foreach ($hive in $UnloadHive) {
                Write-Host "Unloading offline $hive hive..." -ForegroundColor Cyan
                UnmountOffHive -Hive $hive
                Write-Host "  [OK] HKLM:\BROKEN$hive unloaded." -ForegroundColor Green
            }
        }
        catch {
            Write-Error "Repair-OfflineDisk encountered an error: $_"
            throw
        }
        finally {
            # When -LoadHive was used, keep the disk online so the loaded hives remain accessible
            $keepOnlineForHive = $LoadHive.Count -gt 0 -and $UnloadHive.Count -eq 0
            if (-not $LeaveDiskOnline -and -not $keepOnlineForHive -and $script:DiskNumber -ge 0) {
                Write-Host "`r`nSetting disk $script:DiskNumber offline..."
                try {
                    Set-Disk -Number $script:DiskNumber -IsOffline $true
                    Write-Host "[OK] Disk $script:DiskNumber is now offline and can be safely reconnected or used with the VM." -ForegroundColor Green
                }
                catch {
                    Write-Warning "Could not set disk $script:DiskNumber offline: $_"
                }

                # Dismount VHD if we auto-mounted it (prevents "file locked" when starting the VM)
                if ($script:AutoMountedVHDPath) {
                    Write-Host "Dismounting auto-mounted VHD: $($script:AutoMountedVHDPath)..."
                    try {
                        Dismount-VHD -Path $script:AutoMountedVHDPath -ErrorAction Stop
                        Write-Host "[OK] VHD dismounted." -ForegroundColor Green
                    }
                    catch {
                        Write-Warning "Could not dismount VHD: $_"
                    }
                    $script:AutoMountedVHDPath = $null
                }
            }
        }
    }

    # Promote dynamic sub-parameters to local variables so the rest of the script can use them.
    # Dynamic params are in $PSBoundParameters but not in automatic $variables.
    $DriveLetter = if ($PSBoundParameters.ContainsKey('DriveLetter')) { $PSBoundParameters['DriveLetter'] }      else { '' }
    $RepairSource = if ($PSBoundParameters.ContainsKey('RepairSource')) { $PSBoundParameters['RepairSource'] }     else { '' }
    $IncludeServices = [bool]$PSBoundParameters.ContainsKey('IncludeServices')
    $IssuesOnly = [bool]$PSBoundParameters.ContainsKey('IssuesOnly')
    $KeepDefaultFilters = [bool]$PSBoundParameters.ContainsKey('KeepDefaultFilters')
    $DriverStartType = if ($PSBoundParameters.ContainsKey('DriverStartType')) { $PSBoundParameters['DriverStartType'] }  else { 'Manual' }
    $Detailed = [bool]$PSBoundParameters.ContainsKey('Detailed')
    $All = [bool]$PSBoundParameters.ContainsKey('All')
    $SessionId = if ($PSBoundParameters.ContainsKey('SessionId')) { $PSBoundParameters['SessionId'] }        else { '' }
    $ExportTo = if ($PSBoundParameters.ContainsKey('ExportTo')) { $PSBoundParameters['ExportTo'] }         else { '' }

    # Show log entries and exit when -ShowLastSession is requested
    if ($ShowLastSession) {
        Get-LastRepairSession -SessionId $SessionId -Detailed:$Detailed -All:$All -ExportTo $ExportTo
        return
    }

    # Invoke consolidated helper with script-bound parameters
    Repair-OfflineDisk @PSBoundParameters
} # end