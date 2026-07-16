[CmdletBinding()]
param(
    [switch]$Json,
    [string]$Repository
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$checks = New-Object 'System.Collections.Generic.List[object]'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$mirrorConfigPath = Join-Path $repoRoot 'Config\CIMirror.json'
$expectedSourceRepository = 'TrueAlpha0902/Notes'
$expectedMirrorRepository = 'TrueAlpha0902/NextStep-CI'
$expectedMirrorBranch = 'main'

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Warn', 'Block', 'Manual')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $checks.Add([pscustomobject]@{
            Code = $Code
            Name = $Name
            Status = $Status
            Message = $Message
        }) | Out-Null
}

function Get-MirrorConfiguration {
    if (-not (Test-Path -LiteralPath $mirrorConfigPath -PathType Leaf)) {
        return $null
    }
    try {
        $text = Get-Content -LiteralPath $mirrorConfigPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 16KB) {
            return $null
        }
        $configuration = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    $expectedKeys = @(
        'format', 'version', 'sourceRepository', 'mirrorRepository',
        'mirrorBranch', 'historyPolicy', 'licensePolicy'
    )
    $properties = @($configuration.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($properties.Count -ne $expectedKeys.Count) {
        return $null
    }
    foreach ($key in $expectedKeys) {
        if ($properties -cnotcontains $key -or
            [regex]::Matches($text, ('"' + [regex]::Escape($key) + '"\s*:')).Count -ne 1) {
            return $null
        }
    }
    if ($configuration.version -isnot [int] -or [int]$configuration.version -ne 1 -or
        [string]$configuration.format -cne 'nextstep-public-ci-mirror' -or
        [string]$configuration.sourceRepository -cne $expectedSourceRepository -or
        [string]$configuration.mirrorRepository -cne $expectedMirrorRepository -or
        [string]$configuration.mirrorBranch -cne $expectedMirrorBranch -or
        [string]$configuration.historyPolicy -cne 'single-root-snapshot' -or
        [string]$configuration.licensePolicy -cne 'all-rights-reserved') {
        return $null
    }
    return $configuration
}

function Get-RepositorySlug {
    param(
        [string]$RequestedRepository,
        $Configuration
    )

    if ($null -eq $Configuration) {
        return $null
    }
    $configuredRepository = [string]$Configuration.mirrorRepository

    if (-not [string]::IsNullOrWhiteSpace($RequestedRepository)) {
        if ($RequestedRepository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            return $null
        }
        if ($RequestedRepository -cne $configuredRepository) {
            return $null
        }
    }
    return $configuredRepository
}

function Get-OriginRepositorySlug {
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $git) {
        return $null
    }

    $remote = & $git.Source -C $repoRoot remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $remoteText = ($remote -join '').Trim()
    $pattern = '^(?:(?:https://github\.com/)|(?:ssh://git@github\.com/)|(?:git@github\.com:))(?<owner>[A-Za-z0-9_.-]+)/(?<repository>[A-Za-z0-9_.-]+?)(?:\.git)?/?$'
    if ($remoteText -cmatch $pattern) {
        return ('{0}/{1}' -f $Matches['owner'], $Matches['repository'])
    }

    return $null
}

function Get-UninstallEntries {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entries = @()
    foreach ($path in $paths) {
        try {
            $entries += @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)
        }
        catch {
            # A missing or inaccessible registry view is treated as having no entries.
        }
    }
    return @($entries)
}

function Get-RegistryStringProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }
    return [string]$property.Value
}

function Get-StorePackagePresent {
    param([Parameter(Mandatory = $true)][string[]]$NamePatterns)

    $command = Get-Command Get-AppxPackage -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $false
    }

    try {
        $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue)
        foreach ($package in $packages) {
            foreach ($pattern in $NamePatterns) {
                if ([string]$package.Name -match $pattern) {
                    return $true
                }
            }
        }
    }
    catch {
        return $false
    }
    return $false
}

