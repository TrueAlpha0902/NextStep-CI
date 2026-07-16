[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Prepare,
    [switch]$Open,
    [switch]$Json,
    [string]$Repository,
    [string]$Commit,
    [string]$MirrorCommit,
    [long]$RunId,
    [switch]$AllowDirty,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$selectedActions = @(@($Check, $Prepare, $Open) | Where-Object { $_ })
if ($selectedActions.Count -gt 1) {
    throw 'Choose only one action: -Check, -Prepare, or -Open.'
}
if ($selectedActions.Count -eq 0) {
    $Check = $true
}
if ($Json -and -not $Check) {
    throw '-Json is supported only with -Check.'
}

if ($Check) {
    $parameters = @{}
    if ($Json) {
        $parameters.Json = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($Repository)) {
        $parameters.Repository = $Repository
    }
    & (Join-Path $PSScriptRoot 'Test-IPadInstallPrerequisites.ps1') @parameters
    return
}

$parameters = @{}
if (-not [string]::IsNullOrWhiteSpace($Repository)) {
    $parameters.Repository = $Repository
}
if (-not [string]::IsNullOrWhiteSpace($Commit)) {
    $parameters.Commit = $Commit
}
if (-not [string]::IsNullOrWhiteSpace($MirrorCommit)) {
    $parameters.MirrorCommit = $MirrorCommit
}
if ($RunId -gt 0) {
    $parameters.RunId = $RunId
}
if ($AllowDirty) {
    $parameters.AllowDirty = $true
}
if ($DryRun) {
    $parameters.DryRun = $true
}

if ($Prepare) {
    & (Join-Path $PSScriptRoot 'Get-VerifiedUnsignedIPA.ps1') @parameters
    return
}

& (Join-Path $PSScriptRoot 'Open-IPadInstaller.ps1') @parameters
