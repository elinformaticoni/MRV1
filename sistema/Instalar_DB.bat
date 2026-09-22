@echo off
setlocal
:: Instalador de la carga a la API de analisis del Monitor de Red (MR) - solicita elevacion automaticamente.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar_DB.ps1"
if %errorlevel% neq 0 (
    echo.
    echo La configuracion no se completo correctamente. Revise los mensajes anteriores.
    pause
    exit /b 1
)
pause
