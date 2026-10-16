@echo off
chcp 936 >nul 2>&1
setlocal enabledelayedexpansion
title 本地代理控制台

set "ROOT=%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "CTL=%ROOT%scripts\ctl.ps1"

:MENU
cls
echo.
echo   ========================================================
echo     本地代理控制台
echo   ========================================================
echo.
call :SHOWSTATUS
echo.
echo   --------------------------------------------------------
echo     [1]  启动代理          WARP + 内核，自动自检
echo     [2]  停止代理          全部停止
echo     [3]  重启代理
echo.
echo     [4]  查看状态          节点延迟 / 当前出口
echo     [5]  环境体检          内核 / WARP / 配置
echo     [6]  全网诊断          完整端到端诊断
echo.
echo     [7]  浏览器设置指引
echo     [8]  命令行代理设置
echo     [9]  打开控制面板
echo     [0]  退出
echo   --------------------------------------------------------
echo.
set "CH="
set /p "CH=  请选择: "

if "%CH%"=="1" goto ACT_START
if "%CH%"=="2" goto ACT_STOP
if "%CH%"=="3" goto ACT_RESTART
if "%CH%"=="4" goto ACT_STATUS
if "%CH%"=="5" goto ACT_CHECK
if "%CH%"=="6" goto ACT_DIAG
if "%CH%"=="7" goto ACT_BROWSER
if "%CH%"=="8" goto ACT_ENV
if "%CH%"=="9" goto ACT_PANEL
if "%CH%"=="0" goto END
goto MENU

:SHOWSTATUS
set "MC=[已停止]"
set "WC=[已停止]"
tasklist /FI "IMAGENAME eq mihomo.exe" 2>nul | find /I "mihomo" >nul && set "MC=[运行中]"
tasklist /FI "IMAGENAME eq usque.exe"  2>nul | find /I "usque"  >nul && set "WC=[运行中]"
echo     内核 mihomo: !MC!        隧道 WARP: !WC!
exit /b 0

:ACT_START
echo.
%PS% "%CTL%" -Action Start
goto AFTER

:ACT_STOP
echo.
%PS% "%CTL%" -Action Stop
%PS% "%CTL%" -Action WarpStop
goto AFTER

:ACT_RESTART
echo.
%PS% "%CTL%" -Action Restart
goto AFTER

:ACT_STATUS
echo.
%PS% "%CTL%" -Action Status
%PS% "%CTL%" -Action WarpStatus
goto AFTER

:ACT_CHECK
echo.
%PS% "%CTL%" -Action Check
goto AFTER

:ACT_DIAG
echo.
%PS% "%ROOT%scripts\diag.ps1"
goto AFTER

:ACT_BROWSER
echo.
%PS% "%CTL%" -Action Browser
goto AFTER

:ACT_ENV
echo.
%PS% "%CTL%" -Action Env
goto AFTER

:ACT_PANEL
start "" "http://127.0.0.1:9090/ui"
goto AFTER

:AFTER
echo.
echo   ========================================================
echo     代理在后台运行，本窗口可直接关闭
echo   ========================================================
echo.
pause
goto MENU

:END
endlocal
exit /b 0