function Get-SideloadlyCandidatePaths {
    param([object[]]$UninstallEntries)

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $commands = @(Get-Command Sideloadly.exe -CommandType Application -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        if (-not [string]::IsNullOrWhiteSpace($command.Source)) {
            $candidates.Add([string]$command.Source) | Out-Null
        }
    }

    $knownPaths = @()
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $knownPaths += (Join-Path $env:LOCALAPPDATA 'Sideloadly\Sideloadly.exe')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $knownPaths += (Join-Path $env:ProgramFiles 'Sideloadly\Sideloadly.exe')
    }
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $knownPaths += (Join-Path $programFilesX86 'Sideloadly\Sideloadly.exe')
    }
    foreach ($knownPath in $knownPaths) {
        $candidates.Add($knownPath) | Out-Null
    }

    foreach ($entry in $UninstallEntries) {
        $displayName = Get-RegistryStringProperty -Object $entry -Name 'DisplayName'
        if ($displayName -notmatch '(?i)^Sideloadly(?:\s|$)') {
            continue
        }
        $installLocation = Get-RegistryStringProperty -Object $entry -Name 'InstallLocation'
        if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
            $candidates.Add((Join-Path $installLocation 'Sideloadly.exe')) | Out-Null
        }
        $displayIconValue = Get-RegistryStringProperty -Object $entry -Name 'DisplayIcon'
        if (-not [string]::IsNullOrWhiteSpace($displayIconValue)) {
            $displayIcon = $displayIconValue.Trim()
            if ($displayIcon -match '^"([^"]+)"(?:,\s*\d+)?$') {
                $displayIcon = [string]$Matches[1]
            }
            else {
                $displayIcon = ($displayIcon -replace ',\s*\d+$', '').Trim('"')
            }
            if ([System.IO.Path]::GetFileName($displayIcon) -ieq 'Sideloadly.exe') {
                $candidates.Add($displayIcon) | Out-Null
            }
        }
    }

    return @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Find-VerifiedSideloadly {
    param([object[]]$UninstallEntries)

    foreach ($candidate in (Get-SideloadlyCandidatePaths -UninstallEntries $UninstallEntries)) {
        try {
            $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).ProviderPath
            if ([System.IO.Path]::GetFileName($resolved) -ine 'Sideloadly.exe') {
                continue
            }
            $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                continue
            }
            $productText = ('{0} {1}' -f [string]$item.VersionInfo.ProductName, [string]$item.VersionInfo.FileDescription)
            if ($productText -notmatch '(?i)Sideloadly') {
                continue
            }
            $signature = Get-AuthenticodeSignature -FilePath $resolved -ErrorAction Stop
            if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                continue
            }
            return [pscustomobject]@{
                Path = $resolved
                Version = [string]$item.VersionInfo.FileVersion
            }
        }
        catch {
            # Continue looking without disclosing local paths or signature details.
        }
    }
    return $null
}

if ($env:OS -eq 'Windows_NT' -and [Environment]::OSVersion.Version.Major -ge 10) {
    Add-Check -Code 'windows.version' -Name 'Windows' -Status 'Pass' -Message 'Windows 10 or 11 is available.'
}
else {
    Add-Check -Code 'windows.version' -Name 'Windows' -Status 'Block' -Message 'Windows 10 or 11 is required.'
}

if ($PSVersionTable.PSVersion -ge [version]'5.1') {
    Add-Check -Code 'powershell.version' -Name 'PowerShell' -Status 'Pass' -Message ('PowerShell {0} is supported.' -f $PSVersionTable.PSVersion.ToString())
}
else {
    Add-Check -Code 'powershell.version' -Name 'PowerShell' -Status 'Block' -Message 'Windows PowerShell 5.1 or later is required.'
}

