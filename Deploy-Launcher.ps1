[CmdletBinding()]
param(
    # Path of a file dropped onto the .bat, if any (passed through by the .bat wrapper)
    [string]$DroppedPath
)

$ErrorActionPreference = "Stop"

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$DeployScript = Join-Path $ScriptDir "Deploy-CareWebServiceV5.ps1"

Write-Host "===== CareWebServiceV5 Deployment Launcher =====" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $DeployScript -PathType Leaf)) {
    Write-Host "Cannot find Deploy-CareWebServiceV5.ps1 next to this launcher." -ForegroundColor Red
    Write-Host "Expected at: $DeployScript" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

$packagePath = $null
$packageUrl  = $null

# --- 1. A file was dragged onto the .bat -----------------------------------
if ($DroppedPath -and (Test-Path -LiteralPath $DroppedPath -PathType Leaf)) {
    $packagePath = (Resolve-Path -LiteralPath $DroppedPath).Path
    Write-Host "Using dropped file: $packagePath"
}
else {
    # --- 2. Ask for a OneDrive link, or fall back to a file picker ---------
    Add-Type -AssemblyName Microsoft.VisualBasic
    $link = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Paste the OneDrive share link for the release package." + [Environment]::NewLine + [Environment]::NewLine +
        "Leave this blank and click OK to browse for a local zip file instead.",
        "CareWebServiceV5 Deployment",
        ""
    )
    if ($null -ne $link) { $link = $link.Trim() }

    if ($link) {
        $packageUrl = $link
        Write-Host "OneDrive link received ($($link.Length) characters)."
    }
    else {
        Write-Host "No link entered - opening a file picker instead..."
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "Deployment package (*.zip)|*.zip"
        $dlg.Title  = "Select the CareWebServiceV5 release package"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $packagePath = $dlg.FileName
        }
    }
}

if (-not $packagePath -and -not $packageUrl) {
    Write-Host "No package selected and no link entered. Aborting." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit 1
}

Write-Host ""
if ($packageUrl) { Write-Host "OneDrive link: $packageUrl" }
else { Write-Host "Package: $packagePath" }
Write-Host "Script : $DeployScript"
Write-Host ""
Write-Host "Launching deployment (this will request Administrator access)..." -ForegroundColor Cyan
Write-Host ""

# Build the argument list. Windows PowerShell 5.1's Start-Process does NOT
# auto-quote array elements that contain spaces (only PowerShell 7+ does),
# so any path/value with a space - like a deploy folder named "BAT DEPLOY" -
# would get silently split into two broken arguments. To work correctly on
# both PS versions, we wrap each path/value in its own quotes ourselves.
$argList = New-Object System.Collections.Generic.List[string]
$argList.Add("-NoProfile")
$argList.Add("-ExecutionPolicy"); $argList.Add("Bypass")
$argList.Add("-File"); $argList.Add('"' + $DeployScript + '"')
if ($packageUrl) {
    $argList.Add("-PackageUrl"); $argList.Add('"' + $packageUrl + '"')
}
else {
    $argList.Add("-PackagePath"); $argList.Add('"' + $packagePath + '"')
}

try {
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Host ""
        Write-Host "The deployment process exited with an error (code $($proc.ExitCode))." -ForegroundColor Red
        Write-Host "Check the elevated PowerShell window's output above, and the log file under `$env:TEMP." -ForegroundColor Red
    }
}
catch {
    Write-Host "Failed to launch the elevated deployment process: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Deployment launcher finished. Check the elevated PowerShell"
Write-Host " window above for the full step-by-step log and result."
Write-Host " A detailed log file was also saved under `$env:TEMP."
Write-Host "============================================================" -ForegroundColor Cyan
Read-Host "Press Enter to close"
