<#
.SYNOPSIS
    Monitor de Red (MR) - Cargador_DB.ps1
.DESCRIPTION
    Componente independiente y opcional (mismo principio P3 que Cargador_FTP.ps1): un fallo
    aqui no afecta al monitor ni al Cargador FTP. Envia los registros de los CSV locales a la
    API de analisis (backend/api/registros.php, ver backend/IA.md) para poder generar reportes
    con rango de fechas dinamico y de varias PC/ubicaciones.
    - Archivos de dias anteriores (cerrados) en logs\ y logs\cargados\: se envian una sola vez;
      una vez confirmados por la API se marcan como sincronizados en diag\db_sync_state.json
      para no volver a leerlos ni reenviarlos en cada corrida.
    - Archivo del dia en curso: se reenvia completo en cada corrida (su ultima fila puede seguir
      cambiando). No se duplica nada en el servidor: la API hace UPSERT por la clave
      (pc, destino, fecha, hora, tipo, mensaje) - ver backend/IA.md decision D5.
    - El alias del PC (config\db_api.json) se manda en todos los envios, no solo cuando cambia
      (decision D9 de backend/IA.md): es un dato liviano y asi la API mantiene "computadoras"
      al dia sola, sin pasos manuales, incluso si un envio anterior fallo.
    - Se ejecuta al iniciar Windows, de inmediato al instalar/habilitar y cada runEveryMin
      minutos (tarea programada "MRV1 DB"), igual que el Cargador FTP.
    - Al terminar, escribe Root\db_status.json (ultimo envio, archivos sincronizados, filas
      insertadas/actualizadas, proxima hora estimada y error si lo hubo) para que
      Monitor_Red_Console.ps1 lo pueda mostrar, igual que ya hace con ftp_status.json.
    - [v1.11] Al terminar cada corrida, lanza Sincronizar_Config.ps1 (configuracion remota,
      ver MRV1.10.md 10.6) en un proceso aparte, sin esperarlo: un fallo o una demora ahi
      nunca debe retrasar ni afectar la propia carga a la API (P3).
#>
param([string]$Root)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }

if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$cfgDir        = Join-Path $Root 'config'
$logDir        = Join-Path $Root 'logs'
$upDir         = Join-Path $logDir 'cargados'
$diagDir       = Join-Path $Root 'diag'
$statusFile    = Join-Path $Root 'db_status.json'
$syncStateFile = Join-Path $diagDir 'db_sync_state.json'
$pc            = $env:COMPUTERNAME
$utf8          = New-Object System.Text.UTF8Encoding($false)
$script:LastDbError = $null

function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path -LiteralPath $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
        $f = Join-Path $diagDir 'db_worker.log'
        if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).Length -gt 1MB)) {
            Move-Item -LiteralPath $f -Destination ($f + '.1') -Force
        }
        [System.IO.File]::AppendAllText($f, ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) + "`r`n", $utf8)
    } catch { }
}

# Escritura atomica de db_status.json, para que la consola nunca lea un archivo a medias.
function Write-DbStatus([bool]$ok, [int]$syncedOld, [int]$failedOld, [int]$syncedToday, [int]$failedToday, [int]$insertadas, [int]$actualizadas, [int]$runEveryMin, [string]$errorMsg) {
    try {
        $now = Get-Date
        $obj = [ordered]@{
            schemaVersion = 1
            timestamp     = $now.ToString('s')
            ok            = $ok
            syncedOld     = $syncedOld
            failedOld     = $failedOld
            syncedToday   = $syncedToday
            failedToday   = $failedToday
            insertadas    = $insertadas
            actualizadas  = $actualizadas
            runEveryMin   = $runEveryMin
            nextRun       = $now.AddMinutes($runEveryMin).ToString('s')
            lastError     = $errorMsg
        }
        $json = $obj | ConvertTo-Json -Depth 4
        $tmp = $statusFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        if (Test-Path -LiteralPath $statusFile) { [System.IO.File]::Replace($tmp, $statusFile, [NullString]::Value) }
        else { [System.IO.File]::Move($tmp, $statusFile) }
    } catch { Write-Log ('No se pudo escribir db_status.json: ' + $_.Exception.Message) }
}

