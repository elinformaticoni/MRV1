<#
.SYNOPSIS
    Asistente de instalacion/configuracion de la carga a la API de analisis (Cargador_DB.ps1)
    del Monitor de Red (MR).
.DESCRIPTION
    Reutilizable: si ya existe config\db_api.json, lo muestra como valores por defecto.
    Crea/actualiza config\db_api.json (separado de los scripts) y la tarea programada
    "MRV1 DB" (inicio de Windows + cada N minutos), igual que Instalar_FTP.ps1 con el FTP.
    Se invoca desde Instalar_Monitor.ps1 (pregunta "¿Desea habilitar el envio a la API de
    analisis?"), o de forma independiente si ya esta copiado en C:\ProgramData\MRV1.
#>
param([string]$Root = 'C:\ProgramData\MRV1')

$ErrorActionPreference = 'Stop'
Write-Host ''
Write-Host '=== Configuracion de la carga a la API de analisis (Monitor de Red) ===' -ForegroundColor Cyan
Write-Host ''

$cfgDir = Join-Path $Root 'config'
$binDir = Join-Path $Root 'bin'
foreach ($d in @($Root, $cfgDir, $binDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$dbCfgPath = Join-Path $cfgDir 'db_api.json'
$existing = $null
if (Test-Path -LiteralPath $dbCfgPath) {
    try { $existing = Get-Content -LiteralPath $dbCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
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

# Valores de fabrica: API oficial de Monitor de Red y el token vigente al momento de este
# paquete. IMPORTANTE: antes de distribuir el instalador a otras PC, actualizar $defToken
# con el token real vigente en el servidor (config.php del backend) - ver backend/IA.md
# seccion 8 ("regenerar el token una vez terminadas las pruebas").
$defApiUrl = 'https://mrv1.solucionesnicaragua.com/registros.php'
$defToken  = '9dcfe2fde8aae601bb83467c145492d1b1ccc0beb1c2ff8ecd25930a604b747d'
$defAlias  = $env:COMPUTERNAME
$defMin    = 180   # D10 de backend/IA.md: cada 3 horas por defecto
$defRetry  = 3
if ($existing) {
    if ($existing.apiUrl)      { $defApiUrl = [string]$existing.apiUrl }
    if ($existing.token)       { $defToken  = [string]$existing.token }
    if ($existing.alias)       { $defAlias  = [string]$existing.alias }
    if ($existing.runEveryMin) { $defMin    = [int]$existing.runEveryMin }
    if ($existing.retries)     { $defRetry  = [int]$existing.retries }
}

$apiUrl = Read-Default 'URL de la API de analisis' $defApiUrl
$tokenPrompt = '  Token de la API'
$tokenIn = Read-Host ('{0} (Enter = mantener el actual)' -f $tokenPrompt)
$token = $defToken
if (-not [string]::IsNullOrWhiteSpace($tokenIn)) { $token = $tokenIn.Trim() }
Write-Host '  El alias identifica el punto observado (ej. "Laboratorio 2 - Edificio A"); el nombre de la PC no siempre es descriptivo.' -ForegroundColor Gray
$alias = Read-Default '  Alias de esta PC' $defAlias
$runEveryMin = Read-IntDefault 'Frecuencia de envio en minutos' $defMin 5 1440
$retries = Read-IntDefault 'Reintentos ante fallo' $defRetry 1 10

$cfgObj = [ordered]@{
    schemaVersion    = 1
    apiUrl           = $apiUrl
    token            = $token
    alias            = $alias
    runEveryMin      = $runEveryMin
    retries          = $retries
    maxFilasPorEnvio = 300
}
($cfgObj | ConvertTo-Json -Depth 5) | Out-File -LiteralPath $dbCfgPath -Encoding utf8 -Force

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
Copy-FromSource 'Cargador_DB.ps1' (Join-Path $binDir 'Cargador_DB.ps1') -Required

# ---- Copiar tambien los BAT de desinstalacion y el lanzador de la consola a la raiz de $Root
# (por si la API se instala/reinstala por separado sin pasar de nuevo por Instalar_Monitor.ps1),
# para que quede todo lo necesario dentro de C:\ProgramData\MRV1 aunque se borre el paquete
# de descarga original.
foreach ($f in @('Desinstalar_Monitor.bat', 'Desinstalar_DB.bat', 'Abrir_Consola.bat', 'Instalar_Monitor.bat', 'Instalar_Monitor.ps1', 'Instalar_DB.bat', 'Instalar_DB.ps1')) {
    Copy-FromSource $f (Join-Path $Root $f)
}

$exe = (Get-Command powershell.exe).Source
$scriptPath = Join-Path $binDir 'Cargador_DB.ps1'
$action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Root "{1}"' -f $scriptPath, $Root)
$trigStart = New-ScheduledTaskTrigger -AtStartup
$trigRep   = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $runEveryMin) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'MRV1 DB' -Action $action -Trigger @($trigStart, $trigRep) -Principal $principal -Settings $settings -Force | Out-Null

Write-Host ''
Write-Host 'Configuracion guardada en config\db_api.json (separado de los scripts).' -ForegroundColor Gray
Write-Host 'Probando el envio ahora mismo (primera carga de prueba)...' -ForegroundColor Cyan

# Se ejecuta ya mismo, en primer plano (no como tarea programada en segundo plano), para poder
# esperar el resultado real y mostrarlo de inmediato: asi se sabe si la URL/token quedaron bien,
# sin tener que ir a revisar el log a mano. Igual que hace Instalar_FTP.ps1 con la prueba de FTP.
$statusFile = Join-Path $Root 'db_status.json'
$before = $null
if (Test-Path -LiteralPath $statusFile) { try { $before = (Get-Item -LiteralPath $statusFile).LastWriteTimeUtc } catch { } }

& $exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Root $Root

$result = $null
$deadline = (Get-Date).AddSeconds(30)
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
    Write-Host 'Revise diag\db_worker.log para el detalle y vuelva a intentarlo si es necesario.' -ForegroundColor Yellow
} elseif ($result.ok) {
    Write-Host 'ENVIO A LA API CORRECTO.' -ForegroundColor Green
    Write-Host ('  Archivos cerrados sincronizados: {0}   Dia en curso enviado: {1}   Filas insertadas: {2}   Actualizadas: {3}' -f $result.syncedOld, $result.syncedToday, $result.insertadas, $result.actualizadas) -ForegroundColor Green
} else {
    Write-Host 'LA PRUEBA DE ENVIO FALLO:' -ForegroundColor Red
    Write-Host ('  ' + $result.lastError) -ForegroundColor Red
    Write-Host ''
    Write-Host 'Revise la URL y el token, y vuelva a ejecutar Instalar_DB.bat para corregir la' -ForegroundColor Yellow
    Write-Host 'configuracion y probar de nuevo.' -ForegroundColor Yellow
    Write-Host 'La tarea programada "MRV1 DB" queda instalada e igual lo reintentara sola cada' -ForegroundColor Gray
    Write-Host ('{0} minutos, por si el problema era temporal (servidor apagado, red caida, etc.).' -f $runEveryMin) -ForegroundColor Gray
}
Write-Host ''
Write-Host 'Configuracion de la carga a la API de analisis completada.' -ForegroundColor Green
Write-Host ''
