# Marketing images for Riah To-Do.
#
# The note is rendered by its own paint code at 2x, then composed onto a
# desktop backdrop (taskbar + clock), same idea as Riah Usage's tray shot.
# Nothing here redraws a lookalike: what you see is the app.
param(
  [string]$Repo = 'C:\Code\Claude Cowork\Riah To-Do'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$work = Join-Path $env:TEMP ('riah-todo-shots-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$out = Join-Path $Repo 'docs\screenshots'
New-Item -ItemType Directory -Force $out | Out-Null

$DESK   = [System.Drawing.Color]::FromArgb(32, 36, 44)
$BAR    = [System.Drawing.Color]::FromArgb(24, 26, 30)
$BARLINE= [System.Drawing.Color]::FromArgb(55, 58, 66)
$ICON   = [System.Drawing.Color]::FromArgb(70, 74, 84)
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

function Invoke-Poster([string]$store, [string]$png, [int]$w, [int]$h, [int]$scale) {
  $env:RIAH_TODO_FILE = $store
  $env:RIAH_TODO_TRAY_SHOT = (Join-Path $work ('raw-' + [IO.Path]::GetFileName($png)))
  $env:RIAH_TODO_TRAY_POSTER = $png
  $env:RIAH_TODO_TRAY_POSTER_W = $w
  $env:RIAH_TODO_TRAY_POSTER_H = $h
  $env:RIAH_TODO_TRAY_POSTER_SCALE = $scale
  $r = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $Repo 'tray\riah-todo-tray.ps1') 2>&1
  Remove-Item Env:RIAH_TODO_TRAY_POSTER, Env:RIAH_TODO_TRAY_POSTER_W, Env:RIAH_TODO_TRAY_POSTER_H,
    Env:RIAH_TODO_TRAY_POSTER_SCALE, Env:RIAH_TODO_TRAY_SHOT -ErrorAction SilentlyContinue
  $line = ($r | Select-String 'TRAY_POSTER_OK|TRAY_NOTE_FAILED' | Select-Object -First 1)
  if (-not $line) { throw ("no poster came back: " + ($r -join ' ')) }
  Write-Host ('  ' + $line)
  if (-not (Test-Path $png)) { throw "poster missing at $png" }
}

function New-Desktop([int]$w, [int]$h) {
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'ClearTypeGridFit'
  $g.InterpolationMode = 'HighQualityBicubic'

  $bg = New-Object System.Drawing.SolidBrush($DESK)
  $g.FillRectangle($bg, 0, 0, $w, $h)
  $bg.Dispose()

  # Quiet desktop icons on the left - enough to read as a real desk.
  $ib = New-Object System.Drawing.SolidBrush($ICON)
  $fIcon = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
  $tb = New-Object System.Drawing.SolidBrush($CLOCK)
  $labels = @('Claude', 'ChatGPT', 'Cursor')
  for ($i = 0; $i -lt 3; $i++) {
    $ix = 48; $iy = 48 + ($i * 110)
    $g.FillRectangle($ib, $ix, $iy, 48, 48)
    $g.DrawString($labels[$i], $fIcon, $tb, ($ix - 4), ($iy + 54))
  }
  $ib.Dispose(); $fIcon.Dispose(); $tb.Dispose()

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
  $clock = (Get-Date -Format 'h:mm tt') + "`n" + (Get-Date -Format 'M/d/yyyy')
  $sz = $g.MeasureString($clock, $fClock)
  $g.DrawString($clock, $fClock, $bClock, ($w - $sz.Width - 18), ($barY + 6))
  # Tiny pink tray mark next to the clock - the product lives here.
  $pink = New-Object System.Drawing.SolidBrush($PINK)
  $g.FillRectangle($pink, [int]($w - $sz.Width - 40), [int]($barY + 16), 12, 12)
  $pink.Dispose(); $fClock.Dispose(); $bClock.Dispose()

  return @($bmp, $g, $barH)
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

function Place-On-Desktop([string]$notePath, [string]$dest, [int]$deskW, [int]$deskH, [int]$maxNoteH) {
  $note = [System.Drawing.Image]::FromFile($notePath)
  $scale = 1.0
  if ($note.Height -gt $maxNoteH) { $scale = $maxNoteH / $note.Height }
  $nw = [int]($note.Width * $scale)
  $nh = [int]($note.Height * $scale)
  $pair = New-Desktop $deskW $deskH
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
Invoke-Poster $storeA $noteA 520 0 2

# ------------------------------------------------------------- the long list
$long = New-Object System.Collections.ArrayList
[void]$long.Add((Item 'b1' 'Ship the Gumroad listing' $null $false 'today'))
[void]$long.Add((Item 'b2' 'Write the description' 'b1' $true 'today'))
[void]$long.Add((Item 'b3' 'Shoot the cover' 'b1' $false 'today'))
[void]$long.Add((Item 'b4' 'Call the accountant back' $null $true 'today'))
[void]$long.Add((Item 'b5' 'Draft the newsletter' $null $false 'today'))
[void]$long.Add((Item 'b6' 'Chase the invoice from March' $null $false 'today'))
[void]$long.Add((Item 'b7' 'Book the dentist' $null $false 'today'))
[void]$long.Add((Item 'b8' 'Renew the domain' $null $false 'today'))
[void]$long.Add((Item 'b9' 'Reply to Sam about the podcast' $null $false 'today'))
[void]$long.Add((Item 'b10' 'Selah launch checklist' $null $false 'tomorrow'))
[void]$long.Add((Item 'b11' 'Write the launch post' 'b10' $false 'tomorrow'))
[void]$long.Add((Item 'b12' 'Riah Money' $null $false 'future'))
[void]$long.Add((Item 'b13' 'Look at a proper accountant' $null $false 'future'))
$storeB = Join-Path $work 'b.json'
New-Store $storeB $long.ToArray()
$noteB = Join-Path $work 'note-b.png'
Invoke-Poster $storeB $noteB 480 470 2

# ------------------------------------------------------------------ compose
Write-Host 'Composing onto a desktop...'

# Wide desktop shots - note by the clock, like Usage's tray-hover.
Place-On-Desktop $noteA (Join-Path $out 'note-dark.png') 1280 800 620
Place-On-Desktop $noteB (Join-Path $out 'note-scrolling.png') 1280 800 470

# Social card: 1200x630, note on the left of a desk strip, promise on the right.
$note = [System.Drawing.Image]::FromFile($noteA)
$pair = New-Desktop 1200 630
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