try {
    $driveRoot = [System.IO.Path]::GetPathRoot($repoRoot)
    $driveName = $driveRoot.TrimEnd('\').TrimEnd(':')
    $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
    $freeGiB = [math]::Floor($drive.Free / 1GB)
    if ($drive.Free -ge 2GB) {
        Add-Check -Code 'disk.free' -Name 'Free disk space' -Status 'Pass' -Message ('At least 2 GiB is available ({0} GiB free).' -f $freeGiB)
    }
    else {
        Add-Check -Code 'disk.free' -Name 'Free disk space' -Status 'Block' -Message 'At least 2 GiB of free disk space is required.'
    }
}
catch {
    Add-Check -Code 'disk.free' -Name 'Free disk space' -Status 'Warn' -Message 'Free disk space could not be verified.'
}

$gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $gitCommand) {
    Add-Check -Code 'tool.git' -Name 'Git' -Status 'Block' -Message 'Git is required to bind downloads to the current commit.'
}
else {
    Add-Check -Code 'tool.git' -Name 'Git' -Status 'Pass' -Message 'Git is available.'
}

$mirrorConfiguration = Get-MirrorConfiguration
if ($null -eq $mirrorConfiguration) {
    Add-Check -Code 'github.mirrorConfig' -Name 'CI mirror configuration' -Status 'Block' -Message 'Config/CIMirror.json is missing or does not match the supported NextStep public mirror policy.'
}
else {
    Add-Check -Code 'github.mirrorConfig' -Name 'CI mirror configuration' -Status 'Pass' -Message 'The public CI mirror policy is configured.'
}

$originRepository = Get-OriginRepositorySlug
if ($null -ne $mirrorConfiguration -and $originRepository -ceq [string]$mirrorConfiguration.sourceRepository) {
    Add-Check -Code 'github.sourceOrigin' -Name 'Private source origin' -Status 'Pass' -Message 'The worktree origin is the configured authoritative private repository.'
}
else {
    Add-Check -Code 'github.sourceOrigin' -Name 'Private source origin' -Status 'Block' -Message 'The worktree must originate from the configured authoritative private repository.'
}

$repositorySlug = Get-RepositorySlug -RequestedRepository $Repository -Configuration $mirrorConfiguration
if ($null -eq $repositorySlug) {
    Add-Check -Code 'github.repository' -Name 'Public CI mirror' -Status 'Block' -Message 'The repository argument must be the exact public CI mirror configured by this worktree.'
}
else {
    Add-Check -Code 'github.repository' -Name 'Public CI mirror' -Status 'Pass' -Message 'The configured public CI mirror target was determined.'
}

$ghCommand = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $ghCommand) {
    Add-Check -Code 'tool.gh' -Name 'GitHub CLI' -Status 'Block' -Message 'GitHub CLI is required to retrieve the verified artifact.'
}
else {
    & $ghCommand.Source auth status --hostname github.com *> $null
    if ($LASTEXITCODE -ne 0) {
        Add-Check -Code 'github.auth' -Name 'GitHub authentication' -Status 'Block' -Message 'GitHub CLI is not authenticated. Sign in interactively outside this script.'
    }
    else {
        Add-Check -Code 'github.auth' -Name 'GitHub authentication' -Status 'Pass' -Message 'GitHub CLI has an authenticated session.'
        if ($null -ne $repositorySlug) {
            & $ghCommand.Source api --hostname github.com --method GET ('repos/{0}' -f $repositorySlug) *> $null
            if ($LASTEXITCODE -eq 0) {
                Add-Check -Code 'github.access' -Name 'Public mirror access' -Status 'Pass' -Message 'The authenticated GitHub session can read the public CI mirror.'
            }
            else {
                Add-Check -Code 'github.access' -Name 'Public mirror access' -Status 'Block' -Message 'The authenticated GitHub session cannot read the configured public CI mirror.'
            }
        }
        if ($null -ne $mirrorConfiguration) {
            & $ghCommand.Source api --hostname github.com --method GET ('repos/{0}' -f [string]$mirrorConfiguration.sourceRepository) *> $null
            if ($LASTEXITCODE -eq 0) {
                Add-Check -Code 'github.sourceAccess' -Name 'Private source access' -Status 'Pass' -Message 'The authenticated GitHub session can validate the authoritative private repository.'
            }
            else {
                Add-Check -Code 'github.sourceAccess' -Name 'Private source access' -Status 'Block' -Message 'The authenticated GitHub session cannot validate the authoritative private repository.'
            }
        }
    }
}

