# W365 Pulse – Technical Reference

This document describes the internal design of `W365Pulse.ahk` for anyone maintaining or extending the app. It covers the state machine, key algorithms, configuration schema, and the external APIs the app depends on.

---

## Repository layout

```
W365Pulse.ahk              Main script — entire app lives here
W365Pulse.ico              Teal pulse icon (active state)
W365Pulse_paused.ico       Grey icon (paused + standing-down states)
W365Pulse_waiting.ico      Amber clock icon (waiting for session window)
make_waiting_icon.py       Python script that generated W365Pulse_waiting.ico
docs/
  user-guide.md            End-user documentation
  technical.md             This file
README.md                  GitHub front page
```

Runtime data (not in the repo):

```
%APPDATA%\W365Pulse\config.ini      INI configuration (IniRead/IniWrite)
%APPDATA%\W365Pulse\w365pulse.log   Plain-text timestamped log (1 MB cap)
```

---

## Architecture

Single-file AutoHotkey v2 script. It is a persistent background process (no main window, no Dock/taskbar entry) with:

- A 5-second `SetTimer` driving `Tick()` — the core state machine
- An `NSStatusItem`-style tray icon (`A_TrayMenu`) as the entire UI surface
- A `Gui`-based settings window (lazily created, singleton, destroyed on close)
- No threads other than the AHK main thread; all callbacks run on the same thread

---

## Configuration

### Defaults (`Cfg` Map)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `VmTimeoutMin` | int | 15 | Cloud PC's own lock/disconnect timeout in minutes |
| `IntervalMin` | int | 8 | Target pulse interval (soft) |
| `MaxMin` | int | 9 | Hard ceiling — pulse even if user is active (must be < VmTimeoutMin) |
| `IdleSec` | int | 4 | Minimum physical idle seconds before a normal pulse is allowed |
| `GiveUpMin` | int | 20 | Real inactivity threshold before standing down |
| `TargetExe` | string | "" | Process name override ("" = auto-detect from `KnownExes`) |
| `TargetTitle` | string | "" | Title substring override (trusted, bypasses launcher filter) |
| `Key` | string | "{F15}" | Keystroke sent into the session, or `{MouseNudge}` |
| `Enabled` | int | 1 | 0 = paused at startup |
| `Notify` | int | 0 | 1 = show tray balloon on each pulse |

### Known client executables

```autohotkey
KnownExes := ["msrdc.exe", "Windows365.exe", "mstsc.exe"]
```

Checked in order when `TargetExe = ""`. `msrdc.exe` covers both the Windows App (MSIX) and the classic Remote Desktop client. `Windows365.exe` covers the older Windows 365 app. `mstsc.exe` is the legacy inbox client.

### Launcher window titles (non-session)

```autohotkey
NonSessionTitles := ["Windows App", "Windows 365", "Microsoft Remote Desktop",
                     "Devices", "Connection Center"]
```

These are the exact window titles the client shows on its home/device-list screen when no VM is connected. Any window whose title exactly matches one of these is not a valid pulse target. See *Window detection* below.

### Persistence

`LoadConfig()` reads overrides from `%APPDATA%\W365Pulse\config.ini` (INI format, `[Settings]` section) over the in-memory defaults. Integer fields are cast via `Integer(IniRead(..., default))`. String fields are read directly. `SaveConfig()` writes every key in `Cfg` back to the file.

---

## State machine

`SetTimer(Tick, 5000)` fires every 5 seconds. The 5-second resolution gives ±5s precision on the hard ceiling (worst-case: a pulse at 9m 5s instead of 9m 0s — acceptable).

`Tick()` walks through branches in this order:

```
1. UpdateTip()
2. if Paused → return
3. onBattery = !IsOnACPower()
   if onBattery && A_TimeIdlePhysical ≥ GiveUpMin*60000
       → set StandingDown = true, return
4. if StandingDown (and not give-up condition above: real input OR plugged into AC)
       → clear StandingDown, reset LastPulse/Waiting/NextWindowCheck
5. elapsed = A_TickCount – LastPulse
   if elapsed < IntervalMin*60000 → return
6. if Waiting && A_TickCount < NextWindowCheck → return   (5-min backoff)
7. hwnd = GetTargetHwnd()
   if hwnd = 0
       → set Waiting=true, NextWindowCheck=now+300000, return
8. if Waiting (now cleared) → clear Waiting
9. idleOk = (A_TimeIdlePhysical ≥ IdleSec*1000)
   if !idleOk && elapsed < MaxMin*60000 → return
10. DoPulse(false)
```

