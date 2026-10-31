# set-resolution.ps1 - sets the test VM's display mode and saves it in the registry, so the
# snapshots keep it (the VirtIO GPU driver ignores the size QEMU suggests and starts at 640x480).
# Must run on the desktop, not over SSH: windows-vm.sh resolution runs it through a one-off task.
param([int]$Width = 1920, [int]$Height = 1080)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Display {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
    public static int Set(int w, int h) {
        var dm = new DEVMODE();
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(null, -1, ref dm)) return -100;  // ENUM_CURRENT_SETTINGS
        dm.dmPelsWidth = w; dm.dmPelsHeight = h;
        dm.dmFields = 0x80000 | 0x100000;                          // DM_PELSWIDTH | DM_PELSHEIGHT
        return ChangeDisplaySettings(ref dm, 1);                   // CDS_UPDATEREGISTRY; 0 = done
    }
}
"@
$r = [Display]::Set($Width, $Height)
Set-Content (Join-Path $env:TEMP "set-resolution.txt") "result=$r"
