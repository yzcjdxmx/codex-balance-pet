# Read only rollout metadata and token events. No prompts or tool contents are exposed.

function Initialize-UsageReader {
  $current = Get-Variable -Name Usage -Scope Script -ErrorAction SilentlyContinue
  if (-not $current -or -not ($current.Value -is [System.Collections.IDictionary])) { $script:Usage = @{} }
  $defaults = @{
    File = $null; Offset = [long]0; Carry = ''; Requests = [long]0
    Input = [long]0; Cached = [long]0; Output = [long]0; Reasoning = [long]0; Recent = @()
    LastTotal = $null
    SeenEvents = (New-Object 'System.Collections.Generic.HashSet[string]')
    Utf8Decoder = ([System.Text.Encoding]::UTF8.GetDecoder())
    MetaCache = @{}
  }
  foreach ($name in $defaults.Keys) {
    if (-not $script:Usage.Contains($name)) { $script:Usage[$name] = $defaults[$name] }
  }
}

function Reset-UsageReader {
  param([string]$File)
  $script:Usage.File = $File
  $script:Usage.Offset = [long]0
  $script:Usage.Carry = ''
  $script:Usage.Requests = [long]0
  $script:Usage.Input = [long]0
  $script:Usage.Cached = [long]0
  $script:Usage.Output = [long]0
  $script:Usage.Reasoning = [long]0
  $script:Usage.Recent = @()
  $script:Usage.LastTotal = $null
  $script:Usage.SeenEvents = New-Object 'System.Collections.Generic.HashSet[string]'
  $script:Usage.Utf8Decoder = [System.Text.Encoding]::UTF8.GetDecoder()
}

