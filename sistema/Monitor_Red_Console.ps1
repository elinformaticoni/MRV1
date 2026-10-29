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

function Parse-Iso($s) {
    if ($s -is [datetime]) { return $s }
    if ([string]::IsNullOrWhiteSpace([string]$s)) { return $null }
    try { return [datetime]::ParseExact([string]$s, 's', [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

# Ajusta un texto a exactamente $n caracteres: lo recorta con "…" si sobra y lo rellena si falta.
function Fit([string]$s, [int]$n, [bool]$right = $false) {
    if ($n -le 0) { return '' }
    if ($null -eq $s) { $s = '' }
    if ($s.Length -gt $n) {
        if ($n -gt 1) { $s = $s.Substring(0, $n - 1) + '…' } else { $s = $s.Substring(0, $n) }
    }
    if ($right) { return $s.PadLeft($n) }
    return $s.PadRight($n)
}

# Titulo de seccion con una regla fina que llena el ancho: "── TITULO  detalle ─────────"
function New-Rule([string]$title, [int]$w, [string]$extra = '') {
    $h = [string][char]0x2500
    $left = ('{0}{0} ' -f $h)
    $mid = $title
    if ($extra) { $mid += ('  ' + $extra) }
    $fill = $w - 1 - $left.Length - $mid.Length - 1
    if ($fill -lt 2) { $fill = 2 }
    $segs = @((New-Seg $left 'DarkGray'), (New-Seg $title 'White'))
    if ($extra) { $segs += (New-Seg ('  ' + $extra) 'DarkGray') }
    $segs += (New-Seg (' ' + ($h * $fill)) 'DarkGray')
    return ,$segs
}

# $W x $H = tamano actual de la ventana: la pantalla se arma para caber SIEMPRE (nada de desbordes).
function Build-Screen([int]$W, [int]$H) {
    $lines = New-Object System.Collections.ArrayList
    $now = Get-Date
    $sep = [string][char]0x00B7

    $stText = Read-Shared $statusFile
    $st = $null
    if ($stText) { try { $st = $stText | ConvertFrom-Json } catch { $st = $null } }

    if ($null -eq $st) {
        [void]$lines.Add(@((New-Seg 'MONITOR DE RED' 'White')))
        [void]$lines.Add(@((New-Seg '' 'Gray')))
        [void]$lines.Add(@((New-Seg 'Esperando datos del monitor (status.json no disponible)...' 'Yellow')))
        [void]$lines.Add(@((New-Seg 'Si el monitor no está instalado, ejecute Instalar_Monitor.bat.' 'Gray')))
        return $lines
    }

    $ts = Parse-Iso $st.timestamp
    if ($null -eq $ts) { $ts = $now }
    $age = ($now - $ts).TotalSeconds
    $stale = ($age -gt $staleSec)
    $stopped = ($st.running -eq $false)

    # ---- Encabezado: 3 lineas fijas
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
    $title = 'MONITOR DE RED'
    if ($st.version) { $title += ('  ' + $st.version) }
    $aliasTxt = ''
    if (-not [string]::IsNullOrWhiteSpace($alias)) { $aliasTxt = ('   {0}   {1}' -f $sep, $alias.ToUpper()) }
    $right = 'Actualizado ' + $ts.ToString('HH:mm:ss')
    $pad = $W - 1 - $title.Length - $aliasTxt.Length - $right.Length
    if ($pad -lt 2) { $pad = 2 }
    $hdr = @((New-Seg $title 'White'))
    if ($aliasTxt) { $hdr += (New-Seg $aliasTxt 'Cyan') }
    $hdr += (New-Seg ((' ' * $pad) + $right) 'DarkGray')
    [void]$lines.Add($hdr)

    [void]$lines.Add(@((New-Seg ('{0} {1} {2} {1} {3}' -f $st.computer, $sep, $st.user, $adText) 'Gray')))

    $sess = Parse-Iso $st.sessionStart
    if ($null -eq $sess) { $sess = $now }
    $l3 = @((New-Seg ('Sesión desde {0}  ({1} activo)' -f $sess.ToString('yyyy-MM-dd HH:mm:ss'), (Format-Dur (($now - $sess).TotalSeconds))) 'DarkGray'))
    # [v1.11] Revision de configuracion remota ("zombie") aplicada, si Sincronizar_Config.ps1 ya aplico alguna.
    if ($st.configRevision) {
        $rev = [string]$st.configRevision
        $ap = Parse-Iso $st.configAppliedAt
        if ($ap) { $rev += (' (aplicada ' + $ap.ToString('yyyy-MM-dd HH:mm') + ')') }
        $l3 += (New-Seg ('   {0}   Config. remota rev. ' -f $sep) 'DarkGray')
        $l3 += (New-Seg $rev 'DarkCyan')
    }
    [void]$lines.Add($l3)

    if ($stopped) {
        [void]$lines.Add(@((New-Seg '*** MONITOR DETENIDO ***' 'Red')))
    } elseif ($stale) {
        [void]$lines.Add(@((New-Seg '*** MONITOR NO ACTIVO / DATOS DESACTUALIZADOS ***' 'Red')))
    }
    [void]$lines.Add(@((New-Seg '' 'Gray')))

    # ---- Destinos: UNA fila por destino (tabla). Se calculan los totales del dia desde el CSV.
    $all = New-Object System.Collections.ArrayList
    $rowsT = New-Object System.Collections.ArrayList
    $intervals = @{}
    foreach ($t in @($st.targets)) {
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
        $since = Parse-Iso $t.stateSince
        $resp = Parse-Iso $t.lastResponse
        $tot = $okSec + $errSec
        $disp = '--'; if ($tot -gt 0) { $disp = ('{0:0.0}%' -f (100.0 * $okSec / $tot)) }
        $latNow = '--'; if ($null -ne $t.latency) { $latNow = ('{0} ms' -f $t.latency) }
        $latAvg = '--'; if ($latS -gt 0) { $latAvg = ('{0} ms' -f [int][math]::Round($latW / $latS)) }
        if ($t.intervalSec) { $intervals[[string]$t.intervalSec] = $true }
        [void]$rowsT.Add(@{
            dest = [string]$t.address; estado = $status; ecol = $color
            desde = $(if ($since) { $since.ToString('HH:mm:ss') } else { '--' })
            dur = $(if ($since) { Format-Dur $t.stateDuration } else { '--' })
            lat = $latNow; prom = $latAvg
            resp = $(if ($resp) { $resp.ToString('HH:mm:ss') } else { '--' })
            ok = (Format-Dur $okSec); err = (Format-Dur $errSec); errv = $errSec
            caidas = [string]$errCount; disp = $disp
        })
    }

    $extra = ''
    if ($intervals.Count -eq 1) { $extra = ('ping cada {0} s' -f @($intervals.Keys)[0]) }
    [void]$lines.Add((New-Rule 'DESTINOS' $W $extra))
    if ($rowsT.Count -eq 0) {
        [void]$lines.Add(@((New-Seg '  (sin destinos configurados)' 'DarkGray')))
    } else {
        # Columnas por prioridad: en ventanas angostas se omiten las opcionales (Opt = ancho minimo de ventana).
        $defs = @(
            @{ K = 'dest';   H = 'DESTINO';   W = 0;  R = $false; Opt = 0 },
            @{ K = 'estado'; H = 'ESTADO';    W = 7;  R = $false; Opt = 0 },
            @{ K = 'desde';  H = 'DESDE';     W = 8;  R = $false; Opt = 100 },
            @{ K = 'dur';    H = 'DURACIÓN';  W = 8;  R = $false; Opt = 0 },
            @{ K = 'lat';    H = 'LAT.';      W = 7;  R = $true;  Opt = 0 },
            @{ K = 'prom';   H = 'PROM.';     W = 7;  R = $true;  Opt = 100 },
            @{ K = 'resp';   H = 'ÚLT.RESP.'; W = 9;  R = $false; Opt = 118 },
            @{ K = 'ok';     H = 'OK HOY';    W = 8;  R = $false; Opt = 0 },
            @{ K = 'err';    H = 'ERROR HOY'; W = 9;  R = $false; Opt = 0 },
            @{ K = 'caidas'; H = 'CAÍD.';     W = 5;  R = $true;  Opt = 0 },
            @{ K = 'disp';   H = 'DISP.';     W = 6;  R = $true;  Opt = 0 }
        )
        $cols = @($defs | Where-Object { $W -ge $_.Opt })
        $fixed = 2 + (2 * ($cols.Count - 1))
        foreach ($c in $cols) { $fixed += $c.W }
        $destW = $W - 1 - $fixed
        if ($destW -lt 8) { $destW = 8 }
        if ($destW -gt 30) { $destW = 30 }
        foreach ($c in $cols) { if ($c.K -eq 'dest') { $c.W = $destW } }

        $hs = @((New-Seg '  ' 'DarkGray'))
        $first = $true
        foreach ($c in $cols) {
            if (-not $first) { $hs += (New-Seg '  ' 'DarkGray') }
            $first = $false
            $hs += (New-Seg (Fit $c.H $c.W $c.R) 'DarkGray')
        }
        [void]$lines.Add($hs)
        foreach ($rt in $rowsT) {
            $rs = @((New-Seg '  ' 'Gray'))
            $first = $true
            foreach ($c in $cols) {
                if (-not $first) { $rs += (New-Seg '  ' 'Gray') }
                $first = $false
                $col = 'Gray'
                switch ($c.K) {
                    'dest'   { $col = 'White' }
                    'estado' { $col = $rt.ecol }
                    'ok'     { $col = 'Green' }
                    'err'    { if ($rt.errv -gt 0) { $col = 'Red' } else { $col = 'DarkGray' } }
                    'caidas' { if ($rt.caidas -ne '0') { $col = 'Yellow' } else { $col = 'DarkGray' } }
                }
                $rs += (New-Seg (Fit ([string]$rt[$c.K]) $c.W $c.R) $col)
            }
            [void]$lines.Add($rs)
        }
    }
    [void]$lines.Add(@((New-Seg '' 'Gray')))

    # ---- Cargas al servidor (FTP y API/DB) [MEJORA v1.9]: de un vistazo, para cada cargador,
    # si esta configurado o no, si la ultima carga fue correcta, cuando fue y cuando sera la proxima.
    # La consola no habla con el servidor FTP ni con la API: solo lee config\*.json (para saber si
    # el componente esta configurado) y los *_status.json que escriben Cargador_FTP.ps1 / Cargador_DB.ps1.
    [void]$lines.Add((New-Rule 'CARGAS AL SERVIDOR' $W))
    foreach ($ln in (Get-LoaderLines 'FTP' $now)) { [void]$lines.Add($ln) }
    foreach ($ln in (Get-LoaderLines 'DB' $now)) { [void]$lines.Add($ln) }
    [void]$lines.Add(@((New-Seg '' 'Gray')))

    # ---- Cambios de hoy (los EVENTO/INICIO repetidos en varios destinos se muestran como "todos")
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

    # La cantidad de cambios mostrados se calcula con el alto REAL de la ventana: escribir mas lineas
    # de las que caben haria que la consola se desplace sola y rompe el redibujado (ver Draw).
    # Se reservan: regla + cabecera de columnas + linea en blanco + pie.
    $avail = $H - 1 - $lines.Count - 4
    if ($avail -lt 1) { $avail = 1 }
    $shown = $sorted
    if ($sorted.Count -gt $avail) { $shown = $sorted[0..($avail - 1)] }
    $extra = ''
    if ($sorted.Count -gt $shown.Count) { $extra = ('mostrando los {0} más recientes de {1}  ·  el resto está en logs\' -f $shown.Count, $sorted.Count) }
    elseif ($sorted.Count -gt 0) { $extra = ('{0} en total' -f $sorted.Count) }
    [void]$lines.Add((New-Rule 'CAMBIOS DE HOY' $W $extra))

    $dW = 18; if ($W -lt 100) { $dW = 14 }
    $msgW = $W - 1 - (2 + 8 + 2 + $dW + 2 + 7 + 2 + 10 + 2 + 8 + 2)
    if ($msgW -lt 10) { $msgW = 10 }
    [void]$lines.Add(@((New-Seg ('  {0}  {1}  {2}  {3}  {4}  {5}' -f (Fit 'HORA' 8), (Fit 'DESTINO' $dW), (Fit 'TIPO' 7), (Fit 'TIEMPO' 10), (Fit 'LAT.' 8 $true), 'MENSAJE') 'DarkGray')))
    if ($sorted.Count -eq 0) {
        [void]$lines.Add(@((New-Seg '  (sin registros hoy)' 'DarkGray')))
    }
    foreach ($e in $shown) {
        $r = $e.R
        $dest = $e.Dest
        if ($e.Count -gt 1) { $dest = 'todos' }
        $dur = ''
        if ($r.Incomplete) { $dur = 'incompleto' }
        elseif ($r.Open) { $dur = 'en curso' }
        elseif ($null -ne $r.Sec -and (($r.Type -eq 'OK') -or ($r.Type -eq 'ERROR'))) { $dur = Format-Dur $r.Sec }
        $lat = '--'
        if (($r.Type -eq 'OK') -and (-not $r.Incomplete) -and (-not $r.Open) -and ($null -ne $r.Lat)) { $lat = ('{0} ms' -f $r.Lat) }
        elseif (($r.Type -eq 'EVENTO') -or ($r.Type -eq 'INICIO')) { $lat = '' }
        $col = Get-TypeColor $r.Type $r.Incomplete
        [void]$lines.Add(@(
            (New-Seg ('  {0}  {1}  ' -f $r.When.ToString('HH:mm:ss'), (Fit $dest $dW)) 'Gray'),
            (New-Seg ((Fit ([string]$r.Type) 7) + '  ') $col),
            (New-Seg ('{0}  {1}  ' -f (Fit $dur 10), (Fit $lat 8 $true)) 'Gray'),
            (New-Seg (Fit ([string]$r.Msg).Trim() $msgW) $col)))
    }
    [void]$lines.Add(@((New-Seg '' 'Gray')))
    [void]$lines.Add(@((New-Seg 'Q = salir   (cerrar esta ventana no detiene el monitor)' 'DarkGray')))
    return $lines
}

# ---------------------------------------------------------------------------------------------
# Dibujo
# ---------------------------------------------------------------------------------------------
# Se probaron varias formas de reposicionar el cursor para redibujar "en sitio" sin parpadeo
# ([Console]::SetCursorPosition, reanclar la ventana, la secuencia ANSI ESC[H) y en este equipo
# (Windows Terminal) ninguna evito que el encabezado se siguiera insertando como lineas nuevas en
# vez de sobrescribirse. Se usa [Console]::Clear() antes de cada dibujado: es mas tosco (puede
# producir un parpadeo minimo) pero es la unica forma que garantiza, en cualquier terminal, que la
# pantalla realmente se reinicia antes de escribir el cuadro nuevo.
# Anti-desborde: se escribe como maximo (alto - 1) lineas (la ultima fila nunca se usa, asi el cursor
# no provoca un desplazamiento) y cada linea se recorta con "…" al ancho de la ventana (sin saltos de linea).
function Draw([System.Collections.ArrayList]$lines, [int]$w, [int]$h) {
    $maxW = $w - 1
    if ($maxW -lt 20) { $maxW = 20 }
    $maxL = $h - 1
    if ($maxL -lt 1) { $maxL = 1 }
    try { [Console]::Clear() } catch { }
    $n = [math]::Min($lines.Count, $maxL)
    for ($i = 0; $i -lt $n; $i++) {
        $used = 0
        foreach ($seg in $lines[$i]) {
            $txt = $seg.T
            $cut = $false
            if (($used + $txt.Length) -gt $maxW) {
                $room = $maxW - $used
                if ($room -le 0) { break }
                if ($room -gt 1) { $txt = $txt.Substring(0, $room - 1) + '…' } else { $txt = '…' }
                $cut = $true
            }
            [Console]::ForegroundColor = [System.ConsoleColor]$seg.C
            [Console]::Write($txt)
            $used += $txt.Length
            if ($cut) { break }
        }
        [Console]::ForegroundColor = [System.ConsoleColor]::Gray
        [Console]::WriteLine()
    }
}

# ---------------------------------------------------------------------------------------------
# Bucle principal
# ---------------------------------------------------------------------------------------------
try { $Host.UI.RawUI.WindowTitle = 'Monitor de Red - Consola' } catch { }
# Ventana de tamano razonable (cabe en una pantalla normal). El buffer se mantiene IGUAL a la
# ventana (sin barra de desplazamiento): la pantalla se arma a medida del tamano real, y si el
# usuario redimensiona la ventana se vuelve a ajustar en el siguiente cuadro.
$consoleW = 118
$consoleH = 38
try {
    [Console]::SetWindowSize(80, 25)
    [Console]::SetBufferSize($consoleW, $consoleH)
    [Console]::SetWindowSize($consoleW, $consoleH)
} catch {
    try { & cmd.exe /c ('mode con: cols={0} lines={1}' -f $consoleW, $consoleH) | Out-Null } catch { }
}
try {
    [Console]::CursorVisible = $false
    [Console]::Clear()
    while ($true) {
        try {
            $W = [Console]::WindowWidth
            $H = [Console]::WindowHeight
            try {
                if (([Console]::BufferWidth -ne $W) -or ([Console]::BufferHeight -ne $H)) { [Console]::SetBufferSize($W, $H) }
            } catch { }
            $screen = Build-Screen $W $H
            Draw $screen $W $H
        } catch {
            try { [Console]::Clear(); [Console]::ForegroundColor = [System.ConsoleColor]::Red; [Console]::WriteLine(('Error al actualizar: ' + $_.Exception.Message).PadRight(100)) } catch { }
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
