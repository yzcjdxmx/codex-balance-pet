<#
  balance-pet.ps1 — 桌面余额桌宠（逐像素透明的置顶窗口）

  特性：
    · 实时余额显示在脚下的牌子，默认 30 秒刷新一次
    · 按住任意位置拖动，位置会记住（pet-state.json）
    · 点一下：冒一句台词 + 换表情，并立刻刷新余额
    · 余额低于阈值时表情自动变难过；跑任务时写字，闲置时恢复常态
    · 偶尔眨眼；右键有菜单（立即刷新 / 重置位置 / 打个招呼 / 退出）
    · 透明区域不挡鼠标，可以直接点下面的窗口

  用法：
    pwsh -NoProfile -File balance-pet.ps1
    pwsh -NoProfile -File balance-pet.ps1 -RefreshSeconds 60
    pwsh -NoProfile -File balance-pet.ps1 -Preview     # 只渲染合成图到 ./preview 检查外观
    pwsh -NoProfile -File balance-pet.ps1 -Headless    # 只查一次余额

  立绘换法：把 assets/pet-*.png 换成你自己的图即可，尺寸按 320x400 出图最贴合。
#>
param(
  [int]$RefreshSeconds = 30,
  [int]$IdleSleepSeconds = 150,
  [int]$LogIntervalSeconds = 1800,
  [string[]]$CodexProcessNames = @('ChatGPT'),
  [string]$CodexPathFilter = '*OpenAI.Codex*',
  [switch]$DisableWatchdog,
  [switch]$WatchdogProbe,
  [switch]$Preview,
  [switch]$Headless
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 单实例锁：允许多个 Codex 会话同时拉桌宠，但同一时间只会有一个真正跑起来
if (-not ($Preview -or $Headless -or $WatchdogProbe)) {
  $script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\CodexBalancePet')
  if (-not $script:InstanceMutex.WaitOne(0)) {
    Write-Host '桌宠已经在运行了，新实例直接退出'
    exit 0
  }
}

$script:Root       = $PSScriptRoot
$script:AssetDir   = Join-Path $PSScriptRoot 'assets'
$script:StateFile  = Join-Path $PSScriptRoot 'pet-state.json'
$script:DataDir    = Join-Path $PSScriptRoot 'data'
$script:BalanceLogFile = Join-Path $script:DataDir 'balance-log.csv'
$script:SessionsDir = Join-Path $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }) 'sessions'
$script:CanvasW    = 340
$script:CanvasH    = 562
$script:SpriteW    = 320
$script:SpriteH    = 400
$script:SpriteX    = 10
$script:SpriteY    = 84
$script:AccountCodexRoot = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$script:AccountScript = $null
foreach ($script:AccountCandidate in @(
    $env:BALANCE_ACCOUNT_SCRIPT,
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'plugin\plugins\balance\account.mjs'),
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'balance-plugin\plugins\balance\account.mjs'),
    (Join-Path $script:AccountCodexRoot 'local-marketplaces\balance\plugins\balance\account.mjs'),
    (Join-Path $script:AccountCodexRoot 'plugins\cache\local\balance\1.0.0\account.mjs'),
    (Join-Path $PSScriptRoot 'account.mjs')
  )) {
  if ($script:AccountCandidate -and (Test-Path -LiteralPath $script:AccountCandidate)) {
    $script:AccountScript = $script:AccountCandidate; break
  }
}
$script:AccountClientScript = Join-Path $PSScriptRoot 'account-client.ps1'
. $script:AccountClientScript

#region 数据层

function Get-CodexHome {
  $candidates = @()
  if ($env:CODEX_HOME) { $candidates += $env:CODEX_HOME }
  $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
  if ($userHome) { $candidates += (Join-Path $userHome '.codex') }
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'config.toml'))) { return $candidate }
  }
  return $null
}

function Get-ProviderConfig {
  return Get-AccountClientConfig -AccountScript $script:AccountScript
}

function Get-LiveBalance {
  param([hashtable]$Config)
  return Invoke-AccountClient -Config $Config
}

function Get-AlertThreshold {
  $codexHome = Get-CodexHome
  if (-not $codexHome) { return $null }
  $file = Join-Path $codexHome 'balance-alert.json'
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try {
    $parsed = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if ($null -eq $parsed.threshold) { return $null }
    return @{
      Threshold = [double]$parsed.threshold
      Currency  = if ($parsed.currency) { $parsed.currency } else { 'CNY' }
    }
  } catch { return $null }
}

function Get-CurrencySymbol {
  param([string]$Currency)
  switch ($Currency) {
    'CNY' { return '¥' }
    'USD' { return '$' }
    default { return "$Currency " }
  }
}

function Test-CodexRunning {
  foreach ($name in $CodexProcessNames) {
    foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
      try {
        $path = $process.Path
        if (-not $path) { return $true }   # 读不到路径就当作在运行，宁可多留不要误关
        if ($CodexPathFilter -and ($path -notlike $CodexPathFilter)) { continue }
        return $true
      } catch {
        return $true
      }
    }
  }
  return $false
}

#endregion

if ($WatchdogProbe) {
  Write-Host ('codex running: ' + (Test-CodexRunning))
  exit 0
}

if ($Headless) {
  $config = Get-ProviderConfig
  Get-LiveBalance -Config $config | ConvertTo-Json -Depth 5
  exit 0
}

#region 分层窗口

Add-Type -AssemblyName System.Drawing

