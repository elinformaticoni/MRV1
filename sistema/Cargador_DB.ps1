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
    - Archivo del dia en curso: la primera corrida del dia lo envia completo; las siguientes solo
      reenvian desde poco antes de su ultima fila de estado (la unica que puede seguir cambiando;
      [v1.13.8]). No se duplica nada en el servidor: la API hace UPSERT por la clave
      (pc, destino, fecha, hora, tipo, mensaje) - ver backend/IA.md decision D5.
    - [v1.13.8] Cuidado con las protecciones del servidor (Cloudflare, firewall del hosting):
      User-Agent propio ("MRV1-Cargador/x.y.z"); si el servidor rechaza el envio (401/403/429 o una
      respuesta que no es de la API) se corta la corrida en el primer intento, sin reintentos ni
      mas archivos, y no se vuelve a intentar hasta pasado un plazo creciente (diag\db_backoff.json,
      30 min, 1 h, 2 h... hasta la frecuencia normal; respeta Retry-After). Tras encender el equipo se
      espera un tiempo al azar para que un laboratorio entero no llegue a la vez. En el log queda el
      codigo HTTP, el servidor (Cloudflare o no) y el inicio de la respuesta.
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
$script:BloqueadoHasta = $null   # [v1.13.8] 'yyyy-MM-ddTHH:mm:ss' si el servidor rechazo el envio y se espera antes de reintentar
$script:Corte = $false           # la corrida se detiene (servidor rechaza o no responde)
$script:CorteBackoff = $false    # ademas del corte, hay que esperar un plazo (rechazo del servidor)
$script:RetryAfterSec = 0
$backoffFile   = Join-Path $diagDir 'db_backoff.json'

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
        if ($script:BloqueadoHasta) {
            $obj.bloqueadoHasta = $script:BloqueadoHasta
            if ([datetime]$script:BloqueadoHasta -gt $now.AddMinutes($runEveryMin)) { $obj.nextRun = $script:BloqueadoHasta }
        }
        $json = $obj | ConvertTo-Json -Depth 4
        $tmp = $statusFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        if (Test-Path -LiteralPath $statusFile) { [System.IO.File]::Replace($tmp, $statusFile, [NullString]::Value) }
        else { [System.IO.File]::Move($tmp, $statusFile) }
    } catch { Write-Log ('No se pudo escribir db_status.json: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------------------------
# [v1.13.8] Espera ante rechazos del servidor. diag\db_backoff.json = { hasta, intentos, motivo };
# lo leen tambien Sincronizar_Config.ps1 y Actualizar_Script.ps1 para no seguir llamando al
# mismo servidor mientras dura. Se borra al primer envio correcto (o al pedir «Enviar datos ahora»).
# ---------------------------------------------------------------------------------------------
function Get-Backoff {
    try {
        if (-not (Test-Path -LiteralPath $backoffFile)) { return $null }
        $b = [System.IO.File]::ReadAllText($backoffFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($b -and $b.hasta) { return $b }
    } catch { }
    return $null
}
function Set-Backoff([string]$motivo, [int]$retryAfterSec, [int]$runEveryMin) {
    try {
        $n = 1; $prev = Get-Backoff
        if ($prev -and $prev.intentos) { $n = [int]$prev.intentos + 1 }
        $min = [Math]::Min(30 * [Math]::Pow(2, [Math]::Min($n - 1, 10)), [Math]::Max($runEveryMin, 30))
        if ($retryAfterSec -gt 0) { $min = [Math]::Max($min, [Math]::Ceiling($retryAfterSec / 60.0)) }
        $min = [Math]::Min($min, 1440)
        $hasta = (Get-Date).AddMinutes($min).ToString('s')
        $obj = [ordered]@{ schemaVersion = 1; hasta = $hasta; intentos = $n; motivo = $motivo; desde = (Get-Date).ToString('s') }
        if (-not (Test-Path -LiteralPath $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
        [System.IO.File]::WriteAllText($backoffFile, ($obj | ConvertTo-Json), $utf8)
        $script:BloqueadoHasta = $hasta
        Write-Log ('Servidor rechazo el envio (intento {0} seguido): no se reintenta hasta {1} ({2} min).' -f $n, $hasta, [int]$min)
    } catch { Write-Log ('No se pudo guardar db_backoff.json: ' + $_.Exception.Message) }
}
function Clear-Backoff { try { if (Test-Path -LiteralPath $backoffFile) { Remove-Item -LiteralPath $backoffFile -Force -ErrorAction SilentlyContinue } } catch { } }

# Minutos desde el arranque de Windows (9999 si no se puede saber).
function Get-UptimeMin {
    try { return ((Get-Date) - (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime).TotalMinutes } catch { return 9999 }
}

# Resume una excepcion de Invoke-WebRequest: codigo HTTP, servidor, rayo de Cloudflare, Retry-After y el
# inicio de la respuesta. EsApi = la respuesta es JSON de nuestra API (lo demas viene de una capa
# intermedia: Cloudflare, firewall del hosting, pagina del hosting...).
function Get-HttpInfo($ex, $detalleError = $null) {
    $i = [ordered]@{ Status = 0; Server = ''; Ray = ''; RetryAfter = 0; Cuerpo = ''; EsApi = $false; ErrorApi = $null; Msg = [string]$ex.Message }
    $r = $ex.Response
    if ($r) {
        try { $i.Status = [int]$r.StatusCode } catch { }
        try { $i.Server = [string]$r.Headers['Server'] } catch { }
        try { $i.Ray = [string]$r.Headers['CF-RAY'] } catch { }
        try { $n = 0; if ([int]::TryParse([string]$r.Headers['Retry-After'], [ref]$n)) { $i.RetryAfter = $n } } catch { }
        try {
            # En Windows PowerShell 5.1 el cuerpo del error suele venir ya leido en ErrorDetails.Message; si no, de la corriente.
            $b = ''
            if ($detalleError -and $detalleError.Message) { $b = [string]$detalleError.Message }
            if (-not $b) { $sr = New-Object System.IO.StreamReader($r.GetResponseStream()); $b = $sr.ReadToEnd(); $sr.Dispose() }
            $i.Cuerpo = ($b -replace '\s+', ' ').Trim()
            if ($i.Cuerpo.Length -gt 200) { $i.Cuerpo = $i.Cuerpo.Substring(0, 200) }
            $j = $b | ConvertFrom-Json
            if ($j -and $null -ne $j.PSObject.Properties['ok']) { $i.EsApi = $true; if ($j.error) { $i.ErrorApi = [string]$j.error } }
        } catch { }
    }
    return $i
}
function Get-OrigenRechazo($i) {
    if ($i.Ray -or $i.Server -match 'cloudflare') { return 'Cloudflare' + $(if ($i.Ray) { ', ray ' + $i.Ray } else { '' }) }
    if ($i.Server) { return 'servidor ' + $i.Server }
    return 'capa de proteccion del servidor'
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
    # [v1.12] Actualizacion automatica de los scripts (Actualizar_Script.ps1): mismo disparo, mismo principio de mejor esfuerzo.
    try {
        $upd = Join-Path $Root 'bin\Actualizar_Script.ps1'
        if (Test-Path -LiteralPath $upd) {
            $exe2 = (Get-Command powershell.exe).Source
            Start-Process -FilePath $exe2 -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $upd), '-Root', ('"{0}"' -f $Root)) -WindowStyle Hidden | Out-Null
        }
    } catch { Write-Log ('No se pudo lanzar Actualizar_Script.ps1: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------------------------
# Estado de sincronizacion: que archivos CERRADOS ya se confirmaron subidos a la API, para no
# volver a leerlos ni reenviarlos en cada corrida. Del archivo del dia en curso se guarda solo
# desde que fila reenviar en la proxima corrida (diaEnCurso, [v1.13.8]); el UPSERT del servidor
# evita duplicados al solaparse (D5 de IA.md).
# ---------------------------------------------------------------------------------------------
function Get-SyncState {
    if (-not (Test-Path -LiteralPath $syncStateFile)) { return @{ archivosSincronizados = @{}; diaEnCurso = @{} } }
    try {
        $raw = [System.IO.File]::ReadAllText($syncStateFile, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
        $map = @{}
        if ($obj.archivosSincronizados) {
            foreach ($p in $obj.archivosSincronizados.PSObject.Properties) { $map[$p.Name] = $true }
        }
        $dia = @{}
        if ($obj.diaEnCurso) {
            foreach ($p in $obj.diaEnCurso.PSObject.Properties) { $n = 0; if ([int]::TryParse([string]$p.Value, [ref]$n) -and $n -ge 0) { $dia[$p.Name] = $n } }
        }
        return @{ archivosSincronizados = $map; diaEnCurso = $dia }
    } catch {
        Write-Log ('No se pudo leer db_sync_state.json, se reconstruye desde cero: ' + $_.Exception.Message)
        return @{ archivosSincronizados = @{}; diaEnCurso = @{} }
    }
}

function Save-SyncState([hashtable]$state) {
    try {
        if (-not (Test-Path -LiteralPath $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
        $ordered = [ordered]@{}
        foreach ($k in ($state.archivosSincronizados.Keys | Sort-Object)) { $ordered[$k] = $true }
        $hoyTxt = (Get-Date).ToString('yyyy-MM-dd')
        $dia = [ordered]@{}
        foreach ($k in ($state.diaEnCurso.Keys | Sort-Object)) { if ($k.EndsWith(' ' + $hoyTxt + '.csv')) { $dia[$k] = [int]$state.diaEnCurso[$k] } }
        $obj = [ordered]@{ schemaVersion = 2; actualizado = (Get-Date).ToString('s'); archivosSincronizados = $ordered; diaEnCurso = $dia }
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

    # [v1.13.8] User-Agent propio (el de PowerShell por defecto suele ser marcado por las protecciones anti-bot).
    $verTxt = '0'
    try {
        $verPath = Join-Path $cfgDir 'version.json'
        if (Test-Path -LiteralPath $verPath) { $vj = [System.IO.File]::ReadAllText($verPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json; if ($vj.version) { $verTxt = [string]$vj.version } }
    } catch { }
    $userAgent = 'MRV1-Cargador/' + $verTxt

    # [v1.13.8] Si el servidor rechazo el envio hace poco, no insistir hasta que pase el plazo.
    $bk = Get-Backoff
    if ($bk -and ([datetime]$bk.hasta) -gt (Get-Date)) {
        Write-Log ('Envio en espera por rechazo previo del servidor ({0}); proximo intento a partir de {1}.' -f $bk.motivo, $bk.hasta)
        exit 0
    }
    # [v1.13.8] Recien encendido el equipo: esperar un tiempo al azar para que un laboratorio entero no llegue a la vez.
    if ((Get-UptimeMin) -lt 15) {
        $espera = Get-Random -Minimum 0 -Maximum 121
        Write-Log ('Equipo recien encendido: se espera {0} s antes de enviar (evita llegar todos a la vez).' -f $espera)
        Start-Sleep -Seconds $espera
    }

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
        # [v1.13.8] La coma es imprescindible: sin ella, con un solo lote (<= maxFilas filas, lo normal) PowerShell
        # desenvolvia el resultado y el foreach recibia cada FILA como si fuera un lote: una peticion por fila.
        return ,$lotes
    }

    # Envia un lote de filas de un mismo destino. Reintenta $retries veces ante fallo de red.
    function Send-Batch([string]$destino, [array]$filasLote) {
        $bodyObj = [ordered]@{
            pc      = $pc
            alias   = $alias
            destino = $destino
            filas   = @($filasLote)
            # [v1.13.12] Hora LOCAL de esta PC al enviar (la misma base de tiempo que las filas de los CSV) y la frecuencia
            # configurada: el analisis solo da por vivo el estado "en curso" hasta el ultimo envio + esta espera.
            enviado        = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
            frecuencia_min = $runEveryMin
        }
        $body = $bodyObj | ConvertTo-Json -Depth 6 -Compress

        $lastErr = $null
        for ($i = 1; $i -le $retries; $i++) {
            try {
                $resp = Invoke-WebRequest -Uri $apiUrl -Method Post `
                    -Headers @{ 'X-MR-Token' = $token; 'Accept' = 'application/json' } -UserAgent $userAgent `
                    -ContentType 'application/json; charset=utf-8' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                    -TimeoutSec 30 -UseBasicParsing
                $json = $null
                try { $json = $resp.Content | ConvertFrom-Json } catch { }
                if (-not $json -or $null -eq $json.PSObject.Properties['ok']) {
                    # 200 pero no es la API (pagina de desafio, portal cautivo, etc.)
                    $lastErr = 'respuesta que no es de la API (pagina intermedia del servidor o de la red)'
                    $script:Corte = $true; $script:CorteBackoff = $true
                    $ini = (([string]$resp.Content) -replace '\s+', ' ').Trim(); if ($ini.Length -gt 200) { $ini = $ini.Substring(0, 200) }
                    Write-Log ('Respuesta HTTP 200 que no es JSON de la API para {0}. Inicio de la respuesta: {1}' -f $destino, $ini)
                    return @{ Ok = $false; Insertadas = 0; Actualizadas = 0; Error = $lastErr }
                }
                return @{ Ok = $true; Insertadas = [int]$json.insertadas; Actualizadas = [int]$json.actualizadas; Error = $null }
            } catch {
                $h = Get-HttpInfo $_.Exception $_.ErrorDetails
                $lastErr = if ($h.ErrorApi) { $h.ErrorApi } else { $h.Msg }
                Write-Log ('Intento {0}/{1} fallido para {2} ({3} filas): HTTP {4} | servidor="{5}" ray="{6}" | {7} | inicio de la respuesta: {8}' -f $i, $retries, $destino, $filasLote.Count, $h.Status, $h.Server, $h.Ray, $lastErr, $h.Cuerpo)
                if ($h.Status -gt 0) { $script:RetryAfterSec = [Math]::Max($script:RetryAfterSec, $h.RetryAfter) }
                # Rechazo del servidor (401/403/429 o algo que no es nuestra API): insistir solo empeora el bloqueo.
                if (($h.Status -in @(401, 403, 429)) -or ($h.Status -gt 0 -and -not $h.EsApi)) {
                    $lastErr = ('HTTP {0}: {1}' -f $h.Status, $(if ($h.EsApi) { $lastErr } else { 'rechazado por ' + (Get-OrigenRechazo $h) }))
                    $script:Corte = $true; $script:CorteBackoff = $true
                    return @{ Ok = $false; Insertadas = 0; Actualizadas = 0; Error = $lastErr }
                }
                # Error de validacion de la API (4xx): reintentar no lo arregla; se sigue con los demas archivos.
                if ($h.Status -ge 400 -and $h.Status -lt 500) { return @{ Ok = $false; Insertadas = 0; Actualizadas = 0; Error = ('HTTP {0}: {1}' -f $h.Status, $lastErr) } }
                # Sin respuesta (red, DNS, tiempo agotado) o 5xx de la API: espera creciente con azar.
                if ($i -lt $retries) { Start-Sleep -Milliseconds ([int]((Get-Random -Minimum 1500 -Maximum 3500) * [Math]::Pow(2, $i - 1))) }
            }
        }
        # Agotados los reintentos sin respuesta util: no tiene sentido probar con el resto de archivos.
        $script:Corte = $true
        return @{ Ok = $false; Insertadas = 0; Actualizadas = 0; Error = $lastErr }
    }

    # Envia todas las filas de un archivo (en lotes de $maxFilas). Devuelve $true solo si TODOS
    # los lotes se enviaron correctamente.
    function Send-Archivo([string]$destino, [System.Collections.ArrayList]$filas) {
        if ($filas.Count -eq 0) { return $true }  # nada que enviar (archivo solo con encabezado)
        $todoOk = $true
        foreach ($lote in (Get-Batches $filas $maxFilas)) {
            if ($script:Corte) { return $false }
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
        if ($script:Corte) { break }   # el servidor rechazo o no responde: no seguir con mas archivos
        if ($f.Name -notmatch $patron) { continue }
        $destino = $Matches[1]
        $fecha   = $Matches[2]

        if ($fecha -lt $today) {
            # Archivo cerrado: se envia una sola vez.
            if ($state.archivosSincronizados.ContainsKey($f.Name)) { continue }
            $filas = @(Read-CsvRows $f.FullName)
            if (Send-Archivo $destino $filas) {
                $state.archivosSincronizados[$f.Name] = $true
                $syncedOld++
            } else {
                $failedOld++
            }
        } elseif ($fecha -eq $today) {
            # Archivo del dia en curso. Primera corrida del dia: completo. Despues: desde poco antes de la
            # ultima fila OK/ERROR (la unica que el monitor puede seguir modificando). El UPSERT evita duplicados.
            # Copia de lectura compartida para no interferir con el monitor mientras escribe.
            $tmp = $null
            try {
                $tmp = Join-Path $env:TEMP ('mrv1db_' + [Guid]::NewGuid().ToString('N') + '.csv')
                $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $out = [System.IO.File]::Create($tmp)
                try { $fs.CopyTo($out) } finally { $out.Dispose(); $fs.Dispose() }
                $filas = @(Read-CsvRows $tmp)
                $inicio = 0
                if ($state.diaEnCurso.ContainsKey($f.Name)) {
                    $prevIdx = [int]$state.diaEnCurso[$f.Name]
                    if ($prevIdx -gt 0 -and $prevIdx -lt $filas.Count) { $inicio = $prevIdx }   # archivo mas corto que antes = se reenvia completo
                }
                $aEnviar = if ($inicio -gt 0) { @($filas[$inicio..($filas.Count - 1)]) } else { $filas }
                if (Send-Archivo $destino $aEnviar) {
                    $syncedToday++
                    $ult = -1
                    for ($k = 0; $k -lt $filas.Count; $k++) { if ($filas[$k].tipo -eq 'OK' -or $filas[$k].tipo -eq 'ERROR') { $ult = $k } }
                    $state.diaEnCurso[$f.Name] = [Math]::Max(0, $ult - 2)
                } else { $failedToday++ }
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

    $okOverall = (($failedOld + $failedToday) -eq 0) -and (-not $script:Corte)
    if ($script:Corte -and $script:CorteBackoff) { Set-Backoff $script:LastDbError $script:RetryAfterSec $runEveryMin }
    elseif ($okOverall) { Clear-Backoff }
    Write-DbStatus $okOverall $syncedOld $failedOld $syncedToday $failedToday $script:TotalInsertadas $script:TotalActualizadas $runEveryMin $script:LastDbError
    Write-Log ('Ciclo terminado. Archivos cerrados sincronizados: {0} (fallidos: {1}). Dia en curso enviado: {2} (fallidos: {3}). Filas insertadas: {4}, actualizadas: {5}.' -f $syncedOld, $failedOld, $syncedToday, $failedToday, $script:TotalInsertadas, $script:TotalActualizadas)
    # Si el servidor rechazo el envio, no lanzar las otras consultas (configuracion remota, actualizaciones): irian al mismo servidor.
    if (-not ($script:Corte -and $script:CorteBackoff)) { Start-ZombieSync }
}
catch {
    Write-Log ('Error general del cargador DB: ' + $_.Exception.Message)
    try { Write-DbStatus $false 0 0 0 0 0 0 180 $_.Exception.Message } catch { }
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
}
exit 0
