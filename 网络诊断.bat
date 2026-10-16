@echo off
chcp 936 >nul 2>&1
title »´Õ¯’Ô∂œ

set "ROOT=%~dp0"

echo.
echo   ========================================================
echo     ∂ÀµΩ∂À’Ô∂œ
echo   ========================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\diag.ps1"

echo.
pause
exit /b 0
