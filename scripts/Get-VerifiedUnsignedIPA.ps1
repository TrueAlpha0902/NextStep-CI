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

$script:ArtifactName = 'Notes-unsigned-ipa'
$script:WorkflowFile = 'ios-ci.yml'
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
$script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:InstallRoot = [System.IO.Path]::GetFullPath((Join-Path $script:RepoRoot '.local\ipad-install'))
$script:Git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
$script:Gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($null -eq $script:Git) {
    throw 'Git is required to bind the installation artifact to the exact local commit.'
}
if ($null -eq $script:Gh) {
    throw 'GitHub CLI is required to validate and retrieve the exact workflow artifact.'
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        throw "GitHub metadata is missing required property '$Name'."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "GitHub metadata is missing required property '$Name'."
    }
    return $property.Value
}

function ConvertTo-RequiredPositiveInt64 {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = Get-RequiredProperty -Object $Object -Name $Name
    $text = [System.Convert]::ToString($value, [System.Globalization.CultureInfo]::InvariantCulture)
    if ($text -notmatch '^[1-9][0-9]*$') {
        throw "GitHub metadata property '$Name' is not a positive integer."
    }
    [long]$result = 0
    if (-not [long]::TryParse(
            $text,
            [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$result
        ) -or $result -le 0) {
        throw "GitHub metadata property '$Name' exceeds the accepted integer range."
    }
    return $result
}

function Invoke-GitText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & $script:Git.Source -C $script:RepoRoot @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'A required Git read operation failed.'
    }
    return (($output -join [Environment]::NewLine).Trim())
}

function New-GithubComApiArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if ($Arguments.Count -lt 1 -or $Arguments[0] -cne 'api') {
        throw 'A GitHub CLI API invocation must begin with the exact api command.'
    }
    foreach ($argument in $Arguments) {
        if ([string]::IsNullOrWhiteSpace($argument) -or
            $argument.Length -gt 4096 -or
            $argument -match '^--hostname(?:=|$)' -or
            $argument -notmatch '^[A-Za-z0-9_./?=&:+-]+$') {
            throw 'An unsafe or host-routing GitHub CLI argument was rejected.'
        }
    }

    $result = New-Object 'System.Collections.Generic.List[string]'
    $result.Add('api') | Out-Null
    $result.Add('--hostname') | Out-Null
    $result.Add('github.com') | Out-Null
    for ($index = 1; $index -lt $Arguments.Count; $index++) {
        $result.Add($Arguments[$index]) | Out-Null
    }
    return $result.ToArray()
}

function Invoke-GhJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $effectiveArguments = @(New-GithubComApiArguments -Arguments $Arguments)
    $savedGhHost = [Environment]::GetEnvironmentVariable('GH_HOST', 'Process')
    $savedGhEnterpriseToken = [Environment]::GetEnvironmentVariable('GH_ENTERPRISE_TOKEN', 'Process')
    $savedGithubEnterpriseToken = [Environment]::GetEnvironmentVariable('GITHUB_ENTERPRISE_TOKEN', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('GH_HOST', 'github.com', 'Process')
        [Environment]::SetEnvironmentVariable('GH_ENTERPRISE_TOKEN', $null, 'Process')
        [Environment]::SetEnvironmentVariable('GITHUB_ENTERPRISE_TOKEN', $null, 'Process')
        $output = & $script:Gh.Source @effectiveArguments 2>$null
    }
    finally {
        [Environment]::SetEnvironmentVariable('GH_HOST', $savedGhHost, 'Process')
        [Environment]::SetEnvironmentVariable('GH_ENTERPRISE_TOKEN', $savedGhEnterpriseToken, 'Process')
        [Environment]::SetEnvironmentVariable('GITHUB_ENTERPRISE_TOKEN', $savedGithubEnterpriseToken, 'Process')
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'A required GitHub metadata request failed.'
    }
    $text = ($output -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'GitHub returned an empty metadata response.'
    }
    try {
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw 'GitHub returned metadata that could not be validated.'
    }
}

function ConvertFrom-StrictCIMirrorConfiguration {
    param([Parameter(Mandatory = $true)][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 16KB) {
        throw 'The committed CI mirror configuration is missing or outside the accepted size limit.'
    }
    try {
        $configuration = $Text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'The committed CI mirror configuration is not valid JSON.'
    }

    $expectedKeys = @(
        'format', 'version', 'sourceRepository', 'mirrorRepository',
        'mirrorBranch', 'historyPolicy', 'licensePolicy'
    )
    $properties = @($configuration.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($properties.Count -ne $expectedKeys.Count) {
        throw 'The committed CI mirror configuration contains an unexpected property set.'
    }
    foreach ($key in $expectedKeys) {
        if ($properties -cnotcontains $key -or
            [regex]::Matches($Text, ('"' + [regex]::Escape($key) + '"\s*:')).Count -ne 1) {
            throw 'The committed CI mirror configuration contains an unexpected property set.'
        }
    }

    $version = Get-RequiredProperty -Object $configuration -Name 'version'
    if ($version -isnot [int] -or [int]$version -ne 1 -or
        [string](Get-RequiredProperty -Object $configuration -Name 'format') -cne 'nextstep-public-ci-mirror' -or
        [string](Get-RequiredProperty -Object $configuration -Name 'sourceRepository') -cne $script:ExpectedSourceRepository -or
        [string](Get-RequiredProperty -Object $configuration -Name 'mirrorRepository') -cne $script:ExpectedMirrorRepository -or
        [string](Get-RequiredProperty -Object $configuration -Name 'mirrorBranch') -cne $script:ExpectedMirrorBranch -or
        [string](Get-RequiredProperty -Object $configuration -Name 'historyPolicy') -cne 'single-root-snapshot' -or
        [string](Get-RequiredProperty -Object $configuration -Name 'licensePolicy') -cne 'all-rights-reserved') {
        throw 'The committed CI mirror configuration does not match the supported NextStep public mirror policy.'
    }
    return $configuration
}

function Get-CommittedCIMirrorConfiguration {
    param([Parameter(Mandatory = $true)][string]$SourceCommitSha)

    if ($SourceCommitSha -cnotmatch '^[0-9a-f]{40}$') {
        throw 'A canonical source commit is required to read the CI mirror configuration.'
    }
    $text = Invoke-GitText -Arguments @('show', ('{0}:{1}' -f $SourceCommitSha, $script:CIMirrorConfigPath))
    return ConvertFrom-StrictCIMirrorConfiguration -Text $text
}

function Get-OriginRepositorySlug {
    $remote = Invoke-GitText -Arguments @('remote', 'get-url', 'origin')
    $pattern = '^(?:(?:https://github\.com/)|(?:ssh://git@github\.com/)|(?:git@github\.com:))(?<owner>[A-Za-z0-9_.-]+)/(?<repository>[A-Za-z0-9_.-]+?)(?:\.git)?/?$'
    if ($remote -cnotmatch $pattern) {
        throw 'The source origin must be an HTTPS or SSH github.com repository without embedded credentials.'
    }
    return ('{0}/{1}' -f $Matches['owner'], $Matches['repository'])
}

function Assert-SourceRepositoryMetadata {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$ExpectedRepository
    )

    $private = Get-RequiredProperty -Object $Metadata -Name 'private'
    $fork = Get-RequiredProperty -Object $Metadata -Name 'fork'
    if ($private -isnot [bool] -or -not [bool]$private -or
        $fork -isnot [bool] -or [bool]$fork -or
        [string](Get-RequiredProperty -Object $Metadata -Name 'full_name') -cne $ExpectedRepository) {
        throw 'The authoritative source must be the exact configured private, standalone GitHub repository.'
    }
}

function Assert-MirrorRepositoryMetadata {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$ExpectedRepository,
        [Parameter(Mandatory = $true)][string]$ExpectedBranch
    )

    $private = Get-RequiredProperty -Object $Metadata -Name 'private'
    $fork = Get-RequiredProperty -Object $Metadata -Name 'fork'
    if ($private -isnot [bool] -or [bool]$private -or
        $fork -isnot [bool] -or [bool]$fork -or
        [string](Get-RequiredProperty -Object $Metadata -Name 'visibility') -cne 'public' -or
        [string](Get-RequiredProperty -Object $Metadata -Name 'full_name') -cne $ExpectedRepository -or
        [string](Get-RequiredProperty -Object $Metadata -Name 'default_branch') -cne $ExpectedBranch) {
        throw 'The CI mirror must be the exact configured public, standalone GitHub repository and branch.'
    }
}

