@echo off
chcp 936 >nul 2>&1
title 浏览器代理设置

set "ROOT=%~dp0"
set "PAC=file:///%ROOT:\=/%config/browser.pac"

echo.
echo   ========================================================
echo     让浏览器走代理 (不修改系统设置)
echo   ========================================================
echo.
echo     推荐做法: 用 PAC 定向代理
echo       - 只有名单内的国外网站走代理
echo       - 国内网站仍然直连，速度不受影响
echo       - 不碰系统代理设置，微信/游戏等不受影响
echo.
echo   --------------------------------------------------------
echo     用法: 先【完全退出】浏览器，再选下面的选项
echo   --------------------------------------------------------
echo.
echo     [1]  用 PAC 启动 Edge
echo     [2]  用 PAC 启动 Chrome
echo     [3]  仅显示 PAC 地址 (手动配置用)
echo     [4]  打开控制面板
echo     [5]  返回
echo.
set "CH="
set /p "CH=  请选择 [1-5]: "

if "%CH%"=="1" goto EDGE
if "%CH%"=="2" goto CHROME
if "%CH%"=="3" goto SHOW
if "%CH%"=="4" goto PANEL
if "%CH%"=="5" exit /b 0
exit /b 0

:EDGE
if not exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" goto NOEDGE
echo.
echo   正在启动 Edge...
start "" "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" --proxy-pac-url="%PAC%"
goto DONE

:NOEDGE
echo.
echo   未找到 Edge
pause
exit /b 0

:CHROME
if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" (
  start "" "%ProgramFiles%\Google\Chrome\Application\chrome.exe" --proxy-pac-url="%PAC%"
  goto DONE
)
if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" (
  start "" "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" --proxy-pac-url="%PAC%"
  goto DONE
)
echo.
echo   未找到 Chrome
pause
exit /b 0

:SHOW
echo.
echo   PAC 地址 (复制到浏览器或 SwitchyOmega):
echo.
echo     %PAC%
echo.
echo   手动代理地址: 127.0.0.1 : 7890
echo.
pause
exit /b 0

:PANEL
start "" "http://127.0.0.1:9090/ui"
exit /b 0

:DONE
echo.
echo   已启动。打开 https://www.google.com 验证是否可用。
echo.
pause
exit /b 0
