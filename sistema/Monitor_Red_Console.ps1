<#
.SYNOPSIS
    Monitor de Red (MR) - Monitor_Red_Console.ps1
.DESCRIPTION
    Consola de solo lectura (P4): NO hace ping, no guarda nada. Lee status.json (estado instantaneo)
    y los CSV del dia (historial, totales y todos los cambios) y se actualiza cada segundo.
    Muestra tambien el estado de las cargas FTP y API/DB (configurada o no, ultima carga, si fue
    correcta y proxima ejecucion) leyendo config\*.json y ftp_status.json / db_status.json.
    Cerrar la consola no afecta al monitor. Tecla Q para salir.
#>
param([string]$Root)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

# La consola imprime acentos y otros caracteres fuera de ASCII (á, é, í, ó, ú, Ñ...). La consola
# de Windows suele arrancar con una pagina de codigos OEM (437/850) que no los representa bien,
# aunque el script y los CSV esten en UTF-8. Se fuerza aqui la salida a UTF-8 (equivale a chcp 65001).
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$statusFile    = Join-Path $Root 'status.json'
$ftpStatusFile = Join-Path $Root 'ftp_status.json'
$dbStatusFile  = Join-Path $Root 'db_status.json'
$ftpCfgFile    = Join-Path $Root 'config\ftp.json'
$dbCfgFile     = Join-Path $Root 'config\db_api.json'
$loaderGraceMin = 15    # margen tras la hora prevista antes de marcar una carga como ATRASADA
$logDir        = Join-Path $Root 'logs'
$staleSec      = 15      # el monitor escribe status.json cada segundo
$cache         = @{}
$script:TitleAlias = ''

# ---------------------------------------------------------------------------------------------
# Lectura compartida (no bloquea al monitor)
# ---------------------------------------------------------------------------------------------
function Read-Shared([string]$path) {
    try {
        $share = [System.IO.FileShare]([int][System.IO.FileShare]::ReadWrite -bor [int][System.IO.FileShare]::Delete)
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
            return $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return $null }
}

function Get-SafeName([string]$s) { return ($s -replace '[\\/:*?"<>|]', '_') }

function Format-Dur($sec) {
    if ($null -eq $sec) { return '--:--:--' }
    $s = [int][math]::Round([double]$sec)
    if ($s -lt 0) { $s = 0 }
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60), ($s % 60))
}

# ---------------------------------------------------------------------------------------------
# CSV del dia -> filas
# ---------------------------------------------------------------------------------------------
function Get-Rows([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $fi = Get-Item -LiteralPath $file
    $sig = '{0}|{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length
    if ($cache.ContainsKey($file) -and ($cache[$file].Sig -eq $sig)) { return $cache[$file].Rows }
    $text = Read-Shared $file
    if ($null -eq $text) {
        if ($cache.ContainsKey($file)) { return $cache[$file].Rows }
        return @()
    }
    $rows = New-Object System.Collections.ArrayList
    $seq = 0
    $lastState = -1
    foreach ($line in ($text -split "`n")) {
        $l = $line.TrimEnd("`r")
        if ($l -notmatch '^\d{4}-\d{2}-\d{2};') { continue }
        $p = $l.Split(';', 6)
        if ($p.Count -lt 6) { continue }
        $when = [datetime]::MinValue
        if (-not [datetime]::TryParseExact(($p[0] + ' ' + $p[1]), 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$when)) { continue }
        $sec = $null; $lat = $null
        if ($p[3] -ne '') { $sec = [int]$p[3] }
        if ($p[4] -ne '') { $lat = [int]$p[4] }
        $msg = $p[5]
        $isState = ($p[2] -eq 'OK') -or ($p[2] -eq 'ERROR')
        $incomplete = $isState -and ($null -eq $sec) -and $msg.EndsWith('[INCOMPLETO]')
        $seq++
        $r = @{ When = $when; Type = $p[2]; Sec = $sec; Lat = $lat; Msg = $msg; Seq = $seq; Open = $false; Incomplete = $incomplete }
        [void]$rows.Add($r)
        if ($isState) { $lastState = $rows.Count - 1 }
    }
    # La ultima fila de estado sin cerrar y sin marca es el estado en curso; otras filas en blanco quedan incompletas
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        if ((($r.Type -eq 'OK') -or ($r.Type -eq 'ERROR')) -and ($null -eq $r.Sec) -and (-not $r.Incomplete)) {
            if ($i -eq $lastState) { $r.Open = $true } else { $r.Incomplete = $true }
        }
    }
    $arr = $rows.ToArray()
    $cache[$file] = @{ Sig = $sig; Rows = $arr }
    return $arr
}