# [v1.11] Lanza Sincronizar_Config.ps1 en un proceso aparte (oculto, sin esperar el resultado).
# Mejor esfuerzo: si el script no esta presente (paquete anterior a 1.11) o falla al lanzarse,
# se registra en el log y la carga a la API sigue como si esta funcion no existiera (P3).
function Start-ZombieSync {
    try {
        $script = Join-Path $Root 'bin\Sincronizar_Config.ps1'
        if (-not (Test-Path -LiteralPath $script)) { return }
        $exe = (Get-Command powershell.exe).Source
        Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $script), '-Root', ('"{0}"' -f $Root)) -WindowStyle Hidden | Out-Null
    } catch { Write-Log ('No se pudo lanzar Sincronizar_Config.ps1: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------------------------
# Estado de sincronizacion: que archivos CERRADOS ya se confirmaron subidos a la API, para no
# volver a leerlos ni reenviarlos en cada corrida (el archivo del dia en curso nunca se guarda
# aqui: siempre se reenvia completo, el UPSERT del servidor evita duplicados - D5 de IA.md).
# ---------------------------------------------------------------------------------------------
function Get-SyncState {
    if (-not (Test-Path -LiteralPath $syncStateFile)) { return @{ archivosSincronizados = @{} } }
    try {
        $raw = [System.IO.File]::ReadAllText($syncStateFile, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
        $map = @{}
        if ($obj.archivosSincronizados) {
            foreach ($p in $obj.archivosSincronizados.PSObject.Properties) { $map[$p.Name] = $true }
        }
        return @{ archivosSincronizados = $map }
    } catch {
        Write-Log ('No se pudo leer db_sync_state.json, se reconstruye desde cero: ' + $_.Exception.Message)
        return @{ archivosSincronizados = @{} }
    }
}

function Save-SyncState([hashtable]$state) {
    try {
        if (-not (Test-Path -LiteralPath $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
        $ordered = [ordered]@{}
        foreach ($k in ($state.archivosSincronizados.Keys | Sort-Object)) { $ordered[$k] = $true }
        $obj = [ordered]@{ schemaVersion = 1; actualizado = (Get-Date).ToString('s'); archivosSincronizados = $ordered }
        $json = $obj | ConvertTo-Json -Depth 4
        $tmp = $syncStateFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        if (Test-Path -LiteralPath $syncStateFile) { [System.IO.File]::Replace($tmp, $syncStateFile, [NullString]::Value) }
        else { [System.IO.File]::Move($tmp, $syncStateFile) }
    } catch { Write-Log ('No se pudo guardar db_sync_state.json: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------------------------
# Instancia unica (evita solaparse con la ejecucion anterior si la API esta lenta)
# ---------------------------------------------------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\MRV1_DB', [ref]$createdNew)
if (-not $createdNew) { Write-Log 'Ya hay otra ejecucion del cargador DB en curso; se omite esta.'; exit 0 }

try {
    foreach ($d in @($logDir, $upDir, $diagDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    $cfgPath = Join-Path $cfgDir 'db_api.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { Write-Log 'No existe config\db_api.json; la carga a la API de analisis no esta habilitada.'; exit 0 }
    $cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$cfg.apiUrl)) { Write-Log 'db_api.json no tiene "apiUrl" configurado; no se puede enviar nada.'; exit 0 }
    if ([string]::IsNullOrWhiteSpace([string]$cfg.token))  { Write-Log 'db_api.json no tiene "token" configurado; no se puede enviar nada.'; exit 0 }

    $apiUrl      = [string]$cfg.apiUrl
    $token       = [string]$cfg.token
    $alias       = ''; if ($cfg.alias) { $alias = [string]$cfg.alias }
    # [v1.9] El alias oficial vive en config\monitor.json (lo pide Instalar_Monitor.bat); tiene
    # prioridad sobre el de db_api.json, que queda solo como respaldo de instalaciones anteriores.
    try {
        $monCfgPath = Join-Path $cfgDir 'monitor.json'
        if (Test-Path -LiteralPath $monCfgPath) {
            $mc = [System.IO.File]::ReadAllText($monCfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$mc.alias)) { $alias = [string]$mc.alias }
        }
    } catch { }
    $runEveryMin = 180; if ($cfg.runEveryMin) { $runEveryMin = [int]$cfg.runEveryMin }   # D10: predeterminado 3 horas
    $retries     = 3;   if ($cfg.retries)     { $retries     = [int]$cfg.retries }
    $maxFilas    = 300; if ($cfg.maxFilasPorEnvio) { $maxFilas = [int]$cfg.maxFilasPorEnvio }  # margen bajo el limite del servidor (500, ver IA.md sec. 5)

    # ---------------------------------------------------------------------------------------
    # Lectura de CSV: mismo formato que escribe Monitor_Red.ps1 (UTF-8 con BOM, separador ';',
    # header 'FECHA;HORA;TIPO;TIEMPO (s);LATENCIA (ms);MENSAJE'). No se modifica ni se relee
    # nada de Monitor_Red.ps1: este cargador solo interpreta el CSV ya escrito.
    # ---------------------------------------------------------------------------------------
    function Read-CsvRows([string]$path) {
        $filas = New-Object System.Collections.ArrayList
        try {
            $texto = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        } catch {
            Write-Log ('No se pudo leer ' + $path + ': ' + $_.Exception.Message)
            return $filas
        }
        $lineas = $texto -split "`r`n|`n"
        for ($i = 0; $i -lt $lineas.Count; $i++) {
            $l = $lineas[$i]
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            if ($l.StartsWith('FECHA;')) { continue }  # encabezado
            $p = $l.Split(';', 6)
            if ($p.Count -lt 3) { continue }
            $fecha = $p[0]; $hora = $p[1]; $tipo = $p[2]
            if ($fecha -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
            if ($hora  -notmatch '^\d{2}:\d{2}:\d{2}$')  { continue }

            $tiempo = $null
            if ($p.Count -gt 3 -and -not [string]::IsNullOrWhiteSpace($p[3])) {
                $v = 0; if ([int]::TryParse($p[3].Trim(), [ref]$v)) { $tiempo = $v }
            }
            $latencia = $null
            if ($p.Count -gt 4 -and -not [string]::IsNullOrWhiteSpace($p[4])) {
                $v = 0; if ([int]::TryParse($p[4].Trim(), [ref]$v)) { $latencia = $v }
            }
            $mensaje = ''
            if ($p.Count -gt 5) { $mensaje = $p[5] }

            [void]$filas.Add([ordered]@{
                fecha       = $fecha
                hora        = $hora
                tipo        = $tipo.ToUpperInvariant()
                tiempo_s    = $tiempo
                latencia_ms = $latencia
                mensaje     = $mensaje
            })
        }
        return $filas
    }

    function Get-Batches($items, [int]$size) {
        $lotes = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $items.Count; $i += $size) {
            $fin = [Math]::Min($i + $size, $items.Count) - 1
            [void]$lotes.Add(@($items[$i..$fin]))
        }
        return $lotes
    }

    # Envia un lote de filas de un mismo destino. Reintenta $retries veces ante fallo de red.
    function Send-Batch([string]$destino, [array]$filasLote) {
        $bodyObj = [ordered]@{
            pc      = $pc
            alias   = $alias
            destino = $destino
            filas   = @($filasLote)
        }
        $body = $bodyObj | ConvertTo-Json -Depth 6 -Compress

        $lastErr = $null
        for ($i = 1; $i -le $retries; $i++) {
            try {
                $resp = Invoke-WebRequest -Uri $apiUrl -Method Post `
                    -Headers @{ 'X-MR-Token' = $token } `
                    -ContentType 'application/json; charset=utf-8' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                    -TimeoutSec 30 -UseBasicParsing
                $json = $resp.Content | ConvertFrom-Json
                return @{ Ok = $true; Insertadas = [int]$json.insertadas; Actualizadas = [int]$json.actualizadas; Error = $null }
            } catch {
                $detail = $_.Exception.Message
                if ($_.Exception.Response) {
                    try {
                        $stream = $_.Exception.Response.GetResponseStream()
                        $reader = New-Object System.IO.StreamReader($stream)
                        $errBody = $reader.ReadToEnd()
                        $errJson = $errBody | ConvertFrom-Json
                        if ($errJson.error) { $detail = [string]$errJson.error }
                    } catch { }
                }
                $lastErr = $detail
                Write-Log ('Intento {0}/{1} fallido para {2} ({3} filas): {4}' -f $i, $retries, $destino, $filasLote.Count, $lastErr)
                if ($i -lt $retries) { Start-Sleep -Seconds 2 }
            }
        }
        return @{ Ok = $false; Insertadas = 0; Actualizadas = 0; Error = $lastErr }
    }

    # Envia todas las filas de un archivo (en lotes de $maxFilas). Devuelve $true solo si TODOS
    # los lotes se enviaron correctamente.
    function Send-Archivo([string]$destino, [System.Collections.ArrayList]$filas) {
        if ($filas.Count -eq 0) { return $true }  # nada que enviar (archivo solo con encabezado)
        $todoOk = $true
        foreach ($lote in (Get-Batches $filas $maxFilas)) {
            $r = Send-Batch $destino $lote
            if ($r.Ok) {
                $script:TotalInsertadas += $r.Insertadas
                $script:TotalActualizadas += $r.Actualizadas
            } else {
                $todoOk = $false
                $script:LastDbError = ('{0}: {1}' -f $destino, $r.Error)
            }
        }
        return $todoOk
    }

    # ---------------------------------------------------------------------------------------
    # Ejecucion
    # ---------------------------------------------------------------------------------------
    $script:TotalInsertadas = 0
    $script:TotalActualizadas = 0

    $state = Get-SyncState
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $patron = '^' + [regex]::Escape($pc) + ' (.+) (\d{4}-\d{2}-\d{2})\.csv$'

    # Los CSV cerrados pueden estar en logs\ (aun no los movio el FTP, o el FTP esta deshabilitado)
    # o ya en logs\cargados\ (el FTP los movio) - se revisan ambas carpetas por separado del FTP,
    # sin tocar ni mover nada de lo que administra Cargador_FTP.ps1.
    $todosCsv = @()
    $todosCsv += Get-ChildItem -LiteralPath $logDir -Filter '*.csv' -File -ErrorAction SilentlyContinue
    $todosCsv += Get-ChildItem -LiteralPath $upDir  -Filter '*.csv' -File -ErrorAction SilentlyContinue

    $syncedOld = 0; $failedOld = 0
    $syncedToday = 0; $failedToday = 0

    foreach ($f in $todosCsv) {
        if ($f.Name -notmatch $patron) { continue }
        $destino = $Matches[1]
        $fecha   = $Matches[2]

        if ($fecha -lt $today) {
            # Archivo cerrado: se envia una sola vez.
            if ($state.archivosSincronizados.ContainsKey($f.Name)) { continue }
            $filas = Read-CsvRows $f.FullName
            if (Send-Archivo $destino $filas) {
                $state.archivosSincronizados[$f.Name] = $true
                $syncedOld++
            } else {
                $failedOld++
            }
        } elseif ($fecha -eq $today) {
            # Archivo del dia en curso: se reenvia completo en cada corrida (UPSERT evita duplicados).
            # Copia de lectura compartida para no interferir con el monitor mientras escribe.
            $tmp = $null
            try {
                $tmp = Join-Path $env:TEMP ('mrv1db_' + [Guid]::NewGuid().ToString('N') + '.csv')
                $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $out = [System.IO.File]::Create($tmp)
                try { $fs.CopyTo($out) } finally { $out.Dispose(); $fs.Dispose() }
                $filas = Read-CsvRows $tmp
                if (Send-Archivo $destino $filas) { $syncedToday++ } else { $failedToday++ }
            } catch {
                $failedToday++
                $script:LastDbError = ('{0}: {1}' -f $f.Name, $_.Exception.Message)
                Write-Log ('No se pudo preparar la copia del dia en curso ({0}): {1}' -f $f.Name, $_.Exception.Message)
            } finally {
                if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
        # Fechas futuras (reloj adelantado, etc.) se ignoran; se procesaran cuando "today" las alcance.
    }

    Save-SyncState $state

    $okOverall = (($failedOld + $failedToday) -eq 0)
    Write-DbStatus $okOverall $syncedOld $failedOld $syncedToday $failedToday $script:TotalInsertadas $script:TotalActualizadas $runEveryMin $script:LastDbError
    Write-Log ('Ciclo terminado. Archivos cerrados sincronizados: {0} (fallidos: {1}). Dia en curso enviado: {2} (fallidos: {3}). Filas insertadas: {4}, actualizadas: {5}.' -f $syncedOld, $failedOld, $syncedToday, $failedToday, $script:TotalInsertadas, $script:TotalActualizadas)
    Start-ZombieSync
}
catch {
    Write-Log ('Error general del cargador DB: ' + $_.Exception.Message)
    try { Write-DbStatus $false 0 0 0 0 0 0 180 $_.Exception.Message } catch { }
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
}
exit 0
