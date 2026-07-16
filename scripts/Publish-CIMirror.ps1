[CmdletBinding()]
param(
    [switch]$Publish
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configPath = Join-Path $repoRoot 'Config\CIMirror.json'
$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
$gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($null -eq $git -or $null -eq $gh) {
    throw 'Git and GitHub CLI are required to publish the CI mirror.'
}
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'Config/CIMirror.json is missing.'
}

function Invoke-GitText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & $git.Source -C $repoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('Git failed while preparing the CI mirror: {0}' -f (($output | Out-String).Trim()))
    }
    return (($output -join [Environment]::NewLine).Trim())
}

function Invoke-GhJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $savedHost = [Environment]::GetEnvironmentVariable('GH_HOST', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('GH_HOST', 'github.com', 'Process')
        $output = & $gh.Source @Arguments 2>&1
    }
    finally {
        [Environment]::SetEnvironmentVariable('GH_HOST', $savedHost, 'Process')
    }
    if ($LASTEXITCODE -ne 0) {
        throw ('GitHub CLI failed while validating the CI mirror: {0}' -f (($output | Out-String).Trim()))
    }
    try {
        return (($output -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw 'GitHub returned invalid JSON while validating the CI mirror.'
    }
}

function Assert-RepositorySlug {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'CI mirror repository names must use the owner/repository format.'
    }
}

function Get-GitRemoteRefs {
    param([Parameter(Mandatory = $true)][string]$RepositoryUrl)

    $text = Invoke-GitText -Arguments @('ls-remote', '--refs', $RepositoryUrl)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }

    foreach ($line in @($text -split "`r?`n")) {
        if ($line -cnotmatch '^(?<object>[0-9a-f]{40})\s+(?<ref>refs/\S+)$') {
            throw 'Git returned an unexpected remote reference while validating the CI mirror.'
        }
        [pscustomobject]@{
            ObjectId = [string]$Matches['object']
            Ref = [string]$Matches['ref']
        }
    }
}

$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 |
    ConvertFrom-Json -ErrorAction Stop
if ([string]$config.format -cne 'nextstep-public-ci-mirror' -or
    [int]$config.version -ne 1 -or
    [string]$config.historyPolicy -cne 'single-root-snapshot' -or
    [string]$config.licensePolicy -cne 'all-rights-reserved') {
    throw 'Config/CIMirror.json contains an unsupported policy.'
}

$sourceRepository = [string]$config.sourceRepository
$mirrorRepository = [string]$config.mirrorRepository
$mirrorBranch = [string]$config.mirrorBranch
Assert-RepositorySlug -Value $sourceRepository
Assert-RepositorySlug -Value $mirrorRepository
if ($mirrorBranch -cnotmatch '^[A-Za-z0-9._/-]+$' -or
    $mirrorBranch.StartsWith('/') -or
    $mirrorBranch.EndsWith('/') -or
    $mirrorBranch.Contains('..')) {
    throw 'The configured CI mirror branch is invalid.'
}
$checkedBranch = Invoke-GitText -Arguments @('check-ref-format', '--branch', $mirrorBranch)
if ($checkedBranch -cne $mirrorBranch) {
    throw 'Git rejected the configured CI mirror branch.'
}