$uninstallEntries = @(Get-UninstallEntries)
$sideloadly = Find-VerifiedSideloadly -UninstallEntries $uninstallEntries
if ($null -eq $sideloadly) {
    Add-Check -Code 'sideloadly.signature' -Name 'Sideloadly' -Status 'Block' -Message 'An installed Sideloadly.exe with a valid Authenticode signature was not found.'
}
else {
    $versionText = if ([string]::IsNullOrWhiteSpace($sideloadly.Version)) { 'version not reported' } else { 'version ' + $sideloadly.Version }
    Add-Check -Code 'sideloadly.signature' -Name 'Sideloadly' -Status 'Manual' -Message ('An Authenticode-valid Sideloadly candidate was found ({0}). Confirm that you installed it from the official Sideloadly download before opening its trusted shortcut; this script will not execute it.' -f $versionText)
}

$desktopITunes = @($uninstallEntries | Where-Object { (Get-RegistryStringProperty -Object $_ -Name 'DisplayName').Trim() -ieq 'iTunes' }).Count -gt 0
$desktopICloud = @($uninstallEntries | Where-Object { (Get-RegistryStringProperty -Object $_ -Name 'DisplayName').Trim() -ieq 'iCloud' }).Count -gt 0
$desktopITunesPaths = @()
$desktopICloudPaths = @()
$classicProgramFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    $desktopITunesPaths += (Join-Path $env:ProgramFiles 'iTunes\iTunes.exe')
    $desktopICloudPaths += (Join-Path $env:ProgramFiles 'Common Files\Apple\Internet Services\iCloud.exe')
    $desktopICloudPaths += (Join-Path $env:ProgramFiles 'iCloud\iCloud.exe')
}
if (-not [string]::IsNullOrWhiteSpace($classicProgramFilesX86)) {
    $desktopITunesPaths += (Join-Path $classicProgramFilesX86 'iTunes\iTunes.exe')
    $desktopICloudPaths += (Join-Path $classicProgramFilesX86 'Common Files\Apple\Internet Services\iCloud.exe')
    $desktopICloudPaths += (Join-Path $classicProgramFilesX86 'iCloud\iCloud.exe')
}
if (@($desktopITunesPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0) {
    $desktopITunes = $true
}
if (@($desktopICloudPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0) {
    $desktopICloud = $true
}
$storeITunes = Get-StorePackagePresent -NamePatterns @('(?i)(?:^|\.)iTunes$')
$storeICloud = Get-StorePackagePresent -NamePatterns @('(?i)(?:^|\.)iCloud$')
$storeAppleDevices = Get-StorePackagePresent -NamePatterns @('(?i)(?:^|\.)AppleDevices$')

if ($storeITunes) {
    Add-Check -Code 'apple.itunes' -Name 'Classic iTunes' -Status 'Block' -Message 'A Microsoft Store iTunes package was found and is incompatible with the current Sideloadly Windows prerequisites; remove it before installing the classic/web-download version.'
}
elseif ($desktopITunes) {
    Add-Check -Code 'apple.itunes' -Name 'Classic iTunes' -Status 'Pass' -Message 'The classic/web-download iTunes installation is present.'
}
else {
    Add-Check -Code 'apple.itunes' -Name 'Classic iTunes' -Status 'Block' -Message 'The classic/web-download iTunes installation required by Sideloadly was not found.'
}

if ($storeICloud) {
    Add-Check -Code 'apple.icloud' -Name 'Classic iCloud' -Status 'Block' -Message 'A Microsoft Store iCloud package was found and is incompatible with the current Sideloadly Windows prerequisites; remove it before installing the classic/web-download version.'
}
elseif ($desktopICloud) {
    Add-Check -Code 'apple.icloud' -Name 'Classic iCloud' -Status 'Pass' -Message 'The classic/web-download iCloud installation is present.'
}
else {
    Add-Check -Code 'apple.icloud' -Name 'Classic iCloud' -Status 'Block' -Message 'The classic/web-download iCloud installation required by Sideloadly was not found.'
}

if ($storeAppleDevices) {
    Add-Check -Code 'apple.devices-app' -Name 'Apple Devices app' -Status 'Warn' -Message 'Apple Devices is present but does not replace the classic iTunes and iCloud components required by Sideloadly.'
}

$mobileDeviceService = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
if ($null -eq $mobileDeviceService) {
    Add-Check -Code 'apple.mobile-service' -Name 'Apple Mobile Device Service' -Status 'Block' -Message 'Apple Mobile Device Service was not found.'
}
elseif ($mobileDeviceService.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
    Add-Check -Code 'apple.mobile-service' -Name 'Apple Mobile Device Service' -Status 'Block' -Message 'Apple Mobile Device Service is installed but not running; start it manually or repair the Apple components.'
}
else {
    Add-Check -Code 'apple.mobile-service' -Name 'Apple Mobile Device Service' -Status 'Pass' -Message 'Apple Mobile Device Service is running.'
}

$driverPresent = $false
$commonFilesCandidates = @()
if (-not [string]::IsNullOrWhiteSpace($env:CommonProgramFiles)) {
    $commonFilesCandidates += (Join-Path $env:CommonProgramFiles 'Apple\Mobile Device Support\Drivers')
}
$commonFilesX86 = [Environment]::GetEnvironmentVariable('CommonProgramFiles(x86)')
if (-not [string]::IsNullOrWhiteSpace($commonFilesX86)) {
    $commonFilesCandidates += (Join-Path $commonFilesX86 'Apple\Mobile Device Support\Drivers')
}
foreach ($driverFolder in $commonFilesCandidates) {
    if (Test-Path -LiteralPath $driverFolder -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $driverFolder -Filter 'usbaapl*.inf' -File -ErrorAction SilentlyContinue).Count -gt 0) {
            $driverPresent = $true
            break
        }
    }
}
if (-not $driverPresent) {
    try {
        $signedDrivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
                ([string]$_.DeviceName -match '(?i)Apple Mobile Device.*USB') -or
                (([string]$_.Manufacturer -match '(?i)^Apple') -and ([string]$_.DeviceClass -match '(?i)USB'))
            })
        $driverPresent = $signedDrivers.Count -gt 0
    }
    catch {
        $driverPresent = $false
    }
}
if ($driverPresent) {
    Add-Check -Code 'apple.usb-driver' -Name 'Apple USB driver' -Status 'Pass' -Message 'An Apple Mobile Device USB driver was found.'
}
else {
    Add-Check -Code 'apple.usb-driver' -Name 'Apple USB driver' -Status 'Block' -Message 'An Apple Mobile Device USB driver was not found.'
}

