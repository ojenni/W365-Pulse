# W365 Pulse

A lightweight background tray app (AutoHotkey v2) that stops a **Windows 365 / Remote
Desktop** session from logging out after idle. It periodically focuses the Cloud PC
window during a gap in your typing and sends a harmless **F15** keypress *over the
connection*, which resets the host's idle timer.

Built for the setup where the Cloud PC window sits on a dedicated screen (e.g. the
laptop display), always visible, while you work on other monitors.

## Why it works this way
- The host counts idle time from **client input over the connection**, not from activity
  inside the session. So the keystroke must be sent to the *focused, rendered* Cloud PC
  window — a minimized RDP window doesn't process input.
- It only pulses during a **physical idle gap** (`A_TimeIdlePhysical`), so it never
  interrupts your typing. `A_TimeIdlePhysical` ignores the synthetic key it sends.
- A **hard ceiling** (default 14 min, under the 15-min timeout) forces a pulse even if
  you never pause — because your work on other monitors sends no input to the VM.

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
- **Settings...** – the configuration window (below)
- **Start with Windows** – adds/removes an HKCU `Run` entry
- **Open log file** / **Exit**

## Settings window
Right-click the tray icon and choose **Settings...**. Everything is set with
spinners, dropdowns and checkboxes — no text files to mis-edit, and values are
validated on save:

- **Timing** – pulse interval, hard ceiling (must be > interval and < 15), and the
  idle-gap that prevents interrupting your typing.
- **Target window** – pick your Cloud PC from a dropdown of currently open windows
  (with a *Refresh list* button), or leave it on **Auto-detect**.
- **Keep-alive signal** – F15 (default) / F14 / F13 / Shift tap / Mouse nudge.
- **Behavior** – notify on each pulse, start with Windows, active/paused.
- **Test now** sends a pulse immediately so you can confirm it reaches the session.

Settings are stored in `%APPDATA%\W365Pulse\config.ini` (written by the app — you
shouldn't need to touch it, but it's there if you want to inspect it).

## If `{F15}` isn't forwarded by your client
Set `Key` to a tiny mouse nudge instead, e.g. `{WheelUp}`, or change the `Send` line in
`W365Pulse.ahk` to a relative `MouseMove`.

## Optional: compile to a standalone .exe
Use `Ahk2Exe` (ships with AutoHotkey, under `Compiler\`) on `W365Pulse.ahk`. Keep the two
`.ico` files next to the resulting `.exe`, or embed them via Ahk2Exe directives.

## Note
This is a workaround for a session-timeout policy. Make sure keeping the session alive is
acceptable use in your environment.
