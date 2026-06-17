# W365 Pulse – User Guide

## What does it do?

W365 Pulse prevents your Windows 365 or Remote Desktop Cloud PC session from disconnecting due to inactivity. It runs silently in the system tray and, while you are working on other monitors, briefly activates the session window and sends a harmless keystroke every few minutes — enough to keep the Cloud PC's idle timer from expiring.

It is designed for a common multi-monitor setup: your Cloud PC window sits on one screen (often the laptop's built-in display), while you work on one or two external monitors. The Cloud PC sees no keyboard activity from you directly, so without W365 Pulse it would time out and disconnect after 10–15 minutes.

---

## Prerequisites

| Requirement | Where to get it |
|---|---|
| Windows 10 or 11 | — |
| AutoHotkey v2 | [autohotkey.com](https://www.autohotkey.com/) |
| A Windows 365 or Remote Desktop client | [Windows App](https://aka.ms/windowsapp) (recommended), or browser at [windows.cloud.microsoft](https://windows.cloud.microsoft) |

---

## Installation

1. Install **AutoHotkey v2** if it is not already present.
2. Place the following files in any folder (they must stay together):
   - `W365Pulse.ahk`
   - `W365Pulse.ico`
   - `W365Pulse_paused.ico`
   - `W365Pulse_waiting.ico`
3. Double-click `W365Pulse.ahk` to start the app.

A small icon appears in the system tray. That is the entire UI — there is no window that opens on launch.

To start it automatically when Windows boots, right-click the tray icon and tick **Start with Windows**. The setting is also available inside **Settings...**.

---

## Tray icon states

The tray icon changes depending on what the app is currently doing.

| Icon | Colour | Meaning |
|---|---|---|
| Pulse | Teal | **Active** — running normally; hover to see the target window and time of last pulse |
| Clock | Amber | **Waiting** — no session window found; re-checking every 5 minutes |
| Paused | Grey | **Paused** — keep-alive is manually suspended |
| Paused | Grey | **Standing down** — you have been away from the keyboard longer than the *give-up* threshold; keep-alive has stopped so the laptop can sleep normally. Resumes the moment you touch the keyboard or mouse. |

Hover over the tray icon at any time to see a tooltip with the current state, target window title, and time since the last pulse.

---

## Tray menu

Right-click the tray icon to open the menu:

| Item | What it does |
|---|---|
| **W365 Pulse** (header) | Opens the About dialog |
| **Active** | Checkmark toggles keep-alive on or off (same as the Paused state) |
| **Pulse now** | Sends a keep-alive immediately — also the double-click action |
| **Pulse interval** | Quick submenu: 8 / 10 / 12 minute presets |
| **Re-detect window** | Shows which window the app is currently targeting (or warns if none is found) |
| **Check environment** | Full status report: confirms AutoHotkey v2 is running and a client is detected |
| **Settings...** | Opens the full settings window |
| **Start with Windows** | Adds or removes the app from the Windows startup list |
| **Open log file** | Opens `w365pulse.log` in Notepad |
| **Exit** | Quits the app |

---

## Settings window

Open via right-click → **Settings...**

### Timing

All five values interact with each other and are validated on save.

| Field | Default | What it means |
|---|---|---|
| **VM locks after** | 15 min | Your Cloud PC's own idle-disconnect timeout. Check with your IT admin or try it — some tenants lock at 10 min, others at 15 or 30. The other timing fields are validated against this: the hard ceiling must stay below it. |
| **Pulse every** | 8 min | The target pulse interval. The app waits for a natural idle gap of at least *Only when idle for* seconds before pulsing; if that gap never comes, it pulses at the hard ceiling instead. |
| **Force a pulse by** | 9 min | Hard ceiling. Even if you are actively typing (which sends no input to the Cloud PC), a pulse is forced at this many minutes. Must be larger than *Pulse every* and smaller than *VM locks after*. |
| **Only when idle for** | 4 sec | Minimum physical idle time before a pulse is allowed. Prevents the app from interrupting your typing — it waits for a natural pause in your keystrokes. |
| **Give up after** | 20 min | If you have been genuinely away from the keyboard and mouse for this long, the app stops pulsing entirely. This lets the laptop enter sleep mode normally instead of staying awake forever. See *Battery / sleep behavior* below. |

### Target window

By default the app auto-detects any open Windows App / Windows 365 / Remote Desktop session window. Use the dropdown to pin it to a specific window if the auto-detect picks the wrong one (e.g. you have two sessions open). Click **Refresh list** to update the dropdown with currently open windows.

Leave on **Auto-detect (recommended)** unless you need to override it.

> **Note:** The app distinguishes the client being open on its home screen (no VM connected) from an actual running session. A window simply titled "Windows App", "Windows 365", "Devices", or similar does **not** count as a session — the app waits as if the client were not running at all, until a real session window (titled with your Cloud PC or pool name) appears.

### Keep-alive signal

| Option | What gets sent |
|---|---|
| **F15 – invisible (recommended)** | The F15 key — exists on the keyboard protocol but has no effect in any modern application |
| **F14** | Same idea |
| **F13** | Same idea |
| **Shift tap** | A brief Shift keypress — harmless in most contexts |
| **Mouse nudge** | Moves the cursor a few pixels towards the centre of the session window and back; no key is sent. Use this if keystrokes are not forwarded over your RDP connection. |

### Behavior

| Option | What it does |
|---|---|
| **Show a notification on each pulse** | A brief tray balloon appears after every successful pulse. Off by default to avoid distraction. |
| **Start automatically with Windows** | Equivalent to right-click → Start with Windows |
| **Active** | Uncheck to pause keep-alive without closing the app |

### Buttons

| Button | Action |
|---|---|
| **Test now** | Sends an immediate pulse; confirms the signal reaches the session |
| **Reset** | Restores all fields to their factory defaults (does not save until you click Save) |
| **Cancel** | Discards all changes |
| **Save** | Validates and saves all settings; the app applies them immediately |

---

## Battery / sleep behavior

W365 Pulse sends synthetic keystrokes, which reset Windows' own idle-sleep timer — the same timer that normally puts the laptop to sleep after N minutes on battery. Without a cutoff, the laptop would never reach its sleep timeout while the app is running, even if you have walked away for hours.

To prevent this, the app uses `A_TimeIdlePhysical` — an AutoHotkey counter that tracks real physical keyboard/mouse input and deliberately ignores the app's own synthetic input. When that counter reaches the *Give up after* threshold (default 20 min), the app stops pulsing. The laptop's sleep timer is then free to run normally, and the Cloud PC session will lock or disconnect per its own policy — there is nothing the app can do about that while you are genuinely not there.

Once you touch the keyboard or mouse, the app resumes pulsing immediately.

To check your current sleep timeouts, open an elevated Command Prompt or PowerShell and run:

```
powercfg /query SCHEME_CURRENT SUB_SLEEP
```

If the sleep timeout is set to **Never** while plugged in, that is a Windows power plan setting independent of this app. To see what is currently preventing sleep, run:

```
powercfg /requests
```

---

## Lid-close behavior

The session window needs to remain visible and unminimised on the laptop's screen — closing the lid often powers off the internal panel, which may affect whether Windows considers the window visible.

**Recommended if you want to keep the session running with the lid closed:**

Open *Settings > System > Power & battery* (Windows 11) or *Control Panel > Power Options > Choose what closing the lid does* (classic), and set **When I close the lid** → **Do nothing**, for both *On battery* and *Plugged in*.

After changing the setting, test it: close the lid for a few minutes with a session running and confirm the keep-alive log shows continued pulses. Behavior is hardware-dependent — some laptops disable the internal panel at firmware level regardless of the Windows setting.

**Lid-close options and their effect:**

| Setting | What happens to the app and session |
|---|---|
| **Do nothing** | App keeps running; session stays alive as long as the window is still visible |
| **Sleep** | Windows sleeps → AHK script suspends → session disconnects per the Cloud PC policy |
| **Hibernate** | Same as Sleep, but resumes from a saved state |
| **Shut down** | App and session both end |

---

## Troubleshooting

### The session still disconnects

1. Open the log file (right-click tray icon → **Open log file**) and look for `Pulse ->` lines. If you see them, the app is reaching the session.
2. If you see `Activate failed`, the window-focus handoff is not completing. Try switching the keep-alive signal to **Mouse nudge** in Settings.
3. Check **VM locks after** in Settings — if your Cloud PC's timeout is shorter than the default 15 min, lower this value so the hard ceiling is recalculated correctly.
4. Confirm the app is not in *standing-down* mode (grey icon, tooltip says "standing down") — if so, touch the keyboard or mouse to resume.

### The app says "No Cloud PC window found"

- Open your session in Windows App or Remote Desktop first, then right-click the tray icon → **Re-detect window**.
- If the session is already open but not detected, open **Settings...**, refresh the target window list, and pick the correct entry manually.
- The app only detects *actual session windows*, not the Windows App home/device-list screen. Connect to a Cloud PC first.

### The laptop still does not go to sleep

- Lower the **Give up after** threshold in Settings so the app stops pulsing sooner.
- Check `powercfg /requests` (elevated) to see if something other than W365 Pulse is holding the system awake.
- If you are plugged in and sleep is set to "Never" in the power plan, that is a Windows setting to change under *Power Options*, not something the app controls.

### The F15 key does not seem to reach the session

Switch to **Mouse nudge** in Settings → Keep-alive signal. Mouse movement goes over the RDP connection via a different path than keyboard input and is more likely to be forwarded.

### The tray icon is amber (waiting) but my session is open

The app may be seeing the client's home/launcher screen rather than your session window. Check that you are actually connected to a Cloud PC (the window title should show your machine or pool name, not "Windows App" or "Windows 365"). If you are connected, use **Re-detect window** from the tray menu, or manually select the window in Settings.

---

## FAQ

**Does the app need admin rights?**  
No. It runs as a standard user.

**Is the keystroke visible in my session?**  
F15 exists in the keyboard protocol but has no assigned function in any modern application. The session receives it and resets its idle timer, but nothing visible happens. If you switch to Mouse nudge, the cursor makes a tiny invisible movement on the remote desktop.

**Does it interrupt what I am doing?**  
The app waits for a natural idle gap (default 4 seconds of no keyboard/mouse input) before sending a pulse. If you are actively typing on another monitor, it waits until you pause, up to the hard ceiling. The focus handoff (taking and restoring the active window) takes roughly 100–200 ms and is imperceptible in practice.

**Where are settings stored?**  
In `%APPDATA%\W365Pulse\config.ini`. You can open this folder by typing `%APPDATA%\W365Pulse` into the File Explorer address bar.

**Where is the log?**  
Same folder: `%APPDATA%\W365Pulse\w365pulse.log`. It is capped at 1 MB (the old file is deleted when the limit is reached). Right-click the tray icon → **Open log file** opens it directly.

**Can I compile it to a standalone .exe?**  
Yes. Use `Ahk2Exe` (included with AutoHotkey under `Compiler\`) on `W365Pulse.ahk`. Keep the three `.ico` files next to the resulting `.exe`.
