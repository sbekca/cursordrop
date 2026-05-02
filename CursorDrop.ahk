#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
; CursorDrop v4 — Enterprise-grade floating drop zone
;
; Drag files or Ctrl+V clipboard images → SCP to remote
; .cursor-drop-files/ → auto-paste absolute path into Claude Code.
;
; Features:
;   - Polished dark glass UI with smooth state transitions
;   - Resizable (drag edges/corners, right-click size presets, saves to .ini)
;   - Drag to reposition (saves position)
;   - Ctrl+V clipboard paste (images + files)
;   - Supports Cursor, VS Code, VS Code Insiders
;   - Hex-encoded Cursor storage.json format
;   - Cleanup with confirmation dialog
;
; Requirements:
;   - AutoHotkey v2.0+
;   - Windows OpenSSH (ssh / scp on PATH)
;   - SSH key auth configured
;   - Cursor or VS Code connected via Remote-SSH
; ============================================================================

; ----- Config ---------------------------------------------------------------
global CFG := {
    defW:           160,                ; default width
    defH:           52,                 ; default height
    minW:           100,
    minH:           40,
    maxW:           500,
    maxH:           250,
    resizeGrip:     8,
    alphaIdle:      245,
    alphaActive:    255,
    remoteSubdir:   ".cursor-drop-files",
    logFile:        A_ScriptDir . "\CursorDrop.log",
    settingsFile:   A_ScriptDir . "\CursorDrop.ini",
    sshTimeout:     30,
    clipDir:        A_Temp . "\CursorDrop_clips",
    watchDir:       EnvGet("USERPROFILE") . "\CursorDrop",
    videoFPS:       1,                  ; frames per second to extract from video
    videoMaxSec:    30,                 ; max video duration to process (seconds)
    videoExts:      "mp4,mov,webm,avi,mkv,wmv"
}

; Color palettes — auto-detect Windows dark/light mode
global isDarkMode := DetectDarkMode()

DetectDarkMode() {
    try {
        val := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
        return (val = 0)  ; 0 = dark mode, 1 = light mode
    } catch {
        return true  ; default to dark
    }
}

global DARK := {
    bg:             "222222",
    text:           "E0E0E0",
    sub:            "888888",
    hoverBg:        "1B3328",
    hoverText:      "7FD4A0",
    hoverSub:       "5AA87A",
    readBg:         "2A2235",
    readText:       "C4A8E0",
    readSub:        "9A7DBF",
    uploadBg:       "2E2818",
    uploadText:     "E8C86A",
    uploadSub:      "BFA44E",
    successBg:      "1B3328",
    successText:    "7FD4A0",
    successSub:     "5AA87A",
    errorBg:        "351E1E",
    errorText:      "E87070",
    errorSub:       "C05050"
}

global LIGHT := {
    bg:             "FAFAFA",
    text:           "222222",
    sub:            "999999",
    hoverBg:        "E8F5EC",
    hoverText:      "2E8B4E",
    hoverSub:       "5AA87A",
    readBg:         "F0E8F8",
    readText:       "7B3FA0",
    readSub:        "9A7DBF",
    uploadBg:       "FFF5E0",
    uploadText:     "B88A20",
    uploadSub:      "D4A830",
    successBg:      "E8F5EC",
    successText:    "2E8B4E",
    successSub:     "5AA87A",
    errorBg:        "FDE8E8",
    errorText:      "C03030",
    errorSub:       "D05050"
}

global COLORS := isDarkMode ? DARK : LIGHT

; Editor processes
global EDITORS := [
    { exe: "Cursor.exe",              appData: "Cursor" },
    { exe: "Code.exe",                appData: "Code" },
    { exe: "Code - Insiders.exe",     appData: "Code - Insiders" }
]

global isHovering := false
global isBusy := false
global isResizing := false
global isDragging := false
global isPinned := true                ; pin to editor window by default
global pinOffsetX := -24               ; offset from editor right edge
global pinOffsetY := -70               ; offset from editor bottom edge
global resizeEdge := ""
global resizeStartX := 0
global resizeStartY := 0
global resizeStartW := 0
global resizeStartH := 0
global resizeStartPosX := 0
global resizeStartPosY := 0

; Ensure dirs
DirCreate(CFG.clipDir)
DirCreate(CFG.watchDir)

; Track known files in watch folder (so we only process new ones)
global watchKnownFiles := Map()
ScanWatchFolder()  ; snapshot current contents so we don't re-upload existing files

