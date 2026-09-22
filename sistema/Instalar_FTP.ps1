<#
.SYNOPSIS
    Asistente de instalacion/configuracion del Cargador FTP del Monitor de Red (MR).
.DESCRIPTION
    Reutilizable: si ya existe config\ftp.json, lo muestra como valores por defecto.
    Crea/actualiza config\ftp.json (separado de los scripts) y la tarea programada
    "MRV1 FTP" (inicio de Windows + cada N minutos).
#>
param([string]$Root = 'C:\ProgramData\MRV1')

$ErrorActionPreference = 'Stop'
Write-Host ''
Write-Host '=== Instalador del Cargador FTP (Monitor de Red) ===' -ForegroundColor Cyan
Write-Host ''

$cfgDir = Join-Path $Root 'config'
$binDir = Join-Path $Root 'bin'
foreach ($d in @($Root, $cfgDir, $binDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$ftpCfgPath = Join-Path $cfgDir 'ftp.json'
$existing = $null
if (Test-Path -LiteralPath $ftpCfgPath) {
    try { $existing = Get-Content -LiteralPath $ftpCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}

function Read-Default([string]$prompt, [string]$default) {
    $r = Read-Host ('{0} (Enter = {1})' -f $prompt, $default)
    if ([string]::IsNullOrWhiteSpace($r)) { return $default }
    return $r.Trim()
}
function Read-IntDefault([string]$prompt, [int]$default, [int]$min, [int]$max) {
    while ($true) {
        $r = Read-Host ('{0} (Enter = {1})' -f $prompt, $default)
        if ([string]::IsNullOrWhiteSpace($r)) { return $default }
        $v = 0
        if ([int]::TryParse($r.Trim(), [ref]$v) -and ($v -ge $min) -and ($v -le $max)) { return $v }
        Write-Host ('  Valor invalido. Debe ser un entero entre {0} y {1}.' -f $min, $max) -ForegroundColor Yellow
    }
}

$defHost = 'solucionesnicaragua.com'
$defPort = 21
$defUser = 'registros@solucionesnicaragua.com'
$defPass = 'yxFM5awxECy8qaftpnMy'
# La carpeta remota predeterminada es siempre el nombre de esta PC, para separar los registros
# de cada equipo en el servidor sin que el usuario tenga que escribirlo. Si ya existe una
# configuracion previa con una carpeta distinta (el usuario la cambio a proposito), se respeta.
$defDir = '/' + $env:COMPUTERNAME + '/'
$defMin = 120; $defRetry = 3
if ($existing) {
    if ($existing.host)        { $defHost = [string]$existing.host }
    if ($existing.port)        { $defPort = [int]$existing.port }
    if ($existing.user)        { $defUser = [string]$existing.user }
    if ($existing.password)    { $defPass = [string]$existing.password }
    # Una carpeta remota guardada como '/' (raiz) no se respeta como valor definitivo: es lo que
    # quedaba grabado en instalaciones anteriores a la 1.3 (antes de existir la carpeta por PC) y,
    # si se sigue arrastrando, los registros de todas las PC terminan mezclados en la raiz del FTP.
    if ($existing.remoteDir -and ($existing.remoteDir.Trim() -ne '/')) { $defDir = [string]$existing.remoteDir }
    if ($existing.runEveryMin) { $defMin  = [int]$existing.runEveryMin }
    if ($existing.retries)     { $defRetry = [int]$existing.retries }
}

$host_ = Read-Default 'Servidor FTP (dominio o IP)' $defHost
$port  = Read-IntDefault 'Puerto' $defPort 1 65535
$user  = Read-Default 'Usuario' $defUser
$passPrompt = '  Contrasena'
if ($defPass -ne '') { $passPrompt += ' (Enter = mantener la actual)' }
$passIn = Read-Host $passPrompt
$pass = $defPass
if (-not [string]::IsNullOrWhiteSpace($passIn)) { $pass = $passIn }
Write-Host '  Se recomienda una carpeta por PC, para no mezclar los registros de varias computadoras en el servidor.' -ForegroundColor Gray
$remoteDir = Read-Default '  Carpeta remota' $defDir
if (-not $remoteDir.EndsWith('/')) { $remoteDir += '/' }
$runEveryMin = Read-IntDefault 'Frecuencia de ejecucion en minutos' $defMin 5 1440
$retries = Read-IntDefault 'Reintentos ante fallo' $defRetry 1 10

$cfgObj = [ordered]@{
    schemaVersion    = 1
    protocol         = 'ftp'
    host             = $host_
    port             = $port
    remoteDir        = $remoteDir
    user             = $user
    password         = $pass
    runEveryMin      = $runEveryMin
    retries          = $retries
    uploadCurrentDay = $true
}
($cfgObj | ConvertTo-Json -Depth 5) | Out-File -LiteralPath $ftpCfgPath -Encoding utf8 -Force

$src = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- Busqueda de archivos del paquete [v1.9]. El paquete ahora tiene en la raiz solo los BAT
# principales (Instalar_Monitor.bat, Desinstalar_Monitor.bat, Abrir_Consola.bat) y el resto en
# la subcarpeta sistema\. Este asistente puede ejecutarse desde:
#   - <paquete>\sistema\          (los BAT principales estan en la carpeta de arriba)
#   - un paquete antiguo plano      (todo junto)
#   - C:\ProgramData\MRV1\         (reinstalacion desde la copia; los scripts estan en bin\)
# por eso cada archivo se busca en esas ubicaciones, y nunca se copia un archivo sobre si mismo.
function Find-SourceFile([string]$name) {
    $dirs = @($src, (Split-Path -Parent $src), (Join-Path $src 'sistema'), (Join-Path $src 'bin'))
    foreach ($d in $dirs) {
        if ([string]::IsNullOrEmpty($d)) { continue }
        $p = Join-Path $d $name
        if (Test-Path -LiteralPath $p -PathType Leaf) { return [System.IO.Path]::GetFullPath($p) }
    }
    return $null
}
function Copy-FromSource([string]$name, [string]$dest, [switch]$Required) {
    $p = Find-SourceFile $name
    if (-not $p) {
        if ($Required) { throw ('No se encontro {0} en el paquete (se busco en {1}, su carpeta superior y sistema\).' -f $name, $src) }
        return
    }
    if ([string]::Equals($p, [System.IO.Path]::GetFullPath($dest), [System.StringComparison]::OrdinalIgnoreCase)) { return }
    Copy-Item -LiteralPath $p -Destination $dest -Force
}
Copy-FromSource 'Cargador_FTP.ps1' (Join-Path $binDir 'Cargador_FTP.ps1') -Required

# ---- Copiar tambien los BAT de desinstalacion y el lanzador de la consola a la raiz de $Root
# (por si el FTP se instala/reinstala por separado sin pasar de nuevo por Instalar_Monitor.ps1),
# para que quede todo lo necesario dentro de C:\ProgramData\MRV1 aunque se borre el paquete
# de descarga original.
foreach ($f in @('Desinstalar_Monitor.bat', 'Desinstalar_FTP.bat', 'Abrir_Consola.bat', 'Instalar_Monitor.bat', 'Instalar_Monitor.ps1', 'Instalar_FTP.bat', 'Instalar_FTP.ps1')) {
    Copy-FromSource $f (Join-Path $Root $f)
}

$exe = (Get-Command powershell.exe).Source
$scriptPath = Join-Path $binDir 'Cargador_FTP.ps1'
$action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Root "{1}"' -f $scriptPath, $Root)
$trigStart = New-ScheduledTaskTrigger -AtStartup
$trigRep   = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $runEveryMin) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'MRV1 FTP' -Action $action -Trigger @($trigStart, $trigRep) -Principal $principal -Settings $settings -Force | Out-Null

Write-Host ''
Write-Host 'Configuracion FTP guardada en config\ftp.json (separado de los scripts).' -ForegroundColor Gray
Write-Host 'Probando la conexión ahora mismo (primera carga de prueba)...' -ForegroundColor Cyan

# Se ejecuta ya mismo, en primer plano (no como tarea programada en segundo plano), para poder
# esperar el resultado real y mostrarlo de inmediato: asi se sabe si el host/usuario/contrasena/
# puerto quedaron bien, sin tener que ir a revisar el log a mano.
$statusFile = Join-Path $Root 'ftp_status.json'
$before = $null
if (Test-Path -LiteralPath $statusFile) { try { $before = (Get-Item -LiteralPath $statusFile).LastWriteTimeUtc } catch { } }

& $exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Root $Root

$result = $null
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $statusFile) {
        $cur = (Get-Item -LiteralPath $statusFile).LastWriteTimeUtc
        if (-not $before -or ($cur -gt $before)) {
            try { $result = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
            if ($result) { break }
        }
    }
    Start-Sleep -Milliseconds 500
}

Write-Host ''
if ($null -eq $result) {
    Write-Host 'No se obtuvo resultado de la prueba en el tiempo esperado.' -ForegroundColor Yellow
    Write-Host 'Revise diag\ftp_worker.log para el detalle y vuelva a intentarlo si es necesario.' -ForegroundColor Yellow
} elseif ($result.ok) {
    Write-Host ('CONEXIÓN FTP CORRECTA. Carpeta remota: {0}' -f $remoteDir) -ForegroundColor Green
    Write-Host ('  Archivos de días anteriores subidos: {0}   Copia del día en curso: {1}' -f $result.uploadedOld, $result.uploadedToday) -ForegroundColor Green
} else {
    Write-Host 'LA PRUEBA DE CONEXIÓN FALLÓ:' -ForegroundColor Red
    Write-Host ('  ' + $result.lastError) -ForegroundColor Red
    Write-Host ''
    Write-Host 'Revise host, usuario, contraseña, puerto y carpeta remota, y vuelva a ejecutar' -ForegroundColor Yellow
    Write-Host 'Instalar_FTP.bat para corregir la configuración y probar de nuevo.' -ForegroundColor Yellow
    Write-Host 'La tarea programada "MRV1 FTP" queda instalada e igual lo reintentará solo cada' -ForegroundColor Gray
    Write-Host ('{0} minutos, por si el problema era temporal (servidor apagado, red caída, etc.).' -f $runEveryMin) -ForegroundColor Gray
}
Write-Host ''
Write-Host 'La consola de monitoreo (Abrir_Consola.bat) muestra el estado de esta subida y de las próximas.' -ForegroundColor Gray
Write-Host ''
Write-Host 'Instalación del cargador FTP completada.' -ForegroundColor Green
Write-Host ''
