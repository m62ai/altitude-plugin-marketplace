# refresh-api-spec.ps1 — regenerate embedded OpenAPI specs from the live Altitude backend
#
# Windows / PowerShell 7+ equivalent of refresh-api-spec.sh.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\refresh-api-spec.ps1
#   powershell -ExecutionPolicy Bypass -File tools\refresh-api-spec.ps1 -AltitudeBePath C:\dev\altitude-BE
#
# Requires: altitude-BE checked out, Docker Desktop running, Java 21, Gradle wrapper.

param(
    [string]$AltitudeBePath = "$env:ALTITUDE_BE",
    [int]$Port = 8080,
    [int]$BootTimeoutSecs = 300
)

$ErrorActionPreference = 'Stop'

if (-not $AltitudeBePath) {
    $AltitudeBePath = Join-Path $env:USERPROFILE 'Development\altitude-BE'
}
if (-not (Test-Path $AltitudeBePath)) {
    Write-Error "altitude-BE not found at: $AltitudeBePath. Pass -AltitudeBePath or set ALTITUDE_BE env var."
}

$MarketplaceRoot = Split-Path -Parent $PSScriptRoot
$LogFile = Join-Path $env:TEMP "altcore-bootrun-$PID.log"

# Start server
Write-Host ">> Starting altitude-BE at $AltitudeBePath ..."
$bootProc = Start-Process -FilePath (Join-Path $AltitudeBePath 'gradlew.bat') `
    -ArgumentList ':local-dev:bootRun' `
    -WorkingDirectory $AltitudeBePath `
    -RedirectStandardOutput $LogFile `
    -RedirectStandardError $LogFile `
    -NoNewWindow -PassThru

$cleanup = {
    if ($bootProc -and -not $bootProc.HasExited) {
        Write-Host "Stopping bootRun (PID $($bootProc.Id))..."
        Stop-Process -Id $bootProc.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Process | Where-Object { $_.ProcessName -match 'java' -and $_.CommandLine -match 'AltcoreApp' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    if (Test-Path $LogFile) { Remove-Item $LogFile -ErrorAction SilentlyContinue }
}

try {
    Write-Host ">> Waiting for http://localhost:$Port/v3/api-docs (timeout ${BootTimeoutSecs}s)..."
    $elapsed = 0
    $ready = $false
    while ($elapsed -lt $BootTimeoutSecs) {
        try {
            $resp = Invoke-WebRequest "http://localhost:$Port/v3/api-docs" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }

    if (-not $ready) {
        Write-Host "Server failed to start within ${BootTimeoutSecs}s. Last 40 log lines:" -ForegroundColor Red
        Get-Content $LogFile -Tail 40
        throw "bootRun timeout"
    }
    Write-Host ">> Server up after ${elapsed}s"

    $tmpSpec = Join-Path $env:TEMP "altcore-api-$PID.json"
    Invoke-WebRequest "http://localhost:$Port/v3/api-docs" -OutFile $tmpSpec -TimeoutSec 60 -UseBasicParsing

    $spec = Get-Content $tmpSpec -Raw | ConvertFrom-Json
    Write-Host ("  openapi={0} version={1} title={2} paths={3} schemas={4}" -f `
        $spec.openapi, $spec.info.version, $spec.info.title, `
        ($spec.paths.PSObject.Properties | Measure-Object).Count, `
        ($spec.components.schemas.PSObject.Properties | Measure-Object).Count)

    $targets = @(
        'plugins\m62-altitude-onboarding\skills\m62-altitude-onboarding\api-docs\api.json',
        'plugins\m62-altitude-api\skills\m62-altitude-api\api-docs\api.json'
    )
    foreach ($t in $targets) {
        $dest = Join-Path $MarketplaceRoot $t
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        Copy-Item $tmpSpec $dest -Force
        Write-Host ">> Wrote $dest"
    }

    Remove-Item $tmpSpec -ErrorAction SilentlyContinue
    Write-Host ">> Done. Remember to bump the 'Updated:' date in the reference .md files."
}
finally {
    & $cleanup
}
