# Riah To-Do tray -- today's list by the clock. Windows only, zero installs.
#
# CLICK, never hover. (Captain, 2026-07-28: "I don't want it to be hover-to-pop-up.
# I want it to be click-to-pop-up.") Hovering the icon does nothing at all.
#
# Left-click icon : opens the note in the TOP-RIGHT corner of the screen.
# Click anywhere out: it goes away, and stays away until the icon is clicked again.
# Click a row     : ticks it off (or un-ticks it). Writes straight to the file.
# Right-click row : rename / remove / move up / move down.
# Type + Enter    : adds a priority.
# Esc, or the x   : closes it too.
# Right-click icon: menu, incl. "Open the board" (the full page).
#
# There is NO server in the middle. The list is a JSON file and this script reads
# and writes it directly, so the note keeps working when nothing else is running.
# Riah Code and the board write the same file; a poll picks their changes up.
#
# NOTE: keep this file ASCII-only (Windows PowerShell 5.1).

$ErrorActionPreference = 'SilentlyContinue'
$script:HasNative = $false
$script:DpiAware = $false

$script:Root    = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:LogPath = Join-Path $script:Root 'scratch\tray.log'

# The note is a script, not an installed program, so updating it means editing
# this file. A copy already running would keep the old behaviour for as long as
# it stays up -- which makes a real fix look like it did not work. Remember what
# we loaded, and pick up a newer one while nothing is open.
$script:ScriptStamp  = $null
$script:PendingStamp = $null
try { $script:ScriptStamp = (Get-Item $PSCommandPath).LastWriteTimeUtc.Ticks } catch {}

function Write-TrayLog([string]$msg) {
  try {
    $dir = Split-Path -Parent $script:LogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $script:LogPath -Value $line -Encoding ASCII
  } catch {}
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA',
    '-File', ('"{0}"' -f $PSCommandPath)
  ) | Out-Null
  exit 0
}

# Shot mode is the visual smoke test: draw the note, save it as a PNG, quit.
# It must not fight the real tray for the single-instance mutex.
$script:ShotPath = $env:RIAH_TODO_TRAY_SHOT
if (-not $script:ShotPath) {
  $created = $false
  # Script-scoped: a reload has to let go of this before its replacement starts,
  # or the replacement sees the name taken and exits immediately.
  $script:Mutex = New-Object System.Threading.Mutex($true, 'RiahTodoTray', [ref]$created)
  if (-not $created) {
    Write-TrayLog 'exit_duplicate_instance'
    exit 0
  }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- native bits: DPI, true icon rect, and putting the window where we asked ---
function Ensure-NativeType {
  if ('RiahTodo.Native' -as [type]) { $script:HasNative = $true; return $true }
  $src = @'
using System;
using System.Runtime.InteropServices;
namespace RiahTodo {
  public static class Native {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct NOTIFYICONIDENTIFIER {
      public uint cbSize;
      public IntPtr hWnd;
      public uint uID;
      public Guid guidItem;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
      int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("shell32.dll", SetLastError=true)]
    public static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER identifier, out RECT iconLocation);
  }
}
'@
  try {
    Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
    $script:HasNative = [bool]('RiahTodo.Native' -as [type])
  } catch {
    $script:HasNative = [bool]('RiahTodo.Native' -as [type])
    if (-not $script:HasNative) { Write-TrayLog ('native_type_fail: ' + $_.Exception.Message) }
  }
  return $script:HasNative
}

try {
  [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
    [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
  [System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    try { Write-TrayLog ('thread_exception: ' + $e.Exception.Message) } catch {}
  })
} catch {}

Write-TrayLog 'starting'
Ensure-NativeType | Out-Null
if ($script:HasNative) { try { $script:DpiAware = [RiahTodo.Native]::SetProcessDPIAware() } catch {} }
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- the list on disk (same file Riah Code and the board use) ---
# Backstops against a runaway paste, not a rule about how many things a person
# may have on today. (Captain, 2026-07-29: "we absolutely should not have a
# 12-task limit".) Matches lib/store.mjs.
$script:MaxItems = 100
$script:MaxSubtasks = 100
# 0 is a top-level task, so six levels. Matches MAX_DEPTH in lib/store.mjs.
$script:MaxDepth = 5
$script:MaxLabel = 120
$script:Port = 8779
if ($env:RIAH_TODO_PORT) { try { $script:Port = [int]$env:RIAH_TODO_PORT } catch {} }
$script:BaseUrl = 'http://127.0.0.1:{0}' -f $script:Port

function Get-StorePath {
  if ($env:RIAH_TODO_FILE) { return $env:RIAH_TODO_FILE }
  $dir = $env:RIAH_TODO_DIR
  if (-not $dir) { $dir = Join-Path $env:APPDATA 'Riah To-Do' }
  return (Join-Path $dir 'today.json')
}
$script:StorePath = Get-StorePath
$script:FiledPath = Join-Path (Split-Path -Parent $script:StorePath) 'today-filed.json'
$script:SettingsPath = Join-Path (Split-Path -Parent $script:StorePath) 'settings.json'
# Defaults match what the note did before settings existed, so a machine with no
# settings file behaves exactly as it used to.
$script:FileAfterMinutes = 120
$script:VaultPath = ''
$script:VaultSubfolder = ''
$script:PosPath   = Join-Path $script:Root 'scratch\note-geometry.json'
$script:List      = @{ date = (Get-Date -Format 'yyyy-MM-dd'); items = @() }
$script:LastStamp = $null
$script:LongAgo   = (Get-Date).AddDays(-1)

function New-Id { return [guid]::NewGuid().ToString() }

# --- cross-process lock (same protocol as lib/store.mjs) ---
# An atomic rename stops a torn READ. It does nothing about two writers who both
# read "3 items", both add one, and both write "4" -- one task is simply gone.
# Every read-modify-write here takes this lock, and so does the Node side. Keep
# the two in step: same lock file, same stale window.
$script:LockStaleMs = 10000
$script:LockHandle = $null

# Fifteen seconds, matching lib/store.mjs. The lock is held for milliseconds, so
# nobody ever waits; this only stretches genuine contention, and a dead owner is
# reclaimed at once via its PID.
function Enter-StoreLock([int]$timeoutMs = 15000) {
  $lock = $script:StorePath + '.lock'
  $started = Get-Date
  $script:LockHandle = $null
  while ($true) {
    try {
      $script:LockHandle = [System.IO.File]::Open($lock, 'CreateNew', 'Write', 'None')
      # Stamp the owner, in the same shape lib/store.mjs writes and reads. Age
      # alone is not evidence of abandonment -- a busy holder can outlive any
      # window you pick, and stealing its lock puts two writers on one file.
      try {
        $stamp = '{"pid":' + $PID + ',"at":' + [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) + '}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($stamp)
        $script:LockHandle.Write($bytes, 0, $bytes.Length)
        $script:LockHandle.Flush()
      } catch {}
      return $true
    } catch {
      # Only reclaim a lock whose owner is genuinely gone.
      try {
        $held = [System.IO.File]::ReadAllText($lock) | ConvertFrom-Json
        $alive = $false
        if ($held.pid) { $alive = [bool](Get-Process -Id ([int]$held.pid) -ErrorAction SilentlyContinue) }
        if (-not $alive) {
          Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
          continue
        }
      } catch {
        # Unstamped or mid-write: fall back to age, generously.
        try {
          $age = ((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $lock -Force).LastWriteTimeUtc).TotalMilliseconds
          if ($age -gt $script:LockStaleMs) {
            Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
            continue
          }
        } catch {}
      }
      if (((Get-Date) - $started).TotalMilliseconds -gt $timeoutMs) {
        # Writing unlocked here would cancel the guarantee at the exact moment it
        # matters. Refuse instead: nothing written, nothing lost, and the caller
        # aborts rather than racing the other writer.
        Write-TrayLog 'lock_timeout: refusing to write'
        $script:LockHandle = $null
        return $false
      }
      Start-Sleep -Milliseconds 15
    }
  }
}

function Exit-StoreLock {
  # ONLY remove the lock file if this process is the one holding it. Deleting it
  # unconditionally after a failed acquire would free somebody else's live lock
  # and hand two writers the same list.
  if (-not $script:LockHandle) { return }
  try { $script:LockHandle.Dispose() } catch {}
  $script:LockHandle = $null
  try { Remove-Item -LiteralPath ($script:StorePath + '.lock') -Force -ErrorAction SilentlyContinue } catch {}
}

function Read-Store {
  # A missing, empty, or half-written file is an empty list -- never a crash and
  # never a dialog. The next good write repairs it.
  $today = Get-Date -Format 'yyyy-MM-dd'
  $items = New-Object System.Collections.ArrayList
  # "Not there yet" and "there but unreadable" are different. A first run may
  # start empty; a torn file must never be shown as an empty list and then
  # written over. Mirrors ListUnreadableError in lib/store.mjs.
  $script:ListUnreadable = $false
  try {
    if (Test-Path -LiteralPath $script:StorePath) {
      $raw = [System.IO.File]::ReadAllText($script:StorePath)
      if ($raw -and $raw.Trim()) {
        $j = $null
        try {
          $j = $raw | ConvertFrom-Json
        } catch {
          $script:ListUnreadable = $true
          Write-TrayLog ('read_corrupt: ' + $_.Exception.Message)
          return @{ date = $today; items = @() }
        }
        if ($null -eq $j -or $null -eq $j.items) {
          $script:ListUnreadable = $true
          Write-TrayLog 'read_corrupt: not a Riah To-Do list'
          return @{ date = $today; items = @() }
        }
        foreach ($it in @($j.items)) {
          if ($null -eq $it) { continue }
          $label = ''
          try { $label = ([string]$it.label).Trim() } catch {}
          if (-not $label) { continue }
          if ($label.Length -gt $script:MaxLabel) { $label = $label.Substring(0, $script:MaxLabel) }
          $id = ''
          try { $id = [string]$it.id } catch {}
          if (-not $id) { $id = New-Id }
          $done = $false
          try { $done = [bool]$it.completed } catch {}
          $at = $null
          try { if ($it.completedAt) { $at = [string]$it.completedAt } } catch {}
          $parent = $null
          try { if ($it.parentId) { $parent = [string]$it.parentId } } catch {}
          # Read the section back too. Leaving it out here meant a task parked
          # for later silently became "today" on the very next read.
          $sec = 'today'
          try { if ($it.section -and @('today','tomorrow','future') -contains [string]$it.section) { $sec = [string]$it.section } } catch {}
          [void]$items.Add(@{ id = $id; label = $label; completed = $done; completedAt = $at; parentId = $parent; section = $sec })
        }
        # A read that returns FEWER tasks than the file holds is the dangerous
        # one: the note shows a short list, the next tick writes it back, and the
        # rest are gone for real. The empty-write guard never saw this because
        # three of twelve is not empty. Treat any shortfall as unreadable, which
        # blocks every write until a clean read replaces it.
        # (Captain, 2026-07-29 23:15: twelve tasks on disk, three on the note.)
        $rawCount = @($j.items).Count
        if ($items.Count -lt $rawCount) {
          $script:ListUnreadable = $true
          Write-TrayLog ('read_partial: parsed ' + $items.Count + ' of ' + $rawCount +
            ' tasks - writes blocked until a clean read')
        }
      }
    }
  } catch {
    Write-TrayLog ('read_fail ' + $_.Exception.Message)
  }
  $threaded = @(Invoke-Thread @($items.ToArray()))
  if ($threaded.Count -lt $items.Count) {
    $script:ListUnreadable = $true
    Write-TrayLog ('thread_lost: ' + $items.Count + ' tasks in, ' + $threaded.Count +
      ' out - writes blocked until a clean read')
  }
  # A file that plainly contains work but parsed to nothing is the shape of the
  # 2026-07-29 00:21 incident: three open priorities on disk, "items=0" in the
  # log, no exception. Never accept that quietly -- say so, and try once more.
  if ($threaded.Count -eq 0 -and $raw -and $raw -match '"label"') {
    Write-TrayLog 'read_suspect: file contains labels but nothing parsed - retrying'
    Start-Sleep -Milliseconds 150
    try {
      $retry = [System.IO.File]::ReadAllText($script:StorePath)
      $again = New-Object System.Collections.ArrayList
      foreach ($it in @(($retry | ConvertFrom-Json).items)) {
        if ($null -eq $it) { continue }
        $label = ''
        try { $label = ([string]$it.label).Trim() } catch {}
        if (-not $label) { continue }
        [void]$again.Add(@{
          id = $(if ($it.id) { [string]$it.id } else { New-Id })
          label = $label
          completed = [bool]$it.completed
          completedAt = $(if ($it.completedAt) { [string]$it.completedAt } else { $null })
          parentId = $(if ($it.parentId) { [string]$it.parentId } else { $null })
          section = $(if ($it.section -and @('today','tomorrow','future') -contains [string]$it.section) { [string]$it.section } else { 'today' })
        })
      }
      $threaded = @(Invoke-Thread @($again.ToArray()))
      Write-TrayLog ('read_retry recovered=' + $threaded.Count)
    } catch {
      Write-TrayLog ('read_retry_fail ' + $_.Exception.Message)
    }
  }
  # Yesterday's unfinished work is still today's work: carry it and restamp.
  return @{ date = $today; items = $threaded }
}

function Invoke-Thread($items) {
  # Mirror of lib/store.mjs: a depth-first walk, so each item sits directly under
  # its parent with its whole thread beneath it and carries a derived depth.
  # Orphans and loops are promoted rather than dropped; the cap counts TASKS,
  # not rows.
  #
  # It builds fresh rows rather than editing what it was handed, so it works on
  # anything list-shaped -- including the PSCustomObjects ConvertFrom-Json hands
  # back, which reject a property that was not in the JSON.
  $rows = New-Object System.Collections.ArrayList
  foreach ($i in @($items)) {
    if ($null -eq $i) { continue }
    $parent = $null
    try { if ($i.parentId) { $parent = [string]$i.parentId } } catch {}
    [void]$rows.Add(@{
      id = [string]$i.id
      label = [string]$i.label
      completed = [bool]$i.completed
      completedAt = $i.completedAt
      parentId = $parent
      section = $(if ($i.section -and @('today','tomorrow','future') -contains [string]$i.section) { [string]$i.section } else { 'today' })
      depth = 0
    })
  }
  $byId = @{}
  foreach ($i in $rows) { $byId[[string]$i.id] = $i }
  $roots = New-Object System.Collections.ArrayList
  $kids = @{}
  foreach ($i in $rows) {
    # Following parentId upward must terminate; a loop is cut at the top.
    $loop = $false
    $seen = @{}
    $seen[[string]$i.id] = $true
    $cursor = $null
    if ($i.parentId) { $cursor = $byId[[string]$i.parentId] }
    while ($null -ne $cursor) {
      if ($seen.ContainsKey([string]$cursor.id)) { $loop = $true; break }
      $seen[[string]$cursor.id] = $true
      if ($cursor.parentId) { $cursor = $byId[[string]$cursor.parentId] } else { $cursor = $null }
    }
    $p = $null
    if ($i.parentId) { $p = $byId[[string]$i.parentId] }
    if ($null -eq $p -or $p.id -eq $i.id -or $loop) {
      $i.parentId = $null
      [void]$roots.Add($i)
      continue
    }
    $key = [string]$p.id
    if (-not $kids.ContainsKey($key)) { $kids[$key] = New-Object System.Collections.ArrayList }
    [void]$kids[$key].Add($i)
  }

  $out = New-Object System.Collections.ArrayList
  # An explicit stack rather than recursion: PowerShell functions cannot see
  # their own name reliably inside a scriptblock, and this keeps it obvious.
  # Today first, then tomorrow, then later; order within a group is kept.
  $ordered = New-Object System.Collections.ArrayList
  foreach ($sec in @('today','tomorrow','future')) {
    foreach ($r in $roots) { if ([string]$r.section -eq $sec) { [void]$ordered.Add($r) } }
  }
  $n = 0
  foreach ($r in $ordered) {
    if ($n -ge $script:MaxItems) { break }
    $n++
    $stack = New-Object System.Collections.Stack
    $stack.Push(@{ item = $r; depth = 0 })
    while ($stack.Count -gt 0) {
      $frame = $stack.Pop()
      $node = $frame.item
      $node.depth = $frame.depth
      # A thread belongs to one section -- the task's.
      $node.section = [string]$r.section
      [void]$out.Add($node)
      $key = [string]$node.id
      if (-not $kids.ContainsKey($key)) { continue }
      $childDepth = $frame.depth + 1
      $flatten = ($frame.depth -ge $script:MaxDepth)
      if ($flatten) { $childDepth = $frame.depth }
      # Pushed in reverse so they come off the stack in their written order.
      $list = @($kids[$key])
      if (-not $flatten -and $list.Count -gt $script:MaxSubtasks) {
        $list = $list[0..($script:MaxSubtasks - 1)]
      }
      for ($k = $list.Count - 1; $k -ge 0; $k--) {
        if ($flatten) { $list[$k].parentId = $node.parentId }
        $stack.Push(@{ item = $list[$k]; depth = $childDepth })
      }
    }
  }
  # NOT ", @(...)": every caller wraps this in @(), and the unary comma would
  # hand them a single element that happens to be the whole list.
  return $out.ToArray()
}

function Get-Descendants([string]$id) {
  # Everything beneath an item, however deep.
  $out = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack
  $stack.Push($id)
  while ($stack.Count -gt 0) {
    $current = $stack.Pop()
    foreach ($i in @($script:List.items)) {
      if ($i.parentId -eq $current) {
        [void]$out.Add($i)
        $stack.Push($i.id)
      }
    }
  }
  return $out.ToArray()
}

function Get-Ancestors($item) {
  $out = New-Object System.Collections.ArrayList
  $byId = @{}
  foreach ($i in @($script:List.items)) { $byId[[string]$i.id] = $i }
  $cursor = $null
  if ($item.parentId) { $cursor = $byId[[string]$item.parentId] }
  while ($null -ne $cursor -and -not ($out -contains $cursor)) {
    [void]$out.Add($cursor)
    if ($cursor.parentId) { $cursor = $byId[[string]$cursor.parentId] } else { $cursor = $null }
  }
  return $out.ToArray()
}

function Get-Children([string]$id) {
  $out = New-Object System.Collections.ArrayList
  foreach ($i in @($script:List.items)) { if ($i.parentId -eq $id) { [void]$out.Add($i) } }
  return $out.ToArray()
}

function Get-TopLevel {
  $out = New-Object System.Collections.ArrayList
  foreach ($i in @($script:List.items)) { if (-not $i.parentId) { [void]$out.Add($i) } }
  return $out.ToArray()
}

function Write-Store($list) {
  try {
    # A list we could not read is a list we must not replace.
    if ($script:ListUnreadable) {
      Write-TrayLog 'write_blocked: the list file is unreadable - leaving it untouched'
      return $false
    }
    # THE GUARD. Losing a day's priorities is the one unacceptable failure here,
    # and the only way it can happen is a bad read turning into a good write. So:
    # never let an empty in-memory list flatten a file that still has work in it.
    # Deliberate emptying (removing the last item, clearing finished) sets
    # $script:AllowEmptyWrite for exactly one write.
    if (@($list.items).Count -eq 0 -and -not $script:AllowEmptyWrite) {
      if (Test-Path -LiteralPath $script:StorePath) {
        $onDisk = ''
        try { $onDisk = [System.IO.File]::ReadAllText($script:StorePath) } catch {}
        if ($onDisk -and $onDisk -match '"label"') {
          Write-TrayLog 'write_blocked: refusing to overwrite a non-empty list with an empty one'
          return $false
        }
      }
    }
    $script:AllowEmptyWrite = $false
    $dir = Split-Path -Parent $script:StorePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $rows = @()
    foreach ($i in @($list.items)) {
      $rows += [ordered]@{
        id = [string]$i.id
        label = [string]$i.label
        completed = [bool]$i.completed
        completedAt = $i.completedAt
        parentId = $i.parentId
        section = $i.section
      }
    }
    $obj = [ordered]@{ date = [string]$list.date; items = @($rows) }
    $json = ($obj | ConvertTo-Json -Depth 5)
    # Rolling backup of the last good list - so a flat rewrite after reboot
    # (or any other bad write) can be undone without digging through Temp.
    if (Test-Path -LiteralPath $script:StorePath) {
      try {
        [System.IO.File]::Copy($script:StorePath, ($script:StorePath + '.prev'), $true)
      } catch {
        Write-TrayLog ('backup_prev_fail ' + $_.Exception.Message)
      }
    }
    $tmp = $script:StorePath + '.' + $PID + '.tmp'
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $json, $enc)
    # Replace is the atomic step -- a reader sees the whole old file or the whole
    # new one, never a torn list. The backup argument MUST be [NullString]::Value:
    # a plain $null arrives as "" and Replace rejects it as an illegal path.
    if (Test-Path -LiteralPath $script:StorePath) {
      try {
        [System.IO.File]::Replace($tmp, $script:StorePath, [NullString]::Value)
      } catch {
        # Some volumes refuse Replace. A delete-then-move is a hair less atomic
        # but still leaves a whole file, and readers treat a missing one as empty.
        Write-TrayLog ('replace_fell_back ' + $_.Exception.Message)
        Remove-Item -LiteralPath $script:StorePath -Force
        [System.IO.File]::Move($tmp, $script:StorePath)
      }
    } else {
      [System.IO.File]::Move($tmp, $script:StorePath)
    }
    $script:LastStamp = (Get-Item -LiteralPath $script:StorePath).LastWriteTimeUtc
    return $true
  } catch {
    Write-TrayLog ('write_fail ' + $_.Exception.Message)
    return $false
  }
}

