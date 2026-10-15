param(
  [string]$TestRoot = (Join-Path ([System.IO.Path]::GetTempPath()) 'codex-balance-pet-install-tests')
)

$ErrorActionPreference = 'Stop'
$installTestRepo = Split-Path $PSScriptRoot -Parent
$installTestScript = Join-Path $installTestRepo 'tools\install.ps1'
$installTestHome = Join-Path ([System.IO.Path]::GetFullPath($TestRoot)) ('home with spaces-' + [guid]::NewGuid().ToString('N'))
$installTestPet = Join-Path $installTestHome 'pets\balance-pet'
$installTestMarket = Join-Path $installTestHome 'local-marketplaces\balance'
$installTestState = Join-Path $installTestPet 'pet-state.json'
$installTestLog = Join-Path $installTestPet 'data\balance-log.csv'
$installTestStateText = '{"x":17,"y":23,"look":"fixture","stats":true}'
$installTestLogText = "timestamp,balance,currency,source,window`n2026-01-01 00:00:00,12.34,CNY,fixture,fixture`n"
$installTestOriginalHome = $env:CODEX_HOME
$installTestOriginalAccount = $env:BALANCE_ACCOUNT_SCRIPT

function Assert-InstallTest {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

New-Item -ItemType Directory -Force -Path (Split-Path $installTestLog -Parent) | Out-Null
[System.IO.File]::WriteAllText($installTestState, $installTestStateText)
[System.IO.File]::WriteAllText($installTestLog, $installTestLogText)

# -NoRestart skips process discovery, stop and start. Only this fixture is installed.
for ($installTestPass = 1; $installTestPass -le 2; $installTestPass++) {
  . $installTestScript -CodexHome $installTestHome -NoRestart
  Assert-InstallTest ([System.IO.File]::ReadAllText($installTestState) -ceq $installTestStateText) 'Installation overwrote pet-state.json.'
  Assert-InstallTest ([System.IO.File]::ReadAllText($installTestLog) -ceq $installTestLogText) 'Installation overwrote the existing balance log.'
  $installTestManifest = Join-Path $installTestMarket '.agents\plugins\marketplace.json'
  Assert-InstallTest (Test-Path -LiteralPath $installTestManifest) 'Marketplace metadata was not installed.'
  Assert-InstallTest ((Get-FileHash -LiteralPath $installTestManifest).Hash -eq (Get-FileHash -LiteralPath (Join-Path $installTestRepo 'plugin\.agents\plugins\marketplace.json')).Hash) 'Marketplace metadata differs from the source.'
  $installTestMetadata = Get-Content -LiteralPath $installTestManifest -Raw | ConvertFrom-Json
  foreach ($installTestEntry in $installTestMetadata.plugins) {
    Assert-InstallTest (Test-Path -LiteralPath (Join-Path $installTestMarket $installTestEntry.source.path)) 'Installed marketplace points to a missing plugin.'
  }
  $installTestMcp = Get-Content -LiteralPath (Join-Path $installTestMarket 'plugins\balance\.mcp.json') -Raw | ConvertFrom-Json
  Assert-InstallTest ($null -ne $installTestMcp.mcpServers.balance_pet) 'The pet MCP service was not registered.'
  Assert-InstallTest (Test-Path -LiteralPath (Join-Path $installTestPet 'task-activity-store.mjs')) 'Task activity helper was not installed.'
  Assert-InstallTest (Test-Path -LiteralPath (Join-Path $installTestPet 'window-interaction.ps1')) 'Window interaction helper was not installed.'
  Assert-InstallTest (Test-Path -LiteralPath (Join-Path $installTestPet 'sprite-frames.ps1')) 'Sprite frame helper was not installed.'
  Assert-InstallTest (Test-Path -LiteralPath (Join-Path $installTestPet '启动余额桌宠.vbs')) 'The VBS launcher was not installed.'
  Assert-InstallTest (Test-Path -LiteralPath (Join-Path $installTestPet 'assets\pet-blink.png')) 'The closed-eye image was not installed.'
  Assert-InstallTest (Test-Path -LiteralPath (Join-Path $installTestPet 'assets\pet-working-atlas-v1.png')) 'Working animation atlas was not installed.'
}

$installTestAccount = Join-Path $installTestMarket 'plugins\balance\account.mjs'
$installTestStart = New-PetLaunchStartInfo -CodexDirectory $installTestHome -PetDirectory $installTestPet -AccountScript $installTestAccount
Assert-InstallTest ($installTestStart.Environment['CODEX_HOME'] -ceq $installTestHome) 'Child launch did not inherit the chosen Codex home.'
Assert-InstallTest ($installTestStart.Environment['BALANCE_ACCOUNT_SCRIPT'] -ceq $installTestAccount) 'Child launch did not receive the installed account module.'
Assert-InstallTest ($installTestStart.CreateNoWindow -and -not $installTestStart.UseShellExecute) 'Child launch may create a console window.'
Assert-InstallTest ([System.IO.Path]::GetFileName($installTestStart.FileName) -ceq 'wscript.exe') 'Installation still launches through a console application.'
Assert-InstallTest ($installTestStart.ArgumentList[1] -ceq (Join-Path $installTestPet '启动余额桌宠.vbs')) 'Child launch lost the path containing spaces.'

# Execute the same hidden startup configuration against a stub, never the pet.
$installTestLauncherDirectory = Join-Path $installTestHome '启动 fixture with spaces'
New-Item -ItemType Directory -Force -Path $installTestLauncherDirectory | Out-Null
$installTestLauncherFile = Join-Path $installTestLauncherDirectory 'start-pet.ps1'
$installTestLauncherBody = @'
[System.IO.File]::WriteAllText((Join-Path $env:INSTALL_LAUNCH_FIXTURE 'child-environment.json'), (($env:CODEX_HOME, $env:BALANCE_ACCOUNT_SCRIPT) | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
'@
[System.IO.File]::WriteAllText($installTestLauncherFile, $installTestLauncherBody)
Copy-Item -LiteralPath (Join-Path $installTestPet '启动余额桌宠.vbs') -Destination $installTestLauncherDirectory
$installTestChildStart = New-PetLaunchStartInfo -CodexDirectory $installTestHome -PetDirectory $installTestLauncherDirectory -AccountScript $installTestAccount
$installTestChildStart.Environment['INSTALL_LAUNCH_FIXTURE'] = $installTestLauncherDirectory
$installTestChildStart.RedirectStandardOutput = $true
$installTestChildStart.RedirectStandardError = $true
$installTestChild = [System.Diagnostics.Process]::Start($installTestChildStart)
try {
  $installTestChildOutput = $installTestChild.StandardOutput.ReadToEndAsync()
  $installTestChildError = $installTestChild.StandardError.ReadToEndAsync()
  Assert-InstallTest ($installTestChild.WaitForExit(10000)) 'Hidden fixture launch timed out.'
  $null = $installTestChildOutput.GetAwaiter().GetResult()
  $null = $installTestChildError.GetAwaiter().GetResult()
  Assert-InstallTest ($installTestChild.ExitCode -eq 0) 'Hidden fixture launcher failed.'
} finally {
  if (-not $installTestChild.HasExited) { $installTestChild.Kill($true) }
  $installTestChild.Dispose()
}
$installTestChildEnvironment = Get-Content -LiteralPath (Join-Path $installTestLauncherDirectory 'child-environment.json') -Raw | ConvertFrom-Json
Assert-InstallTest ($installTestChildEnvironment.Count -eq 2) 'Fixture exposed unexpected environment values.'
Assert-InstallTest ($installTestChildEnvironment[0] -ceq $installTestHome) 'Chosen Codex home did not reach the actual child.'
Assert-InstallTest ($installTestChildEnvironment[1] -ceq $installTestAccount) 'Account module path did not reach the actual child.'
Assert-InstallTest ($env:CODEX_HOME -ceq $installTestOriginalHome) 'Installation changed the caller CODEX_HOME.'
Assert-InstallTest ($env:BALANCE_ACCOUNT_SCRIPT -ceq $installTestOriginalAccount) 'Installation changed the caller BALANCE_ACCOUNT_SCRIPT.'

Write-Host 'PASS: repeat installation preserves user data, deploys the VBS launcher and interaction/blink assets, and passes the chosen environment through a real hidden fixture launch.'
