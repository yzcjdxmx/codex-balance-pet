param([string]$TestRoot = (Join-Path ([IO.Path]::GetTempPath()) 'pet-usage-refresh-tests'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\pet\usage-reader.ps1')
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\pet\balance-pet.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Pet script has syntax errors' }
foreach ($name in @('Format-Count', 'Update-StatsText', 'Update-FastUsageStats')) {
  $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}.GetNewClosure(), $true)
  . ([scriptblock]::Create($definition.Extent.Text))
}
$script:Discoveries = 0; $script:CostReads = 0; $script:Redraws = 0; $script:StatusWrites = 0
$script:OriginalDiscovery = ${function:Get-NewestRolloutFile}
function Get-NewestRolloutFile { $script:Discoveries++; & $script:OriginalDiscovery }
function Get-HourlyCost { $script:CostReads++; return 1.5 }
function Sync-Frame { $script:Redraws++ }
function Write-PetStatus { $script:StatusWrites++ }
function Assert-Refresh($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Usage-Line([long]$Output) {
  return ((@{type='event_msg'; timestamp=[DateTimeOffset]::UtcNow.ToString('o'); payload=@{
    type='token_count'; info=@{total_token_usage=@{input_tokens=1000;cached_input_tokens=500;output_tokens=$Output;reasoning_output_tokens=0}}
  }} | ConvertTo-Json -Depth 8 -Compress) + "`n")
}
$fixture = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$first = Join-Path $fixture 'rollout-first.jsonl'
$second = Join-Path $fixture 'rollout-second.jsonl'
try {
  $script:Usage = @{}; $script:SessionsDir = $fixture
  [IO.File]::WriteAllText($first, "{`"type`":`"session_meta`",`"payload`":{`"id`":`"first`",`"source`":`"vscode`"}}`n")
  Update-UsageStats
  $script:State = @{ShowStats=$true;StatsText='';AccountKind='balance';AccountSource='fixture';Currency='CNY';LastError=$null}
  Update-StatsText
  Assert-Refresh ($script:Discoveries -eq 1 -and $script:CostReads -eq 1) 'Initial slow refresh did not discover/calculate once'

  [IO.File]::AppendAllText($first, (Usage-Line 600))
  Update-FastUsageStats
  Assert-Refresh ($script:State.StatsText -match '20 tok/s') 'Fast refresh missed newly appended output'
  Assert-Refresh ($script:Discoveries -eq 1 -and $script:CostReads -eq 1) 'Fast refresh scanned directories or reread cost CSV'
  Assert-Refresh ($script:Redraws -eq 0 -and $script:StatusWrites -eq 1) 'Fast path should reuse the animation timer for rendering'
  $offset = $script:Usage.Offset
  Update-FastUsageStats
  Assert-Refresh ($script:Usage.Offset -eq $offset -and $script:Usage.Output -eq 600) 'Idle fast poll reread or recounted bytes'
  Assert-Refresh ($script:Redraws -eq 0 -and $script:StatusWrites -eq 1) 'Unchanged text caused redundant work'
  $script:Usage.Recent[0].t = (Get-Date).AddSeconds(-45)
  Update-FastUsageStats
  Assert-Refresh ($script:State.StatsText -match '0 tok/s' -and $script:Usage.Recent.Count -eq 0) 'Fast display did not expire old output without a new log write'

  $script:State.ShowStats = $false
  [IO.File]::AppendAllText($first, (Usage-Line 900))
  Update-FastUsageStats
  Assert-Refresh ($script:Usage.Offset -eq $offset) 'Hidden usage line still performed fast reads'
  $script:State.ShowStats = $true
  Update-FastUsageStats
  Assert-Refresh ($script:Usage.Output -eq 900) 'Showing usage did not consume pending output'
  $script:State.AccountSource = 'other-account'
  Update-FastUsageStats
  Assert-Refresh ($script:State.StatsText -notmatch '¥') 'Fast refresh reused another account cost'
  Assert-Refresh ($script:CostReads -eq 1) 'Account invalidation did an expensive fast-path cost read'

  [IO.File]::WriteAllText($second, "{`"type`":`"session_meta`",`"payload`":{`"id`":`"second`",`"source`":`"vscode`"}}`n" + (Usage-Line 300))
  [IO.File]::SetLastWriteTimeUtc($second, [datetime]::UtcNow.AddSeconds(1))
  Update-FastUsageStats
  Assert-Refresh ($script:Usage.File -eq $first -and $script:Discoveries -eq 1) 'Fast poll performed a new session discovery'
  Update-UsageStats
  Assert-Refresh ($script:Usage.File -eq $second -and $script:Usage.Output -eq 300) 'Slow discovery did not pick up a new session'

  # A history backlog is owned by the slow path, not reread every second.
  Reset-UsageReader -File $second
  $script:Usage.Offset = 1
  Update-FastUsageStats
  Assert-Refresh ($script:Usage.Offset -eq 1) 'Fast poll replayed initial history'

  [IO.File]::WriteAllText($second, "{`"type`":`"session_meta`",`"payload`":{`"id`":`"second`",`"source`":`"vscode`"}}`n")
  Reset-UsageReader -File $second
  Update-UsageStats
  $startOffset = $script:Usage.Offset
  [IO.File]::AppendAllText($second, ('x' * 300000) + "`n" + (Usage-Line 600))
  Update-FastUsageStats
  Assert-Refresh (($script:Usage.Offset - $startOffset) -eq 262144 -and -not $script:Usage.CaughtUp) 'Fast read exceeded its bounded budget'
  $boundedOffset = $script:Usage.Offset
  Update-FastUsageStats
  Assert-Refresh ($script:Usage.Offset -eq $boundedOffset) 'Fast polling accelerated a large backlog'
  Update-UsageStats
  Assert-Refresh ($script:Usage.CaughtUp -and $script:Usage.Output -eq 600) 'Slow path did not complete a bounded fast read'
  'PASS: fast incremental updates, no directory/cost scan, no idle redraw, hidden pause, account-safe cost cache and slow discovery/history ownership.'
} finally {
  foreach ($file in @($first, $second)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file } }
  Remove-Item -LiteralPath $fixture
}
