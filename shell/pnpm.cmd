@ECHO OFF
setlocal
if not defined DSH_HOME set "DSH_HOME=%~dp0..\dsh-home"
set "pnpm_config_cache_dir=%DSH_HOME%\pnpm-cache"
set "pnpm_config_state_dir=%DSH_HOME%\pnpm-state"
set "pnpm_config_store_dir=%DSH_HOME%\pnpm-store"
set "NODE_COMPILE_CACHE=%DSH_HOME%\node-compile-cache"
set "NODE_COMPILE_CACHE_PORTABLE=1"
"%~dp0node.exe" "%~dp0node_modules\pnpm\bin\pnpm.cjs" %*
exit /b %ERRORLEVEL%
