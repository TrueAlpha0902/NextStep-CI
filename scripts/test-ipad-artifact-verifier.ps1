[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$path = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Get-VerifiedUnsignedIPA.ps1')).Path
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Verifier AST parse failed.' }
foreach ($definition in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)) {
    Invoke-Expression $definition.Extent.Text
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) ('NextStepFixture-' + [guid]::NewGuid().ToString('N'))))
$tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture root.' }
[void][System.IO.Directory]::CreateDirectory($root)

$script:ArtifactName = 'Notes-unsigned-ipa'
$script:WorkflowPath = '.github/workflows/ios-ci.yml'
$script:IpaFile = 'Notes-unsigned.ipa'
$script:ManifestFile = 'install-manifest.json'
$script:RawArtifactFile = 'artifact.zip'
$script:AppBundleDirectory = 'Notes.app'
$script:BundleIdentifier = 'com.speci.localnotes'
$script:BundleDisplayName = 'NextStep'
$script:ManifestFormat = 'nextstep-unsigned-ipa'
$script:CIMirrorConfigPath = 'Config/CIMirror.json'
$script:ExpectedSourceRepository = 'TrueAlpha0902/Notes'
$script:ExpectedMirrorRepository = 'TrueAlpha0902/NextStep-CI'
$script:ExpectedMirrorBranch = 'main'
$script:MaximumOuterBytes = [long](2GB)
$script:MaximumIpaBytes = [long](2GB)
$script:MaximumInnerBytes = [long](8GB)
$script:MaximumManifestBytes = [long](64KB)
$script:MaximumInfoPlistBytes = [long](1MB)
$script:MaximumInnerEntries = 50000
$script:DownloadTotalDeadlineMilliseconds = 30 * 60 * 1000
$script:DownloadIdleDeadlineMilliseconds = 60 * 1000
$script:ProcessTerminationGraceMilliseconds = 5000
$script:RepoRoot = $root
$script:InstallRoot = Join-Path $root 'install'
$script:Passed = 0

function Rejects {
    param([string]$Name, [scriptblock]$Action)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Fixture '$Name' was not rejected." }
    $script:Passed++
}

