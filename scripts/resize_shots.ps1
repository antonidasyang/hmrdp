# 把 tmp\shots\ 里的截图批量改成 AGC 要求的尺寸，输出到 tmp\shots\out\（Windows PowerShell）。
#
# 用法（在仓库根目录执行）：
#   powershell -ExecutionPolicy Bypass -File scripts\resize_shots.ps1 -Width 1920 -Height 1080
#   powershell -ExecutionPolicy Bypass -File scripts\resize_shots.ps1 -Width 1920 -Height 1080 -Mode fit
#
# Mode：
#   fill（默认）等比缩放后居中裁切，铺满目标尺寸、无黑边，但会裁掉边缘一点内容
#   fit            等比缩放后居中留边，内容完整，四周补背景色（-Background 可改）
param(
  [Parameter(Mandatory = $true)][int]$Width,
  [Parameter(Mandatory = $true)][int]$Height,
  [ValidateSet('fill', 'fit')][string]$Mode = 'fill',
  [string]$Background = '#FF1B1B1B',
  [string]$Source = 'tmp\shots',
  [string]$OutDir = 'tmp\shots\out'
)

Add-Type -AssemblyName System.Drawing

if (-not (Test-Path $Source)) { Write-Error "找不到目录 $Source，先用 scripts\screenshot.bat 抓图"; exit 1 }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$files = Get-ChildItem -Path $Source -File | Where-Object { $_.Extension -match '^\.(png|jpg|jpeg)$' }
if ($files.Count -eq 0) { Write-Error "$Source 里没有图片"; exit 1 }

foreach ($f in $files) {
  $src = [System.Drawing.Image]::FromFile($f.FullName)
  $canvas = New-Object System.Drawing.Bitmap($Width, $Height)
  $g = [System.Drawing.Graphics]::FromImage($canvas)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.ColorTranslator]::FromHtml($Background))

  # fill 取较大缩放比（铺满后裁切），fit 取较小（完整留边）
  $sx = $Width / $src.Width
  $sy = $Height / $src.Height
  $scale = if ($Mode -eq 'fill') { [Math]::Max($sx, $sy) } else { [Math]::Min($sx, $sy) }
  $w = [int][Math]::Round($src.Width * $scale)
  $h = [int][Math]::Round($src.Height * $scale)
  $x = [int](($Width - $w) / 2)
  $y = [int](($Height - $h) / 2)
  $g.DrawImage($src, $x, $y, $w, $h)

  $out = Join-Path $OutDir ("{0}_{1}x{2}.png" -f $f.BaseName, $Width, $Height)
  $canvas.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $kb = [Math]::Round((Get-Item $out).Length / 1KB)
  Write-Host ("[完成] {0}  {1}x{2} -> {3}x{4}  {5} KB  ({6})" -f $f.Name, $src.Width, $src.Height, $Width, $Height, $kb, $Mode)

  $g.Dispose(); $canvas.Dispose(); $src.Dispose()
}

Write-Host ""
Write-Host "输出目录: $OutDir"
Write-Host "注意：AGC 单张截图一般限 2MB 以内，超了就把 -Width/-Height 调小或改存 jpeg。"
