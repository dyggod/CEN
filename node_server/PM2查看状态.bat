@echo off
chcp 65001 > nul
echo ======================================
echo   Keltner Webhook 服务状态
echo ======================================
echo.

cd /d "%~dp0"

call pm2 status
echo.
call pm2 info keltner-webhook

echo.
pause