function Get-RolloutClassification {
  param([System.IO.FileInfo]$File)
  $cached = $script:Usage.MetaCache[$File.FullName]
  if ($cached -and $cached.Created -eq $File.CreationTimeUtc.Ticks -and $File.Length -ge $cached.Length -and
      ($cached.Classification -ne 'unknown' -or $File.Length -eq $cached.Length)) { return $cached.Classification }
  $classification = 'unknown'
  $stream = $null; $reader = $null
  try {
    $stream = [System.IO.File]::Open($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $reader = New-Object System.IO.StreamReader($stream)
    # session_meta is the first record. A bounded header read avoids scanning history.
    $line = $reader.ReadLine()
    if ($line -and $line.Length -le 1048576) {
      $record = $line | ConvertFrom-Json -ErrorAction Stop
      if ($record.type -eq 'session_meta') {
        $payload = $record.payload
        $source = $payload.source
        $isSubagent = $null -ne $payload.parent_thread_id -or
          ($source -isnot [string] -and $source -and $null -ne $source.PSObject.Properties['subagent']) -or
          ($source -is [string] -and $source -eq 'subagent')
        if ($isSubagent) { $classification = 'subagent' } else { $classification = 'primary' }
      }
    }
  } catch { } finally {
    if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
  }
  $script:Usage.MetaCache[$File.FullName] = @{ Classification = $classification; Length = $File.Length; Created = $File.CreationTimeUtc.Ticks }
  return $classification
}

function Get-NewestRolloutFile {
  Initialize-UsageReader
  $fallback = $null
  try {
    $files = @(Get-ChildItem -LiteralPath $script:SessionsDir -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTimeUtc -Descending)
    foreach ($file in $files) {
      $classification = Get-RolloutClassification -File $file
      if ($classification -eq 'primary') { return $file.FullName }
      if ($classification -eq 'unknown' -and -not $fallback) { $fallback = $file.FullName }
    }
  } catch { }
  return $fallback
}

function ConvertTo-UsageNumbers {
  param($Value)
  if (-not $Value) { return $null }
  $result = @{}
  foreach ($pair in @(@('Input', 'input_tokens'), @('Cached', 'cached_input_tokens'), @('Output', 'output_tokens'), @('Reasoning', 'reasoning_output_tokens'))) {
    $number = [long]0
    if ($null -ne $Value.($pair[1])) {
      if (-not [long]::TryParse([string]$Value.($pair[1]), [ref]$number) -or $number -lt 0) { return $null }
    }
    $result[$pair[0]] = $number
  }
  # Cached input is a subset of input; reasoning output is a subset of output.
  $result.Cached = [Math]::Min($result.Cached, $result.Input)
  $result.Reasoning = [Math]::Min($result.Reasoning, $result.Output)
  return $result
}

function Add-UsageDelta {
  param([hashtable]$Delta, $Timestamp)
  if (($Delta.Input + $Delta.Output + $Delta.Cached + $Delta.Reasoning) -le 0) { return }
  foreach ($name in @('Input', 'Cached', 'Output', 'Reasoning')) { $script:Usage[$name] += [long]$Delta[$name] }
  $script:Usage.Requests++
  $at = [datetime]::MinValue
  try {
    # PowerShell 7 may deserialize ISO timestamps into DateTime automatically.
    # Keep the typed value: casting it to string first discards its UTC kind.
    if ($Timestamp -is [DateTimeOffset]) {
      $at = $Timestamp.LocalDateTime
    } elseif ($Timestamp -is [datetime]) {
      if ($Timestamp.Kind -eq [DateTimeKind]::Unspecified) {
        $Timestamp = [datetime]::SpecifyKind($Timestamp, [DateTimeKind]::Utc)
      }
      $at = $Timestamp.ToLocalTime()
    } else {
      $at = [DateTimeOffset]::Parse([string]$Timestamp, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).LocalDateTime
    }
  } catch { }
  if ($at -ne [datetime]::MinValue -and $Delta.Output -gt 0) {
    $script:Usage.Recent += [pscustomobject]@{ t = $at; output = [long]$Delta.Output }
    if ($script:Usage.Recent.Count -gt 500) { $script:Usage.Recent = @($script:Usage.Recent[-500..-1]) }
  }
}

function Get-UsageEventSignature {
  param($Record, [hashtable]$Numbers)
  $payload = $Record.payload
  $id = $payload.request_id
  if (-not $id) { $id = $payload.id }
  if (-not $id) { $id = $Record.id }
  if (-not $id) { $id = [string]$Record.timestamp }
  return ([string]$id + '|' + $Numbers.Input + '|' + $Numbers.Cached + '|' + $Numbers.Output + '|' + $Numbers.Reasoning)
}

function Read-UsageEvent {
  param([string]$Line)
  if ($Line -notlike '*"token_count"*' -and $Line -notlike '*"token_usage_record"*') { return }
  try { $record = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return }
  if ($record.type -ne 'event_msg') { return }
  $payload = $record.payload
  if ($payload.type -eq 'token_count') {
    if (-not $payload.info) { return }
    $total = ConvertTo-UsageNumbers $payload.info.total_token_usage
    if ($total) {
      $delta = @{}
      foreach ($name in @('Input', 'Cached', 'Output', 'Reasoning')) {
        $previous = [long]$script:Usage[$name]
        # Duplicate or stale cumulative snapshots never add their last usage again.
        # Already counted legacy deltas are absorbed by the authoritative total.
        if ($total[$name] -lt $previous) { return }
        $delta[$name] = [long]$total[$name] - $previous
      }
      $script:Usage.LastTotal = $total
      $last = ConvertTo-UsageNumbers $payload.info.last_token_usage
      if ($last) { [void]$script:Usage.SeenEvents.Add((Get-UsageEventSignature -Record $record -Numbers $last)) }
      Add-UsageDelta -Delta $delta -Timestamp $record.timestamp
      return
    }
    $numbers = ConvertTo-UsageNumbers $payload.info.last_token_usage
  } elseif ($payload.type -eq 'token_usage_record') {
    $numbers = ConvertTo-UsageNumbers $payload.usage
  } else { return }
  if (-not $numbers) { return }
  $signature = Get-UsageEventSignature -Record $record -Numbers $numbers
  if (-not $script:Usage.SeenEvents.Add($signature)) { return }
  Add-UsageDelta -Delta $numbers -Timestamp $record.timestamp
}

# Incremental bytes plus a UTF-8 decoder keep a split line or multibyte character
# until its next write. Repeated polling does not recount the already read bytes.
function Update-UsageStats {
  Initialize-UsageReader
  $file = Get-NewestRolloutFile
  if (-not $file) { return }
  if ($script:Usage.File -ne $file) { Reset-UsageReader -File $file }
  $chunk = ''; $stream = $null
  try {
    $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    if ($stream.Length -lt $script:Usage.Offset) { Reset-UsageReader -File $file }
    [void]$stream.Seek($script:Usage.Offset, [System.IO.SeekOrigin]::Begin)
    $count = [int][Math]::Min([long]4194304, $stream.Length - $script:Usage.Offset)
    if ($count -le 0) { return }
    $bytes = New-Object byte[] $count
    $read = $stream.Read($bytes, 0, $count)
    $script:Usage.Offset = $stream.Position
    $chars = New-Object char[] ([System.Text.Encoding]::UTF8.GetMaxCharCount($read))
    $decoded = $script:Usage.Utf8Decoder.GetChars($bytes, 0, $read, $chars, 0, $false)
    $chunk = New-Object string($chars, 0, $decoded)
  } catch { return } finally { if ($stream) { $stream.Dispose() } }
  if (-not $chunk) { return }
  $lines = ($script:Usage.Carry + $chunk) -split "`n"
  $script:Usage.Carry = $lines[-1]
  for ($i = 0; $i -lt $lines.Count - 1; $i++) { Read-UsageEvent -Line $lines[$i].TrimEnd("`r") }
}

Initialize-UsageReader
