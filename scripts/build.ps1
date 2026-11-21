[CmdletBinding()]
param([string]$IconPath)
$ErrorActionPreference = 'Stop'
# Builds the launcher with the in-box .NET Framework C# compiler into build/DragonCodexBoot.
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out = Join-Path $repo 'build\DragonCodexBoot'
New-Item -ItemType Directory -Path $out -Force | Out-Null

$frameworkCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319"
) | Where-Object { Test-Path -LiteralPath $_ }
if (!$frameworkCandidates) { throw '未找到 .NET Framework 4.x 编译目录。Windows 10/11 自带，无需另外安装。' }
$fw = $frameworkCandidates[0]
$csc = Join-Path $fw 'csc.exe'
if (!(Test-Path -LiteralPath $csc)) { throw "未找到编译器：$csc" }

$refs = @(
    (Join-Path $fw 'System.dll'),
    (Join-Path $fw 'System.Core.dll'),
    (Join-Path $fw 'System.Web.Extensions.dll'),
    (Join-Path $fw 'WPF\PresentationFramework.dll'),
    (Join-Path $fw 'WPF\PresentationCore.dll'),
    (Join-Path $fw 'WPF\WindowsBase.dll'),
    (Join-Path $fw 'System.Xaml.dll')
)
foreach ($r in $refs) { if (!(Test-Path -LiteralPath $r)) { throw "缺少引用程序集：$r" } }

$exeOut = Join-Path $out 'DragonCodexBoot.exe'
$cscArgs = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    ('/out:' + $exeOut),
    ('/win32manifest:' + (Join-Path $repo 'src\app.manifest')))
if ($IconPath) {
    $resolvedIcon = (Resolve-Path -LiteralPath $IconPath).Path
    if ([IO.Path]::GetExtension($resolvedIcon) -ine '.ico') { throw '-IconPath 需要指向 .ico 文件。' }
    $cscArgs += ('/win32icon:' + $resolvedIcon)
}
foreach ($r in $refs) { $cscArgs += ('/r:' + $r) }
$cscArgs += (Join-Path $repo 'src\DragonCodexBoot.cs')
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc 编译失败，退出码 $LASTEXITCODE。" }

# Assemble the runtime layout next to the executable.
$runtimeScripts = 'Import-Animation.ps1', 'install-start-menu.ps1', 'integrate-entrypoints.ps1'
$runtimeDocs = 'CONFIGURATION.md', 'ENTRYPOINTS.md', 'TESTING.md', 'GITHUB.md'
$runtimeRootFiles = 'LICENSE', 'README.md', 'CONTRIBUTING.md', 'THIRD_PARTY_NOTICES.md', 'VERSION',
    'Rescan-Entrypoints.cmd', 'Restore-Original-Entrypoints.cmd'

New-Item -ItemType Directory -Path (Join-Path $out 'scripts'), (Join-Path $out 'docs'), (Join-Path $out 'media') -Force | Out-Null
foreach ($name in $runtimeScripts) { Copy-Item -LiteralPath (Join-Path $repo ("scripts\" + $name)) -Destination (Join-Path $out 'scripts') -Force }
foreach ($name in $runtimeDocs) { Copy-Item -LiteralPath (Join-Path $repo ("docs\" + $name)) -Destination (Join-Path $out 'docs') -Force }
foreach ($name in $runtimeRootFiles) { Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $out -Force }
Copy-Item -LiteralPath (Join-Path $repo 'media\MEDIA_NOTICE.md') -Destination (Join-Path $out 'media') -Force

# Public config template becomes the live launcher.json on first build; later builds keep user edits.
$liveConfig = Join-Path $out 'launcher.json'
if (!(Test-Path -LiteralPath $liveConfig)) {
    Copy-Item -LiteralPath (Join-Path $repo 'config\launcher.example.json') -Destination $liveConfig -Force
}

# Ship the repository demo video only when the build target has none yet; never overwrite an imported one.
$demoVideo = Join-Path $repo 'media\startup.mp4'
if ((Test-Path -LiteralPath $demoVideo) -and !(Test-Path -LiteralPath (Join-Path $out 'media\startup.mp4'))) {
    Copy-Item -LiteralPath $demoVideo -Destination (Join-Path $out 'media') -Force
}

Write-Host ("构建完成：" + $exeOut)
