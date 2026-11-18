<#
.SYNOPSIS
  Buat/publish repositori GitHub untuk Resi58 (landing page + app-ads.txt + release APK + GitHub Pages).

.DESCRIPTION
  Tidak butuh git/gh CLI. Semua lewat GitHub REST API dengan token milikmu.
  Token TIDAK disimpan ke file manapun — hanya dipakai di memori sesi ini.

.PARAMETER Owner
  Username GitHub kamu (mis. "hardiviper").

.PARAMETER Token
  Personal Access Token (classic) dengan scope "repo". Dibuat di:
  github.com -> Settings -> Developer settings -> Personal access tokens -> Tokens (classic) -> Generate new token
  Centang scope: repo (full control of private repositories). Kedaluwarsa bebas.

.PARAMETER Repo
  Nama repo (default "resi58").

.PARAMETER ApkPath
  Path ke APK rilis. Default: ..\Pdf58Android\app\build\outputs\apk\release\app-release.apk (relatif ke folder ini).

.PARAMETER Tag
  Tag rilis (default "v1.0.0").

.EXAMPLE
  .\publish-github.ps1 -Owner "hardiviper" -Token "ghp_xxxxxxxxxxxxxxxxxxxx"
#>
param(
    [Parameter(Mandatory)] [string]$Owner,
    [Parameter(Mandatory)] [string]$Token,
    [string]$Repo = "resi58",
    [string]$ApkPath = "..\Pdf58Android\app\build\outputs\apk\release\app-release.apk",
    [string]$Tag = "v1.0.0"
)

$ErrorActionPreference = "Stop"
$Api = "https://api.github.com"
$Headers = @{ Authorization = "token $Token"; "User-Agent" = "resi58-publish"; Accept = "application/vnd.github+json" }

function Invoke-GitHub {
    param([string]$Method, [string]$Uri, [object]$Body = $null, [hashtable]$ExtraHeaders = $null)
    $h = $Headers.Clone()
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] } }
    $params = @{ Method = $Method; Uri = $Uri; Headers = $h }
    if ($Body -ne $null) { $params.Body = ($Body | ConvertTo-Json -Depth 10); $params.ContentType = "application/json" }
    try {
        return Invoke-RestMethod @params
    } catch {
        $msg = $_.ErrorDetails.Message
        if (-not $msg) { $msg = $_.Exception.Message }
        Write-Host "  ! $Method $Uri -> $msg" -ForegroundColor Red
        throw
    }
}

function Put-File {
    param([string]$Path, [string]$LocalFile, [string]$Message = "Add $Path")
    # Jika file sudah ada, ambil sha dulu supaya update (idempotent).
    $sha = $null
    try {
        $existing = Invoke-RestMethod -Method Get -Uri "$Api/repos/$Owner/$Repo/contents/$Path" -Headers $Headers
        $sha = $existing.sha
    } catch { }
    $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($LocalFile))
    $body = @{ message = $Message; content = $content }
    if ($sha) { $body.sha = $sha }
    try {
        Invoke-GitHub -Method Put -Uri "$Api/repos/$Owner/$Repo/contents/$Path" -Body $body | Out-Null
        Write-Host "  OK: $Path" -ForegroundColor Green
    } catch {
        Write-Host "  GAGAL upload $Path" -ForegroundColor Red
        throw
    }
}

# ---------- 0. Cek file ----------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$readmePath = Join-Path $scriptDir "README.md"
$adsPath = Join-Path $scriptDir "app-ads.txt"
$ignorePath = Join-Path $scriptDir ".gitignore"
$apkFull = if ([IO.Path]::IsPathRooted($ApkPath)) { $ApkPath } else { Join-Path $scriptDir $ApkPath }
foreach ($f in @($readmePath, $adsPath, $ignorePath)) {
    if (-not (Test-Path $f)) { throw "File tidak ditemukan: $f" }
}
if (-not (Test-Path $apkFull)) { throw "APK tidak ditemukan: $apkFull" }

# ---------- 1. Buat repo ----------
Write-Host "`n[1/5] Membuat repositori '$Repo' (public)..." -ForegroundColor Cyan
$repoBody = @{ name = $Repo; description = "Resi58 - konvert PDF resi A6 jadi potongan 58mm untuk printer thermal (Android 8+)."; private = $false; auto_init = $false; has_issues = $true; has_wiki = $false }
try {
    Invoke-GitHub -Method Post -Uri "$Api/user/repos" -Body $repoBody | Out-Null
    Write-Host "  repo dibuat." -ForegroundColor Green
} catch {
    if ($_.Exception.Message -match "already exists") {
        Write-Host "  repo sudah ada, lanjut." -ForegroundColor Yellow
    } else { throw }
}

