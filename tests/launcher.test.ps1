param(
  [string]$TestRoot = (Join-Path ([System.IO.Path]::GetTempPath()) 'codex-balance-pet-launcher-tests')
)

$ErrorActionPreference = 'Stop'
$launcherTestRepo = Split-Path $PSScriptRoot -Parent
$launcherTestRoot = Join-Path ([System.IO.Path]::GetFullPath($TestRoot)) ('中文 launch %TEMP% & $() with spaces-' + [guid]::NewGuid().ToString('N'))
$launcherTestTemp = Join-Path $launcherTestRoot 'isolated temp'
$launcherTestHome = Join-Path $launcherTestRoot '自定义 Codex home'
$launcherTestAccount = Join-Path $launcherTestRoot 'account script & %TEMP%.mjs'
$launcherTestOriginalHome = $env:CODEX_HOME
$launcherTestOriginalAccount = $env:BALANCE_ACCOUNT_SCRIPT
$launcherTestWscript = Join-Path $env:SystemRoot 'System32\wscript.exe'

function Assert-LauncherTest {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Invoke-LauncherTest {
  param([string]$Directory, [string]$OutputPath, [string[]]$Arguments = @(), [switch]$PathRuntime)
  $start = [System.Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $launcherTestWscript
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.WorkingDirectory = $Directory
  $start.ArgumentList.Add('//nologo')
  $start.ArgumentList.Add((Join-Path $Directory '启动余额桌宠.vbs'))
  foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
  $start.Environment['TEMP'] = $launcherTestTemp
  $start.Environment['TMP'] = $launcherTestTemp
  $start.Environment['CODEX_HOME'] = $launcherTestHome
  $start.Environment['BALANCE_ACCOUNT_SCRIPT'] = $launcherTestAccount
  $start.Environment['BALANCE_LAUNCH_TEST_OUTPUT'] = $OutputPath
  if ($PathRuntime) {
    $start.Environment['USERPROFILE'] = Join-Path $launcherTestRoot 'no bundled runtime'
    $start.Environment['ProgramFiles'] = Join-Path $launcherTestRoot 'no installed runtime'
    $start.Environment['ProgramW6432'] = Join-Path $launcherTestRoot 'no installed runtime'
    $start.Environment['PATH'] = $PSHOME + ';' + (Join-Path $env:SystemRoot 'System32')
  }
  $process = [System.Diagnostics.Process]::Start($start)
  try {
    Assert-LauncherTest ($process.WaitForExit(15000)) 'The VBS launcher timed out.'
    Assert-LauncherTest ($process.ExitCode -eq 0) ('The VBS launcher failed with exit code ' + $process.ExitCode + '.')
  } finally {
    if (-not $process.HasExited) { $process.Kill($true) }
    $process.Dispose()
  }
}

New-Item -ItemType Directory -Force -Path $launcherTestRoot, $launcherTestTemp | Out-Null
Copy-Item -LiteralPath (Join-Path $launcherTestRepo 'pet\启动余额桌宠.vbs') -Destination $launcherTestRoot
Copy-Item -LiteralPath (Join-Path $launcherTestRepo 'pet\start-pet.ps1') -Destination $launcherTestRoot
Copy-Item -LiteralPath (Join-Path $launcherTestRepo 'pet\winless-launch.ps1') -Destination $launcherTestRoot
$launcherTestPet = Join-Path $launcherTestRoot "pet ' & %TEMP% `$().ps1"
$launcherTestPetBody = @'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class LaunchProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
$record = [pscustomobject]@{
  pid = $PID
  console = [LaunchProbe]::GetConsoleWindow().ToInt64()
  codex = $env:CODEX_HOME
  account = $env:BALANCE_ACCOUNT_SCRIPT
  script = $PSCommandPath
  workingDirectory = (Get-Location).Path
}
[System.IO.File]::WriteAllText($env:BALANCE_LAUNCH_TEST_OUTPUT, ($record | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
'@
[System.IO.File]::WriteAllText($launcherTestPet, $launcherTestPetBody, [System.Text.UTF8Encoding]::new($false))
$launcherTestOutput = Join-Path $launcherTestRoot 'child.json'
Invoke-LauncherTest -Directory $launcherTestRoot -OutputPath $launcherTestOutput -Arguments @('-PetScript', $launcherTestPet)
$launcherTestDeadline = [DateTime]::UtcNow.AddSeconds(15)
while (-not (Test-Path -LiteralPath $launcherTestOutput) -and [DateTime]::UtcNow -lt $launcherTestDeadline) { Start-Sleep -Milliseconds 100 }
Assert-LauncherTest (Test-Path -LiteralPath $launcherTestOutput) 'The hidden pet fixture did not produce its output.'
$launcherTestRecord = Get-Content -LiteralPath $launcherTestOutput -Raw | ConvertFrom-Json
Assert-LauncherTest ($launcherTestRecord.console -eq 0) 'The pet child allocated a console window.'
Assert-LauncherTest ($launcherTestRecord.codex -ceq $launcherTestHome) 'CODEX_HOME did not reach the actual pet child.'
Assert-LauncherTest ($launcherTestRecord.account -ceq $launcherTestAccount) 'BALANCE_ACCOUNT_SCRIPT did not reach the actual pet child.'
Assert-LauncherTest ($launcherTestRecord.script -ceq $launcherTestPet) 'PetScript lost spaces, Unicode or literal shell characters.'
Assert-LauncherTest ($launcherTestRecord.workingDirectory -ceq $launcherTestRoot) 'The pet child started in the wrong directory.'

# A running PID in the isolated status file must prevent launching another child.
$launcherTestStatus = Join-Path $launcherTestTemp 'balance-pet-status.json'
[System.IO.File]::WriteAllText($launcherTestStatus, ('{"pid":' + $PID + '}'))
$launcherTestDuplicate = Join-Path $launcherTestRoot 'duplicate.json'
Invoke-LauncherTest -Directory $launcherTestRoot -OutputPath $launcherTestDuplicate -Arguments @('-PetScript', $launcherTestPet)
Assert-LauncherTest (-not (Test-Path -LiteralPath $launcherTestDuplicate)) 'The launcher started another child for a running pet.'

# Use a harmless bootstrap stub to verify argv quoting and PATH runtime discovery.
$launcherTestArgumentRoot = Join-Path $launcherTestRoot 'argv fixture'
New-Item -ItemType Directory -Force -Path $launcherTestArgumentRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $launcherTestRepo 'pet\启动余额桌宠.vbs') -Destination $launcherTestArgumentRoot
$launcherTestArgumentBody = @'
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class BootstrapProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window); }'
$console = [BootstrapProbe]::GetConsoleWindow()
[System.IO.File]::WriteAllText(($env:BALANCE_LAUNCH_TEST_OUTPUT + '.window.json'), (([pscustomobject]@{ console = $console.ToInt64(); visible = [BootstrapProbe]::IsWindowVisible($console) }) | ConvertTo-Json -Compress))
[System.IO.File]::WriteAllText($env:BALANCE_LAUNCH_TEST_OUTPUT, (ConvertTo-Json -InputObject @($args) -Compress), [System.Text.UTF8Encoding]::new($false))
'@
[System.IO.File]::WriteAllText((Join-Path $launcherTestArgumentRoot 'start-pet.ps1'), $launcherTestArgumentBody)
$launcherTestArguments = @('space value', '中文参数', 'literal %TEMP%', 'C:\trailing\', '& $(ignored)', '')
$launcherTestArgumentOutput = Join-Path $launcherTestArgumentRoot 'arguments.json'
Invoke-LauncherTest -Directory $launcherTestArgumentRoot -OutputPath $launcherTestArgumentOutput -Arguments $launcherTestArguments -PathRuntime
$launcherTestReceived = @(Get-Content -LiteralPath $launcherTestArgumentOutput -Raw | ConvertFrom-Json)
$launcherTestBootstrapWindow = Get-Content -LiteralPath ($launcherTestArgumentOutput + '.window.json') -Raw | ConvertFrom-Json
Assert-LauncherTest (-not $launcherTestBootstrapWindow.visible) 'The PowerShell bootstrap exposed a console window.'
Assert-LauncherTest ($launcherTestReceived.Count -eq $launcherTestArguments.Count) 'The launcher changed the argument count.'
for ($launcherTestIndex = 0; $launcherTestIndex -lt $launcherTestArguments.Count; $launcherTestIndex++) {
  Assert-LauncherTest ($launcherTestReceived[$launcherTestIndex] -ceq $launcherTestArguments[$launcherTestIndex]) ('Argument ' + $launcherTestIndex + ' was changed by quoting or expansion.')
}

# WScript.Arguments uses WSH quoting, so literal quotes cannot be supplied via
# ProcessStartInfo's CRT quoting. Exercise the VBS-to-PowerShell quote function
# directly with a literal quote (quotes cannot occur in a PetScript file path).
$launcherTestVbsPath = Join-Path $launcherTestArgumentRoot '启动余额桌宠.vbs'
$launcherTestQuoteVbs = [System.IO.File]::ReadAllText($launcherTestVbsPath).Replace('For Each argument In WScript.Arguments', 'For Each argument In Array("say ""hello""", "before\""after", "C:\trailing\")')
[System.IO.File]::WriteAllText($launcherTestVbsPath, $launcherTestQuoteVbs, [System.Text.Encoding]::ASCII)
$launcherTestQuoteOutput = Join-Path $launcherTestArgumentRoot 'quoted-arguments.json'
Invoke-LauncherTest -Directory $launcherTestArgumentRoot -OutputPath $launcherTestQuoteOutput -PathRuntime
$launcherTestQuoted = @(Get-Content -LiteralPath $launcherTestQuoteOutput -Raw | ConvertFrom-Json)
$launcherTestQuoteExpected = @('say "hello"', 'before\"after', 'C:\trailing\')
Assert-LauncherTest ($launcherTestQuoted.Count -eq $launcherTestQuoteExpected.Count) 'The quote fixture changed the argument count.'
for ($launcherTestIndex = 0; $launcherTestIndex -lt $launcherTestQuoteExpected.Count; $launcherTestIndex++) {
  Assert-LauncherTest ($launcherTestQuoted[$launcherTestIndex] -ceq $launcherTestQuoteExpected[$launcherTestIndex]) ('VBS quoting changed argument ' + $launcherTestIndex + '.')
}
Assert-LauncherTest ($env:CODEX_HOME -ceq $launcherTestOriginalHome) 'The launcher test changed the caller CODEX_HOME.'
Assert-LauncherTest ($env:BALANCE_ACCOUNT_SCRIPT -ceq $launcherTestOriginalAccount) 'The launcher test changed the caller BALANCE_ACCOUNT_SCRIPT.'

Write-Host 'PASS: VBS hides the bootstrap and launches an actual console-free child, preserves custom environment and Unicode/metacharacter paths, quotes argv correctly, finds PATH PowerShell, and respects an existing instance.'
