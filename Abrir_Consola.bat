@echo off
:: Abre la consola del Monitor de Red (solo lectura). No requiere permisos de administrador.
::   Abrir_Consola.bat          -> consola web (se abre en el navegador, con grafico de latencia)
::   Abrir_Consola.bat texto    -> consola de texto clasica (esta ventana)
set MRV1_ROOT=C:\ProgramData\MRV1
if not exist "%MRV1_ROOT%\bin\Monitor_Red_Console.ps1" (
    echo No se encontro el Monitor de Red instalado en %MRV1_ROOT%.
    echo Ejecute primero Instalar_Monitor.bat.
    pause
    exit /b 1
)
if /i "%~1"=="texto" goto :Texto
if not exist "%MRV1_ROOT%\bin\Servidor_Consola.ps1" goto :Texto
if not exist "%MRV1_ROOT%\bin\Consola_Web.html" goto :Texto
:: El servidor corre oculto, solo en esta PC (localhost); si ya hay uno en marcha solo abre el navegador.
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%MRV1_ROOT%\bin\Servidor_Consola.ps1" -Root "%MRV1_ROOT%"
exit /b 0

:Texto
start "Monitor de Red - Consola" powershell -NoProfile -ExecutionPolicy Bypass -File "%MRV1_ROOT%\bin\Monitor_Red_Console.ps1" -Root "%MRV1_ROOT%"
