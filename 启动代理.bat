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
echo     首次运行会自动下载组件并注册免费 WARP 账号，
echo     可能停留几分钟，请不要关闭窗口。
echo.

rem 说明：系统代理的开与关一律由 ctl.ps1 决定。
rem 只有端到端探测通过后它才会开启，探测不通过会保持关闭，
rem 这样即使上游不通，你的正常上网也不会被影响。
powershell -NoProfile -ExecutionPolicy Bypass -File "%CTL%" -Action Start
set "RC=%ERRORLEVEL%"

echo.
echo   --------------------------------------------------------
echo     浏览器处理
echo   --------------------------------------------------------
rem 已经在运行的浏览器不会重新读取代理设置，需要重启才生效。
set "BROWSER="
tasklist /FI "IMAGENAME eq msedge.exe" 2>nul | find /I "msedge" >nul && set "BROWSER=msedge"
if not defined BROWSER (
  tasklist /FI "IMAGENAME eq chrome.exe" 2>nul | find /I "chrome" >nul && set "BROWSER=chrome"
)

if not defined BROWSER (
  echo   浏览器未运行，直接打开即可生效。
  goto PROBE
)

echo   检测到浏览器正在运行，需要重启它代理才会生效。
echo   为避免丢失页面，先确认一下。
echo.
set "RB="
set /p "RB=  现在自动重启浏览器? [Y/n]: "
if /I "%RB%"=="n" (
  echo.
  echo   已跳过。请自己完全关闭浏览器再重新打开，
  echo   否则浏览器仍会直连，国外网站打不开。
  goto PROBE
)

echo.
echo   正在重启浏览器...
taskkill /F /IM msedge.exe >nul 2>&1
taskkill /F /IM chrome.exe >nul 2>&1
timeout /t 2 /nobreak >nul
if "%BROWSER%"=="msedge" (
  if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" start "" "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
  if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" start "" "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
)
if "%BROWSER%"=="chrome" (
  if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" start "" "%ProgramFiles%\Google\Chrome\Application\chrome.exe"
  if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" start "" "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
)
timeout /t 2 /nobreak >nul
echo   [OK] 浏览器已重启

:PROBE
echo.
echo   --------------------------------------------------------
echo     验证 Google 连通性
echo   --------------------------------------------------------
set "CODE=000"
set "TRY=0"
:PROBERETRY
set /a TRY+=1
for /f %%i in ('curl -s -o NUL -x http://127.0.0.1:7890 -w "%%{http_code}" --max-time 30 https://www.google.com/generate_204 2^>nul') do set "CODE=%%i"
if "%CODE%"=="204" goto OK
if "%CODE%"=="200" goto OK
if %TRY% GEQ 4 goto FAILED
echo       第 %TRY% 次探测失败 (HTTP %CODE%)，稍等后重试...
timeout /t 2 /nobreak >nul
goto PROBERETRY

:FAILED
echo.
echo   [!] 连续 4 次探测 Google 均不通 (最后 HTTP %CODE%)
echo.
echo       已自动保持系统代理为【关闭】，你的正常上网不受影响。
echo       免费 WARP 有约 10-30%% 的偶发失败，可以：
echo         1. 再运行一次本脚本
echo         2. 运行「网络诊断.bat」看具体原因
echo.
goto DONE

:OK
echo.
echo   [OK] Google 已连通 —— 代理可以正常使用了
echo.
echo       控制面板: http://127.0.0.1:9090/ui
echo.

:DONE
echo   ========================================================
echo     本窗口可以直接关闭，代理在后台继续运行
echo   ========================================================
echo.
pause
exit /b 0
