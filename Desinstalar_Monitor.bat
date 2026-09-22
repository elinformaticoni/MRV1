@echo off
setlocal
:: Desinstala el Monitor: quita la tarea programada, bin\Monitor_Red.ps1 y bin\Monitor_Red_Console.ps1
:: y config\monitor.json. NO borra logs\ ni logs\cargados\.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
set MRV1_ROOT=C:\ProgramData\MRV1
echo Deteniendo y eliminando la tarea programada MRV1 Monitor (si existe)...
powershell -NoProfile -Command "$t = Get-ScheduledTask -TaskName 'MRV1 Monitor' -ErrorAction SilentlyContinue; if ($t) { Stop-ScheduledTask -TaskName 'MRV1 Monitor' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName 'MRV1 Monitor' -Confirm:$false } else { Write-Host 'La tarea no existia.' }"
if exist "%MRV1_ROOT%\bin\Monitor_Red.ps1" del /f /q "%MRV1_ROOT%\bin\Monitor_Red.ps1"
if exist "%MRV1_ROOT%\bin\Monitor_Red_Console.ps1" del /f /q "%MRV1_ROOT%\bin\Monitor_Red_Console.ps1"
if exist "%MRV1_ROOT%\config\monitor.json" del /f /q "%MRV1_ROOT%\config\monitor.json"
if exist "%MRV1_ROOT%\status.json" del /f /q "%MRV1_ROOT%\status.json"

echo Quitando el acceso directo del escritorio y las copias auxiliares...
if exist "%PUBLIC%\Desktop\Monitor de Red - Consola.lnk" del /f /q "%PUBLIC%\Desktop\Monitor de Red - Consola.lnk"
if exist "%MRV1_ROOT%\Abrir_Consola.bat" del /f /q "%MRV1_ROOT%\Abrir_Consola.bat"
if exist "%MRV1_ROOT%\Desinstalar_FTP.bat" del /f /q "%MRV1_ROOT%\Desinstalar_FTP.bat"
if exist "%MRV1_ROOT%\Instalar_Monitor.bat" del /f /q "%MRV1_ROOT%\Instalar_Monitor.bat"
if exist "%MRV1_ROOT%\Instalar_Monitor.ps1" del /f /q "%MRV1_ROOT%\Instalar_Monitor.ps1"
if exist "%MRV1_ROOT%\Instalar_FTP.bat" del /f /q "%MRV1_ROOT%\Instalar_FTP.bat"
if exist "%MRV1_ROOT%\Instalar_FTP.ps1" del /f /q "%MRV1_ROOT%\Instalar_FTP.ps1"

echo.
echo Monitor desinstalado. Los registros historicos en logs\ y logs\cargados\ se conservaron.
pause
if exist "%MRV1_ROOT%\Desinstalar_Monitor.bat" del /f /q "%MRV1_ROOT%\Desinstalar_Monitor.bat" >nul 2>&1
