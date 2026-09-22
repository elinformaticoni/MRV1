<#
.SYNOPSIS
    Monitor de Red (MR) - Monitor_Red.ps1
.DESCRIPTION
    Unico componente que hace ping (P1). Monitorea uno o mas destinos, registra cambios de
    estado en CSV, detecta cambios de red local y publica el estado instantaneo en status.json.
    Se ejecuta como tarea programada (SYSTEM, inicio de Windows). Ver Monitor_Red_Guia_de_Proyecto.md.
.PARAMETER Root
    Carpeta base (por defecto, la carpeta padre de bin\ : C:\ProgramData\MRV1).
#>
param([string]$Root)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------------------------
# Rutas y constantes
# ---------------------------------------------------------------------------------------------
if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$script:Root       = $Root
$script:CfgDir     = Join-Path $Root 'config'
$script:LogDir     = Join-Path $Root 'logs'
$script:DiagDir    = Join-Path $Root 'diag'
$script:StatusFile = Join-Path $Root 'status.json'
$script:StopFlag   = Join-Path $Root 'stop.flag'
$script:PC         = $env:COMPUTERNAME
$script:CsvHeader  = 'FECHA;HORA;TIPO;TIEMPO (s);LATENCIA (ms);MENSAJE'
$script:Utf8       = New-Object System.Text.UTF8Encoding($false)
$script:GapSec     = 30          # pausa entre ciclos que se considera suspension/pausa
$script:Queue      = New-Object System.Collections.ArrayList
$script:QueueRetryAtMs = 0
$script:LastQueueLogMs = -60000
$script:Clock      = [System.Diagnostics.Stopwatch]::StartNew()
$script:Targets    = @()
$script:User       = '(sin sesión)'
$script:Net        = @{ Adapters = @{}; Active = $null }
$script:LastActive = $null
$script:VersionText = 'MR V1'
$script:ShutdownOk = $false

# ---------------------------------------------------------------------------------------------
# Log tecnico (diag\monitor.log, con rotacion por tamano)
# ---------------------------------------------------------------------------------------------
function Write-DiagLog([string]$msg) {
    try {
        if (-not (Test-Path -LiteralPath $script:DiagDir)) { New-Item -ItemType Directory -Path $script:DiagDir -Force | Out-Null }
        $f = Join-Path $script:DiagDir 'monitor.log'
        if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).Length -gt 1MB)) {
            Move-Item -LiteralPath $f -Destination ($f + '.1') -Force
        }
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
        [System.IO.File]::AppendAllText($f, $line + "`r`n", $script:Utf8)
    } catch { }
}

# ---------------------------------------------------------------------------------------------
# Utilidades de texto y de nombres
# ---------------------------------------------------------------------------------------------
function Clean-Text([string]$s) {
    if ($null -eq $s) { return '' }
    $s = $s -replace '[;,"\r\n]', ' '
    $s = $s -replace '\s+', ' '
    return $s.Trim()
}

function Get-SafeName([string]$s) { return ($s -replace '[\\/:*?"<>|]', '_') }

function Get-CsvPath([string]$addr, [datetime]$day) {
    $n = '{0} {1} {2}.csv' -f $script:PC, (Get-SafeName $addr), $day.ToString('yyyy-MM-dd')
    return (Join-Path $script:LogDir $n)
}

function New-RowLine([datetime]$when, [string]$type, $secs, $lat, [string]$msg) {
    $t = ''; $l = ''
    if ($null -ne $secs) { $t = [string]$secs }
    if ($null -ne $lat)  { $l = [string]$lat }
    return ('{0};{1};{2};{3};{4};{5}' -f $when.ToString('yyyy-MM-dd'), $when.ToString('HH:mm:ss'), $type, $t, $l, (Clean-Text $msg))
}

# ---------------------------------------------------------------------------------------------
# Acceso al CSV: agregar una fila, editar la fila abierta, marcar filas incompletas
# ---------------------------------------------------------------------------------------------
function Add-CsvLine([string]$file, [string]$line) {
    $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    try {
        $prefix = ''
        if ($fs.Length -eq 0) {
            $bom = [byte[]](0xEF, 0xBB, 0xBF)
            $fs.Write($bom, 0, 3)
            $hdr = $script:Utf8.GetBytes($script:CsvHeader + "`r`n")
            $fs.Write($hdr, 0, $hdr.Length)
        } else {
            $null = $fs.Seek(-1, [System.IO.SeekOrigin]::End)
            $last = $fs.ReadByte()
            if ($last -ne 10) { $prefix = "`r`n" }
        }
        $null = $fs.Seek(0, [System.IO.SeekOrigin]::End)
        $bytes = $script:Utf8.GetBytes($prefix + $line + "`r`n")
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
    } finally { $fs.Dispose() }
}

