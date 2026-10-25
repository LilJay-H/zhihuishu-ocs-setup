#Requires -Version 5.1
[CmdletBinding()]
param([string]$Destination, [switch]$DownloadOnly, [switch]$Launch)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 renders Invoke-WebRequest progress per chunk, which slows a ~270 MB download dramatically.
$ProgressPreference = 'SilentlyContinue'

function Get-OcsProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $Default
}

function Get-OcsReleaseAsset {
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/ocsjs/ocs-desktop/releases/latest' -Headers @{
        'User-Agent' = 'zhihuishu-ocs-setup'; Accept = 'application/vnd.github+json'
    } -TimeoutSec 30
    if ((Get-OcsProperty $release 'draft' $true) -or (Get-OcsProperty $release 'prerelease' $true)) {
        throw 'Expected an official stable release.'
    }
    $tag = [string](Get-OcsProperty $release 'tag_name' '')
    if ($tag -notmatch '^v?\d+\.\d+\.\d+$') { throw 'Unsupported release version; use the official download page.' }
    $name = 'ocs-' + ($tag -replace '^v', '') + '-setup-win-x64.exe'
    $assets = @(@(Get-OcsProperty $release 'assets' @()) | Where-Object { (Get-OcsProperty $_ 'name' '') -ceq $name })
    if ($assets.Count -ne 1) { throw 'Expected exactly one Windows x64 installer.' }
    $asset = $assets[0]
    $url = 'https://github.com/ocsjs/ocs-desktop/releases/download/' + $tag + '/' + $name
    if ((Get-OcsProperty $asset 'browser_download_url' '') -cne $url) { throw 'Unexpected official asset URL.' }
    $size = [long](Get-OcsProperty $asset 'size' 0)
    $digest = [string](Get-OcsProperty $asset 'digest' '')
    if ($size -le 0 -or ($digest -and $digest -notmatch '^sha256:[0-9a-fA-F]{64}$')) { throw 'Invalid release size or SHA256.' }
    [pscustomobject]@{ tag=$tag; fileName=$name; url=$url; expectedBytes=$size; publishedDigest=$digest }
}

function Test-OcsArtifact {
    param([string]$Path, [long]$ExpectedBytes, [string]$PublishedDigest)
    if ($ExpectedBytes -le 0) { throw 'ExpectedBytes must be positive.' }
    if ($PublishedDigest -and $PublishedDigest -notmatch '^sha256:[0-9a-fA-F]{64}$') { throw 'Invalid SHA-256 digest.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ ok = $false; reason = 'missing'; integrity = 'none'; sha256 = $null; bytes = 0 }
    }
    $file = Get-Item -LiteralPath $Path
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $reason = 'verified'
    if ($file.Length -ne $ExpectedBytes) { $reason = 'size_mismatch' }
    elseif ($PublishedDigest -and ('sha256:' + $hash) -ine $PublishedDigest) { $reason = 'digest_mismatch' }
    $integrity = 'none'
    if ($reason -eq 'verified') {
        $integrity = 'size_only'
        if ($PublishedDigest) { $integrity = 'publisher_sha256' }
    }
    [pscustomobject][ordered]@{ ok = ($reason -eq 'verified'); reason = $reason; integrity = $integrity; sha256 = $hash; bytes = $file.Length }
}

function Save-OcsArtifact {
    param($Asset, [string]$Folder)
    $root = [IO.Path]::GetFullPath($Folder)
    # fileName is constructed from a validated version, never a user-supplied path.
    $target = Join-Path $root $Asset.fileName
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root | Out-Null }
    $reused = Test-Path -LiteralPath $target
    if ($reused) {
        $check = Test-OcsArtifact $target $Asset.expectedBytes $Asset.publishedDigest
        if (-not $check.ok) { throw ('Existing file differs; preserved without overwrite: ' + $target) }
    } else {
        $partial = $target + '.' + [guid]::NewGuid().ToString('N') + '.partial'
        try {
            # Generous limit: depending on the PowerShell version the timeout may cover the whole ~270 MB transfer.
            Invoke-WebRequest -Uri $Asset.url -OutFile $partial -UseBasicParsing -TimeoutSec 1800 | Out-Null
            $check = Test-OcsArtifact $partial $Asset.expectedBytes $Asset.publishedDigest
            if (-not $check.ok) { throw ('Rejected download: ' + $check.reason) }
            [IO.File]::Move($partial, $target)
        } catch { throw ('Download failed; any partial file remains at ' + $partial + '. ' + $_.Exception.Message) }
    }
    [pscustomobject]@{ file=$target; reused=$reused; verification=$check }
}

