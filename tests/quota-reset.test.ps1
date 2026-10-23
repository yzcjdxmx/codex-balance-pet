$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\pet\account-client.ps1')
function Assert-Reset($Actual, $Expected) {
  if ($Actual -cne $Expected) { throw "Expected [$Expected], received [$Actual]" }
}
$now = [DateTimeOffset]::Parse('2026-10-24T00:00:00+08:00')
$stamp = $now.ToUnixTimeSeconds()
$query = @{kind='quota';provider='fixture';data=@{rateLimitsByLimitId=@{codex=@{
  primary=@{usedPercent=3;windowDurationMins=300;resetsAt=$stamp+17520}
  secondary=@{usedPercent=22;windowDurationMins=10080;resetsAt=$stamp+183840}
}}}}
$display = ConvertTo-AccountDisplay -Query $query
Assert-Reset $display.ResetWindows.Count 2
Assert-Reset (Get-QuotaResetText -Kind quota -Windows $display.ResetWindows -Now $now) '5h 重置还剩 4h 52m'
Assert-Reset (Get-QuotaResetText -Kind quota -Windows @($display.ResetWindows[1]) -Now $now) '周 重置还剩 2d 3h 4m'
Assert-Reset (Get-QuotaResetText -Kind quota -Windows @(@{Label='5h';ResetsAt=$stamp+1}) -Now $now) '5h 重置还剩 1m'
Assert-Reset (Get-QuotaResetText -Kind quota -Windows $display.ResetWindows -Now $now.AddSeconds(17520)) '5h 已到重置时间，等待刷新'
Assert-Reset (Get-QuotaResetText -Kind quota -Windows @() -Now $now) '重置时间暂不可用'
Assert-Reset (Get-QuotaResetText -Kind balance -Windows $display.ResetWindows -Now $now) ''
if ($display.Detail -notmatch '10-24 04:52 重置') { throw 'Exact China-time reset detail was lost' }
$query.data.rateLimitsByLimitId.codex.primary.Remove('resetsAt')
$display = ConvertTo-AccountDisplay -Query $query
Assert-Reset $display.ResetWindows.Count 1
Assert-Reset (Get-QuotaResetText -Kind quota -Windows $display.ResetWindows -Now $now) '周 重置还剩 2d 3h 4m'
Write-Host 'PASS: official window selection, day/hour/minute countdown, deadline pending, absent reset times, API balance exclusion and China-time details.'
