# check-alttabsucks.ps1 - is AltTabSucks.ahk running, with its tray icon, and what did the startup
# manager record? For troubleshooting on the machine itself (no admin needed):
#   powershell -ExecutionPolicy Bypass -File dev-scripts\check-alttabsucks.ps1
# "main window: NO" means AltTabSucks.ahk hasn't finished loading (look for an error dialog);
# "tray icon: NO" with AltTabSucks.ahk started within a second or two of explorer.exe means it came
# up before the taskbar (lib\tray-icon.ahk re-adds the icon for its first two minutes).
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class AtsCheck {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [StructLayout(LayoutKind.Sequential)] struct NII { public int cbSize; public IntPtr hWnd; public uint uID; public Guid guid; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    [DllImport("shell32.dll")] static extern int Shell_NotifyIconGetRect(ref NII id, out RECT r);
    public static IntPtr MainWindow() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            var c = new StringBuilder(64); var t = new StringBuilder(512);
            GetClassName(h, c, 64); GetWindowText(h, t, 512);
            if (c.ToString() == "AutoHotkey" && t.ToString().Contains("\\AltTabSucks.ahk - AutoHotkey")) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static bool TrayIcon(IntPtr h) {
        var id = new NII { cbSize = Marshal.SizeOf(typeof(NII)), hWnd = h, uID = 1028 };
        RECT r; return Shell_NotifyIconGetRect(ref id, out r) == 0;
    }
}
"@
$p = Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" | Where-Object { $_.CommandLine -like '*\AltTabSucks.ahk*' }
$e = Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'"
"AltTabSucks.ahk processes: " + $(if ($p) { ($p | ForEach-Object { "$($_.ProcessId) started $($_.CreationDate.ToString('HH:mm:ss.fff'))" }) -join ', ' } else { 'none' })
"explorer.exe:              " + (($e | ForEach-Object { "$($_.ProcessId) started $($_.CreationDate.ToString('HH:mm:ss.fff'))" }) -join ', ')
$h = [AtsCheck]::MainWindow()
"main window:               " + $(if ($h -ne [IntPtr]::Zero) { 'yes' } else { 'NO (still loading, or stuck on an error dialog?)' })
if ($h -ne [IntPtr]::Zero) { "tray icon:                 " + $(if ([AtsCheck]::TrayIcon($h)) { 'yes' } else { 'NO' }) }
$t = Get-ScheduledTask -TaskName 'AltTabSucks AHK' -ErrorAction SilentlyContinue
if ($t) { $i = Get-ScheduledTaskInfo -TaskName 'AltTabSucks AHK'; "AltTabSucks AHK task:      $($t.State), last run $($i.LastRunTime), result 0x$('{0:X}' -f $i.LastTaskResult), runs $($t.Principal.RunLevel)" }
else { "AltTabSucks AHK task:      not registered" }
$dir = "$env:LOCALAPPDATA\AltTabSucks"
"last startup run:"
Get-Content "$dir\startup-history.jsonl" -Tail 1 -ErrorAction SilentlyContinue
if (Test-Path "$dir\startup-errors.log") { "startup errors:"; Get-Content "$dir\startup-errors.log" -Tail 10 }
