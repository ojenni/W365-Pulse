# W365 Pulse

A lightweight background tray app (AutoHotkey v2) that stops a **Windows 365 / Remote
Desktop** session from logging out after idle. It periodically activates the Cloud PC
window during a gap in your typing and sends a harmless **F15** keypress *over the
connection*, which resets the host's idle timer.

Built for the setup where the Cloud PC window sits on a dedicated screen (e.g. the
laptop display), always visible, while you work on other monitors.

## Why it works this way
- The host counts idle time from **client input over the connection**, not from activity
  inside the session. The keystroke has to actually reach the remote session — sending
  it to a backgrounded window (e.g. via `ControlSend`) is *not* enough, because clients
  like the Windows App (`msrdc.exe`) use the Raw Input API, which only sees input while
  the window genuinely has focus. So the app briefly activates the window using
  `AttachThreadInput` + `SetForegroundWindow` (bypassing Windows' normal foreground-lock
  protection), sends the key, then hands focus straight back to whatever you were doing.
- It only pulses during a **physical idle gap** (`A_TimeIdlePhysical`), so it never
  interrupts your typing. `A_TimeIdlePhysical` ignores the synthetic key it sends.
- A **hard ceiling** (default 9 min, under a typical 10-min lock policy) forces a pulse
  even if you never pause — because your work on other monitors sends no input to the VM.
- If **no session window is open**, it doesn't busy-poll: it enters a *waiting* state
  (amber tray icon) and re-checks every **5 minutes**, then resumes the instant your
  Cloud PC window reappears.
- If you've been **genuinely away from the keyboard** for longer than the *give-up*
  threshold (default 20 min), it stops pulsing entirely until you touch the keyboard or
  mouse again. See **Battery / sleep behavior** below for why this matters.

## Battery / sleep behavior
Windows' own sleep-on-idle timer is reset by *any* keyboard/mouse input — including the
synthetic keystrokes this app sends. Without a cutoff, that means the laptop would never
reach its sleep timeout on battery power and could run until the battery is empty, even
after you've genuinely walked away.

To prevent this, W365 Pulse tracks real physical inactivity (`A_TimeIdlePhysical`, which
ignores its own synthetic input) and **stands down** after the configured *give-up*
minutes of no real input. While standing down:
- It stops sending keystrokes, so Windows' sleep timer is no longer being reset and the
  laptop can sleep on schedule.
- The Cloud PC session will lock/disconnect per its own policy, same as if the app
  weren't running — there's no way around that while you're genuinely not there.
- The tray icon/tooltip shows "standing down (idle N min)"; touching the keyboard or
  mouse resumes keep-alive immediately.

Check your current sleep timeouts with `powercfg /query SCHEME_CURRENT SUB_SLEEP`. If
sleep is set to "Never" while plugged in, that's a Windows power-plan setting independent
of this app. To see whether anything else is holding the system awake, run
`powercfg /requests` from an elevated prompt.

## Lid-close behavior
Since the Cloud PC window needs to stay **visible and not minimized** on the laptop's own
screen, closing the lid is generally something to avoid in this setup — most laptops
power off the internal panel when the lid closes, which can affect whether the window is
still treated as visible. If you do want the laptop to keep running with the lid closed:

- Open **Settings > System > Power & battery > Power mode**, or classic *Control Panel >
  Power Options > Choose what closing the lid does*, and set **"When I close the lid"**
  to **Do nothing** — set this separately for *On battery* and *Plugged in*.
- Test it: close the lid for a few minutes with a session open and confirm the keep-alive
  still reaches the VM (check the log). Behavior here is hardware/OEM-dependent — some
  laptops disable the internal panel at the firmware level regardless of the Windows
  setting, which may or may not affect window state.
- The other lid-close options (**Sleep**, **Hibernate**, **Shut down**) all suspend or
  end the AHK script along with everything else, which will let the session disconnect —
  use those if you specifically want closing the lid to end the session.
- If you don't need the laptop to be portable while the session runs, simply leaving the
  lid open avoids the question entirely.

## Run
Double-click `W365Pulse.ahk`, or:
```
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "W365Pulse.ahk"
```
It lives in the system tray (teal pulse icon = active, grey = paused). No console window.

## Tray menu
- **Active** – check/uncheck to run or pause the keep-alive
- **Pulse now** – send a keep-alive immediately (also the double-click action)
- **Pulse interval** – quick 8 / 10 / 12 minute presets
- **Re-detect window** – shows which window it's targeting
- **Check environment** – reports whether the prerequisites are present (below)
- **Settings...** – the configuration window (below)
- **Start with Windows** – adds/removes an HKCU `Run` entry
- **Open log file** / **Exit**

## Environment check
On startup the app verifies its prerequisites and **only interrupts you if something
is missing**:

- **AutoHotkey v2** – the runtime (always present when run as a script).
- **A Windows 365 / Remote Desktop client** – detected as a running `msrdc.exe` /
  `Windows365.exe`, an installed Windows App / Remote Desktop client on disk, or a
  session window that's already open.

If none is found, a dialog tells you what's missing and where to get it
(Windows App: https://aka.ms/windowsapp, or browser access at
https://windows.cloud.microsoft — then pick that window in *Settings > Target
window*). Run it any time from the tray's **Check environment** item for a full
status report.

## Settings window
Right-click the tray icon and choose **Settings...**. Everything is set with
spinners, dropdowns and checkboxes — no text files to mis-edit, and values are
validated on save:

- **Timing** – pulse interval, hard ceiling (must be > interval and < 15), the idle-gap
  that prevents interrupting your typing, and the give-up threshold (see *Battery / sleep
  behavior* above).
- **Target window** – pick your Cloud PC from a dropdown of currently open windows
  (with a *Refresh list* button), or leave it on **Auto-detect**.
- **Keep-alive signal** – F15 (default) / F14 / F13 / Shift tap / Mouse nudge.
- **Behavior** – notify on each pulse, start with Windows, active/paused.
- **Test now** sends a pulse immediately so you can confirm it reaches the session.

Settings are stored in `%APPDATA%\W365Pulse\config.ini` (written by the app — you
shouldn't need to touch it, but it's there if you want to inspect it).

## If `{F15}` isn't forwarded by your client
Open **Settings > Keep-alive signal** and switch to **Mouse nudge**, which moves the
cursor briefly instead of sending a keystroke.

## Optional: compile to a standalone .exe
Use `Ahk2Exe` (ships with AutoHotkey, under `Compiler\`) on `W365Pulse.ahk`. Keep the two
`.ico` files next to the resulting `.exe`, or embed them via Ahk2Exe directives.

## Note
This is a workaround for a session-timeout policy. Make sure keeping the session alive is
acceptable use in your environment.
