@echo off
setlocal
:: Instalador del Cargador FTP del Monitor de Red (MR) - solicita elevacion automaticamente.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar_FTP.ps1"
if %errorlevel% neq 0 (
    echo.
    echo La instalacion no se completo correctamente. Revise los mensajes anteriores.
    pause
    exit /b 1
)
pause
