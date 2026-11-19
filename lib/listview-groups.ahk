; listview-groups.ahk - native group headers in a ListView (the tab search popup's sections, the
; startup manager's history runs). LvEnableGroups once, then LvAddGroup per section and
; LvSetGroup per row.

LvEnableGroups(lv) {
    SendMessage(0x109D, 1, 0, lv)  ; LVM_ENABLEGROUPVIEW
}

LvRemoveGroups(lv) {
    SendMessage(0x10A0, 0, 0, lv)  ; LVM_REMOVEALLGROUPS
}

; LVGROUP (comctl32 v5 part): cbSize, mask, pszHeader, cchHeader, pszFooter, cchFooter, iGroupId.
LvAddGroup(lv, id, header) {
    grp := Buffer(A_PtrSize = 8 ? 56 : 40, 0)
    NumPut("UInt", grp.Size, grp, 0)
    NumPut("UInt", 0x1 | 0x10, grp, 4)  ; LVGF_HEADER | LVGF_GROUPID
    NumPut("Ptr", StrPtr(header), grp, 8)
    NumPut("Int", id, grp, A_PtrSize = 8 ? 36 : 24)
    SendMessage(0x1091, -1, grp, lv)  ; LVM_INSERTGROUP at the end
}

; LVITEM: mask, iItem, ..., iGroupId (offset 52 on x64, 40 on x86). row is 1-based.
LvSetGroup(lv, row, id) {
    it := Buffer(A_PtrSize = 8 ? 88 : 60, 0)
    NumPut("UInt", 0x100, it, 0)  ; LVIF_GROUPID
    NumPut("Int", row - 1, it, 4)
    NumPut("Int", id, it, A_PtrSize = 8 ? 52 : 40)
    SendMessage(0x104C, 0, it, lv)  ; LVM_SETITEMW
}