function Get-OcsDesktopInstallation {
    $candidates = @()
    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) {
            $relative = 'OCS Desktop\OCS Desktop.exe'
            if ($base -eq $env:LOCALAPPDATA) { $relative = 'Programs\' + $relative }
            $candidates += Join-Path $base $relative
        }
    }
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($entry in @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)) {
            if ((Get-OcsProperty $entry 'DisplayName' '') -notmatch '^OCS Desktop(?:\s|$)') { continue }
            $location = Get-OcsProperty $entry 'InstallLocation' ''
            if ($location) { $candidates += Join-Path $location 'OCS Desktop.exe' }
        }
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $info = (Get-Item -LiteralPath $candidate).VersionInfo
            if ($info.ProductName -eq 'OCS Desktop') {
                return [pscustomobject]@{ path = $candidate; version = $info.FileVersion }
            }
        }
    }
    return $null
}

function Test-OcsNsisHeader {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $bytes = New-Object byte[] 1048576
        $read = $stream.Read($bytes, 0, $bytes.Length)
        return ($read -gt 2 -and $bytes[0] -eq 77 -and $bytes[1] -eq 90 -and
            [Text.Encoding]::ASCII.GetString($bytes, 0, $read).Contains('NullsoftInst'))
    } finally { $stream.Dispose() }
}

function Invoke-OcsInstallerProcess {
    param([string]$Path)
    $process = Start-Process -FilePath $Path -ArgumentList '/S' -WindowStyle Hidden -PassThru
    # Defensive: caching the handle keeps ExitCode readable after exit on all PowerShell versions.
    $null = $process.Handle
    # Large one-click NSIS payload; antivirus scanning can make extraction slow.
    if (-not $process.WaitForExit(600000)) {
        throw 'Installer has not exited after 10 minutes. Do not launch another copy; check it manually.'
    }
    $process.Refresh()
    return $process.ExitCode
}

function Start-OcsInstalledApp {
    param([string]$Path)
    # The app manifest requests highestAvailable, so admins may get a UAC prompt.
    # Declining it (or any launch error) must not hide an install that already succeeded.
    try { Start-Process -FilePath $Path | Out-Null; return $null }
    catch { return $_.Exception.Message }
}

function Invoke-OcsSetup {
    if (-not $DownloadOnly) {
        $existing = Get-OcsDesktopInstallation
        if ($existing) {
            $launchError = $null
            if ($Launch) { $launchError = Start-OcsInstalledApp $existing.path }
            return [pscustomobject]@{ status='already_installed'; installation=$existing; installerExecuted=$false; launchRequested=[bool]$Launch; launchError=$launchError }
        }
    }
    if ($env:OS -ne 'Windows_NT' -or $env:PROCESSOR_ARCHITECTURE -notin @('AMD64','x86') -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'Automatic setup supports Windows x64 only.'
    }
    if (-not $Destination) { $Destination = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\ocs-setup' }
    $asset = Get-OcsReleaseAsset
    if (-not $DownloadOnly -and -not $asset.publishedDigest) { throw 'Automatic execution requires a published SHA256; use -DownloadOnly for manual installation.' }
    $download = Save-OcsArtifact $asset $Destination
    if ($DownloadOnly) { return [pscustomobject]@{ status='downloaded'; artifact=$download; version=$asset.tag; installerExecuted=$false } }
    if (-not (Test-OcsNsisHeader $download.file)) { throw 'Unknown installer format; nothing executed.' }
    $exitCode = Invoke-OcsInstallerProcess $download.file
    if ($exitCode -ne 0) { throw ('Installer exited with code ' + $exitCode + '; no automatic retry.') }
    $installed = Get-OcsDesktopInstallation
    # Compare major.minor.patch only, tolerating 3- or 4-part FileVersion strings.
    $installedVersion = [regex]::Match([string](Get-OcsProperty $installed 'version' ''), '\d+\.\d+\.\d+').Value
    if (-not $installed -or -not $installedVersion -or [version]$installedVersion -ne [version]($asset.tag -replace '^v', '')) {
        throw 'Installer exited successfully but the expected executable/version was not detected.'
    }
    $launchError = $null
    if ($Launch) { $launchError = Start-OcsInstalledApp $installed.path }
    [pscustomobject]@{ status='installed'; installation=$installed; installerExecuted=$true; exitCode=$exitCode; artifact=$download; launchRequested=[bool]$Launch; launchError=$launchError }
}

# Importing defines functions only; it never downloads, installs or launches.
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-OcsSetup | ConvertTo-Json -Depth 6 }
    catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
}
