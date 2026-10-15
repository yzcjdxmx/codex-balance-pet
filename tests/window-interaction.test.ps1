param(
  [string]$TestRoot = (Join-Path ([System.IO.Path]::GetTempPath()) 'codex-balance-pet-window-tests')
)

$ErrorActionPreference = 'Stop'
$interactionTestRepo = Split-Path $PSScriptRoot -Parent
. (Join-Path $interactionTestRepo 'pet\window-interaction.ps1')

function Assert-InteractionTest {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

# Import only the two state functions. Do not execute the pet, account discovery,
# session monitoring, timers, status-file writes or account requests.
$interactionTestTokens = $null
$interactionTestErrors = $null
$interactionTestAst = [System.Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $interactionTestRepo 'pet\balance-pet.ps1'),
  [ref]$interactionTestTokens, [ref]$interactionTestErrors)
Assert-InteractionTest ($interactionTestErrors.Count -eq 0) 'The pet script has a syntax error.'
foreach ($interactionTestFunctionName in 'Get-SavedState', 'Save-PetPosition') {
  $interactionTestFunction = $interactionTestAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq $interactionTestFunctionName
  }, $true)
  Assert-InteractionTest ($null -ne $interactionTestFunction) "Missing state function: $interactionTestFunctionName"
  . ([scriptblock]::Create($interactionTestFunction.Extent.Text))
}

