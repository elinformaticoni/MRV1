@echo off
setlocal
:: Publica una nueva version para la actualizacion automatica (ver Publicar_Actualizacion.ps1).
:: Solicita elevacion de administrador automaticamente. Ejecutelo con doble clic.
::   Publicar_Actualizacion.bat               -> publica la version indicada en sistema\Instalar_Monitor.ps1
::   Publicar_Actualizacion.bat -NuevaClave   -> (solo la primera vez) crea el par de claves de firma
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)
set "MRV1_PS1=%~dp0Publicar_Actualizacion.ps1"
if not exist "%MRV1_PS1%" (
    echo No se encontro Publicar_Actualizacion.ps1 junto a este BAT.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%MRV1_PS1%" %*
if %errorlevel% neq 0 (
    echo.
    echo La publicacion no se completo. Revise los mensajes anteriores.
    pause
    exit /b 1
)
echo.
pause
exit /b 0
