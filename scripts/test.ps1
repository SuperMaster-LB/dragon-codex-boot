[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# Offline verification: compile, run the launcher self-test, then the isolated shortcut and config suites.
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$integrate = Join-Path $PSScriptRoot 'build.ps1'
& $integrate
if (!$?) { throw '构建失败。' }
$appRoot = Join-Path $repo 'build\DragonCodexBoot'
$exe = Join-Path $appRoot 'DragonCodexBoot.exe'
if (!(Test-Path -LiteralPath $exe)) { throw "未找到构建产物：$exe" }

function Check([bool]$Condition, [string]$Name) {
    if (!$Condition) { throw ('FAILED: ' + $Name) }
    Write-Host ('  ok - ' + $Name)
}

Write-Host '[1/3] 启动器自检'
$expectedGeometryCases = 605
$expectedPlacementCases = 12
$qaPath = Join-Path $appRoot 'qa\self-test.json'
if (Test-Path -LiteralPath $qaPath) { Remove-Item -LiteralPath $qaPath -Force }
$proc = Start-Process -FilePath $exe -ArgumentList '--self-test' -WorkingDirectory $appRoot -Wait -PassThru
Check ($proc.ExitCode -eq 0) 'self-test 退出码为 0'
Check (Test-Path -LiteralPath $qaPath) '生成 qa\self-test.json'
$qa = Get-Content -LiteralPath $qaPath -Encoding UTF8 -Raw | ConvertFrom-Json
Check ($qa.ok -eq $true) '自检报告 ok=true'
Check ($qa.geometryCases -eq $expectedGeometryCases) "几何场景 $expectedGeometryCases 项"
Check ($qa.fixedPlacementCases -eq $expectedPlacementCases) "固定位置场景 $expectedPlacementCases 项"
$errorFile = Join-Path $appRoot 'self-test-error.txt'
if (Test-Path -LiteralPath $errorFile) { Remove-Item -LiteralPath $errorFile -Force }

Write-Host '[2/3] 隔离快捷方式测试'
& (Join-Path $repo 'tests\entrypoints-sandbox.tests.ps1') -AppRoot $appRoot

Write-Host '[3/3] 配置拒绝测试'
& (Join-Path $repo 'tests\config-rejection.tests.ps1') -AppRoot $appRoot

Write-Host 'ALL TESTS PASSED'
