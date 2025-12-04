@echo off
chcp 65001 > nul
echo ======================================
echo   完全删除 Keltner Webhook 服务
echo ======================================
echo.
echo ⚠️  警告：此操作将完全删除服务！
echo.
echo 按任意键继续，或关闭窗口取消...
pause > nul

cd /d "%~dp0"

echo.
echo 正在停止并删除服务...
call pm2 delete keltner-webhook

echo.
echo ✅ 服务已删除！
echo.
echo 如需重新启动，请运行 PM2启动.bat
echo.

pause

