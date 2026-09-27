# Portable Web Server for Windows (Prioritizes Wi-Fi for iPhone testing)
$port = 8080

# Get all valid unicast IPv4 addresses
$allIPs = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notlike "169.254.*" }

# Prioritize Wi-Fi interface IP
$wifiIP = ($allIPs | Where-Object { $_.InterfaceAlias -like "*Wi-Fi*" -or $_.InterfaceAlias -like "*Wireless*" } | Select-Object -First 1).IPAddress

if (-not $wifiIP) {
    $wifiIP = ($allIPs | Where-Object { $_.IPAddress -like "192.168.*" } | Select-Object -First 1).IPAddress
}

if (-not $wifiIP -and $allIPs) {
    $wifiIP = $allIPs[0].IPAddress
}

if (-not $wifiIP) {
    $wifiIP = "127.0.0.1"
}

$listener = New-Object System.Net.HttpListener

# Bind to all detected IPs so any connection works
foreach ($ipObj in $allIPs) {
    try { $listener.Prefixes.Add("http://$($ipObj.IPAddress):$port/") } catch {}
}
try { $listener.Prefixes.Add("http://localhost:$port/") } catch {}
try { $listener.Prefixes.Add("http://127.0.0.1:$port/") } catch {}

try {
    $listener.Start()
} catch {
    Write-Host "Starting fallback listener..."
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  LOCAL SERVER IS RUNNING!" -ForegroundColor Green
Write-Host "  Open this link on your iPhone Safari:" -ForegroundColor Yellow
Write-Host "  http://${wifiIP}:$port" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  Wi-Fi IP Address: $wifiIP" -ForegroundColor White
Write-Host "  To stop server: Close this window or press Ctrl+C" -ForegroundColor Gray
Write-Host ""

$mimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.json' = 'application/json'
}

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $rawPath = [System.Uri]::UnescapeDataString($request.Url.AbsolutePath)
        if ($rawPath -eq '/') { $rawPath = '/index.html' }
        
        $cleanPath = $rawPath.TrimStart('/').Replace('/', '\')
        $filePath = Join-Path (Get-Location) $cleanPath

        if (Test-Path $filePath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $contentType = $mimeTypes[$ext]
            if (-not $contentType) { $contentType = 'application/octet-stream' }
            $response.ContentType = $contentType

            $buffer = [System.IO.File]::ReadAllBytes($filePath)
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        } else {
            $response.StatusCode = 404
        }
        $response.OutputStream.Close()
    } catch {}
}
