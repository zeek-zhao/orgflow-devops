@echo off
rem ============================================================
rem  orgflow-devops Windows 验收脚本（#47）
rem
rem  ★ 编码：GBK(936) + CRLF，两个都不能改。
rem    - 存成 UTF-8 会让下面的中文提示全变乱码；
rem    - 行尾变 LF 会让 goto / if 块解析错乱，症状是「跑到一半就退出」，不报错。
rem    .gitattributes 里已对 *.bat 声明 eol=crlf，别删那条。
rem
rem  用法：
rem    acceptance.bat add      加 hosts（6 条，指向网关）
rem    acceptance.bat remove   删 hosts（只删自己的标记块）
rem    acceptance.bat trust    从网关拉根证书并导入「受信任的根证书颁发机构」
rem    acceptance.bat verify   只读自检：hosts / 根证书 / 6 个站点
rem    acceptance.bat all      add + trust + verify
rem ============================================================

setlocal EnableExtensions
chcp 936 >nul 2>&1

set "SCRIPT_DIR=%~dp0"
set "ACTION=%~1"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"

if /i "%ACTION%"=="" goto :usage

rem 四个动作都要写 hosts 或写 LocalMachine 证书存储，一律需要管理员。
rem net session 是判断提权最轻的办法，不依赖 whoami 的输出格式。
net session >nul 2>&1
if errorlevel 1 (
    echo 需要管理员权限，正在提权...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%ACTION%' -Verb RunAs"
    exit /b
)

if /i "%ACTION%"=="add" goto :do_add
if /i "%ACTION%"=="remove" goto :do_remove
if /i "%ACTION%"=="trust" goto :do_trust
if /i "%ACTION%"=="verify" goto :do_verify
if /i "%ACTION%"=="all" goto :do_all

echo 未知动作：%ACTION%
goto :usage

:do_add
%PS% "%SCRIPT_DIR%Set-OrgflowHosts.ps1" -Action Add
goto :report

:do_remove
%PS% "%SCRIPT_DIR%Set-OrgflowHosts.ps1" -Action Remove
goto :report

:do_trust
%PS% "%SCRIPT_DIR%Import-OrgflowRootCa.ps1"
goto :report

:do_verify
%PS% "%SCRIPT_DIR%Test-OrgflowAcceptance.ps1"
goto :report

:do_all
%PS% "%SCRIPT_DIR%Set-OrgflowHosts.ps1" -Action Add
if errorlevel 1 goto :report
%PS% "%SCRIPT_DIR%Import-OrgflowRootCa.ps1"
if errorlevel 1 goto :report
%PS% "%SCRIPT_DIR%Test-OrgflowAcceptance.ps1"
goto :report

:report
if errorlevel 1 (
    echo.
    echo [失败] 上一步没有通过，按提示处理后重跑本脚本。
    echo        证书问题可以先跑：acceptance.bat trust
) else (
    echo.
    echo [完成] 上一步已通过。
)
pause
exit /b

:usage
echo.
echo orgflow-devops Windows 验收脚本
echo.
echo   acceptance.bat add      加 hosts（6 条，指向 192.0.2.10）
echo   acceptance.bat remove   删 hosts（只删自己的标记块）
echo   acceptance.bat trust    从网关拉根证书并导入受信任根
echo   acceptance.bat verify   只读自检（hosts / 根证书 / 6 个站点）
echo   acceptance.bat all      add + trust + verify
echo.
echo 需要管理员权限，脚本会自己提权。
echo.
exit /b 2