$layerCode = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class PetLayer {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx; public int cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct BLENDFUNCTION {
        public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat;
    }
    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFOHEADER {
        public int biSize; public int biWidth; public int biHeight; public short biPlanes; public short biBitCount;
        public int biCompression; public int biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
        public int biClrUsed; public int biClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFO { public BITMAPINFOHEADER bmiHeader; public uint bmiColors; }

    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFO pbmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("user32.dll", SetLastError = true)] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", SetLastError = true)] static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll", SetLastError = true)] static extern int SetWindowLong(IntPtr hWnd, int index, int value);

    const int GWL_EXSTYLE = -20;
    const int WS_EX_LAYERED = 0x00080000;
    const int WS_EX_TOOLWINDOW = 0x00000080;
    const uint ULW_ALPHA = 0x00000002;
    const uint SWP_NOSIZE = 0x0001;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;

    public static void MakeLayered(IntPtr hwnd) {
        int style = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, style | WS_EX_LAYERED | WS_EX_TOOLWINDOW);
    }

    public static void MoveTo(IntPtr hwnd, int x, int y) {
        SetWindowPos(hwnd, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    public static void Push(IntPtr hwnd, Bitmap bitmap, int x, int y) {
        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memDc = CreateCompatibleDC(screenDc);
        IntPtr hBitmap = IntPtr.Zero;
        try {
            int w = bitmap.Width;
            int h = bitmap.Height;

            BITMAPINFO bmi = new BITMAPINFO();
            bmi.bmiHeader.biSize = Marshal.SizeOf(typeof(BITMAPINFOHEADER));
            bmi.bmiHeader.biWidth = w;
            bmi.bmiHeader.biHeight = -h;
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = 0;

            IntPtr bits;
            hBitmap = CreateDIBSection(memDc, ref bmi, 0, out bits, IntPtr.Zero, 0);
            if (hBitmap == IntPtr.Zero) throw new Exception("CreateDIBSection failed");

            BitmapData data = bitmap.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try {
                int stride = Math.Abs(data.Stride);
                byte[] source = new byte[stride * h];
                Marshal.Copy(data.Scan0, source, 0, source.Length);

                byte[] target = new byte[w * 4 * h];
                for (int row = 0; row < h; row++) {
                    int sourceRow = row * stride;
                    int targetRow = row * w * 4;
                    for (int col = 0; col < w; col++) {
                        int s = sourceRow + col * 4;
                        int d = targetRow + col * 4;
                        byte b = source[s];
                        byte g = source[s + 1];
                        byte r = source[s + 2];
                        byte a = source[s + 3];
                        target[d] = (byte)(b * a / 255);
                        target[d + 1] = (byte)(g * a / 255);
                        target[d + 2] = (byte)(r * a / 255);
                        target[d + 3] = a;
                    }
                }
                Marshal.Copy(target, 0, bits, target.Length);
            } finally {
                bitmap.UnlockBits(data);
            }

            IntPtr previous = SelectObject(memDc, hBitmap);
            POINT destination = new POINT(); destination.X = x; destination.Y = y;
            SIZE size = new SIZE(); size.cx = w; size.cy = h;
            POINT sourcePoint = new POINT(); sourcePoint.X = 0; sourcePoint.Y = 0;
            BLENDFUNCTION blend = new BLENDFUNCTION();
            blend.BlendOp = 0; blend.BlendFlags = 0; blend.SourceConstantAlpha = 255; blend.AlphaFormat = 1;

            bool ok = UpdateLayeredWindow(hwnd, screenDc, ref destination, ref size, memDc, ref sourcePoint, 0, ref blend, (int)ULW_ALPHA);
            SelectObject(memDc, previous);
            if (!ok) throw new Exception("UpdateLayeredWindow failed: " + Marshal.GetLastWin32Error());
        } finally {
            if (hBitmap != IntPtr.Zero) DeleteObject(hBitmap);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }
}
'@

Add-Type -TypeDefinition $layerCode -Language CSharp -ReferencedAssemblies @(
  [System.Drawing.Bitmap].Assembly.Location,
  [System.Drawing.Rectangle].Assembly.Location
)

$artCode = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class PetArt {
    public static int[] AlphaBounds(Bitmap bmp, int threshold) {
        int w = bmp.Width, h = bmp.Height;
        BitmapData data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int stride = Math.Abs(data.Stride);
            byte[] buffer = new byte[stride * h];
            Marshal.Copy(data.Scan0, buffer, 0, buffer.Length);
            int minX = w, minY = h, maxX = -1, maxY = -1;
            for (int y = 0; y < h; y++) {
                int row = y * stride;
                for (int x = 0; x < w; x++) {
                    if (buffer[row + x * 4 + 3] > threshold) {
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                }
            }
            if (maxX < 0) return new int[] { 0, 0, w, h };
            return new int[] { minX, minY, maxX - minX + 1, maxY - minY + 1 };
        } finally {
            bmp.UnlockBits(data);
        }
    }
}
'@

Add-Type -TypeDefinition $artCode -Language CSharp -ReferencedAssemblies @(
  [System.Drawing.Bitmap].Assembly.Location,
  [System.Drawing.Rectangle].Assembly.Location
)

#endregion

#region 素材与配色

. (Join-Path $PSScriptRoot 'sprite-frames.ps1')

function Import-Bitmap {
  # 读进内存副本，避免运行时锁住 assets 里的文件（否则换立绘会被占用挡住）
  param([string]$Path)
  $loaded = [System.Drawing.Bitmap]::FromFile($Path)
  try {
    $copy = New-Object System.Drawing.Bitmap($loaded.Width, $loaded.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($copy)
    $graphics.DrawImageUnscaled($loaded, 0, 0)
    $graphics.Dispose()
    return $copy
  } finally {
    $loaded.Dispose()
  }
}

$script:Sprites = @{}
$script:SubjectBounds = $null
$script:LookFiles = @()
$script:LookIndex = 0
$script:WorkingAtlas = $null
$script:WorkingBounds = @()
$script:WorkingCellW = 0
$script:WorkingCellH = 0

$workingAtlasPath = Join-Path $script:AssetDir 'pet-working-atlas-v1.png'
if (Test-Path -LiteralPath $workingAtlasPath) {
  $script:WorkingAtlas = Import-Bitmap -Path $workingAtlasPath
  $script:WorkingCellW = [int]($script:WorkingAtlas.Width / 2)
  $script:WorkingCellH = [int]($script:WorkingAtlas.Height / 2)
  foreach ($frameIndex in 0..3) {
    $cell = [System.Drawing.Rectangle]::new(($frameIndex % 2) * $script:WorkingCellW,
      [int][Math]::Floor($frameIndex / 2) * $script:WorkingCellH, $script:WorkingCellW, $script:WorkingCellH)
    $cellBitmap = $script:WorkingAtlas.Clone($cell, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try { $script:WorkingBounds += ,([PetArt]::AlphaBounds($cellBitmap, 8)) }
    finally { $cellBitmap.Dispose() }
  }
}

# 可轮换的形象：pet-base.png 打头，其余 pet-look-*.png 按名字排序
$script:LookFiles = @(Get-PetLookFiles -AssetDirectory $script:AssetDir)
if ($script:LookFiles.Count -eq 0) {
  throw "缺少立绘：$script:AssetDir 里既没有 pet-base.png，也没有 pet-look-*.png"
}

# 表情真图：有就换脸，没有就用当前形象 + 程序化特效
foreach ($name in 'happy', 'sad', 'sleepy') {
  $file = Join-Path $script:AssetDir ("pet-$name.png")
  if (Test-Path -LiteralPath $file) { $script:Sprites[$name] = Import-Bitmap -Path $file }
}
$script:SleepyBounds = $null
if ($script:Sprites.ContainsKey('sleepy')) {
  $sleepySprite = $script:Sprites['sleepy']
  $sleepyPixels = [PetArt]::AlphaBounds($sleepySprite, 8)
  $script:SleepyBounds = @(
    ($sleepyPixels[0] * $script:SpriteW / $sleepySprite.Width),
    ($sleepyPixels[1] * $script:SpriteH / $sleepySprite.Height),
    ($sleepyPixels[2] * $script:SpriteW / $sleepySprite.Width),
    ($sleepyPixels[3] * $script:SpriteH / $sleepySprite.Height)
  )
}

function Set-Look {
  param([string]$File)
  if (-not $File) { return $false }
  if (-not (Test-Path -LiteralPath $File)) { return $false }
  $resolved = (Resolve-Path -LiteralPath $File).Path
  $index = [array]::IndexOf($script:LookFiles, $resolved)
  if ($index -lt 0) { return $false }
  foreach ($key in @('base', 'normal', 'blink')) {
    if ($script:Sprites.ContainsKey($key)) {
      $script:Sprites[$key].Dispose()
      $script:Sprites.Remove($key)
    }
  }
  $script:Sprites['base'] = Import-Bitmap -Path $resolved
  $framePaths = Get-PetLookFramePaths -LookPath $resolved
  foreach ($key in $framePaths.Keys) { $script:Sprites[$key] = Import-Bitmap -Path $framePaths[$key] }
  $normalSprite = if ($script:Sprites.ContainsKey('normal')) { $script:Sprites['normal'] } else { $script:Sprites['base'] }
  $script:SubjectBounds = [PetArt]::AlphaBounds($normalSprite, 8)
  $script:LookIndex = $index
  return $true
}

$null = Set-Look -File $script:LookFiles[0]

$script:Color = @{
  Ok      = [System.Drawing.Color]::FromArgb(74, 222, 154)
  Low     = [System.Drawing.Color]::FromArgb(255, 146, 74)
  Error   = [System.Drawing.Color]::FromArgb(255, 104, 104)
  Badge   = [System.Drawing.Color]::FromArgb(196, 22, 26, 40)
  BadgeEd = [System.Drawing.Color]::FromArgb(70, 255, 255, 255)
  Text    = [System.Drawing.Color]::FromArgb(240, 244, 252)
  Bubble  = [System.Drawing.Color]::FromArgb(246, 255, 255, 255)
  BubbleEd = [System.Drawing.Color]::FromArgb(255, 214, 221, 240)
  BubbleTx = [System.Drawing.Color]::FromArgb(255, 30, 36, 60)
}

$script:FontBadge  = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$script:FontBubble = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
$script:FontStats  = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)

#region 用量统计与余额记录

. (Join-Path $PSScriptRoot 'usage-reader.ps1')
. (Join-Path $PSScriptRoot 'task-activity.ps1')
Initialize-TaskActivity -SessionsDirectory $script:SessionsDir -CodexDirectory (Get-CodexHome)

function Format-Count {
  param([double]$Value)
  if ($Value -ge 1000000) { return ('{0:N1}M' -f ($Value / 1000000)) }
  if ($Value -ge 1000) { return ('{0:N0}k' -f ($Value / 1000)) }
  return ('{0:N0}' -f $Value)
}

function Get-HourlyCost {
  # 用余额记录反推最近一段时间的花费速度（元/小时）
  if ($script:State.AccountKind -ne 'balance' -or $script:State.Currency -ne 'CNY' -or $script:State.LastError) { return $null }
  try {
    if (-not (Test-Path -LiteralPath $script:BalanceLogFile)) { return $null }
    $logSource = 'auto|' + $script:State.AccountSource
    $rows = @(Import-Csv -LiteralPath $script:BalanceLogFile | Where-Object {
      $_.currency -eq $script:State.Currency -and $_.source -eq $logSource -and
      $null -ne ($_.balance -as [double])
    })
    if ($rows.Count -lt 2) { return $null }
    $first = $rows[0]
    $last = $rows[-1]
    $minutes = ([datetime]$last.timestamp - [datetime]$first.timestamp).TotalMinutes
    if ($minutes -lt 10) { return $null }
    $spent = [double]$first.balance - [double]$last.balance
    if ($spent -le 0) { return $null }
    return [Math]::Round($spent / $minutes * 60, 1)
  } catch {
    return $null
  }
}

function Update-StatsText {
  param([switch]$ReuseCost)
  $now = Get-Date
  $cut = $now.AddSeconds(-30)
  $recent = @($script:Usage.Recent | Where-Object { $_.t -ge $cut })
  $script:Usage.Recent = $recent
  $rate = 0
  if ($recent.Count -gt 0) {
    $rate = ($recent | Measure-Object -Property output -Sum).Sum / 30.0
  }
  $parts = @()
  if ($script:Usage.Requests -gt 0) {
    $parts += ('用量 ' + (Format-Count ($script:Usage.Input + $script:Usage.Output)))
    if ($script:Usage.Input -gt 0) {
      $parts += ('缓存 ' + ('{0:P0}' -f ($script:Usage.Cached / $script:Usage.Input)))
    }
  }
  $rateText = if ($rate -ge 1000) { Format-Count $rate } else { '{0:0.#}' -f $rate }
  $parts += ($rateText + ' tok/s')
  $costKey = "$($script:State.AccountKind)|$($script:State.AccountSource)|$($script:State.Currency)|$($script:State.LastError)"
  $cost = $null
  if (-not $ReuseCost) {
    $cost = Get-HourlyCost
    $script:State.CachedHourlyCost = $cost
    $script:State.CachedCostKey = $costKey
  } elseif ($script:State.CachedCostKey -eq $costKey) {
    $cost = $script:State.CachedHourlyCost
  }
  if ($cost) { $parts += ('¥' + $cost + '/h') }
  $script:State.StatsText = ($parts -join '｜')
}

function Update-FastUsageStats {
  if (-not $script:State.ShowStats) { return }
  $previousText = $script:State.StatsText
  Update-UsageStats -SelectedFileOnly
  Update-StatsText -ReuseCost
  if ($script:State.StatsText -ne $previousText) {
    # The existing 120 ms animation tick paints the new text; do not draw twice.
    Write-PetStatus
  }
}

function Get-UsageDetail {
  $now = Get-Date
  $cut = $now.AddSeconds(-30)
  $recent = @($script:Usage.Recent | Where-Object { $_.t -ge $cut })
  $rate = 0
  if ($recent.Count -gt 0) { $rate = ($recent | Measure-Object -Property output -Sum).Sum / 30.0 }
  $cacheRatio = 0
  if ($script:Usage.Input -gt 0) { $cacheRatio = $script:Usage.Cached / $script:Usage.Input }
  $lines = @(
    ('本会话 输入 ' + (Format-Count $script:Usage.Input) + '（缓存 ' + ('{0:P0}' -f $cacheRatio) + '）'),
    ('输出 ' + (Format-Count $script:Usage.Output) + '（推理 ' + (Format-Count $script:Usage.Reasoning) + '）'),
    ('缓存命中 ' + (Format-Count $script:Usage.Cached) + ' / 输入 ' + (Format-Count $script:Usage.Input)),
    ($script:Usage.Requests.ToString() + ' 次请求'),
    ('近 30 秒输出 ' + (Format-Count $rate) + ' tok/s')
  )
  $cost = Get-HourlyCost
  if ($cost) { $lines += ('按记录推算 ' + '¥' + $cost + ' / 小时') }
  return ($lines -join '；')
}

function Write-BalanceLog {
  param([switch]$Force)
  if ($script:State.AccountKind -ne 'balance' -or $null -eq $script:State.BalanceValue -or $script:State.LastError -or $script:State.IsRefreshing) { return }
  try {
    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null }
    $now = Get-Date
    if (-not $Force -and (Test-Path -LiteralPath $script:BalanceLogFile)) {
      $last = Get-Content -LiteralPath $script:BalanceLogFile -Tail 1 -ErrorAction SilentlyContinue
      if ($last) {
        $stamp = ($last -split ',')[0]
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($stamp, [ref]$parsed) -and ($now - $parsed).TotalSeconds -lt ($LogIntervalSeconds * 0.9)) { return }
      }
    }
    if (-not (Test-Path -LiteralPath $script:BalanceLogFile)) {
      'timestamp,balance,currency,source,window' | Set-Content -LiteralPath $script:BalanceLogFile -Encoding utf8
    }
    $row = [pscustomobject][ordered]@{
      timestamp = $now.ToString('yyyy-MM-dd HH:mm:ss')
      balance = $script:State.BalanceValue.ToString([Globalization.CultureInfo]::InvariantCulture)
      currency = $script:State.Currency
      source = 'auto|' + $script:State.AccountSource
      window = "$($script:BaseX),$($script:BaseY)"
    }
    $row | Export-Csv -LiteralPath $script:BalanceLogFile -Append -NoTypeInformation -Encoding utf8
  } catch { }
}

#endregion

$script:Lines = @(
  '余额还有 {b} 哦～',
  '人家一直帮你盯着余额呢',
  '点我就能立刻查一次余额',
  '今天的余额也记好啦',
  '主人，要不要喝杯茶？',
  '{b}，还够用一阵子～',
  '记账小能手在此！'
)
$script:LowLines = @(
  '余额只剩 {b} 啦…',
  '该充值了，不然要断粮了…',
  '呜呜，钱包越来越轻了'
)

#endregion

#region 合帧

function New-RoundedPath {
  param([double]$X, [double]$Y, [double]$W, [double]$H, [double]$R)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $R * 2
  $path.AddArc([float]$X, [float]$Y, [float]$d, [float]$d, 180, 90)
  $path.AddArc([float]($X + $W - $d), [float]$Y, [float]$d, [float]$d, 270, 90)
  $path.AddArc([float]($X + $W - $d), [float]($Y + $H - $d), [float]$d, [float]$d, 0, 90)
  $path.AddArc([float]$X, [float]($Y + $H - $d), [float]$d, [float]$d, 90, 90)
  $path.CloseFigure()
  return $path
}

function Draw-Sparkle {
  param($G, [double]$X, [double]$Y, [double]$Size, [System.Drawing.Color]$Color)
  $pen = New-Object System.Drawing.Pen($Color, [float]([Math]::Max(1.5, $Size * 0.14)))
  $pen.StartCap = 'Round'
  $pen.EndCap = 'Round'
  $G.DrawLine($pen, [float]($X - $Size / 2), [float]$Y, [float]($X + $Size / 2), [float]$Y)
  $G.DrawLine($pen, [float]$X, [float]($Y - $Size / 2), [float]$X, [float]($Y + $Size / 2))
  $core = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
  $G.FillEllipse($core, [float]($X - $Size * 0.13), [float]($Y - $Size * 0.13), [float]($Size * 0.26), [float]($Size * 0.26))
  $pen.Dispose()
  $core.Dispose()
}

function Draw-Teardrop {
  param($G, [double]$X, [double]$Y, [double]$Size, [System.Drawing.Color]$Color)
  $brush = New-Object System.Drawing.SolidBrush($Color)
  $G.FillEllipse($brush, [float]($X - $Size / 2), [float]$Y, [float]$Size, [float]($Size * 1.2))
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $points = [System.Drawing.PointF[]]@(
    [System.Drawing.PointF]::new([float]($X - $Size * 0.34), [float]($Y + $Size * 0.3)),
    [System.Drawing.PointF]::new([float]($X + $Size * 0.34), [float]($Y + $Size * 0.3)),
    [System.Drawing.PointF]::new([float]$X, [float]($Y - $Size * 0.5))
  )
  $path.AddPolygon($points)
  $G.FillPath($brush, $path)
  $bright = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 255, 255, 255))
  $G.FillEllipse($bright, [float]($X - $Size * 0.28), [float]($Y + $Size * 0.35), [float]($Size * 0.26), [float]($Size * 0.3))
  $brush.Dispose()
  $bright.Dispose()
  $path.Dispose()
}

