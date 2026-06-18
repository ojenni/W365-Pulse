#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
SetTitleMatchMode(2)            ; window title = "contains"

; ============================================================================
;  W365 Pulse v2.2.0 - keeps a Windows 365 / Remote Desktop session from
;  logging out by briefly activating the session window (AttachThreadInput to
;  bypass Windows foreground-lock) and sending a no-op key over the connection.
;  Designed for a setup where the Cloud PC window lives on a dedicated screen.
;  Only pulses when an actual VM session is connected - not when the client is
;  merely open on its launcher screen - and stands down after prolonged real
;  inactivity, but only while running on battery, so the laptop can sleep
;  normally instead of running until empty; while plugged into AC it keeps
;  pulsing regardless of idle time, since there's no battery to drain. The
;  tray's "View log..." opens a drill-down viewer (month/week/day/hour) with
;  newest entries shown first, instead of the raw append-only log file.
; ============================================================================
AppVersion := "2.2.0"

; ---- Paths -----------------------------------------------------------------
ConfigDir  := A_AppData "\W365Pulse"
ConfigFile := ConfigDir "\config.ini"
LogFile    := ConfigDir "\w365pulse.log"
ActiveIcon  := A_ScriptDir "\W365Pulse.ico"
PausedIcon  := A_ScriptDir "\W365Pulse_paused.ico"
WaitingIcon := A_ScriptDir "\W365Pulse_waiting.ico"
if !DirExist(ConfigDir)
    DirCreate(ConfigDir)

; ---- Config (defaults, then overridden by config.ini) ----------------------
Cfg := Map(
    "VmTimeoutMin", 15,         ; the Cloud PC's own lock/disconnect timeout - varies per VM
    "IntervalMin", 8,           ; soft target: pulse roughly this often, on an idle gap
    "MaxMin",      9,           ; hard ceiling: pulse even if you're actively typing (must be < VmTimeoutMin)
    "IdleSec",     4,           ; only pulse after this many seconds of no physical input
    "GiveUpMin",   20,          ; stop pulsing after this much real inactivity (lets sleep happen)
    "TargetExe",   "",          ; empty = auto-detect among the known clients below
    "TargetTitle", "",          ; optional title filter to disambiguate multiple windows
    "Key",         "{F15}",     ; harmless key sent into the session
    "Enabled",     1,
    "Notify",      0)           ; 1 = show a tray balloon on every pulse
KnownExes := ["msrdc.exe", "Windows365.exe", "mstsc.exe"]
; Generic window titles the client shows when it's open but NOT connected to a
; VM (its home/launcher/device-list screen). A window with one of these exact
; titles isn't a session worth pulsing into - the app should wait instead.
NonSessionTitles := ["Windows App", "Windows 365", "Microsoft Remote Desktop", "Devices", "Connection Center"]
KeyVals   := ["{F15}", "{F14}", "{F13}", "{Shift}", "{MouseNudge}"]
KeyLabels := ["F15 - invisible (recommended)", "F14", "F13", "Shift tap", "Mouse nudge"]

LoadConfig()
Paused   := !Cfg["Enabled"]
LastPulse := 0                  ; A_TickCount of last successful pulse (0 = pulse soon)
Waiting   := false              ; true while no W365 session window is present
NextWindowCheck := 0            ; A_TickCount gate for the 5-minute re-check while waiting
StandingDown := false           ; true once real inactivity exceeds GiveUpMin

BuildTray()
SetTimer(Tick, 5000)            ; evaluate every 5s (tight ceiling precision)
Tick()                          ; and once right now
Log("Started v" AppVersion " (VM timeout " Cfg["VmTimeoutMin"] "m, interval " Cfg["IntervalMin"] "m, ceiling " Cfg["MaxMin"] "m, idle gate " Cfg["IdleSec"] "s)")
CheckEnvironment()              ; warn at startup only if a prerequisite is missing