; Load saved settings (size + position)
LoadSettings()

; ============================================================================
; Settings persistence
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
; Build the GUI — clean flat
; ============================================================================
zone := Gui("+AlwaysOnTop -Caption +ToolWindow +LastFound +E0x10 +E0x80000")
zone.BackColor := COLORS.bg
zone.MarginX := 0
zone.MarginY := 0

; Main label + subtitle, vertically centered as a pair
labelH := 18
subH := 14
totalH := labelH + subH + 2
labelY := (CFG.zoneH - totalH) // 2
subY := labelY + labelH + 2

zone.SetFont("s10 w600", "Segoe UI")
zone.Add("Text", "x0 y" labelY " w" CFG.zoneW " h" labelH " Center c" COLORS.text " vLabel BackgroundTrans", "Drop / Paste")

zone.SetFont("s8 w400", "Segoe UI")
zone.Add("Text", "x0 y" subY " w" CFG.zoneW " h" subH " Center c" COLORS.sub " vSubLabel BackgroundTrans", "Ctrl+V or drag files")

; Resize grip
zone.SetFont("s7 w400", "Segoe UI")
zone.Add("Text", "x" (CFG.zoneW - 14) " y" (CFG.zoneH - 14) " w14 h14 c" COLORS.sub " vGrip BackgroundTrans", "⋱")

; Position — use saved position, then recalculate pin offset if pinned
if (CFG.savedX != "" && CFG.savedY != "") {
    posX := Integer(CFG.savedX)
    posY := Integer(CFG.savedY)
} else {
    ; No saved position — default to bottom-right of editor or screen
    posX := 0
    posY := 0
    editorFound := false
    for ed in EDITORS {
        try {
            h := WinExist("ahk_exe " ed.exe)
            if (h) {
                WinGetPos(&ex, &ey, &ew, &eh, h)
                if (ew > 0 && eh > 0) {
                    posX := ex + ew - CFG.zoneW - 24
                    posY := ey + eh - CFG.zoneH - 70
                    editorFound := true
                    break
                }
            }
        }
    }
    if (!editorFound) {
        posX := A_ScreenWidth - CFG.zoneW - 24
        posY := A_ScreenHeight - CFG.zoneH - 70
    }
}

zone.Show("x" posX " y" posY " w" CFG.zoneW " h" CFG.zoneH " NoActivate")

; If pinned, recalculate offset from current position relative to editor
if (isPinned) {
    SetTimer(() => RecalcPinOffset(), -500)
}

