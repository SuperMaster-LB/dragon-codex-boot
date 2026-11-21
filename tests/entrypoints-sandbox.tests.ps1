[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$AppRoot)
$ErrorActionPreference = 'Stop'
# Isolated .lnk tests: everything happens inside a temporary sandbox folder with an
# explicit -SearchRoots, so real desktop, Start menu and taskbar are never touched.
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$integrate = Join-Path $repo 'scripts\integrate-entrypoints.ps1'
$exe = Join-Path $AppRoot 'DragonCodexBoot.exe'
if (!(Test-Path -LiteralPath $exe)) { throw '先运行 scripts\build.ps1 生成构建产物。' }

function Check([bool]$Condition, [string]$Name) {
    if (!$Condition) { throw ('FAILED: ' + $Name) }
    Write-Host ('  ok - ' + $Name)
}
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-Report {
    Get-Content -LiteralPath (Join-Path $AppRoot '.integration\report.json') -Encoding UTF8 -Raw | ConvertFrom-Json
}
function Get-State {
    Get-Content -LiteralPath (Join-Path $AppRoot '.integration\entrypoints-state.json') -Encoding UTF8 -Raw | ConvertFrom-Json
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('DragonCodexBootTests-' + [Guid]::NewGuid().ToString('N'))
$links = Join-Path $sandbox 'links'
$app = Join-Path $sandbox 'app'
New-Item -ItemType Directory -Path $links, (Join-Path $links 'sub'), $app -Force | Out-Null
$fake = Join-Path $app 'FakeClient.exe'
Set-Content -LiteralPath $fake -Value 'M' -NoNewline -Encoding ascii

$shell = New-Object -ComObject WScript.Shell
function Make-Link([string]$Path, [string]$Target, [string]$Icon) {
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath = $Target
    $link.WorkingDirectory = Split-Path -Parent $Target
    $link.IconLocation = $Icon
    $link.Save()
}
$main = Join-Path $links 'FakeClient.lnk'
$deep = Join-Path $links 'sub\DeepLink.lnk'
$other = Join-Path $links 'Notepad.lnk'
Make-Link $main $fake 'imageres.dll,-101'
Make-Link $deep $fake 'shell32.dll,-5'
Make-Link $other "$env:WINDIR\notepad.exe" "$env:WINDIR\notepad.exe,0"
$origMain = Hash $main
$origDeep = Hash $deep
$origOther = Hash $other
$installedSnapshot = Join-Path $sandbox 'installed-main.lnk.bak'

$configPath = Join-Path $AppRoot 'launcher.json'
$configSnapshot = [IO.File]::ReadAllBytes($configPath)
$integrationDir = Join-Path $AppRoot '.integration'
try {
    if (Test-Path -LiteralPath $integrationDir) { Remove-Item -LiteralPath $integrationDir -Recurse -Force }

    Write-Host '  -- 安装：精确匹配、递归发现、图标保留、逐字节备份'
    & $integrate -Action Install -AppRoot $AppRoot -SearchRoots $links -OfficialExecutablePaths $fake -NoCreateDefaultLinks -ScanBudgetSeconds 60
    $report = Get-Report
    Check ($report.Replaced -eq 2) '两个官方 .lnk 被替换'
    Check (@($report.Errors).Count -eq 0) '安装无错误'
    Check ($report.LinksInspected -ge 3) '扫描了 3 个以上快捷方式'
    $state = Get-State
    Check (@($state.Entries).Count -eq 2) '状态记录 2 个条目'
    foreach ($entry in @($state.Entries)) {
        Check ($entry.OriginalExists -eq $true) ('记录了原始备份存在：' + $entry.Path)
        Check ((Test-Path -LiteralPath $entry.OriginalBackup) -and ((Hash $entry.OriginalBackup) -eq $entry.OriginalSHA256)) ('备份逐字节一致：' + $entry.Path)
    }
    $mainLink = $shell.CreateShortcut($main)
    Check ([string]::Equals($mainLink.TargetPath, $exe, [StringComparison]::OrdinalIgnoreCase)) '主 .lnk 指向启动器'
    Check ([string]::Equals($mainLink.WorkingDirectory, $AppRoot, [StringComparison]::OrdinalIgnoreCase)) '工作目录为程序目录'
    Check ($mainLink.IconLocation -eq 'imageres.dll,-101') '图标保留'
    Check ($mainLink.Arguments -eq '') '无附加参数'
    Check ((Hash $deep) -ne $origDeep) '递归发现深层 .lnk 并替换'
    Check ((Hash $other) -eq $origOther) '非官方 .lnk 原样保留（精确匹配）'
    $installedMain = Hash $main
    Copy-Item -LiteralPath $main -Destination $installedSnapshot -Force

    Write-Host '  -- 重复安装'
    & $integrate -Action Install -AppRoot $AppRoot -SearchRoots $links -OfficialExecutablePaths $fake -NoCreateDefaultLinks -ScanBudgetSeconds 60
    $report = Get-Report
    Check ($report.AlreadyOwned -eq 2 -and $report.Replaced -eq 0) '重复安装不改动'
    $state = Get-State
    Check (@($state.Entries).Count -eq 2) '不产生重复记录'
    Check ((Hash $main) -eq $installedMain) '安装哈希未变化'

    Write-Host '  -- 校验'
    & $integrate -Action Verify -AppRoot $AppRoot
    $report = Get-Report
    Check ($report.AlreadyOwned -eq 2) 'Verify 确认 2 个归属条目'

    Write-Host '  -- 用户改动保留'
    $userLink = $shell.CreateShortcut($main)
    $userLink.Arguments = '/user-edit'
    $userLink.Save()
    & $integrate -Action Install -AppRoot $AppRoot -SearchRoots $links -OfficialExecutablePaths $fake -NoCreateDefaultLinks -ScanBudgetSeconds 60
    $report = Get-Report
    $preserved = @($report.Preserved | Where-Object { [string]::Equals($_.Path, $main, [StringComparison]::OrdinalIgnoreCase) })
    Check ($preserved.Count -eq 1) '用户改动不被覆盖'
    Copy-Item -LiteralPath $installedSnapshot -Destination $main -Force
    Check ((Hash $main) -eq $installedMain) '恢复到安装态后哈希一致'

    Write-Host '  -- 恢复：逐字节还原'
    & $integrate -Action Restore -AppRoot $AppRoot
    $report = Get-Report
    Check ($report.Restored -eq 2) '恢复 2 个条目'
    Check (@($report.Errors).Count -eq 0) '恢复无错误'
    Check ((Hash $main) -eq $origMain) '主 .lnk 逐字节还原'
    Check ((Hash $deep) -eq $origDeep) '深层 .lnk 逐字节还原'
    Check ((Hash $other) -eq $origOther) '未参与的 .lnk 不受影响'

    Write-Host '  -- 恢复后 Auto 不重装'
    & $integrate -Action Auto -AppRoot $AppRoot -SearchRoots $links -OfficialExecutablePaths $fake -NoCreateDefaultLinks -ScanBudgetSeconds 60
    Check ((Hash $main) -eq $origMain -and (Hash $deep) -eq $origDeep) 'Auto 运行后链接保持原始状态'

    Write-Host '  -- 配置关闭 AutoReplaceEntrypoints'
    Remove-Item -LiteralPath $integrationDir -Recurse -Force
    $disabled = [Text.Encoding]::UTF8.GetString($configSnapshot) -replace '"AutoReplaceEntrypoints"\s*:\s*true', '"AutoReplaceEntrypoints": false'
    [IO.File]::WriteAllText($configPath, $disabled)
    & $integrate -Action Auto -AppRoot $AppRoot -SearchRoots $links -OfficialExecutablePaths $fake -NoCreateDefaultLinks -ScanBudgetSeconds 60
    $report = Get-Report
    Check ($report.Status -eq 'Disabled') 'Auto 在配置关闭时直接返回 Disabled'
    Check ((Hash $main) -eq $origMain) '关闭状态下未替换任何链接'

    Write-Host '  -- 损坏备份拒绝恢复'
    [IO.File]::WriteAllBytes($configPath, $configSnapshot)
    Remove-Item -LiteralPath $integrationDir -Recurse -Force
    & $integrate -Action Install -AppRoot $AppRoot -SearchRoots $links -OfficialExecutablePaths $fake -NoCreateDefaultLinks -ScanBudgetSeconds 60
    $report = Get-Report
    Check ($report.Replaced -eq 2) '重新安装成功'
    $state = Get-State
    foreach ($entry in @($state.Entries)) {
        [IO.File]::AppendAllText($entry.OriginalBackup, 'corrupted')
    }
    & $integrate -Action Restore -AppRoot $AppRoot
    $report = Get-Report
    Check (@($report.Errors).Count -eq 2) '两个损坏备份都报错'
    $mainLink = $shell.CreateShortcut($main)
    Check ([string]::Equals($mainLink.TargetPath, $exe, [StringComparison]::OrdinalIgnoreCase)) '损坏备份不覆盖已安装链接'
}
finally {
    [IO.File]::WriteAllBytes($configPath, $configSnapshot)
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
    if (Test-Path -LiteralPath $integrationDir) { Remove-Item -LiteralPath $integrationDir -Recurse -Force }
}
Write-Host '  ok - 隔离快捷方式测试全部通过'