function Assert-MirrorSnapshotMetadata {
    param(
        [Parameter(Mandatory = $true)]$Reference,
        [Parameter(Mandatory = $true)]$CommitMetadata,
        [Parameter(Mandatory = $true)][string]$ExpectedBranch,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTree,
        [string]$ExpectedMirrorCommit
    )

    if ($ExpectedSourceTree -cnotmatch '^[0-9a-f]{40}$') {
        throw 'The local source tree is not a canonical Git tree identifier.'
    }
    $referenceObject = Get-RequiredProperty -Object $Reference -Name 'object'
    $referenceSha = [string](Get-RequiredProperty -Object $referenceObject -Name 'sha')
    if ([string](Get-RequiredProperty -Object $Reference -Name 'ref') -cne ('refs/heads/{0}' -f $ExpectedBranch) -or
        [string](Get-RequiredProperty -Object $referenceObject -Name 'type') -cne 'commit' -or
        $referenceSha -cnotmatch '^[0-9a-f]{40}$') {
        throw 'The configured CI mirror branch did not resolve to one canonical commit.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMirrorCommit) -and
        ($ExpectedMirrorCommit -cnotmatch '^[0-9a-f]{40}$' -or $referenceSha -cne $ExpectedMirrorCommit)) {
        throw 'The configured CI mirror branch does not match the explicitly selected mirror commit.'
    }

    $commitSha = [string](Get-RequiredProperty -Object $CommitMetadata -Name 'sha')
    $tree = Get-RequiredProperty -Object $CommitMetadata -Name 'tree'
    $treeSha = [string](Get-RequiredProperty -Object $tree -Name 'sha')
    $parents = @(Get-RequiredProperty -Object $CommitMetadata -Name 'parents')
    $message = [string](Get-RequiredProperty -Object $CommitMetadata -Name 'message')
    $escapedTree = [regex]::Escape($ExpectedSourceTree)
    $expectedMessage = '\ANextStep public CI snapshot\r?\n\r?\nAuthoritative source tree: ' +
        $escapedTree +
        '\r?\nThis root commit intentionally contains no private repository history\.\r?\n?\z'
    if ($commitSha -cne $referenceSha -or
        $treeSha -cne $ExpectedSourceTree -or
        $parents.Count -ne 0 -or
        $message -cnotmatch $expectedMessage) {
        throw 'The mirror commit is not the recognized parentless snapshot of the exact local HEAD tree.'
    }
    return [pscustomobject]@{
        CommitSha = $commitSha
        TreeSha = $treeSha
    }
}

