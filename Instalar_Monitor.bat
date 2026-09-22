@echo off
setlocal
:: Instalador del Monitor de Red (MR) - solicita elevacion de administrador automaticamente.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" 
    exit /b
)
:: [v1.9] En el paquete el asistente esta en sistema\; en la copia de C:\ProgramData\MRV1 esta junto al BAT.
set "MRV1_PS1=%~dp0sistema\Instalar_Monitor.ps1"
if not exist "%MRV1_PS1%" set "MRV1_PS1=%~dp0Instalar_Monitor.ps1"
if not exist "%MRV1_PS1%" goto :SinAsistente
powershell -NoProfile -ExecutionPolicy Bypass -File "%MRV1_PS1%"
if %errorlevel% neq 0 (
    echo.
    echo La instalacion no se completo correctamente. Revise los mensajes anteriores.
    pause
    exit /b 1
)
pause
exit /b 0

:SinAsistente
echo No se encontro Instalar_Monitor.ps1 en la carpeta sistema ni junto a este BAT.
echo Descargue de nuevo el paquete completo.
pause
exit /b 1