; ============================================================================
;  Core loop
; ============================================================================
Tick(*) {
    global LastPulse, Cfg, Paused, Waiting, NextWindowCheck, StandingDown
    UpdateTip()
    if Paused
        return
    ; If you've been truly away (no real keyboard/mouse input) for a while
    ; AND running on battery, stop pulsing: let the Cloud PC's own policy
    ; lock/disconnect, and let Windows' normal sleep timer finally run out
    ; instead of being reset by our own synthetic input every few minutes.
    ; While plugged into AC there's no battery to drain, so the give-up
    ; never kicks in - keep-alive keeps running regardless of idle time.
    onBattery := !IsOnACPower()
    giveUp := onBattery && (A_TimeIdlePhysical >= Cfg["GiveUpMin"] * 60000)
    if giveUp {
        if !StandingDown {
            Log("On battery with no input for " Cfg["GiveUpMin"] " min - standing down so the system can sleep normally")
            StandingDown := true
            UpdateTip()
        }
        return
    }
    if StandingDown {
        Log(onBattery ? "Input detected - resuming keep-alive" : "Plugged in - resuming keep-alive")
        StandingDown := false
        LastPulse := 0
        Waiting := false
        NextWindowCheck := 0
    }
    elapsed := A_TickCount - LastPulse
    if (elapsed < Cfg["IntervalMin"] * 60000)
        return
    ; It's time to pulse - but only if a W365 session window actually exists.
    if (Waiting && A_TickCount < NextWindowCheck)
        return                                                ; still in the 5-minute back-off
    if !GetTargetHwnd() {
        if !Waiting
            Log("No W365 session window - waiting; re-checking every 5 minutes")
        Waiting := true
        NextWindowCheck := A_TickCount + 300000               ; 5 minutes
        UpdateTip()
        return
    }
    if Waiting {
        Log("W365 session window found - resuming keep-alive")
        Waiting := false
    }
    idleOk := (A_TimeIdlePhysical >= Cfg["IdleSec"] * 1000)   ; physical = ignores our own input
    if (!idleOk && elapsed < Cfg["MaxMin"] * 60000)
        return                                                ; wait for a pause, up to the ceiling
    DoPulse(false)
}

DoPulse(manual) {
    global LastPulse, Cfg
    hwnd := GetTargetHwnd()
    if !hwnd {
        Log("No target window found")
        if manual
            TrayTip("W365 Pulse", "No Cloud PC window found.`nOpen your session, then use Re-detect window.", 0x10)
        return false
    }
    ok   := false
    prev := WinExist("A")
    try {
        if (Cfg["Key"] = "{MouseNudge}") {
            WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
            MouseGetPos(&origX, &origY)
            cx := wx + ww // 2
            cy := wy + wh // 2
            MouseMove(cx, cy, 0)
            MouseMove(cx + 3, cy, 0)
            MouseMove(cx, cy, 0)
            MouseMove(origX, origY, 0)
            ok := true
        } else {
            ForceActivate(hwnd)
            if WinWaitActive("ahk_id " hwnd, , 1) {
                Send(Cfg["Key"])
                Sleep(100)
                ok := true
            } else {
                Log("Activate failed")
            }
        }
    } catch as e {
        Log("Pulse error: " e.Message)
    } finally {
        if (prev && Cfg["Key"] != "{MouseNudge}")
            try WinActivate("ahk_id " prev)
    }
    LastPulse := A_TickCount          ; always advance, so we don't spam on error
    if ok {
        Log("Pulse -> " WinGetTitle("ahk_id " hwnd))
        if (manual || Cfg["Notify"])
            TrayTip("W365 Pulse", "Keep-alive sent.", 0x1)
    }
    UpdateTip()
    return ok
}

; Returns true if the machine is on AC power (plugged in), false if running
; on battery. Desktops/unknown report as "online" (true) so the give-up logic
; never affects a machine with no battery to drain.
IsOnACPower() {
    buf := Buffer(12, 0)
    if !DllCall("GetSystemPowerStatus", "Ptr", buf)
        return true
    return NumGet(buf, 0, "UChar") != 0   ; ACLineStatus: 0=offline(battery) 1=online(AC) 255=unknown
}

; Bypass Windows foreground-lock by attaching our thread's input state to the
; target window's thread before calling SetForegroundWindow. Without this,
; Windows silently ignores SetForegroundWindow while another window has focus.
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

; Finds a window that represents an actual running VM session - not just the
; client app sitting open on its home/device-list screen with no VM connected.
; If you've set an explicit TargetTitle, that's trusted as-is (you know better).
; Otherwise, every visible window of the known client exes is checked and any
; with a generic launcher title (NonSessionTitles) is skipped.
GetTargetHwnd() {
    global Cfg, KnownExes, NonSessionTitles
    list := (Cfg["TargetExe"] != "") ? [Cfg["TargetExe"]] : KnownExes
    for exe in list {
        if (Cfg["TargetTitle"] != "") {
            if (id := WinExist(Cfg["TargetTitle"] " ahk_exe " exe))
                return id
            continue
        }
        for id in WinGetList("ahk_exe " exe) {
            if !DllCall("IsWindowVisible", "ptr", id)
                continue
            title := ""
            try title := WinGetTitle("ahk_id " id)
            if (title = "" || IsLauncherTitle(title))
                continue
            return id
        }
    }
    return 0
}

IsLauncherTitle(title) {
    global NonSessionTitles
    for t in NonSessionTitles
        if (title = t)
            return true
    return false
}

