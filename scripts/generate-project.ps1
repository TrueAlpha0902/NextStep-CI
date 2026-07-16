$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$xcodegen = Get-Command xcodegen -ErrorAction SilentlyContinue

if ($null -eq $xcodegen) {
    throw "XcodeGen is required. Install it on macOS with: brew install xcodegen"
}

Push-Location $repoRoot
try {
    & $xcodegen.Source generate --spec project.yml
    if ($LASTEXITCODE -ne 0) {
        throw "XcodeGen failed with exit code $LASTEXITCODE."
    }

    if (-not (Test-Path (Join-Path $repoRoot "Notes.xcodeproj") -PathType Container)) {
        throw "XcodeGen completed without producing Notes.xcodeproj."
    }

    Write-Host "Generated $repoRoot/Notes.xcodeproj"
}
finally {
    Pop-Location
}
