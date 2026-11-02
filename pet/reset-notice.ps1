# Only observes earned reset opportunities. Acknowledgment never redeems a reset.
function Update-PetResetNotice {
  param([hashtable]$State, $Query)
  $State.ResetNoticeText = ''
  if ($Query.kind -ne 'quota') { return }
  $record = $State.ResetNotices | Where-Object { $_.Source -eq $Query.source_id } | Select-Object -First 1
  $credits = $Query.data.rateLimitResetCredits
  if (-not $record -and $null -ne $credits -and $credits.availableCount -gt 0) {
    $record = [pscustomobject]@{Source=$Query.source_id; Acknowledged=@(); Pending=@(); Count=0}
    $State.ResetNotices = @($State.ResetNotices) + @($record)
  }
  if (-not $record) { return }
  if ($null -ne $credits) {
    $record.Count = [int]$credits.availableCount
    $keys = @($credits.credits | Where-Object { $_.id } | ForEach-Object { [string]$_.id })
    # The service may provide only a count or cap the detail rows.
    if ($record.Count -gt $keys.Count) { $keys += ('count:' + $record.Count) }
    if ($record.Count -gt 0 -and $record.Count -eq @($credits.credits).Count -and ('count:' + $record.Count) -in $record.Acknowledged) {
      $record.Acknowledged = @(@($record.Acknowledged | Where-Object { $_ -notlike 'count:*' }) + $keys | Select-Object -Unique)
    }
    if ($record.Count -gt 0) {
      $record.Pending = @(@($record.Pending) + @($keys | Where-Object { $_ -notin $record.Acknowledged }) | Select-Object -Unique)
    }
  }
  if (@($record.Pending).Count -gt 0) {
    $State.ResetNoticeText = if ($record.Count -gt 0) { 'Codex 有 ' + $record.Count + ' 次全额度重置机会' } else { '曾检测到全额度重置机会，当前已无可用次数' }
  }
}

function Confirm-PetResetNotice {
  param([hashtable]$State)
  $record = $State.ResetNotices | Where-Object { $_.Source -eq $State.AccountSource } | Select-Object -First 1
  if ($record) {
    $record.Acknowledged = @(@($record.Acknowledged) + @($record.Pending) | Select-Object -Unique)
    $record.Pending = @()
  }
  $State.ResetNoticeText = ''
}