function Read-AllText([System.IO.FileStream]$fs) {
    $len = [int]$fs.Length
    $bytes = New-Object byte[] $len
    $read = 0
    while ($read -lt $len) {
        $n = $fs.Read($bytes, $read, $len - $read)
        if ($n -le 0) { break }
        $read += $n
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes, 0, $read)
}

# Reemplaza la ultima fila cuyo inicio coincide con $prefix (fecha;hora;tipo;;;) y reescribe solo desde esa fila.
function Update-CsvRow([string]$file, [string]$prefix, [string]$newLine) {
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    try {
        $text = Read-AllText $fs
        $idx = $text.LastIndexOf("`n" + $prefix, [System.StringComparison]::Ordinal)
        if ($idx -lt 0) { return $false }
        $start = $idx + 1
        $tail = $text.Substring($start)
        $eol = $tail.IndexOf("`n")
        $rest = ''
        if ($eol -ge 0) { $rest = $tail.Substring($eol + 1) }
        $newTail = $newLine + "`r`n" + $rest
        $offset = $script:Utf8.GetByteCount($text.Substring(0, $start))
        $nb = $script:Utf8.GetBytes($newTail)
        $fs.Position = $offset
        $fs.Write($nb, 0, $nb.Length)
        $fs.SetLength($offset + $nb.Length)
        $fs.Flush()
        return $true
    } finally { $fs.Dispose() }
}

# Anade [INCOMPLETO] a las filas OK/ERROR que quedaron sin cerrar (apagado abrupto).
function Set-IncompleteMarks([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return }
    $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    try {
        $text = Read-AllText $fs
        $lines = $text -split "`n"
        $changed = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            $cr = ''
            if ($l.EndsWith("`r")) { $cr = "`r"; $l = $l.Substring(0, $l.Length - 1) }
            if (($l -match '^\d{4}-\d{2}-\d{2};\d{2}:\d{2}:\d{2};(OK|ERROR);;;') -and (-not $l.EndsWith('[INCOMPLETO]'))) {
                $lines[$i] = $l + ' [INCOMPLETO]' + $cr
                $changed = $true
            }
        }
        if ($changed) {
            $nb = $script:Utf8.GetBytes(($lines -join "`n"))
            $fs.Position = 0
            $fs.Write($nb, 0, $nb.Length)
            $fs.SetLength($nb.Length)
            $fs.Flush()
        }
    } finally { $fs.Dispose() }
}

function Get-LatestCsv($t) {
    $pat = '^' + [regex]::Escape($script:PC + ' ' + (Get-SafeName $t.Address) + ' ') + '\d{4}-\d{2}-\d{2}\.csv$'
    $f = Get-ChildItem -LiteralPath $script:LogDir -Filter '*.csv' -File -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -match $pat } | Sort-Object Name | Select-Object -Last 1
    if ($f) { return $f.FullName }
    return $null
}

# ---------------------------------------------------------------------------------------------
# Cola de operaciones sobre CSV (si un archivo esta bloqueado, por ejemplo abierto en Excel,
# las operaciones esperan en memoria y se reintentan; nunca se pierden)
# ---------------------------------------------------------------------------------------------
function Add-Op([hashtable]$op) { [void]$script:Queue.Add($op) }