; ============================================================================
;  Tray UI
; ============================================================================
BuildTray() {
    global ActiveIcon
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("W365 Pulse", ShowAbout)
    tray.Add()
    tray.Add("Active", MenuTogglePause)
    tray.Add("Pulse now", (*) => DoPulse(true))
    sub := Menu()
    sub.Add("8 minutes",  SetInterval.Bind(8))
    sub.Add("10 minutes", SetInterval.Bind(10))
    sub.Add("12 minutes", SetInterval.Bind(12))
    tray.Add("Pulse interval", sub)
    global IntervalSub := sub
    tray.Add("Re-detect window", (*) => Redetect())
    tray.Add("Check environment", (*) => CheckEnvironment(true))
    tray.Add()
    tray.Add("Settings...",    ShowSettings)
    tray.Add("Start with Windows", MenuToggleStartup)
    tray.Add("View log...", (*) => ShowLogViewer())
    tray.Add()
    tray.Add("Exit", (*) => ExitApp())
    tray.Default := "Pulse now"
    if FileExist(ActiveIcon)
        TraySetIcon(ActiveIcon)
    RefreshChecks()
}

RefreshChecks() {
    global Cfg, IntervalSub, Paused
    for n in ["8 minutes", "10 minutes", "12 minutes"]
        IntervalSub.Uncheck(n)
    try IntervalSub.Check(Cfg["IntervalMin"] " minutes")
    if StartupRegistered()
        A_TrayMenu.Check("Start with Windows")
    else
        A_TrayMenu.Uncheck("Start with Windows")
    if Paused
        A_TrayMenu.Uncheck("Active")
    else
        A_TrayMenu.Check("Active")
}

UpdateTip() {
    global Paused, LastPulse, ActiveIcon, PausedIcon, WaitingIcon, Waiting, StandingDown
    static CurIcon := ""
    if Paused {
        A_IconTip := "W365 Pulse - Paused"
        if (CurIcon != "p" && FileExist(PausedIcon))
            TraySetIcon(PausedIcon), CurIcon := "p"
        return
    }
    if StandingDown {
        mins := Round(A_TimeIdlePhysical / 60000)
        A_IconTip := "W365 Pulse - standing down (idle " mins " min)`nLetting the system sleep normally - resumes on input"
        if (CurIcon != "s" && FileExist(PausedIcon))
            TraySetIcon(PausedIcon), CurIcon := "s"
        return
    }
    if Waiting {
        A_IconTip := "W365 Pulse - waiting for a session window`nRe-checking every 5 minutes"
        if (CurIcon != "w") {
            ico := FileExist(WaitingIcon) ? WaitingIcon : PausedIcon
            TraySetIcon(ico), CurIcon := "w"
        }
        return
    }
    if (CurIcon != "a" && FileExist(ActiveIcon))
        TraySetIcon(ActiveIcon), CurIcon := "a"
    hwnd := GetTargetHwnd()
    tgt  := hwnd ? WinGetTitle("ahk_id " hwnd) : "no window found"
    ago  := LastPulse ? Round((A_TickCount - LastPulse) / 60000, 1) " min ago" : "pending"
    A_IconTip := "W365 Pulse - Active`nTarget: " tgt "`nLast pulse: " ago
}

; ---- Menu handlers ---------------------------------------------------------
MenuTogglePause(*) {
    global Paused, LastPulse, Cfg, Waiting, NextWindowCheck, StandingDown
    Paused := !Paused
    Cfg["Enabled"] := Paused ? 0 : 1
    SaveConfig()
    if !Paused {
        LastPulse := 0          ; resume -> pulse on next idle gap
        Waiting := false        ; and re-check for the window right away
        NextWindowCheck := 0
        StandingDown := false
    }
    Log(Paused ? "Paused" : "Resumed")
    RefreshChecks()
    UpdateTip()
}

SetInterval(mins, *) {
    global Cfg, LastPulse, NextWindowCheck
    Cfg["IntervalMin"] := mins
    Cfg["MaxMin"]      := Min(mins + 2, Cfg["VmTimeoutMin"] - 1)
    SaveConfig()
    LastPulse := 0
    NextWindowCheck := 0
    Log("Interval set to " mins "m (ceiling " Cfg["MaxMin"] "m)")
    RefreshChecks()
}

Redetect() {
    hwnd := GetTargetHwnd()
    if hwnd
        TrayTip("W365 Pulse", "Found: " WinGetTitle("ahk_id " hwnd) "`n(" WinGetProcessName("ahk_id " hwnd) ")", 0x1)
    else
        TrayTip("W365 Pulse", "No Cloud PC window found.`nOpen the session, or set TargetExe in settings.", 0x10)
    UpdateTip()
}

ShowAbout(*) {
    global AppVersion
    MsgBox(
        "W365 Pulse  v" AppVersion "`n`n"
        . "Keeps a Windows 365 / Remote Desktop session alive by sending a "
        . "harmless keystroke to the session window at regular intervals, "
        . "preventing the host from logging you out due to inactivity.`n`n"
        . "The keystroke is sent directly to the background window "
        . "(no focus stealing) so your work on other monitors is never interrupted.`n`n"
        . "Right-click the tray icon to configure the pulse interval, "
        . "target window, and keep-alive signal.",
        "About W365 Pulse", 0x40)
}

