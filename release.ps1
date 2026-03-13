<#
.SYNOPSIS
    Build and publish a new release of Work Timer.

.PARAMETER Version
    New version string, e.g. "1.0.2". Build number is auto-incremented.

.PARAMETER Token
    GitHub personal access token. Defaults to $env:GITHUB_TOKEN.

.EXAMPLE
    .\release.ps1 -Version 1.0.2
    .\release.ps1 -Version 1.0.2 -Token ghp_xxxx
#>
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [string]$Token = $env:GITHUB_TOKEN
)

$ErrorActionPreference = 'Stop'
$Repo = 'templeboss/timer'
$Root = $PSScriptRoot

# ── Helpers ────────────────────────────────────────────────────────────────────

function Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Die([string]$msg)  { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

function Invoke-GitHub {
    param([string]$Method, [string]$Uri, $Body, [string]$InFile, [string]$ContentType)
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json' }
    $params  = @{ Method = $Method; Uri = $Uri; Headers = $headers; ErrorAction = 'Stop' }
    if ($Body)        { $params.Body        = ($Body | ConvertTo-Json -Depth 5) }
    if ($InFile)      { $params.InFile      = $InFile }
    if ($ContentType) { $params.ContentType = $ContentType }
    else              { $params.ContentType = 'application/json' }
    Invoke-RestMethod @params
}

# ── Validate ───────────────────────────────────────────────────────────────────

if (-not $Token) { Die "No GitHub token. Set `$env:GITHUB_TOKEN or pass -Token." }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { Die "Version must be x.y.z (e.g. 1.0.2)" }

Set-Location $Root

# ── 1. Bump pubspec.yaml ───────────────────────────────────────────────────────

Step "Bumping version to $Version"

$pubspec = Get-Content pubspec.yaml -Raw
$pubspec -match 'version:\s*(\d+\.\d+\.\d+)\+(\d+)' | Out-Null
if (-not $Matches) { Die "Could not parse version from pubspec.yaml" }

$oldBuild = [int]$Matches[2]
$newBuild  = $oldBuild + 1
$pubspec   = $pubspec -replace "version:\s*\d+\.\d+\.\d+\+\d+", "version: $Version+$newBuild"
Set-Content pubspec.yaml $pubspec -NoNewline
Write-Host "  $($Matches[1])+$oldBuild  ->  $Version+$newBuild"

# ── 2. Kill any running instance ───────────────────────────────────────────────

Step "Stopping running timer_app.exe (if any)"
Get-Process timer_app -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

# ── 3. Build ───────────────────────────────────────────────────────────────────

Step "Building Windows release"
flutter build windows --release
if ($LASTEXITCODE -ne 0) { Die "Windows build failed" }

Step "Building Android APK"
flutter build apk --release
if ($LASTEXITCODE -ne 0) { Die "Android build failed" }

# ── 4. Package Windows zip ─────────────────────────────────────────────────────

Step "Packaging Windows zip"
$winZip = "$Root\work-timer-windows-v$Version.zip"
$winDir = "$Root\build\windows\x64\runner\Release"
if (Test-Path $winZip) { Remove-Item $winZip }
Compress-Archive -Path "$winDir\*" -DestinationPath $winZip
Write-Host "  $winZip"

$apkPath = "$Root\build\app\outputs\flutter-apk\app-release.apk"

# ── 5. Commit + tag + push ─────────────────────────────────────────────────────

Step "Committing version bump"
git add pubspec.yaml
git commit -m "chore: bump version to $Version"
if ($LASTEXITCODE -ne 0) { Die "git commit failed" }

Step "Tagging and pushing"
git tag "v$Version"
git push
git push origin "v$Version"
if ($LASTEXITCODE -ne 0) { Die "git push failed" }

# ── 6. Create GitHub release ───────────────────────────────────────────────────

Step "Creating GitHub release v$Version"
$release = Invoke-GitHub -Method POST `
    -Uri "https://api.github.com/repos/$Repo/releases" `
    -Body @{
        tag_name = "v$Version"
        name     = "v$Version"
        body     = "Release $Version"
        draft    = $false
        prerelease = $false
    }
$uploadBase = $release.upload_url -replace '\{.*\}', ''
Write-Host "  Release id: $($release.id)"

# ── 7. Upload assets ───────────────────────────────────────────────────────────

Step "Uploading Windows zip"
Invoke-GitHub -Method POST `
    -Uri "${uploadBase}?name=work-timer-windows-v$Version.zip" `
    -InFile $winZip `
    -ContentType 'application/zip' | Out-Null
Write-Host "  Uploaded $(Split-Path $winZip -Leaf)"

Step "Uploading Android APK"
Invoke-GitHub -Method POST `
    -Uri "${uploadBase}?name=work-timer-android-v$Version.apk" `
    -InFile $apkPath `
    -ContentType 'application/vnd.android.package-archive' | Out-Null
Write-Host "  Uploaded work-timer-android-v$Version.apk"

# ── Done ───────────────────────────────────────────────────────────────────────

Write-Host "`nDone! https://github.com/$Repo/releases/tag/v$Version" -ForegroundColor Green
