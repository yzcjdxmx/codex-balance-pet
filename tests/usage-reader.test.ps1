param([string]$ReaderPath = (Join-Path $PSScriptRoot '..\pet\usage-reader.ps1'))
$ErrorActionPreference = 'Stop'
. $ReaderPath

# Import the real formatter without starting the pet or querying an account.
$parseErrors = $null
$petAst = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot '..\pet\balance-pet.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Pet script has syntax errors' }
foreach ($functionName in @('Format-Count', 'Update-StatsText', 'Get-UsageDetail')) {
  $definition = $petAst.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
  }.GetNewClosure(), $true)
  . ([scriptblock]::Create($definition.Extent.Text))
}
function Get-HourlyCost { return $null }

function Read-Fixture([string]$Stamp, [bool]$Legacy) {
  $numbers = @{ input_tokens=1000; cached_input_tokens=500; output_tokens=600; reasoning_output_tokens=100 }
  $payload = if ($Legacy) { @{type='token_usage_record'; usage=$numbers} }
    else { @{type='token_count'; info=@{total_token_usage=$numbers; last_token_usage=$numbers}} }
  $line = @{type='event_msg'; timestamp=$Stamp; payload=$payload} | ConvertTo-Json -Depth 8 -Compress
  Read-UsageEvent -Line $line
}

# PowerShell may deserialize these timestamps to DateTime automatically.
# Explicit offsets, UTC strings and zero offsets must preserve the same instant.
$instant = [DateTimeOffset]::UtcNow.AddSeconds(-5)
$stamps = @($instant.UtcDateTime.ToString('o'),
  $instant.ToOffset([TimeSpan]::FromHours(8)).ToString('o'), $instant.ToString('o'))
foreach ($legacy in @($false, $true)) {
  foreach ($stamp in $stamps) {
    Reset-UsageReader -File 'timestamp-fixture'
    Read-Fixture -Stamp $stamp -Legacy $legacy
    if ($script:Usage.Recent.Count -ne 1) { throw 'Recent output event was lost' }
    $difference = ($script:Usage.Recent[0].t.ToUniversalTime() - $instant.UtcDateTime).TotalMilliseconds
    if ([Math]::Abs($difference) -gt 1) { throw 'JSON timestamp lost its UTC/offset meaning' }
    $script:State = @{}
    Update-StatsText
    if ($script:State.StatsText -notmatch '20 tok/s') { throw '600 recent output tokens must display 20 tok/s over 30 seconds' }
    if ((Get-UsageDetail) -notmatch '近 30 秒输出 20 tok/s') { throw 'Usage detail must use the same 30-second rate' }
    Read-Fixture -Stamp $stamp -Legacy $legacy
    if ($script:Usage.Output -ne 600) { throw 'Repeated events counted output twice' }
  }
}

Reset-UsageReader -File 'expired-timestamp-fixture'
Read-Fixture -Stamp ([DateTimeOffset]::UtcNow.AddSeconds(-45).ToString('o')) -Legacy $false
Update-StatsText
if ($script:State.StatsText -notmatch '0 tok/s') { throw '45-second-old output did not expire from the 30-second window' }
if ((Get-UsageDetail) -notmatch '近 30 秒输出 0 tok/s') { throw 'Usage detail did not expire old output' }
'PASS: UTC/offset timestamps in modern and legacy events, actual nonzero rate display, deduplication and idle expiry.'
