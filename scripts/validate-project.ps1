$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$projectFile = Join-Path $repoRoot "project.yml"
$infoPlist = Join-Path $repoRoot "Config\NotesApp-Info.plist"
$workflowFile = Join-Path $repoRoot ".github\workflows\ios-ci.yml"
$appIcon = Join-Path $repoRoot "Sources\NotesApp\Resources\Assets.xcassets\AppIcon.appiconset\AppIcon-1024.png"
$appIconContents = Join-Path $repoRoot "Sources\NotesApp\Resources\Assets.xcassets\AppIcon.appiconset\Contents.json"
$stringsCatalog = Join-Path $repoRoot "Sources\NotesApp\Resources\Localizable.xcstrings"
$privacyManifest = Join-Path $repoRoot "Sources\NotesApp\Resources\PrivacyInfo.xcprivacy"

if (-not (Test-Path $projectFile -PathType Leaf)) {
    throw "Missing project.yml."
}
if (-not (Test-Path $infoPlist -PathType Leaf)) {
    throw "Missing Config/NotesApp-Info.plist."
}
if (-not (Test-Path $workflowFile -PathType Leaf)) {
    throw "Missing .github/workflows/ios-ci.yml."
}
foreach ($requiredFile in @($appIcon, $appIconContents, $stringsCatalog, $privacyManifest)) {
    if (-not (Test-Path $requiredFile -PathType Leaf)) {
        throw "Missing required resource '$requiredFile'."
    }
}

$project = Get-Content -Raw $projectFile
$plist = Get-Content -Raw $infoPlist
$workflow = Get-Content -Raw $workflowFile

function Get-WorkflowStepBlock {
    param([Parameter(Mandatory = $true)][string]$Name)

    $escapedName = [System.Text.RegularExpressions.Regex]::Escape($Name)
    $pattern = '(?ms)^      - name: ' + $escapedName + '\r?\n.*?(?=^      - name: |\z)'
    $matches = [System.Text.RegularExpressions.Regex]::Matches($workflow, $pattern)
    if ($matches.Count -ne 1) {
        throw "Workflow must contain exactly one '$Name' step."
    }
    return $matches[0].Value
}

function Assert-WorkflowStepValues {
    param(
        [Parameter(Mandatory = $true)][string]$StepName,
        [Parameter(Mandatory = $true)][string]$StepBlock,
        [Parameter(Mandatory = $true)][string[]]$Values
    )

    foreach ($value in $Values) {
        $foundOnActiveLine = $false
        foreach ($line in ($StepBlock -split '\r?\n')) {
            if (-not $line.TrimStart().StartsWith('#', [System.StringComparison]::Ordinal) -and
                $line.Contains($value)) {
                $foundOnActiveLine = $true
                break
            }
        }
        if (-not $foundOnActiveLine) {
            throw "Workflow step '$StepName' is missing required value '$value'."
        }
    }
}

$requiredProjectValues = @(
    "  NotesCore:",
    "  NotesServices:",
    "  NotesApp:",
    "  NextStepAcademic:",
    "  NextStepDomain:",
    "  NextStepGrounding:",
    "  NextStepPlanning:",
    "  NextStepSync:",
    "  NextStepDesignSystem:",
    "  NotesCoreTests:",
    "  NotesServicesTests:",
    "  NotesAppTests:",
    "  NextStepAcademicTests:",
    "  NextStepDomainTests:",
    "  NextStepGroundingTests:",
    "  NextStepPlanningTests:",
    "  NextStepSyncTests:",
    "  NextStepDesignSystemTests:",
    "  NotesAppUITests:",
    'SWIFT_VERSION: "6.0"',
    'deploymentTarget: "18.0"',
    'TARGETED_DEVICE_FAMILY: "1,2"',
    'SUPPORTED_PLATFORMS: "iphoneos iphonesimulator"',
    "PRODUCT_BUNDLE_IDENTIFIER: com.speci.localnotes",
    "PRODUCT_NAME: Notes",
    "path: Sources/NotesApp",
    "path: Sources/NextStepAcademic",
    "path: Sources/NextStepDomain",
    "path: Sources/NextStepGrounding",
    "path: Sources/NextStepPlanning",
    "path: Sources/NextStepSync",
    "path: Sources/NextStepDesignSystem",
    "path: Tests/NextStepAcademicTests",
    "path: Tests/NextStepDomainTests",
    "path: Tests/NextStepGroundingTests",
    "path: Tests/NextStepPlanningTests",
    "path: Tests/NextStepSyncTests",
    "path: Tests/NextStepDesignSystemTests",
    "path: Tests/NotesAppUITests"
)

foreach ($value in $requiredProjectValues) {
    if (-not $project.Contains($value)) {
        throw "Missing required value '$value' in project.yml."
    }
}