MenuToggleStartup(*) {
    SetStartup(!StartupRegistered())
    RefreshChecks()
}

; ---- Dependency / environment check ----------------------------------------
; Returns true if everything needed is present. On startup it only pops up when
; something is genuinely missing; the tray "Check environment" item passes
; verbose:=true to always show a full status report.
CheckEnvironment(verbose := false) {
    global Cfg
    lines := [], missing := []

    ; 1. AutoHotkey v2 (guaranteed when run as a script, but report it)
    ahkOk := (SubStr(A_AhkVersion, 1, 1) = "2")
    lines.Push((ahkOk ? "[ OK ]  " : "[MISSING]  ") "AutoHotkey v2   (running " A_AhkVersion ")")
    if !ahkOk
        missing.Push("AutoHotkey v2`n        Download: https://www.autohotkey.com/")

    ; 2. A Windows 365 / Remote Desktop client we can keep alive
    pref := PreferredClient()
    if (pref != "")
        lines.Push("[ OK ]  Windows 365 / Remote Desktop client`n             " pref)
    else if (Cfg["TargetExe"] != "" && ProcessExist(Cfg["TargetExe"]))
        lines.Push("[ OK ]  Configured target is running:  " Cfg["TargetExe"])
    else if GetTargetHwnd()
        lines.Push("[ OK ]  A session window is currently open")
    else {
        lines.Push("[MISSING]  No Windows 365 client or session window detected")
        note := (MstscPath() != "")
            ? "`n        (Classic Remote Desktop 'mstsc.exe' is present, but Windows 365`n         normally uses the Windows App or the browser.)"
            : ""
        missing.Push("A Windows 365 session to keep alive. Either:`n"
            . "        - Install the Windows App:  https://aka.ms/windowsapp`n"
            . "        - Or use the browser:  https://windows.cloud.microsoft`n"
            . "          then open your Cloud PC and choose that window in`n"
            . "          Settings > Target window." note)
    }

    for ln in lines
        Log("Env: " StrReplace(StrReplace(ln, "`n", " "), "  ", " "))

    if missing.Length {
        msg := "W365 Pulse checked its prerequisites and something is missing:`n`n"
        for m in missing
            msg .= "  -  " m "`n`n"
        msg .= "The app will keep running and start working as soon as the`nrequirement is met (use 'Re-detect window' once your session is open)."
        MsgBox(msg, "W365 Pulse - missing prerequisites", 0x30)
        return false
    }

    if verbose {
        report := ""
        for ln in lines
            report .= ln "`n`n"
        report .= "Everything needed is in place."
        MsgBox(report, "W365 Pulse - Environment check", 0x40)
    }
    return true
}

PreferredClient() {
    ; running W365 / RDP client process?
    for exe in ["msrdc.exe", "Windows365.exe"]
        if ProcessExist(exe)
            return exe "  (running)"
    ; installed on disk?
    for v in ["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)", "LocalAppData"] {
        base := EnvGet(v)
        if (base = "")
            continue
        for sub in ["\Remote Desktop\msrdc.exe", "\Microsoft\Remote Desktop\msrdc.exe"]
            if FileExist(base sub)
                return base sub
    }
    ; new Windows App (MSIX) registered via App Paths
    for root in ["HKLM", "HKCU"] {
        try {
            val := RegRead(root "\Software\Microsoft\Windows\CurrentVersion\App Paths\msrdc.exe")
            if (val != "")
                return val
        }
    }
    return ""
}

MstscPath() {
    p := A_WinDir "\System32\mstsc.exe"
    return FileExist(p) ? p : ""
}

