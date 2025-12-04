@echo off
chcp 65001 > nul
echo ======================================
echo   查看 Keltner Webhook 服务日志
echo ======================================
echo.
echo 按 Ctrl+C 退出日志查看
echo.

cd /d "%~dp0"

call pm2 logs keltner-webhook --lines 50