function Read-Settings {
  # Missing or unreadable settings mean the defaults, never a stall.
  try {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return }
    $raw = [System.IO.File]::ReadAllText($script:SettingsPath)
    if (-not $raw -or -not $raw.Trim()) { return }
    $j = $raw | ConvertFrom-Json
    if ($null -eq $j) { return }
    if ($null -eq $j.fileAfterMinutes -or "$($j.fileAfterMinutes)" -eq 'never') {
      $script:FileAfterMinutes = $null
    } else {
      try { $script:FileAfterMinutes = [Math]::Max(0, [int]$j.fileAfterMinutes) } catch {}
    }
    if ($null -ne $j.vaultPath) { $script:VaultPath = ([string]$j.vaultPath).Trim() }
    if ($null -ne $j.vaultSubfolder) { $script:VaultSubfolder = ([string]$j.vaultSubfolder).Trim() }
  } catch {
    Write-TrayLog ('settings_read_fail ' + $_.Exception.Message)
  }
}

function Add-VaultTrail($removed) {
  # One markdown file per day in the configured vault, appended to, so a second
  # brain ends up holding what actually got done. Off unless a path is set.
  if (-not $script:VaultPath) { return }
  if (-not $removed -or @($removed).Count -eq 0) { return }
  try {
    $folder = $script:VaultPath
    if ($script:VaultSubfolder) { $folder = Join-Path $folder $script:VaultSubfolder }
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $day = Get-Date -Format 'yyyy-MM-dd'
    $file = Join-Path $folder ($day + '.md')
    if (-not (Test-Path -LiteralPath $file)) {
      [System.IO.File]::WriteAllText($file, ("# Done - " + $day + "`r`n`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    $ids = @{}
    foreach ($r in @($removed)) { $ids[[string]$r.id] = $true }
    $lines = ''
    foreach ($r in @($removed)) {
      $stamp = ''
      if ($r.completedAt) {
        try { $stamp = ([datetime]$r.completedAt).ToLocalTime().ToString('HH:mm') + ' ' } catch {}
      }
      $indent = ''
      if ($r.parentId -and $ids.ContainsKey([string]$r.parentId)) { $indent = '  ' }
      $lines += ($indent + '- [x] ' + $stamp + [string]$r.label + "`r`n")
    }
    # Append, never rewrite: the file may be open in Obsidian right now.
    [System.IO.File]::AppendAllText($file, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Write-TrayLog ('vault_trail ' + $file + ' +' + @($removed).Count)
  } catch {
    # A vault that moved or is offline must never cost Captain a tick.
    Write-TrayLog ('vault_trail_fail ' + $_.Exception.Message)
  }
}

function Add-Filed($removed) {
  if (-not $removed -or @($removed).Count -eq 0) { return }
  Add-VaultTrail $removed
  try {
    $existing = @()
    if (Test-Path -LiteralPath $script:FiledPath) {
      $raw = [System.IO.File]::ReadAllText($script:FiledPath)
      if ($raw -and $raw.Trim()) { $existing = @(($raw | ConvertFrom-Json)) }
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $out = New-Object System.Collections.ArrayList
    foreach ($e in $existing) { if ($null -ne $e) { [void]$out.Add($e) } }
    foreach ($r in @($removed)) {
      [void]$out.Add([ordered]@{
        id = [string]$r.id; label = [string]$r.label
        completed = $true; completedAt = $r.completedAt
        parentId = $r.parentId; filedAt = $stamp
      })
    }
    # -InputObject, NOT the pipeline. Piping an array into ConvertTo-Json in
    # PowerShell 5.1 serialises the COLLECTION -- {"value":[...],"Count":n} --
    # and everything else here expects a plain JSON array, so the archive would
    # be silently thrown away on the next read.
    $json = ConvertTo-Json -InputObject @($out.ToArray()) -Depth 5
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($script:FiledPath, $json, $enc)
  } catch {
    Write-TrayLog ('file_archive_fail ' + $_.Exception.Message)
  }
}

function Invoke-Sweep($list) {
  # Ticked items file themselves after the configured window, so the note shows
  # what is LEFT instead of becoming a monument to what is done. Null = never.
  if ($null -eq $script:FileAfterMinutes) { return $false }
  $keep = New-Object System.Collections.ArrayList
  $gone = New-Object System.Collections.ArrayList
  $filed = @{}
  $cut = (Get-Date).ToUniversalTime().AddMinutes(-1 * $script:FileAfterMinutes)
  foreach ($i in @($list.items)) {
    # Anything under something already filed goes with it, at any depth. The
    # list is in depth-first order, so a parent is always decided first.
    if ($i.parentId -and $filed.ContainsKey([string]$i.parentId)) {
      [void]$gone.Add($i)
      $filed[[string]$i.id] = $true
      continue
    }
    if (-not $i.completed) { [void]$keep.Add($i); continue }
    $when = $null
    if ($i.completedAt) { try { $when = ([datetime]$i.completedAt).ToUniversalTime() } catch {} }
    # No stamp means it predates the stamp, so it is already past the window.
    if ($null -eq $when -or $when -le $cut) {
      # Never file a task out from under a step that is still open.
      $openChild = $false
      foreach ($kid in @($list.items)) {
        if ($kid.parentId -eq $i.id -and -not $kid.completed) { $openChild = $true; break }
      }
      if ($openChild) { [void]$keep.Add($i); continue }
      [void]$gone.Add($i)
      $filed[[string]$i.id] = $true
    } else {
      [void]$keep.Add($i)
    }
  }
  if ($gone.Count -eq 0) { return $false }
  # Filing everything is a real, deliberate empty list -- the work is archived,
  # not lost.
  if ($keep.Count -eq 0) { $script:AllowEmptyWrite = $true }
  $list.items = @($keep.ToArray())
  Add-Filed @($gone.ToArray())
  return $true
}

function Sync-List([bool]$force = $false) {
  # Settings are cheap to re-read and can be changed on the board while the note
  # is open, so pick them up on every pass.
  Read-Settings
  # Cheap: only re-read when the file actually changed under us.
  try {
    $stamp = $null
    if (Test-Path -LiteralPath $script:StorePath) {
      $stamp = (Get-Item -LiteralPath $script:StorePath).LastWriteTimeUtc
    }
    if (-not $force -and $null -ne $stamp -and $null -ne $script:LastStamp -and $stamp -eq $script:LastStamp) {
      return $false
    }
    $script:LastStamp = $stamp
  } catch {}
  $list = Read-Store
  if (Invoke-Sweep $list) { [void](Write-Store $list) }
  $script:List = $list
  return $true
}

# Duplicate labels are ALLOWED. The same job under two different tasks is two
# different jobs. (Captain, 2026-07-29: "post on socials" under Gumroad Shovels
# AND under Riah To-Do -- refusing that was obnoxious.)

function Set-Flash([string]$msg) {
  $script:Flash = $msg
  $script:FlashUntil = (Get-Date).AddSeconds(4)
}

function Add-PriorityUnlocked([string]$label, [string]$parentId = $null) {
  $value = ([string]$label).Trim()
  if (-not $value) { return }
  if ($value.Length -gt $script:MaxLabel) { $value = $value.Substring(0, $script:MaxLabel) }
  [void](Sync-List $true)
  if ($parentId) {
    $parent = $null
    foreach ($i in @($script:List.items)) { if ($i.id -eq $parentId) { $parent = $i; break } }
    if ($null -eq $parent) { return }
    $parentDepth = 0
    if ($null -ne $parent.depth) { $parentDepth = [int]$parent.depth }
    if ($parentDepth -ge $script:MaxDepth) {
      Set-Flash ('That thread is as deep as it goes (' + ($script:MaxDepth + 1) + ' levels).')
      Refresh-Note
      return
    }
    if (@(Get-Children $parentId).Count -ge $script:MaxSubtasks) {
      Set-Flash ('That task is full at ' + $script:MaxSubtasks + ' subtasks.')
      Refresh-Note
      return
    }
  } elseif (@(Get-TopLevel).Count -ge $script:MaxItems) {
    Set-Flash ('Today is full at ' + $script:MaxItems + '.')
    Refresh-Note
    return
  }
  $items = New-Object System.Collections.ArrayList
  foreach ($i in @($script:List.items)) { [void]$items.Add($i) }
  [void]$items.Add(@{ id = New-Id; label = $value; completed = $false; completedAt = $null; parentId = $parentId; section = 'today'; depth = 0 })
  $script:List.items = @(Invoke-Thread @($items.ToArray()))
  [void](Write-Store $script:List)
  Refresh-Note
}

function Rename-PriorityUnlocked([string]$id, [string]$label) {
  $value = ([string]$label).Trim()
  if (-not $value) { return }
  if ($value.Length -gt $script:MaxLabel) { $value = $value.Substring(0, $script:MaxLabel) }
  [void](Sync-List $true)
  foreach ($i in @($script:List.items)) { if ($i.id -eq $id) { $i.label = $value } }
  [void](Write-Store $script:List)
  Refresh-Note
}

function Toggle-PriorityUnlocked([string]$id) {
  # Ticking a task ticks its whole thread; ticking the last open step finishes
  # the task; reopening any step reopens it. Mirrors setDone() in lib/store.mjs.
  [void](Sync-List $true)
  $item = $null
  foreach ($i in @($script:List.items)) { if ($i.id -eq $id) { $item = $i; break } }
  if ($null -eq $item) { return }
  $done = -not $item.completed
  $stamp = $null
  if ($done) { $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
  $item.completed = $done
  $item.completedAt = $stamp
  # Down: the whole thread beneath it, however deep.
  foreach ($kid in @(Get-Descendants $item.id)) {
    $kid.completed = $done
    $kid.completedAt = $stamp
  }
  # Up: each ancestor is done only while every one of ITS children is, and
  # reopening anything reopens the line above it all the way to the top.
  foreach ($parent in @(Get-Ancestors $item)) {
    $allDone = $true
    foreach ($kid in @(Get-Children $parent.id)) { if (-not $kid.completed) { $allDone = $false; break } }
    $parent.completed = $allDone
    if ($allDone) {
      if (-not $parent.completedAt) {
        $parent.completedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
      }
    } else {
      $parent.completedAt = $null
    }
  }
  [void](Write-Store $script:List)
  Refresh-Note
}

function Move-BeforeUnlocked([string]$id, [string]$beforeId) {
  # Drag a task above another one. Its subtasks travel with it.
  [void](Sync-List $true)
  $item = $null
  foreach ($i in @($script:List.items)) { if ($i.id -eq $id) { $item = $i; break } }
  if ($null -eq $item -or $id -eq $beforeId) { return }
  $moving = New-Object System.Collections.ArrayList
  [void]$moving.Add($item)
  # The whole thread travels, however deep.
  foreach ($kid in @(Get-Descendants $item.id)) { [void]$moving.Add($kid) }
  $movingIds = @{}
  foreach ($m in $moving) { $movingIds[[string]$m.id] = $true }
  # A task cannot be dropped inside its own thread.
  if ($beforeId -and $movingIds.ContainsKey([string]$beforeId)) { return }
  $rest = New-Object System.Collections.ArrayList
  foreach ($i in @($script:List.items)) { if (-not $movingIds.ContainsKey([string]$i.id)) { [void]$rest.Add($i) } }
  $at = -1
  for ($k = 0; $k -lt $rest.Count; $k++) { if ($rest[$k].id -eq $beforeId) { $at = $k; break } }
  if ($at -lt 0) { foreach ($m in $moving) { [void]$rest.Add($m) } }
  else { $rest.InsertRange($at, $moving) }
  $script:List.items = @(Invoke-Thread @($rest.ToArray()))
  [void](Write-Store $script:List)
  Refresh-Note
}

function Set-SectionUnlocked([string]$id, [string]$section) {
  [void](Sync-List $true)
  $item = $null
  foreach ($i in @($script:List.items)) { if ($i.id -eq $id) { $item = $i; break } }
  if ($null -eq $item) { return }
  # Always section the TASK, never a step -- a thread stays whole.
  $root = $item
  $guard = 0
  while ($root.parentId -and $guard -lt 50) {
    $guard++
    $next = $null
    foreach ($p in @($script:List.items)) { if ($p.id -eq $root.parentId) { $next = $p; break } }
    if ($null -eq $next) { break }
    $root = $next
  }
  $root.section = $section
  foreach ($kid in @(Get-Descendants $root.id)) { $kid.section = $section }
  $script:List.items = @(Invoke-Thread @($script:List.items))
  [void](Write-Store $script:List)
  Refresh-Note
}

function Set-ParentUnlocked([string]$id, [string]$parentId) {
  [void](Sync-List $true)
  $item = $null
  foreach ($i in @($script:List.items)) { if ($i.id -eq $id) { $item = $i; break } }
  if ($null -eq $item) { return }
  if ($parentId) {
    if ($parentId -eq $id) { return }
    # Dropping something into its own thread would orphan the lot.
    foreach ($kid in @(Get-Descendants $id)) {
      if ($kid.id -eq $parentId) { Set-Flash 'A task cannot go inside its own thread.'; Refresh-Note; return }
    }
    $parent = $null
    foreach ($p in @($script:List.items)) { if ($p.id -eq $parentId) { $parent = $p; break } }
    if ($null -eq $parent) { return }
    $parentDepth = 0
    if ($null -ne $parent.depth) { $parentDepth = [int]$parent.depth }
    $ownDepth = 0
    $mine = 0
    if ($null -ne $item.depth) { $mine = [int]$item.depth }
    foreach ($kid in @(Get-Descendants $id)) {
      $kd = 0
      if ($null -ne $kid.depth) { $kd = [int]$kid.depth }
      if (($kd - $mine) -gt $ownDepth) { $ownDepth = $kd - $mine }
    }
    if (($parentDepth + 1 + $ownDepth) -gt $script:MaxDepth) {
      Set-Flash ('That would nest deeper than ' + ($script:MaxDepth + 1) + ' levels.')
      Refresh-Note
      return
    }
    if (@(Get-Children $parentId).Count -ge $script:MaxSubtasks) {
      Set-Flash ('That task is full at ' + $script:MaxSubtasks + ' subtasks.')
      Refresh-Note
      return
    }
  } elseif (@(Get-TopLevel).Count -ge $script:MaxItems) {
    Set-Flash ('Today is full at ' + $script:MaxItems + '.')
    Refresh-Note
    return
  }
  $item.parentId = $parentId
  $script:List.items = @(Invoke-Thread @($script:List.items))
  [void](Write-Store $script:List)
  Refresh-Note
}

function Remove-PriorityUnlocked([string]$id) {
  [void](Sync-List $true)
  # Removing the last item is a real, deliberate empty list.
  $script:AllowEmptyWrite = $true
  $keep = New-Object System.Collections.ArrayList
  # A task takes its WHOLE thread with it, however deep -- leaving descendants
  # behind would silently promote work Captain thought he had just deleted.
  $doomed = @{}
  $doomed[[string]$id] = $true
  foreach ($kid in @(Get-Descendants $id)) { $doomed[[string]$kid.id] = $true }
  foreach ($i in @($script:List.items)) {
    if (-not $doomed.ContainsKey([string]$i.id)) { [void]$keep.Add($i) }
  }
  $script:List.items = @($keep.ToArray())
  [void](Write-Store $script:List)
  Refresh-Note
}

# Every change is read-modify-write, so each one holds the lock across BOTH
# halves. The bodies above are deliberately lock-free: one place takes the lock,
# one place releases it, and an early return still releases because of finally.
#
# If the lock cannot be had, the change does NOT happen. Saying so is better than
# racing another window and losing whichever edit finishes second.
function Invoke-Locked([scriptblock]$work) {
  if (-not (Enter-StoreLock)) {
    Set-Flash 'Another window is mid-change. Nothing altered - try again.'
    Refresh-Note
    return
  }
  try { & $work } finally { Exit-StoreLock }
}

function Add-Priority([string]$label, [string]$parentId = $null) {
  Invoke-Locked { Add-PriorityUnlocked $label $parentId }
}
function Rename-Priority([string]$id, [string]$label) {
  Invoke-Locked { Rename-PriorityUnlocked $id $label }
}
function Toggle-Priority([string]$id) {
  Invoke-Locked { Toggle-PriorityUnlocked $id }
}
function Move-Before([string]$id, [string]$beforeId) {
  Invoke-Locked { Move-BeforeUnlocked $id $beforeId }
}
function Set-Parent([string]$id, [string]$parentId) {
  Invoke-Locked { Set-ParentUnlocked $id $parentId }
}
function Set-Section([string]$id, [string]$section) {
  Invoke-Locked { Set-SectionUnlocked $id $section }
}
function Remove-Priority([string]$id) {
  Invoke-Locked { Remove-PriorityUnlocked $id }
}

# --- look: the Riah interface signature, drawn ---
#
# HAZARD: PowerShell variable names are case-insensitive AND functions can see
# their caller's locals. A `foreach ($c in ...)` anywhere therefore hides this
# colour table from every function that call goes on to make -- the drawing then
# fails with "cannot find an appropriate constructor for SolidBrush". Same trap
# for $F below. Never use $c or $f as a loop variable in this file.
$C = @{
  Bg     = [System.Drawing.Color]::FromArgb(15, 15, 17)
  Raised = [System.Drawing.Color]::FromArgb(24, 24, 28)
  Row    = [System.Drawing.Color]::FromArgb(20, 20, 23)
  Border = [System.Drawing.Color]::FromArgb(50, 50, 54)
  Hard   = [System.Drawing.Color]::FromArgb(237, 237, 239)
  Text   = [System.Drawing.Color]::FromArgb(237, 237, 239)
  Dim    = [System.Drawing.Color]::FromArgb(154, 154, 162)
  Faint  = [System.Drawing.Color]::FromArgb(119, 119, 127)
  Keep   = [System.Drawing.Color]::FromArgb(63, 207, 127)
  Hot    = [System.Drawing.Color]::FromArgb(242, 109, 91)
  Brand  = [System.Drawing.Color]::FromArgb(255, 92, 168)
}
$F = @{
  Brand = New-Object System.Drawing.Font('Georgia', 14, ([System.Drawing.FontStyle]::Italic))
  Product = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Regular)
  Row   = New-Object System.Drawing.Font('Segoe UI', 10.5)
  RowDone = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Strikeout)
  Meta  = New-Object System.Drawing.Font('Consolas', 8)
  Count = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
  Kill  = New-Object System.Drawing.Font('Segoe UI', 11)
}

# Bigger and longer than the meters box: this one is read and clicked, not
# glanced at. (Captain, 2026-07-28.)
$DEF_W = 380
$MIN_W = 260
$MAX_W = 900
$PAD = 16
$HEAD_H = 34
# 38 let the big count's descender touch the TODAY heading underneath it.
$TALLY_H = 46
$ROW_MIN_H = 40
$ROW_GAP_Y = 4
$CHECK = 20
$CHECK_GAP = 13
$KILL_W = 26
$ADD_H = 38
$FOOT_H = 4
# How far a subtask is stepped in, and how wide the "+" that starts one is.
$THREAD_INDENT = 24
# Room above the first task of a group for its heading.
$SECTION_H = 26
$PLUS_W = 22
# Drag a row this far before it counts as reordering rather than a click.
$ROW_DRAG_SLOP = 5
# How far in from the top-right corner the note sits the FIRST time, before it
# has been dragged anywhere.
$EDGE_GAP = 14
# A click on the icon that merely closed the note must not reopen it.
$REOPEN_GUARD_MS = 450
# How close to an edge counts as "grab to resize".
$GRIP = 6
$CORNER = 14

$script:Rows = @()
# Scrolling. The note grows as the list grows, but a long list eventually meets
# the edge of the screen -- and a note you cannot shrink is worse than a short
# one. Past that point the rows scroll inside whatever height Captain chose.
$script:ScrollY = 0
$script:ContentBottom = 0
$script:ViewTop = 0
$script:ViewBottom = 0
$script:BarRect = $null
$script:BarThumb = $null
$script:BarDragOffset = 0
$script:BarDragging = $false
$script:HoverId = $null
$script:HoverKill = $false
$script:HoverCheck = $false
$script:EditId = $null
$script:Flash = ''
$script:FlashUntil = $script:LongAgo
$script:PopupOpen = $false
$script:ShownAt = $script:LongAgo
$script:HoverClose = $false
$script:HoverBack = $false
$script:BackRect = $null
$script:HiddenAt = $script:LongAgo
$script:IconHandle = [IntPtr]::Zero
$script:LastPlace = ''
# Geometry Captain chose by dragging. Null means "not placed yet".
$script:WinW = $DEF_W
$script:UserPos = $null
$script:UserMinH = 0
$script:UserHSet = $false
$script:Dragging = $false
$script:Resizing = $false
$script:ResizeEdge = ''
$script:DragStart = $null
$script:DragOrigin = $null
$script:Moved = $false
# Dragging a row to reorder it.
$script:RowDragId = $null
$script:RowDragArmed = $false
$script:RowDragFrom = $null
$script:DropBeforeId = $null
$script:DropAtEnd = $false
$script:DropAfterId = $null
$script:RowDragY = 0
$script:HoverPlus = $false

function Get-Indent([int]$depth) {
  # The first step in is full width; deeper ones narrow, so a six-level thread
  # still leaves the words room on a small note. Captain can widen it anyway.
  if ($depth -le 0) { return 0 }
  $indent = $THREAD_INDENT
  for ($d = 2; $d -le $depth; $d++) {
    $step = $THREAD_INDENT - (($d - 1) * 4)
    if ($step -lt 10) { $step = 10 }
    $indent += $step
  }
  return $indent
}

function Get-TextWidth([int]$depth = 0) {
  $w = $script:WinW - (2 * $PAD) - $CHECK - $CHECK_GAP - $KILL_W - $PLUS_W
  return ($w - (Get-Indent $depth))
}

function Get-RowLeft($row) {
  $depth = 0
  if ($null -ne $row.depth) { $depth = [int]$row.depth }
  return ($PAD + (Get-Indent $depth))
}

function Get-HeadHeight($g) {
  # Measured once, then shared by the painter, the row layout, and the drag zone
  # so they cannot drift apart on a different DPI or a missing font.
  if ($script:HeadH) { return $script:HeadH }
  $h = $HEAD_H
  try {
    $a = $g.MeasureString('Riah', $F.Brand).Height
    $b = $g.MeasureString('To-Do', $F.Product).Height
    $h = [int][Math]::Ceiling([Math]::Max($a, $b)) + 6
  } catch {}
  $script:HeadH = $h
  return $h
}

function Test-HasOtherSections {
  foreach ($i in @($script:List.items)) {
    if (-not $i.parentId -and [string]$i.section -ne 'today') { return $true }
  }
  return $false
}

function Measure-Rows($g) {
  $script:HasOtherSections = Test-HasOtherSections
  # Rows wrap to the note's width, so a real sentence stays readable instead of
  # being cut off with dots. Heights are measured once and reused for hit-testing.
  $rows = New-Object System.Collections.ArrayList
  $top = $PAD + (Get-HeadHeight $g) + $TALLY_H
  # The strip the rows live in: below the tally, above the add box.
  $script:ViewTop = $top
  $script:ViewBottom = $popup.ClientSize.Height - $PAD - $FOOT_H - 6 - $ADD_H - 4
  if ($script:ViewBottom -lt ($top + 20)) { $script:ViewBottom = $top + 20 }
  # Clamp against the previous frame's measurements. One frame of lag is
  # invisible and it saves laying every row out twice.
  $maxScroll = $script:ContentBottom - $script:ViewBottom
  if ($maxScroll -lt 0) { $maxScroll = 0 }
  if ($script:ScrollY -gt $maxScroll) { $script:ScrollY = $maxScroll }
  if ($script:ScrollY -lt 0) { $script:ScrollY = 0 }
  $y = $top
  $seenSection = @{}
  foreach ($i in @($script:List.items)) {
    $depth = 0
    if ($null -ne $i.depth) { $depth = [int]$i.depth }
    # A header appears once, above the first task of its group. "Today" is not
    # drawn when nothing else exists -- an unheaded list is the common case.
    $header = $null
    if ($depth -eq 0) {
      $sec = [string]$i.section
      if (-not $seenSection.ContainsKey($sec)) {
        $seenSection[$sec] = $true
        if ($sec -ne 'today' -or $script:HasOtherSections) { $header = $sec }
      }
    }
    if ($header) { $y += $SECTION_H }
    $w = Get-TextWidth $depth
    if ($w -lt 60) { $w = 60 }
    $font = if ($i.completed) { $F.RowDone } else { $F.Row }
    $h = if ($depth -gt 0) { $ROW_MIN_H - 6 } else { $ROW_MIN_H }
    try {
      $size = $g.MeasureString([string]$i.label, $font, $w)
      $needed = [int][Math]::Ceiling($size.Height) + 12
      if ($needed -gt $h) { $h = $needed }
    } catch {}
    # Rows carry their ON-SCREEN y, so drawing, hit-testing and dragging all
    # agree about where a row is without any of them knowing about scrolling.
    [void]$rows.Add(@{ id = $i.id; item = $i; y = ($y - $script:ScrollY); h = $h; depth = $depth; child = ($depth -gt 0); header = $header })
    $y += $h + $ROW_GAP_Y
  }
  $script:Rows = @($rows.ToArray())
  $script:ContentBottom = $y
  # The window is sized from the UNSCROLLED height, or scrolling down would
  # shrink the note out from under itself.
  return $y
}

function Measure-Height {
  $g = $null
  try {
    $g = $popup.CreateGraphics()
    $bottom = Measure-Rows $g
  } catch {
    $bottom = $PAD + $HEAD_H + $TALLY_H + (@($script:List.items).Count * ($ROW_MIN_H + $ROW_GAP_Y))
  } finally {
    if ($null -ne $g) { $g.Dispose() }
  }
  if (@($script:List.items).Count -eq 0) { $bottom += 34 }
  return ($bottom + 8 + $ADD_H + 6 + $FOOT_H + $PAD)
}

function Get-Remaining {
  # Only today's work counts. Parking something for later must not make the
  # number go up -- that would defeat the point of parking it.
  $n = 0
  foreach ($i in @($script:List.items)) {
    if (-not $i.completed -and [string]$i.section -eq 'today') { $n++ }
  }
  return $n
}

function Get-TodayCount {
  $n = 0
  foreach ($i in @($script:List.items)) { if ([string]$i.section -eq 'today') { $n++ } }
  return $n
}

function Update-TrayIcon {
  # The icon itself is the status: one bar per priority (up to four), green when
  # ticked. Nothing left = a single green check.
  $bmp = New-Object System.Drawing.Bitmap(32, 32)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $bg = New-Object System.Drawing.SolidBrush($C.Bg)
  $g.FillRectangle($bg, 1, 1, 30, 30)
  $pen = New-Object System.Drawing.Pen($C.Border)
  $g.DrawRectangle($pen, 1, 1, 29, 29)

  $items = @($script:List.items)
  $left = Get-Remaining
  if ($items.Count -gt 0 -and $left -eq 0) {
    $okPen = New-Object System.Drawing.Pen($C.Keep, 3.5)
    $okPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $okPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($okPen, 8, 16, 14, 22)
    $g.DrawLine($okPen, 14, 22, 24, 10)
    $okPen.Dispose()
  } else {
    $y = 7
    $n = [Math]::Min(4, [Math]::Max($items.Count, 1))
    for ($k = 0; $k -lt $n; $k++) {
      $done = $false
      if ($k -lt $items.Count) { $done = [bool]$items[$k].completed }
      $col = if ($done) { $C.Keep } elseif ($items.Count -eq 0) { $C.Border } else { $C.Brand }
      $dot = New-Object System.Drawing.SolidBrush($col)
      $g.FillRectangle($dot, 7, $y, 4, 4)
      $dot.Dispose()
      $bar = New-Object System.Drawing.SolidBrush($(if ($done) { $C.Border } else { $C.Dim }))
      $g.FillRectangle($bar, 14, ($y + 1), 11, 2)
      $bar.Dispose()
      $y += 6
    }
  }
  $pen.Dispose(); $bg.Dispose(); $g.Dispose()
  $h = $bmp.GetHicon()
  $notify.Icon = [System.Drawing.Icon]::FromHandle($h)
  if ($script:HasNative -and $script:IconHandle -ne [IntPtr]::Zero) {
    try { [RiahTodo.Native]::DestroyIcon($script:IconHandle) | Out-Null } catch {}
  }
  $script:IconHandle = $h
  $bmp.Dispose()
}

function Clear-TrayTip { try { $notify.Text = [string]::Empty } catch {} }

# --- placement (mirrors Riah Usage: the note lives on the icon's monitor) ---
function Get-ScreenForPoint([System.Drawing.Point]$pt) {
  try {
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) { if ($s.Bounds.Contains($pt)) { return $s } }
  } catch {}
  return $null
}

function Get-NotifyPrivate([string[]]$names) {
  $flags = [System.Reflection.BindingFlags]'Instance, NonPublic'
  $t = $notify.GetType()
  foreach ($n in $names) {
    $field = $t.GetField($n, $flags)
    if ($field) { return $field.GetValue($notify) }
  }
  return $null
}

function Get-IconRectRaw {
  if (-not $script:HasNative) { return $null }
  try {
    $idObj = Get-NotifyPrivate @('id', 'Id')
    $win = Get-NotifyPrivate @('window', 'Window')
    if ($null -eq $idObj -or -not $win) { return $null }
    $hwnd = $win.Handle
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $nid = New-Object 'RiahTodo.Native+NOTIFYICONIDENTIFIER'
    $nid.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($nid)
    $nid.hWnd = $hwnd
    $nid.uID = [uint32]$idObj
    $nid.guidItem = [guid]::Empty
    $rc = New-Object 'RiahTodo.Native+RECT'
    if ([RiahTodo.Native]::Shell_NotifyIconGetRect([ref]$nid, [ref]$rc) -ne 0) { return $null }
    $rw = $rc.Right - $rc.Left
    $rh = $rc.Bottom - $rc.Top
    if ($rw -lt 4 -or $rh -lt 4 -or $rw -gt 160 -or $rh -gt 160) { return $null }
    return New-Object System.Drawing.Rectangle($rc.Left, $rc.Top, $rw, $rh)
  } catch { return $null }
}

function Clamp-ToScreen($scr, [int]$x, [int]$y, [int]$w, [int]$h) {
  $wa = $scr.WorkingArea
  if ($x + $w -gt $wa.Right - 4) { $x = $wa.Right - $w - 4 }
  if ($y + $h -gt $wa.Bottom - 4) { $y = $wa.Bottom - $h - 4 }
  if ($x -lt $wa.Left + 4) { $x = $wa.Left + 4 }
  if ($y -lt $wa.Top + 4) { $y = $wa.Top + 4 }
  return ,@($x, $y)
}

function Load-Geometry {
  # Where Captain last dragged it to, and how big he made it. A half-written or
  # empty file means "not placed yet", never 0,0.
  try {
    $script:UserPos = $null
    if (-not (Test-Path $script:PosPath)) { return }
    $j = Get-Content -Path $script:PosPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $j) { return }
    if ($null -ne $j.w) {
      $w = [int]$j.w
      if ($w -ge $MIN_W -and $w -le $MAX_W) { $script:WinW = $w }
    }
    if ($null -ne $j.h) { $script:UserMinH = [Math]::Max(0, [int]$j.h) }
    # Only a deliberate drag of a top or bottom edge counts as choosing a height.
    if ($null -ne $j.hSet) { $script:UserHSet = [bool]$j.hSet }
    if ($null -eq $j.x -or $null -eq $j.y) { return }
    $script:UserPos = New-Object System.Drawing.Point([int]$j.x, [int]$j.y)
    Write-TrayLog ('geometry_loaded ' + $j.x + ',' + $j.y + ' ' + $script:WinW + 'x' + $script:UserMinH)
  } catch { $script:UserPos = $null }
}

function Save-Geometry {
  try {
    $dir = Split-Path -Parent $script:PosPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $o = @{ x = [int]$popup.Left; y = [int]$popup.Top; w = [int]$popup.Width
            h = [int]$popup.Height; hSet = [bool]$script:UserHSet }
    ($o | ConvertTo-Json -Compress) | Set-Content -Path $script:PosPath -Encoding ASCII
    $script:UserPos = New-Object System.Drawing.Point($popup.Left, $popup.Top)
    $script:WinW = $popup.Width
    $script:UserMinH = $popup.Height
  } catch {}
}

function Clear-Geometry([string]$why) {
  $script:UserPos = $null
  try { '{}' | Set-Content -Path $script:PosPath -Encoding ASCII } catch {}
  Write-TrayLog ('geometry_cleared ' + $why)
}

function Place-Popup {
  # Where Captain put it wins. Until he has put it anywhere, the top-right corner
  # of the screen holding the tray icon -- so the first open lands on the monitor
  # he just clicked on, not always the main one.
  $contentH = Measure-Height
  $icon = Get-IconRectRaw
  $scr = $null
  if ($null -ne $icon) {
    $scr = Get-ScreenForPoint (New-Object System.Drawing.Point(
      ($icon.Left + [int]($icon.Width / 2)), $icon.Top))
  }
  if ($null -eq $scr) { $scr = Get-ScreenForPoint ([System.Windows.Forms.Cursor]::Position) }
  if ($null -eq $scr) { $scr = [System.Windows.Forms.Screen]::PrimaryScreen }

  $src = 'top_right'
  if ($null -ne $script:UserPos) {
    # A saved spot on a monitor that is no longer there would put the note
    # nowhere. Check before obeying it.
    $centre = New-Object System.Drawing.Point(
      ($script:UserPos.X + [int]($script:WinW / 2)), ($script:UserPos.Y + 40))
    $savedScr = Get-ScreenForPoint $centre
    if ($null -ne $savedScr) { $scr = $savedScr; $src = 'saved' }
    else { Clear-Geometry 'saved_spot_off_screen' }
  }
  $wa = $scr.WorkingArea

  # Until Captain drags an edge, the note grows with the list -- that part he
  # likes. Once he has set a height, that IS the height and the list scrolls
  # inside it. It used to be treated as a floor, which meant a long list could
  # not be pulled back down to something small. (Captain, 2026-07-29: "I should
  # just be able to make it smaller anytime I want because I'm going to get a
  # lot of things on there.")
  if ($script:UserHSet -and $script:UserMinH -gt 0) {
    $winH = [Math]::Min([Math]::Max($script:UserMinH, 140), $wa.Height)
  } else {
    $winH = [Math]::Min([Math]::Max($contentH, 160), [int]($wa.Height * 0.95))
  }
  if ($src -eq 'saved') {
    $x = $script:UserPos.X
    $y = $script:UserPos.Y
  } else {
    $x = $wa.Right - $script:WinW - $EDGE_GAP
    $y = $wa.Top + $EDGE_GAP
  }
  $xy = Clamp-ToScreen $scr $x $y $script:WinW $winH
  $x = $xy[0]; $y = $xy[1]
  $script:LastPlace = $src + ' want=' + $x + ',' + $y + ' ' + $script:WinW + 'x' + $winH +
    ' work=' + $wa.Left + ',' + $wa.Top + ' ' + $wa.Width + 'x' + $wa.Height
  $popup.SetBounds($x, $y, $script:WinW, $winH)
  Layout-AddBox
  return ,@($x, $y, $script:WinW, $winH)
}

function Force-PopupOnScreen([int]$x, [int]$y, [int]$w, [int]$h) {
  if (-not $script:HasNative) { return }
  try {
    $hw = $popup.Handle
    if ($hw -eq [IntPtr]::Zero) { return }
    $topMost = New-Object IntPtr(-1)
    [void][RiahTodo.Native]::SetWindowPos($hw, $topMost, $x, $y, $w, $h, [uint32](0x0040 -bor 0x0010))
    # Assert the topmost band twice: among topmost windows the last to ask wins,
    # and one ask while placing is not enough (Task Manager is topmost too).
    [void][RiahTodo.Native]::SetWindowPos($hw, $topMost, 0, 0, 0, 0, [uint32](0x0001 -bor 0x0002 -bor 0x0040 -bor 0x0010))
  } catch {}
}

function Test-PopupShown {
  try {
    if (-not $popup.Visible) { return $false }
    if ($script:HasNative) {
      $h = $popup.Handle
      if ($h -ne [IntPtr]::Zero -and -not [RiahTodo.Native]::IsWindowVisible($h)) { return $false }
    }
    return $true
  } catch { return $false }
}

function Refresh-Note {
  Update-TrayIcon
  Clear-TrayTip
  if (Test-PopupShown) {
    try {
      $want = Place-Popup
      Force-PopupOnScreen $want[0] $want[1] $want[2] $want[3]
      $popup.Invalidate()
    } catch {
      # Swallowing this silently once cost an afternoon: the note kept its old
      # size and nothing anywhere said why.
      Write-TrayLog ('refresh_place_fail ' + $_.Exception.Message)
    }
  }
}

function Show-Note {
  try {
    Clear-TrayTip
    [void](Sync-List $false)
    $want = Place-Popup
    $script:PopupOpen = $true
    $popup.TopMost = $false
    $popup.TopMost = $true
    $popup.Invalidate()
    $popup.Show()
    Force-PopupOnScreen $want[0] $want[1] $want[2] $want[3]
    # It takes focus on purpose: that is what lets him type, and what makes a
    # click anywhere else close it.
    try { $popup.Activate(); $addBox.Focus() | Out-Null } catch {}
    $script:ShownAt = Get-Date
    Write-TrayLog ('show_ok ' + $script:LastPlace)
  } catch {
    $script:PopupOpen = $false
    Write-TrayLog ('show_fail: ' + $_.Exception.Message)
  }
}

function Dismiss-Note {
  # A half-typed rename is saved, not thrown away, when the note goes.
  if ($script:EditId) { Stop-Edit $true }
  $script:PopupOpen = $false
  $script:HiddenAt = Get-Date
  # Deliberately NOT Reset-AddBox: closing the note to copy something and coming
  # back must not dump you at the top level. (Captain, 2026-07-29: clicking out
  # "automatically defaults you to starting one thread on the top level, which
  # seems like it is going to annoy some people.") Clear only the typed text.
  $addBox.Text = Get-AddHint
  $addBox.ForeColor = $C.Faint
  try { $popup.Hide() } catch {}
}

function Toggle-Note {
  # Parenthesised on purpose: "Test-PopupShown -and ..." would pass -and to the
  # function as an argument instead of comparing anything.
  if (Test-PopupShown) { Dismiss-Note; return }
  # Clicking the icon while the note is open deactivates it first, which already
  # closed it. Without this guard that same click would immediately reopen it.
  if (((Get-Date) - $script:HiddenAt).TotalMilliseconds -lt $REOPEN_GUARD_MS) { return }
  Show-Note
}

function Open-Board([string]$hash = '') {
  # The board is optional, so start it if it is not up, then open the page.
  try {
    $up = $false
    try {
      $r = Invoke-WebRequest -Uri ($script:BaseUrl + '/api/list') -UseBasicParsing -TimeoutSec 1
      if ($r.StatusCode -eq 200) { $up = $true }
    } catch {}
    if (-not $up) {
      $vbs = Join-Path $script:Root 'start-hidden.vbs'
      if (Test-Path $vbs) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList '//B', '//Nologo', ('"{0}"' -f $vbs) -WorkingDirectory $script:Root
        Start-Sleep -Milliseconds 900
      } else {
        Write-TrayLog ('board_start_fail missing_vbs ' + $vbs)
      }
    }
    Start-Process ($script:BaseUrl + '/' + $hash)
  } catch {}
}

function Quit-Tray {
  try { $fileTimer.Stop(); $awayTimer.Stop() } catch {}
  try { $notify.Visible = $false; $notify.Dispose() } catch {}
  [System.Windows.Forms.Application]::Exit()
}

function Restart-ForUpdate {
  # Swap this copy for the newer one on disk. Only ever called with the note
  # closed and nothing in the middle of a gesture, so there is nothing to lose:
  # the list itself lives in the file, not in here.
  Write-TrayLog 'restart_for_update'
  try { $fileTimer.Stop(); $awayTimer.Stop() } catch {}
  try { $notify.Visible = $false; $notify.Dispose() } catch {}
  try { if ($script:Mutex) { [void]$script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch {}
  try {
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA',
      '-File', ('"{0}"' -f $PSCommandPath)
    ) | Out-Null
  } catch { Write-TrayLog ('restart_failed ' + $_.Exception.Message) }
  [System.Windows.Forms.Application]::Exit()
}

# --- the note itself ---
$popup = New-Object System.Windows.Forms.Form
$popup.Text = 'Riah To-Do'
$popup.FormBorderStyle = 'None'
$popup.ShowInTaskbar = $false
$popup.StartPosition = 'Manual'
$popup.TopMost = $true
$popup.BackColor = $C.Bg
$popup.KeyPreview = $true
$db = $popup.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
if ($db) { $db.SetValue($popup, $true, $null) }
[void]$popup.Handle
Load-Geometry


$ADD_HINT = 'Add a priority'
$addBox = New-Object System.Windows.Forms.TextBox
$addBox.BorderStyle = 'None'
$addBox.BackColor = $C.Raised
$addBox.ForeColor = $C.Faint
$addBox.Font = $F.Row
$addBox.Text = $ADD_HINT
$addBox.MaxLength = $script:MaxLabel
$popup.Controls.Add($addBox)

# When set, whatever is typed next becomes a step under that task instead of a
# new task of its own.
$script:SubtaskParentId = $null

function Get-AddHint {
  if (-not $script:SubtaskParentId) { return $ADD_HINT }
  foreach ($i in @($script:List.items)) {
    if ($i.id -eq $script:SubtaskParentId) {
      $label = [string]$i.label
      if ($label.Length -gt 22) { $label = $label.Substring(0, 22) + '...' }
      return ('Add a step to ' + $label)
    }
  }
  return $ADD_HINT
}

function Reset-AddBox {
  $script:SubtaskParentId = $null
  $addBox.Text = Get-AddHint
  $addBox.ForeColor = $C.Faint
}

function Exit-Subtask {
  # The way back out of a thread, without having to add something first.
  Reset-AddBox
  try { $popup.Activate(); $addBox.Focus() | Out-Null } catch {}
  $popup.Invalidate()
}

function Start-Subtask([string]$parentId) {
  $script:SubtaskParentId = $parentId
  $addBox.Text = Get-AddHint
  $addBox.ForeColor = $C.Faint
  try { $popup.Activate(); $addBox.Focus() | Out-Null } catch {}
  $popup.Invalidate()
}

function Layout-AddBox {
  try {
    $y = $popup.ClientSize.Height - $PAD - $FOOT_H - 6 - $ADD_H
    # While adding into a thread, leave room on the right for the way back out.
    $backW = 0
    if ($script:SubtaskParentId) { $backW = 26 }
    $addBox.SetBounds(($PAD + 8), ($y + 8), ($script:WinW - (2 * $PAD) - 16 - $backW), 18)
    $script:AddRect = New-Object System.Drawing.Rectangle($PAD, $y, ($script:WinW - 2 * $PAD), $ADD_H)
    if ($backW -gt 0) {
      $script:BackRect = New-Object System.Drawing.Rectangle(
        ($script:WinW - $PAD - $backW), ($y + 6), ($backW - 4), ($ADD_H - 12))
    } else {
      $script:BackRect = $null
    }
  } catch {}
}

# --- editing a priority in place ---
# Click the words and they become an editable line, right where they are. No
# menu, no separate field at the bottom. (Captain, 2026-07-28: "the equivalent of
# Riah's social manager, where you just click in it and it's an automatic edit.")
$editBox = New-Object System.Windows.Forms.TextBox
$editBox.BorderStyle = 'None'
$editBox.BackColor = $C.Row
$editBox.ForeColor = $C.Text
$editBox.Font = $F.Row
$editBox.MaxLength = $script:MaxLabel
$editBox.Multiline = $true
$editBox.Visible = $false
$popup.Controls.Add($editBox)

function Stop-Edit([bool]$commit) {
  $id = $script:EditId
  if (-not $id) { return }
  $value = $editBox.Text
  $script:EditId = $null
  $editBox.Visible = $false
  if ($commit) {
    $value = ($value -replace '\r?\n', ' ').Trim()
    if ($value) { Rename-Priority $id $value }
  }
  $popup.Invalidate()
}

function Start-Edit([string]$id) {
  if ($script:EditId -eq $id) { return }
  if ($script:EditId) { Stop-Edit $true }
  $row = $null
  foreach ($r in $script:Rows) { if ($r.id -eq $id) { $row = $r; break } }
  if ($null -eq $row) { return }
  $script:EditId = $id
  $editBox.Text = [string]$row.item.label
  $editBox.SetBounds(
    ($PAD + $CHECK + $CHECK_GAP), ($row.y + 5), (Get-TextWidth), ($row.h - 10))
  $editBox.Visible = $true
  $editBox.BringToFront()
  try { $popup.Activate(); $editBox.Focus() | Out-Null; $editBox.SelectAll() } catch {}
  $popup.Invalidate()
}

$editBox.add_KeyDown({
  param($s, $e)
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
    $e.SuppressKeyPress = $true
    Stop-Edit $true
    return
  }
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
    $e.SuppressKeyPress = $true
    Stop-Edit $false
  }
})
# Clicking another row, or the add box, commits what was typed rather than
# throwing it away.
$editBox.add_Leave({ Stop-Edit $true })

