#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
; CursorDrop v4
;
; Drag files or Ctrl+V clipboard images → SCP to remote
; .cursor-drop-files/ → auto-paste absolute path into Claude Code.
; ============================================================================

; ----- Config ---------------------------------------------------------------
global CFG := {
    defW:           160,
    defH:           52,
    minW:           100,
    minH:           40,
    maxW:           500,
    maxH:           250,
    resizeGrip:     8,
    remoteSubdir:   ".cursor-drop-files",
    logFile:        A_ScriptDir . "\CursorDrop.log",
    settingsFile:   A_ScriptDir . "\CursorDrop.ini",
    sshTimeout:     30,
    clipDir:        A_Temp . "\CursorDrop_clips",
    watchDir:       EnvGet("USERPROFILE") . "\CursorDrop",
    videoFPS:       1,
    videoMaxSec:    30,
    videoExts:      "mp4,mov,webm,avi,mkv,wmv"
}

; Auto dark/light
global isDarkMode := DetectDarkMode()

DetectDarkMode() {
    try {
        val := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
        return (val = 0)
    } catch {
        return true
    }
}

global DARK := {
    bg: "222222", text: "E0E0E0", sub: "888888",
    hoverBg: "1B3328", hoverText: "7FD4A0",
    readBg: "2A2235", readText: "C4A8E0", readSub: "9A7DBF",
    uploadBg: "2E2818", uploadText: "E8C86A", uploadSub: "BFA44E",
    successBg: "1B3328", successText: "7FD4A0", successSub: "5AA87A",
    errorBg: "351E1E", errorText: "E87070", errorSub: "C05050"
}

global LIGHT := {
    bg: "FAFAFA", text: "222222", sub: "999999",
    hoverBg: "E8F5EC", hoverText: "2E8B4E",
    readBg: "F0E8F8", readText: "7B3FA0", readSub: "9A7DBF",
    uploadBg: "FFF5E0", uploadText: "B88A20", uploadSub: "D4A830",
    successBg: "E8F5EC", successText: "2E8B4E", successSub: "5AA87A",
    errorBg: "FDE8E8", errorText: "C03030", errorSub: "D05050"
}

global COLORS := isDarkMode ? DARK : LIGHT

; Editors
global EDITORS := [
    { exe: "Cursor.exe",              appData: "Cursor" },
    { exe: "Code.exe",                appData: "Code" },
    { exe: "Code - Insiders.exe",     appData: "Code - Insiders" }
]

global isHovering := false
global isBusy := false
global isResizing := false
global isDragging := false
global isPinned := true
global pinOffsetX := -24
global pinOffsetY := -70
global resizeEdge := ""
global resizeStartX := 0
global resizeStartY := 0
global resizeStartW := 0
global resizeStartH := 0
global resizeStartPosX := 0
global resizeStartPosY := 0

DirCreate(CFG.clipDir)
DirCreate(CFG.watchDir)

global watchKnownFiles := Map()

LoadSettings()
ScanWatchFolder()

; ============================================================================
; Settings
; ============================================================================
LoadSettings() {
    global CFG, isPinned, pinOffsetX, pinOffsetY, isDarkMode, COLORS, DARK, LIGHT
    CFG.zoneW := CFG.defW
    CFG.zoneH := CFG.defH
    CFG.savedX := ""
    CFG.savedY := ""
    if (!FileExist(CFG.settingsFile))
        return
    try {
        w := IniRead(CFG.settingsFile, "Window", "Width", "")
        h := IniRead(CFG.settingsFile, "Window", "Height", "")
        x := IniRead(CFG.settingsFile, "Window", "PosX", "")
        y := IniRead(CFG.settingsFile, "Window", "PosY", "")
        p := IniRead(CFG.settingsFile, "Window", "Pinned", "1")
        ox := IniRead(CFG.settingsFile, "Window", "PinOffsetX", "")
        oy := IniRead(CFG.settingsFile, "Window", "PinOffsetY", "")
        dm := IniRead(CFG.settingsFile, "Window", "DarkMode", "")
        if (w != "")
            CFG.zoneW := Max(CFG.minW, Min(CFG.maxW, Integer(w)))
        if (h != "")
            CFG.zoneH := Max(CFG.minH, Min(CFG.maxH, Integer(h)))
        if (x != "")
            CFG.savedX := x
        if (y != "")
            CFG.savedY := y
        isPinned := (p = "1")
        if (ox != "")
            pinOffsetX := Integer(ox)
        if (oy != "")
            pinOffsetY := Integer(oy)
        if (dm != "") {
            isDarkMode := (dm = "1")
            COLORS := isDarkMode ? DARK : LIGHT
        }
        fps := IniRead(CFG.settingsFile, "Video", "FPS", "")
        if (fps != "")
            CFG.videoFPS := Float(fps)
    }
}

SaveSettings() {
    global CFG, zone, isPinned, pinOffsetX, pinOffsetY, isDarkMode
    try {
        zone.GetPos(&sx, &sy)
        IniWrite(CFG.zoneW, CFG.settingsFile, "Window", "Width")
        IniWrite(CFG.zoneH, CFG.settingsFile, "Window", "Height")
        IniWrite(sx, CFG.settingsFile, "Window", "PosX")
        IniWrite(sy, CFG.settingsFile, "Window", "PosY")
        IniWrite(isPinned ? "1" : "0", CFG.settingsFile, "Window", "Pinned")
        IniWrite(pinOffsetX, CFG.settingsFile, "Window", "PinOffsetX")
        IniWrite(pinOffsetY, CFG.settingsFile, "Window", "PinOffsetY")
        IniWrite(isDarkMode ? "1" : "0", CFG.settingsFile, "Window", "DarkMode")
        IniWrite(CFG.videoFPS, CFG.settingsFile, "Video", "FPS")
    }
}

; ============================================================================
; Build GUI — simple, no layered window nonsense
; ============================================================================
zone := Gui("+AlwaysOnTop -Caption +ToolWindow +LastFound")
zone.BackColor := COLORS.bg
zone.MarginX := 0
zone.MarginY := 0

labelH := 18
subH := 14
totalH := labelH + subH + 2
labelY := (CFG.zoneH - totalH) // 2
subY := labelY + labelH + 2

