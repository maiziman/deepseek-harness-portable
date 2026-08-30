@echo off
rem DeepSeek Harness portable CLI shim.
rem Usage:  dsh.cmd web --port 8080 | dsh.cmd --profile headless "task in quotes"
rem Starts the packaged official CLI with this folder's portable data home.
setlocal
set "ROOT=%~dp0"
set "DSH_HOME=%ROOT%dsh-home"
set "PATH=%ROOT%runtime;%PATH%"
set "pnpm_config_cache_dir=%DSH_HOME%\pnpm-cache"
set "pnpm_config_state_dir=%DSH_HOME%\pnpm-state"
set "pnpm_config_store_dir=%DSH_HOME%\pnpm-store"
set "NODE_COMPILE_CACHE=%DSH_HOME%\node-compile-cache"
set "NODE_COMPILE_CACHE_PORTABLE=1"
"%ROOT%runtime\node.exe" "%ROOT%app\node_modules\@deepseek-ai\dsh\lib\bin.js" %*
exit /b %ERRORLEVEL%