State variables (all globals):

| Variable | Type | Meaning |
|---|---|---|
| `Paused` | bool | Keep-alive manually suspended |
| `StandingDown` | bool | Physical inactivity exceeded GiveUpMin |
| `Waiting` | bool | No session window found |
| `LastPulse` | int | `A_TickCount` of most recent pulse attempt (0 = pulse ASAP) |
| `NextWindowCheck` | int | `A_TickCount` deadline for next window re-check while waiting |

---

## Window detection

`GetTargetHwnd()` returns a window handle (HWND) for an actual running VM session, or 0 if none is found.

**With explicit `TargetTitle`:** `WinExist(title " ahk_exe " exe)` — the user-supplied title is trusted directly and the launcher filter is bypassed.

**Auto-detect path:**
1. For each exe in `KnownExes` (or `[TargetExe]` if overridden), call `WinGetList("ahk_exe " exe)` to enumerate all windows owned by that process.
2. Skip invisible windows (`DllCall("IsWindowVisible", "ptr", id)` = false).
3. Skip windows with an empty title (try/catch around `WinGetTitle`).
4. Skip windows whose title exactly matches any entry in `NonSessionTitles` via `IsLauncherTitle()`.
5. Return the first window that survives all filters.

`IsLauncherTitle(title)` is a simple linear scan of `NonSessionTitles` checking for exact equality (`=`, case-sensitive).

**Why exact match, not substring:** Session titles like "W365-POOL-EN-CH – Oliver Jenni" don't share substrings with the launcher titles, so exact match is both safe and unambiguous. Substring matching would risk false positives as client titles change across versions.

---

## Keystroke delivery

`DoPulse(manual)` handles delivery. Two paths:

### Keystroke path (default)

```
1. ForceActivate(hwnd)
2. WinWaitActive("ahk_id " hwnd, , 1)   — 1-second timeout
3. Send(Cfg["Key"])
4. Sleep(100)                            — brief settle before restoring focus
5. WinActivate("ahk_id " prev)           — restore previous foreground window
```

`ForceActivate(hwnd)` bypasses Windows' foreground-lock protection — the OS normally blocks `SetForegroundWindow` while a different window has focus. The technique:

```autohotkey
ForceActivate(hwnd) {
    thisThread   := DllCall("GetCurrentThreadId")
    targetThread := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "uint*", &pid := 0, "uint")
    if (thisThread != targetThread)
        DllCall("AttachThreadInput", "uint", thisThread, "uint", targetThread, "int", true)
    DllCall("SetForegroundWindow", "ptr", hwnd)
    WinActivate("ahk_id " hwnd)
    if (thisThread != targetThread)
        DllCall("AttachThreadInput", "uint", thisThread, "uint", targetThread, "int", false)
}
```

`AttachThreadInput` temporarily merges the input state of the AHK thread with the target window's thread, making `SetForegroundWindow` succeed. The attachment is removed immediately after.

**Why this is necessary:** Windows App (`msrdc.exe`) and Remote Desktop clients use the Raw Input API (`WM_INPUT`) rather than the legacy `WM_KEYDOWN` messages. Raw Input is only delivered to the foreground window. `ControlSend` (which posts `WM_KEYDOWN` without focus) does not work — the keystroke reaches AHK's own message queue logic but is silently dropped by the client. The only reliable path is to genuinely steal focus, send a real keystroke, then restore focus.

### Mouse nudge path (`Key = "{MouseNudge}"`)

```
1. WinGetPos(hwnd) → window bounds
2. MouseGetPos() → save current cursor position
3. Move cursor to window centre (cx, cy)
4. Move 3 px right
5. Move back to (cx, cy)
6. Move back to original position
```

No focus change is needed — mouse movement goes over the RDP virtual channel regardless of which window has focus. This is the fallback for clients that do not forward the F-key keystrokes.

---

## Idle detection

`A_TimeIdlePhysical` (milliseconds since last real physical keyboard or mouse input) is used for two purposes:

