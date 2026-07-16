[CmdletBinding()]
param(
    [string]$Repository,
    [string]$Commit,
    [string]$MirrorCommit,
    [long]$RunId,
    [switch]$AllowDirty,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$checkScript = Join-Path $PSScriptRoot 'Test-IPadInstallPrerequisites.ps1'
$downloadScript = Join-Path $PSScriptRoot 'Get-VerifiedUnsignedIPA.ps1'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.local\ipad-install')).TrimEnd('\')

function Get-TrustedExplorerPath {
    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        throw 'The Windows system directory could not be determined.'
    }

    $systemRoot = [System.IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\')
    $candidate = Join-Path $systemRoot 'explorer.exe'
    $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).ProviderPath
    if (-not [string]::Equals(
            [System.IO.Path]::GetDirectoryName($resolved),
            $systemRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Windows Explorer resolved outside the Windows system directory.'
    }

    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Windows Explorer must not be a reparse point.'
    }
    $signature = Get-AuthenticodeSignature -FilePath $resolved -ErrorAction Stop
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw 'The Windows Explorer signature could not be validated.'
    }
    return $resolved
}

function Get-EnvironmentValueCaseInsensitive {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$SourceEnvironment,
        [Parameter(Mandatory = $true)][string]$Name
    )

    foreach ($key in @($SourceEnvironment.Keys)) {
        if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$SourceEnvironment[$key]
        }
    }
    return $null
}

function ConvertTo-ExplorerEnvironmentPath {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    if ($Value.IndexOf([char]0) -ge 0) {
        throw ('The {0} environment path contains an invalid null character.' -f $Name)
    }
    if (-not [System.IO.Path]::IsPathRooted($Value)) {
        throw ('The {0} environment path must be absolute.' -f $Name)
    }
    try {
        return [System.IO.Path]::GetFullPath($Value)
    }
    catch {
        throw ('The {0} environment path is invalid.' -f $Name)
    }
}