; ---- Settings GUI ----------------------------------------------------------
ShowSettings(*) {
    global Cfg, Paused, KeyVals, KeyLabels
    static G := ""
    if (G) {
        try {
            G.Show()
            return
        }
    }

    choices := ListOpenWindows()           ; array of Map("text","exe","title")

    G := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "W365 Pulse v" AppVersion " - Settings")
    G.BackColor := "FFFFFF"
    G.SetFont("s10", "Segoe UI")

    hdr := G.Add("Text", "x0 y0 w470 h52 +0x200 Center Background0F897B cFFFFFF", "W365 Pulse")
    hdr.SetFont("s15 Bold", "Segoe UI")

    ; --- Timing ---
    G.Add("GroupBox", "x16 y62 w438 h194", "Timing")
    G.Add("Text", "x32 y96 w122 +0x200", "VM locks after")
    G.Add("Edit", "x158 y93 w56")
    uVmTimeout := G.Add("UpDown", "Range3-120", Cfg["VmTimeoutMin"])
    G.Add("Text", "x222 y96 w224 +0x200", "minutes (your VM's timeout)")
    G.Add("Text", "x32 y128 w122 +0x200", "Pulse every")
    G.Add("Edit", "x158 y125 w56")
    uInterval := G.Add("UpDown", "Range5-13", Cfg["IntervalMin"])
    G.Add("Text", "x222 y128 w224 +0x200", "minutes (typical gap)")
    G.Add("Text", "x32 y160 w122 +0x200", "Force a pulse by")
    G.Add("Edit", "x158 y157 w56")
    uMax := G.Add("UpDown", "Range6-119", Cfg["MaxMin"])
    G.Add("Text", "x222 y160 w224 +0x200", "minutes (hard ceiling)")
    G.Add("Text", "x32 y192 w122 +0x200", "Only when idle for")
    G.Add("Edit", "x158 y189 w56")
    uIdle := G.Add("UpDown", "Range1-60", Cfg["IdleSec"])
    G.Add("Text", "x222 y192 w224 +0x200", "seconds (idle gap)")
    G.Add("Text", "x32 y224 w122 +0x200", "Give up after")
    G.Add("Edit", "x158 y221 w56")
    uGiveUp := G.Add("UpDown", "Range5-120", Cfg["GiveUpMin"])
    G.Add("Text", "x222 y224 w224 +0x200", "minutes (battery only)")

    ; --- Target window ---
    G.Add("GroupBox", "x16 y268 w438 h86", "Target window")
    items := ["Auto-detect (recommended)"]
    for c in choices
        items.Push(c["text"])
    ddlWin := G.Add("DropDownList", "x32 y298 w322", items)
    G.Add("Button", "x360 y297 w92 h25", "Refresh list").OnEvent("Click", RefreshList)
    G.Add("Text", "x32 y329 w414 cGray", "Leave on Auto-detect unless it grabs the wrong window.")
    ddlWin.Choose(InitialWindowIndex(choices))

    ; --- Keep-alive key ---
    G.Add("GroupBox", "x16 y366 w438 h60", "Keep-alive signal")
    G.Add("Text", "x32 y397 w120 +0x200", "Send")
    ddlKey := G.Add("DropDownList", "x158 y394 w200", KeyLabels)
    ddlKey.Choose(KeyIndex(Cfg["Key"]))

    ; --- Behavior ---
    G.Add("GroupBox", "x16 y438 w438 h106", "Behavior")
    cbNotify  := G.Add("Checkbox", "x32 y468 w400" (Cfg["Notify"] ? " Checked" : ""), "Show a notification on each pulse")
    cbStartup := G.Add("Checkbox", "x32 y494 w400" (StartupRegistered() ? " Checked" : ""), "Start automatically with Windows")
    cbActive  := G.Add("Checkbox", "x32 y520 w400" (Paused ? "" : " Checked"), "Active (uncheck to pause keep-alive)")

    ; --- Buttons ---
    G.Add("Button", "x16 y558 w92 h30", "Test now").OnEvent("Click", (*) => DoPulse(true))
    G.Add("Button", "x116 y558 w84 h30", "Reset").OnEvent("Click", ResetDefaults)
    G.Add("Button", "x286 y558 w78 h30", "Cancel").OnEvent("Click", (*) => CloseGui())
    G.Add("Button", "x370 y558 w84 h30 Default", "Save").OnEvent("Click", SaveBtn)

    G.OnEvent("Close", (*) => CloseGui())
    G.OnEvent("Escape", (*) => CloseGui())
    G.Show("w470 h602")

    CloseGui() {
        G.Destroy()
        G := ""
    }

    RefreshList(*) {
        choices := ListOpenWindows()
        newItems := ["Auto-detect (recommended)"]
        for c in choices
            newItems.Push(c["text"])
        ddlWin.Delete()
        ddlWin.Add(newItems)
        ddlWin.Choose(InitialWindowIndex(choices))
    }

    ResetDefaults(*) {
        uVmTimeout.Value := 15
        uInterval.Value  := 8
        uMax.Value       := 9
        uIdle.Value      := 4
        uGiveUp.Value    := 20
        ddlKey.Choose(1)
        ddlWin.Choose(1)
        cbNotify.Value  := 0
    }

    SaveBtn(*) {
        global Cfg, Paused, KeyVals, LastPulse, NextWindowCheck, StandingDown
        vt  := uVmTimeout.Value
        iv  := uInterval.Value
        mx  := uMax.Value
        idl := uIdle.Value
        gu  := uGiveUp.Value
        if (mx <= iv) {
            MsgBox("The hard ceiling must be larger than the pulse interval.", "Check settings", 0x30)
            return
        }
        if (mx >= vt) {
            MsgBox("The hard ceiling must stay below your VM's lock/timeout (" vt " min).", "Check settings", 0x30)
            return
        }
        Cfg["VmTimeoutMin"] := vt
        Cfg["IntervalMin"] := iv
        Cfg["MaxMin"]      := mx
        Cfg["IdleSec"]     := idl
        Cfg["GiveUpMin"]   := gu
        Cfg["Key"]         := KeyVals[ddlKey.Value]
        Cfg["Notify"]      := cbNotify.Value
        sel := ddlWin.Value
        if (sel <= 1) {
            Cfg["TargetExe"]   := ""
            Cfg["TargetTitle"] := ""
        } else {
            Cfg["TargetExe"]   := choices[sel - 1]["exe"]
            Cfg["TargetTitle"] := ""
        }
        Cfg["Enabled"] := cbActive.Value
        Paused := !cbActive.Value
        SaveConfig()
        SetStartup(cbStartup.Value)
        LastPulse := 0
        NextWindowCheck := 0
        StandingDown := false
        RefreshChecks()
        UpdateTip()
        Log("Settings saved (VM timeout " vt "m, interval " iv "m, ceiling " mx "m, idle " idl "s, give-up " gu "m, key " Cfg["Key"] ", target " (Cfg["TargetExe"] = "" ? "auto" : Cfg["TargetExe"]) ")")
        CloseGui()
        TrayTip("W365 Pulse", "Settings saved.", 0x1)
    }
}