1. **Idle gate** (`IdleSec`): only pulse during a natural typing pause, so the user's work on other monitors is never interrupted.
2. **Give-up threshold** (`GiveUpMin`): stop pulsing entirely after prolonged real inactivity.

`A_TimeIdlePhysical` is AHK's preferred idle counter because it is explicitly documented to **ignore the script's own synthetic `Send`/`MouseMove` calls**. This is critical: if the give-up logic used the OS sleep timer (which _is_ reset by synthetic input), the app would never let the laptop sleep — it would reset the sleep countdown every pulse and keep the laptop awake indefinitely. `A_TimeIdlePhysical` sidesteps this because it counts only real hardware events.

### AC power gating

The give-up threshold only applies while running on battery — there is no point letting the system sleep to save battery that isn't being drained. `IsOnACPower()` wraps the Win32 `GetSystemPowerStatus` API:

```autohotkey
IsOnACPower() {
    buf := Buffer(12, 0)
    if !DllCall("GetSystemPowerStatus", "Ptr", buf)
        return true
    return NumGet(buf, 0, "UChar") != 0   ; ACLineStatus: 0=offline(battery) 1=online(AC) 255=unknown
}
```

`SYSTEM_POWER_STATUS.ACLineStatus` is the first byte of the struct: `0` = running on battery, `1` = on AC, `255` = unknown (e.g. some desktops/VMs report this). The function treats both `1` and `255` as "on AC" — defaulting to "never stand down" is the safer failure mode (worst case: keep-alive runs a bit longer than strictly necessary, rather than a desktop machine spuriously losing keep-alive because it has no battery to report).

`Tick()` calls this once per 5-second tick (`onBattery := !IsOnACPower()`) and combines it with the idle check: `giveUp := onBattery && (A_TimeIdlePhysical >= Cfg["GiveUpMin"] * 60000)`. Plugging in while `StandingDown` is true resumes keep-alive on the very next tick, the same as detecting real keyboard/mouse input.

---

## Tray icon states

`UpdateTip()` is called from `Tick()` and from every action that might change state. It updates both the icon and the tooltip atomically.

| Condition (checked in order) | Icon file | Tooltip |
|---|---|---|
| `Paused` | `W365Pulse_paused.ico` | "W365 Pulse - Paused" |
| `StandingDown` | `W365Pulse_paused.ico` | "standing down (idle N min) / Letting the system sleep..." |
| `Waiting` | `W365Pulse_waiting.ico` (falls back to paused if missing) | "waiting for a session window / Re-checking every 5 minutes" |
| none of the above | `W365Pulse.ico` | "Active / Target: [title] / Last pulse: N min ago" |

Icon switching uses a `static CurIcon` guard (`"a"/"p"/"w"/"s"`) to avoid redundant `TraySetIcon` calls on every 5-second tick.

---

## Environment check

`CheckEnvironment(verbose := false)` is called at startup and from the tray's "Check environment" item (`verbose := true`).

Checks in order:
1. **AutoHotkey v2** — `SubStr(A_AhkVersion, 1, 1) = "2"` (always passes when running as a script, reported for completeness).
2. **A Windows 365 / Remote Desktop client** — `PreferredClient()` probes in order: running process (`ProcessExist`), installed on disk (common program file paths), App Paths registry key. Falls back to `GetTargetHwnd()` (session window already open) or a configured `TargetExe` already running. Sets `clientFound := false` if none of these match (no popup for this — see below).

**Only `!ahkOk` triggers an unprompted `MsgBox` at startup** (`return false` before the `verbose` check). `clientFound := false` is logged (`Env: [ NONE ] ...`) but never shown as a startup dialog — having no client/session detected is the normal state every single time the app starts before a Cloud PC session is open, so treating it as a startup interruption was a bug fixed after a v2.2.1 report: a user with the Windows App genuinely installed, just not currently connected, got nagged by the missing-prerequisites dialog on every launch. `GetTargetHwnd()`/`PreferredClient()`-based detection of MSIX-installed clients is inherently unreliable (no simple App Paths/disk-path registration for Store-installed apps), so rather than trying to perfectly detect "installed," the fix removes the popup for this case entirely and relies on logging + the on-demand verbose report instead.