function Write-Zip {
    param([string]$Path, [object[]]$Definitions)
    $file = $null
    $zip = $null
    try {
        $file = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $zip = New-Object System.IO.Compression.ZipArchive($file, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        foreach ($definition in $Definitions) {
            $entry = $zip.CreateEntry([string]$definition.Name, [System.IO.Compression.CompressionLevel]::Optimal)
            $external = $definition.PSObject.Properties['External']
            if ($null -ne $external) { $entry.ExternalAttributes = [int]$external.Value }
            $property = $definition.PSObject.Properties['Bytes']
            if ($null -eq $property -or $null -eq $property.Value) { continue }
            [byte[]]$bytes = $property.Value
            $stream = $entry.Open()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
    }
    finally {
        if ($null -ne $zip) { $zip.Dispose() }
        if ($null -ne $file) { $file.Dispose() }
    }
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$plist = $utf8.GetBytes(@'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.speci.localnotes</string>
<key>CFBundleDisplayName</key><string>NextStep</string>
</dict></plist>
'@)
$random = New-Object byte[] 8192
(New-Object System.Random(42)).NextBytes($random)
$sha = 'a' * 40

function Make-Ipa {
    param([string]$Path, [object[]]$Extra = @())
    $entries = @(
        [pscustomobject]@{ Name='Payload/'; Bytes=$null },
        [pscustomobject]@{ Name='Payload/Notes.app/'; Bytes=$null },
        [pscustomobject]@{ Name='Payload/Notes.app/Info.plist'; Bytes=$plist },
        [pscustomobject]@{ Name='Payload/Notes.app/random.bin'; Bytes=$random }
    ) + @($Extra)
    Write-Zip -Path $Path -Definitions $entries
}

function Manifest {
    param([string]$IpaHash, [long]$IpaSize, [string]$Run='456', [long]$Schema=1)
    $lines = @(
        '{',
        '  "appBundleDirectory": "Notes.app",',
        '  "artifactName": "Notes-unsigned-ipa",',
        '  "bundleDisplayName": "NextStep",',
        '  "bundleIdentifier": "com.speci.localnotes",',
        ('  "commitSha": "' + $sha + '",'),
        '  "format": "nextstep-unsigned-ipa",',
        '  "ipaFile": "Notes-unsigned.ipa",',
        ('  "ipaSha256": "' + $IpaHash + '",'),
        ('  "ipaSizeBytes": ' + $IpaSize + ','),
        '  "repository": "owner/repository",',
        '  "repositoryId": "123",',
        '  "runAttempt": 1,',
        ('  "runId": "' + $Run + '",'),
        ('  "schemaVersion": ' + $Schema + ','),
        '  "workflowPath": ".github/workflows/ios-ci.yml"',
        '}'
    )
    $lf = [string][char]10
    return (($lines -join $lf) + $lf)
}

function Make-Artifact {
    param([string]$Name, [string]$Run='456', [long]$Schema=1, [string]$Override)
    $dir = Join-Path $root ($Name + '-source')
    [void][System.IO.Directory]::CreateDirectory($dir)
    $ipa = Join-Path $dir 'source.ipa'
    Make-Ipa -Path $ipa
    $text = if ($PSBoundParameters.ContainsKey('Override')) { $Override } else { Manifest -IpaHash (Get-FileSha256 $ipa) -IpaSize (Get-Item $ipa).Length -Run $Run -Schema $Schema }
    $outer = Join-Path $dir 'outer.zip'
    Write-Zip -Path $outer -Definitions @(
        [pscustomobject]@{ Name='Notes-unsigned.ipa'; Bytes=[System.IO.File]::ReadAllBytes($ipa) },
        [pscustomobject]@{ Name='install-manifest.json'; Bytes=$utf8.GetBytes($text) }
    )
    return [pscustomobject]@{ Ipa=$ipa; Manifest=$text; Outer=$outer }
}

function Context {
    param([string]$Outer)
    return [pscustomobject]@{
        Repository='owner/repository'; RepositoryId=123L; CommitSha=$sha
        RunId=456L; RunAttempt=1L; RunUrl='https://example.invalid/456'
        ArtifactId=789L; ArtifactSize=(Get-Item $Outer).Length
        ArtifactDigestHex=Get-FileSha256 $Outer
    }
}

function Expand-Fixture {
    param([string]$Name, [string]$Outer)
    $dir = Join-Path $root $Name
    [void][System.IO.Directory]::CreateDirectory($dir)
    Copy-Item $Outer (Join-Path $dir 'artifact.zip')
    Read-OuterArtifactArchive -ArtifactZipPath (Join-Path $dir 'artifact.zip') -ExtractDirectory $dir | Out-Null
    return $dir
}

try {
    $savedHost = [Environment]::GetEnvironmentVariable('GH_HOST', 'Process')
    $savedEnterpriseToken = [Environment]::GetEnvironmentVariable('GH_ENTERPRISE_TOKEN', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('GH_HOST', 'enterprise.example.invalid', 'Process')
        [Environment]::SetEnvironmentVariable('GH_ENTERPRISE_TOKEN', 'fixture-must-not-route', 'Process')
        $metadataArguments = @(New-GithubComApiArguments -Arguments @(
            'api', '--method', 'GET', 'repos/owner/repository'
        ))
        $downloadArguments = @(New-GithubComApiArguments -Arguments @(
            'api', '--method', 'GET',
            '-H', 'Accept:application/vnd.github+json',
            'repos/owner/repository/actions/artifacts/789/zip'
        ))
    }
    finally {
        [Environment]::SetEnvironmentVariable('GH_HOST', $savedHost, 'Process')
        [Environment]::SetEnvironmentVariable('GH_ENTERPRISE_TOKEN', $savedEnterpriseToken, 'Process')
    }
    foreach ($arguments in @($metadataArguments, $downloadArguments)) {
        if ($arguments.Count -lt 4 -or
            $arguments[0] -cne 'api' -or
            $arguments[1] -cne '--hostname' -or
            $arguments[2] -cne 'github.com' -or
            @($arguments | Where-Object { $_ -ceq '--hostname' }).Count -ne 1 -or
            @($arguments | Where-Object { $_ -ceq 'enterprise.example.invalid' }).Count -ne 0) {
            throw 'GitHub.com host pinning was not preserved in the exact process argument fixture.'
        }
    }
    $script:Passed++
    Rejects 'GitHub host override' { New-GithubComApiArguments -Arguments @('api', '--hostname', 'enterprise.example.invalid', 'repos/owner/repository') }
    Rejects 'GitHub argument injection' { New-GithubComApiArguments -Arguments @('api', 'repos/owner/repository;whoami') }

    $mirrorConfigurationText = @'
{
  "format": "nextstep-public-ci-mirror",
  "version": 1,
  "sourceRepository": "TrueAlpha0902/Notes",
  "mirrorRepository": "TrueAlpha0902/NextStep-CI",
  "mirrorBranch": "main",
  "historyPolicy": "single-root-snapshot",
  "licensePolicy": "all-rights-reserved"
}
'@
    $mirrorConfiguration = ConvertFrom-StrictCIMirrorConfiguration -Text $mirrorConfigurationText
    if ([string]$mirrorConfiguration.sourceRepository -cne 'TrueAlpha0902/Notes' -or
        [string]$mirrorConfiguration.mirrorRepository -cne 'TrueAlpha0902/NextStep-CI' -or
        (Get-RequestedRepositorySlug -ConfiguredRepository ([string]$mirrorConfiguration.mirrorRepository)) -cne 'TrueAlpha0902/NextStep-CI' -or
        (Get-RequestedRepositorySlug -RequestedRepository 'TrueAlpha0902/NextStep-CI' -ConfiguredRepository ([string]$mirrorConfiguration.mirrorRepository)) -cne 'TrueAlpha0902/NextStep-CI') {
        throw 'The configured source-to-mirror mapping was not preserved.'
    }
    $script:Passed++
    Rejects 'mirror repository override' {
        Get-RequestedRepositorySlug -RequestedRepository 'attacker/NextStep-CI' -ConfiguredRepository 'TrueAlpha0902/NextStep-CI'
    }
    Rejects 'mirror config redirect' {
        ConvertFrom-StrictCIMirrorConfiguration -Text $mirrorConfigurationText.Replace(
            '"mirrorRepository": "TrueAlpha0902/NextStep-CI"',
            '"mirrorRepository": "attacker/NextStep-CI"'
        )
    }
    Rejects 'mirror config duplicate key' {
        ConvertFrom-StrictCIMirrorConfiguration -Text $mirrorConfigurationText.Replace(
            '  "licensePolicy": "all-rights-reserved"',
            "  `"mirrorBranch`": `"main`",`n  `"licensePolicy`": `"all-rights-reserved`""
        )
    }

    $mirrorSha = 'b' * 40
    $sourceTreeSha = 'c' * 40
    function New-MirrorReferenceFixture {
        param([string]$Ref = 'refs/heads/main', [string]$Sha = $mirrorSha)
        return [pscustomobject]@{
            ref = $Ref
            object = [pscustomobject]@{ type = 'commit'; sha = $Sha }
        }
    }
    function New-MirrorCommitFixture {
        param(
            [string]$Sha = $mirrorSha,
            [string]$TreeSha = $sourceTreeSha,
            [object[]]$Parents = @(),
            [string]$Message = ("NextStep public CI snapshot`n`nAuthoritative source tree: {0}`nThis root commit intentionally contains no private repository history." -f $sourceTreeSha)
        )
        return [pscustomobject]@{
            sha = $Sha
            tree = [pscustomobject]@{ sha = $TreeSha }
            parents = $Parents
            message = $Message
        }
    }
    Assert-MirrorSnapshotMetadata `
        -Reference (New-MirrorReferenceFixture) `
        -CommitMetadata (New-MirrorCommitFixture) `
        -ExpectedBranch 'main' `
        -ExpectedSourceTree $sourceTreeSha `
        -ExpectedMirrorCommit $mirrorSha | Out-Null
    Assert-SourceRepositoryMetadata `
        -Metadata ([pscustomobject]@{ full_name='TrueAlpha0902/Notes'; private=$true; fork=$false }) `
        -ExpectedRepository 'TrueAlpha0902/Notes'
    Assert-MirrorRepositoryMetadata `
        -Metadata ([pscustomobject]@{ full_name='TrueAlpha0902/NextStep-CI'; private=$false; fork=$false; visibility='public'; default_branch='main' }) `
        -ExpectedRepository 'TrueAlpha0902/NextStep-CI' `
        -ExpectedBranch 'main'
    $script:Passed++
    Rejects 'mirror snapshot has parent' {
        Assert-MirrorSnapshotMetadata -Reference (New-MirrorReferenceFixture) -CommitMetadata (New-MirrorCommitFixture -Parents @([pscustomobject]@{sha=('d' * 40)})) -ExpectedBranch 'main' -ExpectedSourceTree $sourceTreeSha
    }
    Rejects 'mirror snapshot tree mismatch' {
        Assert-MirrorSnapshotMetadata -Reference (New-MirrorReferenceFixture) -CommitMetadata (New-MirrorCommitFixture -TreeSha ('d' * 40)) -ExpectedBranch 'main' -ExpectedSourceTree $sourceTreeSha
    }
    Rejects 'mirror snapshot branch mismatch' {
        Assert-MirrorSnapshotMetadata -Reference (New-MirrorReferenceFixture -Ref 'refs/heads/not-main') -CommitMetadata (New-MirrorCommitFixture) -ExpectedBranch 'main' -ExpectedSourceTree $sourceTreeSha
    }
    Rejects 'mirror snapshot explicit commit mismatch' {
        Assert-MirrorSnapshotMetadata -Reference (New-MirrorReferenceFixture) -CommitMetadata (New-MirrorCommitFixture) -ExpectedBranch 'main' -ExpectedSourceTree $sourceTreeSha -ExpectedMirrorCommit ('d' * 40)
    }
    Rejects 'mirror snapshot unrecognized message' {
        Assert-MirrorSnapshotMetadata -Reference (New-MirrorReferenceFixture) -CommitMetadata (New-MirrorCommitFixture -Message 'ordinary commit') -ExpectedBranch 'main' -ExpectedSourceTree $sourceTreeSha
    }
    Rejects 'private mirror repository' {
        Assert-MirrorRepositoryMetadata -Metadata ([pscustomobject]@{ full_name='TrueAlpha0902/NextStep-CI'; private=$true; fork=$false; visibility='private'; default_branch='main' }) -ExpectedRepository 'TrueAlpha0902/NextStep-CI' -ExpectedBranch 'main'
    }

    $mirrorRun = [pscustomobject]@{
        id=456L; workflow_id=321L; run_attempt=1L
        path='.github/workflows/ios-ci.yml'; head_sha=$mirrorSha; head_branch='main'; event='push'
        status='completed'; conclusion='success'
        repository=[pscustomobject]@{id=123L;full_name='TrueAlpha0902/NextStep-CI'}
        html_url='https://example.invalid/run/456'
    }
    Assert-RunMetadata `
        -Run $mirrorRun `
        -ExpectedRepository 'TrueAlpha0902/NextStep-CI' `
        -ExpectedRepositoryId 123L `
        -ExpectedWorkflowId 321L `
        -ExpectedCommit $mirrorSha `
        -ExpectedBranch 'main' | Out-Null
    $script:Passed++
    $wrongBranchRun = $mirrorRun.PSObject.Copy()
    $wrongBranchRun.head_branch = 'feature'
    Rejects 'workflow run wrong mirror branch' {
        Assert-RunMetadata -Run $wrongBranchRun -ExpectedRepository 'TrueAlpha0902/NextStep-CI' -ExpectedRepositoryId 123L -ExpectedWorkflowId 321L -ExpectedCommit $mirrorSha -ExpectedBranch 'main'
    }
    $pullRequestRun = $mirrorRun.PSObject.Copy()
    $pullRequestRun.event = 'pull_request'
    Rejects 'workflow run untrusted event' {
        Assert-RunMetadata -Run $pullRequestRun -ExpectedRepository 'TrueAlpha0902/NextStep-CI' -ExpectedRepositoryId 123L -ExpectedWorkflowId 321L -ExpectedCommit $mirrorSha -ExpectedBranch 'main'
    }

    $base = Make-Artifact -Name 'base'
    $context = Context $base.Outer
    $baseCacheKey = Get-InstallCacheKey -Context $context
    $runContext = $context.PSObject.Copy()
    $runContext.RunId = 457L
    $attemptContext = $context.PSObject.Copy()
    $attemptContext.RunAttempt = 2L
    $artifactContext = $context.PSObject.Copy()
    $artifactContext.ArtifactId = 790L
    $cacheKeys = @(
        $baseCacheKey,
        (Get-InstallCacheKey -Context $runContext),
        (Get-InstallCacheKey -Context $attemptContext),
        (Get-InstallCacheKey -Context $artifactContext)
    )
    if (@($cacheKeys | Select-Object -Unique).Count -ne 4 -or
        $baseCacheKey -cnotmatch '^[0-9a-f]{40}-run456-attempt1-artifact789$') {
        throw 'The cache key did not bind commit, run ID, run attempt, and artifact ID independently.'
    }
    $script:Passed++

    $valid = Expand-Fixture -Name 'valid' -Outer $base.Outer
    $verified = Test-VerifiedInstallDirectory -DirectoryPath $valid -Context $context
    if ($verified.IpaInfo.BundleDisplayName -cne 'NextStep') { throw 'Positive identity mismatch.' }
    $script:Passed++

    foreach ($leaf in @('Notes-unsigned.ipa', 'install-manifest.json', 'artifact.zip')) {
        $dir = Expand-Fixture -Name ('tamper-' + $leaf.Replace('.', '-')) -Outer $base.Outer
        $target = Join-Path $dir $leaf
        $stream = [System.IO.File]::Open($target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
        try {
            $byte = $stream.ReadByte()
            $stream.Position = 0
            $stream.WriteByte([byte]($byte -bxor 1))
        }
        finally { $stream.Dispose() }
        Rejects ('tamper ' + $leaf) { Test-VerifiedInstallDirectory -DirectoryPath $dir -Context $context }
    }

    foreach ($variation in @(
        [pscustomobject]@{ Name='wrong-run'; Run='999'; Schema=1 },
        [pscustomobject]@{ Name='future-schema'; Run='456'; Schema=2 }
    )) {
        $artifact = Make-Artifact -Name $variation.Name -Run $variation.Run -Schema $variation.Schema
        $dir = Expand-Fixture -Name ($variation.Name + '-expanded') -Outer $artifact.Outer
        $ctx = Context $artifact.Outer
        Rejects $variation.Name { Test-VerifiedInstallDirectory -DirectoryPath $dir -Context $ctx }
    }

    $duplicate = Manifest -IpaHash (Get-FileSha256 $base.Ipa) -IpaSize (Get-Item $base.Ipa).Length
    $lf = [string][char]10
    $duplicate = $duplicate.Replace('  "workflowPath": ".github/workflows/ios-ci.yml"', ('  "runId": "456",' + $lf + '  "workflowPath": ".github/workflows/ios-ci.yml"'))
    $artifact = Make-Artifact -Name 'duplicate' -Override $duplicate
    $dir = Expand-Fixture -Name 'duplicate-expanded' -Outer $artifact.Outer
    $ctx = Context $artifact.Outer
    Rejects 'duplicate manifest key' { Test-VerifiedInstallDirectory -DirectoryPath $dir -Context $ctx }

    $ipaBytes = [System.IO.File]::ReadAllBytes($base.Ipa)
    $manifestBytes = $utf8.GetBytes($base.Manifest)
    $badOuterEntries = @(
        @([pscustomobject]@{Name='Notes-unsigned.ipa';Bytes=$ipaBytes}),
        @([pscustomobject]@{Name='Notes-unsigned.ipa';Bytes=$ipaBytes},[pscustomobject]@{Name='nested/install-manifest.json';Bytes=$manifestBytes}),
        @([pscustomobject]@{Name='Notes-unsigned.ipa';Bytes=$ipaBytes},[pscustomobject]@{Name='../install-manifest.json';Bytes=$manifestBytes}),
        @([pscustomobject]@{Name='Notes-unsigned.ipa';Bytes=$ipaBytes},[pscustomobject]@{Name='CON.json';Bytes=$manifestBytes}),
        @([pscustomobject]@{Name='Notes-unsigned.ipa';Bytes=$ipaBytes},[pscustomobject]@{Name='install-manifest.json. ';Bytes=$manifestBytes}),
        @([pscustomobject]@{Name='Notes-unsigned.ipa';Bytes=$ipaBytes},[pscustomobject]@{Name='file.';Bytes=$manifestBytes}),
        @([pscustomobject]@{Name='Notes-unsigned.ipa';Bytes=$ipaBytes},[pscustomobject]@{Name='install-manifest.json';Bytes=$manifestBytes;External=(0x1000 -shl 16)}),
        @([pscustomobject]@{Name='Notes-unsigned.ipa';Bytes=$ipaBytes},[pscustomobject]@{Name='install-manifest.json';Bytes=$manifestBytes},[pscustomobject]@{Name='extra';Bytes=[byte[]](1)})
    )
    $index = 0
    foreach ($entries in $badOuterEntries) {
        $bad = Join-Path $root ('bad-outer-' + $index + '.zip')
        Write-Zip -Path $bad -Definitions $entries
        Rejects ('bad outer ' + $index) { Read-OuterArtifactArchive -ArtifactZipPath $bad }
        $index++
    }

    $badInnerEntries = @(
        [pscustomobject]@{Name='Payload/Notes.app/../evil';Bytes=[byte[]](1)},
        [pscustomobject]@{Name='Payload/Notes.app/CON.txt';Bytes=[byte[]](1)},
        [pscustomobject]@{Name='Payload/Notes.app/bad. ';Bytes=[byte[]](1)},
        [pscustomobject]@{Name='Payload/Notes.app/file.';Bytes=[byte[]](1)},
        [pscustomobject]@{Name='Payload/Notes.app/fifo';Bytes=[byte[]](1);External=(0x1000 -shl 16)}
    )
    $index = 0
    foreach ($entry in $badInnerEntries) {
        $bad = Join-Path $root ('bad-inner-' + $index + '.ipa')
        Make-Ipa -Path $bad -Extra @($entry)
        Rejects ('bad inner ' + $index) { Test-IpaArchive $bad }
        $index++
    }

    Rejects 'outer size cap' { Invoke-GhArtifactDownload -RepositorySlug 'owner/repository' -ArtifactId 1 -ExpectedBytes ($script:MaximumOuterBytes + 1) -DestinationPath (Join-Path $root 'never') }

    $childPowerShell = (Get-Process -Id $PID -ErrorAction Stop).Path
    $successfulOutput = Join-Path $root 'successful-download.bin'
    Invoke-BoundedBinaryProcessDownload `
        -FileName $childPowerShell `
        -Arguments @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
            '$errorBytes = New-Object byte[] 262144; $stderr = [Console]::OpenStandardError(); $stderr.Write($errorBytes, 0, $errorBytes.Length); $stdout = [Console]::OpenStandardOutput(); $bytes = [byte[]](1, 2, 3); $stdout.Write($bytes, 0, $bytes.Length); $stdout.Flush()'
        ) `
        -ExpectedBytes 3 `
        -DestinationPath $successfulOutput `
        -TotalDeadlineMilliseconds 10000 `
        -IdleDeadlineMilliseconds 5000 `
        -TerminationGraceMilliseconds 1000
    [byte[]]$successfulBytes = [System.IO.File]::ReadAllBytes($successfulOutput)
    if ($successfulBytes.Length -ne 3 -or
        $successfulBytes[0] -ne 1 -or
        $successfulBytes[1] -ne 2 -or
        $successfulBytes[2] -ne 3) {
        throw 'The bounded process pump did not preserve exact binary stdout while draining stderr.'
    }
    $script:Passed++

    $stalledOutput = Join-Path $root 'stalled-download.bin'
    $stallWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Rejects 'idle download deadline' {
        Invoke-BoundedBinaryProcessDownload `
            -FileName $childPowerShell `
            -Arguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
                '[Console]::OpenStandardOutput().WriteByte(65); [Console]::OpenStandardOutput().Flush(); Start-Sleep -Seconds 10'
            ) `
            -ExpectedBytes 2 `
            -DestinationPath $stalledOutput `
            -TotalDeadlineMilliseconds 2000 `
            -IdleDeadlineMilliseconds 250 `
            -TerminationGraceMilliseconds 1000
    }
    $stallWatch.Stop()
    if ($stallWatch.ElapsedMilliseconds -gt 5000 -or (Test-Path -LiteralPath $stalledOutput)) {
        throw 'The stalled-child fixture was not killed and cleaned within its bounded deadline.'
    }
    $script:Passed++

    $continuousOutput = Join-Path $root 'total-deadline-download.bin'
    $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Rejects 'total download deadline' {
        Invoke-BoundedBinaryProcessDownload `
            -FileName $childPowerShell `
            -Arguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
                'while ($true) { [Console]::OpenStandardOutput().WriteByte(66); [Console]::OpenStandardOutput().Flush(); Start-Sleep -Milliseconds 25 }'
            ) `
            -ExpectedBytes 100000 `
            -DestinationPath $continuousOutput `
            -TotalDeadlineMilliseconds 600 `
            -IdleDeadlineMilliseconds 2000 `
            -TerminationGraceMilliseconds 1000
    }
    $totalWatch.Stop()
    if ($totalWatch.ElapsedMilliseconds -gt 5000 -or (Test-Path -LiteralPath $continuousOutput)) {
        throw 'The total-deadline fixture was not killed and cleaned within its bounded deadline.'
    }
    $script:Passed++

    $apiArtifact = [pscustomobject]@{
        id=789L; name='Notes-unsigned-ipa'; size_in_bytes=(Get-Item $base.Outer).Length
        expired=$false; digest=('sha256:' + (Get-FileSha256 $base.Outer))
        workflow_run=[pscustomobject]@{id=456L;repository_id=123L;head_sha=$sha}
    }
    $script:Fake = [pscustomobject]@{total_count=1;artifacts=@($apiArtifact)}
    function Invoke-GhJson { param([string[]]$Arguments) return $script:Fake }
    Get-ExactArtifactMetadata -RepositorySlug 'owner/repository' -RepositoryId 123 -CommitSha $sha -RunId 456 | Out-Null
    $script:Passed++
    $oversize = $apiArtifact.PSObject.Copy()
    $oversize.size_in_bytes = $script:MaximumOuterBytes + 1
    $script:Fake = [pscustomobject]@{total_count=1;artifacts=@($oversize)}
    Rejects 'API size cap' { Get-ExactArtifactMetadata -RepositorySlug 'owner/repository' -RepositoryId 123 -CommitSha $sha -RunId 456 }
    $wrongRun = $apiArtifact.PSObject.Copy()
    $wrongRun.workflow_run = [pscustomobject]@{id=999L;repository_id=123L;head_sha=$sha}
    $script:Fake = [pscustomobject]@{total_count=1;artifacts=@($wrongRun)}
    Rejects 'API provenance' { Get-ExactArtifactMetadata -RepositorySlug 'owner/repository' -RepositoryId 123 -CommitSha $sha -RunId 456 }
    $badDigest = $apiArtifact.PSObject.Copy()
    $badDigest.digest = 'sha256:invalid'
    $script:Fake = [pscustomobject]@{total_count=1;artifacts=@($badDigest)}
    Rejects 'API digest' { Get-ExactArtifactMetadata -RepositorySlug 'owner/repository' -RepositoryId 123 -CommitSha $sha -RunId 456 }

    $source = Join-Path $root 'race-source'
    $destination = Join-Path $root 'race-destination'
    [void][System.IO.Directory]::CreateDirectory($source)
    [void][System.IO.Directory]::CreateDirectory($destination)
    Rejects 'atomic move race' { [System.IO.Directory]::Move($source, $destination) }
    if (-not (Test-Path $source -PathType Container) -or -not (Test-Path $destination -PathType Container)) { throw 'Move race mutated directories.' }
    Test-VerifiedInstallDirectory -DirectoryPath $valid -Context $context | Out-Null
    $script:Passed++

    Write-Output ('Synthetic verifier fixtures passed: {0}' -f $script:Passed)
}
finally {
    if (Test-Path -LiteralPath $root) {
        $resolved = [System.IO.Path]::GetFullPath($root)
        if (-not $resolved.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or -not [System.IO.Path]::GetFileName($resolved).StartsWith('NextStepFixture-', [System.StringComparison]::Ordinal)) { throw 'Unsafe fixture cleanup refused.' }
        [System.IO.Directory]::Delete($resolved, $true)
    }
}
