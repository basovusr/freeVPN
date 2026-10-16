@echo off
chcp 936 >nul 2>&1
title 停止本地代理

set "ROOT=%~dp0"
set "CTL=%ROOT%scripts\ctl.ps1"

echo.
echo   ========================================================
echo     正在停止本地代理...
echo   ========================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%CTL%" -Action Stop
powershell -NoProfile -ExecutionPolicy Bypass -File "%CTL%" -Action WarpStop

rem ------------------------------------------------------------------
rem  Turn the system proxy back OFF. If we leave it on while the proxy is
rem  stopped, the browser would be pointed at a dead port and NOTHING would
rem  load - including domestic sites.
rem ------------------------------------------------------------------
:DISABLE_SYSPROXY
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\system-proxy.ps1" -Disable -Quiet
echo   [OK] 系统代理已关闭（避免浏览器指向已停止的代理）

echo.
echo   [OK] 已全部停止
echo.
echo   要把浏览器也恢复成直连，请完全退出浏览器后重新打开即可。
echo.
pause
exit /b 0