; Apply rounded region
cornerR := Min(CFG.zoneH // 2, 22)
ApplyRoundedRegion(zone.Hwnd, CFG.zoneW, CFG.zoneH, cornerR)
WinSetTransparent(CFG.alphaIdle, zone)

; Accept file drops
DllCall("shell32\DragAcceptFiles", "Ptr", zone.Hwnd, "Int", 1)
OnMessage(0x233, HandleDrop)

; Hover feedback timer
SetTimer(CheckDragHover, 70)

; Pin-to-editor tracking timer
SetTimer(TrackEditorWindow, 200)

; Watch folder timer (for LocalSend / manual drops into ~/CursorDrop)
SetTimer(CheckWatchFolder, 1000)

; Mouse handlers for drag + resize
OnMessage(0x201, HandleLButtonDown)
OnMessage(0x200, HandleMouseMove)

; Right-click context menu
zone.OnEvent("ContextMenu", ShowZoneMenu)

; Hotkeys when zone is focused
HotIfWinActive("ahk_id " zone.Hwnd)
Hotkey("^v", PasteClipboard)
Hotkey("Escape", (*) => ExitApp())
HotIf()

; ---- Tray ----
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
; Rounded region
; ============================================================================
ApplyRoundedRegion(hwnd, w, h, r) {
    hRgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", w + 1, "Int", h + 1, "Int", r, "Int", r, "Ptr")
    DllCall("SetWindowRgn", "Ptr", hwnd, "Ptr", hRgn, "Int", 1)
}

; ============================================================================
; Resize the pill and reflow all controls
; ============================================================================
ResizePill(newW, newH) {
    global zone, CFG

    newW := Max(CFG.minW, Min(CFG.maxW, newW))
    newH := Max(CFG.minH, Min(CFG.maxH, newH))
    CFG.zoneW := newW
    CFG.zoneH := newH

    ; Calculate centered positions
    labelH := 20
    subH := 14
    showSub := (newH >= 48)

    if (showSub) {
        totalH := labelH + subH
        labelY := (newH - totalH) // 2
        subY := labelY + labelH + 1
    } else {
        labelY := (newH - labelH) // 2
        subY := 0
    }

    ; Reposition controls
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

    ; Adjust font size based on width
    fontSize := 10
    if (newW >= 240)
        fontSize := 13
    else if (newW >= 180)
        fontSize := 11
    else if (newW < 120)
        fontSize := 9

    ctrl.SetFont("s" fontSize " w600")

    ; Resize window + reapply region
    zone.GetPos(&cx, &cy)
    zone.Show("x" cx " y" cy " w" newW " h" newH " NoActivate")

    cornerR := Min(newH // 2, 22)
    ApplyRoundedRegion(zone.Hwnd, newW, newH, cornerR)

    ; Re-accept drops after region change
    DllCall("shell32\DragAcceptFiles", "Ptr", zone.Hwnd, "Int", 1)
}

; ============================================================================
; Visual state machine
; ============================================================================
SetState(state, detail := "") {
    global zone, CFG, isBusy, COLORS

    switch state {
        case "idle":
            isBusy := false
            zone.BackColor := COLORS.bg
            SetLabel("Drop / Paste", COLORS.text)
            SetSub("Ctrl+V or drag files", COLORS.sub)
            WinSetTransparent(CFG.alphaIdle, zone)

        case "hover":
            zone.BackColor := COLORS.hoverBg
            SetLabel("Release", COLORS.hoverText)
            SetSub("", "")
            WinSetTransparent(CFG.alphaActive, zone)

        case "reading":
            isBusy := true
            zone.BackColor := COLORS.readBg
            SetLabel("Reading...", COLORS.readText)
            SetSub("Checking clipboard", COLORS.readSub)
            WinSetTransparent(CFG.alphaActive, zone)

        case "uploading":
            isBusy := true
            zone.BackColor := COLORS.uploadBg
            msg := detail ? detail : "Uploading..."
            SetLabel(msg, COLORS.uploadText)
            SetSub("Syncing to remote", COLORS.uploadSub)
            WinSetTransparent(CFG.alphaActive, zone)

        case "success":
            isBusy := false
            zone.BackColor := COLORS.successBg
            msg := detail ? detail : "Done"
            SetLabel(msg, COLORS.successText)
            SetSub("Path pasted", COLORS.successSub)
            WinSetTransparent(CFG.alphaActive, zone)
            SetTimer(() => SetState("idle"), -1500)

        case "error":
            isBusy := false
            zone.BackColor := COLORS.errorBg
            msg := detail ? detail : "Error"
            SetLabel(msg, COLORS.errorText)
            SetSub("Check log", COLORS.errorSub)
            WinSetTransparent(CFG.alphaActive, zone)
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
; Mouse handlers — drag to move, edge-drag to resize
; ============================================================================
HandleLButtonDown(wParam, lParam, msg, hwnd) {
    global zone, CFG, isResizing, isDragging, isPinned, resizeEdge, resizeStartX, resizeStartY
    global resizeStartW, resizeStartH, resizeStartPosX, resizeStartPosY

    if (hwnd != zone.Hwnd)
        return

    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    zone.GetPos(&zx, &zy, &zw, &zh)

    ; Check if mouse is near an edge (resize zone)
    edge := GetResizeEdge(mx, my, zx, zy, zw, zh)

    if (edge != "") {
        ; Start resize
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

    ; Normal drag to reposition
    isDragging := true
    ; Pause pin tracking while dragging
    SetTimer(TrackEditorWindow, 0)
    ; SendMessage blocks until the user releases the mouse (unlike PostMessage)
    SendMessage(0xA1, 2,,, zone)  ; WM_NCLBUTTONDOWN, HTCAPTION
    ; Drag complete — recalculate offset from new position
    if (isPinned) {
        RecalcPinOffset()
    }
    isDragging := false
    ; Resume pin tracking
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

    ; Set cursor based on edge
    if (edge = "br" || edge = "tl")
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32642, "Ptr"))  ; SIZENWSE
    else if (edge = "r" || edge = "l")
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32644, "Ptr"))  ; SIZEWE
    else if (edge = "b" || edge = "t")
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32645, "Ptr"))  ; SIZENS
}