$addBox.add_Enter({
  # Keep the hint visible on focus and clear it on the first real keystroke --
  # an empty box with a blinking caret does not say what it is for.
  if ($addBox.Text -eq (Get-AddHint)) { $addBox.SelectionStart = 0; $addBox.SelectionLength = 0 }
  else { $addBox.ForeColor = $C.Text }
})
$addBox.add_KeyPress({
  if ($addBox.Text -eq (Get-AddHint)) {
    $addBox.Text = ''
    $addBox.ForeColor = $C.Text
  }
})
$addBox.add_Leave({
  if (-not $addBox.Text.Trim()) { Reset-AddBox }
})
$addBox.add_KeyDown({
  param($s, $e)
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
    $e.SuppressKeyPress = $true
    $value = $addBox.Text.Trim()
    $parent = $script:SubtaskParentId
    if ($value -and $value -ne (Get-AddHint)) { Add-Priority $value $parent }
    $addBox.ForeColor = $C.Text
    $addBox.Text = ''
    # Stay in the same thread: adding one step usually means adding the next.
    return
  }
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
    $e.SuppressKeyPress = $true
    # Esc backs out of the thread first, and only then closes the note.
    if ($script:SubtaskParentId) { Reset-AddBox; $popup.Invalidate(); return }
    Dismiss-Note
  }
})