function Draw-ExpressionEffect {
  param($G, [string]$Expression, [int]$Bob, [int]$SleepAnimationFrame = 0)

  # 用主体范围来定位特效，换任何立绘都能跟着走
  $x = $script:SubjectBounds[0] + $script:SpriteX
  $y = $script:SubjectBounds[1] + $script:SpriteY + $Bob
  $w = $script:SubjectBounds[2]
  $h = $script:SubjectBounds[3]

  switch ($Expression) {
    'happy' {
      Draw-Sparkle -G $G -X ($x - 4) -Y ($y + $h * 0.08) -Size 20 -Color ([System.Drawing.Color]::FromArgb(255, 255, 214, 92))
      Draw-Sparkle -G $G -X ($x + $w + 4) -Y ($y + $h * 0.16) -Size 15 -Color ([System.Drawing.Color]::FromArgb(255, 255, 200, 120))
      Draw-Sparkle -G $G -X ($x + $w * 0.08) -Y ($y - 4) -Size 12 -Color ([System.Drawing.Color]::FromArgb(255, 255, 226, 150))
      Draw-Sparkle -G $G -X ($x + $w * 0.92) -Y ($y + $h * 0.02) -Size 10 -Color ([System.Drawing.Color]::FromArgb(255, 255, 236, 180))
    }
    'sad' {
      Draw-Teardrop -G $G -X ($x + $w * 0.16) -Y ($y + $h * 0.30) -Size 13 -Color ([System.Drawing.Color]::FromArgb(220, 130, 200, 255))
      Draw-Teardrop -G $G -X ($x + $w * 0.10) -Y ($y + $h * 0.40) -Size 8 -Color ([System.Drawing.Color]::FromArgb(200, 150, 214, 255))
    }
    'sleepy' {
      # Dedicated sleeping art has different transparent margins from the selected look.
      if ($script:SleepyBounds) {
        $x = $script:SleepyBounds[0] + $script:SpriteX
        $y = $script:SleepyBounds[1] + $script:SpriteY + $Bob
        $w = $script:SleepyBounds[2]
      }
      $fontFamily = [System.Drawing.FontFamily]::GenericSansSerif
      $textFormat = [System.Drawing.StringFormat]::GenericTypographic
      try { for ($i = 0; $i -lt 3; $i++) {
        $phase = (($SleepAnimationFrame % 25) / 25.0 + $i / 3.0) % 1.0
        $alpha = [int][Math]::Round(235 * [Math]::Sin([Math]::PI * $phase))
        if ($alpha -le 0) { continue }
        $size = 18 + 12 * $phase
        $zx = [Math]::Min($script:CanvasW - $size - 10, $x + $w * 0.56 + 48 * $phase + 3 * [Math]::Sin($phase * 2 * [Math]::PI))
        $zy = [Math]::Max(8, $y - 22 - 62 * $phase)
        $letter = if ($phase -gt 0.55) { 'Z' } else { 'z' }
        $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $outline = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb($alpha, 35, 53, 92), 2.6)
        $outline.LineJoin = 'Round'
        $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($alpha, 186, 214, 255))
        try {
          $path.AddString($letter, $fontFamily, [int][System.Drawing.FontStyle]::Bold,
            [float]$size, [System.Drawing.PointF]::new([float]$zx, [float]$zy), $textFormat)
          $G.DrawPath($outline, $path)
          $G.FillPath($brush, $path)
        } finally { $path.Dispose(); $outline.Dispose(); $brush.Dispose() }
      } } finally { $fontFamily.Dispose(); $textFormat.Dispose() }
    }
  }
}

