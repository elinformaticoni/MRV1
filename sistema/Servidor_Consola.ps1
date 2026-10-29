<#
.SYNOPSIS
    Monitor de Red (MR) - Servidor_Consola.ps1  [v1.12]
.DESCRIPTION
    Consola web de SOLO LECTURA (P4). Levanta un servidor HTTP minimo que escucha unicamente en
    esta misma PC (localhost), sirve la pagina Consola_Web.html (SPA) y le entrega los datos que ya
    existen en disco: status.json, los CSV del dia, ftp_status.json y db_status.json.
    NO hace ping, NO escribe nada y NO contacta ningun servidor externo. Cerrarlo no afecta al monitor.

    - Si ya hay una consola web de esta instalacion en marcha, solo abre el navegador en ella.
    - Se cierra solo tras -IdleMin minutos sin que ninguna pagina lo consulte (la pagina abierta
      consulta cada segundo, asi que mientras haya una pestana abierta sigue vivo).
    - No necesita permisos de administrador.
#>
param(
    [string]$Root,
    [int]$Port = 8765,
    [int]$IdleMin = 10,
    [switch]$NoAbrir
)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [System.IO.Path]::GetFullPath($Root)
$htmlFile      = Join-Path $PSScriptRoot 'Consola_Web.html'
$statusFile    = Join-Path $Root 'status.json'
$ftpStatusFile = Join-Path $Root 'ftp_status.json'
$dbStatusFile  = Join-Path $Root 'db_status.json'
$ftpCfgFile    = Join-Path $Root 'config\ftp.json'
$dbCfgFile     = Join-Path $Root 'config\db_api.json'
$monCfgFile    = Join-Path $Root 'config\monitor.json'
$logDir        = Join-Path $Root 'logs'
$diagDir       = Join-Path $Root 'diag'
$cache         = @{}
$utf8          = New-Object System.Text.UTF8Encoding($false)

