# Locate appearance-specific frames without mixing animation frames into the look menu.
function Get-PetLookFiles {
  param([Parameter(Mandatory = $true)][string]$AssetDirectory)
  $basePath = Join-Path $AssetDirectory 'pet-base.png'
  if (Test-Path -LiteralPath $basePath) { (Resolve-Path -LiteralPath $basePath).Path }
  Get-ChildItem -LiteralPath $AssetDirectory -Filter 'pet-look-*.png' -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -notmatch '-(?:normal|blink)$' } |
    Sort-Object Name | ForEach-Object { $_.FullName }
}

function Get-PetLookFramePaths {
  param([Parameter(Mandatory = $true)][string]$LookPath)
  $directory = Split-Path $LookPath -Parent
  $prefix = [IO.Path]::GetFileNameWithoutExtension($LookPath)
  if ($prefix -eq 'pet-base') { $prefix = 'pet' }
  $frames = @{}
  foreach ($expression in @('normal', 'blink')) {
    $framePath = Join-Path $directory ($prefix + '-' + $expression + '.png')
    if (Test-Path -LiteralPath $framePath) { $frames[$expression] = $framePath }
  }
  return $frames
}