function New-PetFrame {
  param(
    [string]$Expression = 'normal',
    [string]$Bubble = '',
    [string]$BalanceText = '—',
    [string]$StatusColor = 'Ok',
    [int]$Bob = 0,
    [int]$AnimationFrame = 0,
    [int]$SleepAnimationFrame = 0
  )

  $bitmap = New-Object System.Drawing.Bitmap($script:CanvasW, $script:CanvasH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bitmap)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.Clear([System.Drawing.Color]::Transparent)

  # 立绘：有对应表情图就用表情图，否则用主立绘 + 情绪特效
  # 缺少当前形象的闭眼帧时保留其常态，不压扁身体或换成其他角色姿势。
  $renderExpression = if ($Expression -eq 'blink' -and -not $script:Sprites.ContainsKey('blink')) { 'normal' } else { $Expression }
  $isWorking = $Expression -eq 'working' -and $null -ne $script:WorkingAtlas
  $dedicated = $isWorking -or $script:Sprites.ContainsKey($renderExpression)
  if ($isWorking) {
    $sprite = $script:WorkingAtlas
  } elseif ($dedicated) {
    $sprite = $script:Sprites[$renderExpression]
  } elseif ($script:Sprites.ContainsKey('base')) {
    $sprite = $script:Sprites['base']
  } else {
    $sprite = $script:Sprites['normal']
  }

  $rotate = 0.0
  $squash = 1.0
  if (-not $dedicated) {
    switch ($Expression) {
      'sad'    { $rotate = -2.0 }
      'happy'  { $squash = 1.02 }
      'sleepy' { $squash = 0.985 }
    }
  }

  $pivotX = $script:SpriteX + $script:SpriteW / 2
  $pivotY = $script:SpriteY + $script:SpriteH + $Bob
  if ($rotate -ne 0 -or $squash -ne 1.0) {
    $g.TranslateTransform([float]$pivotX, [float]$pivotY)
    if ($rotate -ne 0) { $g.RotateTransform([float]$rotate) }
    if ($squash -ne 1.0) { $g.ScaleTransform(1.0, [float]$squash) }
    $g.TranslateTransform([float](-$pivotX), [float](-$pivotY))
  }
  if ($isWorking) {
    $index = $AnimationFrame % 4
    $bounds = $script:WorkingBounds[$index]
    $maxWidth = ($script:WorkingBounds | ForEach-Object { $_[2] } | Measure-Object -Maximum).Maximum
    $scale = $script:SpriteW / [double]$maxWidth
    # Anchor the desk to one baseline; transparent atlas margins must not cause jitter.
    $dest = [System.Drawing.RectangleF]::new(
      [float]($script:CanvasW / 2 - ($bounds[0] + $bounds[2] / 2) * $scale),
      [float]($script:SpriteY + $script:SpriteH + $Bob - ($bounds[1] + $bounds[3]) * $scale),
      [float]($script:WorkingCellW * $scale), [float]($script:WorkingCellH * $scale))
    $src = [System.Drawing.RectangleF]::new(
      [float](($index % 2) * $script:WorkingCellW),
      [float]([int][Math]::Floor($index / 2) * $script:WorkingCellH),
      [float]$script:WorkingCellW, [float]$script:WorkingCellH)
    $g.DrawImage($sprite, $dest, $src, [System.Drawing.GraphicsUnit]::Pixel)
  } else {
    $g.DrawImage($sprite, $script:SpriteX, ($script:SpriteY + $Bob), $script:SpriteW, $script:SpriteH)
  }
  $g.ResetTransform()

  if (-not $dedicated -or $Expression -eq 'sleepy') {
    Draw-ExpressionEffect -G $g -Expression $Expression -Bob $Bob -SleepAnimationFrame $SleepAnimationFrame
  }

  # 台词气泡
  if ($Bubble) {
    $natural = $g.MeasureString($Bubble, $script:FontBubble)
    $bubbleW = [Math]::Min($script:CanvasW - 24, [Math]::Max(140, $natural.Width + 30))
    $textWidth = $bubbleW - 26
    $size = $g.MeasureString($Bubble, $script:FontBubble, [int]$textWidth)
    $bubbleH = $size.Height + 22
    $bubbleX = [Math]::Round(($script:CanvasW - $bubbleW) / 2)
    $bubbleY = [Math]::Max(6, 158 - $bubbleH)

    $tail = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tailCenter = $bubbleX + $bubbleW / 2
    $tailPoints = [System.Drawing.PointF[]]@(
      [System.Drawing.PointF]::new([float]($tailCenter - 14), [float]($bubbleY + $bubbleH - 1)),
      [System.Drawing.PointF]::new([float]($tailCenter + 14), [float]($bubbleY + $bubbleH - 1)),
      [System.Drawing.PointF]::new([float]($tailCenter + 3), [float]($bubbleY + $bubbleH + 13))
    )
    $tail.AddPolygon($tailPoints)

    $bubbleBrush = New-Object System.Drawing.SolidBrush($script:Color.Bubble)
    $bubblePen = New-Object System.Drawing.Pen($script:Color.BubbleEd, 2)
    $body = New-RoundedPath -X $bubbleX -Y $bubbleY -W $bubbleW -H $bubbleH -R 14
    $g.FillPath($bubbleBrush, $body)
    $g.DrawPath($bubblePen, $body)
    $g.FillPath($bubbleBrush, $tail)
    $g.DrawLine($bubblePen, [float]($tailCenter - 13), [float]($bubbleY + $bubbleH - 1), [float]($tailCenter + 13), [float]($bubbleY + $bubbleH - 1))

    $textRect = New-Object System.Drawing.RectangleF([float]($bubbleX + 13), [float]($bubbleY + 11), [float]$textWidth, [float]($bubbleH - 20))
    $textBrush = New-Object System.Drawing.SolidBrush($script:Color.BubbleTx)
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = 'Center'
    $g.DrawString($Bubble, $script:FontBubble, $textBrush, $textRect, $format)

    $format.Dispose(); $textBrush.Dispose(); $bubbleBrush.Dispose(); $bubblePen.Dispose(); $body.Dispose(); $tail.Dispose()
  }

  # 脚下余额牌
  $badgeFormat = [System.Drawing.StringFormat]::GenericTypographic.Clone()
  $badgeFormat.FormatFlags = $badgeFormat.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoWrap
  $badgeFormat.LineAlignment = 'Center'
  $badgeFont = $script:FontBadge
  $ownsBadgeFont = $false
  $badgeTextMaxW = $script:CanvasW - 50
  $badgeSize = $g.MeasureString($BalanceText, $badgeFont, 10000, $badgeFormat)
  # Fit the one-line quota label horizontally; vertical layout uses actual font metrics.
  for ($fontPixels = 19; $badgeSize.Width -gt $badgeTextMaxW -and $fontPixels -ge 14; $fontPixels--) {
    if ($ownsBadgeFont) { $badgeFont.Dispose() }
    $badgeFont = New-Object System.Drawing.Font('Microsoft YaHei UI', $fontPixels, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $ownsBadgeFont = $true
    $badgeSize = $g.MeasureString($BalanceText, $badgeFont, 10000, $badgeFormat)
  }
  $showStats = [bool]($script:State.ShowStats -and $script:State.StatsText)
  $badgeW = $badgeSize.Width + 44
  $statsFormat = [System.Drawing.StringFormat]::GenericTypographic.Clone()
  $statsFormat.FormatFlags = $statsFormat.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoWrap
  $statsFormat.Alignment = 'Center'
  $statsFormat.LineAlignment = 'Center'
  if ($showStats) {
    $statsSize = $g.MeasureString($script:State.StatsText, $script:FontStats, 10000, $statsFormat)
    $badgeW = [Math]::Max($badgeW, $statsSize.Width + 28)
  }
  $badgeW = [Math]::Round([Math]::Min($badgeW, $script:CanvasW - 10))
  $badgeLineH = [Math]::Ceiling($badgeFont.GetHeight($g)) + 6
  $statsLineH = [Math]::Ceiling($script:FontStats.GetHeight($g)) + 4
  $badgeH = $badgeLineH + 12
  if ($showStats) { $badgeH += $statsLineH + 2 }
  $badgeX = [Math]::Round(($script:CanvasW - $badgeW) / 2)
  $badgeY = [Math]::Min(498, $script:CanvasH - $badgeH - 6)

  $badgePath = New-RoundedPath -X $badgeX -Y $badgeY -W $badgeW -H $badgeH -R 17
  $badgeBrush = New-Object System.Drawing.SolidBrush($script:Color.Badge)
  $badgePen = New-Object System.Drawing.Pen($script:Color.BadgeEd, 1.6)
  $g.FillPath($badgeBrush, $badgePath)
  $g.DrawPath($badgePen, $badgePath)

  $dotBrush = New-Object System.Drawing.SolidBrush($script:Color[$StatusColor])
  $dotTop = [Math]::Round(6 + ($badgeLineH - 9) / 2)
  $g.FillEllipse($dotBrush, [float]($badgeX + 14), [float]($badgeY + $dotTop), 9, 9)

  $badgeTextBrush = New-Object System.Drawing.SolidBrush($script:Color.Text)
  $badgeTextRect = New-Object System.Drawing.RectangleF(
    [float][Math]::Round($badgeX + 30), [float][Math]::Round($badgeY + 6), [float][Math]::Round($badgeW - 40), [float]$badgeLineH)
  $g.DrawString($BalanceText, $badgeFont, $badgeTextBrush, $badgeTextRect, $badgeFormat)

  if ($showStats) {
    $statsBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(242, 226, 233, 250))
    $statsRect = New-Object System.Drawing.RectangleF(
      [float][Math]::Round($badgeX + 6), [float][Math]::Round($badgeY + 6 + $badgeLineH + 2), [float][Math]::Round($badgeW - 12), [float]$statsLineH)
    $g.DrawString($script:State.StatsText, $script:FontStats, $statsBrush, $statsRect, $statsFormat)
    $statsBrush.Dispose()
  }

  $dotBrush.Dispose(); $badgeBrush.Dispose(); $badgePen.Dispose(); $badgePath.Dispose()
  $badgeTextBrush.Dispose()
  $badgeFormat.Dispose(); $statsFormat.Dispose()
  if ($ownsBadgeFont) { $badgeFont.Dispose() }
  $g.Dispose()
  return $bitmap
}

