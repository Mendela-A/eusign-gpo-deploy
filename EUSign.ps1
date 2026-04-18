#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# === Config ===
$share       = '\\dc-001\doctors-data\Scripts\EUSign'
$shareExe    = Join-Path $share 'EUSignWebInstall.exe'
$shareHash   = "$shareExe.sha256"
$installer   = Join-Path $env:TEMP 'EUSignWebInstall.exe'
$logFile     = "C:\Windows\Temp\EUSign_$env:COMPUTERNAME`_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$installLog  = "$env:TEMP\EUSignSetup.log"
$lockFile    = "$env:TEMP\EUSign.lock"
$installTimeoutSec = 600

# === Logging ===
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Level | $Message"
    try { Add-Content -Path $logFile -Value $entry -Encoding UTF8 } catch {}
}

# === Single-instance lock ===
if (Test-Path $lockFile) {
    $age = (Get-Date) - (Get-Item $lockFile).LastWriteTime
    if ($age.TotalMinutes -lt 30) { Write-Log "Another instance running, exit." 'WARN'; exit 0 }
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}
New-Item $lockFile -ItemType File -Force | Out-Null

$exitCode = 0
try {
    Write-Log "=== Start on $env:COMPUTERNAME ==="

    # === Share availability (no network = not an error on boot) ===
    if (-not (Test-Path $shareExe)) {
        Write-Log "Share unreachable or installer missing: $shareExe" 'WARN'
        return
    }

    # === Copy installer ===
    Copy-Item $shareExe $installer -Force
    $size = (Get-Item $installer).Length
    if ($size -lt 1MB) { Write-Log "Installer too small: $size bytes" 'ERROR'; $exitCode = 2; return }

    # === SHA256 verify against share ===
    if (Test-Path $shareHash) {
        $expected = (Get-Content $shareHash -Raw).Trim().Split()[0].ToLower()
        $actual   = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) {
            Write-Log "SHA256 mismatch. expected=$expected actual=$actual" 'ERROR'
            $exitCode = 2; return
        }
        Write-Log "SHA256 OK"
    } else {
        Write-Log "No .sha256 on share — skipping hash check" 'WARN'
    }

    # === Authenticode verify ===
    $sig = Get-AuthenticodeSignature $installer
    if ($sig.Status -ne 'Valid') {
        Write-Log "Bad signature: $($sig.Status) / $($sig.StatusMessage)" 'ERROR'
        $exitCode = 2; return
    }
    Write-Log "Signer: $($sig.SignerCertificate.Subject)"

    # === Version parse (safe) ===
    $newVersion = $null
    try { $newVersion = [Version](Get-Item $installer).VersionInfo.ProductVersion } catch {
        Write-Log "Cannot parse installer version — will install anyway" 'WARN'
    }
    Write-Log "Installer version: $newVersion"

    # === Installed version check ===
    # Guard PSObject.Properties lookup — not all Uninstall entries have DisplayIcon,
    # and Set-StrictMode throws on missing-property access.
    $installed = Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSObject.Properties['DisplayIcon'] -and
            $_.DisplayIcon -like '*EUNMHProcess*'
        } |
        Select-Object -First 1

    if ($installed -and $newVersion) {
        $installedVersion = $null
        try { $installedVersion = [Version]$installed.DisplayVersion } catch {
            Write-Log "Cannot parse installed version '$($installed.DisplayVersion)' — will reinstall" 'WARN'
        }
        if ($installedVersion -and $installedVersion -ge $newVersion) {
            Write-Log "Already up to date ($installedVersion). Skip."
            return
        }
        Write-Log "Updating: $installedVersion -> $newVersion"
    } else {
        Write-Log "EUSign not found or version unknown. Installing..."
    }

    # === Install with timeout ===
    Remove-Item $installLog -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $installer `
        -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=`"$installLog`"" `
        -PassThru
    if (-not $proc.WaitForExit($installTimeoutSec * 1000)) {
        Write-Log "Installer timeout ($installTimeoutSec s) — killing" 'ERROR'
        try { $proc.Kill() } catch {}
        $exitCode = 3; return
    }
    Write-Log "Installer exit code: $($proc.ExitCode)"

    if ($proc.ExitCode -ne 0) {
        Write-Log "--- Installer log ---" 'ERROR'
        if (Test-Path $installLog) { Get-Content $installLog | Add-Content $logFile }
        $exitCode = $proc.ExitCode
    }
}
catch {
    Write-Log "Unhandled: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    $exitCode = 3
}
finally {
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    Remove-Item $lockFile  -Force -ErrorAction SilentlyContinue
    Write-Log "=== Done (exit=$exitCode) ==="
    exit $exitCode
}
