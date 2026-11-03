#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated deployment tool for CareWebServiceV5 (ASP.NET Framework 4.8 / IIS on Windows Server).

.DESCRIPTION
    Implements the standard release procedure:
      1. Stop IIS
      2. Verify target app folder exists (C:\work\carewebservicev5)
      3. Extract the release package (.zip) into D:\deployment\<PackageName>
      4. If the extracted package contains web.config, delete it
         (so the server's existing web.config with live settings is preserved)
      5. Copy all extracted content into C:\work\carewebservicev5 (overwrite)
      6. Start IIS again

    A timestamped backup of the current live folder is taken before the
    overwrite (unless -NoBackup is used), and IIS is ALWAYS restarted at the
    end, even if a step fails, via a try/finally block.

.PARAMETER PackagePath
    Full path to a release .zip package that is already on local disk.
    Example: D:\Releases\01_Publish_CareWebServiceV5_2026_v_2_0_0.zip
    Either -PackagePath or -PackageUrl must be supplied.

.PARAMETER PackageUrl
    A OneDrive "share" link (e.g. https://1drv.ms/... or a
    ...-my.sharepoint.com/:u:/g/... link) or any other direct HTTP(S) URL
    to the release .zip. The script downloads it automatically before
    continuing with extraction, so no manual download step is needed.
    Either -PackagePath or -PackageUrl must be supplied.

.PARAMETER DownloadFolder
    Where a package fetched via -PackageUrl is saved to before extraction.
    Default: <ExtractRoot>\_downloads

.PARAMETER ExtractRoot
    Root folder where the package will be extracted to.
    Default: D:\deployment

.PARAMETER TargetFolder
    Live IIS application folder that will receive the new files.
    Default: C:\work\carewebservicev5

.PARAMETER SiteName
    Optional. If supplied, only this IIS site (and, if given, -AppPoolName)
    is stopped/started instead of the whole IIS server (iisreset).
    Requires the WebAdministration module (IIS management tools installed).

.PARAMETER AppPoolName
    Optional. Application pool to stop/start alongside -SiteName.

.PARAMETER NoBackup
    Skip taking a backup copy of the current TargetFolder before overwrite.

.PARAMETER Mirror
    Use robocopy /MIR (mirror) instead of the default additive copy.
    Mirror will DELETE files in TargetFolder that do not exist in the
    package. Only use this if the package is a full, complete publish.

.EXAMPLE
    .\Deploy-CareWebServiceV5.ps1 -PackagePath "D:\Releases\01_Publish_CareWebServiceV5_2026_v_2_0_0.zip"

.EXAMPLE
    .\Deploy-CareWebServiceV5.ps1 -PackagePath "D:\Releases\pkg.zip" -SiteName "CareWebServiceV5" -AppPoolName "CareWebServiceV5Pool"

.EXAMPLE
    .\Deploy-CareWebServiceV5.ps1 -PackageUrl "https://1drv.ms/u/s!AbCdEfGhIjKlMn12345"

.NOTES
    Run this script from an elevated (Administrator) PowerShell prompt on the
    Windows Server that hosts IIS for CareWebServiceV5.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PackagePath,

    [string]$PackageUrl,

    [string]$DownloadFolder,

    [string]$ExtractRoot = "D:\deployment",

    [string]$TargetFolder = "C:\work\carewebservicev5",

    [string]$SiteName,

    [string]$AppPoolName,

    [switch]$NoBackup,

    [switch]$Mirror
)

$ErrorActionPreference = "Stop"

# Keep the elevated console window open on ANY failure (including errors
# that happen before the main try/finally below, such as bad parameters)
# so the person running this via double-click can actually see what went
# wrong, instead of the window flashing and closing instantly.
trap {
    Write-Host ""
    Write-Host "DEPLOYMENT SCRIPT ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
$LogFile = Join-Path $env:TEMP ("CareWebServiceV5_Deploy_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "STEP", "OK")] [string]$Level = "INFO"
    )
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$stamp] [$Level] $Message"

    switch ($Level) {
        "STEP"  { Write-Host $line -ForegroundColor Cyan }
        "OK"    { Write-Host $line -ForegroundColor Green }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    Add-Content -LiteralPath $LogFile -Value $line
}

function Stop-Iis {
    if ($SiteName) {
        Write-Log "Stopping IIS site '$SiteName' (targeted stop, not full IIS reset)..." "STEP"
        Import-Module WebAdministration -ErrorAction Stop
        Stop-Website -Name $SiteName -ErrorAction Stop
        if ($AppPoolName) {
            Write-Log "Stopping application pool '$AppPoolName'..."
            Stop-WebAppPool -Name $AppPoolName -ErrorAction Stop
        }
        Write-Log "Site '$SiteName' stopped." "OK"
    }
    else {
        Write-Log "Stopping IIS (iisreset /stop) on this server..." "STEP"
        $result = iisreset /stop
        Write-Log ($result -join " ")
        Write-Log "IIS stopped." "OK"
    }
}

