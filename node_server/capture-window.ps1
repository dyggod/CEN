# PowerShell Script: Capture specific window
# Usage: powershell -File capture-window.ps1 -WindowTitle "cTrader" -OutputPath "screenshot.png"

param(
    [string]$WindowTitle = "cTrader",
    [string]$OutputPath = "screenshot.png",
    [switch]$BringToFront = $false  # Whether to bring window to front
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Find window and capture
Add-Type -ReferencedAssemblies 'System.Drawing' @"
    using System;
    using System.Runtime.InteropServices;
    using System.Text;
    using System.Drawing;
    using System.Drawing.Imaging;
    
    public class WindowCapture {
        [DllImport("user32.dll")]
        public static extern IntPtr GetWindowDC(IntPtr hWnd);
        
        [DllImport("user32.dll")]
        public static extern bool ReleaseDC(IntPtr hWnd, IntPtr hDC);
        
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
        
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
        
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
        
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr hWnd);
        
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsIconic(IntPtr hWnd);
        
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
        
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
        
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }
        
        public const uint PW_CLIENTONLY = 0x1;
        public const uint PW_RENDERFULLCONTENT = 0x2;
        
        // Capture window using PrintWindow API
        public static Bitmap CaptureWindow(IntPtr hWnd) {
            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) {
                throw new Exception("Cannot get window position");
            }
            
            int width = rect.Right - rect.Left;
            int height = rect.Bottom - rect.Top;
            
            if (width <= 0 || height <= 0) {
                throw new Exception("Invalid window size");
            }
            
            Bitmap bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            
            using (Graphics graphics = Graphics.FromImage(bitmap)) {
                IntPtr hdc = graphics.GetHdc();
                try {
                    // Use PrintWindow to capture directly from window (works even if obscured)
                    bool result = PrintWindow(hWnd, hdc, PW_RENDERFULLCONTENT);
                    if (!result) {
                        throw new Exception("PrintWindow failed");
                    }
                } finally {
                    graphics.ReleaseHdc(hdc);
                }
            }
            
            return bitmap;
        }
    }
"@

# Find window containing specified title
$script:targetWindow = [IntPtr]::Zero
$script:targetTitle = ""

$callback = {
    param($hwnd, $lParam)
    
    $sb = New-Object System.Text.StringBuilder 256
    [WindowCapture]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
    $title = $sb.ToString()
    
    # Only find visible and non-minimized windows
    if ($title -like "*$WindowTitle*" -and 
        [WindowCapture]::IsWindowVisible($hwnd) -and 
        -not [WindowCapture]::IsIconic($hwnd)) {
        $script:targetWindow = $hwnd
        $script:targetTitle = $title
        return $false  # Stop enumeration
    }
    return $true  # Continue enumeration
}

$enumProc = [WindowCapture+EnumWindowsProc]$callback
[WindowCapture]::EnumWindows($enumProc, [IntPtr]::Zero) | Out-Null

if ($script:targetWindow -eq [IntPtr]::Zero) {
    Write-Host ""
    Write-Host "ERROR: Window containing '$WindowTitle' not found" -ForegroundColor Red
    Write-Host ""
    Write-Host "Possible reasons:"
    Write-Host "1. cTrader is not running"
    Write-Host "2. cTrader window is minimized"
    Write-Host "3. Window title does not contain '$WindowTitle'"
    Write-Host ""
    Write-Host "Debug tip:"
    Write-Host "Run: list-windows.ps1 -Filter cTrader"
    Write-Host "Check the actual window title, then update config"
    Write-Host ""
    exit 1
}

Write-Host "Found window: $script:targetTitle"
Write-Host "Window handle: 0x$($script:targetWindow.ToString('X'))"

# Get window size
$rect = New-Object WindowCapture+RECT
[WindowCapture]::GetWindowRect($script:targetWindow, [ref]$rect) | Out-Null

$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top

Write-Host "Window position: X=$($rect.Left), Y=$($rect.Top)"
Write-Host "Window size: W=$width x H=$height"

# Bring to front if needed (optional)
if ($BringToFront) {
    Write-Host "Bringing window to front..."
    [WindowCapture]::SetForegroundWindow($script:targetWindow) | Out-Null
    Start-Sleep -Milliseconds 500
}

# Capture using PrintWindow API (works even if window is obscured)
Write-Host "Capturing window using PrintWindow API..."

try {
    $bitmap = [WindowCapture]::CaptureWindow($script:targetWindow)
    
    # Save as PNG
    $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    
    Write-Host "Screenshot captured successfully: $OutputPath"
    Write-Host "Note: Using PrintWindow API, works even if window is obscured"
    
} catch {
    Write-Host "Screenshot failed: $_" -ForegroundColor Red
    Write-Host "Note: Some windows may not support PrintWindow API"
    Write-Host "Solution: 1) Ensure cTrader window is not minimized 2) Try bringing window to front"
    exit 1
}

exit 0