zone.SetFont("s10 w600", "Segoe UI")
zone.Add("Text", "x0 y" labelY " w" CFG.zoneW " h" labelH " Center c" COLORS.text " vLabel BackgroundTrans", "Drop / Paste")

zone.SetFont("s8 w400", "Segoe UI")
zone.Add("Text", "x0 y" subY " w" CFG.zoneW " h" subH " Center c" COLORS.sub " vSubLabel BackgroundTrans", "Ctrl+V or drag files")

zone.SetFont("s7 w400", "Segoe UI")
zone.Add("Text", "x" (CFG.zoneW - 14) " y" (CFG.zoneH - 14) " w14 h14 c" COLORS.sub " vGrip BackgroundTrans", "⋱")

; Position — safe default at center of primary screen
posX := (A_ScreenWidth - CFG.zoneW) // 2
posY := (A_ScreenHeight - CFG.zoneH) // 2

if (CFG.savedX != "" && CFG.savedY != "") {
    posX := Integer(CFG.savedX)
    posY := Integer(CFG.savedY)
}

zone.Show("x" posX " y" posY " w" CFG.zoneW " h" CFG.zoneH " NoActivate")

; Force topmost z-order (above other always-on-top windows like Cursor)
DllCall("SetWindowPos", "Ptr", zone.Hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0003)  ; HWND_TOPMOST + SWP_NOMOVE|SWP_NOSIZE

; Rounded corners
cornerR := Min(CFG.zoneH // 2, 22)
hRgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", CFG.zoneW + 1, "Int", CFG.zoneH + 1, "Int", cornerR, "Int", cornerR, "Ptr")
DllCall("SetWindowRgn", "Ptr", zone.Hwnd, "Ptr", hRgn, "Int", 1)

; Transparency
WinSetTransparent(245, zone)

; Accept drops
DllCall("shell32\DragAcceptFiles", "Ptr", zone.Hwnd, "Int", 1)
OnMessage(0x233, HandleDrop)

; Timers
SetTimer(CheckDragHover, 70)
SetTimer(TrackEditorWindow, 200)
SetTimer(CheckWatchFolder, 1000)

; Mouse
OnMessage(0x201, HandleLButtonDown)
OnMessage(0x200, HandleMouseMove)

; Right-click
zone.OnEvent("ContextMenu", ShowZoneMenu)

; Hotkeys
HotIfWinActive("ahk_id " zone.Hwnd)
Hotkey("^v", PasteClipboard)
Hotkey("Escape", (*) => ExitApp())
HotIf()

; Global hotkey: Ctrl+Shift+D to bring pill to center of active monitor
Hotkey("^+d", CenterOnScreen)

; If pinned, recalculate offset after a moment
if (isPinned)
    SetTimer(() => RecalcPinOffset(), -500)

; Tray
A_TrayMenu.Delete()
A_TrayMenu.Add("Show log", (*) => Run('notepad.exe "' CFG.logFile '"'))
A_TrayMenu.Add("Open watch folder", (*) => Run('explorer.exe "' CFG.watchDir '"'))
A_TrayMenu.Add("Clean remote files...", (*) => CleanRemoteFiles())
A_TrayMenu.Add("Clean local temp", (*) => CleanLocalTemp())
A_TrayMenu.Add()
A_TrayMenu.Add("Reset position", ResetPosition)
A_TrayMenu.Add("Reset size", ResetSize)
A_TrayMenu.Add()
A_TrayMenu.Add("Exit", (*) => ExitApp())
TraySetIcon("shell32.dll", 46)
A_IconTip := "CursorDrop v4"

OnExit((*) => SaveSettings())
Log("CursorDrop v4 started (" CFG.zoneW "x" CFG.zoneH ")")
return

; ============================================================================
; Resize
; ============================================================================
ResizePill(newW, newH) {
    global zone, CFG

    newW := Max(CFG.minW, Min(CFG.maxW, newW))
    newH := Max(CFG.minH, Min(CFG.maxH, newH))
    CFG.zoneW := newW
    CFG.zoneH := newH

    labelH := 18
    subH := 14
    showSub := (newH >= 48)

    if (showSub) {
        totalH := labelH + subH
        labelY := (newH - totalH) // 2
        subY := labelY + labelH + 2
    } else {
        labelY := (newH - labelH) // 2
        subY := 0
    }

    ctrl := zone["Label"]
    ctrl.Move(0, labelY, newW, labelH)

    subCtrl := zone["SubLabel"]
    if (showSub) {
        subCtrl.Move(0, subY, newW, subH)
        subCtrl.Visible := true
    } else {
        subCtrl.Visible := false
    }

    grip := zone["Grip"]
    grip.Move(newW - 14, newH - 14, 14, 14)

    fontSize := 10
    if (newW >= 240)
        fontSize := 13
    else if (newW >= 180)
        fontSize := 11
    else if (newW < 120)
        fontSize := 9
    ctrl.SetFont("s" fontSize " w600")
    subCtrl.SetFont("s8 w400")

    ; Resize window in place — get position BEFORE Show
    zone.GetPos(&cx, &cy)

    ; Temporarily stop pin tracking
    SetTimer(TrackEditorWindow, 0)

    zone.Show("x" cx " y" cy " w" newW " h" newH " NoActivate")

    cornerR := Min(newH // 2, 22)
    hRgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", newW + 1, "Int", newH + 1, "Int", cornerR, "Int", cornerR, "Ptr")
    DllCall("SetWindowRgn", "Ptr", zone.Hwnd, "Ptr", hRgn, "Int", 1)

    DllCall("shell32\DragAcceptFiles", "Ptr", zone.Hwnd, "Int", 1)
    DllCall("SetWindowPos", "Ptr", zone.Hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0003)

    ; Re-apply colors without moving
    zone.BackColor := COLORS.bg
    ctrl.SetFont("c" COLORS.text)
    ctrl.Value := "Drop / Paste"
    if (showSub) {
        subCtrl.SetFont("c" COLORS.sub)
        subCtrl.Value := "Ctrl+V or drag files"
    }

    ; Recalculate pin offset from new position, then resume tracking
    if (isPinned)
        RecalcPinOffset()
    SetTimer(TrackEditorWindow, 200)
}

; ============================================================================
; State
; ============================================================================
SetState(state, detail := "") {
    global zone, CFG, isBusy, COLORS

    switch state {
        case "idle":
            isBusy := false
            zone.BackColor := COLORS.bg
            SetLabel("Drop / Paste", COLORS.text)
            SetSub("Ctrl+V or drag files", COLORS.sub)

        case "hover":
            zone.BackColor := COLORS.hoverBg
            SetLabel("Release", COLORS.hoverText)
            SetSub("", "")

        case "reading":
            isBusy := true
            zone.BackColor := COLORS.readBg
            SetLabel("Reading...", COLORS.readText)
            SetSub("Checking clipboard", COLORS.readSub)

        case "uploading":
            isBusy := true
            zone.BackColor := COLORS.uploadBg
            msg := detail ? detail : "Uploading..."
            SetLabel(msg, COLORS.uploadText)
            SetSub("Syncing to remote", COLORS.uploadSub)

        case "success":
            isBusy := false
            zone.BackColor := COLORS.successBg
            msg := detail ? detail : "Done"
            SetLabel(msg, COLORS.successText)
            SetSub("Path pasted", COLORS.successSub)
            SetTimer(() => SetState("idle"), -1500)

        case "error":
            isBusy := false
            zone.BackColor := COLORS.errorBg
            msg := detail ? detail : "Error"
            SetLabel(msg, COLORS.errorText)
            SetSub("Check log", COLORS.errorSub)
            SetTimer(() => SetState("idle"), -2500)
    }
}

SetLabel(text, color) {
    global zone
    ctrl := zone["Label"]
    ctrl.SetFont("c" color)
    ctrl.Value := text
}

SetSub(text, color) {
    global zone, CFG
    ctrl := zone["SubLabel"]
    if (CFG.zoneH < 48 || text = "") {
        ctrl.Visible := false
        return
    }
    ctrl.Visible := true
    if (color != "")
        ctrl.SetFont("c" color)
    ctrl.Value := text
}

; ============================================================================
; Mouse — drag + resize
; ============================================================================
HandleLButtonDown(wParam, lParam, msg, hwnd) {
    global zone, CFG, isResizing, isDragging, isPinned, resizeEdge
    global resizeStartX, resizeStartY, resizeStartW, resizeStartH, resizeStartPosX, resizeStartPosY

    if (hwnd != zone.Hwnd)
        return

    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    zone.GetPos(&zx, &zy, &zw, &zh)

    edge := GetResizeEdge(mx, my, zx, zy, zw, zh)

    if (edge != "") {
        isResizing := true
        resizeEdge := edge
        resizeStartX := mx
        resizeStartY := my
        resizeStartW := CFG.zoneW
        resizeStartH := CFG.zoneH
        resizeStartPosX := zx
        resizeStartPosY := zy
        SetTimer(ResizeTick, 16)
        return
    }

    isDragging := true
    SetTimer(TrackEditorWindow, 0)
    SendMessage(0xA1, 2,,, zone)
    if (isPinned)
        RecalcPinOffset()
    isDragging := false
    SetTimer(TrackEditorWindow, 200)
    SaveSettings()
}

HandleMouseMove(wParam, lParam, msg, hwnd) {
    global zone, CFG
    if (hwnd != zone.Hwnd)
        return

    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    zone.GetPos(&zx, &zy, &zw, &zh)

    edge := GetResizeEdge(mx, my, zx, zy, zw, zh)

    if (edge = "br" || edge = "tl")
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32642, "Ptr"))
    else if (edge = "r" || edge = "l")
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32644, "Ptr"))
    else if (edge = "b" || edge = "t")
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32645, "Ptr"))
}

