#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
SetTitleMatchMode(2)            ; window title = "contains"

; ============================================================================
;  W365 Pulse v1.2.1 - keeps a Windows 365 / Remote Desktop session from
;  logging out by sending a no-op keystroke directly to the session window
;  (ControlSend, no focus steal). Designed for a setup where the Cloud PC
;  window lives on a dedicated screen, always visible.
; ============================================================================
AppVersion := "1.2.1"

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
    "IntervalMin", 12,          ; soft target: pulse roughly this often, on an idle gap
    "MaxMin",      14,          ; hard ceiling: pulse even if you're actively typing (< 15)
    "IdleSec",     4,           ; only pulse after this many seconds of no physical input
    "TargetExe",   "",          ; empty = auto-detect among the known clients below
    "TargetTitle", "",          ; optional title filter to disambiguate multiple windows
    "Key",         "{F15}",     ; harmless key sent into the session
    "Enabled",     1,
    "Notify",      0)           ; 1 = show a tray balloon on every pulse
KnownExes := ["msrdc.exe", "Windows365.exe", "mstsc.exe"]
KeyVals   := ["{F15}", "{F14}", "{F13}", "{Shift}", "{MouseNudge}"]
KeyLabels := ["F15 - invisible (recommended)", "F14", "F13", "Shift tap", "Mouse nudge"]

LoadConfig()
Paused   := !Cfg["Enabled"]
LastPulse := 0                  ; A_TickCount of last successful pulse (0 = pulse soon)
Waiting   := false              ; true while no W365 session window is present
NextWindowCheck := 0            ; A_TickCount gate for the 5-minute re-check while waiting

BuildTray()
SetTimer(Tick, 20000)           ; evaluate every 20s
Tick()                          ; and once right now
Log("Started v" AppVersion " (interval " Cfg["IntervalMin"] "m, ceiling " Cfg["MaxMin"] "m, idle gate " Cfg["IdleSec"] "s)")
CheckEnvironment()              ; warn at startup only if a prerequisite is missing