$interactionTestDirectory = Join-Path ([System.IO.Path]::GetFullPath($TestRoot)) ([guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($interactionTestDirectory)
$script:StateFile = Join-Path $interactionTestDirectory 'pet-state.json'
[System.IO.File]::WriteAllText($script:StateFile, '{"x":17,"y":23,"look":"fixture","stats":false}')
$legacyState = Get-SavedState
Assert-InteractionTest ($legacyState.NoActivate -eq $true) 'Legacy state should default to no activation.'
Assert-InteractionTest ($legacyState.X -eq 17 -and $legacyState.Y -eq 23 -and -not $legacyState.Stats) 'Legacy state fields changed.'
[System.IO.File]::WriteAllText($script:StateFile, '{"x":17,"y":23,"noActivate":"false"}')
Assert-InteractionTest ((Get-SavedState).NoActivate -eq $true) 'Malformed activation preference should use the safe default.'
$script:BaseX = 37
$script:BaseY = 41
$script:LookFiles = @('fixture')
$script:LookIndex = 0
$script:State = @{ ShowStats = $true; NoActivate = $false }
Save-PetPosition
$disabledState = Get-SavedState
Assert-InteractionTest (-not $disabledState.NoActivate) 'A disabled preference did not survive saving.'
Assert-InteractionTest ($disabledState.X -eq 37 -and $disabledState.Y -eq 41 -and $disabledState.Look -ceq 'fixture' -and $disabledState.Stats) 'Saving the preference changed position, look or stats.'
$script:State.NoActivate = $true
Save-PetPosition
Assert-InteractionTest ((Get-SavedState).NoActivate) 'An enabled preference did not survive saving.'

$interactionTestNativeCode = @'
using System;
using System.Runtime.InteropServices;
public static class PetWindowTestNative {
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern IntPtr GetFocus();
    [DllImport("user32.dll")] public static extern IntPtr GetActiveWindow();
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hwnd, int index, int style);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
'@
Add-Type -TypeDefinition $interactionTestNativeCode -Language CSharp

# A textbox represents the user's current editor. The only displayed windows are
# these short-lived fixtures. All native messages target fixture handles directly;
# the test neither moves the real cursor nor sends input to another application.
$interactionTestEditor = [System.Windows.Forms.Form]::new()
$interactionTestPet = [BalancePetForm]::new()
$interactionTestMenu = [System.Windows.Forms.ContextMenuStrip]::new()
$interactionTestTextBox = [System.Windows.Forms.TextBox]::new()
$interactionTestEditor.Controls.Add($interactionTestTextBox)
$interactionTestEditor.StartPosition = 'Manual'
$interactionTestEditor.Location = [System.Drawing.Point]::new(40, 40)
$interactionTestEditor.Size = [System.Drawing.Size]::new(260, 120)
$interactionTestEditor.ShowInTaskbar = $false
$interactionTestPet.FormBorderStyle = 'None'
$interactionTestPet.StartPosition = 'Manual'
$interactionTestPet.Location = [System.Drawing.Point]::new(340, 40)
$interactionTestPet.Size = [System.Drawing.Size]::new(100, 100)
$interactionTestPet.ShowInTaskbar = $false
$interactionTestPet.TopMost = $true
$interactionTestMenuItem = $interactionTestMenu.Items.Add('Fixture setting')
$interactionTestMenuItem.CheckOnClick = $true
$interactionTestMenuItem.Checked = $true
$script:InteractionTestMouseDown = 0
$script:InteractionTestMouseUp = 0
$script:InteractionTestMenuClicks = 0
$interactionTestMenuItem.Add_Click({ $script:InteractionTestMenuClicks++ })
$interactionTestPet.Add_MouseDown({
  param($sender, $event)
  if ($event.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $script:InteractionTestMouseDown++
    $sender.Capture = $true
  }
})
$interactionTestPet.Add_MouseUp({
  param($sender, $event)
  if ($event.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $script:InteractionTestMouseUp++
    $sender.Capture = $false
  }
})
Connect-PetContextMenu -Form $interactionTestPet -Menu $interactionTestMenu

try {
  $interactionTestEditor.Show()
  $interactionTestEditor.Activate()
  [void]$interactionTestTextBox.Focus()
  [System.Windows.Forms.Application]::DoEvents()
  $interactionTestFocus = [PetWindowTestNative]::GetFocus()
  $interactionTestActive = [PetWindowTestNative]::GetActiveWindow()
  Assert-InteractionTest ($interactionTestFocus -eq $interactionTestTextBox.Handle) 'Fixture textbox did not receive focus.'
  $interactionTestPet.Show()
  [System.Windows.Forms.Application]::DoEvents()
  Assert-InteractionTest ([PetWindowTestNative]::GetFocus() -eq $interactionTestFocus) 'Showing the pet stole textbox focus.'
  Assert-InteractionTest ([PetWindowTestNative]::GetActiveWindow() -eq $interactionTestActive) 'Showing the pet activated its window.'
  $interactionTestHandle = $interactionTestPet.Handle
  $interactionTestStyle = [PetWindowTestNative]::GetWindowLong($interactionTestHandle, -20)
  Assert-InteractionTest (($interactionTestStyle -band 0x08000000) -ne 0) 'The native no-activation style was not set.'
  Assert-InteractionTest (($interactionTestStyle -band 0x00000008) -ne 0) 'The native topmost style was not set.'
  $interactionTestPet.TopMost = $false
  Assert-InteractionTest (([PetWindowTestNative]::GetWindowLong($interactionTestHandle, -20) -band 0x00000008) -eq 0) 'Disabling topmost did not update its native style.'
  $interactionTestPet.TopMost = $true
  Assert-InteractionTest (([PetWindowTestNative]::GetWindowLong($interactionTestHandle, -20) -band 0x00000008) -ne 0) 'Re-enabling topmost did not restore its native style.'
  Assert-InteractionTest ([PetWindowTestNative]::GetFocus() -eq $interactionTestFocus) 'Changing topmost stole textbox focus.'
  $interactionTestMouseActivation = [PetWindowTestNative]::SendMessage($interactionTestHandle, 0x21, $interactionTestEditor.Handle, [IntPtr]0x02010001)
  Assert-InteractionTest ($interactionTestMouseActivation.ToInt32() -eq 3) 'Mouse activation should return MA_NOACTIVATE without eating input.'
  [void][PetWindowTestNative]::SendMessage($interactionTestHandle, 0x201, [IntPtr]1, [IntPtr]0x000A000A)
  Assert-InteractionTest ($interactionTestPet.Capture -and $script:InteractionTestMouseDown -eq 1) 'Left mouse down or drag capture was lost.'
  [void][PetWindowTestNative]::SetWindowPos($interactionTestHandle, [IntPtr]::Zero, 350, 50, 0, 0, 0x15)
  [void][PetWindowTestNative]::SendMessage($interactionTestHandle, 0x202, [IntPtr]::Zero, [IntPtr]0x000A000A)
  Assert-InteractionTest (-not $interactionTestPet.Capture -and $script:InteractionTestMouseUp -eq 1) 'Left mouse up or drag release was lost.'
  Assert-InteractionTest ([PetWindowTestNative]::GetFocus() -eq $interactionTestFocus) 'Clicking or moving the pet stole textbox focus.'

  # Exercise the production right-click binding and a real WinForms menu item.
  [void][PetWindowTestNative]::SendMessage($interactionTestHandle, 0x204, [IntPtr]2, [IntPtr]0x000A000A)
  [void][PetWindowTestNative]::SendMessage($interactionTestHandle, 0x205, [IntPtr]::Zero, [IntPtr]0x000A000A)
  [System.Windows.Forms.Application]::DoEvents()
  Assert-InteractionTest ($interactionTestMenu.Visible) 'Right click did not open the menu.'
  Assert-InteractionTest ($null -eq $interactionTestMenu.SourceControl) 'The menu is attached to a source control that may activate the pet.'
  Assert-InteractionTest ([PetWindowTestNative]::GetActiveWindow() -eq $interactionTestActive) 'Opening the menu activated the pet.'
  Assert-InteractionTest ([PetWindowTestNative]::GetFocus() -eq $interactionTestFocus) 'Opening the menu stole textbox focus.'
  $interactionTestItemPoint = [System.Drawing.Point]::new($interactionTestMenuItem.Bounds.X + 8, $interactionTestMenuItem.Bounds.Y + 8)
  $interactionTestItemPosition = [IntPtr](($interactionTestItemPoint.Y -shl 16) -bor $interactionTestItemPoint.X)
  [void][PetWindowTestNative]::SendMessage($interactionTestMenu.Handle, 0x201, [IntPtr]1, $interactionTestItemPosition)
  [void][PetWindowTestNative]::SendMessage($interactionTestMenu.Handle, 0x202, [IntPtr]::Zero, $interactionTestItemPosition)
  [System.Windows.Forms.Application]::DoEvents()
  Assert-InteractionTest ($script:InteractionTestMenuClicks -eq 1 -and -not $interactionTestMenuItem.Checked) 'The menu item did not execute or toggle.'
  Assert-InteractionTest (-not $interactionTestMenu.Visible) 'The menu did not close after selection.'
  Assert-InteractionTest ([PetWindowTestNative]::GetFocus() -eq $interactionTestFocus) 'Selecting a menu item stole textbox focus.'

  # Toggling must preserve the handle and unrelated transparency/tool styles.
  [void][PetWindowTestNative]::SetWindowLong($interactionTestHandle, -20, ($interactionTestStyle -bor 0x00080080))
  $interactionTestPet.NoActivate = $false
  Assert-InteractionTest ($interactionTestPet.Handle -eq $interactionTestHandle) 'Toggling recreated the window handle.'
  $interactionTestEnabledStyle = [PetWindowTestNative]::GetWindowLong($interactionTestHandle, -20)
  Assert-InteractionTest (($interactionTestEnabledStyle -band 0x08000000) -eq 0) 'Disabling the setting left the native no-activation style enabled.'
  Assert-InteractionTest (($interactionTestEnabledStyle -band 0x00080080) -eq 0x00080080) 'Disabling the setting discarded layered or tool-window styles.'
  $interactionTestMouseActivation = [PetWindowTestNative]::SendMessage($interactionTestHandle, 0x21, $interactionTestEditor.Handle, [IntPtr]0x02010001)
  Assert-InteractionTest ($interactionTestMouseActivation.ToInt32() -eq 1) 'Disabling the setting did not restore normal mouse activation.'
  $interactionTestPet.Activate()
  [System.Windows.Forms.Application]::DoEvents()
  Assert-InteractionTest ([PetWindowTestNative]::GetActiveWindow() -eq $interactionTestHandle) 'The pet could not activate after disabling the setting.'
  $interactionTestPet.NoActivate = $true
  Assert-InteractionTest ($interactionTestPet.Handle -eq $interactionTestHandle) 'Re-enabling the setting recreated the handle.'
  $interactionTestRestoredStyle = [PetWindowTestNative]::GetWindowLong($interactionTestHandle, -20)
  Assert-InteractionTest (($interactionTestRestoredStyle -band 0x08080080) -eq 0x08080080) 'Re-enabling the setting lost the no-activation, layered or tool-window style.'
} finally {
  $interactionTestMenu.Dispose()
  $interactionTestPet.Dispose()
  $interactionTestEditor.Dispose()
}

Write-Host 'PASS: legacy state and saved focus preference; actual WinForms startup, clicks, drag capture, right-click menu selection, preserved native styles and restored activation.'
