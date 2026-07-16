[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Open-IPadInstaller.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if (@($parseErrors).Count -gt 0) {
    throw ('Open-IPadInstaller.ps1 has parser errors: {0}' -f (($parseErrors | ForEach-Object Message) -join '; '))
}

# Load only the pure/testable helpers. Dot-sourcing the full installer would run
# prerequisite and artifact-download logic, which this offline test must not do.
$helperNames = @(
    'Get-EnvironmentValueCaseInsensitive',
    'ConvertTo-ExplorerEnvironmentPath',
    'Get-ExplorerChildEnvironment',
    'New-ExplorerSelectionStartInfo'
)
foreach ($helperName in $helperNames) {
    $functionNodes = @($ast.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            },
            $true
        ) | Where-Object { [string]::Equals($_.Name, $helperName, [System.StringComparison]::Ordinal) })
    if ($functionNodes.Count -ne 1) {
        throw ('Expected exactly one {0} helper in Open-IPadInstaller.ps1.' -f $helperName)
    }
    . ([scriptblock]::Create($functionNodes[0].Extent.Text))
}

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-ProcessEnvironmentSnapshot {
    $snapshot = @{}
    $environment = [System.Environment]::GetEnvironmentVariables(
        [System.EnvironmentVariableTarget]::Process
    )
    foreach ($key in @($environment.Keys)) {
        $snapshot[[string]$key] = [string]$environment[$key]
    }
    return ,$snapshot
}

function Assert-SnapshotsEqual {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Expected,
        [Parameter(Mandatory = $true)][hashtable]$Actual
    )

    Assert-Condition -Condition ($Expected.Count -eq $Actual.Count) `
        -Message 'The installer helper changed the number of parent environment variables.'
    foreach ($name in @($Expected.Keys)) {
        Assert-Condition -Condition ($Actual.ContainsKey($name)) `
            -Message ('The installer helper removed parent environment variable {0}.' -f $name)
        Assert-Condition `
            -Condition ([string]::Equals(
                    [string]$Expected[$name],
                    [string]$Actual[$name],
                    [System.StringComparison]::Ordinal
                )) `
            -Message ('The installer helper changed parent environment variable {0}.' -f $name)
    }
}

$sensitiveEnvironment = [ordered]@{
    GITHUB_PAT = 'offline-github-pat-sentinel'
    AWS_SESSION_TOKEN = 'offline-aws-session-token-sentinel'
    BUILD_CREDENTIALS = 'offline-credentials-sentinel'
    SERVICE_AUTH = 'offline-auth-sentinel'
    DATABASE_CONNECTION_STRING = 'offline-connection-string-sentinel'
    SESSION_COOKIE = 'offline-cookie-sentinel'
    SSH_AUTH_SOCK = 'offline-ssh-agent-sentinel'
    APPLE_ID_PASSWORD = 'offline-apple-password-sentinel'
}
$originalEnvironment = @{}
foreach ($name in @($sensitiveEnvironment.Keys)) {
    $originalEnvironment[$name] = [System.Environment]::GetEnvironmentVariable(
        $name,
        [System.EnvironmentVariableTarget]::Process
    )
}