ListOpenWindows() {
    out := []
    seen := Map()
    for id in WinGetList() {
        title := WinGetTitle("ahk_id " id)
        if (title = "" || !DllCall("IsWindowVisible", "ptr", id))
            continue
        exe := ""
        try exe := WinGetProcessName("ahk_id " id)
        if (exe = "" || exe = "AutoHotkey64.exe" || exe = "AutoHotkey32.exe")
            continue
        text := title "  -  " exe
        if seen.Has(text)
            continue
        seen[text] := 1
        out.Push(Map("text", text, "exe", exe, "title", title))
    }
    return out
}

InitialWindowIndex(choices) {
    global Cfg
    if (Cfg["TargetExe"] = "")
        return 1
    for i, c in choices
        if (c["exe"] = Cfg["TargetExe"])
            return i + 1
    return 1
}

KeyIndex(val) {
    global KeyVals
    for i, v in KeyVals
        if (v = val)
            return i
    return 1
}

; ============================================================================
;  Log viewer - drill-down by month/week/day/hour, newest entries first
; ============================================================================
ShowLogViewer(*) {
    global LogFile, AppVersion
    static G := ""
    if (G) {
        try {
            G.Show()
            return
        }
    }

    entries := ParseLogEntries()
    groups  := BuildLogGroups(entries)
    nodeEntries := Map()   ; assigned in BuildAndSelectToday(); declared here so it's
                            ; a shared closure across OnSelect/RefreshViewer (siblings)

    G := Gui("-MinimizeBox -MaximizeBox", "W365 Pulse v" AppVersion " - Log Viewer")
    G.SetFont("s10", "Segoe UI")

    TV := G.Add("TreeView", "x10 y10 w280 h480")
    TV.OnEvent("ItemSelect", OnSelect)

    LV := G.Add("ListView", "x300 y10 w560 h480", ["Time", "Message"])
    LV.ModifyCol(1, 140)
    LV.ModifyCol(2, 405)

    BuildAndSelectToday()

    G.Add("Button", "x10 y500 w90 h28", "Refresh").OnEvent("Click", RefreshViewer)
    G.Add("Button", "x108 y500 w120 h28", "Open raw file").OnEvent("Click", (*) => Run('notepad.exe "' LogFile '"'))
    G.Add("Button", "x780 y500 w80 h28", "Close").OnEvent("Click", (*) => CloseViewer())

    G.OnEvent("Close", (*) => CloseViewer())
    G.OnEvent("Escape", (*) => CloseViewer())

    G.Show("w870 h540")

    OnSelect(ctrl, item) {
        DisplayLogEntries(nodeEntries.Has(item) ? nodeEntries[item] : [])
    }

    DisplayLogEntries(idxArr) {
        LV.Delete()
        n := idxArr.Length
        loop n {
            e := entries[idxArr[n - A_Index + 1]]   ; reverse -> newest first
            LV.Add(, e["ts"], e["msg"])
        }
    }

    ; Defaults the view to "By month", expanded and selected on today's day
    ; (falling back to today's month, then today's year, then "All entries"
    ; if today has no log lines yet).
    BuildAndSelectToday() {
        today := FormatTime(, "yyyy-MM-dd")
        result := PopulateLogTree(TV, entries, groups, SubStr(today, 1, 4), SubStr(today, 6, 2), today)
        nodeEntries := result["nodeEntries"]
        target := result["todayDayId"] ? result["todayDayId"]
            : result["todayMonthId"] ? result["todayMonthId"]
            : result["todayYearId"] ? result["todayYearId"] : 0
        if target {
            TV.Modify(target, "Select Vis")
            DisplayLogEntries(nodeEntries[target])
        } else {
            DisplayLogEntries(entries.Length ? AllIndices(entries.Length) : [])
        }
    }

    RefreshViewer(*) {
        entries := ParseLogEntries()
        groups  := BuildLogGroups(entries)
        TV.Delete()
        BuildAndSelectToday()
    }

    CloseViewer() {
        G.Destroy()
        G := ""
    }
}