function Resolve-DirectDownloadLink {
    <#
        Converts a OneDrive "share" link (personal 1drv.ms / onedrive.live.com,
        or OneDrive for Business / SharePoint ...-my.sharepoint.com links)
        into a direct-download URL by:
          1. Following redirects to resolve short links (1drv.ms) to their
             real URL.
          2. Appending a download=1 query parameter, which both OneDrive
             personal and OneDrive for Business honor on "anyone with the
             link" shares.
        If the URL is already a direct link (not OneDrive), it is returned
        unchanged.
    #>
    param([Parameter(Mandatory)] [string]$Url)

    $resolvedUrl = $Url
    if ($Url -match "1drv\.ms" -or $Url -match "onedrive\.live\.com" -or $Url -match "sharepoint\.com") {
        try {
            $req = [System.Net.WebRequest]::Create($Url)
            $req.AllowAutoRedirect = $true
            $req.Method = "HEAD"
            $resp = $req.GetResponse()
            $resolvedUrl = $resp.ResponseUri.AbsoluteUri
            $resp.Close()
        }
        catch {
            Write-Log "Could not pre-resolve redirect for the link, will try downloading as-is. ($($_.Exception.Message))" "WARN"
        }

        if ($resolvedUrl -notmatch "[?&]download=1") {
            $separator = if ($resolvedUrl.Contains("?")) { "&" } else { "?" }
            $resolvedUrl = "$resolvedUrl${separator}download=1"
        }
    }
    return $resolvedUrl
}

function Get-PackageFromUrl {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $directUrl = Resolve-DirectDownloadLink -Url $Url
    Write-Log "Downloading package from OneDrive link..." "STEP"
    Write-Log "Source: $Url"

    $fileName = "CareWebServiceV5_package_{0}.zip" -f (Get-Date -Format "yyyyMMdd_HHmmss")
    $outFile = Join-Path $Destination $fileName

    try {
        $ProgressPreference = "SilentlyContinue"   # much faster Invoke-WebRequest
        $response = Invoke-WebRequest -Uri $directUrl -OutFile $outFile -UseBasicParsing -PassThru -ErrorAction Stop

        # If OneDrive gave us a real filename via Content-Disposition, rename to match.
        $cd = $response.Headers["Content-Disposition"]
        if ($cd -match 'filename\*?="?([^";]+)"?') {
            $suggestedName = [System.Uri]::UnescapeDataString($Matches[1])
            if ($suggestedName -match '\.zip$') {
                $renamedFile = Join-Path $Destination $suggestedName
                Move-Item -LiteralPath $outFile -Destination $renamedFile -Force
                $outFile = $renamedFile
            }
        }
    }
    catch {
        throw "Failed to download package from the provided link. If this is a OneDrive for Business link, confirm sharing is set to 'Anyone with the link' (not restricted to specific people), or supply -PackagePath with a manually downloaded file instead. Underlying error: $($_.Exception.Message)"
    }

    # Sanity-check: make sure we actually got a zip file, not an HTML login/error page.
    $fileInfo = Get-Item -LiteralPath $outFile
    if ($fileInfo.Length -lt 1KB) {
        throw "Downloaded file '$outFile' is suspiciously small ($($fileInfo.Length) bytes) - likely not a real package (may be an HTML sign-in page). Check the link's sharing permissions."
    }
    $sig = [byte[]](Get-Content -LiteralPath $outFile -Encoding Byte -TotalCount 2 -ErrorAction SilentlyContinue)
    if (-not $sig -or $sig.Length -lt 2 -or $sig[0] -ne 0x50 -or $sig[1] -ne 0x4B) {
        throw "Downloaded file '$outFile' does not look like a valid zip file. Check the OneDrive link and sharing permissions, or download manually and use -PackagePath instead."
    }

    Write-Log "Downloaded to: $outFile ($([math]::Round($fileInfo.Length/1MB,2)) MB)" "OK"
    return $outFile
}

function Start-Iis {
    if ($SiteName) {
        Write-Log "Starting IIS site '$SiteName'..." "STEP"
        Import-Module WebAdministration -ErrorAction Stop
        if ($AppPoolName) {
            Write-Log "Starting application pool '$AppPoolName'..."
            Start-WebAppPool -Name $AppPoolName -ErrorAction Stop
        }
        Start-Website -Name $SiteName -ErrorAction Stop
        Write-Log "Site '$SiteName' started." "OK"
    }
    else {
        Write-Log "Starting IIS (iisreset /start)..." "STEP"
        $result = iisreset /start
        Write-Log ($result -join " ")
        Write-Log "IIS started." "OK"
    }
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Write-Log "===== CareWebServiceV5 Deployment started =====" "STEP"
Write-Log "Log file: $LogFile"

if (-not $PackagePath -and -not $PackageUrl) {
    throw "You must supply either -PackagePath (a local zip file) or -PackageUrl (a OneDrive share link)."
}
if ($PackagePath -and $PackageUrl) {
    throw "Supply only one of -PackagePath or -PackageUrl, not both."
}

# Step 1 (of the OneDrive flow): download the package first, BEFORE IIS is
# touched, so a bad/expired link never leaves the site stopped for nothing.
if ($PackageUrl) {
    if (-not $DownloadFolder) { $DownloadFolder = Join-Path $ExtractRoot "_downloads" }
    $PackagePath = Get-PackageFromUrl -Url $PackageUrl -Destination $DownloadFolder
}

if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "Package file not found: $PackagePath"
}