GetResizeEdge(mx, my, zx, zy, zw, zh) {
    global CFG
    g := CFG.resizeGrip
    onRight := (mx >= zx + zw - g && mx <= zx + zw)
    onBottom := (my >= zy + zh - g && my <= zy + zh)
    onLeft := (mx >= zx && mx <= zx + g)
    onTop := (my >= zy && my <= zy + g)

    if (onRight && onBottom)
        return "br"
    if (onRight)
        return "r"
    if (onBottom)
        return "b"
    if (onLeft && onTop)
        return "tl"
    if (onLeft)
        return "l"
    if (onTop)
        return "t"
    return ""
}

ResizeTick() {
    global isResizing, resizeEdge, resizeStartX, resizeStartY
    global resizeStartW, resizeStartH, resizeStartPosX, resizeStartPosY
    global zone, CFG

    if (!GetKeyState("LButton", "P")) {
        isResizing := false
        resizeEdge := ""
        SetTimer(ResizeTick, 0)
        SaveSettings()
        return
    }

    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)

    dx := mx - resizeStartX
    dy := my - resizeStartY
    newW := resizeStartW
    newH := resizeStartH
    newX := resizeStartPosX
    newY := resizeStartPosY

    if InStr(resizeEdge, "r")
        newW := resizeStartW + dx
    if InStr(resizeEdge, "b")
        newH := resizeStartH + dy
    if InStr(resizeEdge, "l") {
        newW := resizeStartW - dx
        newX := resizeStartPosX + dx
    }
    if InStr(resizeEdge, "t") {
        newH := resizeStartH - dy
        newY := resizeStartPosY + dy
    }

    newW := Max(CFG.minW, Min(CFG.maxW, newW))
    newH := Max(CFG.minH, Min(CFG.maxH, newH))

    if InStr(resizeEdge, "l")
        newX := resizeStartPosX + resizeStartW - newW
    if InStr(resizeEdge, "t")
        newY := resizeStartPosY + resizeStartH - newH

    zone.Move(newX, newY)
    ResizePill(newW, newH)
}