; Parses the log file into an array of Maps: ts, date, y, m, d, h, week, msg.
; "week" is the ISO year+week ("YYYYWW") used for the by-week drill-down.
ParseLogEntries() {
    global LogFile
    entries := []
    if !FileExist(LogFile)
        return entries
    content := ""
    try content := FileRead(LogFile, "UTF-8")
    for line in StrSplit(content, "`n", "`r") {
        if (StrLen(line) < 21)
            continue
        ts := SubStr(line, 1, 19)
        if !RegExMatch(ts, "^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$")
            continue
        y  := SubStr(ts, 1, 4)
        mo := SubStr(ts, 6, 2)
        d  := SubStr(ts, 9, 2)
        h  := SubStr(ts, 12, 2)
        dateKey := y "-" mo "-" d
        wk := FormatTime(y . mo . d, "YWeek")
        entries.Push(Map("ts", ts, "date", dateKey, "y", y, "m", mo, "d", d, "h", h,
                          "week", wk, "msg", SubStr(line, 22)))
    }
    return entries
}

; Groups entry indices into two nested Maps for the two drill-down paths:
;   byMonth[year][month][date][hour]  -> array of entry indices
;   byWeek [isoWeek][date][hour]      -> array of entry indices
; weekRange[isoWeek] tracks the min/max date seen, for the week's display label.
BuildLogGroups(entries) {
    byMonth := Map()
    byWeek  := Map()
    weekRange := Map()
    for idx, e in entries {
        y := e["y"], mo := e["m"], dateKey := e["date"], h := e["h"], wk := e["week"]

        if !byMonth.Has(y)
            byMonth[y] := Map()
        if !byMonth[y].Has(mo)
            byMonth[y][mo] := Map()
        if !byMonth[y][mo].Has(dateKey)
            byMonth[y][mo][dateKey] := Map()
        if !byMonth[y][mo][dateKey].Has(h)
            byMonth[y][mo][dateKey][h] := []
        byMonth[y][mo][dateKey][h].Push(idx)

        if !byWeek.Has(wk)
            byWeek[wk] := Map()
        if !byWeek[wk].Has(dateKey)
            byWeek[wk][dateKey] := Map()
        if !byWeek[wk][dateKey].Has(h)
            byWeek[wk][dateKey][h] := []
        byWeek[wk][dateKey][h].Push(idx)

        if !weekRange.Has(wk)
            weekRange[wk] := Map("min", dateKey, "max", dateKey)
        else {
            ; StrCompare, not "<"/">" - AHK tries (and fails) to coerce
            ; dash-containing date strings like "2026-06-15" to numbers.
            if (StrCompare(dateKey, weekRange[wk]["min"]) < 0)
                weekRange[wk]["min"] := dateKey
            if (StrCompare(dateKey, weekRange[wk]["max"]) > 0)
                weekRange[wk]["max"] := dateKey
        }
    }
    return Map("byMonth", byMonth, "byWeek", byWeek, "weekRange", weekRange)
}