$popup.add_KeyDown({
  param($s, $e)
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Dismiss-Note }
})

function Draw-Check($g, [int]$x, [int]$y, [bool]$done, [bool]$hot) {
  $box = New-Object System.Drawing.Rectangle($x, $y, $CHECK, $CHECK)
  if ($done) {
    $fill = New-Object System.Drawing.SolidBrush($C.Keep)
    $g.FillRectangle($fill, $box)
    $fill.Dispose()
    $tick = New-Object System.Drawing.Pen($C.Bg, 2)
    $tick.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $tick.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($tick, ($x + 4), ($y + 9), ($x + 7), ($y + 12))
    $g.DrawLine($tick, ($x + 7), ($y + 12), ($x + 13), ($y + 5))
    $tick.Dispose()
  } else {
    $col = if ($hot) { $C.Brand } else { $C.Border }
    $pen = New-Object System.Drawing.Pen($col, 1.5)
    $g.DrawRectangle($pen, $box)
    $pen.Dispose()
  }
}

# Held in a variable rather than written inline so a poster shot can run the very
# same drawing against a scaled Graphics. A marketing image of a redrawn
# lookalike would be a lie; this is the note itself, rendered larger.
$script:PaintNote = {
  param($s, $e)
  $g = $e.Graphics
  $g.Clear($C.Bg)
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

  $bText = New-Object System.Drawing.SolidBrush($C.Text)
  $bDim = New-Object System.Drawing.SolidBrush($C.Dim)
  $bFaint = New-Object System.Drawing.SolidBrush($C.Faint)
  $bBrand = New-Object System.Drawing.SolidBrush($C.Brand)
  $pen = New-Object System.Drawing.Pen($C.Border)
  [void]$g.DrawRectangle($pen, 0, 0, ($popup.ClientSize.Width - 1), ($popup.ClientSize.Height - 1))

  # Header: the inline lockup, never a badge. Brand first, always.
  # Measure the real glyph box -- Georgia's italic descender will sit on the hard
  # rule if the gap is guessed instead of measured.
  $y = $PAD
  $riahSize = $g.MeasureString('Riah', $F.Brand)
  $prodSize = $g.MeasureString('To-Do', $F.Product)
  $headH = Get-HeadHeight $g
  [void]$g.DrawString('Riah', $F.Brand, $bBrand, $PAD, $y)
  # Sit the product name on the wordmark's baseline rather than its box top.
  [void]$g.DrawString('To-Do', $F.Product, $bText,
    ($PAD + $riahSize.Width - 4), ($y + $riahSize.Height - $prodSize.Height - 1))

  # Close corner -- the note is sticky, so it needs an obvious way out.
  $script:CloseRect = New-Object System.Drawing.Rectangle(($script:WinW - $PAD - 18), $y, 18, 18)
  $closeCol = if ($script:HoverClose) { $C.Hot } else { $C.Faint }
  $bClose = New-Object System.Drawing.SolidBrush($closeCol)
  [void]$g.DrawString('x', $F.Kill, $bClose, ($script:CloseRect.X + 4), ($script:CloseRect.Y + 1))
  $bClose.Dispose()

  $y += $headH
  $hard = New-Object System.Drawing.Pen($C.Hard, 2)
  [void]$g.DrawLine($hard, $PAD, $y, ($script:WinW - $PAD), $y)
  $hard.Dispose()

  # Tally: what is LEFT is the number that matters.
  $y += 8
  $items = @($script:List.items)
  $left = Get-Remaining
  $todayCount = Get-TodayCount
  $done = $todayCount - $left
  if ($script:ListUnreadable) {
    # Never draw a convincing empty list over a file we could not read.
    $bBad = New-Object System.Drawing.SolidBrush($C.Hot)
    [void]$g.DrawString('LIST FILE UNREADABLE', $F.Meta, $bBad, $PAD, ($y + 4))
    [void]$g.DrawString('Nothing was changed. Your file is', $F.Row, $bText, $PAD, ($y + 22))
    [void]$g.DrawString('untouched - open the folder to fix it.', $F.Row, $bText, $PAD, ($y + 40))
    $bBad.Dispose()
  } elseif ($items.Count -eq 0) {
    [void]$g.DrawString('NOTHING CHOSEN YET', $F.Meta, $bFaint, $PAD, ($y + 4))
  } else {
    $countCol = if ($left -eq 0) { $C.Keep } else { $C.Text }
    $bCount = New-Object System.Drawing.SolidBrush($countCol)
    $countTxt = [string]$left
    [void]$g.DrawString($countTxt, $F.Count, $bCount, $PAD, ($y - 4))
    $cw = $g.MeasureString($countTxt, $F.Count).Width
    $tail = if ($left -eq 0) { 'ALL CLEAR - ' + $done + ' DONE' } else { 'LEFT OF ' + $todayCount + ' - ' + $done + ' DONE' }
    [void]$g.DrawString($tail, $F.Meta, $bFaint, ($PAD + $cw + 2), ($y + 6))
    $bCount.Dispose()
  }

  # Rows
  [void](Measure-Rows $g)
  # Everything from here to the scrollbar is clipped to the row strip, so a
  # scrolled row cannot paint over the header or the add box.
  $oldClip = $g.Clip
  $g.SetClip((New-Object System.Drawing.Rectangle(
    1, $script:ViewTop, ($popup.ClientSize.Width - 2), ($script:ViewBottom - $script:ViewTop))))
  foreach ($r in $script:Rows) {
    $item = $r.item
    # The group heading, drawn once above the first task of its section.
    if ($r.header) {
      $labelText = switch ($r.header) {
        'tomorrow' { 'TOMORROW' }
        'future'   { 'LATER' }
        default    { 'TODAY' }
      }
      $hy = $r.y - $SECTION_H + 6
      $bSec = New-Object System.Drawing.SolidBrush($C.Faint)
      [void]$g.DrawString($labelText, $F.Meta, $bSec, $PAD, $hy)
      $secW = $g.MeasureString($labelText, $F.Meta).Width
      $secPen = New-Object System.Drawing.Pen($C.Border)
      $lineY = $hy + 7
      [void]$g.DrawLine($secPen, ($PAD + $secW + 8), $lineY, ($script:WinW - $PAD), $lineY)
      $secPen.Dispose()
      $bSec.Dispose()
    }
    $hover = ($script:HoverId -eq $r.id)
    $editing = ($script:EditId -eq $r.id)
    $dragging = ($script:RowDragId -eq $r.id -and $script:RowDragArmed)
    $left = Get-RowLeft $r
    $textW = Get-TextWidth ([int]$r.depth)
    if ($textW -lt 60) { $textW = 60 }

    if (($hover -or $editing) -and -not $dragging) {
      $rowBg = New-Object System.Drawing.SolidBrush($C.Row)
      $g.FillRectangle($rowBg, ($left - 4), $r.y, ($script:WinW - $left - $PAD + 8), $r.h)
      $rowBg.Dispose()
    }
    if ($editing) {
      $edge = New-Object System.Drawing.Pen($C.Brand)
      $g.DrawRectangle($edge, ($left - 4), $r.y, ($script:WinW - $left - $PAD + 7), ($r.h - 1))
      $edge.Dispose()
    }
    # The thread line: a subtask is visibly hanging off the task above it.
    if ($r.depth -gt 0) {
      $thread = New-Object System.Drawing.Pen($C.Border)
      $mid = $r.y + [int]($r.h / 2)
      $stem = $PAD + (Get-Indent ([int]$r.depth - 1)) + 9
      [void]$g.DrawLine($thread, $stem, $r.y, $stem, $mid)
      [void]$g.DrawLine($thread, $stem, $mid, ($left - 5), $mid)
      $thread.Dispose()
    }

    Draw-Check $g $left ($r.y + [int](($r.h - $CHECK) / 2)) ([bool]$item.completed) ($hover -and $script:HoverCheck)
    # While a row is being edited its text lives in the edit box on top of it.
    if (-not $editing) {
      $font = if ($item.completed) { $F.RowDone } else { $F.Row }
      $brush = if ($item.completed) { $bFaint } else { $bText }
      if ($dragging) { $brush = $bDim }
      $box = New-Object System.Drawing.RectangleF(
        ($left + $CHECK + $CHECK_GAP), ($r.y + 6), $textW, ($r.h - 10))
      [void]$g.DrawString([string]$item.label, $font, $brush, $box)
    }
    if ($hover -and -not $editing -and -not $dragging) {
      # "+" starts a subtask under this task. Subtasks do not get one -- nesting
      # only goes one deep.
      if ([int]$r.depth -lt $script:MaxDepth) {
        $plusCol = if ($script:HoverPlus) { $C.Brand } else { $C.Faint }
        $bPlus = New-Object System.Drawing.SolidBrush($plusCol)
        [void]$g.DrawString('+', $F.Kill, $bPlus,
          ($script:WinW - $PAD - 16 - $PLUS_W), ($r.y + [int](($r.h - 18) / 2)))
        $bPlus.Dispose()
      }
      $killCol = if ($script:HoverKill) { $C.Hot } else { $C.Faint }
      $bKill = New-Object System.Drawing.SolidBrush($killCol)
      [void]$g.DrawString('x', $F.Kill, $bKill, ($script:WinW - $PAD - 16), ($r.y + [int](($r.h - 18) / 2)))
      $bKill.Dispose()
    }
  }

  # The row you are holding, lifted and following the pointer. A drop line alone
  # tells you where it will land but not that you are carrying anything.
  # (Captain, 2026-07-29: "it would be nice if it kind of dragged with you".)
  if ($script:RowDragId -and $script:RowDragArmed) {
    $held = $null
    foreach ($r in $script:Rows) { if ($r.id -eq $script:RowDragId) { $held = $r; break } }
    if ($null -ne $held) {
      $gy = $script:RowDragY - [int]($held.h / 2)
      $gx = $PAD - 4
      $gw = $script:WinW - (2 * $PAD) + 8
      $ghostBg = New-Object System.Drawing.SolidBrush($C.Raised)
      $g.FillRectangle($ghostBg, $gx, $gy, $gw, $held.h)
      $ghostBg.Dispose()
      $ghostPen = New-Object System.Drawing.Pen($C.Brand)
      $g.DrawRectangle($ghostPen, $gx, $gy, ($gw - 1), ($held.h - 1))
      $ghostPen.Dispose()
      $gLeft = $gx + 8 + (Get-Indent ([int]$held.depth))
      Draw-Check $g $gLeft ($gy + [int](($held.h - $CHECK) / 2)) ([bool]$held.item.completed) $false
      $gFont = if ($held.item.completed) { $F.RowDone } else { $F.Row }
      $gBox = New-Object System.Drawing.RectangleF(
        ($gLeft + $CHECK + $CHECK_GAP), ($gy + 6),
        ($gw - ($gLeft - $gx) - $CHECK - $CHECK_GAP - 10), ($held.h - 10))
      [void]$g.DrawString([string]$held.item.label, $gFont, $bText, $gBox)
    }
  }

  # Where a dragged row would land.
  if ($script:RowDragId -and ($script:DropBeforeId -or $script:DropAtEnd)) {
    $lineY = $null
    $lineLeft = $PAD
    foreach ($r in $script:Rows) {
      if ($r.id -eq $script:DropBeforeId) {
        $lineY = $r.y - 2
        $lineLeft = Get-RowLeft $r
        break
      }
    }
    if ($null -eq $lineY -and $script:DropAfterId) {
      foreach ($r in $script:Rows) {
        if ($r.id -eq $script:DropAfterId) {
          # After the last sibling means after its whole thread, or the line
          # would appear above work that belongs to it.
          $bottom = $r.y + $r.h
          foreach ($k in $script:Rows) {
            if ($k.y -gt $r.y -and $k.depth -gt $r.depth) { $bottom = $k.y + $k.h } elseif ($k.y -gt $r.y) { break }
          }
          $lineY = $bottom + 1
          $lineLeft = Get-RowLeft $r
          break
        }
      }
    }
    if ($null -ne $lineY) {
      $dropPen = New-Object System.Drawing.Pen($C.Brand, 2)
      [void]$g.DrawLine($dropPen, $lineLeft, $lineY, ($script:WinW - $PAD), $lineY)
      $dropPen.Dispose()
    }
  }

  $g.Clip = $oldClip
  $oldClip.Dispose()

  # The scrollbar, drawn only when there is more list than room. Thin, on the
  # right edge of the row strip, and draggable.
  $script:BarRect = $null
  $script:BarThumb = $null
  $maxScroll = Get-MaxScroll
  if ($maxScroll -gt 0) {
    $viewH = $script:ViewBottom - $script:ViewTop
    $barX = $script:WinW - $PAD + 4
    $script:BarRect = New-Object System.Drawing.Rectangle($barX, $script:ViewTop, 5, $viewH)
    $bTrack = New-Object System.Drawing.SolidBrush($C.Raised)
    $g.FillRectangle($bTrack, $script:BarRect)
    $bTrack.Dispose()
    $thumbH = [int]([Math]::Max(28, $viewH * $viewH / $script:ContentBottom))
    if ($thumbH -gt $viewH) { $thumbH = $viewH }
    $thumbY = $script:ViewTop + [int](($viewH - $thumbH) * $script:ScrollY / $maxScroll)
    $script:BarThumb = New-Object System.Drawing.Rectangle($barX, $thumbY, 5, $thumbH)
    $bThumb = New-Object System.Drawing.SolidBrush($C.Border)
    $g.FillRectangle($bThumb, $script:BarThumb)
    $bThumb.Dispose()
  }

  # Empty means empty. The box below already says "Add a priority"; saying it
  # twice in a fuller sentence was overexplaining. (Captain, 2026-07-29.)

  # Add box chrome (the real TextBox sits inside this rectangle)
  Layout-AddBox
  if ($script:AddRect) {
    $addBg = New-Object System.Drawing.SolidBrush($C.Raised)
    $g.FillRectangle($addBg, $script:AddRect)
    $addBg.Dispose()
    $addPen = New-Object System.Drawing.Pen($(if ($script:SubtaskParentId) { $C.Brand } else { $C.Border }))
    $g.DrawRectangle($addPen, $script:AddRect)
    $addPen.Dispose()
  }
  # The way back to the top level, always visible while inside a thread.
  if ($script:BackRect) {
    $backCol = if ($script:HoverBack) { $C.Hot } else { $C.Faint }
    $bBack = New-Object System.Drawing.SolidBrush($backCol)
    [void]$g.DrawString('x', $F.Kill, $bBack, ($script:BackRect.X + 3), ($script:BackRect.Y - 1))
    $bBack.Dispose()
  }

  # No standing hint line: Captain asked for the explanation at the bottom to go.
  # The only thing that appears down here is a refusal, and only while it matters.
  if ($script:Flash -and (Get-Date) -lt $script:FlashUntil) {
    $flashBrush = New-Object System.Drawing.SolidBrush($C.Hot)
    [void]$g.DrawString($script:Flash, $F.Meta, $flashBrush,
      ($PAD + 2), ($script:AddRect.Y - 15))
    $flashBrush.Dispose()
  }

  # Resize grip, so "you can drag this bigger" is visible rather than folklore.
  $gripCol = New-Object System.Drawing.SolidBrush($C.Border)
  $gx = $popup.ClientSize.Width - 5
  $gy = $popup.ClientSize.Height - 5
  for ($i = 0; $i -lt 3; $i++) {
    for ($j = 0; $j -lt (3 - $i); $j++) {
      $g.FillRectangle($gripCol, ($gx - ($i * 4)), ($gy - ($j * 4)), 2, 2)
    }
  }
  $gripCol.Dispose()

  $bText.Dispose(); $bDim.Dispose(); $bFaint.Dispose(); $bBrand.Dispose(); $pen.Dispose()
}
$popup.add_Paint($script:PaintNote)