$requiredInfoKeys = @(
    "NSMicrophoneUsageDescription",
    "NSCameraUsageDescription",
    "NSPhotoLibraryUsageDescription",
    "NSPhotoLibraryAddUsageDescription",
    "NSSpeechRecognitionUsageDescription",
    "NSLocalNetworkUsageDescription",
    "UIApplicationSupportsMultipleScenes",
    "UIBackgroundModes",
    "UTExportedTypeDeclarations"
)

foreach ($key in $requiredInfoKeys) {
    if (-not $plist.Contains("<key>$key</key>")) {
        throw "Missing required Info.plist key '$key'."
    }
}

foreach ($typeIdentifier in @("com.speci.localnotes.notepkg", "com.adobe.pdf", "public.image")) {
    if (-not $plist.Contains("<string>$typeIdentifier</string>")) {
        throw "Missing document type '$typeIdentifier'."
    }
}

if ($plist -notmatch '<key>CFBundleDisplayName</key>\s*<string>NextStep</string>') {
    throw "CFBundleDisplayName must be exactly 'NextStep'."
}

$requiredWorkflowValues = @(
    "runs-on: macos-26",
    "bash scripts/generate-project.sh",
    "-destination 'generic/platform=iOS'",
    "CODE_SIGNING_ALLOWED=NO",
    "xcrun xcresulttool export attachments",
    "name: NextStep-iPad-homepage",
    "NextStep-iPad-Home.png",
    "NextStep-responsive-previews",
    "NextStep-beta-native-previews",
    "testNextStepBetaNativeFlow",
    "testNextStepBetaSourceFactReviewFlow",
    "testCompactLegacyLibraryCanOpenQuickNote",
    "Light-Guided-Source",
    'NextStep-Beta-$device-$screen.png',
    "IPHONE_SIMULATOR_UDID",
    "Validate Windows contract preview",
    "node PreviewWeb/tests/state.smoke.mjs",
    "compression-level: 0",
    "retention-days: 7",
    'FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: "true"'
)

foreach ($value in $requiredWorkflowValues) {
    if (-not $workflow.Contains($value)) {
        throw "Missing required CI value '$value'."
    }
}

$checkoutStepName = 'Check out repository'
$bindStepName = 'Bind build to source commit'
$packageStepName = 'Package unsigned IPA'
$manifestStepName = 'Generate unsigned IPA install manifest'
$uploadStepName = 'Upload unsigned IPA'
$unitTestStepName = 'Run unit and integration tests'
$checkoutStep = Get-WorkflowStepBlock -Name $checkoutStepName
$bindStep = Get-WorkflowStepBlock -Name $bindStepName
$packageStep = Get-WorkflowStepBlock -Name $packageStepName
$manifestStep = Get-WorkflowStepBlock -Name $manifestStepName
$uploadStep = Get-WorkflowStepBlock -Name $uploadStepName
$unitTestStep = Get-WorkflowStepBlock -Name $unitTestStepName

$checkoutIndex = $workflow.IndexOf("      - name: $checkoutStepName", [System.StringComparison]::Ordinal)
$bindIndex = $workflow.IndexOf("      - name: $bindStepName", [System.StringComparison]::Ordinal)
$packageIndex = $workflow.IndexOf("      - name: $packageStepName", [System.StringComparison]::Ordinal)
$manifestIndex = $workflow.IndexOf("      - name: $manifestStepName", [System.StringComparison]::Ordinal)
$uploadIndex = $workflow.IndexOf("      - name: $uploadStepName", [System.StringComparison]::Ordinal)
if ($checkoutIndex -lt 0 -or $bindIndex -le $checkoutIndex -or $packageIndex -le $bindIndex -or
    $manifestIndex -le $packageIndex -or $uploadIndex -le $manifestIndex) {
    throw 'Unsigned IPA package, manifest, and upload steps must remain in that order.'
}

Assert-WorkflowStepValues -StepName $checkoutStepName -StepBlock $checkoutStep -Values @(
    'actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0',
    'ref: ${{ github.event.pull_request.head.sha || github.sha }}',
    'persist-credentials: false'
)

Assert-WorkflowStepValues -StepName $bindStepName -StepBlock $bindStep -Values @(
    'case "$GITHUB_EVENT_NAME" in',
    'pull_request)',
    'push|workflow_dispatch)',
    '.pull_request.head.repo.full_name // empty',
    '.pull_request.head.sha // empty',
    '[[ "$expected_repository" == "$GITHUB_REPOSITORY" ]]',
    'built_commit="$(git rev-parse HEAD)"',
    'echo "BUILD_COMMIT_SHA=$built_commit" >> "$GITHUB_ENV"'
)

