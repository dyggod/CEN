@echo off
chcp 65001 > nul
cls
echo ========================================
echo   cTrader Screenshot - Quick Diagnosis
echo ========================================
echo.

cd /d "%~dp0"

echo Step 1: Searching for cTrader window...
echo.
powershell -ExecutionPolicy Bypass -File "list-windows.ps1" -Filter "cTrader"

echo.
echo ========================================
echo.
echo Did you see your cTrader window above?
echo.
echo If YES - Note the window title (e.g., "IC Markets - cTrader")
echo          Then press ENTER to test screenshot
echo.
echo If NO  - Press Ctrl+C to exit
echo          Make sure cTrader is open and not minimized
echo.
pause > nul

echo.
echo ========================================
echo Step 2: Testing screenshot...
echo ========================================
echo.

powershell -ExecutionPolicy Bypass -File "capture-window.ps1" -WindowTitle "IC Markets cTrader 5.5.13" -OutputPath "screenshots\test_capture.png"

if %errorlevel% equ 0 (
    echo.
    echo ========================================
    echo   SUCCESS! Screenshot saved
    echo ========================================
    echo.
    echo File: screenshots\test_capture.png
    echo.
    echo Opening screenshot...
    start screenshots\test_capture.png
) else (
    echo.
    echo ========================================
    echo   FAILED! Screenshot not captured
    echo ========================================
    echo.
    echo Possible reasons:
    echo 1. Window title does not contain "cTrader"
    echo 2. Window is minimized
    echo.
    echo Solution:
    echo 1. Check the window title from Step 1 above
    echo 2. Edit server.js, line ~24:
    echo    CTRADER_WINDOW_TITLE: 'YourActualTitle',
    echo.
    echo Example: If title is "IC Markets - cTrader"
    echo          Use: CTRADER_WINDOW_TITLE: 'IC Markets',
    echo.
)

echo.
pause