function Get-NotePoster([int]$scale) {
  # The note drawn at a multiple of its size: same code, scaled Graphics, so the
  # text is rasterised at the larger size instead of being blown up afterwards.
  $w = $popup.ClientSize.Width
  $h = $popup.ClientSize.Height
  $bmp = New-Object System.Drawing.Bitmap(($w * $scale), ($h * $scale))
  # Do NOT also raise the bitmap's DPI. Point-sized fonts are converted using
  # it, so with the transform as well every string came out at scale-squared,
  # wrapped early, and the list ran off the bottom of its own window.
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.ScaleTransform($scale, $scale)
  # ClearType assumes it is drawing on a real window; on a bitmap it fringes the
  # letters with colour. Greyscale antialiasing is what a screenshot should look
  # like at this size.
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $ev = New-Object System.Windows.Forms.PaintEventArgs($g, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)))
  & $script:PaintNote $popup $ev
  # The add box is a real TextBox sitting on top of the form, so the paint code
  # draws its frame but never its words. Put them back.
  if ($script:AddRect) {
    $bHint = New-Object System.Drawing.SolidBrush($C.Faint)
    [void]$g.DrawString((Get-AddHint), $F.Row, $bHint, ($PAD + 8), ($script:AddRect.Y + 9))
    $bHint.Dispose()
  }
  $g.Dispose()
  return $bmp
}

