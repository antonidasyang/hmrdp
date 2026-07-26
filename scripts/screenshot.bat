@echo off
chcp 65001 >nul
REM 从已连接设备抓一张全屏截图，存到 tmp\shots\（Windows）。
REM 用法: scripts\screenshot.bat 名字
REM   例: scripts\screenshot.bat 01-电脑列表
REM 不给名字则用时间戳。抓完会打印图片实际像素尺寸，便于对照 AGC 的要求。
setlocal enabledelayedexpansion
cd /d "%~dp0.."

if "%DEVECO_HOME%"=="" set "DEVECO_HOME=C:\Program Files\Huawei\DevEco Studio"

set "HDC=hdc"
where hdc >nul 2>nul
if errorlevel 1 (
  set "HDC=%DEVECO_HOME%\sdk\default\openharmony\toolchains\hdc.exe"
  if not exist "!HDC!" set "HDC=%LOCALAPPDATA%\OpenHarmony\Sdk\default\openharmony\toolchains\hdc.exe"
)

set "NAME=%~1"
if "%NAME%"=="" (
  for /f "tokens=1-6 delims=/:. " %%a in ("%date% %time%") do set "NAME=shot-%%a%%b%%c-%%d%%e%%f"
)

if not exist "tmp\shots" mkdir "tmp\shots"
set "REMOTE=/data/local/tmp/hmrdp_shot.png"
set "LOCAL=tmp\shots\%NAME%.png"

echo [抓图] 设备端截屏...
"%HDC%" shell snapshot_display -f %REMOTE% >nul 2>nul
if errorlevel 1 (
  echo [提示] snapshot_display 失败，改用 jpeg 再试
  set "REMOTE=/data/local/tmp/hmrdp_shot.jpeg"
  set "LOCAL=tmp\shots\%NAME%.jpeg"
  "%HDC%" shell snapshot_display -f !REMOTE!
)

echo [取回] %LOCAL%
"%HDC%" file recv %REMOTE% "%LOCAL%" >nul
if not exist "%LOCAL%" (
  echo [失败] 没取回文件。检查设备是否连上: "%HDC%" list targets
  exit /b 1
)
"%HDC%" shell rm -f %REMOTE% >nul 2>nul

powershell -NoProfile -Command "Add-Type -AssemblyName System.Drawing; $i=[System.Drawing.Image]::FromFile((Resolve-Path '%LOCAL%')); Write-Host ('[完成] {0}  {1}x{2}  {3:N0} KB' -f '%LOCAL%', $i.Width, $i.Height, ((Get-Item '%LOCAL%').Length/1KB)); $i.Dispose()"
endlocal
