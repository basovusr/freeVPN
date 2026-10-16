@echo off
chcp 936 >nul 2>&1
title 系统代理开关

set "ROOT=%~dp0"
set "SP=%ROOT%scripts\system-proxy.ps1"

:MENU
cls
echo.
echo   ========================================================
echo     系统代理开关
echo   ========================================================
echo.
echo     说明: 本方案默认【不需要】开系统代理。
echo           浏览器用 PAC、命令行用环境变量即可，
echo           这样微信/钉钉/游戏等软件完全不受影响。
echo.
echo           只有想让【所有软件】都走代理时才需要开。
echo.
echo   --------------------------------------------------------
echo     [1]  开启系统代理
echo     [2]  关闭系统代理
echo     [3]  查看当前状态
echo     [4]  返回
echo   --------------------------------------------------------
echo.
set "CH="
set /p "CH=  请选择 [1-4]: "

if "%CH%"=="1" goto ON
if "%CH%"=="2" goto OFF
if "%CH%"=="3" goto ST
if "%CH%"=="4" exit /b 0
goto MENU

:ON
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SP%" -Enable
echo.
pause
goto MENU

:OFF
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SP%" -Disable
echo.
pause
goto MENU

:ST
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SP%" -Status
echo.
pause
goto MENU
