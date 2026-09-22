@echo off
:: Abre la consola de solo lectura del Monitor de Red. No requiere permisos de administrador.
set MRV1_ROOT=C:\ProgramData\MRV1
if not exist "%MRV1_ROOT%\bin\Monitor_Red_Console.ps1" (
    echo No se encontro el Monitor de Red instalado en %MRV1_ROOT%.
    echo Ejecute primero Instalar_Monitor.bat.
    pause
    exit /b 1
)
start "Monitor de Red - Consola" powershell -NoProfile -ExecutionPolicy Bypass -File "%MRV1_ROOT%\bin\Monitor_Red_Console.ps1" -Root "%MRV1_ROOT%"
