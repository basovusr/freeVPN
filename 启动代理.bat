@echo off
chcp 936 >nul 2>&1
title 启动本地代理

set "ROOT=%~dp0"
set "CTL=%ROOT%scripts\ctl.ps1"

echo.
echo   ========================================================
echo     正在启动本地代理...
echo   ========================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%CTL%" -Action Start

rem ------------------------------------------------------------------
rem  Browser fix: a browser only reads proxy settings when it starts, and
rem  the system proxy is OFF by default. Without this, double-clicking the
rem  browser icon bypasses the proxy and overseas sites stay unreachable.
rem ------------------------------------------------------------------
:ENABLE_SYSPROXY
echo.
echo   --------------------------------------------------------
echo     正在配置浏览器走代理 (系统代理)...
echo   --------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\system-proxy.ps1" -Enable -Quiet

rem Restart the browser if it is running, otherwise it keeps the old settings.
set "BROWSER="
tasklist /FI "IMAGENAME eq msedge.exe" 2>nul | find /I "msedge" >nul && set "BROWSER=msedge"
if not defined BROWSER (
  tasklist /FI "IMAGENAME eq chrome.exe" 2>nul | find /I "chrome" >nul && set "BROWSER=chrome"
)

if not defined BROWSER goto PROBE

echo.
echo   [!] 检测到浏览器正在运行，需要重启它才能让代理生效
echo       为避免丢失页面，先确认一下再继续。
echo.
set "RB="
set /p "RB=  现在自动重启浏览器? [Y/n]: "
if /I "%RB%"=="n" (
  echo.
  echo       已跳过。请自己完全关闭浏览器再重新打开，
  echo       否则浏览器仍会直连，国外网站打不开。
  goto PROBE
)

echo.
echo   正在重启浏览器...
taskkill /F /IM msedge.exe >nul 2>&1
taskkill /F /IM chrome.exe >nul 2>&1
timeout /t 2 /nobreak >nul
if "%BROWSER%"=="msedge" (
  if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" start "" "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
)
if "%BROWSER%"=="chrome" (
  if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" start "" "%ProgramFiles%\Google\Chrome\Application\chrome.exe"
)
timeout /t 2 /nobreak >nul
echo   [OK] 浏览器已重启，现在会走代理

echo.
echo   --------------------------------------------------------
echo     验证 Google 连通性...
echo   --------------------------------------------------------
rem Retry: free WARP has ~10-30%% transient failures. One blip must not
rem produce a scary warning, so probe up to 4 times with a short backoff.
set "CODE=000"
set "TRY=0"
:PROBE
set /a TRY+=1
for /f %%i in ('curl -s -o NUL -x http://127.0.0.1:7890 -w "%%{http_code}" --max-time 30 https://www.google.com/generate_204 2^>nul') do set "CODE=%%i"
if "%CODE%"=="204" goto OK
if "%CODE%"=="200" goto OK
if %TRY% GEQ 4 goto FAILED
echo       第 %TRY% 次探测失败 (HTTP %CODE%)，稍等后重试...
timeout /t 2 /nobreak >nul
goto PROBE

:FAILED

echo.
echo   [!] 连续 4 次探测 Google 均不通 (最后 HTTP %CODE%)
echo.
echo       免费 WARP 有约 10-30%% 的偶发失败，通常刷新重试即可。
echo       可以试试:
echo         1. 再运行一次本脚本
echo         2. 在菜单里选 [6] 全网诊断 看具体原因
echo.
goto DONE

:OK
echo.
echo   [OK] Google 已连通 —— 代理可以正常使用了
echo.
echo       浏览器走代理: 运行「浏览器设置.bat」
echo       控制面板:     http://127.0.0.1:9090/ui
echo.

:DONE
echo   ========================================================
echo     本窗口可以直接关闭，代理在后台继续运行
echo   ========================================================
echo.
pause
exit /b 0
