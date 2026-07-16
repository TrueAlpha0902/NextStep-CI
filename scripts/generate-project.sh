#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

cd "$repo_root"
xcodegen generate --spec project.yml

if [[ ! -d Notes.xcodeproj ]]; then
  echo "XcodeGen completed without producing Notes.xcodeproj." >&2
  exit 1
fi

echo "Generated $repo_root/Notes.xcodeproj"
