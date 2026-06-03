#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
SetTitleMatchMode(2)            ; window title = "contains"

; ============================================================================
;  W365 Pulse - keeps a Windows 365 / Remote Desktop session from logging out
;  by briefly focusing its window during an idle gap and sending a no-op key
;  (F15) over the connection, which resets the host's idle timer. Designed for
;  a setup where the Cloud PC window lives on a dedicated screen, always visible.
; ============================================================================

; ---- Paths -----------------------------------------------------------------
ConfigDir  := A_AppData "\W365Pulse"
ConfigFile := ConfigDir "\config.ini"
LogFile    := ConfigDir "\w365pulse.log"
ActiveIcon := A_ScriptDir "\W365Pulse.ico"
PausedIcon := A_ScriptDir "\W365Pulse_paused.ico"
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

BuildTray()
SetTimer(Tick, 20000)           ; evaluate every 20s
Tick()                          ; and once right now
Log("Started (interval " Cfg["IntervalMin"] "m, ceiling " Cfg["MaxMin"] "m, idle gate " Cfg["IdleSec"] "s)")

; ============================================================================
;  Core loop
; ============================================================================
Tick(*) {
    global LastPulse, Cfg, Paused
    UpdateTip()
    if Paused
        return
    elapsed := A_TickCount - LastPulse
    soft := Cfg["IntervalMin"] * 60000
    hard := Cfg["MaxMin"]      * 60000
    if (elapsed < soft)
        return
    idleOk := (A_TimeIdlePhysical >= Cfg["IdleSec"] * 1000)   ; physical = ignores our own input
    if (!idleOk && elapsed < hard)
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
    prev   := WinExist("A")
    minmax := WinGetMinMax("ahk_id " hwnd)      ; -1 = minimized
    try {
        if (minmax = -1)
            WinRestore("ahk_id " hwnd)
        WinActivate("ahk_id " hwnd)
        if !WinWaitActive("ahk_id " hwnd, , 2) {
            Log("Activate timed out")
            return false
        }
        SendKeepAlive(Cfg["Key"])
        Sleep(150)
    } catch as e {
        Log("Pulse error: " e.Message)
        return false
    } finally {
        if (minmax = -1)                         ; leave it as we found it
            WinMinimize("ahk_id " hwnd)
        else if prev
            try WinActivate("ahk_id " prev)      ; hand focus back to your work
    }
    LastPulse := A_TickCount
    Log("Pulse -> " WinGetTitle("ahk_id " hwnd))
    if (manual || Cfg["Notify"])
        TrayTip("W365 Pulse", "Keep-alive sent.", 0x1)
    UpdateTip()
    return true
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
    tray.Add("W365 Pulse", (*) => "")
    tray.Disable("W365 Pulse")
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
    global Paused, LastPulse, ActiveIcon, PausedIcon
    static CurIcon := ""
    if Paused {
        A_IconTip := "W365 Pulse - Paused"
        if (CurIcon != "p" && FileExist(PausedIcon)) {
            TraySetIcon(PausedIcon), CurIcon := "p"
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
    global Paused, LastPulse, Cfg
    Paused := !Paused
    Cfg["Enabled"] := Paused ? 0 : 1
    SaveConfig()
    if !Paused
        LastPulse := 0          ; resume -> pulse on next idle gap
    Log(Paused ? "Paused" : "Resumed")
    RefreshChecks()
    UpdateTip()
}

SetInterval(mins, *) {
    global Cfg, LastPulse
    Cfg["IntervalMin"] := mins
    Cfg["MaxMin"]      := Min(mins + 2, 14)
    SaveConfig()
    LastPulse := 0
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

MenuToggleStartup(*) {
    SetStartup(!StartupRegistered())
    RefreshChecks()
}

SendKeepAlive(k) {
    if (k = "{MouseNudge}") {
        MouseMove(3, 0, 0, "R")
        MouseMove(-3, 0, 0, "R")
    } else {
        Send(k)
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

    G := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "W365 Pulse - Settings")
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
        global Cfg, Paused, KeyVals, LastPulse
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