function Get-ExplorerChildEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$SystemRootPath,
        [System.Collections.IDictionary]$SourceEnvironment = [System.Environment]::GetEnvironmentVariables(
            [System.EnvironmentVariableTarget]::Process
        )
    )

    # This is an allowlist, not a denylist. Developer credentials and service
    # configuration are never copied, regardless of how their names are spelled.
    $systemRoot = ConvertTo-ExplorerEnvironmentPath -Name 'SystemRoot' -Value $SystemRootPath
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        throw 'The Windows system directory could not be determined.'
    }
    $systemRoot = $systemRoot.TrimEnd('\')
    $systemDriveRoot = [System.IO.Path]::GetPathRoot($systemRoot)
    if ([string]::IsNullOrWhiteSpace($systemDriveRoot)) {
        throw 'The Windows system drive could not be determined.'
    }

    $childEnvironment = [ordered]@{
        SystemRoot = $systemRoot
        WINDIR = $systemRoot
        SystemDrive = $systemDriveRoot.TrimEnd('\')
        PATH = [string]::Join(';', @((Join-Path $systemRoot 'System32'), $systemRoot))
    }

    # Only shell/user known-folder paths that Explorer may need are eligible.
    # Values must be literal absolute paths; variable expansion is intentionally
    # not performed because it could expand a credential-bearing parent variable.
    foreach ($name in @(
            'TEMP',
            'TMP',
            'USERPROFILE',
            'LOCALAPPDATA',
            'APPDATA',
            'ProgramData',
            'PUBLIC'
        )) {
        $sourceValue = Get-EnvironmentValueCaseInsensitive -SourceEnvironment $SourceEnvironment -Name $name
        $pathValue = ConvertTo-ExplorerEnvironmentPath -Name $name -Value $sourceValue
        if (-not [string]::IsNullOrWhiteSpace($pathValue)) {
            $childEnvironment[$name] = $pathValue
        }
    }

    if ($childEnvironment.Contains('ProgramData')) {
        $childEnvironment['ALLUSERSPROFILE'] = [string]$childEnvironment['ProgramData']
    }

    if ($childEnvironment.Contains('USERPROFILE')) {
        $profilePath = [string]$childEnvironment['USERPROFILE']
        $profileRoot = [System.IO.Path]::GetPathRoot($profilePath)
        if (-not [string]::IsNullOrWhiteSpace($profileRoot) -and $profileRoot -match '^[A-Za-z]:\\$') {
            $childEnvironment['HOMEDRIVE'] = $profileRoot.TrimEnd('\')
            $relativeProfile = $profilePath.Substring($profileRoot.Length).TrimStart('\')
            $childEnvironment['HOMEPATH'] = if ([string]::IsNullOrWhiteSpace($relativeProfile)) {
                '\'
            }
            else {
                '\' + $relativeProfile
            }
        }
    }

    return ,$childEnvironment
}

function New-ExplorerSelectionStartInfo {
    param(
        [Parameter(Mandatory = $true)][string]$ExplorerPath,
        [Parameter(Mandatory = $true)][string]$IpaPath,
        [System.Collections.IDictionary]$SourceEnvironment = [System.Environment]::GetEnvironmentVariables(
            [System.EnvironmentVariableTarget]::Process
        )
    )

    foreach ($pathInput in @(
            [pscustomobject]@{ Name = 'ExplorerPath'; Value = $ExplorerPath },
            [pscustomobject]@{ Name = 'IpaPath'; Value = $IpaPath }
        )) {
        if ([string]::IsNullOrWhiteSpace([string]$pathInput.Value) -or
            ([string]$pathInput.Value).IndexOf([char]0) -ge 0 -or
            ([string]$pathInput.Value).IndexOf('"') -ge 0 -or
            ([string]$pathInput.Value).IndexOf("`r") -ge 0 -or
            ([string]$pathInput.Value).IndexOf("`n") -ge 0) {
            throw ('{0} contains characters that cannot be passed safely to Explorer.' -f [string]$pathInput.Name)
        }
        if (-not [System.IO.Path]::IsPathRooted([string]$pathInput.Value)) {
            throw ('{0} must be an absolute path.' -f [string]$pathInput.Name)
        }
    }

    try {
        $fullExplorerPath = [System.IO.Path]::GetFullPath($ExplorerPath)
        $fullIpaPath = [System.IO.Path]::GetFullPath($IpaPath)
    }
    catch {
        throw 'ExplorerPath or IpaPath is invalid.'
    }

    $childEnvironment = Get-ExplorerChildEnvironment `
        -SystemRootPath ([System.IO.Path]::GetDirectoryName($fullExplorerPath)) `
        -SourceEnvironment $SourceEnvironment

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $fullExplorerPath
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = '/select,"{0}"' -f $fullIpaPath

    # ProcessStartInfo begins with a copy of the parent environment. Clear it
    # before adding the explicit allowlist so no developer-shell secret survives.
    $startInfo.EnvironmentVariables.Clear()
    foreach ($name in @($childEnvironment.Keys | Sort-Object)) {
        $startInfo.EnvironmentVariables.Add([string]$name, [string]$childEnvironment[$name])
    }

    return $startInfo
}

function Open-IpaSelection {
    param(
        [Parameter(Mandatory = $true)][string]$ExplorerPath,
        [Parameter(Mandatory = $true)][string]$IpaPath
    )

    $startInfo = New-ExplorerSelectionStartInfo -ExplorerPath $ExplorerPath -IpaPath $IpaPath
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw 'Windows Explorer could not be started.'
    }
    $process.Dispose()
}

$checkParameters = @{ Json = $true }
if (-not [string]::IsNullOrWhiteSpace($Repository)) {
    $checkParameters.Repository = $Repository
}
$prerequisiteJson = ((& $checkScript @checkParameters) | Out-String).Trim()
try {
    $prerequisites = $prerequisiteJson | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw 'The prerequisite report could not be read safely.'
}
$blockingChecks = @($prerequisites.Checks | Where-Object { [string]$_.Status -eq 'Block' })
if ($blockingChecks.Count -gt 0) {
    throw ('Prerequisite checks found {0} blocking item(s). Run scripts\install-ipad.ps1 -Check to review them.' -f $blockingChecks.Count)
}

$downloadParameters = @{}
if (-not [string]::IsNullOrWhiteSpace($Repository)) {
    $downloadParameters.Repository = $Repository
}
if (-not [string]::IsNullOrWhiteSpace($Commit)) {
    $downloadParameters.Commit = $Commit
}
if (-not [string]::IsNullOrWhiteSpace($MirrorCommit)) {
    $downloadParameters.MirrorCommit = $MirrorCommit
}
if ($RunId -gt 0) {
    $downloadParameters.RunId = $RunId
}
if ($AllowDirty) {
    $downloadParameters.AllowDirty = $true
}
if ($DryRun) {
    $downloadParameters.DryRun = $true
}
$download = & $downloadScript @downloadParameters

$manualSteps = @(
    'Connect the intended iPad with a data-capable USB cable, unlock it, and accept Trust prompts.',
    'Open Sideloadly from the Start menu or another shortcut you installed from its official download.',
    'Drag the IPA selected in Explorer into Sideloadly, select the intended iPad, and complete Apple Account or 2FA prompts only in its UI.',
    'Keep the same Apple Account and bundle identifier when installing over the existing NextStep app.',
    'After the first install, enable Sideloadly automatic refresh if you want USB or Wi-Fi refresh reminders.'
)

if ($DryRun) {
    [pscustomobject]@{
        Status = 'Planned'
        Artifact = $download
        Action = 'Select the verified IPA in Windows Explorer without launching or delegating to a third-party file association.'
        ManualSteps = $manualSteps
    }
    return
}

$ipaPath = [string]$download.IPAPath
if ([string]::IsNullOrWhiteSpace($ipaPath) -or -not (Test-Path -LiteralPath $ipaPath -PathType Leaf)) {
    throw 'The verified IPA is not available at the expected local path.'
}
$ipaPath = [System.IO.Path]::GetFullPath($ipaPath)
$installPrefix = $installRoot + [System.IO.Path]::DirectorySeparatorChar
if (-not $ipaPath.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The verified IPA resolved outside the local install directory.'
}
$ipa = Get-Item -LiteralPath $ipaPath -Force -ErrorAction Stop
if (($ipa.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The verified IPA must not be a reparse point.'
}

$explorerPath = Get-TrustedExplorerPath
Open-IpaSelection -ExplorerPath $explorerPath -IpaPath $ipaPath

[pscustomobject]@{
    Status = 'Opened'
    Artifact = $download
    Action = 'Selected the verified IPA in signed Windows Explorer. Open Sideloadly from your trusted shortcut and import this file manually.'
    ManualSteps = $manualSteps
}