$bonjour = Get-Service -Name 'Bonjour Service', 'mDNSResponder' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $bonjour) {
    Add-Check -Code 'apple.bonjour' -Name 'Bonjour' -Status 'Warn' -Message 'Bonjour was not found. USB installation can still work, but Wi-Fi refresh discovery may not.'
}
elseif ($bonjour.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
    Add-Check -Code 'apple.bonjour' -Name 'Bonjour' -Status 'Warn' -Message 'Bonjour is installed but not running. USB installation can still work, but Wi-Fi refresh discovery may not.'
}
else {
    Add-Check -Code 'apple.bonjour' -Name 'Bonjour' -Status 'Pass' -Message 'Bonjour is running for optional Wi-Fi discovery.'
}

$appleDeviceCount = 0
try {
    $appleDevices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object {
            [string]$_.PNPDeviceID -match '(?i)^USB\\VID_05AC'
        })
    $appleDeviceCount = $appleDevices.Count
}
catch {
    $appleDeviceCount = 0
}
if ($appleDeviceCount -gt 0) {
    $healthyAppleDeviceCount = @($appleDevices | Where-Object { [string]$_.Status -ieq 'OK' }).Count
    if ($healthyAppleDeviceCount -gt 0) {
        Add-Check -Code 'ipad.usb-present' -Name 'Apple USB device' -Status 'Pass' -Message ('Windows reports {0} connected Apple USB device(s), with {1} ready; no device names or identifiers are shown.' -f $appleDeviceCount, $healthyAppleDeviceCount)
    }
    else {
        Add-Check -Code 'ipad.usb-present' -Name 'Apple USB device' -Status 'Warn' -Message ('Windows reports {0} connected Apple USB device(s), but none are ready; no device names or identifiers are shown.' -f $appleDeviceCount)
    }
}
else {
    Add-Check -Code 'ipad.usb-present' -Name 'Apple USB device' -Status 'Manual' -Message 'Connect the iPad with a data-capable USB cable, unlock it, and accept the Trust prompt.'
}

