; utils.ahk - General utilities (split into categories)

#Include globals.ahk
#Include general.ahk
#Include window-management.ahk
#Include settings.ahk
#Include window-switcher.ahk

_settingsGui := 0
_switcherGui         := 0
_switcherItems       := []
_switcherLV          := 0
_switcherEdit        := 0
_switcherCurrentRow  := 1
_switcherHeldMods    := []
_previewGui          := 0
_previewThumbnail    := 0