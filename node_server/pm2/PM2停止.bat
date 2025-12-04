@echo off
chcp 65001 > nul
echo ======================================
echo   停止 Keltner Webhook 服务
echo ======================================
echo.

cd /d "%~dp0\.."

call pm2 stop EA&CTrader-Webhook
echo.
call pm2 status

echo.
echo ✅ 服务已停止！
echo.
pause