$daemonDetected = $false
try {
    $daemonDetected = @(Get-Process -Name 'SideloadlyDaemon', 'Sideloadly' -ErrorAction SilentlyContinue).Count -gt 0
}
catch {
    $daemonDetected = $false
}
if (-not $daemonDetected) {
    foreach ($runKey in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')) {
        try {
            $runValues = (Get-ItemProperty -LiteralPath $runKey -ErrorAction Stop).PSObject.Properties
            if (@($runValues | Where-Object { $_.Name -match '(?i)Sideloadly' }).Count -gt 0) {
                $daemonDetected = $true
                break
            }
        }
        catch {
            # Startup registration is optional and is never modified here.
        }
    }
}
if ($daemonDetected) {
    Add-Check -Code 'sideloadly.refresh' -Name 'Automatic refresh' -Status 'Pass' -Message 'A Sideloadly process or startup registration was detected.'
}
else {
    Add-Check -Code 'sideloadly.refresh' -Name 'Automatic refresh' -Status 'Warn' -Message 'Sideloadly automatic refresh was not detected; enable it manually after the first installation if desired.'
}

Add-Check -Code 'manual.apple-account' -Name 'Apple Account and 2FA' -Status 'Manual' -Message 'Complete Apple Account sign-in, two-factor authentication, and any developer agreement only in the official Sideloadly or Apple interface.'
Add-Check -Code 'manual.ipad-trust' -Name 'iPad trust' -Status 'Manual' -Message 'On the iPad, confirm USB trust, enable Developer Mode if requested, and trust the developer profile when iPadOS asks.'

$overallStatus = 'Pass'
if (@($checks | Where-Object { $_.Status -eq 'Block' }).Count -gt 0) {
    $overallStatus = 'Block'
}
elseif (@($checks | Where-Object { $_.Status -eq 'Warn' }).Count -gt 0) {
    $overallStatus = 'Warn'
}
elseif (@($checks | Where-Object { $_.Status -eq 'Manual' }).Count -gt 0) {
    $overallStatus = 'Manual'
}

$result = [pscustomobject]@{
    SchemaVersion = 1
    OverallStatus = $overallStatus
    Checks = $checks.ToArray()
}

if ($Json) {
    $result | ConvertTo-Json -Depth 5 -Compress
}
else {
    foreach ($check in $checks) {
        '[{0}] {1}: {2}' -f $check.Status, $check.Name, $check.Message
    }
    ''
    'Overall: {0}' -f $overallStatus
}
