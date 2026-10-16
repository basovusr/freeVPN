@echo off
chcp 936 >nul 2>&1
title 创建桌面快捷方式

set "ROOT=%~dp0"
set "LNK=%USERPROFILE%\Desktop\启动代理.lnk"

echo.
echo   正在创建桌面快捷方式: 启动代理
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "$w=New-Object -ComObject WScript.Shell; $s=$w.CreateShortcut($env:USERPROFILE+'\Desktop\启动代理.lnk'); $s.TargetPath='%ROOT%启动代理.bat'; $s.WorkingDirectory='%ROOT%'; $s.IconLocation='%SystemRoot%\System32\shell32.dll,13'; $s.Description='启动本地代理'; $s.Save()"

if exist "%LNK%" (
  echo   [OK] 已在桌面创建: 启动代理
  echo.
  echo   提示: 右键该快捷方式可「固定到任务栏」
  echo         想要总菜单，把「菜单.bat」也发送到桌面即可
) else (
  echo   [失败] 自动创建失败
  echo   手动方法: 右键「启动代理.bat」- 发送到 - 桌面快捷方式
)
echo.
pause
exit /b 0