#endregion

if ($Preview) {
  $previewDir = Join-Path $script:Root 'preview'
  if (-not (Test-Path $previewDir)) { New-Item -ItemType Directory -Force -Path $previewDir | Out-Null }
  $shots = @(
    @{ Name = 'idle';    Args = @{ Expression = 'normal'; BalanceText = '¥8.47'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'blink';   Args = @{ Expression = 'blink'; BalanceText = '¥8.47'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'talking'; Args = @{ Expression = 'happy'; Bubble = '余额还有 ¥8.47 哦～'; BalanceText = '¥8.47'; StatusColor = 'Ok'; Bob = -3 } },
    @{ Name = 'low';     Args = @{ Expression = 'sad'; Bubble = '余额只剩 ¥4.20 啦…'; BalanceText = '¥4.20'; StatusColor = 'Low'; Bob = 0 } },
    @{ Name = 'sleepy';  Args = @{ Expression = 'sleepy'; BalanceText = '¥8.47'; StatusColor = 'Ok'; Bob = 2 } },
    @{ Name = 'sleepy-8'; Args = @{ Expression = 'sleepy'; SleepAnimationFrame = 8; BalanceText = '¥8.47'; StatusColor = 'Ok'; Bob = 2 } },
    @{ Name = 'sleepy-16'; Args = @{ Expression = 'sleepy'; SleepAnimationFrame = 16; BalanceText = '¥8.47'; StatusColor = 'Ok'; Bob = 2 } },
    @{ Name = 'error';   Args = @{ Expression = 'sad'; Bubble = '查询失败：网络不可用'; BalanceText = '查询失败'; StatusColor = 'Error'; Bob = 0 } },
    @{ Name = 'stats';   Args = @{ Expression = 'normal'; BalanceText = '¥5.61'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'quota';   Args = @{ Expression = 'normal'; BalanceText = '额度 5h 83%｜周 97%'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'quota-single'; Args = @{ Expression = 'normal'; BalanceText = '额度 5h 100%｜周 100%'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'quota-detail'; Args = @{ Expression = 'normal'; Bubble = 'ChatGPT Plus；5h 剩余 83%，10-14 20:48 重置；周 剩余 97%，10-21 15:48 重置'; BalanceText = '额度 5h 83%｜周 97%'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'query-1'; Args = @{ Expression = 'normal'; Bubble = '查询中.'; BalanceText = '额度 5h 83%｜周 97%'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'query-2'; Args = @{ Expression = 'normal'; Bubble = '查询中..'; BalanceText = '额度 5h 83%｜周 97%'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'query-3'; Args = @{ Expression = 'normal'; Bubble = '查询中...'; BalanceText = '额度 5h 83%｜周 97%'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'working-0'; Args = @{ Expression = 'working'; AnimationFrame = 0; BalanceText = '额度 5h 83%｜周 97%'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'working-1'; Args = @{ Expression = 'working'; AnimationFrame = 1; BalanceText = '额度 5h 83%｜周 97%'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'working-2'; Args = @{ Expression = 'working'; AnimationFrame = 2; BalanceText = '额度 5h 83%｜周 97%'; StatusColor = 'Ok'; Bob = 0 } },
    @{ Name = 'working-3'; Args = @{ Expression = 'working'; AnimationFrame = 3; BalanceText = '额度 5h 83%｜周 97%'; StatusColor = 'Ok'; Bob = 0 } }
  )
  $script:State = @{ ShowStats = $false; StatsText = '' }
  foreach ($shot in $shots) {
    $script:State.ShowStats = ($shot.Name -in @('stats', 'quota', 'quota-detail', 'query-1', 'query-2', 'query-3', 'working-0', 'working-1', 'working-2', 'working-3'))
    $script:State.StatsText = if ($shot.Name -eq 'stats') { '用量 58.8M｜缓存 99%｜12.3k tok/s｜¥1.5/h' } elseif ($script:State.ShowStats) { '用量 80k｜缓存 66%｜1.2k tok/s' } else { '' }
    $splat = $shot.Args
    $frame = New-PetFrame @splat
    $target = Join-Path $previewDir ($shot.Name + '.png')
    $frame.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
    $frame.Dispose()
    Write-Host "preview $target"
  }
  exit 0
}

#region 运行时状态

$script:State = @{
  Expression      = 'normal'
  ExpressionUntil = [datetime]::MinValue
  Bubble          = ''
  BubbleUntil     = [datetime]::MinValue
  BlinkUntil      = [datetime]::MinValue
  NextBlinkAt     = (Get-Date).AddSeconds(4)
  LastInteraction = Get-Date
  BalanceText     = '—'
  StatusColor     = 'Ok'
  LowBalance      = $false
  LastError       = $null
  AccountKind     = ''
  AccountSource   = ''
  Provider        = ''
  Model           = ''
  Currency        = $null
  BalanceValue    = $null
  AccountDetail   = ''
  QueriedAt       = $null
  HasAccountSnapshot = $false
  IsRefreshing    = $false
  QueryStartedAt  = [datetime]::MinValue
  TaskBusy        = $false
  ActiveTasks     = 0
  TaskPhase       = 'unverified'
  WorkStartedAt   = [datetime]::UtcNow
  Bob             = 0
  BobPhase        = 0.0
  StatsText       = ''
  ShowStats       = $true
  NoActivate      = $true
  LastSignature   = ''
  Frame           = $null
}

$script:BaseX = 0
$script:BaseY = 0
$script:Bob = 0
$script:WatchdogMisses = 0
$script:AccountWorker = $null
$script:AccountTask = $null

function Get-BalanceDisplay {
  $alert = Get-AlertThreshold
  $config = Get-ProviderConfig
  $data = Get-LiveBalance -Config $config
  return ConvertTo-AccountDisplay -Query $data -Alert $alert
}

function Get-StatusText {
  $script:State.BalanceText
}

function Get-RenderedBubble {
  param([datetime]$Now = [datetime]::UtcNow)
  if ($script:State.IsRefreshing) {
    $elapsed = [Math]::Max(0, ($Now - $script:State.QueryStartedAt).TotalMilliseconds)
    $dots = 1 + ([int][Math]::Floor($elapsed / 400) % 3)
    return ('查询中' + ('.' * $dots))
  }
  return $script:State.Bubble
}

function Get-RenderedExpression {
  if ($script:State.TaskBusy -and $script:WorkingAtlas) { return 'working' }
  return $script:State.Expression
}

function Get-WorkingFrame {
  if (-not $script:State.TaskBusy) { return 0 }
  $elapsed = [Math]::Max(0, ([datetime]::UtcNow - $script:State.WorkStartedAt).TotalMilliseconds)
  return ([int][Math]::Floor($elapsed / 160) % 4)
}

function Get-SleepAnimationFrame {
  param([datetime]$Now = [datetime]::UtcNow)
  if ((Get-RenderedExpression) -ne 'sleepy') { return 0 }
  # 25 frames at 120 ms: a gentle three-second loop, independent of token speed.
  return [int]([Math]::Floor($Now.TimeOfDay.TotalMilliseconds / 120) % 25)
}

function Update-PetTaskActivity {
  $result = Update-TaskActivity
  $wasBusy = [bool]$script:State.TaskBusy
  $script:State.TaskBusy = [bool]$result.IsBusy
  $script:State.ActiveTasks = [int]$result.ActiveCount
  $script:State.TaskPhase = $result.Phase
  if ($script:State.TaskBusy -and -not $wasBusy) { $script:State.WorkStartedAt = [datetime]::UtcNow }
  if ($wasBusy -and -not $script:State.TaskBusy) {
    $script:State.Expression = if ($script:State.LowBalance) { 'sad' } else { 'normal' }
    $script:State.LastInteraction = Get-Date
  }
}

function Write-PetStatus {
  try {
    $file = Join-Path ([System.IO.Path]::GetTempPath()) 'balance-pet-status.json'
    $payload = [ordered]@{
      updated_at  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      pid         = $PID
      visible     = $script:Form.Visible
      handle      = [int64]0
      location    = "$($script:Form.Location.X),$($script:Form.Location.Y)"
      expression  = Get-RenderedExpression
      look        = if ($script:LookFiles.Count -gt 0) { [System.IO.Path]::GetFileNameWithoutExtension($script:LookFiles[$script:LookIndex]) } else { $null }
      lookCount   = $script:LookFiles.Count
      balance     = $script:State.BalanceText
      low         = $script:State.LowBalance
      bubble      = Get-RenderedBubble
      last_error  = $script:State.LastError
      account_kind = $script:State.AccountKind
      account_source = $script:State.AccountSource
      provider    = $script:State.Provider
      model       = $script:State.Model
      account_detail = $script:State.AccountDetail
      queried_at  = $script:State.QueriedAt
      refreshing  = [bool]$script:State.IsRefreshing
      show_stats  = [bool]$script:State.ShowStats
      no_activate = [bool]$script:State.NoActivate
      stats_text  = $script:State.StatsText
      token_requests = $script:Usage.Requests
      token_output = $script:Usage.Output
      task_busy   = [bool]$script:State.TaskBusy
      active_tasks = $script:State.ActiveTasks
      task_phase  = $script:State.TaskPhase
      animation_frame = Get-WorkingFrame
      sleep_animation_frame = Get-SleepAnimationFrame
    }
    try { $payload.handle = $script:Form.Handle.ToInt64() } catch { }
    ($payload | ConvertTo-Json -Compress) | Set-Content -LiteralPath $file -Encoding utf8
  } catch { }
}

function Sync-Frame {
  param([switch]$Force)
  $bubble = Get-RenderedBubble
  $expression = Get-RenderedExpression
  $animationFrame = Get-WorkingFrame
  $sleepAnimationFrame = Get-SleepAnimationFrame
  $signature = "$expression|$animationFrame|$sleepAnimationFrame|$bubble|$($script:State.BalanceText)|$($script:State.StatusColor)|$($script:State.StatsText)|$($script:State.ShowStats)"
  if (-not $Force -and $signature -eq $script:State.LastSignature) { return }
  $script:State.LastSignature = $signature

  $frame = New-PetFrame -Expression $expression -Bubble $bubble `
    -BalanceText $script:State.BalanceText -StatusColor $script:State.StatusColor -Bob 0 -AnimationFrame $animationFrame -SleepAnimationFrame $sleepAnimationFrame
  if ($script:State.Frame) { $script:State.Frame.Dispose() }
  $script:State.Frame = $frame
  [PetLayer]::Push($script:Form.Handle, $frame, $script:BaseX, ($script:BaseY + $script:Bob))
  if ($script:State.IsRefreshing -or $script:State.TaskBusy) { Write-PetStatus }
}

function Set-Bob {
  param([int]$Offset)
  if ($Offset -eq $script:Bob) { return }
  $script:Bob = $Offset
  [PetLayer]::MoveTo($script:Form.Handle, $script:BaseX, ($script:BaseY + $script:Bob))
}

function Show-Bubble {
  param([string]$Text, [double]$Seconds = 4.0, [string]$Expression)
  $script:State.Bubble = $Text
  $script:State.BubbleUntil = (Get-Date).AddSeconds($Seconds)
  if ($Expression) {
    $script:State.Expression = $Expression
    $script:State.ExpressionUntil = (Get-Date).AddSeconds($Seconds)
  }
}

function Get-TalkLine {
  if ($script:State.LowBalance) {
    $line = $script:LowLines | Get-Random
  } else {
    $line = $script:Lines | Get-Random
  }
  return $line.Replace('{b}', $script:State.BalanceText)
}

function Clear-AccountSnapshot {
  $script:State.BalanceText = '—'
  $script:State.BalanceValue = $null
  $script:State.Currency = $null
  $script:State.LowBalance = $false
  $script:State.AccountDetail = ''
  $script:State.QueriedAt = $null
  $script:State.HasAccountSnapshot = $false
  $script:State.LastError = $null
}

function Update-Balance {
  if ($script:AccountTask) { return }
  # Only a confirmed change of account clears its previous display.
  # This local source lookup does not make a network request.
  try {
    $source = Invoke-AccountClient -Config (Get-ProviderConfig) -SourceOnly
    if ($script:State.AccountSource -and $script:State.AccountSource -ne $source.source_id) {
      Clear-AccountSnapshot
    }
    $script:State.AccountSource = $source.source_id
    $script:State.AccountKind = $source.kind
    $script:State.Provider = $source.provider
    $script:State.Model = $source.model
  } catch {
    $script:State.LastError = '无法识别当前账户，请检查查询模块'
    $script:State.StatusColor = 'Error'
    Write-PetStatus
    return
  }
  $script:State.QueryStartedAt = [datetime]::UtcNow
  $script:State.IsRefreshing = $true
  try {
    $script:AccountWorker = [PowerShell]::Create()
    [void]$script:AccountWorker.AddScript({
      param($clientScript, $accountScript)
      $ErrorActionPreference = 'Stop'
      . $clientScript
      Invoke-AccountClient -Config (Get-AccountClientConfig -AccountScript $accountScript)
    }).AddArgument($script:AccountClientScript).AddArgument($script:AccountScript)
    $script:AccountTask = $script:AccountWorker.BeginInvoke()
  } catch {
    if ($script:AccountWorker) { $script:AccountWorker.Dispose() }
    $script:AccountWorker = $null
    $script:AccountTask = $null
    $script:State.IsRefreshing = $false
    $script:State.LastError = '无法启动账户查询'
    $script:State.StatusColor = 'Error'
    Show-Bubble -Text '查询失败：无法启动账户查询' -Seconds 6 -Expression 'sad'
  }
  Write-PetStatus
}

function Complete-BalanceQuery {
  if (-not $script:AccountTask -or -not $script:AccountTask.IsCompleted) { return }
  $succeeded = $false
  try {
    $results = @($script:AccountWorker.EndInvoke($script:AccountTask))
    if ($script:AccountWorker.HadErrors -or $results.Count -eq 0) { throw '账户查询未完成，请检查服务商连接' }
    $query = $results[-1]
    if ($script:State.AccountSource -and $script:State.AccountSource -ne $query.source_id) { Clear-AccountSnapshot }
    $script:State.AccountKind = $query.kind
    $script:State.AccountSource = $query.source_id
    $script:State.Provider = $query.provider
    $script:State.Model = $query.model
    $display = ConvertTo-AccountDisplay -Query $query -Alert (Get-AlertThreshold)
    $script:State.BalanceText = $display.Text
    $script:State.BalanceValue = $display.Value
    $script:State.Currency = $display.Currency
    $script:State.AccountDetail = $display.Detail
    $script:State.QueriedAt = $display.QueriedAt
    $script:State.HasAccountSnapshot = $true
    $script:State.LowBalance = $display.Low
    $script:State.StatusColor = if ($display.Low) { 'Low' } else { 'Ok' }
    $script:State.LastError = $null
    if ($display.Low -and -not $script:State.Bubble) {
      $script:State.Expression = 'sad'
    }
    if ($script:State.Bubble -like '查询失败：*') { $script:State.Bubble = '' }
    $succeeded = $true
  } catch {
    if (-not $script:State.HasAccountSnapshot) { $script:State.BalanceText = '—' }
    $script:State.StatusColor = 'Error'
    $script:State.LastError = $_.Exception.Message
    $message = $_.Exception.Message
    if ($message.Length -gt 40) { $message = $message.Substring(0, 40) + '…' }
    Show-Bubble -Text ('查询失败：' + $message) -Seconds 6 -Expression 'sad'
  } finally {
    $script:AccountWorker.Dispose()
    $script:AccountWorker = $null
    $script:AccountTask = $null
    $script:State.IsRefreshing = $false
  }
  if ($succeeded) { Write-BalanceLog }
  if ($script:State.ShowStats) { Update-StatsText }
  Write-PetStatus
}

function Save-PetPosition {
  try {
    [pscustomobject]@{
      x         = $script:BaseX
      y         = $script:BaseY
      look      = if ($script:LookFiles.Count -gt 0) { $script:LookFiles[$script:LookIndex] } else { $null }
      stats     = [bool]$script:State.ShowStats
      noActivate = [bool]$script:State.NoActivate
      updatedAt = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding utf8
  } catch { }
}

function Get-SavedState {
  try {
    if (Test-Path -LiteralPath $script:StateFile) {
      $saved = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
      if ($null -ne $saved.x -and $null -ne $saved.y) {
        $showSavedStats = if ($null -ne $saved.stats) { [bool]$saved.stats } else { $true }
        $savedNoActivate = if ($saved.noActivate -is [bool]) { $saved.noActivate } else { $true }
        return @{ X = [int]$saved.x; Y = [int]$saved.y; Look = $saved.look; Stats = $showSavedStats; NoActivate = $savedNoActivate }
      }
    }
  } catch { }
  return $null
}

#endregion

#region 交互与主循环

Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot 'window-interaction.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) } catch { }

$form = New-Object BalancePetForm
$form.Text = '余额桌宠'
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.MinimizeBox = $false
$form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size($script:CanvasW, $script:CanvasH)
$form.BackColor = [System.Drawing.Color]::Black
$script:Form = $form

$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$saved = Get-SavedState
if ($saved) {
  if ($saved.Look) { $null = Set-Look -File $saved.Look }
  $script:State.ShowStats = [bool]$saved.Stats
  $script:State.NoActivate = [bool]$saved.NoActivate
  $script:BaseX = $saved.X
  $script:BaseY = $saved.Y
} else {
  $script:BaseX = $workArea.Right - $script:CanvasW - 40
  $script:BaseY = $workArea.Bottom - $script:CanvasH - 40
}
$form.NoActivate = [bool]$script:State.NoActivate
$form.Location = New-Object System.Drawing.Point($script:BaseX, $script:BaseY)

# 拖动
$script:Drag = @{ Active = $false; Offset = $null; Moved = $false }

$form.Add_MouseDown({
  param($sender, $event)
  if ($event.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $script:Drag.Active = $true
    $script:Drag.Moved = $false
    $script:Drag.Offset = $event.Location
    $script:Form.Capture = $true
  }
})

$form.Add_MouseMove({
  param($sender, $event)
  # 万一松开鼠标时窗口已失去捕获，这里兜底结束拖动，避免桌宠一直粘着鼠标
  if ($script:Drag.Active -and [System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::Left) {
    $script:Drag.Active = $false
    Save-PetPosition
    Write-PetStatus
    return
  }
  if ($script:Drag.Active) {
    $screenPoint = $script:Form.PointToScreen($event.Location)
    $newX = $screenPoint.X - $script:Drag.Offset.X
    $newY = $screenPoint.Y - $script:Drag.Offset.Y
    if ([Math]::Abs($newX - $script:BaseX) -gt 2 -or [Math]::Abs($newY - $script:BaseY) -gt 2) {
      $script:Drag.Moved = $true
    }
    $script:BaseX = $newX
    $script:BaseY = $newY
    [PetLayer]::MoveTo($script:Form.Handle, $script:BaseX, ($script:BaseY + $script:Bob))
  }
})

$form.Add_MouseUp({
  param($sender, $event)
  $script:Form.Capture = $false
  if ($event.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
  $wasDragging = $script:Drag.Active
  $script:Drag.Active = $false
  if (-not $wasDragging) { return }

  $script:State.LastInteraction = Get-Date
  if ($script:Drag.Moved) {
    Save-PetPosition
    Write-PetStatus
  } else {
    # 单击：刷新一次 + 说句话
    Update-Balance
    Show-Bubble -Text (Get-TalkLine) -Seconds 4 -Expression $(if ($script:State.LowBalance) { 'sad' } else { 'happy' })
    Sync-Frame
  }
})

# 右键菜单
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemRefresh = $menu.Items.Add('立即刷新余额')
$itemTalk = $menu.Items.Add('打个招呼')
$itemLook = $menu.Items.Add(('换个形象（共 {0} 个）' -f [Math]::Max(1, $script:LookFiles.Count)))
$itemStats = $menu.Items.Add('显示用量信息')
$itemStats.CheckOnClick = $true
$itemStats.Checked = [bool]$script:State.ShowStats
$itemNoActivate = $menu.Items.Add('不抢焦点')
$itemNoActivate.CheckOnClick = $true
$itemNoActivate.Checked = [bool]$script:State.NoActivate
$itemUsage = $menu.Items.Add('用量详情')
$itemAccount = $menu.Items.Add('账户余额 / 额度详情')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itemReset = $menu.Items.Add('回到右下角')
$itemExit = $menu.Items.Add('退出')

$itemRefresh.Add_Click({
  Update-Balance
  Sync-Frame
})
$itemAccount.Add_Click({
  $detail = if ($script:State.LastError) { '刷新失败：' + $script:State.LastError } elseif ($script:State.AccountDetail) { $script:State.AccountDetail } else { '暂无账户数据' }
  Show-Bubble -Text $detail -Seconds 12
  Sync-Frame -Force
})
$itemTalk.Add_Click({
  $script:State.LastInteraction = Get-Date
  Show-Bubble -Text (Get-TalkLine) -Seconds 4 -Expression 'happy'
  Sync-Frame
})
$itemLook.Add_Click({
  if ($script:LookFiles.Count -le 1) {
    Show-Bubble -Text 'assets 里只放了一个形象哦' -Seconds 3
    Sync-Frame
    return
  }
  $next = ($script:LookIndex + 1) % $script:LookFiles.Count
  $null = Set-Look -File $script:LookFiles[$next]
  Save-PetPosition
  Show-Bubble -Text ('形象 {0}/{1}' -f ($script:LookIndex + 1), $script:LookFiles.Count) -Seconds 3
  Sync-Frame -Force
})
$itemStats.Add_Click({
  $script:State.ShowStats = [bool]$itemStats.Checked
  if ($script:State.ShowStats) {
    Update-UsageStats
    Update-StatsText
  }
  Save-PetPosition
  Sync-Frame -Force
})
$itemUsage.Add_Click({
  $script:State.LastInteraction = Get-Date
  Update-UsageStats
  Show-Bubble -Text (Get-UsageDetail) -Seconds 12
  Sync-Frame -Force
})
$itemNoActivate.Add_Click({
  $script:Form.NoActivate = [bool]$itemNoActivate.Checked
  $script:State.NoActivate = [bool]$itemNoActivate.Checked
  Save-PetPosition
  Write-PetStatus
})
$itemReset.Add_Click({
  $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $script:BaseX = $area.Right - $script:CanvasW - 40
  $script:BaseY = $area.Bottom - $script:CanvasH - 40
  [PetLayer]::MoveTo($script:Form.Handle, $script:BaseX, $script:BaseY)
  Save-PetPosition
})
$itemExit.Add_Click({ $script:Form.Close() })
Connect-PetContextMenu -Form $form -Menu $menu

# 动画与状态推进
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 120
$animTimer.Add_Tick({
  Complete-BalanceQuery
  $now = Get-Date
  $state = $script:State

  # 台词到期
  if ($state.Bubble -and $now -gt $state.BubbleUntil) { $state.Bubble = '' }

  # 表情到期回落
  if ($state.Expression -in @('happy', 'sad', 'blink') -and $now -gt $state.ExpressionUntil -and $now -gt $state.BlinkUntil) {
    if ($state.LowBalance) { $state.Expression = 'sad' } else { $state.Expression = 'normal' }
  }

  # 眨眼
  if ($state.Expression -eq 'normal' -and $now -gt $state.NextBlinkAt) {
    $state.Expression = 'blink'
    $state.BlinkUntil = $now.AddMilliseconds(140)
    $state.NextBlinkAt = $now.AddSeconds((Get-Random -Minimum 3 -Maximum 7))
  }
  if ($state.Expression -eq 'blink' -and $now -gt $state.BlinkUntil) { $state.Expression = 'normal' }

  # 闲置打盹：任务进行中不睡（写字动画优先），超过阈值才蜷起来
  $idle = ($now - $state.LastInteraction).TotalSeconds
  if (-not $state.TaskBusy -and $idle -gt $IdleSleepSeconds -and $state.Expression -ne 'sleepy' -and -not $state.Bubble -and -not $state.IsRefreshing) {
    $state.Expression = 'sleepy'
  }
  if ($idle -lt 2 -and $state.Expression -eq 'sleepy') {
    $state.Expression = 'normal'
    $state.LastInteraction = $now
  }

  # 呼吸浮动
  if ($state.Expression -eq 'sleepy') {
    Set-Bob -Offset ([int][Math]::Round([Math]::Sin($state.BobPhase) * 2))
  } else {
    Set-Bob -Offset ([int][Math]::Round([Math]::Sin($state.BobPhase) * 3))
  }
  $state.BobPhase += 0.18

  Sync-Frame
})

# 余额刷新
$balanceTimer = New-Object System.Windows.Forms.Timer
$balanceTimer.Interval = [Math]::Max(5, $RefreshSeconds) * 1000
$balanceTimer.Add_Tick({
  if ($script:Drag.Active) { return }
  Update-Balance
})

# 随 Codex 关闭：找不到 Codex 进程连续 15 秒就自己退出
$watchdogTimer = New-Object System.Windows.Forms.Timer
$watchdogTimer.Interval = 5000
$watchdogTimer.Add_Tick({
  if (Test-CodexRunning) {
    $script:WatchdogMisses = 0
    return
  }
  $script:WatchdogMisses++
  if ($script:WatchdogMisses -ge 3) {
    Write-Host 'codex 已退出，桌宠随之关闭'
    $script:Form.Close()
  }
})

# Every five seconds: discover session changes, catch up history and refresh costs.
$statsTimer = New-Object System.Windows.Forms.Timer
$statsTimer.Interval = 5000
$statsTimer.Add_Tick({
  Update-UsageStats
  if ($script:State.ShowStats) {
    Update-StatsText
    Sync-Frame
  }
  Write-PetStatus
})

$rateTimer = New-Object System.Windows.Forms.Timer
$rateTimer.Interval = 1000
$rateTimer.Add_Tick({ Update-FastUsageStats })

$taskTimer = New-Object System.Windows.Forms.Timer
$taskTimer.Interval = 2000
$taskTimer.Add_Tick({
  Update-PetTaskActivity
  Sync-Frame
  Write-PetStatus
})

$form.Add_Shown({
  [PetLayer]::MakeLayered($script:Form.Handle)
  Update-Balance
  Update-UsageStats
  Update-PetTaskActivity
  if ($script:State.ShowStats) { Update-StatsText }
  $script:State.Expression = if ($script:State.LowBalance) { 'sad' } else { 'normal' }
  Sync-Frame -Force
  $animTimer.Start()
  $balanceTimer.Start()
  $statsTimer.Start()
  $rateTimer.Start()
  $taskTimer.Start()
  if (-not $DisableWatchdog) { $watchdogTimer.Start() }
})

$form.Add_FormClosed({
  $animTimer.Stop(); $balanceTimer.Stop(); $statsTimer.Stop(); $rateTimer.Stop(); $watchdogTimer.Stop(); $taskTimer.Stop()
  if ($script:AccountWorker) {
    try { $script:AccountWorker.Stop(); $script:AccountWorker.Dispose() } catch { }
  }
  Write-BalanceLog -Force
  Save-PetPosition
  if ($script:State.Frame) { $script:State.Frame.Dispose() }
  foreach ($sprite in $script:Sprites.Values) { $sprite.Dispose() }
  if ($script:WorkingAtlas) { $script:WorkingAtlas.Dispose() }
  if ($script:TaskActivity.StoreProcess) {
    try { if (-not $script:TaskActivity.StoreProcess.HasExited) { $script:TaskActivity.StoreProcess.Kill() }; $script:TaskActivity.StoreProcess.Dispose() } catch { }
  }
})

[System.Windows.Forms.Application]::Run($form)

#endregion