When `verbose = true`, the report always shows (whether `clientFound` is true or false) — the "no client/session yet" case gets the install/browser instructions inline in the report rather than as a separate forced dialog.

The function's return value (`clientFound`, or `false` if `!ahkOk`) is unused by its only two call sites today — both call it for the logging/dialog side effects, not the return value.

---

## Logging

`Log(msg)` appends a timestamped line to `w365pulse.log` (UTF-8):

```
2026-06-17 14:23:01  Pulse -> W365-POOL-EN-CH - Oliver Jenni
```

If the file exceeds 1 MB it is deleted and a new one started (simplest rotation strategy — avoids unbounded growth without needing a multi-file rotation scheme).

---

## Log viewer

`ShowLogViewer()` (tray → "View log...") is a singleton `Gui` (same `static G` pattern as `ShowSettings()`) with a `TreeView` on the left and a `ListView` on the right, replacing the old behavior of opening the raw log in Notepad.

**Parsing** (`ParseLogEntries()`): reads the whole log file, splits on `` `n ``/`` `r ``, and for each line validates the first 19 characters against `^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$` before treating it as a log entry (silently skips malformed/partial lines). Each entry becomes a `Map` with `ts`, `date` (`yyyy-MM-dd`), `y`/`m`/`d`/`h`, an ISO `week` key, and `msg`. The ISO week is computed via `FormatTime(y . m . d, "YWeek")`, which returns a `YYYYWW` string (e.g. `"202625"` = ISO week 25 of 2026).

**Grouping** (`BuildLogGroups(entries)`): builds two parallel nested `Map` structures from the same entry list:
- `byMonth[year][month][date][hour]` → array of entry indices
- `byWeek[isoWeek][date][hour]` → array of entry indices
- `weekRange[isoWeek]` → `{min, max}` date strings seen in that week, used only for the week node's display label (e.g. "Week 25, 2026 (Jun 15 - Jun 18)")

