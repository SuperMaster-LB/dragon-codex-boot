[CmdletBinding()]
param([switch]$WithoutMedia)
$ErrorActionPreference = 'Stop'
# Assembles the distributable runtime package from the fresh build output, the public
# config template and the repository demo video. Personal imports in the local build
# directory are never packaged: config and media always come from the repository.
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
& (Join-Path $PSScriptRoot 'build.ps1')
if (!$?) { throw '构建失败。' }

$version = (Get-Content -LiteralPath (Join-Path $repo 'VERSION') -Raw).Trim()
if (!$version) { throw 'VERSION 文件为空。' }
$dist = Join-Path $repo 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$suffix = 'with-video'
if ($WithoutMedia) { $suffix = 'without-video' }
$zipName = "DragonCodexBoot-$version-win-x64-$suffix.zip"
$zipPath = Join-Path $dist $zipName

$build = Join-Path $repo 'build\DragonCodexBoot'
if (!(Test-Path -LiteralPath (Join-Path $build 'DragonCodexBoot.exe'))) { throw "缺少构建产物：$build" }

$stage = Join-Path $dist 'stage'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $stage 'scripts'), (Join-Path $stage 'docs'), (Join-Path $stage 'media') -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $build 'DragonCodexBoot.exe') -Destination $stage -Force
Copy-Item -LiteralPath (Join-Path $repo 'config\launcher.example.json') -Destination (Join-Path $stage 'launcher.json') -Force
foreach ($name in 'LICENSE', 'README.md', 'CONTRIBUTING.md', 'THIRD_PARTY_NOTICES.md', 'VERSION',
    'Rescan-Entrypoints.cmd', 'Restore-Original-Entrypoints.cmd') {
    Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $stage -Force
}
foreach ($name in 'Import-Animation.ps1', 'install-start-menu.ps1', 'integrate-entrypoints.ps1') {
    Copy-Item -LiteralPath (Join-Path $repo ("scripts\" + $name)) -Destination (Join-Path $stage 'scripts') -Force
}
foreach ($name in 'CONFIGURATION.md', 'ENTRYPOINTS.md', 'TESTING.md', 'GITHUB.md') {
    Copy-Item -LiteralPath (Join-Path $repo ("docs\" + $name)) -Destination (Join-Path $stage 'docs') -Force
}

$demoVideo = Join-Path $repo 'media\startup.mp4'
$demoNotice = Join-Path $repo 'media\MEDIA_NOTICE.md'
if (!$WithoutMedia) {
    if (!(Test-Path -LiteralPath $demoVideo)) { throw "缺少仓库演示视频：$demoVideo" }
    Copy-Item -LiteralPath $demoVideo -Destination (Join-Path $stage 'media') -Force
    Copy-Item -LiteralPath $demoNotice -Destination (Join-Path $stage 'media') -Force
    $packagedHash = (Get-FileHash -LiteralPath (Join-Path $stage 'media\startup.mp4')).Hash
    if ($packagedHash -ne (Get-FileHash -LiteralPath $demoVideo).Hash) { throw '随附视频字节哈希与仓库不一致。' }
}

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
# ZipFile.CreateFromDirectory writes zip entries with forward slashes, matching the
# published package layout; Compress-Archive on Windows PowerShell 5.1 uses backslashes.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
("$hash  " + $zipName) | Set-Content -LiteralPath ($zipPath + '.sha256') -Encoding ascii

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    # .NET Framework's ZipArchiveEntry.FullName renders separators as backslashes
    # even when entries are stored with forward slashes; normalize before checking.
    $names = @($zip.Entries | ForEach-Object { ($_.FullName -replace '\\', '/') })
    if ($names -notcontains 'DragonCodexBoot.exe') { throw '程序包缺少 DragonCodexBoot.exe。' }
    if ($names -notcontains 'launcher.json') { throw '程序包缺少 launcher.json。' }
    if (!$WithoutMedia -and $names -notcontains 'media/startup.mp4') { throw '程序包缺少随附视频。' }
    if (!$WithoutMedia -and $names -notcontains 'media/MEDIA_NOTICE.md') { throw '程序包缺少媒体说明。' }
}
finally { $zip.Dispose() }
Remove-Item -LiteralPath $stage -Recurse -Force

Write-Host ("打包完成：" + $zipPath)
Write-Host ("SHA-256：" + $hash)