function Invoke-Queue {
    if ($script:Queue.Count -eq 0) { return }
    if ($script:Clock.ElapsedMilliseconds -lt $script:QueueRetryAtMs) { return }
    $blocked = @{}
    $i = 0
    while ($i -lt $script:Queue.Count) {
        $op = $script:Queue[$i]
        if ($blocked.ContainsKey($op.File)) { $i++; continue }
        try {
            if ($op.Kind -eq 'Append') {
                Add-CsvLine $op.File $op.Line
            } else {
                $ok = Update-CsvRow $op.File $op.Prefix $op.Line
                if (-not $ok) { Write-DiagLog ('No se encontro la fila abierta para cerrarla: {0} [{1}]' -f (Split-Path -Leaf $op.File), $op.Prefix) }
            }
            $script:Queue.RemoveAt($i)
        } catch {
            $blocked[$op.File] = $true
            $script:QueueRetryAtMs = $script:Clock.ElapsedMilliseconds + 2000
            if (($script:Clock.ElapsedMilliseconds - $script:LastQueueLogMs) -gt 60000) {
                $script:LastQueueLogMs = $script:Clock.ElapsedMilliseconds
                Write-DiagLog ('CSV no disponible ({0}); {1} operaciones en espera: {2}' -f (Split-Path -Leaf $op.File), $script:Queue.Count, $_.Exception.Message)
            }
            $i++
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Filas de estado: abrir (al comenzar el estado) y cerrar (completar TIEMPO y LATENCIA)
# ---------------------------------------------------------------------------------------------
function Open-Row($t, [string]$type, [datetime]$when, [string]$msg) {
    if ($when.Date -lt $script:Day) { $when = $script:Day }
    $line = New-RowLine $when $type $null $null $msg
    $prefix = '{0};{1};{2};;;' -f $when.ToString('yyyy-MM-dd'), $when.ToString('HH:mm:ss'), $type
    Add-Op @{ Kind = 'Append'; File = $t.File; Line = $line }
    $t.OpenRow = @{ File = $t.File; Prefix = $prefix; Type = $type; Start = $when; Msg = $msg }
}

function Close-OpenRow($t, [int]$durSec) {
    if ($null -eq $t.OpenRow) { return }
    $r = $t.OpenRow
    $avg = 0
    if (($r.Type -eq 'OK') -and ($t.LatCount -gt 0)) { $avg = [int][math]::Round($t.LatSum / $t.LatCount) }
    if ($durSec -lt 0) { $durSec = 0 }
    $line = New-RowLine $r.Start $r.Type $durSec $avg $r.Msg
    Add-Op @{ Kind = 'Update'; File = $r.File; Prefix = $r.Prefix; Line = $line }
    $t.OpenRow = $null
}

function Add-EventRow([string]$msg) {
    $when = Get-Date
    foreach ($t in $script:Targets) {
        Add-Op @{ Kind = 'Append'; File = $t.File; Line = (New-RowLine $when 'EVENTO' 0 0 $msg) }
    }
    Write-DiagLog ('EVENTO: ' + $msg)
}

# ---------------------------------------------------------------------------------------------
# Mensajes del ping
# ---------------------------------------------------------------------------------------------
function Get-ErrorMessage([string]$code) {
    switch ($code) {
        'TimedOut'                      { return 'Destino no responde [TimedOut]' }
        'DestinationHostUnreachable'    { return 'Host de destino inalcanzable [DestinationHostUnreachable]' }
        'DestinationNetworkUnreachable' { return 'Red de destino inalcanzable [DestinationNetworkUnreachable]' }
        'DestinationUnreachable'        { return 'Destino inalcanzable [DestinationUnreachable]' }
        'TtlExpired'                    { return 'TTL expirado [TtlExpired]' }
        'DNS'                           { return 'No se resuelve el nombre [DNS]' }
        'SendError'                     { return 'Error al enviar el ping [SendError]' }
        default                         { return ('Fallo de ping [{0}]' -f $code) }
    }
}

# ---------------------------------------------------------------------------------------------
# Identificacion: usuario interactivo y adaptador de red activo
# ---------------------------------------------------------------------------------------------
function Get-ActiveUser {
    try {
        $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($u) { return (($u -split '\\')[-1]) }
    } catch { }
    try {
        $p = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
        if ($p) {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
            if ($o.User) { return [string]$o.User }
        }
    } catch { }
    return '(sin sesión)'
}

function Get-WifiSsid {
    try {
        $out = & netsh.exe wlan show interfaces 2>$null
        foreach ($l in $out) {
            if ($l -match '^\s*SSID\s*:\s*(.+?)\s*$') { return $Matches[1] }
        }
    } catch { }
    return $null
}

function Get-AdapterLabel($a) {
    if ($null -eq $a) { return '(sin adaptador)' }
    if (($a.Type -eq 'Wi-Fi') -and $a.Ssid) { return ('{0} {1}' -f $a.Name, $a.Ssid) }
    return [string]$a.Name
}

function Get-IdentText($adapter, [string]$user) {
    $ip = '(sin IP)'
    if ($adapter) { $ip = $adapter.Ip }
    return ('{0} - {1} - {2} - {3} - {4}' -f $script:PC, $user, (Get-AdapterLabel $adapter), $ip, $script:VersionText)
}

# Adaptador activo: el que tiene ruta por defecto (menor metrica); se ignoran los virtuales.
function Get-ActiveAdapter($prev) {
    $virt = 'Hyper-V|vEthernet|VMware|VirtualBox|Virtual|Loopback|Bluetooth|TAP-|Npcap|Miniport|Teredo|ISATAP|Tunnel'
    $cands = @()
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        $nt = $ni.NetworkInterfaceType.ToString()
        if (($nt -eq 'Loopback') -or ($nt -eq 'Tunnel')) { continue }
        if (($ni.Description -match $virt) -or ($ni.Name -match $virt)) { continue }
        $props = $ni.GetIPProperties()
        $gw = $props.GatewayAddresses | Where-Object { ($_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) -and ($_.Address.ToString() -ne '0.0.0.0') } | Select-Object -First 1
        if (-not $gw) { continue }
        $ip = $props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
        if (-not $ip) { continue }
        $type = 'Otro'
        if ($nt -eq 'Wireless80211') { $type = 'Wi-Fi' }
        elseif ($nt -match 'Ethernet') { $type = 'Ethernet' }
        $idx = 0
        try { $idx = [int]$props.GetIPv4Properties().Index } catch { }
        $cands += @{ Name = $ni.Name; Type = $type; Ip = $ip.Address.ToString(); Index = $idx; Status = 'Up'; Ssid = $null; Metric = 0 }
    }
    if ($cands.Count -eq 0) { return $null }
    $best = $cands[0]
    if ($cands.Count -gt 1) {
        try {
            foreach ($c in $cands) {
                $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $c.Index -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
                $m = (Get-NetIPInterface -InterfaceIndex $c.Index -AddressFamily IPv4 -ErrorAction Stop).InterfaceMetric
                $c.Metric = [int]$r.RouteMetric + [int]$m
            }
            $best = ($cands | Sort-Object { $_.Metric } | Select-Object -First 1)
        } catch { $best = $cands[0] }
    }
    if ($best.Type -eq 'Wi-Fi') {
        if ($prev -and ($prev.Name -eq $best.Name) -and ($prev.Ip -eq $best.Ip)) { $best.Ssid = $prev.Ssid }
        else { $best.Ssid = Get-WifiSsid }
    }
    return $best
}

function Get-NetSnapshot($prevActive) {
    $snap = @{ Adapters = @{}; Active = $null }
    try {
        foreach ($a in (Get-NetAdapter -Physical -ErrorAction Stop)) { $snap.Adapters[[string]$a.Name] = [string]$a.Status }
    } catch { }
    try { $snap.Active = Get-ActiveAdapter $prevActive } catch { Write-DiagLog ('Error al leer el adaptador activo: ' + $_.Exception.Message) }
    return $snap
}

function Test-NetworkChanges {
    $old = $script:Net
    $new = Get-NetSnapshot $script:LastActive
    # Estado de cada adaptador fisico
    foreach ($name in @($new.Adapters.Keys)) {
        if (-not $old.Adapters.ContainsKey($name)) { continue }
        $os = $old.Adapters[$name]; $ns = $new.Adapters[$name]
        if ($os -eq $ns) { continue }
        if ($ns -eq 'Disabled')      { Add-EventRow ('Adaptador deshabilitado: ' + $name) }
        elseif ($os -eq 'Disabled')  { Add-EventRow ('Adaptador habilitado: ' + $name) }
        elseif ($ns -eq 'Up')        { Add-EventRow ('Interfaz conectada: ' + $name) }
        elseif ($os -eq 'Up')        { Add-EventRow ('Interfaz desconectada: ' + $name) }
    }
    # Adaptador activo y direccion IP (se compara con el ultimo adaptador activo conocido)
    $na = $new.Active
    if ($na) {
        $la = $script:LastActive
        if ($la) {
            if ($la.Name -ne $na.Name) {
                Add-EventRow ('Cambio de adaptador: {0} -> {1} - {2}' -f (Get-AdapterLabel $la), (Get-AdapterLabel $na), (Get-IdentText $na $script:User))
            } elseif ($la.Ip -ne $na.Ip) {
                Add-EventRow ('Cambio de dirección IP: {0} -> {1}' -f $la.Ip, $na.Ip)
            }
        }
        $script:LastActive = $na
    }
    $script:Net = $new
}

function Test-UserChange {
    $u = Get-ActiveUser
    if ($u -ne $script:User) {
        Add-EventRow ('Cambio de usuario: {0} -> {1}' -f $script:User, $u)
        $script:User = $u
    }
}

# ---------------------------------------------------------------------------------------------
# status.json (estado instantaneo; escritura atomica)
# ---------------------------------------------------------------------------------------------
function Write-Status([bool]$running) {
    try {
        $tl = @()
        foreach ($t in $script:Targets) {
            $st = 'INICIANDO'; $dur = $null; $since = $null; $lastResp = $null
            if ($null -ne $t.Status) {
                $st = $t.Status
                $dur = [int][math]::Round(($script:Clock.ElapsedMilliseconds - $t.StateStartMs) / 1000)
                $since = $t.StateStartWall.ToString('s')
            }
            if ($null -ne $t.LastResponse) { $lastResp = $t.LastResponse.ToString('s') }
            $tl += [ordered]@{
                address       = $t.Address
                intervalSec   = [int]($t.IntervalMs / 1000)
                confirmPings  = $t.Confirm
                status        = $st
                stateSince    = $since
                stateDuration = $dur
                latency       = $t.LastLatency
                lastResponse  = $lastResp
                lastMessage   = $t.LastCode
            }
        }
        $ad = $script:Net.Active
        $adObj = [ordered]@{ name = '(sin adaptador)'; type = ''; ssid = $null; ip = ''; status = 'Down' }
        if ($ad) { $adObj = [ordered]@{ name = $ad.Name; type = $ad.Type; ssid = $ad.Ssid; ip = $ad.Ip; status = 'Up' } }
        $obj = [ordered]@{
            schemaVersion = 1
            version       = $script:VersionText
            running       = $running
            computer      = $script:PC
            user          = $script:User
            adapter       = $adObj
            sessionStart  = $script:SessionStart.ToString('s')
            timestamp     = (Get-Date).ToString('s')
            targets       = @($tl)
        }
        $json = $obj | ConvertTo-Json -Depth 6
        $tmp = $script:StatusFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8)
        if (Test-Path -LiteralPath $script:StatusFile) {
            [System.IO.File]::Replace($tmp, $script:StatusFile, [NullString]::Value)
        } else {
            [System.IO.File]::Move($tmp, $script:StatusFile)
        }
    } catch {
        $script:StatusErrors++
        if (($script:StatusErrors % 60) -eq 1) { Write-DiagLog ('No se pudo escribir status.json: ' + $_.Exception.Message) }
    }
}
$script:StatusErrors = 0

# ---------------------------------------------------------------------------------------------
# Deteccion de cambios de estado
# ---------------------------------------------------------------------------------------------
function Complete-Probe($t, [bool]$ok, [string]$code, [double]$lat, [long]$nowMs) {
    $t.Stage = 'idle'
    $t.Task = $null
    $t.LastCode = $code
    if ($ok) { $t.LastResponse = Get-Date; $t.LastLatency = [int]$lat } else { $t.LastLatency = $null }
    $newState = 'ERROR'
    if ($ok) { $newState = 'OK' }

    # Primer resultado de la sesion: abre el estado sin umbral
    if ($null -eq $t.Status) {
        $t.Status = $newState
        $t.StateStartWall = $t.ProbeWall
        $t.StateStartMs = $t.ProbeMs
        $t.LatSum = 0.0; $t.LatCount = 0; $t.DiffCount = 0
        if ($ok) {
            $t.LatSum = $lat; $t.LatCount = 1
            Open-Row $t 'OK' $t.StateStartWall 'Conectividad disponible [Success]'
        } else {
            Open-Row $t 'ERROR' $t.StateStartWall (Get-ErrorMessage $code)
        }
        return
    }

    if ($newState -eq $t.Status) {
        $t.DiffCount = 0
        if ($ok) { $t.LatSum += $lat; $t.LatCount++ }
        return
    }

    # Resultado distinto al estado actual: se confirma tras $t.Confirm pings consecutivos
    if ($t.DiffCount -eq 0) {
        $t.DiffWall = $t.ProbeWall; $t.DiffMs = $t.ProbeMs; $t.DiffCode = $code
        $t.DiffLatSum = 0.0; $t.DiffLatCount = 0
    }
    $t.DiffCount++
    if ($ok) { $t.DiffLatSum += $lat; $t.DiffLatCount++ }
    if ($t.DiffCount -lt $t.Confirm) { return }

    # Cambio confirmado: el nuevo estado comienza en el primer ping que lo origino
    $startWall = $t.DiffWall; $startMs = $t.DiffMs
    if ($startMs -lt $t.StateStartMs) { $startMs = $t.StateStartMs }
    if ($startWall -lt $t.StateStartWall) { $startWall = $t.StateStartWall }
    $durSec = [int][math]::Round(($startMs - $t.StateStartMs) / 1000)
    $oldState = $t.Status
    Close-OpenRow $t $durSec
    $t.Status = $newState
    $t.StateStartWall = $startWall
    $t.StateStartMs = $startMs
    $t.LatSum = $t.DiffLatSum; $t.LatCount = $t.DiffLatCount
    $t.DiffCount = 0
    if ($newState -eq 'OK') {
        Open-Row $t 'OK' $startWall 'Conectividad restaurada [Success]'
    } else {
        Open-Row $t 'ERROR' $startWall (Get-ErrorMessage $t.DiffCode)
    }
    Write-DiagLog ('{0}: {1} -> {2}' -f $t.Address, $oldState, $newState)
}

function Start-Probe($t, [long]$nowMs) {
    $t.ProbeWall = Get-Date
    $t.ProbeMs = $nowMs
    $t.StageStartMs = $nowMs
    $t.NextDueMs = $t.NextDueMs + $t.IntervalMs
    if ($t.NextDueMs -le $nowMs) { $t.NextDueMs = $nowMs + $t.IntervalMs }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($t.Address, [ref]$ip)) {
        $t.Task = $t.Ping.SendPingAsync($ip, [int]$t.TimeoutMs)
        $t.Stage = 'ping'
    } else {
        $t.Task = [System.Net.Dns]::GetHostAddressesAsync($t.Address)
        $t.Stage = 'dns'
    }
}