GetResizeEdge(mx, my, zx, zy, zw, zh) {
    global CFG
    g := CFG.resizeGrip
    onRight  := (mx >= zx + zw - g && mx <= zx + zw)
    onBottom := (my >= zy + zh - g && my <= zy + zh)
    onLeft   := (mx >= zx && mx <= zx + g)
    onTop    := (my >= zy && my <= zy + g)

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
        ; Mouse released — finish resize
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

    ; Clamp position if resizing from left/top
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
    global isPinned, isDarkMode
    m := Menu()

    m.Add("Paste clipboard", (*) => PasteClipboard())
    m.Add()

    ; Pin toggle
    pinLabel := isPinned ? "✓ Pinned to editor" : "Pin to editor"
    m.Add(pinLabel, TogglePin)

    ; Theme toggle
    themeLabel := isDarkMode ? "Switch to light" : "Switch to dark"
    m.Add(themeLabel, ToggleTheme)

    ; Size presets submenu
    sizeMenu := Menu()
    sizeMenu.Add("Compact  (120 × 44)", (*) => (ResizePill(120, 44), SaveSettings()))
    sizeMenu.Add("Default  (160 × 52)", (*) => (ResizePill(160, 52), SaveSettings()))
    sizeMenu.Add("Medium   (200 × 60)", (*) => (ResizePill(200, 60), SaveSettings()))
    sizeMenu.Add("Large    (260 × 72)", (*) => (ResizePill(260, 72), SaveSettings()))
    m.Add("Resize", sizeMenu)

    ; Video FPS submenu
    fpsMenu := Menu()
    fpsMenu.Add("0.5 fps (1 frame per 2s)", (*) => SetVideoFPS(0.5))
    fpsMenu.Add("1 fps (default)", (*) => SetVideoFPS(1))
    fpsMenu.Add("2 fps (detailed)", (*) => SetVideoFPS(2))
    fpsMenu.Add("4 fps (animations)", (*) => SetVideoFPS(4))
    ; Check the current setting
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
        ; Recalculate offset from where the pill IS right now
        ; so it doesn't jump when TrackEditorWindow fires
        RecalcPinOffset()
        Log("Pin mode: ON (offset: " pinOffsetX ", " pinOffsetY ")")
    } else {
        Log("Pin mode: OFF")
    }
    SaveSettings()
}

ResetPosition(*) {
    global zone, CFG, isPinned
    isPinned := true
    ; Will snap to editor on next TrackEditorWindow tick
    SaveSettings()
}

ResetSize(*) {
    global CFG
    ResizePill(CFG.defW, CFG.defH)
    SaveSettings()
}

