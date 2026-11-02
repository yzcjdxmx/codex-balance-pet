$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\pet\reset-notice.ps1')
function Check($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Query($Count, $Ids, $Source='quota/fixture#account-a') {
  @{kind='quota';source_id=$Source;data=@{rateLimitResetCredits=@{availableCount=$Count;credits=@($Ids | ForEach-Object { @{id=$_} })}}}
}
$state = @{ ResetNotices=@(); ResetNoticeText=''; AccountSource='quota/fixture#account-a' }
$first = Query 2 @('id-1','id-2')
Update-PetResetNotice $state $first
Check ($state.ResetNoticeText -match '2 次') 'Available resets were not announced'
$state.ResetNotices = @((ConvertFrom-Json ($state.ResetNotices | ConvertTo-Json -Depth 6 -AsArray)))
Update-PetResetNotice $state @{kind='quota';source_id=$state.AccountSource}
Check ([bool]$state.ResetNoticeText) 'Unavailable response cleared persisted pending notice'
Confirm-PetResetNotice $state
Update-PetResetNotice $state $first
Check (-not $state.ResetNoticeText) 'Acknowledged grants were announced again'
Update-PetResetNotice $state (Query 1 @('id-2'))
Check (-not $state.ResetNoticeText) 'A decreased count caused a new notice'
Update-PetResetNotice $state (Query 2 @('id-2','id-3'))
Check ([bool]$state.ResetNoticeText) 'A new grant did not announce itself'
Update-PetResetNotice $state (Query 0 @())
Check ([bool]$state.ResetNoticeText) 'Pending notice disappeared without acknowledgment'
Update-PetResetNotice $state (Query 0 @() 'quota/fixture#account-b')
Check (-not $state.ResetNoticeText) 'Notice leaked to another account'
Update-PetResetNotice $state @{kind='balance';source_id=$state.AccountSource}
Check (-not $state.ResetNoticeText) 'API balance displayed an official reset notice'
$state = @{ResetNotices=@();ResetNoticeText='';AccountSource='quota/fixture#account-a'}
Update-PetResetNotice $state (Query 2 @())
Confirm-PetResetNotice $state
Update-PetResetNotice $state $first
Check (-not $state.ResetNoticeText) 'Count-only response was announced again after details arrived'
Update-PetResetNotice $state (Query 2 @('id-2','id-3'))
Check ([bool]$state.ResetNoticeText) 'New grant after count-only acknowledgment was missed'
'PASS: persistence, acknowledge-only dismissal, new grants, consumed grants, missing fields, account isolation and count-only compatibility.'

# Invoke the production mouse handlers on an isolated, undisplayed form.
. (Join-Path $PSScriptRoot '..\pet\window-interaction.ps1')
$tokens=$null; $errors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\pet\balance-pet.ps1'),[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0) 'Pet script has syntax errors'
$script:Form = [BalancePetForm]::new()
$script:Drag = @{Active=$false;Moved=$false}
$script:NoticeButtonRect = [Drawing.Rectangle]::new(20,20,100,28)
$script:State = $state
$script:Saved = $false
function Save-PetPosition { $script:Saved=$true }
function Sync-Frame { param([switch]$Force) }
function Write-PetStatus {}
function Update-Balance { throw 'Acknowledgment must not query or redeem anything' }
try {
  foreach($name in @('Add_MouseDown','Add_MouseUp')) {
    $binding = $ast.Find({param($node)
      $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
      $node.Expression.Extent.Text -eq '$form' -and $node.Member.Value -eq $name
    }.GetNewClosure(),$true)
    . ([scriptblock]::Create($binding.Extent.Text.Replace('$form.','$script:Form.')))
  }
  $flags = [Reflection.BindingFlags]'Instance,NonPublic'
  $event = [Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left,1,30,30,0)
  [Windows.Forms.Control].GetMethod('OnMouseDown',$flags).Invoke($script:Form,@($event)) | Out-Null
  Check ($script:NoticePress -and -not $script:Drag.Active) 'Button press started a drag'
  [Windows.Forms.Control].GetMethod('OnMouseUp',$flags).Invoke($script:Form,@($event)) | Out-Null
  Check (-not $script:State.ResetNoticeText -and $script:Saved) 'Button did not dismiss and persist acknowledgment'
  'PASS: actual production button handlers acknowledge without dragging, querying or redeeming.'
} finally { $script:Form.Dispose() }