# ---------------------------------------------------------------------------------------------
# Cargadores FTP y API/DB [MEJORA v1.9]
# ---------------------------------------------------------------------------------------------
function Read-JsonShared([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $txt = Read-Shared $path
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    try { return ($txt | ConvertFrom-Json) } catch { return $null }
}

function ConvertTo-LocalDate($s) {
    if ($s -is [datetime]) { return $s }   # PowerShell 7 ya convierte las fechas ISO al leer el JSON
    if ([string]::IsNullOrWhiteSpace([string]$s)) { return $null }
    try { return [datetime]::ParseExact([string]$s, 's', [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

# Hora corta si es hoy; fecha y hora si fue otro dia (una carga de ayer no debe parecer de hoy).
function Format-When([datetime]$dt, [datetime]$now) {
    if ($dt.Date -eq $now.Date) { return $dt.ToString('HH:mm:ss') }
    return $dt.ToString('yyyy-MM-dd HH:mm')
}

# Estado de configuracion de un cargador: 'none' (no instalado), 'incomplete' (falta un dato) u 'ok'.
# Si el archivo existe pero no se puede leer (permisos), se asume configurado y decide el *_status.json.
function Get-LoaderConfigState([string]$kind) {
    if ($kind -eq 'FTP') {
        $cfgPath = $ftpCfgFile
        $need = @('host')
    } else {
        $cfgPath = $dbCfgFile
        $need = @('apiUrl', 'token')
    }
    if (-not (Test-Path -LiteralPath $cfgPath)) { return 'none' }
    $cfg = Read-JsonShared $cfgPath
    if ($null -eq $cfg) { return 'ok' }
    foreach ($k in $need) {
        if ([string]::IsNullOrWhiteSpace([string]$cfg.$k)) { return 'incomplete' }
    }
    return 'ok'
}

# Devuelve las lineas (segmentos) de estado de un cargador: 'FTP' o 'DB'.
function Get-LoaderLines([string]$kind, [datetime]$now) {
    $out = New-Object System.Collections.ArrayList
    if ($kind -eq 'FTP') {
        $label = '  FTP  '; $bat = 'Instalar_FTP.bat'; $task = 'MRV1 FTP'; $log = 'diag\ftp_worker.log'
        $statusPath = $ftpStatusFile; $what = 'La carga FTP'
    } else {
        $label = '  DB   '; $bat = 'Instalar_DB.bat';  $task = 'MRV1 DB';  $log = 'diag\db_worker.log'
        $statusPath = $dbStatusFile;  $what = 'La carga al servidor DB'
    }

    $cfgState = Get-LoaderConfigState $kind
    if ($cfgState -eq 'none') {
        [void]$out.Add(@((New-Seg $label 'White'), (New-Seg 'NO CONFIGURADO' 'DarkGray'), (New-Seg ('   {0} no está configurada (ejecute {1} para habilitarla).' -f $what, $bat) 'DarkGray')))
        return ,$out
    }
    if ($cfgState -eq 'incomplete') {
        [void]$out.Add(@((New-Seg $label 'White'), (New-Seg 'CONFIGURACIÓN INCOMPLETA' 'Yellow'), (New-Seg ('   {0} tiene datos faltantes (ejecute {1} para completarla).' -f $what, $bat) 'Yellow')))
        return ,$out
    }

    $st = Read-JsonShared $statusPath
    if ($null -eq $st) {
        [void]$out.Add(@((New-Seg $label 'White'), (New-Seg 'SIN EJECUTAR' 'Yellow'), (New-Seg ('   Configurada; aún no hay cargas registradas (espere la tarea programada ''{0}'').' -f $task) 'Gray')))
        return ,$out
    }

    $last = ConvertTo-LocalDate $st.timestamp
    $next = ConvertTo-LocalDate $st.nextRun
    $lastTxt = '--'
    if ($last) { $lastTxt = ('{0} (hace {1})' -f (Format-When $last $now), (Format-Dur (($now - $last).TotalSeconds))) }

    # Proxima carga: a tiempo / en breve / atrasada (la tarea no corrio cuando tocaba).
    $nextSegs = @((New-Seg '   Próxima: ' 'Gray'))
    if ($null -eq $next) {
        $nextSegs += (New-Seg '--' 'Gray')
    } elseif ($next -gt $now) {
        $nextSegs += (New-Seg ('{0} (en {1})' -f (Format-When $next $now), (Format-Dur (($next - $now).TotalSeconds))) 'Gray')
    } elseif (($now - $next).TotalMinutes -le $loaderGraceMin) {
        $nextSegs += (New-Seg 'en breve' 'Yellow')
    } else {
        $nextSegs += (New-Seg ('ATRASADA desde {0}' -f (Format-When $next $now)) 'Yellow')
    }

    if ($st.ok) {
        $head = @((New-Seg $label 'White'), (New-Seg 'OK' 'Green'), (New-Seg ('   Última carga: ' + $lastTxt) 'Gray')) + $nextSegs
        [void]$out.Add($head)
        if ($kind -eq 'FTP') {
            $old = [int]$st.uploadedOld; $today = [int]$st.uploadedToday
            $dirTxt = ''; if ($st.remoteDir) { $dirTxt = ('   Carpeta: {0}' -f $st.remoteDir) }
            [void]$out.Add(@((New-Seg ('         Archivos subidos: {0} (días anteriores {1} + hoy {2}){3}' -f ($old + $today), $old, $today, $dirTxt) 'DarkGray')))
        } else {
            $old = [int]$st.syncedOld; $today = [int]$st.syncedToday
            [void]$out.Add(@((New-Seg ('         Archivos sincronizados: {0} (días anteriores {1} + hoy {2})   Filas: {3} nuevas, {4} actualizadas' -f ($old + $today), $old, $today, [int]$st.insertadas, [int]$st.actualizadas) 'DarkGray')))
        }
    } else {
        $head = @((New-Seg $label 'White'), (New-Seg '*** ERROR ***' 'Red'), (New-Seg ('   Último intento: ' + $lastTxt) 'Gray')) + $nextSegs
        [void]$out.Add($head)
        $errMsg = [string]$st.lastError
        if ([string]::IsNullOrWhiteSpace($errMsg)) { $errMsg = ('(sin detalle; revise {0})' -f $log) }
        [void]$out.Add(@((New-Seg '         ' 'Gray'), (New-Seg $errMsg 'Red')))
        if ($kind -eq 'FTP') {
            [void]$out.Add(@((New-Seg ('         Vuelva a ejecutar {0} para corregir host, usuario, contraseña o carpeta.' -f $bat) 'Yellow')))
        } else {
            [void]$out.Add(@((New-Seg ('         Vuelva a ejecutar {0} para corregir la URL, el token o la conexión.' -f $bat) 'Yellow')))
        }
    }
    if ($next -and (($now - $next).TotalMinutes -gt $loaderGraceMin)) {
        [void]$out.Add(@((New-Seg ('         La tarea programada ''{0}'' no ha corrido cuando tocaba; verifique que exista y esté habilitada.' -f $task) 'Yellow')))
    }
    return ,$out
}

# ---------------------------------------------------------------------------------------------
# Construccion de la pantalla (cada linea = lista de segmentos texto/color)
# ---------------------------------------------------------------------------------------------
function New-Seg([string]$text, [string]$color) { return @{ T = $text; C = $color } }

function Get-TypeColor($type, $incomplete) {
    if ($incomplete) { return 'DarkGray' }
    switch ($type) {
        'OK'     { return 'Green' }
        'ERROR'  { return 'Red' }
        'EVENTO' { return 'Yellow' }
        'INICIO' { return 'Cyan' }
        default  { return 'Gray' }
    }
}

function Build-Screen {
    $lines = New-Object System.Collections.ArrayList
    $now = Get-Date

    $stText = Read-Shared $statusFile
    $st = $null
    if ($stText) { try { $st = $stText | ConvertFrom-Json } catch { $st = $null } }

    if ($null -eq $st) {
        [void]$lines.Add(@((New-Seg 'MONITOR DE RED' 'White')))
        [void]$lines.Add(@((New-Seg '' 'Gray')))
        [void]$lines.Add(@((New-Seg 'Esperando datos del monitor (status.json no disponible)...' 'Yellow')))
        [void]$lines.Add(@((New-Seg 'Si el monitor no esta instalado, ejecute Instalar_Monitor.bat.' 'Gray')))
        return $lines
    }

    $ts = $now
    try { $ts = [datetime]::ParseExact([string]$st.timestamp, 's', [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
    $age = ($now - $ts).TotalSeconds
    $stale = ($age -gt $staleSec)
    $stopped = ($st.running -eq $false)

    # ---- Encabezado
    # [v1.9] Alias de la PC: de status.json; si el monitor en marcha es anterior y no lo trae, de config\monitor.json.
    $alias = [string]$st.alias
    if ([string]::IsNullOrWhiteSpace($alias)) {
        $mc = Read-JsonShared (Join-Path $Root 'config\monitor.json')
        if ($mc -and $mc.alias) { $alias = [string]$mc.alias }
    }
    if (-not [string]::IsNullOrWhiteSpace($alias) -and ($alias -ne $script:TitleAlias)) {
        $script:TitleAlias = $alias
        try { $Host.UI.RawUI.WindowTitle = 'Monitor de Red - ' + $alias } catch { }
    }
    $ad = $st.adapter
    $adText = '(sin adaptador)'
    if ($ad -and $ad.name -and ($ad.ip)) {
        $adText = ('{0} ({1}{2}) {3}' -f $ad.name, $ad.type, $(if ($ad.ssid) { ' ' + $ad.ssid } else { '' }), $ad.ip)
    }
    $hdr = @((New-Seg ('MONITOR DE RED  ' + $st.version) 'White'))
    if (-not [string]::IsNullOrWhiteSpace($alias)) { $hdr += (New-Seg '   ·   ' 'DarkGray'); $hdr += (New-Seg $alias.ToUpper() 'Cyan') }
    $hdr += (New-Seg ('     Actualizado ' + $ts.ToString('HH:mm:ss')) 'DarkGray')
    [void]$lines.Add($hdr)
    [void]$lines.Add(@((New-Seg ('COMPUTADORA: {0}   USUARIO: {1}' -f $st.computer, $st.user) 'Gray')))
    [void]$lines.Add(@((New-Seg ('ADAPTADOR: ' + $adText) 'Gray')))
    $sess = $now
    try { $sess = [datetime]::ParseExact([string]$st.sessionStart, 's', [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
    [void]$lines.Add(@((New-Seg ('SESIÓN DESDE: {0}   TIEMPO ACTIVO: {1}' -f $sess.ToString('yyyy-MM-dd HH:mm:ss'), (Format-Dur (($now - $sess).TotalSeconds))) 'Gray')))
    if ($stopped) {
        [void]$lines.Add(@((New-Seg '*** MONITOR DETENIDO ***' 'Red')))
    } elseif ($stale) {
        [void]$lines.Add(@((New-Seg '*** MONITOR NO ACTIVO / DATOS DESACTUALIZADOS ***' 'Red')))
    }
    [void]$lines.Add(@((New-Seg '' 'Gray')))

    # ---- Por destino
    $all = New-Object System.Collections.ArrayList
    $n = 0
    $targets = @($st.targets)
    foreach ($t in $targets) {
        $n++
        $file = Join-Path $logDir ('{0} {1} {2}.csv' -f $st.computer, (Get-SafeName ([string]$t.address)), $now.ToString('yyyy-MM-dd'))
        $rows = Get-Rows $file

        $okSec = 0; $errSec = 0; $errCount = 0; $latW = 0.0; $latS = 0.0
        foreach ($r in $rows) {
            if ($r.Type -eq 'OK') {
                if ($null -ne $r.Sec) { $okSec += $r.Sec; if (($null -ne $r.Lat) -and ($r.Lat -gt 0) -and ($r.Sec -gt 0)) { $latW += ($r.Lat * $r.Sec); $latS += $r.Sec } }
                elseif ($r.Open) { $okSec += ($now - $r.When).TotalSeconds }
            } elseif ($r.Type -eq 'ERROR') {
                if ($r.Incomplete) { continue }
                $errCount++
                if ($null -ne $r.Sec) { $errSec += $r.Sec } elseif ($r.Open) { $errSec += ($now - $r.When).TotalSeconds }
            }
            [void]$all.Add(@{ Dest = [string]$t.address; R = $r })
        }

        $status = [string]$t.status
        $color = 'Yellow'
        if ($status -eq 'OK') { $color = 'Green' } elseif ($status -eq 'ERROR') { $color = 'Red' }
        if ($stale -or $stopped) { $color = 'DarkGray' }
        $since = ''
        if ($t.stateSince) { $since = ' desde ' + ([datetime]::ParseExact([string]$t.stateSince, 's', [System.Globalization.CultureInfo]::InvariantCulture)).ToString('HH:mm:ss') + ' (' + (Format-Dur $t.stateDuration) + ')' }
        [void]$lines.Add(@((New-Seg ('DESTINO {0}: {1}   ' -f $n, $t.address) 'White'), (New-Seg ('ESTADO: ' + $status) $color), (New-Seg $since 'Gray')))

        $latNow = '--'; if ($null -ne $t.latency) { $latNow = ('{0} ms' -f $t.latency) }
        $latAvg = '--'; if ($latS -gt 0) { $latAvg = ('{0} ms' -f [int][math]::Round($latW / $latS)) }
        $lastResp = '--'
        if ($t.lastResponse) { $lastResp = ([datetime]::ParseExact([string]$t.lastResponse, 's', [System.Globalization.CultureInfo]::InvariantCulture)).ToString('HH:mm:ss') }
        [void]$lines.Add(@((New-Seg ('  Latencia: {0} (prom. del día: {1})   Última respuesta: {2}   Intervalo: {3} s' -f $latNow, $latAvg, $lastResp, $t.intervalSec) 'Gray')))
        $tot = $okSec + $errSec
        $pct = ''
        if ($tot -gt 0) { $pct = (' ({0:0.0}% disponible)' -f (100.0 * $okSec / $tot)) }
        [void]$lines.Add(@((New-Seg '  Hoy: ' 'Gray'), (New-Seg ('OK ' + (Format-Dur $okSec)) 'Green'), (New-Seg '  ' 'Gray'), (New-Seg ('ERROR ' + (Format-Dur $errSec)) 'Red'), (New-Seg ('   Caídas: {0}{1}' -f $errCount, $pct) 'Gray')))
        [void]$lines.Add(@((New-Seg '' 'Gray')))
    }

    # ---- Cargas al servidor (FTP y API/DB) [MEJORA v1.9]: de un vistazo, para cada cargador,
    # si esta configurado o no, si la ultima carga fue correcta, cuando fue y cuando sera la proxima.
    # La consola no habla con el servidor FTP ni con la API: solo lee config\*.json (para saber si
    # el componente esta configurado) y los *_status.json que escriben Cargador_FTP.ps1 / Cargador_DB.ps1.
    [void]$lines.Add(@((New-Seg 'CARGAS AL SERVIDOR' 'White')))
    foreach ($ln in (Get-LoaderLines 'FTP' $now)) { [void]$lines.Add($ln) }
    foreach ($ln in (Get-LoaderLines 'DB' $now)) { [void]$lines.Add($ln) }
    [void]$lines.Add(@((New-Seg '' 'Gray')))

    # ---- Todos los cambios de hoy (los EVENTO/INICIO repetidos en varios destinos se muestran como "todos")
    [void]$lines.Add(@((New-Seg 'TODOS LOS CAMBIOS DE HOY' 'White')))
    [void]$lines.Add(@((New-Seg ('  {0,-9}{1,-23}{2,-8}{3,-11}{4,-9}{5}' -f 'HORA', 'DESTINO', 'TIPO', 'TIEMPO', 'LATENCIA', 'MENSAJE') 'DarkGray')))
    $groups = @{}
    $entries = New-Object System.Collections.ArrayList
    foreach ($e in $all) {
        $r = $e.R
        if (($r.Type -eq 'EVENTO') -or ($r.Type -eq 'INICIO')) {
            $key = '{0}|{1}|{2}' -f $r.When.ToString('s'), $r.Type, $r.Msg
            if ($groups.ContainsKey($key)) { $groups[$key].Count++; continue }
            $g = @{ Dest = $e.Dest; R = $r; Count = 1 }
            $groups[$key] = $g
            [void]$entries.Add($g)
        } else {
            [void]$entries.Add(@{ Dest = $e.Dest; R = $r; Count = 1 })
        }
    }
    $sorted = @($entries | Sort-Object -Property @{ Expression = { $_.R.When }; Descending = $true }, @{ Expression = { $_.R.Seq }; Descending = $true })
    if ($sorted.Count -eq 0) {
        [void]$lines.Add(@((New-Seg '  (sin registros hoy)' 'DarkGray')))
    }
    foreach ($e in $sorted) {
        $r = $e.R
        $dest = $e.Dest
        if ($e.Count -gt 1) { $dest = 'todos' }
        if ($dest.Length -gt 22) { $dest = $dest.Substring(0, 22) }
        $dur = ''
        if ($r.Incomplete) { $dur = 'incompleto' }
        elseif ($r.Open) { $dur = 'en curso' }
        elseif ($null -ne $r.Sec -and (($r.Type -eq 'OK') -or ($r.Type -eq 'ERROR'))) { $dur = Format-Dur $r.Sec }
        $lat = '--'
        if (($r.Type -eq 'OK') -and (-not $r.Incomplete) -and (-not $r.Open) -and ($null -ne $r.Lat)) { $lat = ('{0} ms' -f $r.Lat) }
        elseif (($r.Type -eq 'EVENTO') -or ($r.Type -eq 'INICIO')) { $lat = '' }
        $col = Get-TypeColor $r.Type $r.Incomplete
        [void]$lines.Add(@((New-Seg ('  {0}  {1,-22} ' -f $r.When.ToString('HH:mm:ss'), $dest) 'Gray'), (New-Seg ('{0,-7} ' -f $r.Type) $col), (New-Seg ('{0,-10} ' -f $dur) 'Gray'), (New-Seg ('{0,-8} ' -f $lat) 'Gray'), (New-Seg $r.Msg $col)))
    }
    [void]$lines.Add(@((New-Seg '' 'Gray')))
    [void]$lines.Add(@((New-Seg 'Q = salir   (cerrar esta ventana no detiene el monitor)' 'DarkGray')))
    return $lines
}

# ---------------------------------------------------------------------------------------------
# Dibujo sin parpadeo (se reposiciona el cursor, no se usa Clear-Host)
# ---------------------------------------------------------------------------------------------
function Draw([System.Collections.ArrayList]$lines, [int]$prevCount) {
    $w = [Console]::WindowWidth - 1
    if ($w -lt 20) { $w = 20 }
    [Console]::SetCursorPosition(0, 0)
    foreach ($ln in $lines) {
        $used = 0
        foreach ($seg in $ln) {
            $txt = $seg.T
            if (($used + $txt.Length) -gt $w) { $txt = $txt.Substring(0, [math]::Max(0, $w - $used)) }
            [Console]::ForegroundColor = [System.ConsoleColor]$seg.C
            [Console]::Write($txt)
            $used += $txt.Length
        }
        [Console]::ForegroundColor = [System.ConsoleColor]::Gray
        if ($used -lt $w) { [Console]::Write((' ' * ($w - $used))) }
        [Console]::WriteLine()
    }
    for ($i = $lines.Count; $i -lt $prevCount; $i++) { [Console]::Write((' ' * $w)); [Console]::WriteLine() }
    return $lines.Count
}

# ---------------------------------------------------------------------------------------------
# Bucle principal
# ---------------------------------------------------------------------------------------------
try { $Host.UI.RawUI.WindowTitle = 'Monitor de Red - Consola' } catch { }
# Al quitar el limite de "ultimos 20 cambios" la pantalla puede crecer mucho en un dia con muchas
# caidas. Se agranda el buffer de la consola (historial desplazable) muy por encima de la ventana
# visible, para que el redibujado en sitio (Draw, mas abajo) nunca truncated de forma brusca y el
# usuario pueda usar la barra de desplazamiento para ver cambios mas antiguos del dia.
try {
    [Console]::SetWindowSize(80, 25)
    [Console]::SetBufferSize(118, 3000)
    [Console]::SetWindowSize(118, 46)
} catch {
    try { & cmd.exe /c 'mode con: cols=118 lines=46' | Out-Null } catch { }
}
$prev = 0
try {
    [Console]::CursorVisible = $false
    [Console]::Clear()
    while ($true) {
        try {
            $screen = Build-Screen
            $prev = Draw $screen $prev
        } catch {
            try { [Console]::SetCursorPosition(0, 0); [Console]::ForegroundColor = [System.ConsoleColor]::Red; [Console]::WriteLine(('Error al actualizar: ' + $_.Exception.Message).PadRight(100)) } catch { }
        }
        $until = (Get-Date).AddSeconds(1)
        $quit = $false
        while ((Get-Date) -lt $until) {
            try {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq [System.ConsoleKey]::Q) { $quit = $true; break }
                }
            } catch { }
            Start-Sleep -Milliseconds 100
        }
        if ($quit) { break }
    }
} finally {
    try { [Console]::CursorVisible = $true; [Console]::ResetColor(); [Console]::WriteLine() } catch { }
}