; ============================================================================
; Track editor window — keep pill pinned relative to editor window
; ============================================================================
RecalcPinOffset() {
    global zone, CFG, pinOffsetX, pinOffsetY

    ; Find editor window
    editorHwnd := FindEditorHwnd()
    if (!editorHwnd)
        return

    try {
        WinGetPos(&ex, &ey, &ew, &eh, editorHwnd)
        zone.GetPos(&zx, &zy)
        ; Store offset from editor's bottom-right corner
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

    ; Don't move the pill while user is dragging anything (mouse button held)
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

    ; Skip if editor is minimized
    if (ew <= 0 || eh <= 0)
        return

    ; Position relative to editor's bottom-right corner + saved offset
    ; No screen clamping — works across any monitor setup
    targetX := ex + ew + pinOffsetX
    targetY := ey + eh + pinOffsetY

    ; Only move if position actually changed by more than 1px
    ; (prevents jitter from editor redraws during file drag-over)
    try {
        zone.GetPos(&cx, &cy)
        if (Abs(cx - targetX) <= 1 && Abs(cy - targetY) <= 1)
            return
    }

    zone.Move(targetX, targetY)
}

; ============================================================================
; Drag-hover detection
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
; Ctrl+V — paste clipboard (native Win32 API, no PowerShell)
; ============================================================================
PasteClipboard(*) {
    global CFG

    Log("Ctrl+V — checking clipboard (native)")

    timestamp := FormatTime(, "yyyyMMdd-HHmmss")
    filesToUpload := []

    ; Open clipboard
    if (!DllCall("OpenClipboard", "Ptr", 0)) {
        SetState("error", "Clipboard locked")
        Log("Failed to open clipboard")
        return
    }

    ; Check for file drop list first (CF_HDROP = 15)
    hDrop := DllCall("GetClipboardData", "UInt", 15, "Ptr")
    if (hDrop) {
        Log("CF_HDROP found")
        fileCount := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", 0xFFFFFFFF, "Ptr", 0, "UInt", 0)
        Log("CF_HDROP file count: " fileCount)
        Loop fileCount {
            i := A_Index - 1
            size := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", i, "Ptr", 0, "UInt", 0) + 1
            buf := Buffer(size * 2, 0)
            DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", i, "Ptr", buf, "UInt", size)
            fpath := StrGet(buf, "UTF-16")
            if (FileExist(fpath)) {
                filesToUpload.Push(fpath)
                Log("Clipboard file: " fpath)
            } else {
                Log("Clipboard file NOT FOUND: " fpath)
            }
        }
    } else {
        Log("No CF_HDROP on clipboard")
    }

    ; Check for bitmap (CF_BITMAP = 2, CF_DIB = 8, CF_DIBV5 = 17)
    hasBitmap := DllCall("IsClipboardFormatAvailable", "UInt", 2)
              || DllCall("IsClipboardFormatAvailable", "UInt", 8)
              || DllCall("IsClipboardFormatAvailable", "UInt", 17)

    ; ALWAYS close clipboard before doing anything else
    DllCall("CloseClipboard")

    ; Route 1: Files found — instant path, no PowerShell
    if (filesToUpload.Length > 0) {
        Log("Using file route (instant)")
        ctx := FindEditorContext()
        if (!ctx.alias || !ctx.workspace) {
            SetState("error", "No SSH session")
            return
        }
        ProcessDrops(filesToUpload, ctx)
        return
    }

    ; Route 2: Bitmap — save via native GDI+ (no PowerShell)
    if (hasBitmap) {
        Log("Using bitmap route (native GDI+)")
        outFile := CFG.clipDir . "\clip-" . timestamp . ".png"

        if (SaveClipboardBitmapGDI(outFile)) {
            Log("Bitmap saved (native): " outFile)
            ctx := FindEditorContext()
            if (!ctx.alias || !ctx.workspace) {
                SetState("error", "No SSH session")
                return
            }
            ProcessDrops([outFile], ctx)
        } else {
            SetState("error", "Bitmap save failed")
            Log("Native GDI+ save failed")
        }
        return
    }

    ; Nothing useful on clipboard
    SetState("error", "Empty clipboard")
    Log("Nothing on clipboard")
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
; WM_DROPFILES — files dragged from Explorer
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
; Find editor SSH context
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

; ============================================================================
; Resolve remote workspace from editor storage
; ============================================================================
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

    ; Format B: hex-encoded JSON (newer Cursor)
    jsonStr := '{"hostName":"' . alias . '"}'
    hexStr := ""
    Loop Parse, jsonStr
        hexStr .= Format("{:02x}", Ord(A_LoopField))

    needleB := "vscode-remote://ssh-remote%2B" . hexStr
    Log("Trying format B: " needleB)
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

    ; Format A: plain alias (VS Code)
    needleA := "vscode-remote://ssh-remote+" . alias
    Log("Trying format A: " needleA)
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
; Video → frames conversion (ffmpeg)
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
            . "Install it with:`n"
            . "  winget install ffmpeg`n`n"
            . "Or download from https://ffmpeg.org/download.html`n"
            . "and add it to your PATH.`n`n"
            . "Open the download page?",
            "CursorDrop — FFmpeg required",
            "YesNo Icon!"
        )
        if (result = "Yes")
            Run("https://ffmpeg.org/download.html")
        return []
    }

    SplitPath(videoPath, &fname, , &ext)
    timestamp := FormatTime(, "yyyyMMdd-HHmmss")
    frameDir := CFG.clipDir . "\frames-" . timestamp
    DirCreate(frameDir)

    ; Copy video to temp with a clean ASCII filename
    ; (WhatsApp and macOS use non-breaking spaces and Unicode chars in filenames
    ;  which break batch files / ffmpeg path handling)
    tempVideo := CFG.clipDir . "\tempvideo-" . timestamp . "." . ext
    try {
        FileCopy(videoPath, tempVideo, true)
        Log("Copied video to clean path: " tempVideo)
    } catch as e {
        Log("Failed to copy video: " e.Message)
        SetState("error", "Copy failed")
        return []
    }

    ; Get video duration via ffprobe
    tmpFile := A_Temp . "\cursordrop_duration.txt"
    try FileDelete(tmpFile)

    RunWait(A_ComSpec . ' /c ffprobe -v error -show_entries format=duration -of csv=p=0 "' . tempVideo . '" > "' . tmpFile . '" 2>&1', , "Hide")

    ; Log what ffprobe returned
    probeOutput := ""
    try probeOutput := Trim(FileRead(tmpFile, "UTF-8"))
    Log("ffprobe output: [" probeOutput "]")

    ; Strip any non-numeric characters (BOM, whitespace, etc)
    cleanDuration := RegExReplace(probeOutput, "[^\d.]", "")
    Log("Clean duration string: [" cleanDuration "]")

    duration := 0
    if (cleanDuration != "")
        try duration := Float(cleanDuration)

    Log("Parsed duration: " duration)

    if (duration <= 0) {
        Log("Could not get video duration: " videoPath)
        SetState("error", "Bad video")
        return []
    }

    clipDuration := Min(duration, CFG.videoMaxSec)

    if (duration > CFG.videoMaxSec) {
        result := MsgBox(
            "Video is " . Round(duration) . "s long.`n"
            . "Only the first " . CFG.videoMaxSec . "s will be extracted.`n`nContinue?",
            "CursorDrop",
            "YesNo Icon!"
        )
        if (result != "Yes")
            return []
    }

    expectedFrames := Ceil(clipDuration * CFG.videoFPS)

    ; Hard cap at 60 frames — protect against accidental 4fps × 30s = 120 frames
    if (expectedFrames > 60) {
        clipDuration := Floor(60 / CFG.videoFPS)
        expectedFrames := 60
        Log("Capped to 60 frames (" clipDuration "s at " CFG.videoFPS " fps)")
    }

    SetState("uploading", "Extracting " . expectedFrames . " frames...")
    Log("Extracting: " fname " (" . Round(duration, 1) . "s → " . expectedFrames . " frames)")

    ; Extract frames using the clean temp copy
    ffmpegCmd := 'ffmpeg -i "' . tempVideo . '" -t ' . clipDuration . ' -vf "fps=' . CFG.videoFPS . '" -q:v 2 "' . frameDir . '\frame_%03d.jpg" -y'
    Log("Run: " ffmpegCmd)
    RunWait(A_ComSpec . ' /c ' . ffmpegCmd . ' > nul 2>&1', , "Hide")

    ; Clean up temp video copy
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
; Upload files via SCP → instant path paste with background upload
;
; Flow:
;   1. Pre-process: convert any videos to frames
;   2. Build remote filenames locally (zero network, instant)
;   3. Paste paths into terminal IMMEDIATELY — before any SSH call
;   4. ssh mkdir -p + touch placeholders (single call, background)
;   5. scp real files (background, overwrites placeholders)
;
; The path appears in Claude Code before anything hits the network.
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

    ; Process videos first — each gets its own remote subfolder
    videoPaths := []    ; remote folder paths to paste
    videoDirMap := []   ; { localDir, remoteDir } for batch SCP

    for _, videoPath in videoFiles {
        frames := ExtractVideoFrames(videoPath)
        if (frames.Length = 0)
            continue

        SplitPath(frames[1], , &localFrameDir)
        tempFrameDirs.Push(localFrameDir)

        SplitPath(videoPath, &vname, , &vext)
        timestamp := FormatTime(, "yyyyMMdd-HHmmss")
        folderName := timestamp . "-" . SanitizeFilename(StrReplace(vname, "." . vext, "")) . "-frames"
        remoteVideoDir := ctx.workspace . "/" . CFG.remoteSubdir . "/" . folderName
        remoteVideoDir := StrReplace(remoteVideoDir, "//", "/")

        videoPaths.Push(remoteVideoDir)
        videoDirMap.Push({ localDir: localFrameDir, remoteDir: remoteVideoDir, count: frames.Length })
    }

    ; Build full list of paths to paste (video folders + regular file paths)
    remoteDir := ctx.workspace . "/" . CFG.remoteSubdir
    remoteDir := StrReplace(remoteDir, "//", "/")

    remoteFiles := []
    localFiles := []
    touchParts := ""

    for _, localPath in regularFiles {
        if (!FileExist(localPath)) {
            Log("Skip: " localPath)
            continue
        }

        SplitPath(localPath, &fname)
        timestamp := FormatTime(, "yyyyMMdd-HHmmss")
        remoteName := timestamp . "-" . SanitizeFilename(fname)
        remotePath := remoteDir . "/" . remoteName

        remoteFiles.Push(remotePath)
        localFiles.Push(localPath)
        touchParts .= " " . ShellQuote(remotePath)
    }

    if (remoteFiles.Length = 0 && videoPaths.Length = 0) {
        SetState("error", "No files")
        return
    }

    ; Build payload — video folder paths + regular file paths
    payload := ""
    for _, vp in videoPaths
        payload .= (payload ? " " : "") . "'" . vp . "/'"
    for _, p in remoteFiles
        payload .= (payload ? " " : "") . "'" . p . "'"

    ; Paste IMMEDIATELY — before any SSH call
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

    if (!pasted) {
        Log("Auto-paste failed. Path on clipboard.")
        Notify("Path copied — Ctrl+V in Claude Code.", false)
    }

    ; Background: create remote dirs + placeholders
    videoFrameCount := 0
    for _, vd in videoDirMap
        videoFrameCount += vd.count
    totalFiles := remoteFiles.Length + videoDirMap.Length
    SetState("uploading", "Syncing...")

    ; Build mkdir commands for all needed directories
    mkdirParts := ShellQuote(remoteDir)
    for _, vp in videoPaths
        mkdirParts .= " " . ShellQuote(vp)

    mkCmd := Format('ssh -o ConnectTimeout={1} {2} "mkdir -p {3}"',
        CFG.sshTimeout, ctx.alias, mkdirParts)

    ; Add touch for regular files
    if (touchParts != "")
        mkCmd := Format('ssh -o ConnectTimeout={1} {2} "mkdir -p {3} && touch{4}"',
            CFG.sshTimeout, ctx.alias, mkdirParts, touchParts)

    Log("Run: " mkCmd)
    if (!RunCommand(mkCmd, &stderr)) {
        SetState("error", "Remote prep failed")
        Log("FAIL mkdir: " stderr)
        return
    }

    ; SCP regular files
    failCount := 0
    uploaded := 0
    for i, localPath in localFiles {
        uploaded++
        SplitPath(localPath, &fname)
        SetState("uploading", "Syncing " . uploaded . "/" . totalFiles . " " . fname)

        scpCmd := Format('scp -o ConnectTimeout={1} {2} {3}:{4}',
            CFG.sshTimeout,
            ShellQuote(localPath),
            ctx.alias,
            ShellQuote(remoteFiles[i]))
        Log("Run: " scpCmd)

        if (!RunCommand(scpCmd, &stderr)) {
            Log("FAIL scp: " stderr)
            failCount++
        } else {
            Log("OK: " localPath " -> " remoteFiles[i])
        }
    }

    ; SCP video frame directories (one scp call per video — all frames at once)
    for _, vd in videoDirMap {
        uploaded++
        SetState("uploading", "Syncing " . uploaded . "/" . totalFiles . " (" . vd.count . " frames)")

        ; scp all jpgs in the local frame dir to the remote dir in one shot
        scpCmd := Format('scp -o ConnectTimeout={1} {2}\*.jpg {3}:{4}/',
            CFG.sshTimeout,
            ShellQuote(vd.localDir),
            ctx.alias,
            ShellQuote(vd.remoteDir))
        Log("Run: " scpCmd)

        if (!RunCommand(scpCmd, &stderr)) {
            Log("FAIL scp frames: " stderr)
            failCount++
        } else {
            Log("OK: " vd.count " frames -> " vd.remoteDir)
        }
    }

    if (failCount > 0) {
        SetState("error", failCount . " upload(s) failed")
    } else {
        SetState("success", totalFiles . " file" . (totalFiles > 1 ? "s" : "") . " ready")
    }

    ; Clean up temp frame directories
    for _, dir in tempFrameDirs {
        try {
            Loop Files, dir . "\*.*"
                FileDelete(A_LoopFileFullPath)
            DirDelete(dir)
            Log("Cleaned temp frames: " dir)
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
    Log("Count: " countCmd)

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
        "Clean remote .cursor-drop-files?",
        "YesNo Icon! Default2"
    )

    if (result != "Yes") {
        SetState("idle")
        return
    }

    SetState("uploading", "Deleting...")
    cleanCmd := Format('ssh -o ConnectTimeout={1} {2} "rm -rf {3}/*"',
        CFG.sshTimeout, ctx.alias, ShellQuote(remoteDir))
    Log("Clean: " cleanCmd)

    if (RunCommand(cleanCmd, &stderr)) {
        SetState("success", count . " deleted")
        Log("Remote cleanup: " count " files deleted")
    } else {
        SetState("error", "Clean failed")
        Log("Remote cleanup failed: " stderr)
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
    Log("Local cleanup: " count " files")
}

; ============================================================================
; Watch folder — auto-upload files dropped into ~/CursorDrop/
; Works with LocalSend, manual file copies, or any other source.
; Files are uploaded then deleted from the watch folder.
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
                ; Check file size stability — wait for writes to finish
                ; (LocalSend might still be writing)
                size1 := A_LoopFileSize
                Sleep(200)
                try {
                    if (FileExist(A_LoopFileFullPath)) {
                        size2 := FileGetSize(A_LoopFileFullPath)
                        if (size1 = size2 && size2 > 0) {
                            newFiles.Push(A_LoopFileFullPath)
                        }
                        ; else still being written — will catch on next tick
                    }
                }
            }
        }
    }

    if (newFiles.Length = 0)
        return

    ; Mark as known immediately to prevent re-processing
    for _, f in newFiles
        watchKnownFiles[f] := true

    Log("Watch folder: " newFiles.Length " new file(s)")

    ; Find editor context
    ctx := FindEditorContext()
    if (!ctx.alias || !ctx.workspace) {
        SetState("error", "No SSH session")
        Log("Watch folder: no SSH context")
        return
    }

    ; Upload using the same instant-paste flow
    ProcessDrops(newFiles, ctx)

    ; Delete local copies after successful upload
    for _, f in newFiles {
        try {
            if (FileExist(f)) {
                FileDelete(f)
                watchKnownFiles.Delete(f)
                Log("Watch folder: cleaned " f)
            }
        }
    }
}

