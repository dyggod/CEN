@echo off
chcp 65001 > nul
echo ======================================
echo   Keltner Webhook 服务器
echo ======================================
echo.
echo 正在启动服务器...
echo.

cd /d "%~dp0"
npm start

pause