Write-Log "Package : $PackagePath"
Write-Log "Extract : $ExtractRoot"
Write-Log "Target  : $TargetFolder"

if (-not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
    throw "Target folder '$TargetFolder' was not found. Aborting before touching IIS. Create the folder first, or check the path (step 2 of the runbook: find C:\work\carewebservicev5)."
}

if (-not (Test-Path -LiteralPath $ExtractRoot)) {
    Write-Log "Extract root '$ExtractRoot' does not exist yet, creating it..." "WARN"
    New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
}

$iisStopped = $false

try {
    # -----------------------------------------------------------------
    # Step 1: Stop IIS
    # -----------------------------------------------------------------
    Stop-Iis
    $iisStopped = $true

    # -----------------------------------------------------------------
    # Step 3: Extract the package into D:\deployment\<package name>
    # -----------------------------------------------------------------
    $pkgBaseName  = [System.IO.Path]::GetFileNameWithoutExtension($PackagePath)
    $extractPath  = Join-Path $ExtractRoot $pkgBaseName

    Write-Log "Extracting package to '$extractPath'..." "STEP"
    if (Test-Path -LiteralPath $extractPath) {
        Write-Log "A previous extraction folder already exists, removing it first..." "WARN"
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }
    Expand-Archive -LiteralPath $PackagePath -DestinationPath $extractPath -Force
    Write-Log "Extraction complete." "OK"

    # The zip may contain a single top-level folder (e.g. "01 Publish
    # CareWebServiceV5 2026 v.2.0.0") rather than the files directly at the
    # root. If so, drill into it so we copy the actual app content.
    $items = Get-ChildItem -LiteralPath $extractPath
    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
        $sourceContentPath = $items[0].FullName
        Write-Log "Package root contains a single folder ('$($items[0].Name)'); using it as the content source."
    }
    else {
        $sourceContentPath = $extractPath
    }

    # -----------------------------------------------------------------
    # Step 4: If the package contains web.config, delete it
    # -----------------------------------------------------------------
    $webConfigPath = Join-Path $sourceContentPath "web.config"
    if (Test-Path -LiteralPath $webConfigPath) {
        Write-Log "web.config found in package - deleting it so the live server config is preserved..." "STEP"
        Remove-Item -LiteralPath $webConfigPath -Force
        Write-Log "web.config removed from package content." "OK"
    }
    else {
        Write-Log "No web.config present in this package (nothing to delete)."
    }

    # -----------------------------------------------------------------
    # Optional backup of the current live folder before overwrite
    # -----------------------------------------------------------------
    if (-not $NoBackup) {
        $backupPath = "{0}_backup_{1}" -f $TargetFolder.TrimEnd('\'), (Get-Date -Format "yyyyMMdd_HHmmss")
        Write-Log "Backing up current live folder to '$backupPath'..." "STEP"
        robocopy $TargetFolder $backupPath /E /R:2 /W:5 /NFL /NDL /NJH | Out-Null
        Write-Log "Backup complete." "OK"
    }
    else {
        Write-Log "Skipping backup (-NoBackup specified)." "WARN"
    }

    # -----------------------------------------------------------------
    # Step 5: Copy all package content into the live target folder
    # -----------------------------------------------------------------
    Write-Log "Copying package content into '$TargetFolder'..." "STEP"

    $robocopyArgs = @($sourceContentPath, $TargetFolder, "/E", "/R:3", "/W:5", "/NFL", "/NDL", "/NJH", "/NP")
    if ($Mirror) {
        Write-Log "Mirror mode enabled: files in the target that are not in the package WILL be deleted." "WARN"
        $robocopyArgs += "/MIR"
    }

    $robocopyOutput = & robocopy @robocopyArgs
    # Robocopy exit codes 0-7 are success/informational; 8+ indicate real errors.
    $rc = $LASTEXITCODE
    Write-Log ($robocopyOutput -join "`n")
    if ($rc -ge 8) {
        throw "robocopy reported errors while copying to '$TargetFolder' (exit code $rc)."
    }
    Write-Log "Deployment content copied successfully (robocopy exit code $rc)." "OK"

}
catch {
    Write-Log "DEPLOYMENT FAILED: $($_.Exception.Message)" "ERROR"
    throw
}
finally {
    # -----------------------------------------------------------------
    # Step 6: Always start IIS again, even if something above failed
    # -----------------------------------------------------------------
    if ($iisStopped) {
        try {
            Start-Iis
        }
        catch {
            Write-Log "FAILED TO RESTART IIS: $($_.Exception.Message)" "ERROR"
            Write-Log "Manually run 'iisreset /start' (or start the site/app pool) immediately." "ERROR"
        }
    }
}

Write-Log "===== CareWebServiceV5 Deployment finished successfully =====" "OK"
Write-Log "Full log saved to: $LogFile"
Read-Host "Press Enter to close"
