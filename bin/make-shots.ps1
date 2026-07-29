# Marketing images for Riah To-Do.
#
# The note is rendered by its own paint code at 2x, then composed onto a
# backdrop. Nothing here redraws a lookalike: what you see is the app.
param(
  [string]$Repo = 'C:\Code\Claude Cowork\Riah To-Do'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$work = Join-Path $env:TEMP ('riah-todo-shots-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$out = Join-Path $Repo 'docs\screenshots'
New-Item -ItemType Directory -Force $out | Out-Null

$BG     = [System.Drawing.Color]::FromArgb(15, 15, 17)
$GRID   = [System.Drawing.Color]::FromArgb(26, 26, 30)
$INK    = [System.Drawing.Color]::FromArgb(237, 237, 239)
$BODY   = [System.Drawing.Color]::FromArgb(154, 154, 162)
$PINK   = [System.Drawing.Color]::FromArgb(255, 92, 168)

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

function New-Backdrop([int]$w, [int]$h) {
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'AntiAliasGridFit'
  $bg = New-Object System.Drawing.SolidBrush($BG)
  $g.FillRectangle($bg, 0, 0, $w, $h)
  $bg.Dispose()
  # A faint grid, the same one the studio's other covers use. Quiet enough that
  # the note is still the only thing you look at.
  $pen = New-Object System.Drawing.Pen($GRID, 1)
  for ($x = 0; $x -lt $w; $x += 64) { $g.DrawLine($pen, $x, 0, $x, $h) }
  for ($y = 0; $y -lt $h; $y += 64) { $g.DrawLine($pen, 0, $y, $w, $y) }
  $pen.Dispose()
  return @($bmp, $g)
}

function Add-Shadow($g, [int]$x, [int]$y, [int]$w, [int]$h) {
  for ($i = 18; $i -ge 1; $i--) {
    $a = [int](40 / $i)
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
Write-Host 'Composing...'

# 1. Hero: square, the note centred.
$note = [System.Drawing.Image]::FromFile($noteA)
$pad = 130
$cw = $note.Width + 2 * $pad; $ch = $note.Height + 2 * $pad
$pair = New-Backdrop $cw $ch
$bmp = $pair[0]; $g = $pair[1]
Add-Shadow $g $pad $pad $note.Width $note.Height
$g.DrawImage($note, $pad, $pad, $note.Width, $note.Height)
$g.Dispose(); $note.Dispose()
Save-Png $bmp (Join-Path $out 'note-dark.png')

# 2. Long list, same treatment.
$note = [System.Drawing.Image]::FromFile($noteB)
$pad2 = 130
$pair = New-Backdrop ($note.Width + 2 * $pad2) ($note.Height + 2 * $pad2)
$bmp = $pair[0]; $g = $pair[1]
Add-Shadow $g $pad2 $pad2 $note.Width $note.Height
$g.DrawImage($note, $pad2, $pad2, $note.Width, $note.Height)
$g.Dispose(); $note.Dispose()
Save-Png $bmp (Join-Path $out 'note-scrolling.png')

# 3. Social card: 1200x630, note on the left, the promise on the right.
$note = [System.Drawing.Image]::FromFile($noteA)
$pair = New-Backdrop 1200 630
$bmp = $pair[0]; $g = $pair[1]
$scale = 470 / $note.Height
$nw = [int]($note.Width * $scale); $nh = [int]($note.Height * $scale)
$nx = 96; $ny = [int]((630 - $nh) / 2)
Add-Shadow $g $nx $ny $nw $nh
$g.InterpolationMode = 'HighQualityBicubic'
$g.DrawImage($note, $nx, $ny, $nw, $nh)

$fBrand = New-Object System.Drawing.Font('Georgia', 26, ([System.Drawing.FontStyle]::Italic))
$fProd  = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Regular)
$fHead  = New-Object System.Drawing.Font('Georgia', 40, [System.Drawing.FontStyle]::Regular)
$fBody  = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Regular)
$bPink  = New-Object System.Drawing.SolidBrush($PINK)
$bInk   = New-Object System.Drawing.SolidBrush($INK)
$bBody  = New-Object System.Drawing.SolidBrush($BODY)
$tx = $nx + $nw + 92
$g.DrawString('Riah', $fBrand, $bPink, $tx, 168)
$rw = $g.MeasureString('Riah', $fBrand).Width
$g.DrawString('To-Do', $fProd, $bInk, ($tx + $rw - 4), 176)
$box = New-Object System.Drawing.RectangleF($tx, 232, (1200 - $tx - 80), 190)
$g.DrawString("The to-do list you'll actually open.", $fHead, $bInk, $box)
$g.DrawString('Free, MIT licensed, Windows 10 and 11.', $fBody, $bBody, $tx, 424)
$fBrand.Dispose(); $fProd.Dispose(); $fHead.Dispose(); $fBody.Dispose()
$bPink.Dispose(); $bInk.Dispose(); $bBody.Dispose()
$g.Dispose(); $note.Dispose()
Save-Png $bmp (Join-Path $out 'social-card.png')

# 4. The bare note, no backdrop, for the sales page to place on its own.
$bare = Join-Path (Join-Path $Repo 'docs') (Join-Path 'assets' 'note-2x.png')
Copy-Item $noteA $bare -Force
Write-Host ('  saved note-2x.png  ' + [int]((Get-Item $bare).Length / 1KB) + ' KB')

Write-Host ('Done. ' + $out)
