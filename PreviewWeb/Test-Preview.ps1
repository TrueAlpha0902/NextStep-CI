$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

$requiredFiles = @(
    'index.html',
    'styles.css',
    'app.mjs',
    'core.mjs',
    'Start-Preview.ps1',
    'README.md',
    'tests/state.smoke.mjs'
)

foreach ($file in $requiredFiles) {
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf) -Message "Missing required file: $file"
}

$indexPath = Join-Path $root 'index.html'
$index = Get-Content -LiteralPath $indexPath -Raw
Assert-True ($index.Contains('Contract preview — not the iOS app')) 'Preview disclaimer is missing.'
Assert-True ($index.Contains('data-layout="phone"')) 'iPhone compact toggle is missing.'
Assert-True ($index.Contains('data-layout="tablet"')) 'iPad regular toggle is missing.'
Assert-True ($index.Contains('connect-src ''none''')) 'Offline-only Content Security Policy is missing.'

$webSources = @('index.html', 'styles.css', 'app.mjs', 'core.mjs')
foreach ($source in $webSources) {
    $text = Get-Content -LiteralPath (Join-Path $root $source) -Raw
    Assert-True -Condition (-not [regex]::IsMatch($text, '(?i)(src|href)\s*=\s*["'']https?://')) -Message "Remote asset reference found in $source"
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -ne $node) {
    & $node.Source --check (Join-Path $root 'core.mjs')
    if ($LASTEXITCODE -ne 0) { $failures.Add('core.mjs failed JavaScript syntax validation.') }
    & $node.Source --check (Join-Path $root 'app.mjs')
    if ($LASTEXITCODE -ne 0) { $failures.Add('app.mjs failed JavaScript syntax validation.') }
    & $node.Source (Join-Path $root 'tests/state.smoke.mjs')
    if ($LASTEXITCODE -ne 0) { $failures.Add('Interactive state smoke tests failed.') }
}
else {
    Write-Warning 'Node.js is not available; JavaScript state tests were skipped.'
}

$serverProcess = $null
$port = Get-Random -Minimum 43000 -Maximum 49000
try {
    $powerShellPath = (Get-Process -Id $PID).Path
    $serverArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'Start-Preview.ps1'),
        '-Port', $port,
        '-NoBrowser'
    )
    $serverProcess = Start-Process -FilePath $powerShellPath -ArgumentList $serverArguments -PassThru -WindowStyle Hidden

    $response = $null
    for ($attempt = 0; $attempt -lt 30 -and $null -eq $response; $attempt++) {
        Start-Sleep -Milliseconds 150
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -TimeoutSec 2 -UseBasicParsing
        }
        catch {
            if ($attempt -eq 29) { throw }
        }
    }

    Assert-True ($response.StatusCode -eq 200) 'Local preview server did not return HTTP 200.'
    Assert-True ($response.Content.Contains('id="device-stage"')) 'Local preview server returned unexpected content.'
}
catch {
    $failures.Add("Local server smoke test failed: $($_.Exception.Message)")
}
finally {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force
        $serverProcess.WaitForExit()
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'NextStep preview validation failed:' -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host 'NextStep preview validation passed.' -ForegroundColor Green
Write-Host 'Checked local-only assets, responsive device contracts, state transitions, and the PowerShell server.'
