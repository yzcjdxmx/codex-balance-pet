<#
  install.ps1 — 把桌宠与 Codex 插件装到当前用户的 .codex 目录（可反复执行，幂等）

  做四件事：
    1. pet\                    -> <CodexHome>\pets\balance-pet\                     桌宠常驻副本
    2. plugin\                 -> <CodexHome>\local-marketplaces\balance\（含市场清单）
       并把桌宠的启动链（pet-host.ps1 / winless-launch.ps1 / scripts\launch_balance_pet.cmd）放进插件目录
    3. 在插件目录的 .mcp.json 里确保注册 balance 与 balance_pet 两个 MCP 服务
    4. 启动桌宠并打印状态

  已存在的 data\balance-log.csv 与 pet-state.json 不会被覆盖。

  用法：
    pwsh -NoProfile -File tools\install.ps1
    pwsh -NoProfile -File tools\install.ps1 -NoRestart          # 只复制文件，不动正在跑的桌宠
    pwsh -NoProfile -File tools\install.ps1 -WithCache          # 同时刷新 Codex 的插件缓存副本
    pwsh -NoProfile -File tools\install.ps1 -CodexHome D:\x\.codex
#>
param(
  [string]$CodexHome,
  [switch]$NoRestart,
  [switch]$WithCache
)

$ErrorActionPreference = 'Stop'

if (-not $CodexHome) {
  if ($env:CODEX_HOME) { $CodexHome = $env:CODEX_HOME } else { $CodexHome = Join-Path $env:USERPROFILE '.codex' }
}
$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)

$repoRoot     = Split-Path $PSScriptRoot -Parent
$petSource    = Join-Path $repoRoot 'pet'
$pluginSource = Join-Path $repoRoot 'plugin\plugins\balance'
$marketplaceSource = Join-Path $repoRoot 'plugin\.agents\plugins\marketplace.json'
foreach ($required in @($petSource, $pluginSource, $marketplaceSource)) {
  if (-not (Test-Path -LiteralPath $required)) { throw ('仓库不完整，缺少：' + $required) }
}

$liveRoot    = Join-Path $CodexHome 'pets\balance-pet'
$marketplaceRoot = Join-Path $CodexHome 'local-marketplaces\balance'
$marketplace = Join-Path $marketplaceRoot 'plugins\balance'
$cacheRoot   = Join-Path $CodexHome 'plugins\cache\local\balance'

Write-Host ('Codex home : ' + $CodexHome)
Write-Host ('桌宠副本   : ' + $liveRoot)
Write-Host ('插件目录   : ' + $marketplace)

function Get-PetProcesses {
  $petName = 'balance' + '-pet.ps1'
  $found = @()
  foreach ($name in @('pwsh.exe', 'powershell.exe')) {
    $found += @(Get-CimInstance Win32_Process -Filter ("Name='" + $name + "'") -ErrorAction SilentlyContinue |
      Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like ('*' + $petName + '*') })
  }
  return $found
}

function New-PetLaunchStartInfo {
  param([string]$CodexDirectory, [string]$PetDirectory, [string]$AccountScript)
  $start = [System.Diagnostics.ProcessStartInfo]::new()
  $start.FileName = Join-Path $env:SystemRoot 'System32\wscript.exe'
  $start.ArgumentList.Add('//nologo')
  $start.ArgumentList.Add((Join-Path $PetDirectory '启动余额桌宠.vbs'))
  $start.WorkingDirectory = $PetDirectory
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  # Pass the selected installation only to this child and its descendants.
  $start.Environment['CODEX_HOME'] = $CodexDirectory
  $start.Environment['BALANCE_ACCOUNT_SCRIPT'] = $AccountScript
  return $start
}

Write-Host '=== 1) 停掉正在运行的桌宠（立绘文件被占用时无法更新）==='
if ($NoRestart) {
  Write-Host '    -NoRestart：跳过'
} else {
  $running = Get-PetProcesses
  Write-Host ('    实例数：' + $running.Count)
  $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  if ($running.Count -gt 0) { Start-Sleep -Seconds 3 }
}

Write-Host '=== 2) 桌宠本体 -> 常驻目录 ==='
New-Item -ItemType Directory -Force -Path (Join-Path $liveRoot 'assets') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $liveRoot 'data') | Out-Null
foreach ($file in @('balance-pet.ps1', 'pet-host.ps1', 'account-client.ps1', 'usage-reader.ps1',
    'task-activity.ps1', 'task-activity-store.mjs', 'window-interaction.ps1', 'sprite-frames.ps1', 'start-pet.ps1', 'winless-launch.ps1',
    'launch_balance_pet.cmd', '启动余额桌宠.cmd', '启动余额桌宠.vbs')) {
  Copy-Item -LiteralPath (Join-Path $petSource $file) -Destination $liveRoot -Force
}
Copy-Item -Path (Join-Path $petSource 'assets\*') -Destination (Join-Path $liveRoot 'assets') -Force
if (-not (Test-Path -LiteralPath (Join-Path $liveRoot 'data\balance-log.csv'))) {
  'timestamp,balance,currency,source,window' | Set-Content -LiteralPath (Join-Path $liveRoot 'data\balance-log.csv') -Encoding utf8
}
Get-ChildItem -LiteralPath $liveRoot -File | Select-Object -ExpandProperty Name

