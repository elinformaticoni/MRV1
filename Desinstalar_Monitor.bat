@echo off
setlocal
:: Desinstala el Monitor: quita la tarea programada, bin\Monitor_Red.ps1 y bin\Monitor_Red_Console.ps1
:: y config\monitor.json. NO borra logs\ ni logs\cargados\.
:: [v1.9] Si el Cargador FTP o la carga a la API (DB) siguen instalados, pregunta si se desinstalan
:: tambien; si se responde N, se conservan sus tareas y las copias de sus instaladores/desinstaladores
:: en C:\ProgramData\MRV1 (antes se borraban esas copias y la tarea MRV1 FTP / MRV1 DB quedaba huerfana).
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
set MRV1_ROOT=C:\ProgramData\MRV1
echo Deteniendo y eliminando la tarea programada MRV1 Monitor...
call :QuitarTarea "MRV1 Monitor" "Monitor_Red.ps1"
if exist "%MRV1_ROOT%\bin\Monitor_Red.ps1" del /f /q "%MRV1_ROOT%\bin\Monitor_Red.ps1"
if exist "%MRV1_ROOT%\bin\Monitor_Red_Console.ps1" del /f /q "%MRV1_ROOT%\bin\Monitor_Red_Console.ps1"
if exist "%MRV1_ROOT%\config\monitor.json" del /f /q "%MRV1_ROOT%\config\monitor.json"
if exist "%MRV1_ROOT%\status.json" del /f /q "%MRV1_ROOT%\status.json"

:: ---- Cargadores FTP / DB que sigan instalados
set HAY_EXTRAS=
schtasks.exe /Query /TN "MRV1 FTP" >nul 2>&1 && set HAY_EXTRAS=1
schtasks.exe /Query /TN "MRV1 DB" >nul 2>&1 && set HAY_EXTRAS=1
if exist "%MRV1_ROOT%\config\ftp.json" set HAY_EXTRAS=1
if exist "%MRV1_ROOT%\config\db_api.json" set HAY_EXTRAS=1
set QUITAR_EXTRAS=S
if not defined HAY_EXTRAS goto :Copias
echo.
echo Tambien estan instalados el Cargador FTP y/o la carga a la API de analisis DB.
set RESP=
set /p RESP=Desea desinstalarlos tambien? [S/N] (Enter = S): 
if /i "%RESP%"=="N" set QUITAR_EXTRAS=N
if /i "%QUITAR_EXTRAS%"=="N" goto :Copias
echo Deteniendo y eliminando la tarea programada MRV1 FTP...
call :QuitarTarea "MRV1 FTP" "Cargador_FTP.ps1"
if exist "%MRV1_ROOT%\bin\Cargador_FTP.ps1" del /f /q "%MRV1_ROOT%\bin\Cargador_FTP.ps1"
if exist "%MRV1_ROOT%\config\ftp.json" del /f /q "%MRV1_ROOT%\config\ftp.json"
if exist "%MRV1_ROOT%\ftp_status.json" del /f /q "%MRV1_ROOT%\ftp_status.json"
echo Deteniendo y eliminando la tarea programada MRV1 DB...
call :QuitarTarea "MRV1 DB" "Cargador_DB.ps1"
if exist "%MRV1_ROOT%\bin\Cargador_DB.ps1" del /f /q "%MRV1_ROOT%\bin\Cargador_DB.ps1"
if exist "%MRV1_ROOT%\config\db_api.json" del /f /q "%MRV1_ROOT%\config\db_api.json"
if exist "%MRV1_ROOT%\db_status.json" del /f /q "%MRV1_ROOT%\db_status.json"

:Copias
echo.
echo Quitando el acceso directo del escritorio y las copias auxiliares...
if exist "%PUBLIC%\Desktop\Monitor de Red - Consola.lnk" del /f /q "%PUBLIC%\Desktop\Monitor de Red - Consola.lnk"
if exist "%MRV1_ROOT%\Abrir_Consola.bat" del /f /q "%MRV1_ROOT%\Abrir_Consola.bat"
if exist "%MRV1_ROOT%\Instalar_Monitor.bat" del /f /q "%MRV1_ROOT%\Instalar_Monitor.bat"
if exist "%MRV1_ROOT%\Instalar_Monitor.ps1" del /f /q "%MRV1_ROOT%\Instalar_Monitor.ps1"
if /i "%QUITAR_EXTRAS%"=="N" goto :Fin
if exist "%MRV1_ROOT%\Desinstalar_FTP.bat" del /f /q "%MRV1_ROOT%\Desinstalar_FTP.bat"
if exist "%MRV1_ROOT%\Desinstalar_DB.bat" del /f /q "%MRV1_ROOT%\Desinstalar_DB.bat"
if exist "%MRV1_ROOT%\Instalar_FTP.bat" del /f /q "%MRV1_ROOT%\Instalar_FTP.bat"
if exist "%MRV1_ROOT%\Instalar_FTP.ps1" del /f /q "%MRV1_ROOT%\Instalar_FTP.ps1"
if exist "%MRV1_ROOT%\Instalar_DB.bat" del /f /q "%MRV1_ROOT%\Instalar_DB.bat"
if exist "%MRV1_ROOT%\Instalar_DB.ps1" del /f /q "%MRV1_ROOT%\Instalar_DB.ps1"

:Fin
echo.
echo Monitor desinstalado. Los registros historicos en logs\ y logs\cargados\ se conservaron.
if /i "%QUITAR_EXTRAS%"=="N" echo El Cargador FTP / DB se conservaron; para quitarlos use Desinstalar_FTP.bat / Desinstalar_DB.bat en %MRV1_ROOT%.
echo Si el Programador de tareas ya estaba abierto, presione F5 para actualizar la lista.
pause
if exist "%MRV1_ROOT%\Desinstalar_Monitor.bat" del /f /q "%MRV1_ROOT%\Desinstalar_Monitor.bat" >nul 2>&1 & exit /b 0

:: ---------------------------------------------------------------------------------------------
:: QuitarTarea "Nombre": detiene y elimina la tarea programada, con respaldo por schtasks.exe, y
:: VERIFICA que ya no exista (antes solo se intentaba y no se comprobaba el resultado). [v1.9]
:: ---------------------------------------------------------------------------------------------
:QuitarTarea
powershell -NoProfile -ExecutionPolicy Bypass -Command "$n = '%~1'; $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue; if (-not $t) { Write-Host ('La tarea ' + $n + ' no existia.'); exit 0 }; Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" -ErrorAction SilentlyContinue | Where-Object { ($_.ProcessId -ne $PID) -and $_.CommandLine -and ($_.CommandLine -like ('*' + '%~2' + '*')) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; try { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop } catch { Write-Host ('Unregister-ScheduledTask fallo: ' + $_.Exception.Message) }; if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { schtasks.exe /Delete /TN $n /F 2>&1 | Out-Null }; if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { Write-Host ('*** NO SE PUDO ELIMINAR LA TAREA ' + $n + ' *** Eliminela a mano en el Programador de tareas.') -ForegroundColor Red; exit 1 } else { Write-Host ('Tarea ' + $n + ' eliminada.') -ForegroundColor Green }"
exit /b %errorlevel%