; ============================================================================
; Native GDI+ bitmap save — no PowerShell, instant
; ============================================================================
SaveClipboardBitmapGDI(outFile) {
    ; Load GDI+ DLL explicitly
    hGdiplus := DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
    if (!hGdiplus) {
        Log("GDI+: LoadLibrary failed")
        return false
    }

    ; Initialize GDI+
    gdipToken := 0
    si := Buffer(24, 0)              ; GdiplusStartupInput
    NumPut("UInt", 1, si, 0)         ; GdiplusVersion = 1
    result := DllCall("gdiplus\GdiplusStartup", "Ptr*", &gdipToken, "Ptr", si, "Ptr", 0, "Int")
    if (result != 0) {
        Log("GDI+ startup failed: " result)
        DllCall("FreeLibrary", "Ptr", hGdiplus)
        return false
    }

    success := false

    ; Open clipboard and get CF_BITMAP
    if (!DllCall("OpenClipboard", "Ptr", 0, "Int")) {
        Log("GDI+: clipboard open failed")
        DllCall("gdiplus\GdiplusShutdown", "Ptr", gdipToken)
        DllCall("FreeLibrary", "Ptr", hGdiplus)
        return false
    }

    hBitmap := DllCall("GetClipboardData", "UInt", 2, "Ptr")  ; CF_BITMAP = 2
    if (!hBitmap) {
        DllCall("CloseClipboard")
        Log("GDI+: no CF_BITMAP")
        DllCall("gdiplus\GdiplusShutdown", "Ptr", gdipToken)
        DllCall("FreeLibrary", "Ptr", hGdiplus)
        return false
    }

    ; Create GDI+ Bitmap from HBITMAP
    pBitmap := 0
    result := DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hBitmap, "Ptr", 0, "Ptr*", &pBitmap, "Int")
    DllCall("CloseClipboard")

    if (result != 0 || !pBitmap) {
        Log("GDI+ bitmap create failed: " result)
        DllCall("gdiplus\GdiplusShutdown", "Ptr", gdipToken)
        DllCall("FreeLibrary", "Ptr", hGdiplus)
        return false
    }

    ; PNG encoder CLSID: {557CF406-1A04-11D3-9A73-0000F81EF32E}
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

    ; Save to file
    result := DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", outFile, "Ptr", pngClsid, "Ptr", 0, "Int")

    ; Cleanup
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    DllCall("gdiplus\GdiplusShutdown", "Ptr", gdipToken)
    DllCall("FreeLibrary", "Ptr", hGdiplus)

    if (result != 0) {
        Log("GDI+ save failed: " result)
        return false
    }

    success := true
    return success
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
