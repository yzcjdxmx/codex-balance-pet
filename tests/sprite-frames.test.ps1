param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
. (Join-Path $ProjectRoot 'pet\sprite-frames.ps1')

function Assert-Sprite($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

# Load the actual selection functions without running the desktop pet or account query.
$petSource = Join-Path $ProjectRoot 'pet\balance-pet.ps1'
$parseTokens = $null; $parseErrors = $null
$petAst = [Management.Automation.Language.Parser]::ParseFile($petSource, [ref]$parseTokens, [ref]$parseErrors)
Assert-Sprite ($parseErrors.Count -eq 0) 'The desktop pet has syntax errors.'
foreach ($name in @('Import-Bitmap', 'Set-Look')) {
  $definition = $petAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
  Assert-Sprite ($null -ne $definition) ('Missing function: ' + $name)
  . ([scriptblock]::Create($definition.Extent.Text))
}
if (-not ('PetArt' -as [type])) {
  $artMatch = [regex]::Match([IO.File]::ReadAllText($petSource), '(?s)\$artCode = @''\r?\n(.*?)\r?\n''@')
  Assert-Sprite $artMatch.Success 'Missing artwork bounds helper.'
  Add-Type -TypeDefinition $artMatch.Groups[1].Value -ReferencedAssemblies @(
    [Drawing.Bitmap].Assembly.Location, [Drawing.Rectangle].Assembly.Location)
}

$assetDirectory = Join-Path $ProjectRoot 'pet\assets'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('pet-sprite-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$fixtureFiles = @()
$script:Sprites = @{}
try {
  foreach ($file in @('pet-base.png', 'pet-normal.png', 'pet-blink.png', 'pet-look-03.png')) {
    $destination = Join-Path $fixture $file
    Copy-Item -LiteralPath (Join-Path $assetDirectory $file) -Destination $destination
    $fixtureFiles += $destination
  }
  $script:LookFiles = @(Get-PetLookFiles -AssetDirectory $fixture)
  Assert-Sprite ($script:LookFiles.Count -eq 2) 'Animation frames became selectable appearances.'
  Assert-Sprite (Set-Look -File $script:LookFiles[0]) 'Default appearance did not load.'
  Assert-Sprite ($script:Sprites.ContainsKey('normal') -and $script:Sprites.ContainsKey('blink')) 'Default eye frames are missing.'
  $normal = $script:Sprites['normal']; $blink = $script:Sprites['blink']
  Assert-Sprite ($normal.Width -eq 320 -and $normal.Height -eq 400 -and $blink.Size -eq $normal.Size) 'Eye frames have incompatible dimensions.'
  Assert-Sprite ($normal.GetPixel(0, 0).A -eq 0 -and $blink.GetPixel(0, 0).A -eq 0) 'Eye frames lost their transparent background.'
  $normalBounds = [PetArt]::AlphaBounds($normal, 8); $blinkBounds = [PetArt]::AlphaBounds($blink, 8)
  for ($i = 0; $i -lt 4; $i++) {
    Assert-Sprite ([Math]::Abs($normalBounds[$i] - $blinkBounds[$i]) -le 3) 'Eye frames move or resize the character silhouette.'
  }
  $eyesChanged = $false
  foreach ($x in @(103, 111, 119, 177, 186, 193)) {
    foreach ($y in @(171, 178, 185)) {
      if ($normal.GetPixel($x, $y).ToArgb() -ne $blink.GetPixel($x, $y).ToArgb()) { $eyesChanged = $true }
    }
  }
  Assert-Sprite $eyesChanged 'The eye frames are identical.'

  Assert-Sprite (Set-Look -File $script:LookFiles[1]) 'Alternate appearance did not load.'
  Assert-Sprite (-not $script:Sprites.ContainsKey('normal') -and -not $script:Sprites.ContainsKey('blink')) 'Default frames leaked into another appearance.'
  foreach ($expression in @('normal', 'blink')) {
    $destination = Join-Path $fixture ('pet-look-03-' + $expression + '.png')
    Copy-Item -LiteralPath (Join-Path $fixture ('pet-' + $expression + '.png')) -Destination $destination
    $fixtureFiles += $destination
  }
  $script:LookFiles = @(Get-PetLookFiles -AssetDirectory $fixture)
  Assert-Sprite ($script:LookFiles.Count -eq 2) 'Per-appearance frames became menu appearances.'
  Assert-Sprite (Set-Look -File $script:LookFiles[1]) 'Per-appearance frames did not reload.'
  Assert-Sprite ($script:Sprites.ContainsKey('normal') -and $script:Sprites.ContainsKey('blink')) 'Per-appearance frames were ignored.'
  Assert-Sprite (Set-Look -File $script:LookFiles[0]) 'Returning to the default appearance failed.'
  'PASS: real transparent eye frames, silhouette alignment, appearance-specific loading and no animation frames in the look menu.'
} finally {
  foreach ($sprite in $script:Sprites.Values) { $sprite.Dispose() }
  foreach ($file in $fixtureFiles) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file } }
  Remove-Item -LiteralPath $fixture
}
