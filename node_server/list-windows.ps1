# List all visible windows
param(
    [string]$Filter = ""
)

Add-Type @"
    using System;
    using System.Runtime.InteropServices;
    using System.Text;
    
    public class WindowEnumerator {
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
        
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
        
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr hWnd);
        
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsIconic(IntPtr hWnd);
        
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    }
"@

Write-Host "======================================"
Write-Host "  Searching for windows..."
Write-Host "======================================"
Write-Host ""

$windows = @()

$callback = {
    param($hwnd, $lParam)
    
    if ([WindowEnumerator]::IsWindowVisible($hwnd) -and -not [WindowEnumerator]::IsIconic($hwnd)) {
        $sb = New-Object System.Text.StringBuilder 256
        [WindowEnumerator]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
        $title = $sb.ToString()
        
        if ($title.Length -gt 0) {
            $script:windows += [PSCustomObject]@{
                Handle = "0x" + $hwnd.ToString("X")
                Title = $title
            }
        }
    }
    
    return $true
}

$enumProc = [WindowEnumerator+EnumWindowsProc]$callback
[WindowEnumerator]::EnumWindows($enumProc, [IntPtr]::Zero) | Out-Null

if ($Filter) {
    Write-Host "Filter: *$Filter*"
    Write-Host ""
    $windows = $windows | Where-Object { $_.Title -like "*$Filter*" }
}

if ($windows.Count -eq 0) {
    Write-Host "No windows found!"
    if ($Filter) {
        Write-Host ""
        Write-Host "Tip: Make sure the window with '$Filter' is open and not minimized"
    }
} else {
    Write-Host "Found $($windows.Count) window(s):"
    Write-Host ""
    
    $i = 1
    foreach ($window in $windows) {
        Write-Host "[$i] Title: $($window.Title)"
        Write-Host "    Handle: $($window.Handle)"
        Write-Host ""
        $i++
    }
}

Write-Host "======================================"

