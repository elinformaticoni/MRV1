<#
.SYNOPSIS
    Monitor de Red (MR) - Sincronizar_Config.ps1  [v1.11]
.DESCRIPTION
    Cliente de la configuracion remota ("zombie", ver MRV1.10.md seccion 10.6 y backend/IA.md
    seccion 5.1). Componente independiente y de mejor esfuerzo (mismo principio P3 que
    Cargador_FTP.ps1 / Cargador_DB.ps1): un fallo aqui nunca debe afectar al monitor, al FTP
    ni a la carga a la API.

    El servidor manda y la PC obedece: no hay modo "zombie si/no" ni configuracion local
    paralela. Este script:
      1. Si hay una revision aplicada pero aun no confirmada de una corrida anterior (por
         ejemplo, la confirmacion fallo por red), reintenta confirmarla primero.
      2. Descarga la instruccion de esta PC (GET zombie.php?accion=config&pc=NOMBRE). Sin
         instruccion (404), sin red, servidor caido, JSON invalido o revision no mayor a la
         ya aplicada: no hace nada.
      3. Valida los valores recibidos (mismos rangos que los instaladores / MR_Z_LIM del
         servidor). Si algo no es valido, no aplica nada y lo registra en el log.
      4. Sobrescribe SOLO las secciones que vinieron en la instruccion, en monitor.json,
         ftp.json y db_api.json. Nunca toca credenciales FTP, token ni URL. El alias solo
         cambia si la instruccion trae "alias" (lo manda el panel de analisis, "Editar
         nombre"); en ese caso se pide ademas un envio de datos (paso 8), sin reiniciar el monitor.
      5. Si cambiaron destinos o "detection", escribe un EVENTO "Configuracion remota
         aplicada (rev. N)" en el CSV de cada destino anterior y reinicia el monitor con una
         parada ordenada (igual que Instalar_Monitor.ps1).
      6. Si cambio la frecuencia de la API o del FTP, ajusta el disparador de repeticion de
         la tarea programada correspondiente ("MRV1 DB" / "MRV1 FTP").
      7. Confirma la revision aplicada al servidor (POST zombie.php?accion=confirmar) y guarda
         el resultado en diag\zombie_state.json, que Monitor_Red.ps1 lee para publicar
         configRevision / configAppliedAt en status.json (y la consola, en el encabezado).

    Se invoca (siempre en un proceso aparte, sin bloquear al que lo lanza):
      - al terminar cada corrida de Cargador_DB.ps1 (inicio de Windows y cada runEveryMin);
      - cada vez que el monitor escribe una fila INICIO (arranque y cambio de dia).
    Una PC sin la API de analisis habilitada (sin config\db_api.json) no recibe instrucciones:
    el monitor sigue funcionando exactamente igual (P3).
#>
param([string]$Root)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }

if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$cfgDir       = Join-Path $Root 'config'
$logDir       = Join-Path $Root 'logs'
$diagDir      = Join-Path $Root 'diag'
$stateFile    = Join-Path $diagDir 'zombie_state.json'
$stopFlag     = Join-Path $Root 'stop.flag'
$pc           = $env:COMPUTERNAME
$utf8         = New-Object System.Text.UTF8Encoding($false)
$utf8Bom      = New-Object System.Text.UTF8Encoding($true)

# [v1.13.8] User-Agent propio (el de PowerShell por defecto suele ser marcado por las protecciones anti-bot).
$verTxt = '0'
try {
    $vp = Join-Path $cfgDir 'version.json'
    if (Test-Path -LiteralPath $vp) { $vj = [System.IO.File]::ReadAllText($vp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json; if ($vj.version) { $verTxt = [string]$vj.version } }
} catch { }
$userAgent = 'MRV1-Config/' + $verTxt

# Rangos validos (MR_Z_LIM del servidor - ver backend/IA.md seccion 5.1; los mismos que usan
# Instalar_Monitor.ps1 / Instalar_FTP.ps1 / Instalar_DB.ps1 para sus propias preguntas).
$LIM = @{
    IntervalSec     = @(1, 3600)
    ConfirmPings    = @(1, 10)
    TimeoutMs       = @(500, 10000)
    NetworkCheckSec = @(1, 300)
    DbRunEveryMin   = @(5, 720)
    FtpRunEveryMin  = @(5, 1440)
    Retries         = @(1, 10)
    MaxTargets      = 8
}

function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path -LiteralPath $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
        $f = Join-Path $diagDir 'zombie_worker.log'
        if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).Length -gt 1MB)) {
            Move-Item -LiteralPath $f -Destination ($f + '.1') -Force
        }
        [System.IO.File]::AppendAllText($f, ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) + "`r`n", $utf8)
    } catch { }
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { Write-Log ('No se pudo leer ' + $path + ': ' + $_.Exception.Message); return $null }
}

