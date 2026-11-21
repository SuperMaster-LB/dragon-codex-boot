[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$AppRoot)
$ErrorActionPreference = 'Stop'
# Invalid launcher.json variants must be rejected headlessly: the launcher writes
# self-test-error.txt next to the executable and exits with code 1.
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$exe = Join-Path $AppRoot 'DragonCodexBoot.exe'
if (!(Test-Path -LiteralPath $exe)) { throw '先运行 scripts\build.ps1 生成构建产物。' }
$configPath = Join-Path $AppRoot 'launcher.json'
$example = Get-Content -LiteralPath $configPath -Encoding UTF8 -Raw | ConvertFrom-Json

function Check([bool]$Condition, [string]$Name) {
    if (!$Condition) { throw ('FAILED: ' + $Name) }
    Write-Host ('  ok - ' + $Name)
}

function New-ConfigFromExample {
    param([scriptblock]$Mutate)
    $copy = $example | ConvertTo-Json -Depth 12
    $obj = $copy | ConvertFrom-Json
    & $Mutate $obj
    $obj | ConvertTo-Json -Depth 12
}

$cases = [ordered]@{
    'empty ProcessNames'       = { param($o) $o.ProcessNames = @() }
    'single ScreenFrame'        = { param($o) $o.ScreenFrames = @($o.ScreenFrames[0]) }
    'TransitionStart <= HoldAt' = { param($o) $o.TransitionStart = $o.HoldAt }
    'Volume out of range'       = { param($o) $o.Volume = 2 }
    'missing Video'             = { param($o) $o.PSObject.Properties.Remove('Video') }
    'AppLaunch invalid form'    = { param($o) $o.AppLaunch = 'Codex' }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('DragonCodexBootCfgTests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    foreach ($name in $cases.Keys) {
        $caseDir = Join-Path $tempRoot ($name -replace '[^A-Za-z0-9]', '_')
        New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
        Copy-Item -LiteralPath $exe -Destination (Join-Path $caseDir 'DragonCodexBoot.exe') -Force
        $badJson = New-ConfigFromExample $cases[$name]
        [IO.File]::WriteAllText((Join-Path $caseDir 'launcher.json'), $badJson)
        $errorFile = Join-Path $caseDir 'self-test-error.txt'
        $proc = Start-Process -FilePath (Join-Path $caseDir 'DragonCodexBoot.exe') -ArgumentList '--self-test' -WorkingDirectory $caseDir -Wait -PassThru
        Check ($proc.ExitCode -eq 1) ("拒绝并退出 1：" + $name)
        Check (Test-Path -LiteralPath $errorFile) ("写入 self-test-error.txt：" + $name)
    }
    $invalidJsonDir = Join-Path $tempRoot 'invalid_json'
    New-Item -ItemType Directory -Path $invalidJsonDir -Force | Out-Null
    Copy-Item -LiteralPath $exe -Destination (Join-Path $invalidJsonDir 'DragonCodexBoot.exe') -Force
    [IO.File]::WriteAllText((Join-Path $invalidJsonDir 'launcher.json'), '{ not valid json')
    $errorFile = Join-Path $invalidJsonDir 'self-test-error.txt'
    $proc = Start-Process -FilePath (Join-Path $invalidJsonDir 'DragonCodexBoot.exe') -ArgumentList '--self-test' -WorkingDirectory $invalidJsonDir -Wait -PassThru
    Check ($proc.ExitCode -eq 1) '拒绝并退出 1：无法解析的 JSON'
    Check (Test-Path -LiteralPath $errorFile) '写入 self-test-error.txt：无法解析的 JSON'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-Host '  ok - 配置拒绝测试全部通过'