function Update-Target($t, [long]$nowMs) {
    if ($t.Stage -eq 'idle') {
        if ($nowMs -ge $t.NextDueMs) { Start-Probe $t $nowMs }
        return
    }
    if ($t.Stage -eq 'dns') {
        if ($t.Task.IsCompleted) {
            $addrs = $null
            if ((-not $t.Task.IsFaulted) -and (-not $t.Task.IsCanceled)) { $addrs = $t.Task.Result }
            $ip = $null
            if ($addrs -and ($addrs.Count -gt 0)) {
                foreach ($a in $addrs) {
                    if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $ip = $a; break }
                }
                if ($null -eq $ip) { $ip = $addrs[0] }
            }
            if ($null -eq $ip) { Complete-Probe $t $false 'DNS' 0 $nowMs; return }
            $t.Task = $t.Ping.SendPingAsync($ip, [int]$t.TimeoutMs)
            $t.Stage = 'ping'
            $t.StageStartMs = $nowMs
        } elseif (($nowMs - $t.StageStartMs) -gt ($t.TimeoutMs + 1000)) {
            Complete-Probe $t $false 'DNS' 0 $nowMs
        }
        return
    }
    if ($t.Stage -eq 'ping') {
        if ($t.Task.IsCompleted) {
            if ($t.Task.IsFaulted -or $t.Task.IsCanceled) {
                Complete-Probe $t $false 'SendError' 0 $nowMs
            } else {
                $r = $t.Task.Result
                if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    Complete-Probe $t $true 'Success' ([double]$r.RoundtripTime) $nowMs
                } else {
                    Complete-Probe $t $false $r.Status.ToString() 0 $nowMs
                }
            }
        } elseif (($nowMs - $t.StageStartMs) -gt ($t.TimeoutMs + 3000)) {
            $t.Ping = New-Object System.Net.NetworkInformation.Ping
            Complete-Probe $t $false 'TimedOut' 0 $nowMs
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Cambio de dia, pausas y cierre
# ---------------------------------------------------------------------------------------------
function Add-StartRows([bool]$reopen) {
    $now = Get-Date
    $ident = Get-IdentText $script:Net.Active $script:User
    $nowMs = $script:Clock.ElapsedMilliseconds
    foreach ($t in $script:Targets) {
        Add-Op @{ Kind = 'Append'; File = $t.File; Line = (New-RowLine $now 'INICIO' 0 0 $ident) }
        if ($reopen -and ($null -ne $t.Status)) {
            $t.StateStartWall = $now
            $t.StateStartMs = $nowMs
            $t.LatSum = 0.0; $t.LatCount = 0
            if ($t.Status -eq 'OK') { Open-Row $t 'OK' $now 'Conectividad disponible [Success]' }
            else { Open-Row $t 'ERROR' $now (Get-ErrorMessage $t.LastCode) }
        }
    }
}

function Invoke-Rollover([long]$nowMs) {
    $script:Day = (Get-Date).Date
    foreach ($t in $script:Targets) {
        if ($t.OpenRow) {
            $dur = [int][math]::Round(($nowMs - $t.StateStartMs) / 1000)
            Close-OpenRow $t $dur
        }
        $t.File = Get-CsvPath $t.Address $script:Day
    }
    Add-StartRows $true
    Write-DiagLog 'Cambio de dia: registros cerrados y nuevos archivos iniciados'
}

function Invoke-GapHandling([double]$gapSecs, [long]$lastTickMs, [long]$nowMs) {
    foreach ($t in $script:Targets) {
        if ($t.OpenRow) {
            $dur = [int][math]::Round(($lastTickMs - $t.StateStartMs) / 1000)
            Close-OpenRow $t $dur
        }
        $t.Status = $null
        $t.DiffCount = 0
        $t.Stage = 'idle'
        $t.Task = $null
        $t.NextDueMs = $nowMs
        $t.Ping = New-Object System.Net.NetworkInformation.Ping
    }
    Add-EventRow ('Pausa del monitor o suspensión de Windows: {0} s sin actividad' -f [int][math]::Round($gapSecs))
}

function Close-AllStates([string]$reason) {
    $nowMs = $script:Clock.ElapsedMilliseconds
    foreach ($t in $script:Targets) {
        if ($t.OpenRow) {
            $dur = [int][math]::Round(($nowMs - $t.StateStartMs) / 1000)
            Close-OpenRow $t $dur
        }
    }
    for ($k = 0; ($k -lt 5) -and ($script:Queue.Count -gt 0); $k++) {
        $script:QueueRetryAtMs = 0
        Invoke-Queue
        if ($script:Queue.Count -gt 0) { Start-Sleep -Milliseconds 200 }
    }
    Write-Status $false
    Write-DiagLog ('Monitor detenido (' + $reason + ')')
}

# ---------------------------------------------------------------------------------------------
# Inicio
# ---------------------------------------------------------------------------------------------
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Global\MRV1_Monitor', [ref]$createdNew)
if (-not $createdNew) {
    Write-DiagLog 'Ya hay otra instancia del monitor en ejecucion; esta se cierra.'
    exit 0
}

try {
    foreach ($d in @($script:LogDir, $script:DiagDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    if (Test-Path -LiteralPath $script:StopFlag) { Remove-Item -LiteralPath $script:StopFlag -Force -ErrorAction SilentlyContinue }

    # Configuracion
    $cfgPath = Join-Path $script:CfgDir 'monitor.json'
    $cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $cfg.targets -or @($cfg.targets).Count -eq 0) { throw 'monitor.json no contiene destinos.' }
    $verPath = Join-Path $script:CfgDir 'version.json'
    if (Test-Path -LiteralPath $verPath) {
        try {
            $v = [System.IO.File]::ReadAllText($verPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($v.version) { $script:VersionText = 'MR V' + $v.version }
        } catch { }
    }
    $timeoutCfg = 2000; $netSec = 5
    if ($cfg.detection) {
        if ($cfg.detection.timeoutMs)      { $timeoutCfg = [int]$cfg.detection.timeoutMs }
        if ($cfg.detection.networkCheckSec) { $netSec = [int]$cfg.detection.networkCheckSec }
    }
    if ($netSec -lt 1) { $netSec = 5 }

    $idx = 0
    foreach ($c in @($cfg.targets)) {
        $interval = 5; if ($c.intervalSec)  { $interval = [int]$c.intervalSec }
        $confirm  = 1; if ($c.confirmPings) { $confirm  = [int]$c.confirmPings }
        if ($interval -lt 1) { $interval = 1 }
        if ($confirm -lt 1)  { $confirm = 1 }
        $timeout = [Math]::Min($timeoutCfg, $interval * 1000)
        $script:Targets += @{
            Address = [string]$c.address; IntervalMs = [long]($interval * 1000); Confirm = $confirm; TimeoutMs = [long]$timeout
            Ping = (New-Object System.Net.NetworkInformation.Ping); Stage = 'idle'; Task = $null; StageStartMs = 0
            NextDueMs = [long]($idx * 300); ProbeWall = $null; ProbeMs = 0
            Status = $null; StateStartWall = $null; StateStartMs = 0; LatSum = 0.0; LatCount = 0
            DiffCount = 0; DiffWall = $null; DiffMs = 0; DiffCode = ''; DiffLatSum = 0.0; DiffLatCount = 0
            OpenRow = $null; File = ''; LastResponse = $null; LastLatency = $null; LastCode = ''
        }
        $idx++
    }

    $script:SessionStart = Get-Date
    $script:Day = (Get-Date).Date
    Write-DiagLog ('Monitor iniciado. Destinos: ' + (($script:Targets | ForEach-Object { $_.Address }) -join ', '))

    # Manejo (mejor esfuerzo) del apagado normal de Windows: cierra los estados antes de terminar
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class MRShutdown {
    public delegate bool HandlerRoutine(int ctrlType);
    [DllImport("kernel32.dll")] private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);
    private static HandlerRoutine _h;
    public static volatile bool Requested = false;
    public static volatile bool Done = false;
    public static void Install() { _h = new HandlerRoutine(OnCtrl); SetConsoleCtrlHandler(_h, true); }
    private static bool OnCtrl(int t) {
        if (t == 5) { return true; }                       // cierre de sesion de un usuario: se ignora
        if (t == 0 || t == 1 || t == 2 || t == 6) {        // Ctrl+C, Ctrl+Break, cierre de consola, apagado
            Requested = true;
            for (int i = 0; i < 40 && !Done; i++) { Thread.Sleep(100); }
            return true;
        }
        return false;
    }
}
'@
        [MRShutdown]::Install()
        $script:ShutdownOk = $true
    } catch { Write-DiagLog ('No se pudo instalar el manejador de apagado: ' + $_.Exception.Message) }

    # Identificacion inicial y red
    $script:User = Get-ActiveUser
    $script:Net = Get-NetSnapshot $null
    $script:LastActive = $script:Net.Active

    # Archivos del dia, marcado de filas incompletas de la sesion anterior y filas INICIO
    foreach ($t in $script:Targets) {
        $t.File = Get-CsvPath $t.Address $script:Day
        try {
            $latest = Get-LatestCsv $t
            if ($latest) { Set-IncompleteMarks $latest }
        } catch { Write-DiagLog ('No se pudo marcar filas incompletas: ' + $_.Exception.Message) }
    }
    Add-StartRows $false
    Invoke-Queue
    Write-Status $true

    # -----------------------------------------------------------------------------------------
    # Bucle principal
    # -----------------------------------------------------------------------------------------
    $lastWallUtc = [DateTime]::UtcNow
    $lastTickMs = $script:Clock.ElapsedMilliseconds
    $lastNetMs = $lastTickMs
    $lastUserMs = $lastTickMs
    $lastStatusMs = $lastTickMs
    $reason = ''

    while ($true) {
        try {
            $nowMs = $script:Clock.ElapsedMilliseconds
            $wallUtc = [DateTime]::UtcNow

            if ($script:ShutdownOk -and [MRShutdown]::Requested) { $reason = 'apagado de Windows o cierre del proceso'; break }
            if (Test-Path -LiteralPath $script:StopFlag)         { $reason = 'senal de parada'; break }

            $gap = ($wallUtc - $lastWallUtc).TotalSeconds
            if ($gap -gt $script:GapSec) { Invoke-GapHandling $gap $lastTickMs $nowMs }
            $lastWallUtc = $wallUtc
            $lastTickMs = $nowMs

            if ((Get-Date).Date -ne $script:Day) { Invoke-Rollover $nowMs }

            foreach ($t in $script:Targets) { Update-Target $t $nowMs }

            if (($nowMs - $lastNetMs) -ge ($netSec * 1000)) { $lastNetMs = $nowMs; Test-NetworkChanges }
            if (($nowMs - $lastUserMs) -ge 30000)           { $lastUserMs = $nowMs; Test-UserChange }

            Invoke-Queue

            if (($nowMs - $lastStatusMs) -ge 1000) { $lastStatusMs = $nowMs; Write-Status $true }
        } catch {
            Write-DiagLog ('Error en el ciclo principal: ' + $_.Exception.Message)
            Start-Sleep -Seconds 1
        }
        Start-Sleep -Milliseconds 200
    }

    Close-AllStates $reason
    if ($script:ShutdownOk) { [MRShutdown]::Done = $true }
}
catch {
    Write-DiagLog ('Error fatal: ' + $_.Exception.Message)
    exit 1
}
finally {
    try { $script:Mutex.ReleaseMutex() } catch { }
}
exit 0
