; startup-upgrade.ahk - offers the startup manager (StartupManager.ahk) to installs from before it
; existed: AltTabSucks is installed (its server task exists) but the "AltTabSucks Startup" logon
; task isn't. Asks once, a few seconds after startup; "No" is remembered. "Yes" runs
; installer.ps1 -Action startup-setup in a console, which asks before moving any startup apps.

SetTimer(_OfferStartupManager, -8000)

_OfferStartupManager() {
    declined := EnvGet("LOCALAPPDATA") "\AltTabSucks\startup-setup-declined"
    if FileExist(declined)
        return
    try {
        svc := ComObject("Schedule.Service")
        svc.Connect()
        folder := svc.GetFolder("\")
        try {
            folder.GetTask("AltTabSucks Startup")
            return  ; already set up
        }
        folder.GetTask("AltTabSucks")  ; throws when AltTabSucks was never installed (run by hand)
    } catch {
        return
    }
    answer := MsgBox("AltTabSucks can now start your startup apps itself: AltTabSucks first (without a UAC "
        . "prompt), then each app in order, with delays you choose, in place of Windows' late all-at-once "
        . "startup. A small window shows their progress, and a history shows how long each took.`n`n"
        . "Set it up now? It asks before moving any of your apps.", "AltTabSucks: startup manager", "YesNo Iconi")
    if answer = "Yes" {
        ; This script is elevated, so the installer is too: no UAC prompt.
        Run('pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "' A_ScriptDir '\installer.ps1" -Action startup-setup', A_ScriptDir)
        return
    }
    try {
        DirCreate(EnvGet("LOCALAPPDATA") "\AltTabSucks")
        FileAppend("", declined)
    }
    TrayTip("To set it up later: installer.ps1 -Action startup-setup", "AltTabSucks")
}