; ============================================================================
; Right-click menu
; ============================================================================
ShowZoneMenu(*) {
    global isPinned, isDarkMode, CFG
    m := Menu()

    m.Add("Paste clipboard", (*) => PasteClipboard())
    m.Add()

    pinLabel := isPinned ? "✓ Pinned to editor" : "Pin to editor"
    m.Add(pinLabel, TogglePin)

    themeLabel := isDarkMode ? "Switch to light" : "Switch to dark"
    m.Add(themeLabel, ToggleTheme)

    sizeMenu := Menu()
    sizeMenu.Add("Compact  (120 × 44)", (*) => (ResizePill(120, 44), SaveSettings()))
    sizeMenu.Add("Default  (160 × 52)", (*) => (ResizePill(160, 52), SaveSettings()))
    sizeMenu.Add("Medium   (200 × 60)", (*) => (ResizePill(200, 60), SaveSettings()))
    sizeMenu.Add("Large    (260 × 72)", (*) => (ResizePill(260, 72), SaveSettings()))
    m.Add("Resize", sizeMenu)

    fpsMenu := Menu()
    fpsMenu.Add("0.5 fps (1 frame per 2s)", (*) => SetVideoFPS(0.5))
    fpsMenu.Add("1 fps (default)", (*) => SetVideoFPS(1))
    fpsMenu.Add("2 fps (detailed)", (*) => SetVideoFPS(2))
    fpsMenu.Add("4 fps (animations)", (*) => SetVideoFPS(4))
    if (CFG.videoFPS = 0.5)
        fpsMenu.Check("0.5 fps (1 frame per 2s)")
    else if (CFG.videoFPS = 1)
        fpsMenu.Check("1 fps (default)")
    else if (CFG.videoFPS = 2)
        fpsMenu.Check("2 fps (detailed)")
    else if (CFG.videoFPS = 4)
        fpsMenu.Check("4 fps (animations)")
    m.Add("Video frame rate", fpsMenu)

    m.Add()
    m.Add("Open watch folder", (*) => Run('explorer.exe "' CFG.watchDir '"'))
    m.Add("Clean remote files...", (*) => CleanRemoteFiles())
    m.Add("Clean local temp", (*) => CleanLocalTemp())
    m.Add()
    m.Add("Show log", (*) => Run('notepad.exe "' CFG.logFile '"'))
    m.Add("Reset position", ResetPosition)
    m.Add()
    m.Add("Close CursorDrop", (*) => ExitApp())
    m.Show()
}

ToggleTheme(*) {
    global isDarkMode, COLORS, DARK, LIGHT
    isDarkMode := !isDarkMode
    COLORS := isDarkMode ? DARK : LIGHT
    SetState("idle")
    SaveSettings()
    Log("Theme: " (isDarkMode ? "dark" : "light"))
}

SetVideoFPS(fps) {
    global CFG
    CFG.videoFPS := fps
    SaveSettings()
    Log("Video FPS: " fps)
}

TogglePin(*) {
    global isPinned
    isPinned := !isPinned
    if (isPinned) {
        RecalcPinOffset()
        Log("Pin mode: ON (offset: " pinOffsetX ", " pinOffsetY ")")
    } else {
        Log("Pin mode: OFF")
    }
    SaveSettings()
}