function Get-VerifiedMirrorSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$RepositorySlug,
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)][string]$SourceTreeSha,
        [string]$RequestedMirrorCommit
    )

    if ($Branch -cnotmatch '^[A-Za-z0-9._/-]+$' -or
        $Branch.StartsWith('/') -or $Branch.EndsWith('/') -or $Branch.Contains('..')) {
        throw 'The configured CI mirror branch is invalid.'
    }
    $reference = Invoke-GhJson -Arguments @(
        'api', '--method', 'GET', ('repos/{0}/git/ref/heads/{1}' -f $RepositorySlug, $Branch)
    )
    $referenceObject = Get-RequiredProperty -Object $reference -Name 'object'
    $referenceSha = [string](Get-RequiredProperty -Object $referenceObject -Name 'sha')
    if ($referenceSha -cnotmatch '^[0-9a-f]{40}$') {
        throw 'The configured CI mirror branch returned an invalid commit identifier.'
    }
    $commitMetadata = Invoke-GhJson -Arguments @(
        'api', '--method', 'GET', ('repos/{0}/git/commits/{1}' -f $RepositorySlug, $referenceSha)
    )
    return Assert-MirrorSnapshotMetadata `
        -Reference $reference `
        -CommitMetadata $commitMetadata `
        -ExpectedBranch $Branch `
        -ExpectedSourceTree $SourceTreeSha `
        -ExpectedMirrorCommit $RequestedMirrorCommit
}

function Get-RequestedRepositorySlug {
    param(
        [string]$RequestedRepository,
        [Parameter(Mandatory = $true)][string]$ConfiguredRepository
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedRepository)) {
        if ($RequestedRepository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            throw 'Repository must use the owner/repository format.'
        }
        if ($RequestedRepository -cne $ConfiguredRepository) {
            throw 'Repository must be the exact public CI mirror configured by the committed source tree.'
        }
    }
    return $ConfiguredRepository
}

function Get-CanonicalRepository {
    param([Parameter(Mandatory = $true)][string]$RequestedRepository)

    $response = Invoke-GhJson -Arguments @(
        'api', '--method', 'GET',
        ('repos/{0}' -f $RequestedRepository)
    )
    $name = [string](Get-RequiredProperty -Object $response -Name 'full_name')
    if ($name -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'GitHub returned an invalid canonical repository name.'
    }
    $id = ConvertTo-RequiredPositiveInt64 -Object $response -Name 'id'
    return [pscustomobject]@{
        Name = $name
        Id = $id
        Metadata = $response
    }
}

function Get-WorkflowMetadata {
    param([Parameter(Mandatory = $true)][string]$RepositorySlug)

    $workflow = Invoke-GhJson -Arguments @(
        'api', '--method', 'GET',
        ('repos/{0}/actions/workflows/{1}' -f $RepositorySlug, $script:WorkflowFile)
    )
    $workflowId = ConvertTo-RequiredPositiveInt64 -Object $workflow -Name 'id'
    $path = [string](Get-RequiredProperty -Object $workflow -Name 'path')
    $state = [string](Get-RequiredProperty -Object $workflow -Name 'state')
    if ($path -cne $script:WorkflowPath -or $state -cne 'active') {
        throw 'The selected GitHub workflow is not the active .github/workflows/ios-ci.yml workflow.'
    }
    return [pscustomobject]@{
        Id = $workflowId
        Path = $path
    }
}

function Assert-RunMetadata {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$ExpectedRepository,
        [Parameter(Mandatory = $true)][long]$ExpectedRepositoryId,
        [Parameter(Mandatory = $true)][long]$ExpectedWorkflowId,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedBranch
    )

    $id = ConvertTo-RequiredPositiveInt64 -Object $Run -Name 'id'
    $workflowId = ConvertTo-RequiredPositiveInt64 -Object $Run -Name 'workflow_id'
    $runAttempt = ConvertTo-RequiredPositiveInt64 -Object $Run -Name 'run_attempt'
    $path = [string](Get-RequiredProperty -Object $Run -Name 'path')
    $headSha = [string](Get-RequiredProperty -Object $Run -Name 'head_sha')
    $headBranch = [string](Get-RequiredProperty -Object $Run -Name 'head_branch')
    $event = [string](Get-RequiredProperty -Object $Run -Name 'event')
    $status = [string](Get-RequiredProperty -Object $Run -Name 'status')
    $conclusion = [string](Get-RequiredProperty -Object $Run -Name 'conclusion')
    $repository = Get-RequiredProperty -Object $Run -Name 'repository'
    $repositoryId = ConvertTo-RequiredPositiveInt64 -Object $repository -Name 'id'
    $repositoryName = [string](Get-RequiredProperty -Object $repository -Name 'full_name')

    if ($workflowId -ne $ExpectedWorkflowId -or
        $path -cne $script:WorkflowPath -or
        $headSha -cne $ExpectedCommit -or
        $headBranch -cne $ExpectedBranch -or
        ($event -cne 'push' -and $event -cne 'workflow_dispatch') -or
        $status -cne 'completed' -or
        $conclusion -cne 'success' -or
        $repositoryId -ne $ExpectedRepositoryId -or
        $repositoryName -cne $ExpectedRepository) {
        throw 'The workflow run does not match the exact workflow, repository, branch, commit, and successful completion state.'
    }

    $urlProperty = $Run.PSObject.Properties['html_url']
    $url = if ($null -ne $urlProperty -and $null -ne $urlProperty.Value) { [string]$urlProperty.Value } else { '' }
    return [pscustomobject]@{
        Id = $id
        Attempt = $runAttempt
        Url = $url
    }
}

function Get-ExactRunMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$RepositorySlug,
        [Parameter(Mandatory = $true)][long]$RepositoryId,
        [Parameter(Mandatory = $true)][long]$WorkflowId,
        [Parameter(Mandatory = $true)][string]$CommitSha,
        [Parameter(Mandatory = $true)][string]$Branch,
        [long]$RequestedRunId
    )

    [long]$selectedRunId = $RequestedRunId
    if ($selectedRunId -le 0) {
        $response = Invoke-GhJson -Arguments @(
            'api', '--method', 'GET',
            ('repos/{0}/actions/workflows/{1}/runs?head_sha={2}&status=success&per_page=100' -f
                $RepositorySlug, $WorkflowId, $CommitSha)
        )
        $runsValue = Get-RequiredProperty -Object $response -Name 'workflow_runs'
        $validated = New-Object 'System.Collections.Generic.List[object]'
        foreach ($candidate in @($runsValue)) {
            try {
                $candidateInfo = Assert-RunMetadata `
                    -Run $candidate `
                    -ExpectedRepository $RepositorySlug `
                    -ExpectedRepositoryId $RepositoryId `
                    -ExpectedWorkflowId $WorkflowId `
                    -ExpectedCommit $CommitSha `
                    -ExpectedBranch $Branch
                $validated.Add($candidateInfo) | Out-Null
            }
            catch {
                continue
            }
        }
        if ($validated.Count -lt 1) {
            throw 'No successful run of the exact iOS workflow exists for the selected commit.'
        }
        $selectedRunId = [long](($validated | Sort-Object -Property Id -Descending | Select-Object -First 1).Id)
    }

    $exactRun = Invoke-GhJson -Arguments @(
        'api', '--method', 'GET',
        ('repos/{0}/actions/runs/{1}' -f $RepositorySlug, $selectedRunId)
    )
    $result = Assert-RunMetadata `
        -Run $exactRun `
        -ExpectedRepository $RepositorySlug `
        -ExpectedRepositoryId $RepositoryId `
        -ExpectedWorkflowId $WorkflowId `
        -ExpectedCommit $CommitSha `
        -ExpectedBranch $Branch
    if ($result.Id -ne $selectedRunId) {
        throw 'GitHub returned a different workflow run than the requested run ID.'
    }
    return $result
}

function Get-ExactArtifactMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$RepositorySlug,
        [Parameter(Mandatory = $true)][long]$RepositoryId,
        [Parameter(Mandatory = $true)][string]$CommitSha,
        [Parameter(Mandatory = $true)][long]$RunId
    )

    $response = Invoke-GhJson -Arguments @(
        'api', '--method', 'GET',
        ('repos/{0}/actions/runs/{1}/artifacts?name={2}&per_page=100' -f
            $RepositorySlug, $RunId, $script:ArtifactName)
    )
    $totalCount = ConvertTo-RequiredPositiveInt64 -Object $response -Name 'total_count'
    $artifactsValue = Get-RequiredProperty -Object $response -Name 'artifacts'
    $matching = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in @($artifactsValue)) {
        $nameProperty = $candidate.PSObject.Properties['name']
        if ($null -ne $nameProperty -and [string]$nameProperty.Value -ceq $script:ArtifactName) {
            $matching.Add($candidate) | Out-Null
        }
    }
    if ($totalCount -ne 1 -or $matching.Count -ne 1) {
        throw 'The exact workflow run must contain one and only one Notes-unsigned-ipa artifact.'
    }

    $artifact = $matching[0]
    $artifactId = ConvertTo-RequiredPositiveInt64 -Object $artifact -Name 'id'
    $size = ConvertTo-RequiredPositiveInt64 -Object $artifact -Name 'size_in_bytes'
    if ($size -le 1KB -or $size -gt $script:MaximumOuterBytes) {
        throw 'The GitHub artifact size is outside the accepted 2 GiB outer archive limit.'
    }

    $expired = Get-RequiredProperty -Object $artifact -Name 'expired'
    if ($expired -isnot [bool] -or [bool]$expired) {
        throw 'The exact workflow artifact is expired or has invalid expiration metadata.'
    }
    $digest = [string](Get-RequiredProperty -Object $artifact -Name 'digest')
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'The artifact API did not provide an exact SHA-256 outer archive digest.'
    }

    $workflowRun = Get-RequiredProperty -Object $artifact -Name 'workflow_run'
    $artifactRunId = ConvertTo-RequiredPositiveInt64 -Object $workflowRun -Name 'id'
    $artifactRepositoryId = ConvertTo-RequiredPositiveInt64 -Object $workflowRun -Name 'repository_id'
    $artifactHeadSha = [string](Get-RequiredProperty -Object $workflowRun -Name 'head_sha')
    if ($artifactRunId -ne $RunId -or
        $artifactRepositoryId -ne $RepositoryId -or
        $artifactHeadSha -cne $CommitSha) {
        throw 'The artifact provenance does not match the exact run, repository, and commit.'
    }

    return [pscustomobject]@{
        Id = $artifactId
        Size = $size
        Digest = $digest
        DigestHex = $digest.Substring(7)
    }
}

function Get-InstallCacheKey {
    param([Parameter(Mandatory = $true)]$Context)

    $commitSha = [string](Get-RequiredProperty -Object $Context -Name 'CommitSha')
    if ($commitSha -cnotmatch '^[0-9a-f]{40}$') {
        throw 'The verified cache context contains an invalid commit SHA.'
    }
    $runId = ConvertTo-RequiredPositiveInt64 -Object $Context -Name 'RunId'
    $runAttempt = ConvertTo-RequiredPositiveInt64 -Object $Context -Name 'RunAttempt'
    $artifactId = ConvertTo-RequiredPositiveInt64 -Object $Context -Name 'ArtifactId'
    $key = '{0}-run{1}-attempt{2}-artifact{3}' -f $commitSha, $runId, $runAttempt, $artifactId
    if ($key -cnotmatch '^[0-9a-f]{40}-run[1-9][0-9]*-attempt[1-9][0-9]*-artifact[1-9][0-9]*$') {
        throw 'The verified artifact provenance could not be represented as a safe cache key.'
    }
    return $key
}

function Assert-RepositoryLocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $baseFull = $script:RepoRoot.TrimEnd('\')
    $targetFull = [System.IO.Path]::GetFullPath($Path)
    $prefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The install path resolved outside the repository.'
    }

    $baseItem = Get-Item -LiteralPath $baseFull -Force -ErrorAction Stop
    if (($baseItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The repository root must not be a reparse point during artifact installation.'
    }

    $relative = $targetFull.Substring($prefix.Length)
    $current = $baseFull
    foreach ($part in $relative.Split([System.IO.Path]::DirectorySeparatorChar)) {
        if ([string]::IsNullOrEmpty($part)) {
            continue
        }
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'A reparse point was found in the local artifact path.'
            }
        }
    }
    return $targetFull
}

function Remove-SafeTemporaryDirectory {
    param([Parameter(Mandatory = $true)][string]$TemporaryPath)

    $temporaryFull = [System.IO.Path]::GetFullPath($TemporaryPath)
    $parent = [System.IO.Path]::GetDirectoryName($temporaryFull)
    if (-not [string]::Equals($parent, $script:InstallRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [System.IO.Path]::GetFileName($temporaryFull).StartsWith('.tmp-', [System.StringComparison]::Ordinal)) {
        throw 'Refusing to clean a path that is not a direct install temporary directory.'
    }
    [void](Assert-RepositoryLocalPath -Path $temporaryFull)
    if (Test-Path -LiteralPath $temporaryFull) {
        if (-not (Test-Path -LiteralPath $temporaryFull -PathType Container)) {
            throw 'Refusing to recursively clean a non-directory install temporary path.'
        }
        Remove-Item -LiteralPath $temporaryFull -Recurse -Force -ErrorAction Stop
    }
}

function Assert-AvailableInstallSpace {
    param([Parameter(Mandatory = $true)][long]$ArtifactBytes)

    $root = [System.IO.Path]::GetPathRoot($script:RepoRoot)
    try {
        $drive = New-Object System.IO.DriveInfo($root)
        if (-not $drive.IsReady) {
            throw 'not ready'
        }
        [long]$required = $ArtifactBytes + $script:MaximumIpaBytes + [long](128MB)
        if ($drive.AvailableFreeSpace -lt $required) {
            throw ('The repository volume needs at least {0:N0} free bytes for bounded artifact staging.' -f $required)
        }
    }
    catch {
        if ($_.Exception.Message -like 'The repository volume needs at least*') {
            throw
        }
        throw 'The free space on the repository volume could not be validated safely.'
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $sha = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read,
            65536,
            [System.IO.FileOptions]::SequentialScan
        )
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash($stream)
        return ([System.BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())
    }
    finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Assert-SafeZipEntry {
    param([Parameter(Mandatory = $true)]$Entry)

    $name = [string]$Entry.FullName
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 4096) {
        throw 'A ZIP entry has an empty or overlong path.'
    }
    if ($name.StartsWith('/') -or
        $name.Contains('//') -or
        $name -match '[\x00-\x1F\x7F<>:"\\|?*]') {
        throw 'A ZIP entry contains an unsafe Windows path.'
    }

    $isDirectory = $name.EndsWith('/')
    $normalized = $name.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'A ZIP entry has an invalid root directory path.'
    }
    foreach ($part in $normalized.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($part) -or
            $part -eq '.' -or
            $part -eq '..' -or
            $part.Length -gt 255 -or
            $part -cne $part.Trim() -or
            $part.EndsWith('.', [System.StringComparison]::Ordinal) -or
            $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw 'A ZIP entry contains a relative, reserved, trailing-dot/space, or overlong path component.'
        }
    }

    [long]$external = [int64]$Entry.ExternalAttributes
    if ($external -lt 0) { $external += 4294967296 }
    $unixType = (($external -shr 16) -band 0xF000)
    $dosAttributes = ($external -band 0xFFFF)
    if ($isDirectory) {
        if ([long]$Entry.Length -ne 0 -or ($unixType -ne 0 -and $unixType -ne 0x4000)) {
            throw 'A ZIP directory entry has an invalid file type or size.'
        }
    }
    else {
        if (($unixType -ne 0 -and $unixType -ne 0x8000) -or ($dosAttributes -band 0x10) -ne 0) {
            throw 'A ZIP file entry is not a regular file.'
        }
    }

    return [pscustomobject]@{
        Name = $name
        NormalizedName = $normalized
        IsDirectory = $isDirectory
    }
}

function Read-ZipEntryBounded {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][long]$MaximumBytes,
        [string]$DestinationPath,
        [switch]$CaptureBytes
    )

    [long]$declared = $Entry.Length
    if ($declared -lt 0 -or $declared -gt $MaximumBytes) {
        throw 'A ZIP entry exceeds its accepted uncompressed size limit.'
    }
    if ($CaptureBytes -and $declared -gt $script:MaximumInfoPlistBytes) {
        throw 'The captured Info.plist exceeds its accepted size limit.'
    }

    $input = $null
    $output = $null
    $memory = $null
    $sha = $null
    try {
        $input = $Entry.Open()
        if ($PSBoundParameters.ContainsKey('DestinationPath')) {
            if (Test-Path -LiteralPath $DestinationPath) {
                throw 'Refusing to overwrite a staged artifact file.'
            }
            $output = New-Object System.IO.FileStream(
                $DestinationPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None,
                65536,
                [System.IO.FileOptions]::SequentialScan
            )
        }
        if ($CaptureBytes) {
            $memory = New-Object System.IO.MemoryStream
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $buffer = New-Object byte[] 65536
        [long]$actual = 0
        while ($true) {
            [long]$remaining = $declared - $actual
            $readLength = if ($remaining -lt $buffer.Length) { [int]($remaining + 1) } else { $buffer.Length }
            $read = $input.Read($buffer, 0, $readLength)
            if ($read -eq 0) { break }
            if ($actual -gt ($declared - $read)) {
                throw 'A ZIP entry expanded beyond its declared or accepted size.'
            }
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
            if ($null -ne $output) { $output.Write($buffer, 0, $read) }
            if ($null -ne $memory) { $memory.Write($buffer, 0, $read) }
            $actual += $read
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        if ($actual -ne $declared) {
            throw 'A ZIP entry length does not match its declared size.'
        }
        if ($null -ne $output) { $output.Flush($true) }

        return [pscustomobject]@{
            Length = $actual
            Sha256 = ([System.BitConverter]::ToString($sha.Hash).Replace('-', '').ToLowerInvariant())
            Bytes = if ($null -ne $memory) { $memory.ToArray() } else { $null }
        }
    }
    finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $memory) { $memory.Dispose() }
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $input) { $input.Dispose() }
    }
}

function Read-OuterArtifactArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactZipPath,
        [string]$ExtractDirectory
    )

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ArtifactZipPath)
        $entries = @($archive.Entries | ForEach-Object { $_ })
        if ($entries.Count -ne 2) {
            throw 'The raw GitHub artifact ZIP must contain exactly the IPA and install manifest.'
        }

        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $result = @{}
        foreach ($entry in $entries) {
            $safe = Assert-SafeZipEntry -Entry $entry
            if (-not $seen.Add($safe.NormalizedName)) {
                throw 'The raw artifact ZIP contains duplicate or case-colliding paths.'
            }
            if ($safe.IsDirectory -or $safe.NormalizedName.Contains('/')) {
                throw 'The raw artifact ZIP files must be regular files at the archive root.'
            }
            if ($safe.NormalizedName -cne $script:IpaFile -and
                $safe.NormalizedName -cne $script:ManifestFile) {
                throw 'The raw artifact ZIP contains an unexpected file.'
            }
            [long]$limit = if ($safe.NormalizedName -ceq $script:IpaFile) {
                $script:MaximumIpaBytes
            }
            else {
                $script:MaximumManifestBytes
            }
            if ($safe.NormalizedName -ceq $script:IpaFile -and [long]$entry.Length -le 1KB) {
                throw 'The IPA in the raw artifact ZIP is too small to be valid.'
            }
            if ([long]$entry.CompressedLength -lt 0 -or
                [long]$entry.CompressedLength -gt (Get-Item -LiteralPath $ArtifactZipPath -Force).Length) {
                throw 'The raw artifact ZIP contains an invalid compressed entry length.'
            }

            $parameters = @{
                Entry = $entry
                MaximumBytes = $limit
            }
            if ($PSBoundParameters.ContainsKey('ExtractDirectory')) {
                $parameters.DestinationPath = Join-Path $ExtractDirectory $safe.NormalizedName
            }
            $result[$safe.NormalizedName] = Read-ZipEntryBounded @parameters
        }

        if (-not $result.ContainsKey($script:IpaFile) -or -not $result.ContainsKey($script:ManifestFile)) {
            throw 'The raw artifact ZIP is missing the IPA or install manifest.'
        }
        return [pscustomobject]@{
            Ipa = $result[$script:IpaFile]
            Manifest = $result[$script:ManifestFile]
        }
    }
    catch [System.IO.InvalidDataException] {
        throw 'The downloaded GitHub artifact is not a valid ZIP archive.'
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
}

function Read-StrictInstallManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Length -le 0 -or $item.Length -gt $script:MaximumManifestBytes) {
        throw 'The install manifest size is outside the accepted range.'
    }
    $bytes = [System.IO.File]::ReadAllBytes($item.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'The install manifest must be canonical UTF-8 without a BOM.'
    }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $encoding.GetString($bytes)
    }
    catch {
        throw 'The install manifest is not strict UTF-8.'
    }
    if ($text.Contains("`r") -or -not $text.EndsWith("`n")) {
        throw 'The install manifest is not in canonical jq -nS line format.'
    }

    $expectedKeys = @(
        'appBundleDirectory', 'artifactName', 'bundleDisplayName',
        'bundleIdentifier', 'commitSha', 'format', 'ipaFile',
        'ipaSha256', 'ipaSizeBytes', 'repository', 'repositoryId',
        'runAttempt', 'runId', 'schemaVersion', 'workflowPath'
    )
    $lines = $text.Substring(0, $text.Length - 1).Split("`n")
    if ($lines.Count -ne ($expectedKeys.Count + 2) -or $lines[0] -cne '{' -or $lines[$lines.Count - 1] -cne '}') {
        throw 'The install manifest does not have the exact canonical top-level schema.'
    }
    $rawValues = @{}
    for ($index = 0; $index -lt $expectedKeys.Count; $index++) {
        $key = $expectedKeys[$index]
        $line = $lines[$index + 1]
        $prefix = '  "' + $key + '": '
        $suffix = if ($index -lt ($expectedKeys.Count - 1)) { ',' } else { '' }
        if (-not $line.StartsWith($prefix, [System.StringComparison]::Ordinal) -or
            -not $line.EndsWith($suffix, [System.StringComparison]::Ordinal) -or
            $line.Length -le ($prefix.Length + $suffix.Length)) {
            throw 'The install manifest contains missing, reordered, duplicate, or non-canonical keys.'
        }
        $rawValues[$key] = $line.Substring($prefix.Length, $line.Length - $prefix.Length - $suffix.Length)
    }
    if ([string]$rawValues['schemaVersion'] -cne '1' -or
        [string]$rawValues['runAttempt'] -cnotmatch '^[1-9][0-9]*$' -or
        [string]$rawValues['ipaSizeBytes'] -cnotmatch '^[1-9][0-9]*$') {
        throw 'The install manifest contains an invalid numeric schema field.'
    }

    try {
        $manifest = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'The install manifest is not valid canonical JSON.'
    }
    $properties = @($manifest.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($properties.Count -ne $expectedKeys.Count) {
        throw 'The install manifest contains missing or duplicate properties.'
    }
    foreach ($key in $expectedKeys) {
        if ($properties -cnotcontains $key) {
            throw 'The install manifest contains an unexpected property set.'
        }
    }
    return $manifest
}

