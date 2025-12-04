@echo off
chcp 65001 > nul
echo ======================================
echo   重启 Keltner Webhook 服务
echo ======================================
echo.

cd /d "%~dp0\.."

call pm2 restart EA&CTrader-Webhook
echo.
call pm2 status

echo.
echo ✅ 服务已重启！
echo.
pause