# Escritura atomica (igual patron que status.json / db_status.json en los demas componentes).
function Write-JsonFile([string]$path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 6
    $tmp = $path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, $utf8)
    if (Test-Path -LiteralPath $path) { [System.IO.File]::Replace($tmp, $path, [NullString]::Value) }
    else { [System.IO.File]::Move($tmp, $path) }
}

function Get-SafeName([string]$s) { return ($s -replace '[\\/:*?"<>|]', '_') }

function Get-State {
    $s = Read-JsonFile $stateFile
    if ($null -eq $s) { return [ordered]@{ schemaVersion = 1; revisionAplicada = 0; aplicadaEn = $null; confirmada = $true } }
    $rev = 0;   if ($s.revisionAplicada) { $rev = [long]$s.revisionAplicada }
    $conf = $true; if ($null -ne $s.confirmada) { $conf = [bool]$s.confirmada }
    return [ordered]@{ schemaVersion = 1; revisionAplicada = $rev; aplicadaEn = $s.aplicadaEn; confirmada = $conf }
}

function Save-State($state) {
    try {
        if (-not (Test-Path -LiteralPath $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
        Write-JsonFile $stateFile $state
    } catch { Write-Log ('No se pudo guardar zombie_state.json: ' + $_.Exception.Message) }
}

function In-Range([double]$v, [double[]]$rango) { return ($v -ge $rango[0] -and $v -le $rango[1]) }

# ---------------------------------------------------------------------------------------------
# Confirmacion al servidor de que una revision quedo aplicada localmente.
# ---------------------------------------------------------------------------------------------
function Confirm-Revision([string]$zombieUrl, [string]$token, [long]$revision) {
    try {
        $bodyObj = [ordered]@{ pc = $pc; revision = $revision }
        $body = $bodyObj | ConvertTo-Json -Compress
        $resp = Invoke-WebRequest -Uri ($zombieUrl + '?accion=confirmar') -Method Post `
            -Headers @{ 'X-MR-Token' = $token; 'Accept' = 'application/json' } -UserAgent $userAgent -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 -UseBasicParsing
        $json = $resp.Content | ConvertFrom-Json
        if ($json.ok) { return $true }
        Write-Log ('El servidor no confirmo la revision {0}: {1}' -f $revision, $resp.Content)
        return $false
    } catch {
        Write-Log ('No se pudo confirmar la revision {0} al servidor: {1}' -f $revision, $_.Exception.Message)
        return $false
    }
}

# ---------------------------------------------------------------------------------------------
# Reinicio del monitor con parada ordenada (mismo patron que Instalar_Monitor.ps1 seccion 4.6):
# senal de parada, esperar hasta 15s, forzar si no responde, y por ultimo matar el proceso
# huerfano si sigue vivo. Nunca deja de reiniciar la tarea, aunque la parada no fuera limpia.
# ---------------------------------------------------------------------------------------------
function Restart-Monitor {
    try {
        $binDir = Join-Path $Root 'bin'
        $task = Get-ScheduledTask -TaskName 'MRV1 Monitor' -ErrorAction SilentlyContinue
        if ($task -and ($task.State -eq 'Running')) {
            New-Item -ItemType File -Path $stopFlag -Force | Out-Null
            $waited = 0
            while ((($t2 = Get-ScheduledTask -TaskName 'MRV1 Monitor' -ErrorAction SilentlyContinue).State -eq 'Running') -and ($waited -lt 15)) {
                Start-Sleep -Seconds 1; $waited++
            }
            if ($t2 -and ($t2.State -eq 'Running')) {
                try { Stop-ScheduledTask -TaskName 'MRV1 Monitor' -ErrorAction SilentlyContinue } catch { }
                Start-Sleep -Seconds 1
                try {
                    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -and ($_.CommandLine -match [regex]::Escape((Join-Path $binDir 'Monitor_Red.ps1'))) } |
                        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
                } catch { }
            }
        }
        Remove-Item -LiteralPath $stopFlag -Force -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName 'MRV1 Monitor' -ErrorAction SilentlyContinue
        Write-Log 'Monitor reiniciado tras aplicar la configuracion remota.'
    } catch {
        Write-Log ('No se pudo reiniciar el monitor: ' + $_.Exception.Message)
    }
}

# Ajusta solo la repeticion (runEveryMin) de una tarea programada existente, sin tocar su
# disparador de inicio de Windows ni ninguna otra propiedad.
#
# [v1.11.1] IMPORTANTE: Set-ScheduledTask, cuando se le pasa solo -Trigger (sin -Principal ni
# -Settings), no tiene un comportamiento documentado de preservar el principal/contexto de
# seguridad de la tarea (ver "Set-ScheduledTask" en Microsoft Learn: la propia documentacion no
# garantiza que Principal/Settings queden intactos si se omiten). En la practica esto reinicio
# la tarea "MRV1 DB" tras aplicar una configuracion remota: quedo con un principal/contexto que
# ya no corria desatendida (sin usuario con sesion iniciada), y dejo de dispararse en su
# horario aunque el disparador en si quedara bien formado. Por eso aqui se reafirman
# EXPLICITAMENTE el mismo Principal y Settings que usan Instalar_DB.ps1 / Instalar_FTP.ps1 al
# registrar la tarea (SYSTEM, RunLevel maximo, "ejecutar el usuario haya iniciado sesion o no"),
# para que un cambio de frecuencia nunca pueda dejar la tarea sin poder correr desatendida.
function Update-TaskFrequency([string]$taskName, [int]$runEveryMin) {
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) { Write-Log ('No se encontro la tarea "{0}"; no se ajusta su frecuencia.' -f $taskName); return }
        $trigStart = New-ScheduledTaskTrigger -AtStartup
        $trigRep   = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $runEveryMin) -RepetitionDuration (New-TimeSpan -Days 3650)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
        Set-ScheduledTask -TaskName $taskName -Trigger @($trigStart, $trigRep) -Principal $principal -Settings $settings | Out-Null
        # Verificacion: si por lo que sea la tarea quedo sin poder correr desatendida, que quede
        # registrado (mejor esfuerzo; nunca detiene el resto del proceso).
        try {
            $t2 = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($t2 -and $t2.Principal -and ($t2.Principal.LogonType -ne 'ServiceAccount')) {
                Write-Log ('AVISO: la tarea "{0}" quedo con LogonType "{1}" (se esperaba ServiceAccount/SYSTEM); revisar en el Programador de tareas.' -f $taskName, $t2.Principal.LogonType)
            }
        } catch { }
        Write-Log ('Frecuencia de la tarea "{0}" ajustada a cada {1} min.' -f $taskName, $runEveryMin)
    } catch {
        Write-Log ('No se pudo ajustar la frecuencia de la tarea "{0}": {1}' -f $taskName, $_.Exception.Message)
    }
}

# Escribe la fila EVENTO "Configuracion remota aplicada (rev. N)" en el CSV de hoy de cada
# destino ANTERIOR (antes de sobrescribir monitor.json), para acotar el estudio al momento
# exacto del cambio. Mejor esfuerzo: si el archivo no existe o esta bloqueado, se omite sin
# detener el resto del proceso (el propio reinicio del monitor generara un nuevo INICIO).
function Write-RemoteConfigEvent([array]$targetsAnteriores, [long]$revision) {
    $hoy = (Get-Date).ToString('yyyy-MM-dd')
    $msg = ('Configuración remota aplicada (rev. {0})' -f $revision)
    $linea = '{0};{1};EVENTO;0;0;{2}' -f (Get-Date -Format 'yyyy-MM-dd'), (Get-Date -Format 'HH:mm:ss'), $msg
    foreach ($t in $targetsAnteriores) {
        try {
            $file = Join-Path $logDir ('{0} {1} {2}.csv' -f $pc, (Get-SafeName ([string]$t.address)), $hoy)
            if (-not (Test-Path -LiteralPath $file)) { continue }
            $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $bytes = $utf8.GetBytes($linea + "`r`n")
                $fs.Write($bytes, 0, $bytes.Length)
            } finally { $fs.Dispose() }
        } catch {
            Write-Log ('No se pudo escribir el EVENTO de configuracion remota en {0}: {1}' -f $t.address, $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Instancia unica: si Cargador_DB.ps1 y una fila INICIO disparan este script casi a la vez,
# la segunda corrida se omite (evita aplicar/reintentar dos veces en simultaneo).
# ---------------------------------------------------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\MRV1_Zombie', [ref]$createdNew)
if (-not $createdNew) { Write-Log 'Ya hay otra sincronizacion de configuracion remota en curso; se omite esta.'; exit 0 }

try {
    # [v1.13.8] Si Cargador_DB.ps1 anoto que el servidor rechazo el envio (diag\db_backoff.json), no llamar al mismo
    # servidor hasta que pase el plazo; y tras un arranque de Windows, esperar un tiempo al azar para no llegar todos a la vez.
    $bk = Read-JsonFile (Join-Path $diagDir 'db_backoff.json')
    if ($bk -and $bk.hasta -and ([datetime]$bk.hasta) -gt (Get-Date)) { Write-Log ('Servidor en espera por rechazo previo; no se consulta hasta {0}.' -f $bk.hasta); exit 0 }
    try {
        if (((Get-Date) - (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime).TotalMinutes -lt 15) { Start-Sleep -Seconds (Get-Random -Minimum 0 -Maximum 61) }
    } catch { }

    $cfgPath = Join-Path $cfgDir 'db_api.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { exit 0 }  # sin API de analisis habilitada: no hay a donde preguntar
    $dbCfg = Read-JsonFile $cfgPath
    if ($null -eq $dbCfg -or [string]::IsNullOrWhiteSpace([string]$dbCfg.apiUrl) -or [string]::IsNullOrWhiteSpace([string]$dbCfg.token)) {
        Write-Log 'db_api.json incompleto (falta apiUrl o token); no se puede consultar la configuracion remota.'
        exit 0
    }
    $token = [string]$dbCfg.token

    # zombie.php vive en la misma carpeta del servidor que registros.php (backend/IA.md sec. 5.1/7).
    $zombieUrl = $null
    try { $zombieUrl = [Uri]::new([Uri]$dbCfg.apiUrl, 'zombie.php').AbsoluteUri } catch { }
    if (-not $zombieUrl) { Write-Log ('No se pudo derivar la URL de zombie.php a partir de "{0}".' -f $dbCfg.apiUrl); exit 0 }

    $state = Get-State

    # Paso 1: si quedo una revision aplicada sin confirmar de una corrida anterior, reintentar.
    if (-not $state.confirmada -and $state.revisionAplicada -gt 0) {
        if (Confirm-Revision $zombieUrl $token $state.revisionAplicada) {
            $state.confirmada = $true
            Save-State $state
        }
    }

    # Paso 2: consultar si hay una instruccion nueva para esta PC.
    $resp = $null
    try {
        $resp = Invoke-WebRequest -Uri ('{0}?accion=config&pc={1}' -f $zombieUrl, [Uri]::EscapeDataString($pc)) `
            -Headers @{ 'X-MR-Token' = $token; 'Accept' = 'application/json' } -UserAgent $userAgent -Method Get -TimeoutSec 20 -UseBasicParsing
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 404) { Write-Log 'Sin instruccion de configuracion remota pendiente.'; exit 0 }
        Write-Log ('No se pudo consultar la configuracion remota (servidor inaccesible o error de red): ' + $_.Exception.Message)
        exit 0
    }

    $instr = $null
    try { $instr = $resp.Content | ConvertFrom-Json } catch {
        Write-Log 'La respuesta de zombie.php no es JSON valido; se ignora.'
        exit 0
    }
    if (-not $instr.revision) { Write-Log 'La instruccion no trae "revision"; se ignora.'; exit 0 }
    $revision = [long]$instr.revision
    if ($revision -le $state.revisionAplicada) {
        Write-Log ('Revision {0} ya aplicada (actual: {1}); nada que hacer.' -f $revision, $state.revisionAplicada)
        exit 0
    }

    # Paso 3: validar TODO antes de aplicar nada (una instruccion parcialmente invalida no se
    # aplica en absoluto; queda para que se corrija en el servidor).
    $errores = New-Object System.Collections.ArrayList
    $targetsNuevos = $null
    if ($instr.targets) {
        $targetsNuevos = @($instr.targets)
        if ($targetsNuevos.Count -eq 0 -or $targetsNuevos.Count -gt $LIM.MaxTargets) {
            [void]$errores.Add(('targets debe tener entre 1 y {0} elementos' -f $LIM.MaxTargets))
        }
        foreach ($t in $targetsNuevos) {
            if ([string]::IsNullOrWhiteSpace([string]$t.address)) { [void]$errores.Add('un destino no tiene direccion') }
            if ($t.intervalSec -and -not (In-Range ([double]$t.intervalSec) $LIM.IntervalSec)) { [void]$errores.Add(('intervalSec fuera de rango: {0}' -f $t.intervalSec)) }
            if ($t.confirmPings -and -not (In-Range ([double]$t.confirmPings) $LIM.ConfirmPings)) { [void]$errores.Add(('confirmPings fuera de rango: {0}' -f $t.confirmPings)) }
        }
    }
    if ($instr.detection) {
        if ($instr.detection.timeoutMs -and -not (In-Range ([double]$instr.detection.timeoutMs) $LIM.TimeoutMs)) { [void]$errores.Add(('detection.timeoutMs fuera de rango: {0}' -f $instr.detection.timeoutMs)) }
        if ($instr.detection.networkCheckSec -and -not (In-Range ([double]$instr.detection.networkCheckSec) $LIM.NetworkCheckSec)) { [void]$errores.Add(('detection.networkCheckSec fuera de rango: {0}' -f $instr.detection.networkCheckSec)) }
    }
    if ($instr.db) {
        if ($instr.db.runEveryMin -and -not (In-Range ([double]$instr.db.runEveryMin) $LIM.DbRunEveryMin)) { [void]$errores.Add(('db.runEveryMin fuera de rango: {0}' -f $instr.db.runEveryMin)) }
        if ($instr.db.retries -and -not (In-Range ([double]$instr.db.retries) $LIM.Retries)) { [void]$errores.Add(('db.retries fuera de rango: {0}' -f $instr.db.retries)) }
    }
    if ($instr.ftp) {
        if ($instr.ftp.runEveryMin -and -not (In-Range ([double]$instr.ftp.runEveryMin) $LIM.FtpRunEveryMin)) { [void]$errores.Add(('ftp.runEveryMin fuera de rango: {0}' -f $instr.ftp.runEveryMin)) }
        if ($instr.ftp.retries -and -not (In-Range ([double]$instr.ftp.retries) $LIM.Retries)) { [void]$errores.Add(('ftp.retries fuera de rango: {0}' -f $instr.ftp.retries)) }
    }
    # [v1.13.8] alias: nombre del equipo corregido desde el panel de analisis (index.php, "Editar nombre").
    $aliasNuevo = $null
    if ($null -ne $instr.alias) {
        $aliasNuevo = ([string]$instr.alias).Trim()
        if ($aliasNuevo.Length -lt 1 -or $aliasNuevo.Length -gt 150 -or $aliasNuevo -match '[\x00-\x1F\x7F]') {
            [void]$errores.Add('alias no valido (1 a 150 caracteres, sin caracteres de control)')
        }
    }
    if ($errores.Count -gt 0) {
        Write-Log ('Instruccion de configuracion remota (rev. {0}) invalida, no se aplica nada: {1}' -f $revision, ($errores -join ' | '))
        exit 0
    }

    # Paso 4: aplicar solo las secciones presentes.
    $monitorPath = Join-Path $cfgDir 'monitor.json'
    $ftpPath     = Join-Path $cfgDir 'ftp.json'

    $monitorChanged = $false
    $aliasCambiado = $false
    $targetsAnteriores = @()
    if ($targetsNuevos -or $instr.detection -or $aliasNuevo) {
        $mc = Read-JsonFile $monitorPath
        if ($null -eq $mc) { Write-Log 'No existe config\monitor.json; se ignora la instruccion de destinos/detection/alias.' }
        else {
            $targetsAnteriores = @($mc.targets)
            $obj = [ordered]@{ schemaVersion = 1; alias = [string]$mc.alias }
            if ($aliasNuevo -and $aliasNuevo -cne [string]$mc.alias) { $obj.alias = $aliasNuevo; $aliasCambiado = $true }
            if ($targetsNuevos) {
                $obj.targets = @($targetsNuevos | ForEach-Object {
                    $tt = [ordered]@{ address = [string]$_.address }
                    $tt.intervalSec  = if ($_.intervalSec)  { [int]$_.intervalSec }  else { 5 }
                    $tt.confirmPings = if ($_.confirmPings) { [int]$_.confirmPings } else { 1 }
                    $tt
                })
            } else { $obj.targets = @($mc.targets) }
            $det = [ordered]@{ timeoutMs = 2000; networkCheckSec = 5 }
            if ($mc.detection) {
                if ($mc.detection.timeoutMs)       { $det.timeoutMs = [int]$mc.detection.timeoutMs }
                if ($mc.detection.networkCheckSec) { $det.networkCheckSec = [int]$mc.detection.networkCheckSec }
            }
            if ($instr.detection) {
                if ($instr.detection.timeoutMs)       { $det.timeoutMs = [int]$instr.detection.timeoutMs }
                if ($instr.detection.networkCheckSec) { $det.networkCheckSec = [int]$instr.detection.networkCheckSec }
            }
            $obj.detection = $det
            # [v1.13.8] La instruccion puede traer secciones que la PC ya tiene tal cual (el panel las conserva al cambiar
            # el nombre del equipo). Solo si algo cambia de verdad se escribe el archivo y se reinicia el monitor.
            function Get-TextoDestinos($lista) {
                return ((@($lista) | ForEach-Object { '{0}|{1}|{2}' -f [string]$_.address, $(if ($_.intervalSec) { [int]$_.intervalSec } else { 5 }), $(if ($_.confirmPings) { [int]$_.confirmPings } else { 1 }) }) -join ';')
            }
            $destinosCambian = $false
            if ($targetsNuevos) { $destinosCambian = ((Get-TextoDestinos $targetsNuevos) -ne (Get-TextoDestinos $mc.targets)) }
            $deteccionCambia = $false
            if ($instr.detection) {
                $actT = 2000; $actN = 5
                if ($mc.detection) {
                    if ($mc.detection.timeoutMs)       { $actT = [int]$mc.detection.timeoutMs }
                    if ($mc.detection.networkCheckSec) { $actN = [int]$mc.detection.networkCheckSec }
                }
                $deteccionCambia = (($det.timeoutMs -ne $actT) -or ($det.networkCheckSec -ne $actN))
            }
            if ($destinosCambian -or $deteccionCambia -or $aliasCambiado) { Write-JsonFile $monitorPath $obj }
            # Solo destinos/deteccion obligan a reiniciar el monitor; un cambio de alias no (el monitor
            # lo toma en su proximo arranque y Cargador_DB.ps1 lo lee de monitor.json en cada envio).
            if ($destinosCambian -or $deteccionCambia) { $monitorChanged = $true }
        }
    }

    $ftpFreqChanged = $false
    $newFtpRunEveryMin = 0
    if ($instr.ftp) {
        $fc = Read-JsonFile $ftpPath
        if ($null -eq $fc) { Write-Log 'No existe config\ftp.json; se ignora la instruccion de FTP (el FTP no esta habilitado en esta PC).' }
        else {
            $obj = [ordered]@{}
            foreach ($p in $fc.PSObject.Properties) { $obj[$p.Name] = $p.Value }
            if ($instr.ftp.runEveryMin) {
                if ([int]$obj.runEveryMin -ne [int]$instr.ftp.runEveryMin) { $ftpFreqChanged = $true }
                $obj.runEveryMin = [int]$instr.ftp.runEveryMin
            }
            if ($instr.ftp.retries)          { $obj.retries = [int]$instr.ftp.retries }
            if ($null -ne $instr.ftp.uploadCurrentDay) { $obj.uploadCurrentDay = [bool]$instr.ftp.uploadCurrentDay }
            Write-JsonFile $ftpPath $obj
            $newFtpRunEveryMin = [int]$obj.runEveryMin
        }
    }

    $dbFreqChanged = $false
    $newDbRunEveryMin = 0
    if ($instr.db) {
        $obj = [ordered]@{}
        foreach ($p in $dbCfg.PSObject.Properties) { $obj[$p.Name] = $p.Value }
        if ($instr.db.runEveryMin) {
            if ([int]$obj.runEveryMin -ne [int]$instr.db.runEveryMin) { $dbFreqChanged = $true }
            $obj.runEveryMin = [int]$instr.db.runEveryMin
        }
        if ($instr.db.retries) { $obj.retries = [int]$instr.db.retries }
        Write-JsonFile $cfgPath $obj
        $newDbRunEveryMin = [int]$obj.runEveryMin
    }

    # Paso 5: EVENTO + reinicio del monitor SOLO si cambiaron destinos o deteccion (el monitor
    # puede trabajar sin la API ni esta funcion - P3 - por eso un cambio de frecuencia de FTP/DB
    # no toca el monitor en absoluto).
    if ($monitorChanged) {
        Write-RemoteConfigEvent $targetsAnteriores $revision
        Restart-Monitor
    }

    # Paso 6: ajustar disparadores de las tareas de FTP / DB si cambio su frecuencia.
    if ($ftpFreqChanged) { Update-TaskFrequency 'MRV1 FTP' $newFtpRunEveryMin }
    if ($dbFreqChanged)  { Update-TaskFrequency 'MRV1 DB'  $newDbRunEveryMin }

    Write-Log ('Configuracion remota rev. {0} aplicada (destinos/deteccion: {1}, alias: {2}, ftp: {3}, db: {4}).' -f $revision, $monitorChanged, $aliasCambiado, $ftpFreqChanged, $dbFreqChanged)

    # Paso 7: confirmar al servidor y guardar el estado local.
    $confirmado = Confirm-Revision $zombieUrl $token $revision
    Save-State ([ordered]@{ schemaVersion = 1; revisionAplicada = $revision; aplicadaEn = (Get-Date).ToString('s'); confirmada = $confirmado })

    # Paso 8 [v1.13.8]: si cambio el alias, mandar los datos ya con el nombre nuevo. Sin esto, el envio que
    # acaba de terminar (con el nombre anterior) dejaria el nombre viejo en el panel hasta el siguiente.
    if ($aliasCambiado) {
        try {
            $w = 0
            $t = Get-ScheduledTask -TaskName 'MRV1 DB' -ErrorAction SilentlyContinue
            while ($t -and $t.State -eq 'Running' -and $w -lt 90) {
                Start-Sleep -Seconds 2; $w += 2
                $t = Get-ScheduledTask -TaskName 'MRV1 DB' -ErrorAction SilentlyContinue
            }
            if ($t -and $t.State -ne 'Running') {
                Start-ScheduledTask -TaskName 'MRV1 DB' -ErrorAction Stop
                Write-Log 'Alias nuevo aplicado: se pidio un envio de datos a la API para publicarlo.'
            } else { Write-Log 'Alias nuevo aplicado; el envio de datos se hara en su siguiente corrida programada.' }
        } catch { Write-Log ('No se pudo pedir el envio de datos tras cambiar el alias: ' + $_.Exception.Message) }
    }
}
catch {
    Write-Log ('Error general de la sincronizacion de configuracion remota: ' + $_.Exception.Message)
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
}
exit 0