$testCount = 0
try {
    foreach ($name in @($sensitiveEnvironment.Keys)) {
        [System.Environment]::SetEnvironmentVariable(
            $name,
            [string]$sensitiveEnvironment[$name],
            [System.EnvironmentVariableTarget]::Process
        )
    }

    $parentBefore = Get-ProcessEnvironmentSnapshot
    $sourceEnvironment = [System.Environment]::GetEnvironmentVariables(
        [System.EnvironmentVariableTarget]::Process
    )
    $sourceEnvironment['PATH'] = 'C:\sensitive-parent-path\GITHUB_PAT'

    $systemRoot = [System.IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\')
    $explorerPath = Join-Path $systemRoot 'explorer.exe'
    $ipaPath = Join-Path ([System.IO.Path]::GetTempPath()) 'NextStep verified, offline sample.ipa'

    $childEnvironment = Get-ExplorerChildEnvironment `
        -SystemRootPath $systemRoot `
        -SourceEnvironment $sourceEnvironment
    $allowedNames = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(
            'SystemRoot',
            'WINDIR',
            'SystemDrive',
            'PATH',
            'TEMP',
            'TMP',
            'USERPROFILE',
            'HOMEDRIVE',
            'HOMEPATH',
            'LOCALAPPDATA',
            'APPDATA',
            'ProgramData',
            'ALLUSERSPROFILE',
            'PUBLIC'
        )) {
        [void]$allowedNames.Add($name)
    }
    foreach ($name in @($childEnvironment.Keys)) {
        Assert-Condition -Condition ($allowedNames.Contains([string]$name)) `
            -Message ('Unexpected child environment variable was allowlisted: {0}' -f $name)
    }
    $testCount += 1

    foreach ($name in @($sensitiveEnvironment.Keys)) {
        Assert-Condition -Condition (-not $childEnvironment.Contains($name)) `
            -Message ('Sensitive environment variable leaked to Explorer: {0}' -f $name)
    }
    $testCount += 1

    $childValues = (@($childEnvironment.Values) | ForEach-Object { [string]$_ }) -join "`n"
    foreach ($sentinel in @($sensitiveEnvironment.Values)) {
        Assert-Condition -Condition ($childValues.IndexOf([string]$sentinel, [System.StringComparison]::Ordinal) -lt 0) `
            -Message 'A sensitive parent value leaked into an allowlisted Explorer environment value.'
    }
    $testCount += 1

    $expectedPath = [string]::Join(';', @((Join-Path $systemRoot 'System32'), $systemRoot))
    Assert-Condition `
        -Condition ([string]::Equals(
                [string]$childEnvironment['PATH'],
                $expectedPath,
                [System.StringComparison]::OrdinalIgnoreCase
            )) `
        -Message 'Explorer PATH was not rebuilt from the minimal Windows system directories.'
    $testCount += 1

    $startInfo = New-ExplorerSelectionStartInfo `
        -ExplorerPath $explorerPath `
        -IpaPath $ipaPath
    Assert-Condition -Condition (-not $startInfo.UseShellExecute) `
        -Message 'Explorer must be started without shell execution.'
    Assert-Condition `
        -Condition ([string]::Equals(
                $startInfo.FileName,
                [System.IO.Path]::GetFullPath($explorerPath),
                [System.StringComparison]::OrdinalIgnoreCase
            )) `
        -Message 'ProcessStartInfo did not retain the explicit Explorer executable path.'
    Assert-Condition `
        -Condition ([string]::Equals(
                $startInfo.Arguments,
                ('/select,"{0}"' -f [System.IO.Path]::GetFullPath($ipaPath)),
                [System.StringComparison]::Ordinal
            )) `
        -Message 'Explorer /select arguments were not encoded as expected.'
    $testCount += 1

    $startInfoNames = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([System.StringComparer]::OrdinalIgnoreCase)
    Assert-Condition -Condition ($startInfo.EnvironmentVariables.Count -eq $childEnvironment.Count) `
        -Message 'ProcessStartInfo did not contain exactly the explicit child environment allowlist.'
    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
        [void]$startInfoNames.Add([string]$name)
        Assert-Condition -Condition ($allowedNames.Contains([string]$name)) `
            -Message ('ProcessStartInfo retained a non-allowlisted variable: {0}' -f $name)
    }
    foreach ($name in @($childEnvironment.Keys)) {
        Assert-Condition -Condition ($startInfo.EnvironmentVariables.ContainsKey([string]$name)) `
            -Message ('ProcessStartInfo omitted allowlisted variable {0}.' -f $name)
        Assert-Condition `
            -Condition ([string]::Equals(
                    [string]$startInfo.EnvironmentVariables[[string]$name],
                    [string]$childEnvironment[$name],
                    [System.StringComparison]::Ordinal
                )) `
            -Message ('ProcessStartInfo changed allowlisted variable {0}.' -f $name)
    }
    foreach ($name in @($sensitiveEnvironment.Keys)) {
        Assert-Condition -Condition (-not $startInfoNames.Contains([string]$name)) `
            -Message ('ProcessStartInfo retained sensitive variable {0}.' -f $name)
    }
    $testCount += 1

    $parentAfter = Get-ProcessEnvironmentSnapshot
    Assert-SnapshotsEqual -Expected $parentBefore -Actual $parentAfter
    $testCount += 1

    $rejectedUnsafeArgument = $false
    try {
        $null = New-ExplorerSelectionStartInfo `
            -ExplorerPath $explorerPath `
            -IpaPath ($ipaPath + '" /e,C:\') `
            -SourceEnvironment $sourceEnvironment
    }
    catch {
        $rejectedUnsafeArgument = $true
    }
    Assert-Condition -Condition $rejectedUnsafeArgument `
        -Message 'Explorer argument construction accepted an unsafe quote character.'
    $testCount += 1
}
finally {
    foreach ($name in @($sensitiveEnvironment.Keys)) {
        [System.Environment]::SetEnvironmentVariable(
            $name,
            $originalEnvironment[$name],
            [System.EnvironmentVariableTarget]::Process
        )
    }
}

[pscustomobject]@{
    Status = 'Passed'
    TestCount = $testCount
    Script = $scriptPath
}