Write-Host '=== 3) 插件 -> 插件市场目录 ==='
New-Item -ItemType Directory -Force -Path $marketplace | Out-Null
$marketplaceMetadata = Join-Path $marketplaceRoot '.agents\plugins'
New-Item -ItemType Directory -Force -Path $marketplaceMetadata | Out-Null
Copy-Item -LiteralPath $marketplaceSource -Destination (Join-Path $marketplaceMetadata 'marketplace.json') -Force
Copy-Item -Path (Join-Path $pluginSource '*') -Destination $marketplace -Recurse -Force
# 桌宠常驻服务的启动链必须跟着插件走（Codex 只会加载插件目录里的东西）
Copy-Item -LiteralPath (Join-Path $petSource 'pet-host.ps1') -Destination $marketplace -Force
Copy-Item -LiteralPath (Join-Path $petSource 'winless-launch.ps1') -Destination $marketplace -Force
New-Item -ItemType Directory -Force -Path (Join-Path $marketplace 'scripts') | Out-Null
Copy-Item -LiteralPath (Join-Path $petSource 'launch_balance_pet.cmd') -Destination (Join-Path $marketplace 'scripts\launch_balance_pet.cmd') -Force

Write-Host '=== 4) 注册 balance_pet MCP 服务 ==='
$mcpPath = Join-Path $marketplace '.mcp.json'
if (Test-Path -LiteralPath $mcpPath) {
  $config = Get-Content -LiteralPath $mcpPath -Raw | ConvertFrom-Json
  if ($config.mcpServers.PSObject.Properties.Name -contains 'balance_pet') {
    Write-Host '    已经注册过了，跳过'
  } else {
    $config.mcpServers | Add-Member -NotePropertyName 'balance_pet' -NotePropertyValue ([pscustomobject]@{
        command             = 'cmd.exe'
        cwd                 = '.'
        args                = @('/d', '/s', '/c', 'call', './scripts/launch_balance_pet.cmd')
        env_vars            = @('PATH', 'PATHEXT', 'SystemRoot', 'ComSpec', 'TEMP', 'TMP', 'USERPROFILE',
          'LOCALAPPDATA', 'APPDATA', 'HOME', 'CODEX_HOME', 'CODEX_MCP_NODE_PATH', 'CODEX_ELECTRON_RESOURCES_PATH')
        startup_timeout_sec = 30
        tool_timeout_sec    = 60
      })
    $json = $config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($mcpPath, $json, [System.Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $mcpPath -Raw | ConvertFrom-Json   # 校验能解析
    Write-Host ('    已注册：' + $mcpPath)
  }
} else {
  Write-Host ('    找不到 .mcp.json：' + $mcpPath)
}

if ($WithCache) {
  Write-Host '=== 5) 刷新 Codex 插件缓存 ==='
  $cacheDir = Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cacheDir) {
    Copy-Item -Path (Join-Path $marketplace '*') -Destination $cacheDir.FullName -Recurse -Force
    Write-Host ('    已更新：' + $cacheDir.FullName)
  } else {
    Write-Host ('    没找到已安装的缓存：先在 Codex 里装一次插件，再用 -WithCache：' + $cacheRoot)
  }
}

Write-Host '=== 6) 启动桌宠 ==='
if ($NoRestart) {
  Write-Host '    -NoRestart：跳过'
} else {
  $launchInfo = New-PetLaunchStartInfo -CodexDirectory $CodexHome -PetDirectory $liveRoot -AccountScript (Join-Path $marketplace 'account.mjs')
  $launcher = [System.Diagnostics.Process]::Start($launchInfo)
  if ($launcher) { $launcher.Dispose() }
  Start-Sleep -Seconds 12
  $statusFile = Join-Path ([System.IO.Path]::GetTempPath()) 'balance-pet-status.json'
  Write-Host ('    桌宠实例数：' + (Get-PetProcesses).Count)
  if (Test-Path -LiteralPath $statusFile) {
    Get-Content -LiteralPath $statusFile
  } else {
    Write-Host '    还没有状态文件，稍等几秒后右键桌宠 -> 立即刷新余额 再看看'
  }
}

Write-Host ''
Write-Host '安装完成。最后一步在 Codex 里启用插件：'
Write-Host ('  插件市场目录：' + (Join-Path $CodexHome 'local-marketplaces\balance'))
Write-Host '  打开 Codex 的插件 / 市场面板，安装 local 市场里的 balance（实时余额）；'
Write-Host '  装好之后对话框里就能问「余额多少」，Codex 启动时也会顺手把桌宠拉起来。'
Write-Host '  想直接看桌宠可以先双击 pet\启动余额桌宠.vbs（隐藏启动）。'