function Write-ServerLog([string]$msg) {
    try {
        if (-not (Test-Path -LiteralPath $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $diagDir 'consola_web.log') -Value ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch { }
}

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

# Devuelve el texto JSON del archivo si existe y es valido (para incrustarlo tal cual); si no, $null.
function Read-JsonText([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $txt = Read-Shared $path
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    try { $null = $txt | ConvertFrom-Json } catch { return $null }
    return $txt.Trim([char]0xFEFF).Trim()
}

function Read-JsonObj([string]$path) {
    $t = Read-JsonText $path
    if ($null -eq $t) { return $null }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

function Get-SafeName([string]$s) { return ($s -replace '[\\/:*?"<>|]', '_') }

function ConvertTo-JsonString([string]$s) {
    if ($null -eq $s) { return 'null' }
    $e = $s.Replace('\', '\\').Replace('"', '\"')
    $e = [regex]::Replace($e, '[\x00-\x1f]', { param($m) ('\u{0:x4}' -f [int][char]$m.Value) })
    return '"' + $e + '"'
}

# Estado de configuracion de un cargador: 'none' (no instalado), 'incomplete' (falta un dato) u 'ok'.
function Get-LoaderConfigState([string]$kind) {
    if ($kind -eq 'FTP') { $cfgPath = $ftpCfgFile; $need = @('host') }
    else { $cfgPath = $dbCfgFile; $need = @('apiUrl', 'token') }
    if (-not (Test-Path -LiteralPath $cfgPath)) { return 'none' }
    $cfg = Read-JsonObj $cfgPath
    if ($null -eq $cfg) { return 'ok' }
    foreach ($k in $need) { if ([string]::IsNullOrWhiteSpace([string]$cfg.$k)) { return 'incomplete' } }
    return 'ok'
}

# ---------------------------------------------------------------------------------------------
# CSV del dia -> filas (misma logica que la consola de texto)
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
    $lastState = -1
    foreach ($line in ($text -split "`n")) {
        $l = $line.TrimEnd("`r")
        if ($l -notmatch '^\d{4}-\d{2}-\d{2};') { continue }
        $p = $l.Split(';', 6)
        if ($p.Count -lt 6) { continue }
        if ($p[1] -notmatch '^\d{2}:\d{2}:\d{2}$') { continue }
        $sec = $null; $lat = $null
        if ($p[3] -ne '') { $sec = [int]$p[3] }
        if ($p[4] -ne '') { $lat = [int]$p[4] }
        $msg = $p[5]
        $isState = ($p[2] -eq 'OK') -or ($p[2] -eq 'ERROR')
        $incomplete = $isState -and ($null -eq $sec) -and $msg.EndsWith('[INCOMPLETO]')
        [void]$rows.Add(@{ T = $p[1]; Ty = $p[2]; S = $sec; L = $lat; M = $msg; F = $(if ($incomplete) { 'i' } else { '' }) })
        if ($isState) { $lastState = $rows.Count - 1 }
    }
    # La ultima fila de estado sin cerrar y sin marca es el estado en curso; otras filas en blanco quedan incompletas
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        if ((($r.Ty -eq 'OK') -or ($r.Ty -eq 'ERROR')) -and ($null -eq $r.S) -and ($r.F -ne 'i')) {
            if ($i -eq $lastState) { $r.F = 'o' } else { $r.F = 'i' }
        }
    }
    $arr = $rows.ToArray()
    $cache[$file] = @{ Sig = $sig; Rows = $arr }
    return $arr
}

# ---------------------------------------------------------------------------------------------
# Respuestas
# ---------------------------------------------------------------------------------------------
function Send-Bytes($ctx, [int]$code, [string]$type, [byte[]]$bytes, [hashtable]$extra) {
    $res = $ctx.Response
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.Headers['Cache-Control'] = 'no-cache'
    $res.Headers['X-Content-Type-Options'] = 'nosniff'
    $res.Headers['Referrer-Policy'] = 'no-referrer'
    $res.Headers['X-Frame-Options'] = 'DENY'
    $res.Headers['Content-Security-Policy'] = "default-src 'none'; connect-src 'self'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    if ($extra) { foreach ($k in $extra.Keys) { $res.Headers[$k] = [string]$extra[$k] } }
    if ($code -ne 304) {
        $res.ContentLength64 = $bytes.Length
        # En HEAD (o cualquier metodo no GET) se responde solo con cabeceras.
        if (($bytes.Length -gt 0) -and ($ctx.Request.HttpMethod -eq 'GET')) { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
    }
}
function Send-Json($ctx, [string]$json, [hashtable]$extra) { Send-Bytes $ctx 200 'application/json; charset=utf-8' $utf8.GetBytes($json) $extra }
function Send-Text($ctx, [int]$code, [string]$msg) { Send-Bytes $ctx $code 'text/plain; charset=utf-8' $utf8.GetBytes($msg) $null }

function Get-EstadoJson {
    $now = Get-Date
    $st = Read-JsonText $statusFile
    $alias = ''
    if ($st) { try { $alias = [string](($st | ConvertFrom-Json).alias) } catch { } }
    if ([string]::IsNullOrWhiteSpace($alias)) {
        $mc = Read-JsonObj $monCfgFile
        if ($mc -and $mc.alias) { $alias = [string]$mc.alias }
    }
    $ftpSt = Read-JsonText $ftpStatusFile
    $dbSt  = Read-JsonText $dbStatusFile
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{"ahora":').Append((ConvertTo-JsonString $now.ToString('yyyy-MM-ddTHH:mm:ss')))
    [void]$sb.Append(',"alias":').Append((ConvertTo-JsonString $alias))
    [void]$sb.Append(',"status":').Append($(if ($st) { $st } else { 'null' }))
    [void]$sb.Append(',"ftp":{"config":').Append((ConvertTo-JsonString (Get-LoaderConfigState 'FTP'))).Append(',"status":').Append($(if ($ftpSt) { $ftpSt } else { 'null' })).Append('}')
    [void]$sb.Append(',"db":{"config":').Append((ConvertTo-JsonString (Get-LoaderConfigState 'DB'))).Append(',"status":').Append($(if ($dbSt) { $dbSt } else { 'null' })).Append('}}')
    return $sb.ToString()
}

function Get-DiasJson {
    $set = @{}
    try {
        foreach ($f in (Get-ChildItem -LiteralPath $logDir -Filter '*.csv' -File -ErrorAction Stop)) {
            if ($f.Name -match ' (\d{4}-\d{2}-\d{2})\.csv$') { $set[$Matches[1]] = $true }
        }
    } catch { }
    $d = @($set.Keys | Sort-Object -Descending | Select-Object -First 400)
    return ('[' + (($d | ForEach-Object { ConvertTo-JsonString $_ }) -join ',') + ']')
}

# Filas de un dia para todos los destinos. Devuelve @{ Json; Sig }; el JSON se reutiliza mientras los CSV no cambien.
$diaCache = @{}
function Get-DiaJson([string]$fecha) {
    $st = Read-JsonObj $statusFile
    if ($null -eq $st) { return @{ Json = ('{"fecha":' + (ConvertTo-JsonString $fecha) + ',"targets":[]}'); Sig = 'sinstatus' } }
    $targets = @($st.targets)
    $files = @()
    $sigParts = New-Object System.Collections.ArrayList
    foreach ($t in $targets) {
        $f = Join-Path $logDir ('{0} {1} {2}.csv' -f $st.computer, (Get-SafeName ([string]$t.address)), $fecha)
        $files += ,@{ Addr = [string]$t.address; File = $f }
        if (Test-Path -LiteralPath $f) { $fi = Get-Item -LiteralPath $f; [void]$sigParts.Add(('{0}:{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length)) } else { [void]$sigParts.Add('-') }
    }
    $sig = ($fecha + '|' + ($sigParts -join ',')).GetHashCode().ToString('x')
    $full = $fecha + '|' + ($sigParts -join ',')
    if ($diaCache.ContainsKey($fecha) -and ($diaCache[$fecha].Full -eq $full)) { return $diaCache[$fecha] }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{"fecha":').Append((ConvertTo-JsonString $fecha)).Append(',"targets":[')
    $firstT = $true
    foreach ($x in $files) {
        if (-not $firstT) { [void]$sb.Append(',') }
        $firstT = $false
        [void]$sb.Append('{"address":').Append((ConvertTo-JsonString $x.Addr)).Append(',"filas":[')
        $firstR = $true
        foreach ($r in (Get-Rows $x.File)) {
            if (-not $firstR) { [void]$sb.Append(',') }
            $firstR = $false
            [void]$sb.Append('[').Append((ConvertTo-JsonString $r.T)).Append(',').Append((ConvertTo-JsonString $r.Ty)).Append(',')
            [void]$sb.Append($(if ($null -ne $r.S) { [string]$r.S } else { 'null' })).Append(',')
            [void]$sb.Append($(if ($null -ne $r.L) { [string]$r.L } else { 'null' })).Append(',')
            [void]$sb.Append((ConvertTo-JsonString $r.M)).Append(',').Append((ConvertTo-JsonString $r.F)).Append(']')
        }
        [void]$sb.Append(']}')
    }
    [void]$sb.Append(']}')
    $entry = @{ Json = $sb.ToString(); Sig = $sig; Full = $full }
    $diaCache[$fecha] = $entry
    return $entry
}

function Invoke-Request($ctx, [int]$port) {
    $req = $ctx.Request
    # Solo se atiende a quien llega por localhost / 127.0.0.1 (defensa contra DNS rebinding) y solo lectura (GET).
    $hostHdr = [string]$req.Headers['Host']
    if ($hostHdr -notmatch '^(localhost|127\.0\.0\.1)(:\d+)?$') { Send-Text $ctx 403 'Acceso denegado.'; return }
    if ($req.HttpMethod -ne 'GET') { Send-Text $ctx 405 'Solo lectura.'; return }
    $path = $req.Url.AbsolutePath
    switch ($path) {
        '/' {
            if (-not (Test-Path -LiteralPath $htmlFile)) { Send-Text $ctx 500 'Falta Consola_Web.html junto a Servidor_Consola.ps1.'; return }
            Send-Bytes $ctx 200 'text/html; charset=utf-8' ([System.IO.File]::ReadAllBytes($htmlFile)) $null
        }
        '/api/ping'   { Send-Json $ctx ('{"app":"mrv1-consola","root":' + (ConvertTo-JsonString $Root) + ',"port":' + $port + '}') $null }
        '/api/estado' { Send-Json $ctx (Get-EstadoJson) $null }
        '/api/dias'   { Send-Json $ctx (Get-DiasJson) $null }
        '/api/dia' {
            $fecha = [string]$req.QueryString['fecha']
            if ($fecha -notmatch '^\d{4}-\d{2}-\d{2}$') { Send-Text $ctx 400 'Fecha invalida (use yyyy-MM-dd).'; return }
            $e = Get-DiaJson $fecha
            $etag = '"' + $e.Sig + '"'
            if ([string]$req.Headers['If-None-Match'] -eq $etag) { Send-Bytes $ctx 304 'application/json' ([byte[]]@()) @{ ETag = $etag }; return }
            Send-Json $ctx $e.Json @{ ETag = $etag }
        }
        '/favicon.ico' { Send-Bytes $ctx 204 'image/x-icon' ([byte[]]@()) $null }
        default { Send-Text $ctx 404 'No encontrado.' }
    }
}

# ---------------------------------------------------------------------------------------------
# Inicio: reutilizar una consola ya abierta o levantar una nueva
# ---------------------------------------------------------------------------------------------
function Open-Browser([string]$url) {
    if ($NoAbrir) { return }
    try { Start-Process -FilePath $url } catch { Write-ServerLog ('No se pudo abrir el navegador: ' + $_.Exception.Message) }
}

function Find-Running {
    for ($p = $Port; $p -lt ($Port + 10); $p++) {
        try {
            $rq = [System.Net.HttpWebRequest]::Create(('http://localhost:{0}/api/ping' -f $p))
            $rq.Timeout = 700; $rq.ReadWriteTimeout = 700
            $rs = $rq.GetResponse()
            try {
                $sr = New-Object System.IO.StreamReader($rs.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $o = $sr.ReadToEnd() | ConvertFrom-Json
            } finally { $rs.Close() }
            if (($o.app -eq 'mrv1-consola') -and ([string]$o.root -ieq $Root)) { return $p }
        } catch { }
    }
    return 0
}

$running = Find-Running
if ($running -gt 0) {
    Open-Browser ('http://localhost:{0}/' -f $running)
    return
}

$listener = $null
$usedPort = 0
for ($p = $Port; $p -lt ($Port + 10); $p++) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add(('http://localhost:{0}/' -f $p))
    try { $l.Start(); $listener = $l; $usedPort = $p; break } catch { try { $l.Close() } catch { } }
}
if ($null -eq $listener) {
    Write-ServerLog ('No se pudo abrir ningun puerto entre {0} y {1}.' -f $Port, ($Port + 9))
    throw ('No se pudo iniciar la consola web (puertos {0}-{1} ocupados o sin permiso).' -f $Port, ($Port + 9))
}
Write-ServerLog ('Consola web iniciada en http://localhost:{0}/ (Root {1})' -f $usedPort, $Root)
Open-Browser ('http://localhost:{0}/' -f $usedPort)

$lastReq = Get-Date
$pending = $null
try {
    while ($true) {
        if ($null -eq $pending) { $pending = $listener.GetContextAsync() }
        if (-not $pending.Wait(1000)) {
            if (((Get-Date) - $lastReq).TotalMinutes -ge $IdleMin) { Write-ServerLog 'Sin consultas: la consola web se cierra.'; break }
            continue
        }
        $ctx = $pending.Result
        $pending = $null
        $lastReq = Get-Date
        try { Invoke-Request $ctx $usedPort }
        catch {
            Write-ServerLog ('Error atendiendo {0}: {1}' -f $ctx.Request.RawUrl, $_.Exception.Message)
            try { Send-Text $ctx 500 'Error interno.' } catch { }
        }
        finally { try { $ctx.Response.Close() } catch { } }
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch { }
}
