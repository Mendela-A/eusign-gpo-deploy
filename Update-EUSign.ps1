#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Перевіряє та завантажує актуальний інсталятор EUSign на файлову шару.

.DESCRIPTION
    Запускається щодня Scheduled Task від SYSTEM. Качає EUSignWebInstall.exe
    з iit.com.ua, перевіряє підпис, розмір, версію, і атомарно замінює файл
    на шарі разом з SHA256.

.EXAMPLE
    .\Update-EUSign.ps1
    .\Update-EUSign.ps1 -Verbose
    .\Update-EUSign.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Url         = 'https://iit.com.ua/download/productfiles/EUSignWebInstall.exe',
    [string]$ShareDir    = 'C:\doctors-data\Scripts\EUSign',
    [int]$MinFileSize    = 1MB,
    [int]$MaxRetries     = 3,
    [int]$RetryDelay     = 15,
    [int]$MaxLogSize     = 5MB,
    [int]$KeepBackups    = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Paths ---
$shareExe  = Join-Path $ShareDir 'EUSignWebInstall.exe'
$shareHash = "$shareExe.sha256"
$logDir    = Join-Path $ShareDir 'Logs'
$logFile   = Join-Path $logDir 'DC_Update.log'
$lockFile  = Join-Path $ShareDir '.update.lock'
$tempExe   = Join-Path $env:TEMP 'EUSignWebInstall_new.exe'

# --- Helpers ---
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Level | $Message"
    Add-Content -Path $logFile -Value $entry -Encoding UTF8
    Write-Verbose $entry
}

function Rotate-Log {
    if (-not (Test-Path $logFile)) { return }
    if ((Get-Item $logFile).Length -le $MaxLogSize) { return }
    for ($i = $KeepBackups; $i -gt 1; $i--) {
        $src = "$logFile.$($i-1)"
        $dst = "$logFile.$i"
        if (Test-Path $src) { Move-Item $src $dst -Force }
    }
    Move-Item $logFile "$logFile.1" -Force
}

# --- Init ---
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
Rotate-Log

# --- Lock (single-instance) ---
if (Test-Path $lockFile) {
    $lockAge = (Get-Date) - (Get-Item $lockFile).LastWriteTime
    if ($lockAge.TotalMinutes -lt 30) {
        Write-Log "Another instance is running (lock age: $([int]$lockAge.TotalMinutes) min). Exit." -Level WARN
        exit 0
    }
    Write-Log "Stale lock found ($([int]$lockAge.TotalMinutes) min). Removing." -Level WARN
    Remove-Item $lockFile -Force
}
Set-Content -Path $lockFile -Value $PID -Force

try {
    Write-Log "=== EUSign Update Check started (PID $PID) ==="

    # --- Current version on share ---
    $currentVersion = $null
    if (Test-Path $shareExe) {
        try {
            $currentVersion = [Version](Get-Item $shareExe).VersionInfo.FileVersion
            Write-Log "Current share version: $currentVersion"
        } catch {
            Write-Log "Cannot read current version: $_" -Level WARN
        }
    } else {
        Write-Log "No file on share — initial download" -Level WARN
    }

    # --- Download with retry ---
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Remove-Item $tempExe -Force -ErrorAction SilentlyContinue

    $downloaded = $false
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            $params = @{
                Uri             = $Url
                OutFile         = $tempExe
                UseBasicParsing = $true
                TimeoutSec      = 120
            }
            Invoke-WebRequest @params
            $downloaded = $true
            break
        } catch {
            Write-Log "Download attempt $i/$MaxRetries failed: $_" -Level WARN
            if ($i -lt $MaxRetries) { Start-Sleep -Seconds ($RetryDelay * $i) }
        }
    }
    if (-not $downloaded) {
        Write-Log "All download attempts failed" -Level ERROR
        exit 1
    }

    # --- Size check ---
    $fileInfo = Get-Item $tempExe
    if ($fileInfo.Length -lt $MinFileSize) {
        Write-Log "Downloaded file too small ($($fileInfo.Length) bytes)" -Level ERROR
        exit 2
    }

    # --- Signature check ---
    $sig = Get-AuthenticodeSignature $tempExe
    if ($sig.Status -ne 'Valid') {
        Write-Log "Invalid signature: $($sig.Status) — $($sig.StatusMessage)" -Level ERROR
        exit 2
    }
    Write-Log "Signature OK: $($sig.SignerCertificate.Subject)"

    # --- Version compare ---
    $newVersion = $null
    try {
        $newVersion = [Version]$fileInfo.VersionInfo.FileVersion
    } catch {
        Write-Log "Cannot parse new version: $_" -Level ERROR
        exit 2
    }
    Write-Log "Version from site: $newVersion"

    # Regression guard: нова версія не повинна бути нижчою по major
    if ($currentVersion -and $newVersion -and $newVersion.Major -lt $currentVersion.Major) {
        Write-Log "Regression blocked: $newVersion < $currentVersion (major)" -Level ERROR
        exit 2
    }

    if ($currentVersion -and $newVersion -and $currentVersion -ge $newVersion) {
        Write-Log "Already up to date ($currentVersion)"
        Write-Log "=== Done ==="
        exit 0
    }

    # --- Atomic replace + hash ---
    $stagingExe  = "$shareExe.new"
    $stagingHash = "$shareHash.new"

    if ($PSCmdlet.ShouldProcess($shareExe, 'Replace installer')) {
        Copy-Item $tempExe $stagingExe -Force

        $hash = (Get-FileHash $stagingExe -Algorithm SHA256).Hash
        Set-Content -Path $stagingHash -Value $hash -Encoding ASCII

        # Hash first so partial failure leaves (new-hash, old-exe) — client fails
        # fast on mismatch, instead of (new-exe, old-hash) which looks like tamper.
        Move-Item $stagingHash $shareHash -Force
        Move-Item $stagingExe  $shareExe  -Force

        Write-Log "Updated: $currentVersion -> $newVersion (SHA256: $hash)"
    }

    Write-Log "=== Done ==="
    exit 0

} catch {
    Write-Log "Unhandled error: $($_.Exception.Message)`n$($_.ScriptStackTrace)" -Level ERROR
    exit 3
}
finally {
    Remove-Item $tempExe  -Force -ErrorAction SilentlyContinue
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}