function Get-RowAt([System.Drawing.Point]$client) {
  # A row scrolled under the header or below the add box is not there to click,
  # however much of it the maths says overlaps the pointer.
  if ($client.Y -lt $script:ViewTop -or $client.Y -ge $script:ViewBottom) { return $null }
  foreach ($r in $script:Rows) {
    if ($client.Y -ge $r.y -and $client.Y -lt ($r.y + $r.h)) { return $r }
  }
  return $null
}

function Move-ScrollThumb([int]$y) {
  if ($null -eq $script:BarRect -or $null -eq $script:BarThumb) { return }
  $travel = $script:BarRect.Height - $script:BarThumb.Height
  if ($travel -le 0) { return }
  $rel = $y - $script:BarDragOffset - $script:BarRect.Y
  Set-Scroll ([int]((Get-MaxScroll) * $rel / $travel))
}

function Get-MaxScroll {
  $max = $script:ContentBottom - $script:ViewBottom
  if ($max -lt 0) { return 0 }
  return $max
}

function Set-Scroll([int]$value) {
  $max = Get-MaxScroll
  $next = $value
  if ($next -gt $max) { $next = $max }
  if ($next -lt 0) { $next = 0 }
  if ($next -eq $script:ScrollY) { return }
  $script:ScrollY = $next
  # An edit box floats above a row; scrolling would leave it stranded.
  if ($script:EditId) { Stop-Edit $true }
  $popup.Invalidate()
}

function Test-InCheck([System.Drawing.Point]$pt, $row) {
  # The tick box, generously padded. Everything else on the row is the words.
  if ($null -eq $row) { return $false }
  $left = Get-RowLeft $row
  return ($pt.X -ge ($left - 4) -and $pt.X -lt ($left + $CHECK + 6))
}

function Test-InKill([System.Drawing.Point]$pt) {
  return ($pt.X -ge ($script:WinW - $PAD - 24))
}

function Test-InPlus([System.Drawing.Point]$pt, $row) {
  # Any row can start a sub-thread, right down to the depth limit.
  if ($null -eq $row -or [int]$row.depth -ge $script:MaxDepth) { return $false }
  $x0 = $script:WinW - $PAD - 24 - $PLUS_W
  return ($pt.X -ge $x0 -and $pt.X -lt ($x0 + $PLUS_W))
}

function Get-DropTarget([System.Drawing.Point]$pt) {
  # Which row the dragged one would land above. Past the last one means the end.
  #
  # A row reorders among ITS OWN SIBLINGS -- tasks among tasks, and a step among
  # the steps of the same task. (Captain, 2026-07-29: "any sub thread needs to be
  # able to be dragged and dropped within the sub thread as well.") Dragging a
  # step out of its thread is a re-parent, which is a different gesture.
  $script:DropBeforeId = $null
  $script:DropAtEnd = $false
  $script:DropAfterId = $null
  if (@($script:Rows).Count -eq 0 -or -not $script:RowDragId) { return }

  $dragged = $null
  foreach ($r in $script:Rows) { if ($r.id -eq $script:RowDragId) { $dragged = $r; break } }
  if ($null -eq $dragged) { return }
  $parentId = $dragged.item.parentId

  $movingIds = @{}
  $movingIds[[string]$script:RowDragId] = $true
  foreach ($kid in @(Get-Descendants $script:RowDragId)) { $movingIds[[string]$kid.id] = $true }

  $siblings = New-Object System.Collections.ArrayList
  foreach ($r in $script:Rows) {
    if ($movingIds.ContainsKey([string]$r.id)) { continue }
    # Same parent means same level of the same thread. $null -eq $null covers the
    # top level without a special case.
    if ([string]$r.item.parentId -ne [string]$parentId) { continue }
    [void]$siblings.Add($r)
  }
  if ($siblings.Count -eq 0) { return }

  foreach ($r in $siblings) {
    if ($pt.Y -lt ($r.y + [int]($r.h / 2))) { $script:DropBeforeId = $r.id; return }
  }
  # Past the last sibling: land after it, which for a nested row is NOT the end
  # of the whole list.
  $script:DropAfterId = $siblings[$siblings.Count - 1].id
  $script:DropAtEnd = $true
}

