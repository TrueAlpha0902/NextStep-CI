#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="$repo_root/project.yml"
info_plist="$repo_root/Config/NotesApp-Info.plist"
workflow_file="$repo_root/.github/workflows/ios-ci.yml"
app_icon="$repo_root/Sources/NotesApp/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
strings_catalog="$repo_root/Sources/NotesApp/Resources/Localizable.xcstrings"
privacy_manifest="$repo_root/Sources/NotesApp/Resources/PrivacyInfo.xcprivacy"

require_literal() {
  local file="$1"
  local literal="$2"
  if ! grep -Fq -- "$literal" "$file"; then
    echo "Missing required value '$literal' in $file" >&2
    exit 1
  fi
}

get_workflow_step_block() {
  local name="$1"
  local header="      - name: $name"
  local count
  count="$(grep -Fxc -- "$header" "$workflow_file")"
  if [[ "$count" != "1" ]]; then
    echo "Workflow must contain exactly one '$name' step." >&2
    exit 1
  fi

  awk -v header="$header" '
    $0 == header { capture = 1 }
    capture && $0 != header && index($0, "      - name: ") == 1 { exit }
    capture { print }
  ' "$workflow_file"
}

require_step_literal() {
  local step_name="$1"
  local step_block="$2"
  local literal="$3"
  if ! awk -v literal="$literal" '
    {
      active = $0
      sub(/^[[:space:]]*/, "", active)
      if (active !~ /^#/ && index($0, literal) > 0) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' <<< "$step_block"; then
    echo "Workflow step '$step_name' is missing required value '$literal'." >&2
    exit 1
  fi
}

test -f "$project_file"
test -f "$info_plist"
test -f "$workflow_file"
test -f "$app_icon"
test -f "$strings_catalog"
test -f "$privacy_manifest"

for target in NotesCore NotesServices NotesApp NextStepAcademic NextStepDomain NextStepGrounding NextStepPlanning NextStepSync NextStepDesignSystem NotesCoreTests NotesServicesTests NotesAppTests NextStepAcademicTests NextStepDomainTests NextStepGroundingTests NextStepPlanningTests NextStepSyncTests NextStepDesignSystemTests NotesAppUITests; do
  require_literal "$project_file" "  $target:"
done

require_literal "$project_file" 'SWIFT_VERSION: "6.0"'
require_literal "$project_file" 'deploymentTarget: "18.0"'
require_literal "$project_file" 'TARGETED_DEVICE_FAMILY: "1,2"'
require_literal "$project_file" 'SUPPORTED_PLATFORMS: "iphoneos iphonesimulator"'
require_literal "$project_file" 'PRODUCT_BUNDLE_IDENTIFIER: com.speci.localnotes'
require_literal "$project_file" 'PRODUCT_NAME: Notes'
require_literal "$project_file" 'path: Sources/NotesApp'
require_literal "$project_file" 'path: Sources/NextStepAcademic'
require_literal "$project_file" 'path: Sources/NextStepDomain'
require_literal "$project_file" 'path: Sources/NextStepGrounding'
require_literal "$project_file" 'path: Sources/NextStepPlanning'
require_literal "$project_file" 'path: Sources/NextStepSync'
require_literal "$project_file" 'path: Sources/NextStepDesignSystem'
require_literal "$project_file" 'path: Tests/NextStepAcademicTests'
require_literal "$project_file" 'path: Tests/NextStepDomainTests'
require_literal "$project_file" 'path: Tests/NextStepGroundingTests'
require_literal "$project_file" 'path: Tests/NextStepPlanningTests'
require_literal "$project_file" 'path: Tests/NextStepSyncTests'
require_literal "$project_file" 'path: Tests/NextStepDesignSystemTests'
require_literal "$project_file" 'path: Tests/NotesAppUITests'

for key in \
  NSMicrophoneUsageDescription \
  NSCameraUsageDescription \
  NSPhotoLibraryUsageDescription \
  NSPhotoLibraryAddUsageDescription \
  NSSpeechRecognitionUsageDescription \
  NSLocalNetworkUsageDescription \
  UIApplicationSupportsMultipleScenes \
  UIBackgroundModes \
  UTExportedTypeDeclarations; do
  require_literal "$info_plist" "<key>$key</key>"
done

require_literal "$info_plist" '<string>com.speci.localnotes.notepkg</string>'
require_literal "$info_plist" '<string>com.adobe.pdf</string>'
require_literal "$info_plist" '<string>public.image</string>'

require_literal "$workflow_file" 'runs-on: macos-26'
require_literal "$workflow_file" 'bash scripts/generate-project.sh'
require_literal "$workflow_file" "-destination 'generic/platform=iOS'"
require_literal "$workflow_file" 'CODE_SIGNING_ALLOWED=NO'
require_literal "$workflow_file" 'xcrun xcresulttool export attachments'
require_literal "$workflow_file" 'name: NextStep-iPad-homepage'
require_literal "$workflow_file" 'NextStep-iPad-Home.png'
require_literal "$workflow_file" 'NextStep-responsive-previews'
require_literal "$workflow_file" 'NextStep-beta-native-previews'
require_literal "$workflow_file" 'testNextStepBetaNativeFlow'
require_literal "$workflow_file" 'testNextStepBetaSourceFactReviewFlow'
require_literal "$workflow_file" 'testCompactLegacyLibraryCanOpenQuickNote'
require_literal "$workflow_file" 'Light-Guided-Source'
require_literal "$workflow_file" 'NextStep-Beta-$device-$screen.png'
require_literal "$workflow_file" 'IPHONE_SIMULATOR_UDID'
require_literal "$workflow_file" 'Validate Windows contract preview'
require_literal "$workflow_file" 'node PreviewWeb/tests/state.smoke.mjs'
require_literal "$workflow_file" 'compression-level: 0'
require_literal "$workflow_file" 'retention-days: 7'
require_literal "$workflow_file" 'FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: "true"'
require_literal "$repo_root/Sources/NotesApp/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json" '"filename" : "AppIcon-1024.png"'

checkout_step_name='Check out repository'
bind_step_name='Bind build to source commit'
package_step_name='Package unsigned IPA'
manifest_step_name='Generate unsigned IPA install manifest'
upload_step_name='Upload unsigned IPA'
unit_test_step_name='Run unit and integration tests'
checkout_step="$(get_workflow_step_block "$checkout_step_name")"
bind_step="$(get_workflow_step_block "$bind_step_name")"
package_step="$(get_workflow_step_block "$package_step_name")"
manifest_step="$(get_workflow_step_block "$manifest_step_name")"
upload_step="$(get_workflow_step_block "$upload_step_name")"
unit_test_step="$(get_workflow_step_block "$unit_test_step_name")"

checkout_line="$(grep -Fn -- "      - name: $checkout_step_name" "$workflow_file" | cut -d: -f1)"
bind_line="$(grep -Fn -- "      - name: $bind_step_name" "$workflow_file" | cut -d: -f1)"
package_line="$(grep -Fn -- "      - name: $package_step_name" "$workflow_file" | cut -d: -f1)"
manifest_line="$(grep -Fn -- "      - name: $manifest_step_name" "$workflow_file" | cut -d: -f1)"
upload_line="$(grep -Fn -- "      - name: $upload_step_name" "$workflow_file" | cut -d: -f1)"
if ! (( checkout_line < bind_line && bind_line < package_line && package_line < manifest_line && manifest_line < upload_line )); then
  echo 'Unsigned IPA package, manifest, and upload steps must remain in that order.' >&2
  exit 1
fi

for literal in \
  'actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0' \
  'ref: ${{ github.event.pull_request.head.sha || github.sha }}' \
  'persist-credentials: false'; do
  require_step_literal "$checkout_step_name" "$checkout_step" "$literal"
done

for literal in \
  'case "$GITHUB_EVENT_NAME" in' \
  'pull_request)' \
  'push|workflow_dispatch)' \
  '.pull_request.head.repo.full_name // empty' \
  '.pull_request.head.sha // empty' \
  '[[ "$expected_repository" == "$GITHUB_REPOSITORY" ]]' \
  'built_commit="$(git rev-parse HEAD)"' \
  'echo "BUILD_COMMIT_SHA=$built_commit" >> "$GITHUB_ENV"'; do
  require_step_literal "$bind_step_name" "$bind_step" "$literal"
done

for literal in \
  'artifact_root="$RUNNER_TEMP/NotesUnsignedArtifact"' \
  'plutil -convert xml1 "$package_root/Payload/Notes.app/Info.plist"' \
  '"$artifact_root/Notes-unsigned.ipa"'; do
  require_step_literal "$package_step_name" "$package_step" "$literal"
done

for literal in \
  "readonly workflow_path='.github/workflows/ios-ci.yml'" \
  "readonly artifact_name='Notes-unsigned-ipa'" \
  "readonly ipa_file='Notes-unsigned.ipa'" \
  "readonly app_bundle_directory='Notes.app'" \
  "readonly expected_bundle_identifier='com.speci.localnotes'" \
  "readonly expected_display_name='NextStep'" \
  'plutil -extract CFBundleIdentifier raw' \
  'plutil -extract CFBundleDisplayName raw' \
  '[[ "$BUILD_COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]' \
  '[[ "$(git rev-parse HEAD)" == "$BUILD_COMMIT_SHA" ]]' \
  '--arg commitSha "$BUILD_COMMIT_SHA"' \
  'shasum -a 256' \
  "stat -f '%z'" \
  'jq -nS' \
  'jq -e' \
  "--arg format 'nextstep-unsigned-ipa'" \
  '--argjson schemaVersion 1' \
  'install-manifest.json' \
  'appBundleDirectory:' \
  'artifactName:' \
  'bundleDisplayName:' \
  'bundleIdentifier:' \
  'commitSha:' \
  'format:' \
  'ipaFile:' \
  'ipaSha256:' \
  'ipaSizeBytes:' \
  'repository:' \
  'repositoryId:' \
  'runAttempt:' \
  'runId:' \
  'schemaVersion:' \
  'workflowPath:' \
  'mv "$manifest_temporary" "$manifest_path"' \
  'shopt -s dotglob nullglob' \
  'artifact_entries=("$artifact_root"/*)' \
  '[[ "${#artifact_entries[@]}" == '\''2'\'' ]]' \
  '[[ -f "$artifact_entry" && ! -L "$artifact_entry" ]]'; do
  require_step_literal "$manifest_step_name" "$manifest_step" "$literal"