ResetPosition(*) {
    global zone, CFG, isPinned
    zone.Move((A_ScreenWidth - CFG.zoneW) // 2, (A_ScreenHeight - CFG.zoneH) // 2)
    isPinned := false
    SaveSettings()
}

ResetSize(*) {
    global CFG
    ResizePill(CFG.defW, CFG.defH)
    SaveSettings()
}

CenterOnScreen(*) {
    global zone, CFG, isPinned
    ; Get the monitor the mouse is currently on
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    MonitorCount := MonitorGetCount()
    Loop MonitorCount {
        MonitorGet(A_Index, &L, &T, &R, &B)
        if (mx >= L && mx < R && my >= T && my < B) {
            cx := L + (R - L - CFG.zoneW) // 2
            cy := T + (B - T - CFG.zoneH) // 2
            zone.Move(cx, cy)
            isPinned := false
            SaveSettings()
            Log("Centered on monitor " A_Index)
            return
        }
    }
    ; Fallback to primary
    zone.Move((A_ScreenWidth - CFG.zoneW) // 2, (A_ScreenHeight - CFG.zoneH) // 2)
    isPinned := false
    SaveSettings()
}

; ============================================================================
; Hover detection
; ============================================================================
CheckDragHover() {
    global isHovering, isBusy, isResizing, isDragging, zone, CFG, COLORS

    if (isBusy || isResizing || isDragging)
        return

    mouseDown := GetKeyState("LButton", "P")

    if (mouseDown) {
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        try zone.GetPos(&zx, &zy, &zw, &zh)
        catch
            return

        overZone := (mx >= zx && mx <= zx + zw && my >= zy && my <= zy + zh)

        if (overZone && !isHovering) {
            isHovering := true
            zone.BackColor := COLORS.hoverBg
            try {
                ctrl := zone["Label"]
                ctrl.Value := "Release"
            }
        } else if (!overZone && isHovering) {
            isHovering := false
            zone.BackColor := COLORS.bg
            try {
                ctrl := zone["Label"]
                ctrl.Value := "Drop / Paste"
            }
        }
    } else if (isHovering) {
        isHovering := false
        zone.BackColor := COLORS.bg
        try {
            ctrl := zone["Label"]
            ctrl.Value := "Drop / Paste"
        }
    }
}

; ============================================================================
; Pin to editor
; ============================================================================
RecalcPinOffset() {
    global zone, CFG, pinOffsetX, pinOffsetY

    editorHwnd := FindEditorHwnd()
    if (!editorHwnd)
        return

    try {
        WinGetPos(&ex, &ey, &ew, &eh, editorHwnd)
        zone.GetPos(&zx, &zy)
        pinOffsetX := zx - (ex + ew)
        pinOffsetY := zy - (ey + eh)
        Log("Pin offset updated: " pinOffsetX ", " pinOffsetY)
    }
}

FindEditorHwnd() {
    for ed in EDITORS {
        try {
            h := WinExist("ahk_exe " ed.exe)
            if (h)
                return h
        }
    }
    return 0
}

TrackEditorWindow() {
    global zone, CFG, isPinned, isBusy, isResizing, isDragging, isHovering
    global pinOffsetX, pinOffsetY

    if (!isPinned || isBusy || isResizing || isDragging || isHovering)
        return

    if (GetKeyState("LButton", "P"))
        return

    editorHwnd := FindEditorHwnd()
    if (!editorHwnd)
        return

    try {
        WinGetPos(&ex, &ey, &ew, &eh, editorHwnd)
    } catch {
        return
    }

    if (ew <= 0 || eh <= 0)
        return

    targetX := ex + ew + pinOffsetX
    targetY := ey + eh + pinOffsetY

    try {
        zone.GetPos(&cx, &cy)
        if (Abs(cx - targetX) <= 1 && Abs(cy - targetY) <= 1)
            return
    }

    zone.Move(targetX, targetY)
    ; Re-assert topmost so we stay above Cursor
    DllCall("SetWindowPos", "Ptr", zone.Hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0003)
}

; ============================================================================
; Clipboard paste
; ============================================================================
PasteClipboard(*) {
    global CFG

    Log("Ctrl+V — checking clipboard (native)")

    timestamp := FormatTime(, "yyyyMMdd-HHmmss")
    filesToUpload := []

    if (!DllCall("OpenClipboard", "Ptr", 0, "Int")) {
        SetState("error", "Clipboard locked")
        return
    }

    hDrop := DllCall("GetClipboardData", "UInt", 15, "Ptr")
    if (hDrop) {
        fileCount := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", 0xFFFFFFFF, "Ptr", 0, "UInt", 0)
        Loop fileCount {
            i := A_Index - 1
            size := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", i, "Ptr", 0, "UInt", 0) + 1
            buf := Buffer(size * 2, 0)
            DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", i, "Ptr", buf, "UInt", size)
            fpath := StrGet(buf, "UTF-16")
            if (FileExist(fpath)) {
                filesToUpload.Push(fpath)
                Log("Clipboard file: " fpath)
            }
        }
    }

    hasBitmap := DllCall("IsClipboardFormatAvailable", "UInt", 2)
              || DllCall("IsClipboardFormatAvailable", "UInt", 8)
              || DllCall("IsClipboardFormatAvailable", "UInt", 17)

    DllCall("CloseClipboard")

    if (filesToUpload.Length > 0) {
        ctx := FindEditorContext()
        if (!ctx.alias || !ctx.workspace) {
            SetState("error", "No SSH session")
            return
        }
        ProcessDrops(filesToUpload, ctx)
        return
    }

    if (hasBitmap) {
        outFile := CFG.clipDir . "\clip-" . timestamp . ".png"
        if (SaveClipboardBitmapGDI(outFile)) {
            Log("Bitmap saved: " outFile)
            ctx := FindEditorContext()
            if (!ctx.alias || !ctx.workspace) {
                SetState("error", "No SSH session")
                return
            }
            ProcessDrops([outFile], ctx)
        } else {
            SetState("error", "Bitmap save failed")
        }
        return
    }

    SetState("error", "Empty clipboard")
}

RunCmdCapture(cmd) {
    tmpFile := A_Temp . "\cursordrop_ps.txt"
    try FileDelete(tmpFile)
    RunWait(A_ComSpec . ' /c ' . cmd . ' > "' tmpFile '" 2>&1', , "Hide")
    result := ""
    if FileExist(tmpFile)
        result := FileRead(tmpFile, "UTF-8")
    return result
}

; ============================================================================
; GDI+ bitmap save
; ============================================================================
SaveClipboardBitmapGDI(outFile) {
    hGdiplus := DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
    if (!hGdiplus) {
        Log("GDI+: LoadLibrary failed")
        return false
    }

    gdipToken := 0
    si := Buffer(24, 0)
    NumPut("UInt", 1, si, 0)
    result := DllCall("gdiplus\GdiplusStartup", "Ptr*", &gdipToken, "Ptr", si, "Ptr", 0, "Int")
    if (result != 0) {
        DllCall("FreeLibrary", "Ptr", hGdiplus)
        return false
    }

    if (!DllCall("OpenClipboard", "Ptr", 0, "Int")) {
        DllCall("gdiplus\GdiplusShutdown", "Ptr", gdipToken)
        DllCall("FreeLibrary", "Ptr", hGdiplus)
        return false
    }

    hBitmap := DllCall("GetClipboardData", "UInt", 2, "Ptr")
    if (!hBitmap) {
        DllCall("CloseClipboard")
        DllCall("gdiplus\GdiplusShutdown", "Ptr", gdipToken)
        DllCall("FreeLibrary", "Ptr", hGdiplus)
        return false
    }

    pBitmap := 0
    result := DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hBitmap, "Ptr", 0, "Ptr*", &pBitmap, "Int")
    DllCall("CloseClipboard")

    if (result != 0 || !pBitmap) {
        DllCall("gdiplus\GdiplusShutdown", "Ptr", gdipToken)
        DllCall("FreeLibrary", "Ptr", hGdiplus)
        return false
    }

    pngClsid := Buffer(16)
    NumPut("UInt", 0x557CF406, pngClsid, 0)
    NumPut("UShort", 0x1A04, pngClsid, 4)
    NumPut("UShort", 0x11D3, pngClsid, 6)
    NumPut("UChar", 0x9A, pngClsid, 8)
    NumPut("UChar", 0x73, pngClsid, 9)
    NumPut("UChar", 0x00, pngClsid, 10)
    NumPut("UChar", 0x00, pngClsid, 11)
    NumPut("UChar", 0xF8, pngClsid, 12)
    NumPut("UChar", 0x1E, pngClsid, 13)
    NumPut("UChar", 0xF3, pngClsid, 14)
    NumPut("UChar", 0x2E, pngClsid, 15)

    result := DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", outFile, "Ptr", pngClsid, "Ptr", 0, "Int")

    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    DllCall("gdiplus\GdiplusShutdown", "Ptr", gdipToken)
    DllCall("FreeLibrary", "Ptr", hGdiplus)

    return (result = 0)
}

; ============================================================================
; File drop handler
; ============================================================================
HandleDrop(wParam, lParam, msg, hwnd) {
    global zone
    static DQF := "shell32\DragQueryFileW"

    if (hwnd != zone.Hwnd)
        return

    fileCount := DllCall(DQF, "Ptr", wParam, "UInt", 0xFFFFFFFF, "Ptr", 0, "UInt", 0)
    if (fileCount < 1) {
        DllCall("shell32\DragFinish", "Ptr", wParam)
        return
    }

    ctx := FindEditorContext()

    droppedFiles := []
    Loop fileCount {
        i := A_Index - 1
        size := DllCall(DQF, "Ptr", wParam, "UInt", i, "Ptr", 0, "UInt", 0) + 1
        buf := Buffer(size * 2, 0)
        DllCall(DQF, "Ptr", wParam, "UInt", i, "Ptr", buf, "UInt", size)
        droppedFiles.Push(StrGet(buf, "UTF-16"))
    }
    DllCall("shell32\DragFinish", "Ptr", wParam)

    if (!ctx.alias || !ctx.workspace) {
        SetState("error", "No SSH session")
        return
    }

    Log("Drop: " droppedFiles.Length " file(s) | " ctx.alias ":" ctx.workspace)
    SetTimer(() => ProcessDrops(droppedFiles, ctx), -50)
}

; ============================================================================
; Editor context
; ============================================================================
FindEditorContext() {
    info := { alias: "", workspace: "", appData: "" }

    hwnd := WinExist("A")
    title := ""
    procName := ""
    try title := WinGetTitle(hwnd)
    try procName := WinGetProcessName(hwnd)

    matchedEditor := ""
    for ed in EDITORS {
        if (procName = ed.exe) {
            matchedEditor := ed
            break
        }
    }

    if (!matchedEditor) {
        for ed in EDITORS {
            try {
                h := WinExist("ahk_exe " ed.exe)
                if (h) {
                    hwnd := h
                    title := WinGetTitle(hwnd)
                    matchedEditor := ed
                    break
                }
            }
        }
    }

    if (!matchedEditor) {
        Log("No editor window found")
        return info
    }

    info.appData := matchedEditor.appData
    Log("Editor: " matchedEditor.exe " | title: " title)

    if (RegExMatch(title, "i)\[SSH:?\s*([^\]]+)\]", &m))
        info.alias := Trim(m[1])

    info.workspace := GetEditorRemoteWorkspace(info.alias, matchedEditor.appData)
    return info
}

GetEditorRemoteWorkspace(alias, appDataFolder) {
    if (!alias)
        return ""

    storagePaths := [
        EnvGet("APPDATA") . "\" . appDataFolder . "\User\globalStorage\storage.json",
        EnvGet("APPDATA") . "\" . appDataFolder . "\storage.json"
    ]

    content := ""
    foundPath := ""
    for sp in storagePaths {
        if (FileExist(sp)) {
            try {
                content := FileRead(sp, "UTF-8")
                foundPath := sp
                break
            }
        }
    }

    if (!content) {
        Log("No storage.json for " appDataFolder)
        return ""
    }

    Log("Reading: " foundPath)
    lastMatch := ""

    jsonStr := '{"hostName":"' . alias . '"}'
    hexStr := ""
    Loop Parse, jsonStr
        hexStr .= Format("{:02x}", Ord(A_LoopField))

    needleB := "vscode-remote://ssh-remote%2B" . hexStr
    pos := 1
    while (pos := InStr(content, needleB, false, pos + 1)) {
        endPos := InStr(content, '"', false, pos)
        if (!endPos)
            break
        uri := SubStr(content, pos, endPos - pos)
        lastMatch := uri
    }

    if (lastMatch) {
        afterPrefix := SubStr(lastMatch, StrLen(needleB) + 1)
        path := UrlDecode(afterPrefix)
        Log("Workspace (B): " path)
        return path
    }

    needleA := "vscode-remote://ssh-remote+" . alias
    pos := 1
    while (pos := InStr(content, needleA, false, pos + 1)) {
        endPos := InStr(content, '"', false, pos)
        if (!endPos)
            break
        uri := SubStr(content, pos, endPos - pos)
        lastMatch := uri
    }

    if (lastMatch) {
        path := SubStr(lastMatch, StrLen(needleA) + 1)
        path := UrlDecode(path)
        Log("Workspace (A): " path)
        return path
    }

    Log("No URI for '" alias "' in " foundPath)
    return ""
}

UrlDecode(s) {
    s := StrReplace(s, "+", " ")
    pos := 1
    while (pos := RegExMatch(s, "%([0-9A-Fa-f]{2})", &m, pos)) {
        ch := Chr("0x" m[1])
        s := SubStr(s, 1, pos - 1) . ch . SubStr(s, pos + 3)
        pos += StrLen(ch)
    }
    return s
}

; ============================================================================
; Video
; ============================================================================
IsVideoFile(filePath) {
    global CFG
    SplitPath(filePath, , , &ext)
    ext := StrLower(ext)
    return InStr("," . CFG.videoExts . ",", "," . ext . ",")
}

HasFFmpeg() {
    tmpFile := A_Temp . "\cursordrop_ffcheck.txt"
    try FileDelete(tmpFile)
    exitCode := RunWait(A_ComSpec . ' /c ffmpeg -version > "' tmpFile '" 2>&1', , "Hide")
    return (exitCode = 0)
}

ExtractVideoFrames(videoPath) {
    global CFG

    if (!HasFFmpeg()) {
        result := MsgBox(
            "FFmpeg is required to extract frames from videos.`n`n"
            . "Install it with:`n  winget install ffmpeg`n`n"
            . "Open the download page?",
            "CursorDrop — FFmpeg required", "YesNo Icon!"
        )
        if (result = "Yes")
            Run("https://ffmpeg.org/download.html")
        return []
    }

    SplitPath(videoPath, &fname, , &ext)
    ts := FormatTime(, "yyyyMMdd-HHmmss")
    frameDir := CFG.clipDir . "\frames-" . ts
    DirCreate(frameDir)

    tempVideo := CFG.clipDir . "\tempvideo-" . ts . "." . ext
    try {
        FileCopy(videoPath, tempVideo, true)
    } catch as e {
        Log("Failed to copy video: " e.Message)
        SetState("error", "Copy failed")
        return []
    }

    tmpFile := A_Temp . "\cursordrop_duration.txt"
    try FileDelete(tmpFile)
    RunWait(A_ComSpec . ' /c ffprobe -v error -show_entries format=duration -of csv=p=0 "' . tempVideo . '" > "' . tmpFile . '" 2>&1', , "Hide")

    probeOutput := ""
    try probeOutput := Trim(FileRead(tmpFile, "UTF-8"))

    cleanDuration := RegExReplace(probeOutput, "[^\d.]", "")
    duration := 0
    if (cleanDuration != "")
        try duration := Float(cleanDuration)

    if (duration <= 0) {
        Log("Could not get video duration: " videoPath)
        try FileDelete(tempVideo)
        SetState("error", "Bad video")
        return []
    }

    clipDuration := Min(duration, CFG.videoMaxSec)

    if (duration > CFG.videoMaxSec) {
        result := MsgBox(
            "Video is " . Round(duration) . "s long.`n"
            . "Only the first " . CFG.videoMaxSec . "s will be extracted.`n`nContinue?",
            "CursorDrop", "YesNo Icon!"
        )
        if (result != "Yes") {
            try FileDelete(tempVideo)
            return []
        }
    }

    expectedFrames := Ceil(clipDuration * CFG.videoFPS)
    if (expectedFrames > 60) {
        clipDuration := Floor(60 / CFG.videoFPS)
        expectedFrames := 60
    }

    SetState("uploading", "Extracting " . expectedFrames . " frames...")
    Log("Extracting: " fname " (" . Round(duration, 1) . "s → " . expectedFrames . " frames)")

    ffmpegCmd := 'ffmpeg -i "' . tempVideo . '" -t ' . clipDuration . ' -vf "fps=' . CFG.videoFPS . '" -q:v 2 "' . frameDir . '\frame_%03d.jpg" -y'
    RunWait(A_ComSpec . ' /c ' . ffmpegCmd . ' > nul 2>&1', , "Hide")

    try FileDelete(tempVideo)

    frames := []
    try {
        Loop Files, frameDir . "\frame_*.jpg"
            frames.Push(A_LoopFileFullPath)
    }

    if (frames.Length = 0) {
        Log("No frames extracted from " fname)
        SetState("error", "Extraction failed")
        return []
    }

    Log("Got " . frames.Length . " frames from " fname)
    return frames
}

; ============================================================================
; Upload — instant paste, background SCP
; ============================================================================
ProcessDrops(files, ctx) {
    global CFG

    ; Separate videos from regular files
    regularFiles := []
    videoFiles := []
    tempFrameDirs := []

    for _, localPath in files {
        if (!FileExist(localPath))
            continue
        if (IsVideoFile(localPath))
            videoFiles.Push(localPath)
        else
            regularFiles.Push(localPath)
    }

    ; Process videos
    videoPaths := []
    videoDirMaps := []

    for _, videoPath in videoFiles {
        frames := ExtractVideoFrames(videoPath)
        if (frames.Length = 0)
            continue

        SplitPath(frames[1], , &localFrameDir)
        tempFrameDirs.Push(localFrameDir)

        SplitPath(videoPath, &vname, , &vext)
        ts := FormatTime(, "yyyyMMdd-HHmmss")
        folderName := ts . "-" . SanitizeFilename(StrReplace(vname, "." . vext, "")) . "-frames"
        remoteBase := ctx.workspace . "/" . CFG.remoteSubdir
        remoteVideoDir := remoteBase . "/" . folderName
        remoteVideoDir := StrReplace(remoteVideoDir, "//", "/")

        videoPaths.Push(remoteVideoDir)
        videoDirMaps.Push({ localDir: localFrameDir, remoteDir: remoteVideoDir, count: frames.Length })
    }

    ; Regular files
    remoteDir := ctx.workspace . "/" . CFG.remoteSubdir
    remoteDir := StrReplace(remoteDir, "//", "/")

    remoteFiles := []
    localFiles := []
    touchParts := ""

    for _, localPath in regularFiles {
        if (!FileExist(localPath))
            continue

        SplitPath(localPath, &fname)
        ts := FormatTime(, "yyyyMMdd-HHmmss")
        remoteName := ts . "-" . SanitizeFilename(fname)
        remotePath := remoteDir . "/" . remoteName

        remoteFiles.Push(remotePath)
        localFiles.Push(localPath)
        touchParts .= " " . ShellQuote(remotePath)
    }

    if (remoteFiles.Length = 0 && videoPaths.Length = 0) {
        SetState("error", "No files")
        return
    }

    ; Build payload
    payload := ""
    for _, vp in videoPaths
        payload .= (payload ? " " : "") . "'" . vp . "/'"
    for _, p in remoteFiles
        payload .= (payload ? " " : "") . "'" . p . "'"

    ; PASTE IMMEDIATELY
    A_Clipboard := payload

    pasted := false
    for ed in EDITORS {
        try {
            if WinExist("ahk_exe " ed.exe) {
                WinActivate("ahk_exe " ed.exe)
                WinWaitActive("ahk_exe " ed.exe, , 2)
                Sleep(100)
                Send("^v")
                pasted := true
                break
            }
        }
    }

    if (!pasted)
        Notify("Path copied — Ctrl+V in Claude Code.", false)

    ; Background: mkdir + touch + scp
    videoFrameCount := 0
    for _, vd in videoDirMaps
        videoFrameCount += vd.count
    totalFiles := remoteFiles.Length + videoDirMaps.Length
    SetState("uploading", "Syncing...")

    mkdirParts := ShellQuote(remoteDir)
    for _, vp in videoPaths
        mkdirParts .= " " . ShellQuote(vp)

    mkCmd := "ssh -o ConnectTimeout=" . CFG.sshTimeout . " " . ctx.alias . ' "mkdir -p ' . mkdirParts . '"'
    if (touchParts != "")
        mkCmd := "ssh -o ConnectTimeout=" . CFG.sshTimeout . " " . ctx.alias . ' "mkdir -p ' . mkdirParts . " && touch" . touchParts . '"'

    Log("Run: " mkCmd)
    if (!RunCommand(mkCmd, &stderr)) {
        SetState("error", "Remote prep failed")
        return
    }

    failCount := 0
    uploaded := 0

    for i, localPath in localFiles {
        uploaded++
        SplitPath(localPath, &fname)
        SetState("uploading", "Syncing " . uploaded . "/" . totalFiles . " " . fname)

        scpCmd := Format('scp -o ConnectTimeout={1} {2} {3}:{4}',
            CFG.sshTimeout, ShellQuote(localPath), ctx.alias, ShellQuote(remoteFiles[i]))
        Log("Run: " scpCmd)

        if (!RunCommand(scpCmd, &stderr)) {
            Log("FAIL scp: " stderr)
            failCount++
        } else {
            Log("OK: " localPath " -> " remoteFiles[i])
        }
    }

    for _, vd in videoDirMaps {
        uploaded++
        SetState("uploading", "Syncing " . uploaded . "/" . totalFiles . " (" . vd.count . " frames)")

        scpCmd := Format('scp -o ConnectTimeout={1} {2}\*.jpg {3}:{4}/',
            CFG.sshTimeout, ShellQuote(vd.localDir), ctx.alias, ShellQuote(vd.remoteDir))
        Log("Run: " scpCmd)

        if (!RunCommand(scpCmd, &stderr)) {
            Log("FAIL scp frames: " stderr)
            failCount++
        } else {
            Log("OK: " vd.count " frames -> " vd.remoteDir)
        }
    }

    if (failCount > 0)
        SetState("error", failCount . " upload(s) failed")
    else
        SetState("success", totalFiles . " file" . (totalFiles > 1 ? "s" : "") . " ready")

    for _, dir in tempFrameDirs {
        try {
            Loop Files, dir . "\*.*"
                FileDelete(A_LoopFileFullPath)
            DirDelete(dir)
        }
    }
}

; ============================================================================
; Cleanup
; ============================================================================
CleanRemoteFiles(*) {
    global CFG
    ctx := FindEditorContext()
    if (!ctx.alias || !ctx.workspace) {
        SetState("error", "No SSH session")
        return
    }

    remoteDir := ctx.workspace . "/" . CFG.remoteSubdir

    SetState("uploading", "Counting...")
    countCmd := Format('ssh -o ConnectTimeout={1} {2} "ls -1 {3} 2>/dev/null | wc -l"',
        CFG.sshTimeout, ctx.alias, ShellQuote(remoteDir))

    if (!RunCommand(countCmd, &stderr)) {
        SetState("error", "Count failed")
        return
    }

    countOut := ""
    try countOut := FileRead(A_Temp . "\cursordrop_out.txt", "UTF-8")
    count := 0
    if (RegExMatch(Trim(countOut), "(\d+)", &cm))
        count := Integer(cm[1])

    if (count = 0) {
        SetState("success", "Already clean")
        return
    }

    result := MsgBox(
        Format("Delete all {1} file(s) in:`n{2}:{3}`n`nThis cannot be undone.", count, ctx.alias, remoteDir),
        "Clean remote .cursor-drop-files?", "YesNo Icon! Default2"
    )

    if (result != "Yes") {
        SetState("idle")
        return
    }

    SetState("uploading", "Deleting...")
    cleanCmd := Format('ssh -o ConnectTimeout={1} {2} "rm -rf {3}/*"',
        CFG.sshTimeout, ctx.alias, ShellQuote(remoteDir))

    if (RunCommand(cleanCmd, &stderr)) {
        SetState("success", count . " deleted")
        Log("Remote cleanup: " count " files deleted")
    } else {
        SetState("error", "Clean failed")
    }
}

CleanLocalTemp(*) {
    global CFG
    count := 0
    try {
        Loop Files, CFG.clipDir . "\*.*" {
            try {
                FileDelete(A_LoopFileFullPath)
                count++
            }
        }
    }
    SetState("success", count . " temp cleared")
}

; ============================================================================
; Watch folder
; ============================================================================
ScanWatchFolder() {
    global CFG, watchKnownFiles
    try {
        Loop Files, CFG.watchDir . "\*.*" {
            if (A_LoopFileName = "desktop.ini" || A_LoopFileName = ".DS_Store")
                continue
            watchKnownFiles[A_LoopFileFullPath] := true
        }
    }
    Log("Watch folder scanned: " watchKnownFiles.Count " existing files ignored")
}

CheckWatchFolder() {
    global CFG, watchKnownFiles, isBusy

    if (isBusy)
        return

    newFiles := []

    try {
        Loop Files, CFG.watchDir . "\*.*" {
            if (A_LoopFileName = "desktop.ini" || A_LoopFileName = ".DS_Store")
                continue
            if (!watchKnownFiles.Has(A_LoopFileFullPath)) {
                size1 := A_LoopFileSize
                Sleep(200)
                try {
                    if (FileExist(A_LoopFileFullPath)) {
                        size2 := FileGetSize(A_LoopFileFullPath)
                        if (size1 = size2 && size2 > 0)
                            newFiles.Push(A_LoopFileFullPath)
                    }
                }
            }
        }
    }

    if (newFiles.Length = 0)
        return

    for _, f in newFiles
        watchKnownFiles[f] := true

    Log("Watch folder: " newFiles.Length " new file(s)")

    ctx := FindEditorContext()
    if (!ctx.alias || !ctx.workspace) {
        SetState("error", "No SSH session")
        return
    }

    ProcessDrops(newFiles, ctx)

    for _, f in newFiles {
        try {
            if (FileExist(f)) {
                FileDelete(f)
                watchKnownFiles.Delete(f)
            }
        }
    }
}

; ============================================================================
; Helpers
; ============================================================================
RunCommand(cmd, &stderrOut) {
    stderrOut := ""
    tmpOut := A_Temp . "\cursordrop_out.txt"
    tmpErr := A_Temp . "\cursordrop_err.txt"
    try FileDelete(tmpOut)
    try FileDelete(tmpErr)
    full := A_ComSpec . ' /c ' . cmd . ' 1>"' tmpOut '" 2>"' tmpErr '"'
    exitCode := RunWait(full, , "Hide")
    if (FileExist(tmpErr))
        try stderrOut := FileRead(tmpErr, "UTF-8")
    return (exitCode = 0)
}

ShellQuote(s) {
    return '"' . StrReplace(s, '"', '\"') . '"'
}

SanitizeFilename(name) {
    name := RegExReplace(name, "[\s]+", "_")
    name := RegExReplace(name, "[^\w.\-]", "")
    return name
}

Notify(msg, isError := false) {
    TrayTip("CursorDrop", msg, isError ? 0x2 : 0x1)
}

Log(msg) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") . " " . msg . "`n", CFG.logFile, "UTF-8")
}
