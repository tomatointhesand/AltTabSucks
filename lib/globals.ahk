; globals.ahk - Global configuration variables

; When true, cycle mode falls back to toggle when an app has only one window.
; Overridable in config.ahk or via the Settings UI (Ctrl+Alt+Shift+,).
CYCLE_SINGLE_AS_TOGGLE := false

; "auto" follows the system dark/light setting; "dark" or "light" forces a specific theme.
THEME := "auto"

; When true, a live DWM thumbnail of the highlighted window appears beside the switcher popup.
SWITCHER_SHOW_PREVIEW := true

; When true, the keyboard hint bar is shown at the top of the window switcher popup.
SWITCHER_SHOW_HINTS := true

; Which side of the switcher popup the window preview appears on: "right" or "left".
SWITCHER_PREVIEW_SIDE := "right"

; Preview size as a percentage of the default max dimensions (640×400). Range 25–200.
SWITCHER_PREVIEW_SIZE := 100

; When true, preview shows as a static row/grid of all windows (Windows 11 style).
; The selected row is highlighted with an outline.  Takes precedence over the single side-preview;
; ignored when SWITCHER_CAROUSEL is true.  Requires SWITCHER_SHOW_PREVIEW := true.
SWITCHER_GRID_PREVIEW := false

; When true, preview shows as an animated multi-window carousel arc instead of a single thumbnail.
; Requires SWITCHER_SHOW_PREVIEW := true.
SWITCHER_CAROUSEL := false

; Number of windows visible in the carousel (odd number, 3–9).
SWITCHER_CAROUSEL_SLOTS := 5

; Where the carousel appears relative to the switcher popup: "above" or "below".
SWITCHER_CAROUSEL_POSITION := "above"

; When true, carousel slot transitions animate with a lerp rather than snapping instantly.
SWITCHER_CAROUSEL_ANIMATE := false

; Lerp speed for animated carousel transitions: "slow", "medium", or "fast".
SWITCHER_CAROUSEL_SPEED := "medium"