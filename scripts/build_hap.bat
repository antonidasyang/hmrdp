@echo off
chcp 65001 >nul
REM 命令行构建 HAP（Windows）。用 DevEco Studio 自带的 node/jbr/sdk，无需另装。
REM 用法: scripts\build_hap.bat [debug^|release]   默认 debug
REM DevEco 装在别处时，先设环境变量再跑：
REM   set "DEVECO_HOME=D:\DevEco Studio"
setlocal
cd /d "%~dp0.."

if "%DEVECO_HOME%"=="" set "DEVECO_HOME=C:\Program Files\Huawei\DevEco Studio"
if not exist "%DEVECO_HOME%\tools\hvigor\bin\hvigorw.bat" (
  echo [错误] 找不到 DevEco Studio: "%DEVECO_HOME%"
  echo        先执行:  set "DEVECO_HOME=你的DevEco安装目录"
  exit /b 1
)

set "NODE_HOME=%DEVECO_HOME%\tools\node"
set "JAVA_HOME=%DEVECO_HOME%\jbr"
set "DEVECO_SDK_HOME=%DEVECO_HOME%\sdk"
set "PATH=%NODE_HOME%;%JAVA_HOME%\bin;%PATH%"

set "MODE=%~1"
if "%MODE%"=="" set "MODE=debug"

echo [构建] mode=%MODE%
call "%DEVECO_HOME%\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default -p buildMode=%MODE% --no-daemon
if errorlevel 1 (
  echo [失败] 构建未通过
  exit /b 1
)

echo.
echo [产物]
dir /b /s entry\build\default\outputs\default\*.hap
endlocal
