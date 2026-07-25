@echo off
chcp 65001 >nul
REM 安装已构建的 HAP 到已连接设备，并实时打印 HMRDP 相关日志（Windows）。
REM 用法: scripts\install_and_log.bat [nolog]
REM 过滤在设备侧用 grep 完成（ASCII 关键字 HMRDP），避免 Windows 管道把中文日志弄乱码。
setlocal
cd /d "%~dp0.."

if "%DEVECO_HOME%"=="" set "DEVECO_HOME=C:\Program Files\Huawei\DevEco Studio"

REM 找 hdc：优先 PATH，其次 DevEco SDK，再次用户级 OpenHarmony SDK
set "HDC=hdc"
where hdc >nul 2>nul
if errorlevel 1 (
  set "HDC=%DEVECO_HOME%\sdk\default\openharmony\toolchains\hdc.exe"
  if not exist "%DEVECO_HOME%\sdk\default\openharmony\toolchains\hdc.exe" (
    set "HDC=%LOCALAPPDATA%\OpenHarmony\Sdk\default\openharmony\toolchains\hdc.exe"
  )
)

set "HAP=entry\build\default\outputs\default\entry-default-signed.hap"
if not exist "%HAP%" (
  echo [错误] 找不到 %HAP%，先跑 scripts\build_hap.bat
  exit /b 1
)

echo [安装] %HAP%
"%HDC%" install -r "%HAP%"
if errorlevel 1 (
  echo [失败] 安装未通过（设备没连上？先跑 "%HDC%" list targets 看看）
  exit /b 1
)

if /i "%~1"=="nolog" goto :end

echo.
echo [日志] 过滤 HMRDP（Ctrl+C 结束）。关注这几条：
echo        HMRDP 键盘拦截态=true/false
echo        HMRDP 返回桌面热键：... 原生=... 系统订阅=... 拦截态=...
echo        返回桌面热键命中 / 未命中
echo        HMRDP 热键录入：收到按键 code=...
echo.
"%HDC%" shell "hilog | grep HMRDP"

:end
endlocal
