@echo off
setlocal
:: Desinstala el Cargador FTP: quita la tarea programada, bin\Cargador_FTP.ps1 y config\ftp.json
:: (incluye las credenciales). NO borra logs\ ni logs\cargados\.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
set MRV1_ROOT=C:\ProgramData\MRV1
echo Deteniendo y eliminando la tarea programada MRV1 FTP (si existe)...
powershell -NoProfile -Command "$t = Get-ScheduledTask -TaskName 'MRV1 FTP' -ErrorAction SilentlyContinue; if ($t) { Stop-ScheduledTask -TaskName 'MRV1 FTP' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName 'MRV1 FTP' -Confirm:$false } else { Write-Host 'La tarea no existia.' }"
if exist "%MRV1_ROOT%\bin\Cargador_FTP.ps1" del /f /q "%MRV1_ROOT%\bin\Cargador_FTP.ps1"
if exist "%MRV1_ROOT%\config\ftp.json" del /f /q "%MRV1_ROOT%\config\ftp.json"
echo.
echo Cargador FTP desinstalado (credenciales incluidas). Los registros en logs\ y logs\cargados\ se conservaron.
pause
