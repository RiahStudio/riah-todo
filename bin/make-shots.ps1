# Marketing images for Riah To-Do.
#
# The note is rendered by its own paint code at 2x, then composed onto a
# desktop backdrop (taskbar + clock), same idea as Riah Usage's tray shot.
# Nothing here redraws a lookalike: what you see is the app.
param(
  [string]$Repo = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
Add-Type -AssemblyName System.Drawing

$work = Join-Path $env:TEMP ('riah-todo-shots-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$out = Join-Path $Repo 'docs\screenshots'
New-Item -ItemType Directory -Force $out | Out-Null

$DESK   = [System.Drawing.Color]::FromArgb(32, 36, 44)
$BAR    = [System.Drawing.Color]::FromArgb(24, 26, 30)
$BARLINE= [System.Drawing.Color]::FromArgb(55, 58, 66)
$CLOCK  = [System.Drawing.Color]::FromArgb(200, 202, 208)
$PINK   = [System.Drawing.Color]::FromArgb(255, 92, 168)
$INK    = [System.Drawing.Color]::FromArgb(237, 237, 239)
$BODY   = [System.Drawing.Color]::FromArgb(154, 154, 162)

function New-Store([string]$path, $items) {
  $list = @{ date = (Get-Date -Format 'yyyy-MM-dd'); items = $items }
  ($list | ConvertTo-Json -Depth 6) | Set-Content -Path $path -Encoding UTF8
}

function Item($id, $label, $parent, $done, $section) {
  return @{ id = $id; label = $label; parentId = $parent; completed = $done
            completedAt = $(if ($done) { (Get-Date).ToString('o') } else { $null })
            section = $section }
}

function Invoke-Poster([string]$store, [string]$png, [int]$w, [int]$h, [int]$scale, [string]$iconPng) {
  $env:RIAH_TODO_FILE = $store
  $env:RIAH_TODO_TRAY_SHOT = (Join-Path $work ('raw-' + [IO.Path]::GetFileName($png)))
  $env:RIAH_TODO_TRAY_POSTER = $png
  $env:RIAH_TODO_TRAY_POSTER_W = $w
  $env:RIAH_TODO_TRAY_POSTER_H = $h
  $env:RIAH_TODO_TRAY_POSTER_SCALE = $scale
  if ($iconPng) { $env:RIAH_TODO_TRAY_ICON = $iconPng }
  $r = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $Repo 'tray\riah-todo-tray.ps1') 2>&1
  Remove-Item Env:RIAH_TODO_TRAY_POSTER, Env:RIAH_TODO_TRAY_POSTER_W, Env:RIAH_TODO_TRAY_POSTER_H,
    Env:RIAH_TODO_TRAY_POSTER_SCALE, Env:RIAH_TODO_TRAY_SHOT, Env:RIAH_TODO_TRAY_ICON -ErrorAction SilentlyContinue
  $line = ($r | Select-String 'TRAY_POSTER_OK|TRAY_NOTE_FAILED' | Select-Object -First 1)
  if (-not $line) { throw ("no poster came back: " + ($r -join ' ')) }
  Write-Host ('  ' + $line)
  if (-not (Test-Path $png)) { throw "poster missing at $png" }
}

function New-Desktop([int]$w, [int]$h, [string]$trayIcon) {
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'ClearTypeGridFit'
  $g.InterpolationMode = 'HighQualityBicubic'

  $bg = New-Object System.Drawing.SolidBrush($DESK)
  $g.FillRectangle($bg, 0, 0, $w, $h)
  $bg.Dispose()

  # Real desktop icons on the left — Claude / Cursor / Codex art, not grey boxes.
  $iconDir = Join-Path $Repo 'docs\screenshots\icons'
  $deskIcons = @(
    @{ Label = 'Claude'; File = 'claude.png' },
    @{ Label = 'Cursor'; File = 'cursor.png' },
    @{ Label = 'Codex';  File = 'codex.png' }
  )
  $fIcon = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
  $tb = New-Object System.Drawing.SolidBrush($CLOCK)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = [System.Drawing.StringAlignment]::Center
  for ($i = 0; $i -lt $deskIcons.Count; $i++) {
    $ix = 48; $iy = 48 + ($i * 110)
    $iconPath = Join-Path $iconDir $deskIcons[$i].File
    if (-not (Test-Path $iconPath)) { throw "missing desktop icon: $iconPath" }
    $img = [System.Drawing.Image]::FromFile($iconPath)
    $g.DrawImage($img, $ix, $iy, 48, 48)
    $img.Dispose()
    $labelRect = New-Object System.Drawing.RectangleF(($ix - 12), ($iy + 52), 72, 28)
    $g.DrawString($deskIcons[$i].Label, $fIcon, $tb, $labelRect, $sf)
  }
  $fIcon.Dispose(); $tb.Dispose(); $sf.Dispose()

  # Taskbar + clock (where the tray icon lives).
  $barH = 48
  $barY = $h - $barH
  $barBrush = New-Object System.Drawing.SolidBrush($BAR)
  $g.FillRectangle($barBrush, 0, $barY, $w, $barH)
  $barBrush.Dispose()
  $pen = New-Object System.Drawing.Pen($BARLINE, 1)
  $g.DrawLine($pen, 0, $barY, $w, $barY)
  $pen.Dispose()

  $fClock = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
  $bClock = New-Object System.Drawing.SolidBrush($CLOCK)
  $clockText = (Get-Date -Format 'h:mm tt') + "`n" + (Get-Date -Format 'M/d/yyyy')
  $sz = $g.MeasureString($clockText, $fClock)
  $clockPad = 16
  $clockX = $w - $sz.Width - $clockPad
  $g.DrawString($clockText, $fClock, $bClock, $clockX, ($barY + 6))
  $fClock.Dispose(); $bClock.Dispose()

  # Win11 notification area. Sized and spaced for a GitHub-half-width shot:
  # native 32px To-Do mark, Windows MDL2 wifi + volume, real gaps between them.
  if (-not $trayIcon -or -not (Test-Path $trayIcon)) {
    throw "missing the live tray icon at $trayIcon"
  }
  $appS = 32
  $glyphS = 24
  $volX = [int]($clockX - 28 - $glyphS)
  $wifiX = $volX - 22 - $glyphS
  $appX = $wifiX - 32 - $appS
  Add-TrayGlyph $g 0xE767 $volX ($barY + [int](($barH - $glyphS) / 2)) $glyphS
  Add-TrayGlyph $g 0xE701 $wifiX ($barY + [int](($barH - $glyphS) / 2)) $glyphS
  $app = [System.Drawing.Image]::FromFile($trayIcon)
  $iy = $barY + [int](($barH - $appS) / 2)
  $g.DrawImage($app, $appX, $iy, $appS, $appS)
  $app.Dispose()

  return @($bmp, $g, $barH)
}

function Get-Mdl2Font([int]$px) {
  if (-not $script:Mdl2) {
    $script:Mdl2 = New-Object System.Drawing.Text.PrivateFontCollection
    $script:Mdl2.AddFontFile('C:\Windows\Fonts\segmdl2.ttf')
  }
  return New-Object System.Drawing.Font(
    $script:Mdl2.Families[0], $px,
    [System.Drawing.FontStyle]::Regular,
    [System.Drawing.GraphicsUnit]::Pixel)
}

function Add-TrayGlyph($g, [int]$code, [int]$x, [int]$y, [int]$size) {
  # Paint the Windows glyph at 4x, then scale down so it stays sharp in the shot.
  $hi = $size * 4
  $bmp = New-Object System.Drawing.Bitmap($hi, $hi)
  $gg = [System.Drawing.Graphics]::FromImage($bmp)
  $gg.SmoothingMode = 'AntiAlias'
  $gg.TextRenderingHint = 'AntiAliasGridFit'
  $gg.Clear([System.Drawing.Color]::Transparent)
  $font = Get-Mdl2Font ($hi - 8)
  $brush = New-Object System.Drawing.SolidBrush($CLOCK)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = [System.Drawing.StringAlignment]::Center
  $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
  $rect = New-Object System.Drawing.RectangleF(0, 0, $hi, $hi)
  $gg.DrawString([string][char]$code, $font, $brush, $rect, $sf)
  $font.Dispose(); $brush.Dispose(); $sf.Dispose(); $gg.Dispose()
  $g.DrawImage($bmp, $x, $y, $size, $size)
  $bmp.Dispose()
}

function Add-Shadow($g, [int]$x, [int]$y, [int]$w, [int]$h) {
  for ($i = 18; $i -ge 1; $i--) {
    $a = [int](36 / $i)
    $b = New-Object System.Drawing.SolidBrush(
      [System.Drawing.Color]::FromArgb($a, 0, 0, 0))
    $g.FillRectangle($b, ($x - $i), ($y - $i + 6), ($w + 2 * $i), ($h + 2 * $i))
    $b.Dispose()
  }
}

function Save-Png($bmp, [string]$path) {
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  $kb = [int]((Get-Item $path).Length / 1KB)
  Write-Host ("  saved " + [IO.Path]::GetFileName($path) + "  " + $kb + " KB")
}

function Place-On-Desktop([string]$notePath, [string]$dest, [int]$deskW, [int]$deskH, [int]$maxNoteH, [string]$trayIcon) {
  $note = [System.Drawing.Image]::FromFile($notePath)
  $scale = 1.0
  if ($note.Height -gt $maxNoteH) { $scale = $maxNoteH / $note.Height }
  $nw = [int]($note.Width * $scale)
  $nh = [int]($note.Height * $scale)
  $pair = New-Desktop $deskW $deskH $trayIcon
  $bmp = $pair[0]; $g = $pair[1]; $barH = $pair[2]
  # Sit above the tray / clock, top-right - where the real note opens.
  $nx = $deskW - $nw - 36
  $ny = $deskH - $barH - $nh - 18
  if ($ny -lt 24) { $ny = 24 }
  Add-Shadow $g $nx $ny $nw $nh
  $g.DrawImage($note, $nx, $ny, $nw, $nh)
  $g.Dispose(); $note.Dispose()
  Save-Png $bmp $dest
}

# ---------------------------------------------------------------- the day list
Write-Host 'Rendering the note...'
$storeA = Join-Path $work 'a.json'
New-Store $storeA @(
  (Item 'a1' 'Ship the Gumroad listing' $null $false 'today'),
  (Item 'a2' 'Write the description' 'a1' $true 'today'),
  (Item 'a3' 'Shoot the cover' 'a1' $false 'today'),
  (Item 'a4' 'Borrow the good lamp' 'a3' $false 'today'),
  (Item 'a5' 'Call the accountant back' $null $true 'today'),
  (Item 'a6' 'Draft the newsletter' $null $false 'today'),
  (Item 'a7' 'Selah launch checklist' $null $false 'tomorrow'),
  (Item 'a8' 'Riah Money' $null $false 'future')
)
$noteA = Join-Path $work 'note-a.png'
$iconA = Join-Path $work 'icon-a.png'
Invoke-Poster $storeA $noteA 520 0 2 $iconA
if (-not (Test-Path $iconA)) { throw "live tray icon missing at $iconA" }

# A different day, narrower. Only today's visible thread, so the tally matches
# what you can actually see (hidden rows were reading as a broken count).
$storeB = Join-Path $work 'b.json'
New-Store $storeB @(
  (Item 'b1' 'Pack for the trip' $null $false 'today'),
  (Item 'b2' 'Find the charger' 'b1' $false 'today'),
  (Item 'b3' 'Print the boarding pass' 'b1' $true 'today'),
  (Item 'b4' 'Meds in the carry-on' 'b1' $false 'today')
)
$noteB = Join-Path $work 'note-b.png'
$iconB = Join-Path $work 'icon-b.png'
Invoke-Poster $storeB $noteB 360 0 2 $iconB
if (-not (Test-Path $iconB)) { throw "live tray icon missing at $iconB" }

# ------------------------------------------------------------------ compose
Write-Host 'Composing onto a desktop...'

Place-On-Desktop $noteA (Join-Path $out 'note-dark.png') 1280 800 720 $iconA
Place-On-Desktop $noteB (Join-Path $out 'note-scrolling.png') 1280 800 380 $iconB

# Social card: 1200x630, note on the left of a desk strip, promise on the right.
$note = [System.Drawing.Image]::FromFile($noteA)
$pair = New-Desktop 1200 630 $iconA
$bmp = $pair[0]; $g = $pair[1]; $barH = $pair[2]
$scale = 520 / $note.Height
$nw = [int]($note.Width * $scale); $nh = [int]($note.Height * $scale)
$nx = 64; $ny = [int]((630 - $barH - $nh) / 2)
if ($ny -lt 24) { $ny = 24 }
Add-Shadow $g $nx $ny $nw $nh
$g.DrawImage($note, $nx, $ny, $nw, $nh)

$fBrand = New-Object System.Drawing.Font('Georgia', 26, ([System.Drawing.FontStyle]::Italic))
$fProd  = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Regular)
$fHead  = New-Object System.Drawing.Font('Georgia', 36, [System.Drawing.FontStyle]::Regular)
$fBody  = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Regular)
$bPink  = New-Object System.Drawing.SolidBrush($PINK)
$bInk   = New-Object System.Drawing.SolidBrush($INK)
$bBody  = New-Object System.Drawing.SolidBrush($BODY)
$tx = $nx + $nw + 72
$g.DrawString('Riah', $fBrand, $bPink, $tx, 150)
$rw = $g.MeasureString('Riah', $fBrand).Width
$g.DrawString('To-Do', $fProd, $bInk, ($tx + $rw - 4), 158)
$box = New-Object System.Drawing.RectangleF($tx, 214, (1200 - $tx - 64), 160)
$g.DrawString("The to-do list you'll actually open.", $fHead, $bInk, $box)
$g.DrawString('Free, MIT licensed, Windows 10 and 11.', $fBody, $bBody, $tx, 400)
$fBrand.Dispose(); $fProd.Dispose(); $fHead.Dispose(); $fBody.Dispose()
$bPink.Dispose(); $bInk.Dispose(); $bBody.Dispose()
$g.Dispose(); $note.Dispose()
Save-Png $bmp (Join-Path $out 'social-card.png')

$bare = Join-Path (Join-Path $Repo 'docs') (Join-Path 'assets' 'note-2x.png')
Copy-Item $noteA $bare -Force
Write-Host ('  saved note-2x.png  ' + [int]((Get-Item $bare).Length / 1KB) + ' KB')

Write-Host ('Done. ' + $out)

