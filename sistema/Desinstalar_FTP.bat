@echo off
setlocal
:: Desinstala el Cargador FTP: quita la tarea programada, bin\Cargador_FTP.ps1, config\ftp.json
:: (incluye las credenciales) y ftp_status.json. NO borra logs\ ni logs\cargados\.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
set MRV1_ROOT=C:\ProgramData\MRV1
echo Deteniendo y eliminando la tarea programada MRV1 FTP...
call :QuitarTarea "MRV1 FTP" "Cargador_FTP.ps1"
set TAREA_ERR=%errorlevel%
if exist "%MRV1_ROOT%\bin\Cargador_FTP.ps1" del /f /q "%MRV1_ROOT%\bin\Cargador_FTP.ps1"
if exist "%MRV1_ROOT%\config\ftp.json" del /f /q "%MRV1_ROOT%\config\ftp.json"
if exist "%MRV1_ROOT%\ftp_status.json" del /f /q "%MRV1_ROOT%\ftp_status.json"
echo.
if not "%TAREA_ERR%"=="0" echo ATENCION: la tarea MRV1 FTP no se pudo eliminar. Revise el mensaje de arriba.
echo Cargador FTP desinstalado (credenciales incluidas). Los registros en logs\ y logs\cargados\ se conservaron.
echo Si el Programador de tareas ya estaba abierto, presione F5 para actualizar la lista.
pause
exit /b 0

:: ---------------------------------------------------------------------------------------------
:: QuitarTarea "Nombre": detiene y elimina la tarea programada, con respaldo por schtasks.exe, y
:: VERIFICA que ya no exista (antes solo se intentaba y no se comprobaba el resultado). [v1.9]
:: ---------------------------------------------------------------------------------------------
:QuitarTarea
powershell -NoProfile -ExecutionPolicy Bypass -Command "$n = '%~1'; $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue; if (-not $t) { Write-Host ('La tarea ' + $n + ' no existia.'); exit 0 }; Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" -ErrorAction SilentlyContinue | Where-Object { ($_.ProcessId -ne $PID) -and $_.CommandLine -and ($_.CommandLine -like ('*' + '%~2' + '*')) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; try { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop } catch { Write-Host ('Unregister-ScheduledTask fallo: ' + $_.Exception.Message) }; if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { schtasks.exe /Delete /TN $n /F 2>&1 | Out-Null }; if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { Write-Host ('*** NO SE PUDO ELIMINAR LA TAREA ' + $n + ' *** Eliminela a mano en el Programador de tareas.') -ForegroundColor Red; exit 1 } else { Write-Host ('Tarea ' + $n + ' eliminada.') -ForegroundColor Green }"
exit /b %errorlevel%