$topLevel = Invoke-GitText -Arguments @('rev-parse', '--show-toplevel')
if (-not [string]::Equals(
        [System.IO.Path]::GetFullPath($topLevel).TrimEnd('\'),
        $repoRoot.TrimEnd('\'),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Publish-CIMirror.ps1 must run from its own repository worktree.'
}

$status = Invoke-GitText -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
if (-not [string]::IsNullOrWhiteSpace($status)) {
    throw 'The source worktree must be clean so the public snapshot matches an exact reviewed commit.'
}

$head = Invoke-GitText -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')
$sourceTree = Invoke-GitText -Arguments @('rev-parse', ($head + '^{tree}'))
if ($head -cnotmatch '^[0-9a-f]{40}$' -or $sourceTree -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Git did not return canonical source commit and tree identifiers.'
}

$origin = Invoke-GitText -Arguments @('remote', 'get-url', 'origin')
$githubOriginPattern = '^(?:(?:https://github\.com/)|(?:ssh://git@github\.com/)|(?:git@github\.com:))(?<owner>[A-Za-z0-9_.-]+)/(?<repository>[A-Za-z0-9_.-]+?)(?:\.git)?/?$'
if ($origin -cnotmatch $githubOriginPattern) {
    throw 'The source origin must be an HTTPS or SSH github.com repository without embedded credentials.'
}
$originSlug = '{0}/{1}' -f $Matches['owner'], $Matches['repository']
if (-not [string]::Equals($originSlug, $sourceRepository, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The source origin does not match Config/CIMirror.json.'
}

$currentBranch = Invoke-GitText -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
if ($currentBranch -ceq 'HEAD') {
    throw 'The source repository must be on a branch with an origin upstream.'
}
$upstream = Invoke-GitText -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
if (-not $upstream.StartsWith('origin/', [System.StringComparison]::Ordinal)) {
    throw 'The source branch upstream must be on the validated origin remote.'
}
$upstreamBranch = $upstream.Substring('origin/'.Length)

$treePathText = Invoke-GitText -Arguments @(
    '-c', 'core.quotePath=false', 'ls-tree', '-r', '--name-only', $head
)
$trackedFiles = @(
    if (-not [string]::IsNullOrWhiteSpace($treePathText)) {
        $treePathText -split "`r?`n"
    }
)
$quotedPaths = @($trackedFiles | Where-Object { $_.StartsWith('"') })
if ($quotedPaths.Count -gt 0) {
    throw 'Refusing to publish a tree containing control characters or quoting-sensitive file names.'
}

$treeEntriesText = Invoke-GitText -Arguments @('ls-tree', '-r', '--full-tree', $head)
$unsupportedTreeEntries = @(
    $treeEntriesText -split "`r?`n" |
        Where-Object { $_ -match '^(120000|160000) ' }
)
if ($unsupportedTreeEntries.Count -gt 0) {
    throw 'Refusing to publish symlinks or Git submodule entries in the public CI mirror.'
}

$sensitivePaths = @($trackedFiles | Where-Object {
        $_ -match '(?i)(^|/)(\.env($|\.)|\.gitmodules$|\.netrc$|\.npmrc$|\.pypirc$|id_(rsa|dsa|ecdsa|ed25519)$|Config/Local\.xcconfig$|\.local/|\.aws/|\.ssh/|\.docker/config\.json$)' -or
        $_ -match '(?i)^Models/' -or
        $_ -match '(?i)\.(p8|p12|pfx|pem|ppk|der|mobileprovision|provisionprofile|mobileconfig|key|jks|keystore|kdbx|ovpn|age|gpg|sqlite|sqlite3|db|realm|ipa|pdf|doc|docx|ppt|pptx|xls|xlsx|pages|numbers|keynote|zip|7z|rar|tar|tgz|gz)$' -or
        $_ -match '(?i)(^|/)[^/]+\.(xcarchive|xcresult)(/|$)'
    })
if ($sensitivePaths.Count -gt 0) {
    throw ('Refusing to publish tracked sensitive paths: {0}' -f (($sensitivePaths | Select-Object -First 10) -join ', '))
}

$rootLicensePaths = @($trackedFiles | Where-Object {
        $_ -match '(?i)^(LICENSE|LICENCE|COPYING)(\..*)?$'
    })
if ($rootLicensePaths.Count -gt 0) {
    throw 'The all-rights-reserved mirror policy requires no root open-source license file.'
}

$secretPatterns = @(
    '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----',
    'github_pat_[A-Za-z0-9_]{20,}',
    'gh[pousr]_[A-Za-z0-9_]{20,}',
    '(AKIA|ASIA)[0-9A-Z]{16}',
    'AIza[0-9A-Za-z_-]{35}',
    'sk-(proj-)?[A-Za-z0-9_-]{20,}',
    'xox[baprs]-[A-Za-z0-9-]{10,}',
    '[rs]k_live_[A-Za-z0-9]{16,}'
)
foreach ($pattern in $secretPatterns) {
    $matchingPaths = & $git.Source -C $repoRoot grep -a -l -E -e $pattern $head -- 2>$null
    $grepExitCode = $LASTEXITCODE
    if ($grepExitCode -eq 0) {
        throw ('A credential-like value blocked public mirror publication in tracked file: {0}' -f (($matchingPaths | Select-Object -First 1) -join ''))
    }
    if ($grepExitCode -ne 1) {
        throw 'The credential scan could not be completed.'
    }
}

$sourceMetadata = Invoke-GhJson -Arguments @('api', '--method', 'GET', ('repos/{0}' -f $sourceRepository))
if ([string]$sourceMetadata.full_name -cne $sourceRepository -or -not [bool]$sourceMetadata.private) {
    throw 'The authoritative source repository must be the configured private repository.'
}

$encodedUpstreamBranch = (($upstreamBranch -split '/') | ForEach-Object {
        [Uri]::EscapeDataString($_)
    }) -join '/'
$upstreamMetadata = Invoke-GhJson -Arguments @(
    'api', '--method', 'GET', ('repos/{0}/git/ref/heads/{1}' -f $sourceRepository, $encodedUpstreamBranch)
)
if ([string]$upstreamMetadata.ref -cne ('refs/heads/{0}' -f $upstreamBranch) -or
    [string]$upstreamMetadata.object.type -cne 'commit' -or
    [string]$upstreamMetadata.object.sha -cne $head) {
    throw 'The exact source HEAD must be pushed to its configured origin upstream before publication.'
}

$mirrorMetadata = Invoke-GhJson -Arguments @('api', '--method', 'GET', ('repos/{0}' -f $mirrorRepository))
if ([string]$mirrorMetadata.full_name -cne $mirrorRepository -or
    [bool]$mirrorMetadata.private -or
    [string]$mirrorMetadata.visibility -cne 'public' -or
    [bool]$mirrorMetadata.fork -or
    [string]$mirrorMetadata.default_branch -cne $mirrorBranch) {
    throw 'The CI mirror must be the configured standalone public repository.'
}

$activeUser = Invoke-GhJson -Arguments @('api', '--method', 'GET', 'user')
$activeAccount = [string]$activeUser.login
if (-not [string]::Equals($activeAccount, $sourceRepository.Split('/')[0], [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'GitHub CLI must be authenticated as the configured repository owner.'
}

$mirrorUrl = 'https://github.com/{0}.git' -f $mirrorRepository
$allowedMirrorRef = 'refs/heads/{0}' -f $mirrorBranch
$mirrorRefs = @(Get-GitRemoteRefs -RepositoryUrl $mirrorUrl)
$unexpectedMirrorRefs = @($mirrorRefs | Where-Object {
        $_.Ref -cne $allowedMirrorRef -and
        $_.Ref -cnotmatch '^refs/pull/[1-9][0-9]*/(?:head|merge)$'
    })
if ($unexpectedMirrorRefs.Count -gt 0) {
    throw ('The public mirror contains an unexpected Git reference: {0}' -f $unexpectedMirrorRefs[0].Ref)
}
$currentMirrorRefs = @($mirrorRefs | Where-Object { $_.Ref -ceq $allowedMirrorRef })
if ($currentMirrorRefs.Count -gt 1) {
    throw 'The public mirror returned duplicate main references.'
}
$previousMirrorCommit = $null
if ($currentMirrorRefs.Count -eq 1) {
    $previousMirrorCommit = [string]$currentMirrorRefs[0].ObjectId
    $previousMirrorMetadata = Invoke-GhJson -Arguments @(
        'api', '--method', 'GET', ('repos/{0}/git/commits/{1}' -f $mirrorRepository, $previousMirrorCommit)
    )
    if (@($previousMirrorMetadata.parents).Count -ne 0 -or
        [string]$previousMirrorMetadata.message -cnotmatch '^NextStep public CI snapshot(?:\r?\n|$)') {
        throw 'The existing mirror branch is not a recognized parentless NextStep snapshot; recreate the mirror instead of overwriting it.'
    }
}

$result = [ordered]@{
    Format = 'nextstep-public-ci-mirror-publication'
    SourceRepository = $sourceRepository
    SourceCommit = $head
    SourceTree = $sourceTree
    MirrorRepository = $mirrorRepository
    MirrorBranch = $mirrorBranch
    HistoryPolicy = 'single-root-snapshot'
    Published = $false
    PreviousMirrorCommit = $previousMirrorCommit
    MirrorCommit = $null
}

if (-not $Publish) {
    [pscustomobject]$result
    return
}

$timestamp = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$mirrorAuthorName = 'TrueAlpha0902'
$mirrorAuthorEmail = '299879199+TrueAlpha0902@users.noreply.github.com'
$message = @"
NextStep public CI snapshot

Authoritative source tree: $sourceTree
This root commit intentionally contains no private repository history.
"@
$savedEnvironment = @{}
foreach ($name in @(
        'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE',
        'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE'
    )) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    [Environment]::SetEnvironmentVariable('GIT_AUTHOR_NAME', $mirrorAuthorName, 'Process')
    [Environment]::SetEnvironmentVariable('GIT_AUTHOR_EMAIL', $mirrorAuthorEmail, 'Process')
    [Environment]::SetEnvironmentVariable('GIT_AUTHOR_DATE', $timestamp, 'Process')
    [Environment]::SetEnvironmentVariable('GIT_COMMITTER_NAME', $mirrorAuthorName, 'Process')
    [Environment]::SetEnvironmentVariable('GIT_COMMITTER_EMAIL', $mirrorAuthorEmail, 'Process')
    [Environment]::SetEnvironmentVariable('GIT_COMMITTER_DATE', $timestamp, 'Process')
    $snapshotCommit = ($message | & $git.Source -C $repoRoot commit-tree $sourceTree).Trim()
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
if ($LASTEXITCODE -ne 0 -or $snapshotCommit -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Git could not create the parentless public snapshot commit.'
}

$commitLine = Invoke-GitText -Arguments @('rev-list', '--parents', '-n', '1', $snapshotCommit)
if ($commitLine -cne $snapshotCommit) {
    throw 'The proposed public snapshot unexpectedly contains a parent commit.'
}
$snapshotTree = Invoke-GitText -Arguments @('rev-parse', ($snapshotCommit + '^{tree}'))
if ($snapshotTree -cne $sourceTree) {
    throw 'The proposed public snapshot tree differs from the authoritative source tree.'
}
if ((Invoke-GitText -Arguments @('show', '-s', '--format=%an', $snapshotCommit)) -cne $mirrorAuthorName -or
    (Invoke-GitText -Arguments @('show', '-s', '--format=%ae', $snapshotCommit)) -cne $mirrorAuthorEmail -or
    (Invoke-GitText -Arguments @('show', '-s', '--format=%cn', $snapshotCommit)) -cne $mirrorAuthorName -or
    (Invoke-GitText -Arguments @('show', '-s', '--format=%ce', $snapshotCommit)) -cne $mirrorAuthorEmail -or
    (Invoke-GitText -Arguments @('show', '-s', '--format=%s', $snapshotCommit)) -cne 'NextStep public CI snapshot') {
    throw 'The proposed public snapshot contains unexpected identity or message metadata.'
}

$leaseArgument = '--force-with-lease={0}:{1}' -f $allowedMirrorRef, [string]$previousMirrorCommit
$savedErrorActionPreference = $ErrorActionPreference
try {
    # Windows PowerShell 5.1 surfaces a native process's stderr as a
    # NativeCommandError when ErrorActionPreference is Stop. Git writes normal
    # push progress to stderr, so capture it under Continue and decide only by
    # the native exit code.
    $ErrorActionPreference = 'Continue'
    $pushOutput = @(
        & $git.Source -C $repoRoot push --no-verify --no-follow-tags `
            --recurse-submodules=no $leaseArgument $mirrorUrl `
            ('{0}:{1}' -f $snapshotCommit, $allowedMirrorRef) 2>&1
    )
    $pushExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
if ($pushExitCode -ne 0) {
    throw ('The public CI snapshot push failed: {0}' -f (($pushOutput | Out-String).Trim()))
}

$publishedRefs = @(Get-GitRemoteRefs -RepositoryUrl $mirrorUrl)
$unexpectedPublishedRefs = @($publishedRefs | Where-Object {
        $_.Ref -cne $allowedMirrorRef -and
        $_.Ref -cnotmatch '^refs/pull/[1-9][0-9]*/(?:head|merge)$'
    })
$publishedMainRefs = @($publishedRefs | Where-Object { $_.Ref -ceq $allowedMirrorRef })
if ($unexpectedPublishedRefs.Count -gt 0 -or
    $publishedMainRefs.Count -ne 1 -or
    $publishedMainRefs[0].ObjectId -cne $snapshotCommit) {
    throw 'The public mirror branch does not point at the exact snapshot commit or an unexpected Git reference is present.'
}

$remoteCommitMetadata = Invoke-GhJson -Arguments @(
    'api', '--method', 'GET', ('repos/{0}/git/commits/{1}' -f $mirrorRepository, $snapshotCommit)
)
if ([string]$remoteCommitMetadata.tree.sha -cne $sourceTree -or
    @($remoteCommitMetadata.parents).Count -ne 0 -or
    [string]$remoteCommitMetadata.author.name -cne $mirrorAuthorName -or
    [string]$remoteCommitMetadata.author.email -cne $mirrorAuthorEmail -or
    [string]$remoteCommitMetadata.committer.name -cne $mirrorAuthorName -or
    [string]$remoteCommitMetadata.committer.email -cne $mirrorAuthorEmail -or
    [string]$remoteCommitMetadata.message -cnotmatch '^NextStep public CI snapshot(?:\r?\n|$)') {
    throw 'GitHub did not preserve the exact tree and sanitized parentless mirror metadata.'
}

$result.Published = $true
$result.MirrorCommit = $snapshotCommit
[pscustomobject]$result