function Get-ResizeEdge([System.Drawing.Point]$pt) {
  # Which border is under the pointer, if any. Corners win over sides.
  $w = $popup.ClientSize.Width
  $h = $popup.ClientSize.Height
  $left = ($pt.X -le $GRIP)
  $right = ($pt.X -ge ($w - $GRIP))
  $top = ($pt.Y -le $GRIP)
  $bottom = ($pt.Y -ge ($h - $GRIP))
  $nearL = ($pt.X -le $CORNER)
  $nearR = ($pt.X -ge ($w - $CORNER))
  $nearT = ($pt.Y -le $CORNER)
  $nearB = ($pt.Y -ge ($h - $CORNER))
  if (($right -and $nearB) -or ($bottom -and $nearR)) { return 'se' }
  if (($left -and $nearB) -or ($bottom -and $nearL)) { return 'sw' }
  if (($right -and $nearT) -or ($top -and $nearR)) { return 'ne' }
  if (($left -and $nearT) -or ($top -and $nearL)) { return 'nw' }
  if ($right) { return 'e' }
  if ($left) { return 'w' }
  if ($bottom) { return 's' }
  if ($top) { return 'n' }
  return ''
}

function Get-CursorForEdge([string]$edge) {
  switch ($edge) {
    'e'  { return [System.Windows.Forms.Cursors]::SizeWE }
    'w'  { return [System.Windows.Forms.Cursors]::SizeWE }
    'n'  { return [System.Windows.Forms.Cursors]::SizeNS }
    's'  { return [System.Windows.Forms.Cursors]::SizeNS }
    'se' { return [System.Windows.Forms.Cursors]::SizeNWSE }
    'nw' { return [System.Windows.Forms.Cursors]::SizeNWSE }
    'ne' { return [System.Windows.Forms.Cursors]::SizeNESW }
    'sw' { return [System.Windows.Forms.Cursors]::SizeNESW }
  }
  return [System.Windows.Forms.Cursors]::Default
}

