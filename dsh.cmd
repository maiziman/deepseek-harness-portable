@echo off
rem DeepSeek Harness portable CLI shim.
rem Usage:  dsh.cmd web --port 8080 | dsh.cmd --profile headless "task in quotes"
setlocal
set "ROOT=%~dp0"
set "DSH_HOME=%ROOT%dsh-home"
set "PATH=%ROOT%runtime;%PATH%"
"%ROOT%runtime\node.exe" "%ROOT%app\node_modules\@deepseek-ai\dsh\lib\bin.js" %*
exit /b %ERRORLEVEL%
