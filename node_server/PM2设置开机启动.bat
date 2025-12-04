@echo off
chcp 65001 > nul
echo ======================================
echo   设置 PM2 开机自动启动
echo ======================================
echo.
echo ⚠️  需要管理员权限！
echo.
echo 按任意键继续，或关闭窗口取消...
pause > nul

cd /d "%~dp0"

echo.
echo [1/3] 配置 PM2 开机启动...
call pm2 startup

echo.
echo [2/3] 保存当前进程列表...
call pm2 save

echo.
echo [3/3] 完成！
echo.
echo ======================================
echo   ✅ 开机启动已配置！
echo ======================================
echo.
echo 提示：
echo 1. 请务必按照上方提示执行显示的命令（如果有）
echo 2. 下次开机后，服务将自动启动
echo 3. 取消开机启动：pm2 unstartup
echo.

pause

