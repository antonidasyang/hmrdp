@echo off
REM 清掉新手引导的已读标记，下次连接电脑会重新走一遍向导。
REM 引导标记存在 preferences 的 hmrdp_settings 里；preferences 有内存缓存，必须先停掉应用。
setlocal
set PKG=com.d2ssoft.hmrdp
set PREF=/data/app/el2/100/base/%PKG%/haps/entry/preferences/hmrdp_settings

echo [1/2] 停止应用...
hdc shell aa force-stop %PKG%

echo [2/2] 清除引导标记...
hdc shell rm -f %PREF%

echo.
echo 完成。重新打开 HMRDP 并连接一台电脑，向导会重新出现。
echo （注意：返回桌面热键的自定义设置也会一并恢复默认）
endlocal