; ============================================================================
;  Core loop
; ============================================================================
Tick(*) {
    global LastPulse, Cfg, Paused, Waiting, NextWindowCheck
    UpdateTip()
    if Paused
        return
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
    ok := false
    try {
        SendKeepAlive(Cfg["Key"], hwnd)
        ok := true
    } catch as e {
        Log("Pulse error: " e.Message)
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

GetTargetHwnd() {
    global Cfg, KnownExes
    list := (Cfg["TargetExe"] != "") ? [Cfg["TargetExe"]] : KnownExes
    for exe in list {
        crit := (Cfg["TargetTitle"] != "") ? (Cfg["TargetTitle"] " ahk_exe " exe) : ("ahk_exe " exe)
        if (id := WinExist(crit))
            return id
    }
    return 0
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
    tray.Add("Open log file",  (*) => Run('notepad.exe "' LogFile '"'))
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
    global Paused, LastPulse, ActiveIcon, PausedIcon, WaitingIcon, Waiting
    static CurIcon := ""
    if Paused {
        A_IconTip := "W365 Pulse - Paused"
        if (CurIcon != "p" && FileExist(PausedIcon))
            TraySetIcon(PausedIcon), CurIcon := "p"
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
    global Paused, LastPulse, Cfg, Waiting, NextWindowCheck
    Paused := !Paused
    Cfg["Enabled"] := Paused ? 0 : 1
    SaveConfig()
    if !Paused {
        LastPulse := 0          ; resume -> pulse on next idle gap
        Waiting := false        ; and re-check for the window right away
        NextWindowCheck := 0
    }
    Log(Paused ? "Paused" : "Resumed")
    RefreshChecks()
    UpdateTip()
}

SetInterval(mins, *) {
    global Cfg, LastPulse, NextWindowCheck
    Cfg["IntervalMin"] := mins
    Cfg["MaxMin"]      := Min(mins + 2, 14)
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

; ControlSend posts keystrokes directly to the window's message queue without
; needing focus — RDP/W365 clients forward these to the remote session, which
; resets the host's idle timer. This avoids the foreground-lock problem where
; WinActivate is blocked while the user types on another monitor.
SendKeepAlive(k, hwnd) {
    if (k = "{MouseNudge}") {
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
        MouseGetPos(&origX, &origY)
        cx := wx + ww // 2
        cy := wy + wh // 2
        MouseMove(cx, cy, 0)
        MouseMove(cx + 3, cy, 0)
        MouseMove(cx, cy, 0)
        MouseMove(origX, origY, 0)
    } else {
        ControlSend(k, , "ahk_id " hwnd)
    }
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
    G.Add("GroupBox", "x16 y62 w438 h130", "Timing")
    G.Add("Text", "x32 y96 w122 +0x200", "Pulse every")
    G.Add("Edit", "x158 y93 w56")
    uInterval := G.Add("UpDown", "Range5-13", Cfg["IntervalMin"])
    G.Add("Text", "x222 y96 w224 +0x200", "minutes (typical gap)")
    G.Add("Text", "x32 y128 w122 +0x200", "Force a pulse by")
    G.Add("Edit", "x158 y125 w56")
    uMax := G.Add("UpDown", "Range6-14", Cfg["MaxMin"])
    G.Add("Text", "x222 y128 w224 +0x200", "minutes (hard ceiling, must be < 15)")
    G.Add("Text", "x32 y160 w122 +0x200", "Only when idle for")
    G.Add("Edit", "x158 y157 w56")
    uIdle := G.Add("UpDown", "Range1-60", Cfg["IdleSec"])
    G.Add("Text", "x222 y160 w224 +0x200", "seconds (avoids interrupting typing)")

    ; --- Target window ---
    G.Add("GroupBox", "x16 y204 w438 h86", "Target window")
    items := ["Auto-detect (recommended)"]
    for c in choices
        items.Push(c["text"])
    ddlWin := G.Add("DropDownList", "x32 y234 w322", items)
    G.Add("Button", "x360 y233 w92 h25", "Refresh list").OnEvent("Click", RefreshList)
    G.Add("Text", "x32 y265 w414 cGray", "Leave on Auto-detect unless it grabs the wrong window.")
    ddlWin.Choose(InitialWindowIndex(choices))

    ; --- Keep-alive key ---
    G.Add("GroupBox", "x16 y302 w438 h60", "Keep-alive signal")
    G.Add("Text", "x32 y333 w120 +0x200", "Send")
    ddlKey := G.Add("DropDownList", "x158 y330 w200", KeyLabels)
    ddlKey.Choose(KeyIndex(Cfg["Key"]))

    ; --- Behavior ---
    G.Add("GroupBox", "x16 y374 w438 h106", "Behavior")
    cbNotify  := G.Add("Checkbox", "x32 y404 w400" (Cfg["Notify"] ? " Checked" : ""), "Show a notification on each pulse")
    cbStartup := G.Add("Checkbox", "x32 y430 w400" (StartupRegistered() ? " Checked" : ""), "Start automatically with Windows")
    cbActive  := G.Add("Checkbox", "x32 y456 w400" (Paused ? "" : " Checked"), "Active (uncheck to pause keep-alive)")

    ; --- Buttons ---
    G.Add("Button", "x16 y494 w92 h30", "Test now").OnEvent("Click", (*) => DoPulse(true))
    G.Add("Button", "x116 y494 w84 h30", "Reset").OnEvent("Click", ResetDefaults)
    G.Add("Button", "x286 y494 w78 h30", "Cancel").OnEvent("Click", (*) => CloseGui())
    G.Add("Button", "x370 y494 w84 h30 Default", "Save").OnEvent("Click", SaveBtn)

    G.OnEvent("Close", (*) => CloseGui())
    G.OnEvent("Escape", (*) => CloseGui())
    G.Show("w470 h538")

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
        uInterval.Value := 12
        uMax.Value      := 14
        uIdle.Value     := 4
        ddlKey.Choose(1)
        ddlWin.Choose(1)
        cbNotify.Value  := 0
    }

    SaveBtn(*) {
        global Cfg, Paused, KeyVals, LastPulse, NextWindowCheck
        iv  := uInterval.Value
        mx  := uMax.Value
        idl := uIdle.Value
        if (mx <= iv) {
            MsgBox("The hard ceiling must be larger than the pulse interval.", "Check settings", 0x30)
            return
        }
        if (mx >= 15) {
            MsgBox("The hard ceiling must stay below 15 minutes.", "Check settings", 0x30)
            return
        }
        Cfg["IntervalMin"] := iv
        Cfg["MaxMin"]      := mx
        Cfg["IdleSec"]     := idl
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
        RefreshChecks()
        UpdateTip()
        Log("Settings saved (interval " iv "m, ceiling " mx "m, idle " idl "s, key " Cfg["Key"] ", target " (Cfg["TargetExe"] = "" ? "auto" : Cfg["TargetExe"]) ")")
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
;  Persistence / startup / logging
; ============================================================================
LoadConfig() {
    global Cfg, ConfigFile
    if !FileExist(ConfigFile) {
        SaveConfig()
        return
    }
    for k in ["IntervalMin", "MaxMin", "IdleSec", "Enabled", "Notify"]
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