$popup.add_MouseDown({
  param($s, $e)
  if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
  $pt = New-Object System.Drawing.Point($e.X, $e.Y)
  $edge = Get-ResizeEdge $pt
  if ($edge) {
    $script:Resizing = $true
    $script:ResizeEdge = $edge
    # Grabbing a top or bottom edge is choosing a height. From here on the note
    # keeps it instead of growing back to fit the list.
    if ($edge -match 'n|s') { $script:UserHSet = $true }
    $script:DragStart = [System.Windows.Forms.Cursor]::Position
    $script:DragOrigin = New-Object System.Drawing.Rectangle(
      $popup.Left, $popup.Top, $popup.Width, $popup.Height)
    return
  }
  # The scrollbar takes the click before any row does.
  if ($null -ne $script:BarRect) {
    $barHit = New-Object System.Drawing.Rectangle(
      ($script:BarRect.X - 7), $script:BarRect.Y, ($script:BarRect.Width + 10), $script:BarRect.Height)
    if ($barHit.Contains($pt)) {
      if ($null -ne $script:BarThumb -and $pt.Y -ge $script:BarThumb.Y `
          -and $pt.Y -lt ($script:BarThumb.Y + $script:BarThumb.Height)) {
        # Grab it where you took hold of it, so the thumb does not jump.
        $script:BarDragOffset = $pt.Y - $script:BarThumb.Y
      } else {
        $script:BarDragOffset = [int]($script:BarThumb.Height / 2)
      }
      $script:BarDragging = $true
      Move-ScrollThumb $pt.Y
      return
    }
  }
  $row = Get-RowAt $pt
  if ($null -ne $row) {
    # Arm a row drag. It only becomes a reorder once the pointer actually moves,
    # so a plain click still ticks or edits.
    if (-not (Test-InKill $pt) -and -not (Test-InPlus $pt $row) -and $script:EditId -ne $row.id) {
      $script:RowDragId = $row.id
      $script:RowDragArmed = $false
      $script:RowDragFrom = [System.Windows.Forms.Cursor]::Position
    }
    return
  }
  # Anywhere that is not a row and not the add box is a handle: grab it and move
  # the note wherever you want it, the way the meters box moves.
  if ($script:AddRect -and $script:AddRect.Contains($pt)) { return }
  if ($script:BackRect -and $script:BackRect.Contains($pt)) { return }
  $script:Dragging = $true
  $script:Moved = $false
  $script:DragStart = [System.Windows.Forms.Cursor]::Position
  $script:DragOrigin = New-Object System.Drawing.Rectangle(
    $popup.Left, $popup.Top, $popup.Width, $popup.Height)
})

$popup.add_MouseMove({
  param($s, $e)
  $pt = New-Object System.Drawing.Point($e.X, $e.Y)

  if ($script:Resizing) {
    $cur = [System.Windows.Forms.Cursor]::Position
    $dx = $cur.X - $script:DragStart.X
    $dy = $cur.Y - $script:DragStart.Y
    $o = $script:DragOrigin
    $x = $o.X; $y = $o.Y; $w = $o.Width; $h = $o.Height
    if ($script:ResizeEdge -match 'e') { $w = $o.Width + $dx }
    if ($script:ResizeEdge -match 'w') { $w = $o.Width - $dx; $x = $o.X + $dx }
    if ($script:ResizeEdge -match 's') { $h = $o.Height + $dy }
    if ($script:ResizeEdge -match 'n') { $h = $o.Height - $dy; $y = $o.Y + $dy }
    if ($w -lt $MIN_W) { if ($script:ResizeEdge -match 'w') { $x = $o.X + $o.Width - $MIN_W }; $w = $MIN_W }
    if ($w -gt $MAX_W) { if ($script:ResizeEdge -match 'w') { $x = $o.X + $o.Width - $MAX_W }; $w = $MAX_W }
    if ($h -lt 140) { if ($script:ResizeEdge -match 'n') { $y = $o.Y + $o.Height - 140 }; $h = 140 }
    $script:WinW = $w
    $script:HeadH = $null
    $popup.SetBounds($x, $y, $w, $h)
    Layout-AddBox
    $popup.Invalidate()
    return
  }

  if ($script:BarDragging) { Move-ScrollThumb $pt.Y; return }

  if ($script:Dragging) {
    $cur = [System.Windows.Forms.Cursor]::Position
    $dx = $cur.X - $script:DragStart.X
    $dy = $cur.Y - $script:DragStart.Y
    if (-not $script:Moved -and [Math]::Abs($dx) -lt 4 -and [Math]::Abs($dy) -lt 4) { return }
    $script:Moved = $true
    $popup.SetBounds(($script:DragOrigin.X + $dx), ($script:DragOrigin.Y + $dy),
      $popup.Width, $popup.Height)
    return
  }

  if ($script:RowDragId) {
    $cur = [System.Windows.Forms.Cursor]::Position
    $dy = $cur.Y - $script:RowDragFrom.Y
    $dx = $cur.X - $script:RowDragFrom.X
    if (-not $script:RowDragArmed) {
      if ([Math]::Abs($dy) -lt $ROW_DRAG_SLOP -and [Math]::Abs($dx) -lt $ROW_DRAG_SLOP) { return }
      $script:RowDragArmed = $true
      if ($script:EditId) { Stop-Edit $true }
    }
    Get-DropTarget $pt
    $script:RowDragY = $pt.Y
    $popup.Cursor = [System.Windows.Forms.Cursors]::SizeNS
    $popup.Invalidate()
    return
  }

  $edge = Get-ResizeEdge $pt
  $row = Get-RowAt $pt
  $id = $null
  if ($null -ne $row) { $id = $row.id }
  $inCheck = Test-InCheck $pt $row
  $overKill = ($null -ne $row -and (Test-InKill $pt))
  $overPlus = (Test-InPlus $pt $row)
  $overClose = ($script:CloseRect -and $script:CloseRect.Contains($pt))
  $overBack = ($script:BackRect -and $script:BackRect.Contains($pt))
  if ($id -ne $script:HoverId -or $overKill -ne $script:HoverKill -or
      $overClose -ne $script:HoverClose -or $inCheck -ne $script:HoverCheck -or
      $overPlus -ne $script:HoverPlus -or $overBack -ne $script:HoverBack) {
    $script:HoverId = $id
    $script:HoverKill = $overKill
    $script:HoverClose = $overClose
    $script:HoverCheck = $inCheck
    $script:HoverPlus = $overPlus
    $script:HoverBack = $overBack
    $popup.Invalidate()
  }
  # The cursor is the instruction now that the hint line is gone: a hand over the
  # box, the x and the +, a text caret over the words, arrows on the edges.
  $popup.Cursor = if ($edge) { Get-CursorForEdge $edge }
    elseif ($overClose -or $overKill -or $inCheck -or $overPlus -or $overBack) { [System.Windows.Forms.Cursors]::Hand }
    elseif ($null -ne $row) { [System.Windows.Forms.Cursors]::IBeam }
    elseif ($script:AddRect -and $script:AddRect.Contains($pt)) { [System.Windows.Forms.Cursors]::IBeam }
    else { [System.Windows.Forms.Cursors]::SizeAll }
})

$popup.add_MouseUp({
  param($s, $e)
  $pt = New-Object System.Drawing.Point($e.X, $e.Y)

  if ($script:Resizing) {
    $script:Resizing = $false
    $script:ResizeEdge = ''
    Save-Geometry
    Refresh-Note
    return
  }
  if ($script:BarDragging) { $script:BarDragging = $false; return }

  if ($script:Dragging) {
    $wasMove = $script:Moved
    $script:Dragging = $false
    $script:Moved = $false
    if ($wasMove) { Save-Geometry; return }
  }

  if ($script:RowDragId) {
    $dragged = $script:RowDragId
    $armed = $script:RowDragArmed
    $before = $script:DropBeforeId
    $atEnd = $script:DropAtEnd
    $script:RowDragId = $null
    $script:RowDragArmed = $false
    $script:DropBeforeId = $null
    $script:DropAtEnd = $false
    $script:DropAfterId = $null
    if ($armed) {
      if ($before -or $atEnd) { Move-Before $dragged $before }
      else { $popup.Invalidate() }
      return
    }
  }

  $row = Get-RowAt $pt
  # Right-click a row and you are editing it. No menu in between.
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
    if ($null -ne $row) {
      if ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) {
        # Shift+right-click moves it to the next group: today -> tomorrow ->
        # later -> today.
        $cur = [string]$row.item.section
        $next = switch ($cur) { 'today' { 'tomorrow' } 'tomorrow' { 'future' } default { 'today' } }
        Set-Section $row.id $next
      } else {
        Start-Edit $row.id
      }
    }
    return
  }
  if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
  if ($script:CloseRect -and $script:CloseRect.Contains($pt)) { Dismiss-Note; return }
  if ($script:BackRect -and $script:BackRect.Contains($pt)) { Exit-Subtask; return }
  if ($null -eq $row) {
    if ($script:EditId) { Stop-Edit $true }
    return
  }
  if (Test-InKill $pt) { Remove-Priority $row.id; return }
  if (Test-InPlus $pt $row) {
    if ($script:EditId) { Stop-Edit $true }
    Start-Subtask $row.id
    return
  }
  # In the box marks it done. Anywhere else on the row edits the words.
  if (Test-InCheck $pt $row) {
    if ($script:EditId) { Stop-Edit $true }
    Toggle-Priority $row.id
    return
  }
  Start-Edit $row.id
})

$popup.add_MouseLeave({
  if ($script:Dragging -or $script:Resizing) { return }
  $script:HoverId = $null
  $script:HoverKill = $false
  $script:HoverClose = $false
  $script:HoverCheck = $false
  $popup.Invalidate()
})

# The wheel scrolls the list. It is attached to the boxes as well as the form
# because WinForms sends the wheel to whatever has focus, and the add box almost
# always does -- on the form alone it would only work after clicking a row.
$script:OnWheel = {
  param($s, $e)
  Set-Scroll ($script:ScrollY - ([int]($e.Delta / 120) * 48))
}
$popup.add_MouseWheel($script:OnWheel)
$addBox.add_MouseWheel($script:OnWheel)
$editBox.add_MouseWheel($script:OnWheel)

# Clicking anywhere outside the note closes it. That is the whole dismiss model:
# no hover, no timers, no leave-grace -- the note is up or it is not.
$popup.add_Deactivate({
  # Moving or resizing is not leaving.
  if ($script:Dragging -or $script:Resizing) { return }
  if (-not (Test-PopupShown)) { return }
  Write-TrayLog 'dismissed_click_away'
  Dismiss-Note
})

# --- tray icon ---
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text = [string]::Empty
$notify.Visible = $false

[void](Sync-List $true)
try { Update-TrayIcon; Clear-TrayTip } catch { Write-TrayLog ('icon_boot_fail ' + $_.Exception.Message) }

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $menu.Items.Add("Today's list")
$miShow.add_Click({ Show-Note })
$miBoard = $menu.Items.Add('Open the board')
$miBoard.add_Click({ Open-Board })
# Settings live on the board, where there is room for real controls -- the note
# stays a note.
$miFinished = $menu.Items.Add("What I've finished")
$miFinished.add_Click({ Open-Board '#finished' })
$miSettings = $menu.Items.Add('Settings')
$miSettings.add_Click({ Open-Board '#settings' })
$miClear = $menu.Items.Add('File the finished ones now')
$miClear.add_Click({
  [void](Sync-List $true)
  $gone = New-Object System.Collections.ArrayList
  $keep = New-Object System.Collections.ArrayList
  foreach ($i in @($script:List.items)) {
    if ($i.completed) { [void]$gone.Add($i) } else { [void]$keep.Add($i) }
  }
  if ($gone.Count -eq 0) { Set-Flash 'Nothing finished yet.'; Refresh-Note; return }
  if ($keep.Count -eq 0) { $script:AllowEmptyWrite = $true }
  $script:List.items = @($keep.ToArray())
  Add-Filed @($gone.ToArray())
  [void](Write-Store $script:List)
  Refresh-Note
})
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miQuit = $menu.Items.Add('Quit')
$miQuit.add_Click({ Quit-Tray })
$notify.ContextMenuStrip = $menu

$notify.add_MouseUp({
  param($s, $e)
  Clear-TrayTip
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    Write-TrayLog 'left_click'
    Toggle-Note
  }
})

# Deliberately NO MouseMove handler on the icon: hovering must do nothing.

$notify.add_BalloonTipClicked({ Show-Note })

# Belt and braces for click-away. Deactivate is the fast path, but Windows can
# refuse a background process the foreground window, and a note that never became
# active would never deactivate -- and so would never close. This notices that.
$awayTimer = New-Object System.Windows.Forms.Timer
$awayTimer.Interval = 200
$awayTimer.add_Tick({
  if (-not $script:HasNative) { return }
  if ($script:Dragging -or $script:Resizing) { return }
  if (-not (Test-PopupShown)) { return }
  # Give the window a moment to actually come up before judging it.
  if (((Get-Date) - $script:ShownAt).TotalMilliseconds -lt 600) { return }
  try {
    $fg = [RiahTodo.Native]::GetForegroundWindow()
    if ($fg -eq $popup.Handle) { return }
    Write-TrayLog 'dismissed_lost_foreground'
    Dismiss-Note
  } catch {}
})

# Riah Code and the board write the same file. Poll so the note follows them
# instead of quietly showing yesterday.
$fileTimer = New-Object System.Windows.Forms.Timer
$fileTimer.Interval = 1500
$fileTimer.add_Tick({
  # Never re-lay-out the rows while Captain is typing into one of them.
  if ($script:EditId) { return }

  # A newer copy of this script on disk is an update. Take it while the note is
  # closed and no gesture is in flight -- never mid-drag, never mid-shot.
  if ($script:ScriptStamp -and -not $script:ShotPath -and -not (Test-PopupShown) `
      -and -not $script:RowDragId -and -not $script:Dragging -and -not $script:Resizing) {
    $stamp = $null
    try { $stamp = (Get-Item $PSCommandPath).LastWriteTimeUtc.Ticks } catch {}
    if ($stamp -and $stamp -ne $script:ScriptStamp) {
      # Only once the file has stopped changing. Relaunching an editor's
      # half-written save would leave no tray at all.
      if ($script:PendingStamp -eq $stamp) { Restart-ForUpdate; return }
      $script:PendingStamp = $stamp
    } elseif ($script:PendingStamp) { $script:PendingStamp = $null }
  }

  $today = Get-Date -Format 'yyyy-MM-dd'
  $rolled = ($script:List.date -ne $today)
  if ((Sync-List $rolled) -or $rolled) { Refresh-Note }
  elseif ($script:Flash -and (Get-Date) -ge $script:FlashUntil) {
    $script:Flash = ''
    if (Test-PopupShown) { $popup.Invalidate() }
  }
})

Clear-TrayTip
$notify.Visible = $true
# Log what the FILE holds next to what we ended up with. When the note showed
# three of twelve there was no line anywhere that said so, and working out which
# stage lost them took a copy of the file and three separate experiments.
$onDiskCount = -1
try {
  if (Test-Path -LiteralPath $script:StorePath) {
    $onDiskCount = @(((Get-Content -LiteralPath $script:StorePath -Raw) | ConvertFrom-Json).items).Count
  }
} catch {}
Write-TrayLog ('notify_visible items=' + @($script:List.items).Count + ' onDisk=' + $onDiskCount +
  ' unreadable=' + [bool]$script:ListUnreadable + ' store=' + $script:StorePath)

$fileTimer.Start()
$awayTimer.Start()

try {
  $notify.BalloonTipTitle = 'Riah To-Do'
  $notify.BalloonTipText = "Click the icon for today's list. Click a row to tick it off."
  $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
  $notify.ShowBalloonTip(4000)
} catch { Write-TrayLog ('balloon_fail ' + $_.Exception.Message) }

function Test-ShotHasContent($bmp) {
  # A real note has a pink wordmark, ink text and a rule. One colour across the
  # whole sample means the capture failed, whatever the API returned.
  try {
    $seen = @{}
    for ($x = 2; $x -lt $bmp.Width; $x += 9) {
      for ($y = 2; $y -lt $bmp.Height; $y += 9) {
        $p = $bmp.GetPixel($x, $y)
        $seen[('{0},{1},{2}' -f $p.R, $p.G, $p.B)] = $true
        if ($seen.Count -ge 5) { return $true }
      }
    }
    return $false
  } catch {
    return $false
  }
}

if ($script:ShotPath) {
  # Draw the note exactly as Captain would see it and write it to a file, so the
  # look can be checked without anyone driving the mouse.
  $shotTimer = New-Object System.Windows.Forms.Timer
  $shotTimer.Interval = 700
  $shotTimer.add_Tick({
    $shotTimer.Stop()
    try {
      Show-Note
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 350
      if ($env:RIAH_TODO_TRAY_EXERCISE -eq '1') {
        # Drive the same paths a click drives, so the write side is proven and
        # not just the drawing. The checker reads the file afterwards.
        Add-Priority 'Added by the note'
        $first = @($script:List.items)[0]
        if ($first) { Toggle-Priority $first.id }

        # Threads and dragging: the parts most likely to break quietly.
        $host2 = $null
        foreach ($i in @($script:List.items)) {
          if ($i.label -eq 'Added by the note') { $host2 = $i; break }
        }
        if ($host2) {
          Add-Priority 'Step one' $host2.id
          Add-Priority 'Step two' $host2.id
          # And a sub-thread under a sub-point, which is the whole point of
          # nesting past one level.
          $stepOne = $null
          foreach ($i in @($script:List.items)) { if ($i.label -eq 'Step one') { $stepOne = $i; break } }
          if ($stepOne) {
            Add-Priority 'Deeper still' $stepOne.id
            $deeper = $null
            foreach ($i in @($script:List.items)) { if ($i.label -eq 'Deeper still') { $deeper = $i; break } }
            if ($deeper) { Add-Priority 'Deepest of all' $deeper.id }
          }
          # Ticking the task must tick the whole thread, at every level.
          Toggle-Priority $host2.id
          # Park something for later so the groups are exercised and drawn.
          Add-Priority 'Riah Money'
          $later = $null
          foreach ($i in @($script:List.items)) { if ($i.label -eq 'Riah Money') { $later = $i; break } }
          if ($later) { Set-Section $later.id 'future' }
          # Drag it to the very top, thread and all.
          $top = @(Get-TopLevel)[0]
          if ($top -and $top.id -ne $host2.id) { Move-Before $host2.id $top.id }

          # A step must reorder among its OWN steps. Captain, 2026-07-29:
          # dragging "Make the songs" above "Tiktok vid" did nothing. This drives
          # the real pointer path -- Get-DropTarget on real row geometry, then
          # the same call MouseUp makes -- not just Move-Before on its own.
          $popup.Invalidate()
          [System.Windows.Forms.Application]::DoEvents()
          Start-Sleep -Milliseconds 150
          $gm = $null
          try { $gm = $popup.CreateGraphics(); [void](Measure-Rows $gm) } catch {} finally { if ($gm) { $gm.Dispose() } }
          $rowOne = $null; $rowTwo = $null
          foreach ($r in $script:Rows) {
            if ([string]$r.item.label -eq 'Step one') { $rowOne = $r }
            if ([string]$r.item.label -eq 'Step two') { $rowTwo = $r }
          }
          if ($rowOne -and $rowTwo) {
            $script:RowDragId = $rowTwo.id
            $script:RowDragArmed = $true
            Get-DropTarget (New-Object System.Drawing.Point(60, ($rowOne.y + 2)))
            Write-Host ("SUBDRAG before=" + $script:DropBeforeId + " end=" + $script:DropAtEnd + " want=" + $rowOne.id)
            if ($script:DropBeforeId -or $script:DropAtEnd) {
              Move-Before $rowTwo.id $script:DropBeforeId
            }
            $script:RowDragId = $null
            $script:RowDragArmed = $false
            $script:DropBeforeId = $null
            $script:DropAtEnd = $false
            $script:DropAfterId = $null
          }
        }

        # Scrolling. A list longer than the note must scroll inside it, the note
        # must keep the height Captain chose, and the top row must never be cut
        # off. (Captain, 2026-07-29: "The very top item clips when we hit
        # maximum ... I should just be able to make it smaller anytime I want.")
        $fillers = New-Object System.Collections.ArrayList
        for ($n = 1; $n -le 24; $n++) {
          $fillLabel = 'Filler ' + $n
          Add-Priority $fillLabel
          foreach ($i in @($script:List.items)) { if ($i.label -eq $fillLabel) { [void]$fillers.Add($i.id); break } }
        }
        $script:UserHSet = $true
        $script:UserMinH = 320
        # Place-Popup, not Refresh-Note: Refresh-Note deliberately leaves a
        # hidden note alone, and anything at all taking focus during the
        # exercise would make this measure whatever height it happened to have.
        [void](Place-Popup)
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
        $gs = $null
        try { $gs = $popup.CreateGraphics(); [void](Measure-Rows $gs) } catch {} finally { if ($gs) { $gs.Dispose() } }
        $restTop = @($script:Rows)[0].y
        $roomFor = Get-MaxScroll
        Set-Scroll 200
        try { $gs = $popup.CreateGraphics(); [void](Measure-Rows $gs) } catch {} finally { if ($gs) { $gs.Dispose() } }
        $scrolledTop = @($script:Rows)[0].y
        $diag = 'SCROLL height=' + $popup.Height + ' max=' + $roomFor + ' resttop=' + $restTop +
          ' viewtop=' + $script:ViewTop + ' scrolledtop=' + $scrolledTop + ' at=' + $script:ScrollY
        Write-Host $diag
        Write-TrayLog ($diag + ' shown=' + (Test-PopupShown) + ' visible=' + $popup.Visible +
          ' hset=' + $script:UserHSet + ' minh=' + $script:UserMinH)
        Set-Scroll 0
        foreach ($fid in $fillers) { Remove-Priority $fid }
        $script:UserHSet = $false
        $script:UserMinH = 0

        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
      }
      # Poster mode: the note at a multiple of its size, for the README and the
      # page. Never saves geometry -- the real note shares this settings file and
      # must not come back a different shape because a picture was taken.
      if ($env:RIAH_TODO_TRAY_POSTER) {
        $pw = 0; $ph = 0; $pscale = 2
        if ($env:RIAH_TODO_TRAY_POSTER_W) { $pw = [int]$env:RIAH_TODO_TRAY_POSTER_W }
        if ($env:RIAH_TODO_TRAY_POSTER_H) { $ph = [int]$env:RIAH_TODO_TRAY_POSTER_H }
        if ($env:RIAH_TODO_TRAY_POSTER_SCALE) { $pscale = [int]$env:RIAH_TODO_TRAY_POSTER_SCALE }
        if ($pw -gt 0) { $script:WinW = $pw }
        if ($ph -gt 0) {
          $script:UserHSet = $true; $script:UserMinH = $ph
        } else {
          # No height asked for means "as tall as the list needs". Without this
          # the poster would inherit whatever height the real note was left at
          # and cut the list off halfway down.
          $script:UserHSet = $false; $script:UserMinH = 0
        }
        # Width changes how the text wraps, which changes the height, which
        # changes nothing else -- so it settles in two passes. One pass measured
        # at the old width and cut the last rows off.
        for ($pass = 0; $pass -lt 3; $pass++) {
          [void](Place-Popup)
          $popup.Refresh()
          [System.Windows.Forms.Application]::DoEvents()
        }
        Start-Sleep -Milliseconds 250
        $poster = Get-NotePoster $pscale
        $poster.Save($env:RIAH_TODO_TRAY_POSTER, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Host ('TRAY_POSTER_OK ' + $poster.Width + 'x' + $poster.Height +
          ' rows=' + @($script:Rows).Count + ' win=' + $popup.ClientSize.Height +
          ' content=' + $script:ContentBottom + ' view=' + $script:ViewBottom +
          ' scroll=' + (Get-MaxScroll) + ' at=' + $env:RIAH_TODO_TRAY_POSTER)
        $poster.Dispose()
      }

      $bmp = New-Object System.Drawing.Bitmap($popup.Width, $popup.Height)
      # PrintWindow with PW_RENDERFULLCONTENT captures child controls too, so the
      # shot shows the real note -- text box and all -- not just what Paint drew.
      $shotDone = $false
      if ($script:HasNative) {
        $gs = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $gs.GetHdc()
        try { $shotDone = [RiahTodo.Native]::PrintWindow($popup.Handle, $hdc, 2) } catch {}
        $gs.ReleaseHdc($hdc)
        $gs.Dispose()
      }
      if (-not $shotDone) {
        $popup.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $popup.Width, $popup.Height)))
      }
      # PrintWindow can return TRUE and still hand back an all-black bitmap when
      # the window is not being composited. Three of four shots on 2026-07-29
      # were solid black and the smoke called them a pass. So check the pixels,
      # and fall back to DrawToBitmap rather than saving a lie.
      if (-not (Test-ShotHasContent $bmp)) {
        Write-TrayLog 'shot_blank: PrintWindow gave an empty image - falling back to DrawToBitmap'
        $popup.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
        $popup.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $popup.Width, $popup.Height)))
      }
      if (-not (Test-ShotHasContent $bmp)) {
        $bmp.Dispose()
        throw 'the note drew nothing - every pixel came back the same colour'
      }
      $bmp.Save($script:ShotPath, [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
      Write-TrayLog ('shot_saved ' + $script:ShotPath + ' ' + $popup.Width + 'x' + $popup.Height +
        ' rows=' + @($script:Rows).Count)
      Write-Host ('TRAY_NOTE_OK size=' + $popup.Width + 'x' + $popup.Height +
        ' rows=' + @($script:Rows).Count + ' shot=' + $script:ShotPath)
    } catch {
      $where = ''
      try { $where = ' at line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + ($_.InvocationInfo.Line).Trim() } catch {}
      Write-TrayLog ('shot_fail ' + $_.Exception.Message + $where)
      Write-Host ('TRAY_NOTE_FAILED ' + $_.Exception.Message + $where)
    }
    Quit-Tray
  })
  $shotTimer.Start()
}

$ctx = New-Object System.Windows.Forms.ApplicationContext
Write-TrayLog 'run_loop'
try {
  [System.Windows.Forms.Application]::Run($ctx)
} catch {
  Write-TrayLog ('run_fail ' + $_.Exception.Message)
} finally {
  Write-TrayLog 'exit'
  try { $notify.Visible = $false; $notify.Dispose() } catch {}
  try { if ($script:IconHandle -ne [IntPtr]::Zero) { [RiahTodo.Native]::DestroyIcon($script:IconHandle) | Out-Null } } catch {}
  try { if ($mutex) { $mutex.ReleaseMutex() } } catch {}
}