; Builds the TreeView (an "All entries" node, then "By month" Year/Month/Day/Hour,
; then "By week" Week/Day/Hour) and returns a Map of TreeView item ID -> array of
; entry indices for that node's whole subtree, used to populate the ListView.
; todayY/todayMo/todayDate (e.g. "2026"/"06"/"2026-06-18") let the caller default
; the view to today's day under "By month"; todayDayId/todayMonthId/todayYearId
; in the return value are 0 if no log entries fall on that day/month/year.
PopulateLogTree(TV, entries, groups, todayY := "", todayMo := "", todayDate := "") {
    nodeEntries := Map()
    byMonth   := groups["byMonth"]
    byWeek    := groups["byWeek"]
    weekRange := groups["weekRange"]
    todayYearId := 0, todayMonthId := 0, todayDayId := 0

    allId := TV.Add("All entries (" entries.Length ")", 0)
    nodeEntries[allId] := AllIndices(entries.Length)

    rootMonth := TV.Add("By month", 0)
    for y in SortedKeysDesc(byMonth) {
        yEntries := []
        yId := TV.Add(y, rootMonth)
        if (y = todayY)
            todayYearId := yId
        for mo in SortedKeysDesc(byMonth[y]) {
            moEntries := []
            moId := TV.Add(FormatTime(y . mo . "01", "MMMM yyyy"), yId)
            if (y = todayY && mo = todayMo)
                todayMonthId := moId
            for dateKey in SortedKeysDesc(byMonth[y][mo]) {
                dEntries := []
                dId := TV.Add(FormatTime(StrReplace(dateKey, "-", ""), "ddd, MMM d"), moId)
                if (dateKey = todayDate)
                    todayDayId := dId
                for h in SortedKeysDesc(byMonth[y][mo][dateKey]) {
                    idxArr := byMonth[y][mo][dateKey][h]
                    hId := TV.Add(h ":00", dId)
                    nodeEntries[hId] := idxArr
                    dEntries.Push(idxArr*)
                }
                nodeEntries[dId] := dEntries
                moEntries.Push(dEntries*)
            }
            nodeEntries[moId] := moEntries
            yEntries.Push(moEntries*)
        }
        nodeEntries[yId] := yEntries
    }

    rootWeek := TV.Add("By week", 0)
    for wk in SortedKeysDesc(byWeek) {
        wkEntries := []
        wkYear := SubStr(wk, 1, 4)
        wkNum  := SubStr(wk, 5, 2)
        rng := weekRange[wk]
        label := "Week " wkNum ", " wkYear "  (" FormatTime(StrReplace(rng["min"], "-", ""), "MMM d")
            . " - " FormatTime(StrReplace(rng["max"], "-", ""), "MMM d") ")"
        wkId := TV.Add(label, rootWeek)
        for dateKey in SortedKeysDesc(byWeek[wk]) {
            dEntries := []
            dId := TV.Add(FormatTime(StrReplace(dateKey, "-", ""), "ddd, MMM d"), wkId)
            for h in SortedKeysDesc(byWeek[wk][dateKey]) {
                idxArr := byWeek[wk][dateKey][h]
                hId := TV.Add(h ":00", dId)
                nodeEntries[hId] := idxArr
                dEntries.Push(idxArr*)
            }
            nodeEntries[dId] := dEntries
            wkEntries.Push(dEntries*)
        }
        nodeEntries[wkId] := wkEntries
    }

    return Map("nodeEntries", nodeEntries, "todayYearId", todayYearId,
        "todayMonthId", todayMonthId, "todayDayId", todayDayId)
}

AllIndices(n) {
    arr := []
    loop n
        arr.Push(A_Index)
    return arr
}

; Returns the keys of a Map sorted newest/largest-first (plain string descending
; sort is correct here because every key is a zero-padded, fixed-width string -
; year "2026", month/day/hour "06", or ISO week "202625").
SortedKeysDesc(m) {
    keys := []
    for k, v in m
        keys.Push(k)
    return SortDesc(keys)
}

SortDesc(arr) {
    n := arr.Length
    loop n - 1 {
        i := A_Index + 1
        key := arr[i]
        j := i - 1
        ; StrCompare, not "<" - see note in BuildLogGroups for why.
        while (j >= 1 && StrCompare(arr[j], key) < 0) {
            arr[j + 1] := arr[j]
            j--
        }
        arr[j + 1] := key
    }
    return arr
}

; ============================================================================
;  Persistence / startup / logging
; ============================================================================
LoadConfig() {
    global Cfg, ConfigFile
    if !FileExist(ConfigFile) {
        SaveConfig()
        return
    }
    for k in ["VmTimeoutMin", "IntervalMin", "MaxMin", "IdleSec", "GiveUpMin", "Enabled", "Notify"]
        Cfg[k] := Integer(IniRead(ConfigFile, "Settings", k, Cfg[k]))
    for k in ["TargetExe", "TargetTitle", "Key"]
        Cfg[k] := IniRead(ConfigFile, "Settings", k, Cfg[k])
}

SaveConfig() {
    global Cfg, ConfigFile
    for k, v in Cfg
        IniWrite(v, ConfigFile, "Settings", k)
}

StartupRegistered() {
    try return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "W365Pulse") != ""
    catch
        return false
}

SetStartup(on) {
    key := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
    if on {
        cmd := A_IsCompiled ? ('"' A_ScriptFullPath '"') : ('"' A_AhkPath '" "' A_ScriptFullPath '"')
        RegWrite(cmd, "REG_SZ", key, "W365Pulse")
        Log("Registered to start with Windows")
    } else {
        try RegDelete(key, "W365Pulse")
        Log("Removed from Windows startup")
    }
}

Log(msg) {
    global LogFile
    try {
        if (FileExist(LogFile) && FileGetSize(LogFile) > 1048576)
            FileDelete(LogFile)
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " msg "`n", LogFile, "UTF-8")
    }
}
