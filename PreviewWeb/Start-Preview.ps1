param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 4173,

    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$address = [System.Net.IPAddress]::Loopback
$listener = [System.Net.Sockets.TcpListener]::new($address, $Port)

$mimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.mjs'  = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.ico'  = 'image/x-icon'
}

function Write-HttpResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$StatusCode,
        [string]$Reason,
        [string]$ContentType,
        [byte[]]$Body,
        [bool]$IncludeBody = $true
    )

    $header = @(
        "HTTP/1.1 $StatusCode $Reason"
        "Content-Type: $ContentType"
        "Content-Length: $($Body.Length)"
        'Cache-Control: no-store'
        'X-Content-Type-Options: nosniff'
        'Referrer-Policy: no-referrer'
        'Connection: close'
        ''
        ''
    ) -join "`r`n"

    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($IncludeBody -and $Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
    $Stream.Flush()
}

try {
    $listener.Start()
    $url = "http://127.0.0.1:$Port/"
    Write-Host "NextStep contract preview is running at $url" -ForegroundColor Green
    Write-Host 'Contract preview — not the iOS app. Press Ctrl+C to stop.' -ForegroundColor Yellow

    if (-not $NoBrowser) {
        Start-Process -FilePath $url
    }

    while ($true) {
        $client = $listener.AcceptTcpClient()
        $reader = $null
        $stream = $null
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 5000
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new(
                $stream,
                [System.Text.Encoding]::ASCII,
                $false,
                1024,
                $true
            )

            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) {
                continue
            }

            do {
                $line = $reader.ReadLine()
            } while ($null -ne $line -and $line.Length -gt 0)

            $parts = $requestLine.Split(' ')
            if ($parts.Length -lt 2) {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Bad request')
                Write-HttpResponse -Stream $stream -StatusCode 400 -Reason 'Bad Request' -ContentType 'text/plain; charset=utf-8' -Body $body
                continue
            }

            $method = $parts[0].ToUpperInvariant()
            if ($method -ne 'GET' -and $method -ne 'HEAD') {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Method not allowed')
                Write-HttpResponse -Stream $stream -StatusCode 405 -Reason 'Method Not Allowed' -ContentType 'text/plain; charset=utf-8' -Body $body
                continue
            }

            $requestPath = ($parts[1] -split '\?', 2)[0]
            $decodedPath = [System.Uri]::UnescapeDataString($requestPath)
            if ($decodedPath -eq '/') {
                $decodedPath = '/index.html'
            }

            $relativePath = $decodedPath.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $targetPath = [System.IO.Path]::GetFullPath((Join-Path $root $relativePath))
            $rootPrefix = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

            if (-not $targetPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Forbidden')
                Write-HttpResponse -Stream $stream -StatusCode 403 -Reason 'Forbidden' -ContentType 'text/plain; charset=utf-8' -Body $body
                continue
            }

            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Not found')
                Write-HttpResponse -Stream $stream -StatusCode 404 -Reason 'Not Found' -ContentType 'text/plain; charset=utf-8' -Body $body
                continue
            }

            $extension = [System.IO.Path]::GetExtension($targetPath).ToLowerInvariant()
            $contentType = if ($mimeTypes.ContainsKey($extension)) { $mimeTypes[$extension] } else { 'application/octet-stream' }
            $body = [System.IO.File]::ReadAllBytes($targetPath)
            Write-HttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -ContentType $contentType -Body $body -IncludeBody ($method -eq 'GET')
        }
        catch {
            Write-Warning "A preview request could not be served: $($_.Exception.Message)"
        }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
            $client.Dispose()
        }
    }
}
finally {
    $listener.Stop()
}
