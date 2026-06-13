; secrets.ahk - SecretManagement bridge + short-lived cache + lock awareness

_SECRET_CACHE := Map()
_SECRET_CACHE_MS := 300000 ; 5 minutes
_secretBridgeSh := A_ScriptDir "\lib\secret-bridge.sh"
_secretLockSignalPath := A_Temp "\alts_secrets_lock.trigger"

_InitSecrets()

_InitSecrets() {
    static initialized := false
    if (initialized) {
        return
    }
    initialized := true

    if (!FileExist(_secretBridgeSh)) {
        return
    }

    ; Poll for external lock requests from management scripts.
    SetTimer(_PollSecretLockSignal, 750)

    ; Register for workstation lock/unlock notifications.
    if DllCall("wtsapi32\WTSRegisterSessionNotification", "ptr", A_ScriptHwnd, "uint", 0, "int") {
        OnMessage(0x02B1, _OnSessionChange)
        OnExit(_UnregisterSessionNotifications)
    }
}

_PollSecretLockSignal(*) {
    global _secretLockSignalPath

    if (!FileExist(_secretLockSignalPath)) {
        return
    }

    ; Best effort cleanup of the signal file, then clear in-memory cache immediately.
    try FileDelete(_secretLockSignalPath)
    SecretCacheClear()
}

_UnregisterSessionNotifications(*) {
    DllCall("wtsapi32\WTSUnRegisterSessionNotification", "ptr", A_ScriptHwnd, "int")
}

_OnSessionChange(wParam, lParam, msg, hwnd) {
    ; WTS_SESSION_LOCK = 0x7, WTS_SESSION_UNLOCK = 0x8
    if (wParam = 0x7) {
        SecretVaultLock()
    } else if (wParam = 0x8) {
        SecretCacheClear()
    }
}

SecretCacheClear() {
    global _SECRET_CACHE
    _SECRET_CACHE := Map()
}

GetSecret(secretName, allowPrompt := true) {
    global _SECRET_CACHE, _SECRET_CACHE_MS

    if (_SECRET_CACHE.Has(secretName)) {
        cached := _SECRET_CACHE[secretName]
        if (cached.expiresAt > A_TickCount) {
            return cached.value
        }
        _SECRET_CACHE.Delete(secretName)
    }

    secret := _SecretBridge("get", secretName, allowPrompt)
    if (secret = "") {
        return ""
    }

    _SECRET_CACHE[secretName] := {
        value: secret,
        expiresAt: A_TickCount + _SECRET_CACHE_MS
    }
    return secret
}

SendSecret(secretName, allowPrompt := true) {
    secret := GetSecret(secretName, allowPrompt)
    if (secret = "") {
        ShowTextGui("Secret Unavailable", "Unable to read secret: " secretName "`n`nRun dev-scripts/setup-secrets.sh if needed, then try again.", 640, 180)
        return false
    }

    ; Send as literal text so characters like ! ^ + # are not interpreted as modifiers.
    SendText(secret)
    return true
}

SecretVaultLock() {
    SecretCacheClear()
    _SecretBridge("lock")
}

_ToBashPath(winPath) {
    p := StrReplace(winPath, "\", "/")
    if RegExMatch(p, "i)^([A-Z]):/(.*)$", &m) {
        return "/" . StrLower(m[1]) . "/" . m[2]
    }
    return p
}

_SecretBridge(action, secretName := "", allowPrompt := true) {
    global _secretBridgeSh

    if (!FileExist(_secretBridgeSh)) {
        return ""
    }

    bashBridgePath := _ToBashPath(_secretBridgeSh)
    bashCmd := "bash " . Chr(34) . bashBridgePath . Chr(34) . " " . action

    if (secretName != "") {
        bashCmd .= " " . Chr(34) . secretName . Chr(34)
    }
    if (allowPrompt) {
        bashCmd .= " allow_prompt"
    }

    outputPath := A_Temp "\alts_secrets_" A_TickCount ".txt"
    cmd := "cmd.exe /d /c " . Chr(34) . bashCmd . " > " . Chr(34) . outputPath . Chr(34) . " 2>nul" . Chr(34)
    RunWait(cmd,, "Hide")

    result := ""
    if FileExist(outputPath) {
        result := Trim(FileRead(outputPath, "UTF-8"), "`r`n")
        FileDelete(outputPath)
    }
    return result
}
