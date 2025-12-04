@echo off
chcp 65001 > nul
echo ======================================
echo   使用 PM2 启动 Keltner Webhook 服务
echo ======================================
echo.

cd /d "%~dp0\.."

REM 检查 PM2 是否已安装
call npm list -g pm2 >nul 2>&1
if errorlevel 1 (
    echo [提示] 首次使用，正在安装 PM2...
    call npm install -g pm2
    echo.
)

echo [1/3] 启动服务...
call pm2 start pm2\ecosystem.config.js

echo.
echo [2/3] 保存进程列表...
call pm2 save

echo.
echo [3/3] 查看状态...
call pm2 status

echo.
echo ======================================
echo   ✅ 服务已启动！
echo ======================================
echo.
echo 常用命令:
echo   查看日志: pm2 logs EA&CTrader-Webhook
echo   停止服务: pm2 stop EA&CTrader-Webhook
echo   重启服务: pm2 restart EA&CTrader-Webhook
echo   查看状态: pm2 status
echo.
echo 服务地址: http://localhost:6699
echo.

pause

