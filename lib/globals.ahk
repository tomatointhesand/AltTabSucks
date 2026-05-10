; globals.ahk - Global configuration variables

; When true, cycle mode falls back to toggle when an app has only one window.
; Overridable in config.ahk or via the Settings UI (Ctrl+Alt+Shift+,).
CYCLE_SINGLE_AS_TOGGLE := false

; "auto" follows the system dark/light setting; "dark" or "light" forces a specific theme.
THEME := "auto"

; When true, a live DWM thumbnail of the highlighted window appears beside the switcher popup.
SWITCHER_SHOW_PREVIEW := true

; Which side of the switcher popup the window preview appears on: "right" or "left".
SWITCHER_PREVIEW_SIDE := "right"

; Preview size as a percentage of the default max dimensions (640×400). Range 25–200.
SWITCHER_PREVIEW_SIZE := 100