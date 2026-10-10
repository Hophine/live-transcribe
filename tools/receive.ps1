# Prints the live transcript from a phone that is sharing.
#
# The phone serves newline-delimited JSON on port 45678. Over Wi-Fi, pass the
# phone's address. Over USB, run `adb forward tcp:45678 tcp:45678` first and
# use the default host, which then reaches the phone through the cable.
#
#   powershell -ExecutionPolicy Bypass -File tools\receive.ps1
#   powershell -ExecutionPolicy Bypass -File tools\receive.ps1 -Host 192.168.1.42

param(
    [string]$RemoteHost = '127.0.0.1',
    [int]$Port = 45678
)

$ErrorActionPreference = 'Stop'

Write-Host "Connecting to ${RemoteHost}:${Port} ..." -ForegroundColor Cyan

try {
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect($RemoteHost, $Port)
} catch {
    Write-Host "Could not connect: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Is "Share" switched on in the app? Over USB, run: adb forward tcp:45678 tcp:45678' -ForegroundColor Yellow
    exit 1
}

Write-Host 'Connected. Waiting for speech (Ctrl+C to stop).' -ForegroundColor Green

$stream = $client.GetStream()
$reader = New-Object System.IO.StreamReader($stream)

try {
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try {
            $msg = $line | ConvertFrom-Json
        } catch {
            Write-Host "unparsed: $line" -ForegroundColor DarkGray
            continue
        }

        switch ($msg.t) {
            'hello'   { Write-Host "[linked] sender language: $($msg.lang)" -ForegroundColor Cyan }
            'partial' { Write-Host "  ... $($msg.text)" -ForegroundColor DarkGray }
            'final'   { Write-Host "[$($msg.lang)] $($msg.text)" -ForegroundColor White }
            'clear'   { Write-Host '[transcript cleared]' -ForegroundColor Yellow }
            default   { Write-Host "unknown: $line" -ForegroundColor DarkGray }
        }
    }
    Write-Host 'The phone closed the connection.' -ForegroundColor Yellow
} finally {
    $reader.Dispose()
    $client.Close()
}