function Get-ManifestString {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = Get-RequiredProperty -Object $Manifest -Name $Name
    if ($value -isnot [string]) {
        throw "Install manifest property '$Name' must be a string."
    }
    return [string]$value
}

function Assert-InstallManifest {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$ExpectedIpaSha256,
        [Parameter(Mandatory = $true)][long]$ExpectedIpaBytes
    )

    $schemaVersion = ConvertTo-RequiredPositiveInt64 -Object $Manifest -Name 'schemaVersion'
    $runAttempt = ConvertTo-RequiredPositiveInt64 -Object $Manifest -Name 'runAttempt'
    $ipaSize = ConvertTo-RequiredPositiveInt64 -Object $Manifest -Name 'ipaSizeBytes'
    $repositoryId = Get-ManifestString -Manifest $Manifest -Name 'repositoryId'
    $runId = Get-ManifestString -Manifest $Manifest -Name 'runId'

    if ($schemaVersion -ne 1 -or
        (Get-ManifestString -Manifest $Manifest -Name 'format') -cne $script:ManifestFormat -or
        (Get-ManifestString -Manifest $Manifest -Name 'repository') -cne $Context.Repository -or
        $repositoryId -cne ([string]$Context.RepositoryId) -or
        (Get-ManifestString -Manifest $Manifest -Name 'commitSha') -cne $Context.CommitSha -or
        $runId -cne ([string]$Context.RunId) -or
        $runAttempt -ne $Context.RunAttempt -or
        (Get-ManifestString -Manifest $Manifest -Name 'workflowPath') -cne $script:WorkflowPath -or
        (Get-ManifestString -Manifest $Manifest -Name 'artifactName') -cne $script:ArtifactName -or
        (Get-ManifestString -Manifest $Manifest -Name 'ipaFile') -cne $script:IpaFile -or
        (Get-ManifestString -Manifest $Manifest -Name 'ipaSha256') -cne $ExpectedIpaSha256 -or
        $ipaSize -ne $ExpectedIpaBytes -or
        (Get-ManifestString -Manifest $Manifest -Name 'bundleIdentifier') -cne $script:BundleIdentifier -or
        (Get-ManifestString -Manifest $Manifest -Name 'bundleDisplayName') -cne $script:BundleDisplayName -or
        (Get-ManifestString -Manifest $Manifest -Name 'appBundleDirectory') -cne $script:AppBundleDirectory) {
        throw 'The install manifest does not match the exact repository, run, workflow, IPA, or NextStep app identity.'
    }
}

