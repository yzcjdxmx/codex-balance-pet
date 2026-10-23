# Shared with the headless check and background GUI query. Credentials remain in Node.
function Get-AccountClientConfig {
  param([string]$AccountScript)
  if (-not (Test-Path -LiteralPath $AccountScript)) { throw '找不到账户查询模块' }
  $candidates = @()
  if ($env:CODEX_MCP_NODE_PATH) { $candidates += $env:CODEX_MCP_NODE_PATH }
  if ($env:USERPROFILE) {
    $candidates += (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe')
  }
  $candidates += (Get-Command node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      return @{ Node = $candidate; AccountScript = $AccountScript }
    }
  }
  throw '找不到账户查询所需的 Node 运行时'
}

function Invoke-AccountClient {
  param([hashtable]$Config, [switch]$SourceOnly)
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Config.Node
  $startInfo.ArgumentList.Add($Config.AccountScript)
  $startInfo.ArgumentList.Add($(if ($SourceOnly) { '--source-json' } else { '--json' }))
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $started = $false
  try {
    if (-not $process.Start()) { throw '账户查询进程未能启动' }
    $started = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(17000)) {
      try { $process.Kill($true) } catch { }
      throw '账户查询超时，请检查服务商连接'
    }
    $output = $stdoutTask.GetAwaiter().GetResult().Trim()
    # Never expose stderr: third-party errors may contain credentials or identity.
    $null = $stderrTask.GetAwaiter().GetResult()
    try { $result = $output | ConvertFrom-Json -ErrorAction Stop }
    catch { throw '账户查询模块未返回有效结果' }
    if (-not $result) { throw '账户查询模块返回空结果' }
    if ($process.ExitCode -ne 0 -and -not $result.error) { throw '账户查询失败' }
    return $result
  } finally {
    if ($started -and -not $process.HasExited) { try { $process.Kill($true) } catch { } }
    $process.Dispose()
  }
}

function Get-QuotaWindowLabel {
  param([int]$Minutes)
  if ($Minutes -eq 10080) { return '周' }
  if ($Minutes -ge 60 -and $Minutes % 60 -eq 0) { return (($Minutes / 60).ToString() + 'h') }
  if ($Minutes -gt 0) { return ($Minutes.ToString() + 'm') }
  return '额度'
}

function Get-QuotaResetText {
  param([string]$Kind, [array]$Windows, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
  if ($Kind -ne 'quota') { return '' }
  $next = $Windows | Where-Object { $null -ne $_.ResetsAt } | Sort-Object ResetsAt | Select-Object -First 1
  if (-not $next) { return '重置时间暂不可用' }
  $seconds = [long]$next.ResetsAt - $Now.ToUnixTimeSeconds()
  if ($seconds -le 0) { return ($next.Label + ' 已到重置时间，等待刷新') }
  $minutes = [long][Math]::Ceiling($seconds / 60.0)
  $days = [long][Math]::Floor($minutes / 1440.0)
  $hours = [long][Math]::Floor(($minutes % 1440) / 60.0)
  $parts = @()
  if ($days -gt 0) { $parts += ($days.ToString() + 'd') }
  if ($hours -gt 0 -or $days -gt 0) { $parts += ($hours.ToString() + 'h') }
  $parts += (($minutes % 60).ToString() + 'm')
  return ($next.Label + ' 重置还剩 ' + ($parts -join ' '))
}

function ConvertTo-AccountDisplay {
  param($Query, $Alert)
  if ($Query.error) { throw [string]$Query.error }
  if ($Query.kind -eq 'quota') {
    $data = $Query.data
    $limits = $null
    if ($data.rateLimitsByLimitId) {
      # Use the Codex bucket, not an unrelated model-specific bucket.
      $limits = $data.rateLimitsByLimitId.codex
    }
    if (-not $limits) { $limits = $data.rateLimits }
    if (-not $limits) { throw '账户未返回可用额度' }
    $parts = @()
    $resetWindows = @()
    $details = @('ChatGPT ' + [string]$limits.planType)
    $low = $false
    foreach ($window in @($limits.primary, $limits.secondary)) {
      if ($null -eq $window -or $null -eq $window.usedPercent) { continue }
      $remaining = [Math]::Max(0, [Math]::Min(100, 100 - [double]$window.usedPercent))
      $label = Get-QuotaWindowLabel -Minutes ([int]$window.windowDurationMins)
      $parts += ($label + ' ' + ('{0:0.#}%' -f $remaining))
      if ($remaining -le 0) { $low = $true }
      $reset = '重置时间未知'
      if ($null -ne $window.resetsAt) {
        $resetWindows += [pscustomobject]@{ Label = $label; ResetsAt = [long]$window.resetsAt }
        $chinaZone = [TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')
        $resetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$window.resetsAt)
        $reset = [TimeZoneInfo]::ConvertTime($resetAt, $chinaZone).ToString('MM-dd HH:mm') + ' 重置'
      }
      $details += ($label + ' 剩余 ' + ('{0:0.#}%' -f $remaining) + '，' + $reset)
    }
    if ($parts.Count -eq 0) { throw '账户额度暂不可用' }
    return @{
      Text = '额度 ' + ($parts -join '｜'); Low = $low; Kind = 'quota'
      Value = $null; Currency = $null; Provider = $Query.provider
      Source = $Query.source_id; Model = $Query.model; QueriedAt = $Query.queried_at
      Detail = ($details -join '；')
      ResetWindows = $resetWindows
    }
  }
  if ($Query.kind -ne 'balance') { throw '当前服务商没有可查询的余额接口' }
  $data = $Query.data
  $infos = @($data.balance_infos)
  $primary = $infos | Where-Object { $_.currency -eq 'CNY' } | Select-Object -First 1
  if (-not $primary) { $primary = $infos | Where-Object { $_.currency -eq 'USD' } | Select-Object -First 1 }
  if (-not $primary) { $primary = $infos | Where-Object { $_.currency -and $null -ne $_.total_balance } | Select-Object -First 1 }
  if (-not $primary -or $null -eq $primary.total_balance) { throw '接口未返回余额明细' }
  $value = 0.0
  if (-not [double]::TryParse([string]$primary.total_balance, [Globalization.NumberStyles]::Float,
    [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { throw '接口返回的余额无效' }
  $symbol = switch ($primary.currency) { 'CNY' { '¥' } 'USD' { '$' } default { [string]$primary.currency + ' ' } }
  $low = ($data.is_available -eq $false)
  if ($Alert -and $Alert.Currency -eq $primary.currency) { $low = $low -or ($value -lt $Alert.Threshold) }
  return @{
    Text = $symbol + [string]$primary.total_balance; Low = $low; Kind = 'balance'
    Value = $value; Currency = $primary.currency; Provider = $Query.provider
    Source = $Query.source_id; Model = $Query.model; QueriedAt = $Query.queried_at
    Detail = ([string]$Query.provider + ' 余额 ' + $symbol + [string]$primary.total_balance)
    ResetWindows = @()
  }
}