done
if grep -Fq -- '$GITHUB_SHA' <<< "$manifest_step"; then
  echo "Workflow step '$manifest_step_name' must bind the manifest to BUILD_COMMIT_SHA, not the pull-request merge SHA." >&2
  exit 1
fi

for literal in \
  'uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1' \
  'name: Notes-unsigned-ipa' \
  'path: |' \
  '${{ runner.temp }}/NotesUnsignedArtifact/Notes-unsigned.ipa' \
  '${{ runner.temp }}/NotesUnsignedArtifact/install-manifest.json' \
  'if-no-files-found: error' \
  'retention-days: 7' \
  'compression-level: 0'; do
  require_step_literal "$upload_step_name" "$upload_step" "$literal"
done

for literal in \
  '-only-testing:NotesCoreTests' \
  '-only-testing:NotesServicesTests' \
  '-only-testing:NotesAppTests' \
  '-only-testing:NextStepAcademicTests' \
  '-only-testing:NextStepDomainTests' \
  '-only-testing:NextStepGroundingTests' \
  '-only-testing:NextStepPlanningTests' \
  '-only-testing:NextStepSyncTests' \
  '-only-testing:NextStepDesignSystemTests'; do
  require_step_literal "$unit_test_step_name" "$unit_test_step" "$literal"
done

if ! grep -A1 '<key>CFBundleDisplayName</key>' "$info_plist" | grep -Fxq $'\t<string>NextStep</string>'; then
  echo "CFBundleDisplayName must be exactly 'NextStep'." >&2
  exit 1
fi

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$info_plist"
  plutil -lint "$privacy_manifest"
fi

if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool "$strings_catalog" >/dev/null
fi

if command -v node >/dev/null 2>&1; then
  node "$repo_root/scripts/validate-ai-schemas.mjs"
  node "$repo_root/scripts/validate-localization.mjs"
fi

if command -v sips >/dev/null 2>&1; then
  test "$(sips -g pixelWidth "$app_icon" | awk '/pixelWidth/ {print $2}')" = "1024"
  test "$(sips -g pixelHeight "$app_icon" | awk '/pixelHeight/ {print $2}')" = "1024"
  if sips -g hasAlpha "$app_icon" | grep -Eq 'hasAlpha: yes'; then
    echo "App icon must not contain an alpha channel." >&2
    exit 1
  fi
fi

echo "Project configuration is valid."