# ---------- 2. Upload file (README dengan OWNER diganti) ----------
Write-Host "`n[2/5] Upload README.md, app-ads.txt, .gitignore..." -ForegroundColor Cyan
# README dengan placeholder {{OWNER}} diganti
$readmeText = (Get-Content $readmePath -Raw) -replace '{{OWNER}}', $Owner
$tmpReadme = Join-Path $env:TEMP "resi58-README.md"
[IO.File]::WriteAllText($tmpReadme, $readmeText, [Text.Encoding]::UTF8)
Put-File -Path "README.md" -LocalFile $tmpReadme -Message "Add README"
Put-File -Path "app-ads.txt" -LocalFile $adsPath -Message "Add app-ads.txt"
Put-File -Path ".gitignore" -LocalFile $ignorePath -Message "Add .gitignore"
Remove-Item $tmpReadme -Force -ErrorAction SilentlyContinue

# ---------- 3. Buat rilis ----------
Write-Host "`n[3/5] Membuat rilis $Tag..." -ForegroundColor Cyan
$releaseUri = "$Api/repos/$Owner/$Repo/releases"
$releaseBody = @{ tag_name = $Tag; name = "Resi58 $Tag"; body = "Rilis pertama Resi58: konvert PDF resi A6 -> potongan 58mm untuk printer thermal. Android 8+. APK signed (release)."; draft = $false; prerelease = $false }
$release = $null
try {
    $release = Invoke-GitHub -Method Post -Uri $releaseUri -Body $releaseBody
    Write-Host "  rilis dibuat." -ForegroundColor Green
} catch {
    if ($_.Exception.Message -match "already exists") {
        Write-Host "  rilis sudah ada, ambil yang existing." -ForegroundColor Yellow
        $release = Invoke-RestMethod -Method Get -Uri "$Api/repos/$Owner/$Repo/releases/tags/$Tag" -Headers $Headers
    } else { throw }
}

# ---------- 4. Upload APK ----------
Write-Host "`n[4/5] Upload APK ke rilis..." -ForegroundColor Cyan
$uploadBase = $release.upload_url -replace '\{\?name,label\}', ''
$assetName = "Resi58.apk"
$uploadUri = "${uploadBase}?name=$assetName"
# Hapus asset lama jika ada (idempotent)
try {
    $assets = Invoke-RestMethod -Method Get -Uri "$Api/repos/$Owner/$Repo/releases/$($release.id)/assets" -Headers $Headers
    $old = $assets | Where-Object { $_.name -eq $assetName }
    if ($old) {
        Invoke-RestMethod -Method Delete -Uri "$Api/repos/$Owner/$Repo/releases/assets/$($old.id)" -Headers $Headers | Out-Null
        Write-Host "  asset lama dihapus." -ForegroundColor Yellow
    }
} catch { }
$bytes = [IO.File]::ReadAllBytes($apkFull)
$assetHeaders = $Headers.Clone()
$assetHeaders["Content-Type"] = "application/vnd.android.package-archive"
$assetHeaders["Content-Length"] = $bytes.Length
try {
    $asset = Invoke-RestMethod -Method Post -Uri $uploadUri -Headers $assetHeaders -Body $bytes
    Write-Host "  APK terupload: $($asset.browser_download_url)" -ForegroundColor Green
} catch {
    Write-Host "  GAGAL upload APK: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

# ---------- 5. Aktifkan GitHub Pages ----------
Write-Host "`n[5/5] Mengaktifkan GitHub Pages..." -ForegroundColor Cyan
try {
    Invoke-GitHub -Method Post -Uri "$Api/repos/$Owner/$Repo/pages" -Body @{ source = @{ branch = "main"; path = "/" } } | Out-Null
    Write-Host "  Pages diaktifkan." -ForegroundColor Green
} catch {
    if ($_.Exception.Message -match "already exists|409") {
        Write-Host "  Pages sudah aktif." -ForegroundColor Yellow
    } else {
        Write-Host "  Pages gagal diaktifkan (bisa diaktifkan manual: Settings -> Pages -> Source: main). $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ---------- Selesai ----------
$repoUrl = "https://github.com/$Owner/$Repo"
$releaseUrl = "https://github.com/$Owner/$Repo/releases/tag/$Tag"
$apkUrl = "https://github.com/$Owner/$Repo/releases/download/$Tag/app-release.apk"
$pagesUrl = "https://$Owner.github.io/$Repo/"
$adsUrl = "https://$Owner.github.io/$Repo/app-ads.txt"

Write-Host "`n================ HASIL ================" -ForegroundColor Cyan
Write-Host "Repo        : $repoUrl"
Write-Host "Rilis       : $releaseUrl"
Write-Host "Unduhan APK : $apkUrl"
Write-Host "Pages       : $pagesUrl"
Write-Host "app-ads.txt : $adsUrl"
Write-Host ""
Write-Host "Langkah terakhir (manual, 1 menit):" -ForegroundColor Yellow
Write-Host "  1. Buka $repoUrl/settings/pages -> pastikan Source = 'Deploy from branch' -> Branch 'main' -> Save"
Write-Host "  2. Tunggu 1-2 menit lalu buka $adsUrl (harus bisa diakses publik)"
Write-Host "  3. Start.io: masukkan App URL = $repoUrl (atau $pagesUrl) di portal"
Write-Host "  4. (Opsional) Pasang custom domain nanti kalau sudah punya website"
Write-Host ""
Write-Host "Token TIDAK disimpan ke file. Sesi ini selesai." -ForegroundColor Green