**Tree construction** (`PopulateLogTree(TV, entries, groups, todayY, todayMo, todayDate)`): adds an "All entries" root, then a "By month" branch (Year → Month → Day → Hour) and a "By week" branch (Week → Day → Hour) to the `TreeView`, sorting each level's keys descending (newest first) via `SortedKeysDesc()`. While building, it accumulates each node's full subtree of entry indices bottom-up (`arr.Push(otherArr*)` to concatenate) into a `nodeEntries` Map keyed by the `TreeView` item ID — this is what gets looked up when a node is clicked. It also tracks, while walking the "By month" branch, the item IDs matching `todayY`/`todayMo`/`todayDate` (the caller's current date) as `todayYearId`/`todayMonthId`/`todayDayId`, returned alongside `nodeEntries` in a wrapping `Map`.

**Display** (`DisplayLogEntries(idxArr)`): clears and repopulates the `ListView`, iterating `idxArr` **in reverse** so the most recent entry within the selected node appears first — `idxArr` itself is built in chronological (ascending) order since entries are appended to it in file order.

**Default view** (`BuildAndSelectToday()`): called once when the window is built and again from **Refresh**. Computes today's date with `FormatTime(, "yyyy-MM-dd")`, calls `PopulateLogTree()` with it, then selects the most specific match available — `todayDayId` if today has log entries, else `todayMonthId`, else `todayYearId`, else falls back to "All entries". Selection uses `TV.Modify(target, "Select Vis")`; the `Vis` option auto-expands every ancestor node so the day is immediately visible without manually expanding "By month" → year → month first.

**Sorting helper gotcha**: `SortedKeysDesc()`/`SortDesc()` must use `StrCompare(a, b)` rather than the `<`/`>` operators. AHK v2's relational operators try to coerce dash-containing strings like `"2026-06-15"` to numbers and throw `Expected a Number but got a String` instead of falling back to a string comparison — this surfaced during testing as the entire log viewer silently failing to open (the auto-execute thread aborted before `G.Show()` ran, with no dialog visible). The same pitfall applies to the `weekRange` min/max tracking in `BuildLogGroups()`. **Any future string comparison added to this file should use `StrCompare()`, never `<`/`>`.**

**Closure-sharing gotcha**: `nodeEntries` (and any other variable read by one nested function but only *assigned* by a sibling nested function) must be declared in `ShowLogViewer`'s own top-level body first, e.g. `nodeEntries := Map()`, even though the "real" assignment happens inside `BuildAndSelectToday()`. AHK v2 only treats a variable as a closure shared across sibling nested functions if their common ancestor function references it directly — two nested functions that are siblings (`OnSelect` and `BuildAndSelectToday`, both nested directly in `ShowLogViewer`) do **not** automatically share a variable just because one assigns it and the other reads it; without the empty declaration in the parent, AHK's static analysis flags the variable as "never assigned" in the *reading* function and pops up a blocking `#Warn`-style dialog *before any code runs at all* (this surfaced during testing as the whole script appearing to hang with no window and no log output — the dialog's title was just the script filename, easy to miss). This is also why `LV` must be created *before* the first call to `BuildAndSelectToday()` — code order matters for the same reason a variable can't be read before it's assigned.

**Refresh**: the **Refresh** button re-parses the file, calls `TV.Delete()` (clears every node), and calls `BuildAndSelectToday()` again — so refreshing jumps back to today, the same as opening the viewer fresh.

---

## Startup registration

`SetStartup(on)` writes or removes a `REG_SZ` value named `W365Pulse` under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. The value is:

- If running compiled (`.exe`): `"C:\path\to\W365Pulse.exe"`
- If running as a script: `"C:\path\to\AutoHotkey64.exe" "C:\path\to\W365Pulse.ahk"`

`StartupRegistered()` reads the same key and returns true if a non-empty value is present.

---

## Icon files

The three `.ico` files each contain 8 sizes (16, 20, 24, 32, 40, 48, 64, 256 px) stored as uncompressed 32-bit DIB frames.

**Why uncompressed DIB:** The .NET `System.Drawing.Icon` class (used by AHK's `TraySetIcon` implementation on some Windows builds) rejects ICO files that contain PNG-compressed frames, treating them as invalid. Uncompressed frames are universally accepted.

`W365Pulse_waiting.ico` was generated by `make_waiting_icon.py` (Python, using the `struct` module to hand-build the ICO binary with a clock-face design in amber/orange on a transparent background). The other two icons were created manually.

---

## Settings GUI

The settings window is a singleton `Gui` stored in a `static G` variable inside `ShowSettings()`. If `G` is truthy when `ShowSettings()` is called, the existing window is brought to front. The window is destroyed on close (`G.Destroy(); G := ""`), so the next call creates a fresh instance.

All controls operate on local variables; the user's current `Cfg` is only written on **Save**. **Cancel** and the close button just destroy the window.

Validation on save:
- `MaxMin > IntervalMin` (ceiling must exceed interval)
- `MaxMin < VmTimeoutMin` (ceiling must stay below VM timeout)

The **Pulse interval** quick-presets in the tray menu (`SetInterval(mins, *)`) automatically recalculate `MaxMin` as `Min(mins + 2, VmTimeoutMin - 1)` to maintain a valid relationship.

---

## Keeping this documentation up to date

When a new feature is added to `W365Pulse.ahk`, update the following in the same commit:

| What changed | Files to update |
|---|---|
| New `Cfg` key / default | *Configuration* table in this file; *Settings window* table in user-guide.md; Settings GUI section in this file |
| New tray icon state | *Tray icon states* table in both docs; `UpdateTip()` section in this file |
| New state variable in `Tick()` | *State machine* section in this file |
| New tray menu item | *Tray menu* table in user-guide.md; `BuildTray()` notes in this file |
| New window detection heuristic | *Window detection* section in this file; relevant FAQ/troubleshooting in user-guide.md |
| Change to idle/sleep behavior | *Idle detection* section in this file; *Battery / sleep behavior* in user-guide.md and README.md |
| New key/signal option | *Keep-alive signal* table in user-guide.md; `KeyVals`/`KeyLabels` section in this file |
| Change to log format/fields | *Log viewer* section in this file (parsing regex assumes the existing format); *Log Viewer* section in user-guide.md |
| Version bump | `AppVersion` in `W365Pulse.ahk`; header comment in `W365Pulse.ahk` |

Also update the macOS port plan at `C:\Users\olive\.claude\plans\sprightly-moseying-waffle.md` for any behavioral change that would need an equivalent design on macOS.