Assert-WorkflowStepValues -StepName $packageStepName -StepBlock $packageStep -Values @(
    'artifact_root="$RUNNER_TEMP/NotesUnsignedArtifact"',
    'plutil -convert xml1 "$package_root/Payload/Notes.app/Info.plist"',
    '"$artifact_root/Notes-unsigned.ipa"'
)

Assert-WorkflowStepValues -StepName $manifestStepName -StepBlock $manifestStep -Values @(
    "readonly workflow_path='.github/workflows/ios-ci.yml'",
    "readonly artifact_name='Notes-unsigned-ipa'",
    "readonly ipa_file='Notes-unsigned.ipa'",
    "readonly app_bundle_directory='Notes.app'",
    "readonly expected_bundle_identifier='com.speci.localnotes'",
    "readonly expected_display_name='NextStep'",
    'plutil -extract CFBundleIdentifier raw',
    'plutil -extract CFBundleDisplayName raw',
    '[[ "$BUILD_COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]',
    '[[ "$(git rev-parse HEAD)" == "$BUILD_COMMIT_SHA" ]]',
    '--arg commitSha "$BUILD_COMMIT_SHA"',
    'shasum -a 256',
    "stat -f '%z'",
    'jq -nS',
    'jq -e',
    "--arg format 'nextstep-unsigned-ipa'",
    '--argjson schemaVersion 1',
    'install-manifest.json',
    'appBundleDirectory:',
    'artifactName:',
    'bundleDisplayName:',
    'bundleIdentifier:',
    'commitSha:',
    'format:',
    'ipaFile:',
    'ipaSha256:',
    'ipaSizeBytes:',
    'repository:',
    'repositoryId:',
    'runAttempt:',
    'runId:',
    'schemaVersion:',
    'workflowPath:',
    'mv "$manifest_temporary" "$manifest_path"',
    'shopt -s dotglob nullglob',
    'artifact_entries=("$artifact_root"/*)',
    '[[ "${#artifact_entries[@]}" == ''2'' ]]',
    '[[ -f "$artifact_entry" && ! -L "$artifact_entry" ]]'
)
if ($manifestStep.Contains('$GITHUB_SHA')) {
    throw "Workflow step '$manifestStepName' must bind the manifest to BUILD_COMMIT_SHA, not the pull-request merge SHA."
}

Assert-WorkflowStepValues -StepName $uploadStepName -StepBlock $uploadStep -Values @(
    'uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1',
    'name: Notes-unsigned-ipa',
    'path: |',
    '${{ runner.temp }}/NotesUnsignedArtifact/Notes-unsigned.ipa',
    '${{ runner.temp }}/NotesUnsignedArtifact/install-manifest.json',
    'if-no-files-found: error',
    'retention-days: 7',
    'compression-level: 0'
)

Assert-WorkflowStepValues -StepName $unitTestStepName -StepBlock $unitTestStep -Values @(
    '-only-testing:NotesCoreTests',
    '-only-testing:NotesServicesTests',
    '-only-testing:NotesAppTests',
    '-only-testing:NextStepAcademicTests',
    '-only-testing:NextStepDomainTests',
    '-only-testing:NextStepGroundingTests',
    '-only-testing:NextStepPlanningTests',
    '-only-testing:NextStepSyncTests',
    '-only-testing:NextStepDesignSystemTests'
)

try {
    [xml](Get-Content -Raw $infoPlist) | Out-Null
    [xml](Get-Content -Raw $privacyManifest) | Out-Null
}
catch {
    throw "An app plist resource is not valid XML: $($_.Exception.Message)"
}

try {
    Get-Content -Raw -Encoding utf8 $stringsCatalog | ConvertFrom-Json | Out-Null
    $iconCatalog = Get-Content -Raw -Encoding utf8 $appIconContents | ConvertFrom-Json
    if ($iconCatalog.images[0].filename -ne "AppIcon-1024.png") {
        throw "AppIcon Contents.json does not reference AppIcon-1024.png."
    }
}
catch {
    throw "An app JSON resource is invalid: $($_.Exception.Message)"
}

Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Image]::FromFile($appIcon)
try {
    if ($image.Width -ne 1024 -or $image.Height -ne 1024) {
        throw "App icon must be exactly 1024x1024 pixels."
    }
    if ($image.PixelFormat.ToString().Contains("Alpha") -or $image.PixelFormat.ToString().Contains("Argb")) {
        throw "App icon must not contain an alpha channel."
    }
}
finally {
    $image.Dispose()
}

if (Get-Command node -ErrorAction SilentlyContinue) {
    & node (Join-Path $repoRoot "scripts\validate-ai-schemas.mjs")
    if ($LASTEXITCODE -ne 0) { throw "AI schema validation failed." }
    & node (Join-Path $repoRoot "scripts\validate-localization.mjs")
    if ($LASTEXITCODE -ne 0) { throw "Localization coverage validation failed." }
}

Write-Host "Project configuration is valid."