function Get-XmlPlistIdentity {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    try {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $encoding.GetString($Bytes)
    }
    catch {
        throw 'The packaged Info.plist is not strict UTF-8 XML.'
    }
    if (-not $text.TrimStart().StartsWith('<?xml', [System.StringComparison]::Ordinal) -or
        $text -match '(?i)<!ENTITY') {
        throw 'The packaged Info.plist is not the expected safe XML plist format.'
    }

    $memory = $null
    $reader = $null
    try {
        $memory = New-Object System.IO.MemoryStream(, $Bytes)
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
        $settings.XmlResolver = $null
        $settings.MaxCharactersInDocument = $script:MaximumInfoPlistBytes
        $settings.IgnoreComments = $true
        $settings.IgnoreWhitespace = $true
        $reader = [System.Xml.XmlReader]::Create($memory, $settings)
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.PreserveWhitespace = $false
        $document.Load($reader)

        $root = $document.DocumentElement
        if ($null -eq $root -or $root.Name -cne 'plist') {
            throw 'invalid plist root'
        }
        $elements = @($root.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
        if ($elements.Count -ne 1 -or $elements[0].Name -cne 'dict') {
            throw 'invalid plist dictionary'
        }
        $children = @($elements[0].ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
        if (($children.Count % 2) -ne 0) {
            throw 'invalid plist key/value sequence'
        }
        $values = @{}
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        for ($index = 0; $index -lt $children.Count; $index += 2) {
            if ($children[$index].Name -cne 'key') {
                throw 'invalid plist key node'
            }
            $key = [string]$children[$index].InnerText
            if (-not $seen.Add($key)) {
                throw 'duplicate plist key'
            }
            $values[$key] = $children[$index + 1]
        }
        if (-not $values.ContainsKey('CFBundleIdentifier') -or
            -not $values.ContainsKey('CFBundleDisplayName') -or
            $values['CFBundleIdentifier'].Name -cne 'string' -or
            $values['CFBundleDisplayName'].Name -cne 'string') {
            throw 'missing plist app identity'
        }
        return [pscustomobject]@{
            BundleIdentifier = [string]$values['CFBundleIdentifier'].InnerText
            BundleDisplayName = [string]$values['CFBundleDisplayName'].InnerText
        }
    }
    catch {
        throw 'The packaged Info.plist could not be validated as a safe XML plist.'
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $memory) { $memory.Dispose() }
    }
}

function Test-IpaArchive {
    param([Parameter(Mandatory = $true)][string]$IpaPath)

    $item = Get-Item -LiteralPath $IpaPath -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -le 1KB -or
        $item.Length -gt $script:MaximumIpaBytes) {
        throw 'The staged IPA is a reparse point or outside the accepted 2 GiB limit.'
    }

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($item.FullName)
        $entries = @($archive.Entries | ForEach-Object { $_ })
        if ($entries.Count -lt 1 -or $entries.Count -gt $script:MaximumInnerEntries) {
            throw 'The IPA contains an unsafe number of ZIP entries.'
        }

        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        [long]$declaredTotal = 0
        [long]$actualTotal = 0
        $infoBytes = $null
        $infoCount = 0
        foreach ($entry in $entries) {
            $safe = Assert-SafeZipEntry -Entry $entry
            if (-not $seen.Add($safe.NormalizedName)) {
                throw 'The IPA contains duplicate or case-colliding ZIP paths.'
            }
            [long]$length = $entry.Length
            if ($length -lt 0 -or $length -gt $script:MaximumIpaBytes -or
                $declaredTotal -gt ($script:MaximumInnerBytes - $length)) {
                throw 'The IPA exceeds the accepted 8 GiB inner archive limit.'
            }
            $declaredTotal += $length
            if ([long]$entry.CompressedLength -lt 0 -or [long]$entry.CompressedLength -gt $item.Length) {
                throw 'The IPA contains an invalid compressed entry length.'
            }

            if ($safe.NormalizedName -ceq 'Payload' -or
                $safe.NormalizedName -ceq ('Payload/' + $script:AppBundleDirectory)) {
                if (-not $safe.IsDirectory) {
                    throw 'Payload and the direct Notes.app entry must be directories when present.'
                }
            }
            elseif (-not $safe.NormalizedName.StartsWith(
                    'Payload/' + $script:AppBundleDirectory + '/',
                    [System.StringComparison]::Ordinal
                )) {
                throw 'Every IPA entry must be inside the single Payload/Notes.app bundle.'
            }

            if ($safe.IsDirectory) {
                continue
            }
            $isInfo = $safe.NormalizedName -ceq ('Payload/' + $script:AppBundleDirectory + '/Info.plist')
            $read = Read-ZipEntryBounded `
                -Entry $entry `
                -MaximumBytes $script:MaximumIpaBytes `
                -CaptureBytes:$isInfo
            $actualTotal += $read.Length
            if ($isInfo) {
                $infoCount++
                $infoBytes = $read.Bytes
            }
        }
        if ($actualTotal -ne $declaredTotal -or $actualTotal -gt $script:MaximumInnerBytes) {
            throw 'The IPA actual uncompressed size does not match its bounded declared size.'
        }
        if ($infoCount -ne 1 -or $null -eq $infoBytes -or $infoBytes.Length -le 0) {
            throw 'The IPA must contain exactly one direct Payload/Notes.app/Info.plist.'
        }
        $identity = Get-XmlPlistIdentity -Bytes $infoBytes
        if ($identity.BundleIdentifier -cne $script:BundleIdentifier -or
            $identity.BundleDisplayName -cne $script:BundleDisplayName) {
            throw 'The packaged Info.plist does not identify com.speci.localnotes as NextStep.'
        }
        return [pscustomobject]@{
            AppBundleDirectory = $script:AppBundleDirectory
            BundleIdentifier = $identity.BundleIdentifier
            BundleDisplayName = $identity.BundleDisplayName
            EntryCount = $entries.Count
            UncompressedBytes = $actualTotal
        }
    }
    catch [System.IO.InvalidDataException] {
        throw 'The staged IPA is not a valid ZIP archive.'
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
}

function Test-VerifiedInstallDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$DirectoryPath,
        [Parameter(Mandatory = $true)]$Context
    )

    [void](Assert-RepositoryLocalPath -Path $DirectoryPath)
    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        throw 'The verified install directory does not exist.'
    }
    $items = @(Get-ChildItem -LiteralPath $DirectoryPath -Force)
    if ($items.Count -ne 3 -or @($items | Where-Object { $_.PSIsContainer }).Count -ne 0) {
        throw 'The install directory must contain exactly artifact.zip, the IPA, and the manifest.'
    }
    $expectedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    [void]$expectedNames.Add($script:RawArtifactFile)
    [void]$expectedNames.Add($script:IpaFile)
    [void]$expectedNames.Add($script:ManifestFile)
    foreach ($item in $items) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not $expectedNames.Remove([string]$item.Name)) {
            throw 'The install directory contains a reparse point or unexpected file.'
        }
    }
    if ($expectedNames.Count -ne 0) {
        throw 'The install directory is missing an expected file.'
    }

    $artifactZip = Join-Path $DirectoryPath $script:RawArtifactFile
    $ipaPath = Join-Path $DirectoryPath $script:IpaFile
    $manifestPath = Join-Path $DirectoryPath $script:ManifestFile
    $artifactItem = Get-Item -LiteralPath $artifactZip -Force -ErrorAction Stop
    if ($artifactItem.Length -ne $Context.ArtifactSize -or
        (Get-FileSha256 -Path $artifactZip) -cne $Context.ArtifactDigestHex) {
        throw 'The retained raw artifact ZIP does not match the fresh GitHub API size and digest.'
    }

    $outer = Read-OuterArtifactArchive -ArtifactZipPath $artifactZip
    $ipaItem = Get-Item -LiteralPath $ipaPath -Force -ErrorAction Stop
    $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    $ipaHash = Get-FileSha256 -Path $ipaPath
    $manifestHash = Get-FileSha256 -Path $manifestPath
    if ($ipaItem.Length -ne $outer.Ipa.Length -or
        $ipaHash -cne $outer.Ipa.Sha256 -or
        $manifestItem.Length -ne $outer.Manifest.Length -or
        $manifestHash -cne $outer.Manifest.Sha256) {
        throw 'The extracted IPA or manifest does not match the retained raw artifact ZIP.'
    }

    $manifest = Read-StrictInstallManifest -Path $manifestPath
    Assert-InstallManifest `
        -Manifest $manifest `
        -Context $Context `
        -ExpectedIpaSha256 $ipaHash `
        -ExpectedIpaBytes $ipaItem.Length
    $ipaInfo = Test-IpaArchive -IpaPath $ipaPath
    return [pscustomobject]@{
        IPAPath = $ipaPath
        ManifestPath = $manifestPath
        ArtifactZipPath = $artifactZip
        SHA256 = $ipaHash
        IpaInfo = $ipaInfo
    }
}

function ConvertTo-ProcessArgumentText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Argument)

    if ($Argument.Length -gt 4096) {
        throw 'A process argument exceeded the accepted length limit.'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    [int]$backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            if ($backslashes -gt 0) {
                [void]$builder.Append([char]92, ($backslashes * 2))
            }
            [void]$builder.Append([char]92)
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append([char]92, $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]92, ($backslashes * 2))
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function ConvertTo-ProcessArgumentLine {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $encoded = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in $Arguments) {
        $encoded.Add((ConvertTo-ProcessArgumentText -Argument $argument)) | Out-Null
    }
    $line = $encoded.ToArray() -join ' '
    if ($line.Length -gt 30000) {
        throw 'The process command line exceeded the accepted Windows length limit.'
    }
    return $line
}

function Stop-BoundedChildProcess {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][int]$GraceMilliseconds
    )

    try {
        if (-not $Process.HasExited) {
            try { $Process.Kill() } catch { }
            try { [void]$Process.WaitForExit($GraceMilliseconds) } catch { }
        }
    }
    catch { }
}

function Invoke-BoundedBinaryProcessDownload {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][long]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [int]$TotalDeadlineMilliseconds = $script:DownloadTotalDeadlineMilliseconds,
        [int]$IdleDeadlineMilliseconds = $script:DownloadIdleDeadlineMilliseconds,
        [int]$TerminationGraceMilliseconds = $script:ProcessTerminationGraceMilliseconds
    )

    if ([string]::IsNullOrWhiteSpace($FileName) -or
        -not [System.IO.Path]::IsPathRooted($FileName) -or
        -not (Test-Path -LiteralPath $FileName -PathType Leaf)) {
        throw 'The binary download executable must be an existing absolute file path.'
    }
    if ($ExpectedBytes -le 0 -or $ExpectedBytes -gt $script:MaximumOuterBytes) {
        throw 'Refusing to start a binary download outside the accepted outer size limit.'
    }
    if ($TotalDeadlineMilliseconds -lt 100 -or $TotalDeadlineMilliseconds -gt (2 * 60 * 60 * 1000) -or
        $IdleDeadlineMilliseconds -lt 100 -or $IdleDeadlineMilliseconds -gt (5 * 60 * 1000) -or
        $TerminationGraceMilliseconds -lt 100 -or $TerminationGraceMilliseconds -gt 30000) {
        throw 'The binary download deadlines are outside their accepted bounded ranges.'
    }

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $FileName
    $start.Arguments = ConvertTo-ProcessArgumentLine -Arguments $Arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['GH_HOST'] = 'github.com'
    [void]$start.EnvironmentVariables.Remove('GH_ENTERPRISE_TOKEN')
    [void]$start.EnvironmentVariables.Remove('GITHUB_ENTERPRISE_TOKEN')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $output = $null
    $stdout = $null
    $stderr = $null
    $stderrTask = $null
    $started = $false
    $destinationCreated = $false
    $succeeded = $false
    [long]$written = 0
    $totalWatch = New-Object System.Diagnostics.Stopwatch
    $idleWatch = New-Object System.Diagnostics.Stopwatch
    try {
        $output = New-Object System.IO.FileStream(
            $DestinationPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            65536,
            [System.IO.FileOptions]::SequentialScan
        )
        $destinationCreated = $true
        if (-not $process.Start()) {
            throw 'The binary download process could not be started.'
        }
        $started = $true
        $totalWatch.Start()
        $idleWatch.Start()
        $stdout = $process.StandardOutput.BaseStream
        $stderr = $process.StandardError.BaseStream
        $stderrTask = $stderr.CopyToAsync([System.IO.Stream]::Null, 65536)

        $buffer = New-Object byte[] 65536
        while ($true) {
            [long]$remaining = $ExpectedBytes - $written
            $readLength = if ($remaining -lt $buffer.Length) { [int]($remaining + 1) } else { $buffer.Length }
            $readTask = $stdout.ReadAsync($buffer, 0, $readLength)
            while (-not $readTask.IsCompleted) {
                if ($totalWatch.ElapsedMilliseconds -ge $TotalDeadlineMilliseconds) {
                    Stop-BoundedChildProcess -Process $process -GraceMilliseconds $TerminationGraceMilliseconds
                    throw 'The binary download exceeded its total deadline and was stopped.'
                }
                if ($idleWatch.ElapsedMilliseconds -ge $IdleDeadlineMilliseconds) {
                    Stop-BoundedChildProcess -Process $process -GraceMilliseconds $TerminationGraceMilliseconds
                    throw 'The binary download made no progress before its idle deadline and was stopped.'
                }
                try { [void]$readTask.Wait(50) } catch [System.AggregateException] { break }
            }
            try {
                $read = ($readTask.GetAwaiter()).GetResult()
            }
            catch {
                throw 'The binary download output stream failed before completion.'
            }
            if ($totalWatch.ElapsedMilliseconds -ge $TotalDeadlineMilliseconds) {
                Stop-BoundedChildProcess -Process $process -GraceMilliseconds $TerminationGraceMilliseconds
                throw 'The binary download exceeded its total deadline and was stopped.'
            }
            if ($idleWatch.ElapsedMilliseconds -ge $IdleDeadlineMilliseconds) {
                Stop-BoundedChildProcess -Process $process -GraceMilliseconds $TerminationGraceMilliseconds
                throw 'The binary download made no progress before its idle deadline and was stopped.'
            }
            if ($read -eq 0) { break }
            if ($written -gt ($ExpectedBytes - $read)) {
                Stop-BoundedChildProcess -Process $process -GraceMilliseconds $TerminationGraceMilliseconds
                throw 'The artifact byte stream exceeded the API size and was stopped before writing excess bytes.'
            }
            $output.Write($buffer, 0, $read)
            $written += $read
            $idleWatch.Restart()
        }

        while (-not $process.HasExited) {
            if ($totalWatch.ElapsedMilliseconds -ge $TotalDeadlineMilliseconds) {
                Stop-BoundedChildProcess -Process $process -GraceMilliseconds $TerminationGraceMilliseconds
                throw 'The binary download process exceeded its total deadline after closing output.'
            }
            if ($idleWatch.ElapsedMilliseconds -ge $IdleDeadlineMilliseconds) {
                Stop-BoundedChildProcess -Process $process -GraceMilliseconds $TerminationGraceMilliseconds
                throw 'The binary download process remained alive past its idle deadline after closing output.'
            }
            [void]$process.WaitForExit(50)
        }

        while ($null -ne $stderrTask -and -not $stderrTask.IsCompleted) {
            if ($totalWatch.ElapsedMilliseconds -ge $TotalDeadlineMilliseconds) {
                throw 'The binary download error stream did not close before the total deadline.'
            }
            try { [void]$stderrTask.Wait(50) } catch [System.AggregateException] { break }
        }
        if ($null -ne $stderrTask) {
            try { [void](($stderrTask.GetAwaiter()).GetResult()) } catch { throw 'The binary download error stream failed to drain.' }
        }
        if ($totalWatch.ElapsedMilliseconds -ge $TotalDeadlineMilliseconds) {
            throw 'The binary download exceeded its total deadline before final verification.'
        }
        if ($process.ExitCode -ne 0) {
            throw 'The binary download process returned a failure exit code.'
        }
        if ($written -ne $ExpectedBytes) {
            throw 'The artifact byte stream did not match the exact API size.'
        }
        $output.Flush($true)
        $output.Dispose()
        $output = $null
        $succeeded = $true
    }
    finally {
        $totalWatch.Stop()
        $idleWatch.Stop()
        if ($started) {
            Stop-BoundedChildProcess -Process $process -GraceMilliseconds $TerminationGraceMilliseconds
        }
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $stdout) { $stdout.Dispose() }
        if ($null -ne $stderr) { $stderr.Dispose() }
        $process.Dispose()
        if ($destinationCreated -and -not $succeeded -and (Test-Path -LiteralPath $DestinationPath)) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-GhArtifactDownload {
    param(
        [Parameter(Mandatory = $true)][string]$RepositorySlug,
        [Parameter(Mandatory = $true)][long]$ArtifactId,
        [Parameter(Mandatory = $true)][long]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if ($RepositorySlug -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $ArtifactId -le 0) {
        throw 'The artifact download repository or artifact ID is invalid.'
    }
    if ($ExpectedBytes -le 0 -or $ExpectedBytes -gt $script:MaximumOuterBytes) {
        throw 'Refusing to start an artifact download outside the accepted outer size limit.'
    }
    $endpoint = 'repos/{0}/actions/artifacts/{1}/zip' -f $RepositorySlug, $ArtifactId
    $arguments = @(New-GithubComApiArguments -Arguments @(
        'api', '--method', 'GET',
        '-H', 'Accept:application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version:2026-03-10',
        $endpoint
    ))
    Invoke-BoundedBinaryProcessDownload `
        -FileName $script:Gh.Source `
        -Arguments $arguments `
        -ExpectedBytes $ExpectedBytes `
        -DestinationPath $DestinationPath
}

function New-InstallResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)]$Context,
        $VerifiedDirectory
    )

    return [pscustomobject]@{
        Status = $Status
        SourceRepository = $Context.SourceRepository
        SourceCommitSha = $Context.SourceCommitSha
        SourceTreeSha = $Context.SourceTreeSha
        Repository = $Context.Repository
        RepositoryId = $Context.RepositoryId
        CommitSha = $Context.CommitSha
        MirrorCommitSha = $Context.CommitSha
        MirrorBranch = $Context.MirrorBranch
        WorkflowPath = $script:WorkflowPath
        RunId = $Context.RunId
        RunAttempt = $Context.RunAttempt
        RunUrl = $Context.RunUrl
        ArtifactId = $Context.ArtifactId
        ArtifactName = $script:ArtifactName
        ArtifactDigest = ('sha256:' + $Context.ArtifactDigestHex)
        ArtifactSizeBytes = $Context.ArtifactSize
        IPAPath = if ($null -ne $VerifiedDirectory) { $VerifiedDirectory.IPAPath } else { $null }
        ManifestPath = if ($null -ne $VerifiedDirectory) { $VerifiedDirectory.ManifestPath } else { $null }
        ArtifactZipPath = if ($null -ne $VerifiedDirectory) { $VerifiedDirectory.ArtifactZipPath } else { $null }
        SHA256 = if ($null -ne $VerifiedDirectory) { $VerifiedDirectory.SHA256 } else { $null }
        BundleIdentifier = $script:BundleIdentifier
        DisplayName = $script:BundleDisplayName
        AppBundleDirectory = $script:AppBundleDirectory
    }
}

$explicitCommit = $PSBoundParameters.ContainsKey('Commit')
$explicitMirrorCommit = $PSBoundParameters.ContainsKey('MirrorCommit')
$explicitRunId = $PSBoundParameters.ContainsKey('RunId')
$topLevel = Invoke-GitText -Arguments @('rev-parse', '--show-toplevel')
if (-not [string]::Equals(
        [System.IO.Path]::GetFullPath($topLevel).TrimEnd('\'),
        $script:RepoRoot.TrimEnd('\'),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The installer script must run from its own repository worktree.'
}
$headSha = Invoke-GitText -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')
if ($headSha -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Git did not return a full lowercase 40-character HEAD commit SHA.'
}
$dirty = -not [string]::IsNullOrWhiteSpace(
    (Invoke-GitText -Arguments @('status', '--porcelain=v1', '--untracked-files=all'))
)

if ($AllowDirty) {
    if (-not $explicitCommit -or $Commit -cnotmatch '^[0-9a-f]{40}$' -or
        -not $explicitMirrorCommit -or $MirrorCommit -cnotmatch '^[0-9a-f]{40}$' -or
        -not $explicitRunId -or $RunId -le 0) {
        throw '-AllowDirty requires explicit full lowercase 40-character -Commit and -MirrorCommit SHAs plus a positive explicit -RunId, for DryRun and real downloads.'
    }
}
elseif ($dirty) {
    throw 'The working tree is not clean. Commit or set aside changes, or use -AllowDirty with explicit full -Commit, -MirrorCommit, and -RunId values.'
}

$sourceCommitSha = if ($explicitCommit) { $Commit } else { $headSha }
if ($sourceCommitSha -cnotmatch '^[0-9a-f]{40}$' -or $sourceCommitSha -cne $headSha) {
    throw 'The selected commit must be the exact full lowercase SHA of the current HEAD.'
}
if ($explicitMirrorCommit -and $MirrorCommit -cnotmatch '^[0-9a-f]{40}$') {
    throw '-MirrorCommit must be a full lowercase 40-character mirror snapshot SHA.'
}
if ($explicitRunId -and $RunId -le 0) {
    throw '-RunId must be a positive workflow database ID.'
}

$sourceTreeSha = Invoke-GitText -Arguments @('rev-parse', ($sourceCommitSha + '^{tree}'))
if ($sourceTreeSha -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Git did not return a canonical tree identifier for the exact local HEAD.'
}
$configuration = Get-CommittedCIMirrorConfiguration -SourceCommitSha $sourceCommitSha
$sourceRepository = [string]$configuration.sourceRepository
$mirrorRepository = [string]$configuration.mirrorRepository
$mirrorBranch = [string]$configuration.mirrorBranch
$originRepository = Get-OriginRepositorySlug
if ($originRepository -cne $sourceRepository) {
    throw 'The local origin is not the authoritative private repository configured by this source commit.'
}
$sourceMetadata = Invoke-GhJson -Arguments @(
    'api', '--method', 'GET', ('repos/{0}' -f $sourceRepository)
)
Assert-SourceRepositoryMetadata -Metadata $sourceMetadata -ExpectedRepository $sourceRepository

$requestedRepository = Get-RequestedRepositorySlug `
    -RequestedRepository $Repository `
    -ConfiguredRepository $mirrorRepository
$canonicalRepository = Get-CanonicalRepository -RequestedRepository $requestedRepository
Assert-MirrorRepositoryMetadata `
    -Metadata $canonicalRepository.Metadata `
    -ExpectedRepository $mirrorRepository `
    -ExpectedBranch $mirrorBranch
$snapshot = Get-VerifiedMirrorSnapshot `
    -RepositorySlug $canonicalRepository.Name `
    -Branch $mirrorBranch `
    -SourceTreeSha $sourceTreeSha `
    -RequestedMirrorCommit $(if ($explicitMirrorCommit) { $MirrorCommit } else { '' })
$mirrorCommitSha = [string]$snapshot.CommitSha
$workflow = Get-WorkflowMetadata -RepositorySlug $canonicalRepository.Name
$run = Get-ExactRunMetadata `
    -RepositorySlug $canonicalRepository.Name `
    -RepositoryId $canonicalRepository.Id `
    -WorkflowId $workflow.Id `
    -CommitSha $mirrorCommitSha `
    -Branch $mirrorBranch `
    -RequestedRunId $(if ($explicitRunId) { $RunId } else { 0 })
$artifact = Get-ExactArtifactMetadata `
    -RepositorySlug $canonicalRepository.Name `
    -RepositoryId $canonicalRepository.Id `
    -CommitSha $mirrorCommitSha `
    -RunId $run.Id

$context = [pscustomobject]@{
    SourceRepository = $sourceRepository
    SourceCommitSha = $sourceCommitSha
    SourceTreeSha = $sourceTreeSha
    Repository = $canonicalRepository.Name
    RepositoryId = $canonicalRepository.Id
    CommitSha = $mirrorCommitSha
    MirrorBranch = $mirrorBranch
    RunId = $run.Id
    RunAttempt = $run.Attempt
    RunUrl = $run.Url
    ArtifactId = $artifact.Id
    ArtifactSize = $artifact.Size
    ArtifactDigestHex = $artifact.DigestHex
}

if ($DryRun) {
    New-InstallResult -Status 'Planned' -Context $context -VerifiedDirectory $null
    return
}

[void](Assert-RepositoryLocalPath -Path $script:InstallRoot)
[void][System.IO.Directory]::CreateDirectory($script:InstallRoot)
[void](Assert-RepositoryLocalPath -Path $script:InstallRoot)
$cacheKey = Get-InstallCacheKey -Context $context
$destination = [System.IO.Path]::GetFullPath((Join-Path $script:InstallRoot $cacheKey))
[void](Assert-RepositoryLocalPath -Path $destination)

if (Test-Path -LiteralPath $destination) {
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        throw 'The existing provenance cache path is not a directory and was left untouched.'
    }
    try {
        $verifiedExisting = Test-VerifiedInstallDirectory -DirectoryPath $destination -Context $context
    }
    catch {
        throw 'The existing provenance cache failed fresh API, raw ZIP, manifest, IPA, or app identity verification and was left untouched.'
    }
    New-InstallResult -Status 'Reused' -Context $context -VerifiedDirectory $verifiedExisting
    return
}

Assert-AvailableInstallSpace -ArtifactBytes $artifact.Size
$temporary = Join-Path $script:InstallRoot ('.tmp-' + [guid]::NewGuid().ToString('N'))
[void](Assert-RepositoryLocalPath -Path $temporary)
[void][System.IO.Directory]::CreateDirectory($temporary)

try {
    $artifactZip = Join-Path $temporary $script:RawArtifactFile
    Invoke-GhArtifactDownload `
        -RepositorySlug $canonicalRepository.Name `
        -ArtifactId $artifact.Id `
        -ExpectedBytes $artifact.Size `
        -DestinationPath $artifactZip
    $downloaded = Get-Item -LiteralPath $artifactZip -Force -ErrorAction Stop
    if ($downloaded.Length -ne $artifact.Size -or
        (Get-FileSha256 -Path $artifactZip) -cne $artifact.DigestHex) {
        throw 'The downloaded artifact ZIP failed the API size or SHA-256 digest check.'
    }

    [void](Read-OuterArtifactArchive -ArtifactZipPath $artifactZip -ExtractDirectory $temporary)
    $verifiedBeforePublish = Test-VerifiedInstallDirectory -DirectoryPath $temporary -Context $context

    if (Test-Path -LiteralPath $destination) {
        throw 'The destination appeared during verification; refusing to merge or replace it.'
    }
    [void](Assert-RepositoryLocalPath -Path $temporary)
    [void](Assert-RepositoryLocalPath -Path $destination)
    [System.IO.Directory]::Move($temporary, $destination)
    $temporary = $null

    [void](Assert-RepositoryLocalPath -Path $destination)
    $verifiedAfterPublish = Test-VerifiedInstallDirectory -DirectoryPath $destination -Context $context
    New-InstallResult -Status 'Verified' -Context $context -VerifiedDirectory $verifiedAfterPublish
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($temporary) -and (Test-Path -LiteralPath $temporary)) {
        Remove-SafeTemporaryDirectory -TemporaryPath $temporary
    }
}
