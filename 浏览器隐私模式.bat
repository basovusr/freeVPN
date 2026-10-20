@echo off
chcp 936 >nul 2>&1
title 浏览器隐私模式（禁用 WebRTC）

set "FLAG=--force-webrtc-ip-handling-policy=disable_non_proxied_udp"

echo.
echo   ========================================================
echo     以隐私模式启动浏览器
echo   ========================================================
echo.
echo     作用: 禁止浏览器通过非代理 UDP 发送 WebRTC 流量,
echo           避免网页用 JS 拿到你的真实 IP。
echo.
echo     注意: 必须【先完全退出浏览器】再运行本脚本,
echo           否则参数不会生效(浏览器会复用已有进程)。
echo.
echo   --------------------------------------------------------
echo     [1] Edge
echo     [2] Chrome
echo     [3] 先关闭浏览器再用 Edge 启动
echo     [4] 退出
echo   --------------------------------------------------------
echo.
set "CH="
set /p "CH=  请选择 [1-4]: "

if "%CH%"=="1" goto EDGE
if "%CH%"=="2" goto CHROME
if "%CH%"=="3" goto KILL_EDGE
if "%CH%"=="4" exit /b 0
exit /b 0

:KILL_EDGE
echo.
echo   正在关闭 Edge...
taskkill /F /IM msedge.exe >nul 2>&1
timeout /t 2 /nobreak >nul
goto EDGE

:EDGE
if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" (
  start "" "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" %FLAG%
  goto DONE
)
if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" (
  start "" "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" %FLAG%
  goto DONE
)
echo   未找到 Edge
pause
exit /b 0

:CHROME
if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" (
  start "" "%ProgramFiles%\Google\Chrome\Application\chrome.exe" %FLAG%
  goto DONE
)
if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" (
  start "" "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" %FLAG%
  goto DONE
)
echo   未找到 Chrome
pause
exit /b 0

:DONE
echo.
echo   [OK] 已以隐私模式启动
echo.
echo   验证方法: 浏览器访问 https://browserleaks.com/webrtc
echo             如果 Public IP 显示的是 Cloudflare 地址(不是 111.198.61.46)
echo             说明 WebRTC 泄漏已被阻止。
echo.
pause
exit /b 0