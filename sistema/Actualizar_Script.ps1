<#
.SYNOPSIS
    Monitor de Red (MR) - Actualizar_Script.ps1  [v1.12]
.DESCRIPTION
    Actualizacion automatica de los scripts (ver MRV1.11.md seccion 10.7 y backend/IA.md 5.2).
    Componente independiente y de mejor esfuerzo (mismo principio P3 que Sincronizar_Config.ps1):
    un fallo aqui nunca debe afectar al monitor, al FTP ni a la carga a la API.

    Cuando el servidor publica una version mayor que la instalada, este script:
      1. Descarga manifest.json y manifest.sig y VERIFICA la firma RSA-SHA256 con la clave publica
         instalada (config\update_pubkey.xml). Sin clave publica o con firma invalida: no hace nada.
      2. Descarga solo los archivos que cambiaron y comprueba tamano y SHA-256 de cada uno.
      3. Comprueba que todos los .ps1 compilan (no se instala nada que no se pueda ejecutar).
      4. Guarda copia de lo que va a reemplazar (diag\update_backup\) y reemplaza los archivos.
      5. Si cambio Monitor_Red.ps1, reinicia el monitor con parada ordenada y comprueba que vuelve
         a escribir status.json; si no, RESTAURA la copia y lo vuelve a reiniciar (rollback).
      6. Escribe config\version.json, informa la version al servidor (POST confirmar) y deja el
         resultado en diag\update_state.json y diag\update.log.

    NUNCA toca config\*.json (salvo version.json), credenciales, alias, CSV ni estados.
    Solo acepta archivos de una lista fija de nombres/extensiones y solo por HTTPS (o localhost).

    Se invoca, en un proceso aparte y oculto: en cada INICIO del monitor (arranque y cambio de dia)
    y al terminar cada corrida de Cargador_DB.ps1. Con -Force salta el limite de una consulta cada 30 min.
    Usa la URL y el token de config\db_api.json: una PC sin la API habilitada no se actualiza sola.
#>
param([string]$Root, [switch]$Force)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }

if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root      = [System.IO.Path]::GetFullPath($Root)
$cfgDir    = Join-Path $Root 'config'
$binDir    = Join-Path $Root 'bin'
$diagDir   = Join-Path $Root 'diag'
$stateFile = Join-Path $diagDir 'update_state.json'
$verFile   = Join-Path $cfgDir 'version.json'
$pubFile   = Join-Path $cfgDir 'update_pubkey.xml'
$stopFlag  = Join-Path $Root 'stop.flag'
$bakRoot   = Join-Path $diagDir 'update_backup'
$tmpRoot   = Join-Path $diagDir 'update_tmp'
$pc        = $env:COMPUTERNAME
$utf8      = New-Object System.Text.UTF8Encoding($false)
$MIN_ENTRE_CONSULTAS_MIN = 30
$MAX_ARCHIVOS = 40
$MAX_BYTES    = 5MB
$EXT_OK       = @('.ps1', '.html', '.bat')

function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path -LiteralPath $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
        $f = Join-Path $diagDir 'update.log'
        if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).Length -gt 1MB)) { Move-Item -LiteralPath $f -Destination ($f + '.1') -Force }
        [System.IO.File]::AppendAllText($f, ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) + "`r`n", $utf8)
    } catch { }
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $null }
}

function Write-JsonFile([string]$path, $obj) {
    $tmp = $path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 5), $utf8)
    if (Test-Path -LiteralPath $path) { [System.IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [System.IO.File]::Move($tmp, $path) }
}

function Save-State([string]$resultado, [string]$versionRemota, [string]$detalle) {
    try {
        $local = Get-LocalVersion
        $prevSt = Read-JsonFile $stateFile
        $rep = $null
        if ($prevSt -and $prevSt.reportado) { $rep = $prevSt.reportado }   # lo ultimo informado al servidor se conserva
        Write-JsonFile $stateFile ([ordered]@{
            schemaVersion = 1; ultimaConsulta = (Get-Date).ToString('s'); resultado = $resultado
            versionLocal = $local; versionRemota = $versionRemota; detalle = $detalle; reportado = $rep
        })
    } catch { Write-Log ('No se pudo guardar update_state.json: ' + $_.Exception.Message) }
}

# Anota en update_state.json lo que ya se informo al servidor (version|resultado y dia), para no repetirlo.
function Set-Reportado([string]$version, [string]$resultado) {
    try {
        $s = Read-JsonFile $stateFile
        $o = [ordered]@{ schemaVersion = 1; ultimaConsulta = (Get-Date).ToString('s'); resultado = $resultado; versionLocal = $version; versionRemota = ''; detalle = '' }
        if ($s) { foreach ($k in @('ultimaConsulta', 'resultado', 'versionLocal', 'versionRemota', 'detalle')) { if ($null -ne $s.$k) { $o[$k] = $s.$k } } }
        $o['reportado'] = [ordered]@{ clave = ('{0}|{1}' -f $version, $resultado); fecha = (Get-Date).ToString('yyyy-MM-dd') }
        Write-JsonFile $stateFile $o
    } catch { }
}

function Get-LocalVersion {
    $v = Read-JsonFile $verFile
    if ($v -and $v.version -and ([string]$v.version -match '^\d+(\.\d+){1,3}$')) { return [string]$v.version }
    return '0.0'
}

function Get-FileSha256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($path))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# ---------------------------------------------------------------------------------------------
# Red
# ---------------------------------------------------------------------------------------------
function Get-Bytes([string]$url, [string]$token) {
    $r = Invoke-WebRequest -Uri $url -Method Get -Headers @{ 'X-MR-Token' = $token } -TimeoutSec 30 -UseBasicParsing
    return $r.RawContentStream.ToArray()
}

function Send-Confirm([string]$baseUrl, [string]$token, [string]$version, [bool]$ok, [string]$detalle, [string]$resultado = '') {
    try {
        $body = [ordered]@{ pc = $pc; version = $version; ok = $ok; resultado = $resultado; detalle = $detalle } | ConvertTo-Json -Compress
        Invoke-WebRequest -Uri ($baseUrl + '?accion=confirmar') -Method Post -Headers @{ 'X-MR-Token' = $token } `
            -ContentType 'application/json; charset=utf-8' -Body ($utf8.GetBytes($body)) -TimeoutSec 20 -UseBasicParsing | Out-Null
        Set-Reportado $version $resultado
    } catch { Write-Log ('No se pudo informar la version al servidor: ' + $_.Exception.Message) }
}

# Informa al servidor la version instalada y el resultado de esta corrida, sin repetirse: solo si cambio la
# version o el resultado, o como maximo una vez al dia (asi index.php ve la version aunque nunca haya cambiado).
function Send-ReportIfDue([string]$baseUrl, [string]$token, [string]$resultado, [bool]$ok, [string]$detalle) {
    try {
        $v = Get-LocalVersion
        $s = Read-JsonFile $stateFile
        $clave = '{0}|{1}' -f $v, $resultado
        if ($s -and $s.reportado -and ([string]$s.reportado.clave -eq $clave) -and ([string]$s.reportado.fecha -eq (Get-Date).ToString('yyyy-MM-dd'))) { return }
        Send-Confirm $baseUrl $token $v $ok $detalle $resultado
    } catch { }
}

# ---------------------------------------------------------------------------------------------
# Reinicio del monitor (parada ordenada, igual que Instalar_Monitor.ps1 / Sincronizar_Config.ps1)
# ---------------------------------------------------------------------------------------------
function Restart-Monitor {
    try {
        $task = Get-ScheduledTask -TaskName 'MRV1 Monitor' -ErrorAction SilentlyContinue
        if (-not $task) { Write-Log 'No existe la tarea "MRV1 Monitor"; no se reinicia.'; return $false }
        if ($task.State -eq 'Running') {
            New-Item -ItemType File -Path $stopFlag -Force | Out-Null
            $waited = 0
            while ((($t2 = Get-ScheduledTask -TaskName 'MRV1 Monitor' -ErrorAction SilentlyContinue).State -eq 'Running') -and ($waited -lt 15)) { Start-Sleep -Seconds 1; $waited++ }
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
        return $true
    } catch {
        Write-Log ('No se pudo reiniciar el monitor: ' + $_.Exception.Message)
        return $false
    }
}

# El monitor reescribe status.json cada segundo: si vuelve a hacerlo tras el reinicio, esta sano.
function Test-MonitorSano {
    $sf = Join-Path $Root 'status.json'
    $limite = (Get-Date).AddSeconds(40)
    $desde = Get-Date
    while ((Get-Date) -lt $limite) {
        Start-Sleep -Seconds 2
        try {
            if ((Test-Path -LiteralPath $sf) -and ((Get-Item -LiteralPath $sf).LastWriteTime -gt $desde)) {
                $st = [System.IO.File]::ReadAllText($sf, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($st.running -ne $false) { return $true }
            }
        } catch { }
    }
    return $false
}

function Copy-Atomic([string]$src, [string]$dst) {
    $tmp = $dst + '.new'
    Copy-Item -LiteralPath $src -Destination $tmp -Force
    if (Test-Path -LiteralPath $dst) { [System.IO.File]::Replace($tmp, $dst, [NullString]::Value) } else { [System.IO.File]::Move($tmp, $dst) }
}

function Get-TargetPath([string]$dest, [string]$name) {
    if ($dest -eq 'bin') { return (Join-Path $binDir $name) }
    return (Join-Path $Root $name)
}

# ---------------------------------------------------------------------------------------------
# Principal
# ---------------------------------------------------------------------------------------------
$mutex = $null
$haveMutex = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\MRV1_Actualizar_Script')
    try { $haveMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
    if (-not $haveMutex) { exit 0 }   # ya hay una actualizacion en curso

    # --- Limite de consultas (salvo -Force o una actualizacion pendiente de la corrida anterior)
    $prev = Read-JsonFile $stateFile
    if (-not $Force -and $prev -and $prev.ultimaConsulta -and ($prev.resultado -in @('al_dia', 'sin_cambios', 'sin_clave'))) {
        $last = $null
        try { $last = [datetime]::ParseExact([string]$prev.ultimaConsulta, 's', [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
        if ($last -and (((Get-Date) - $last).TotalMinutes -lt $MIN_ENTRE_CONSULTAS_MIN)) { exit 0 }
    }
    if (-not $Force) { Start-Sleep -Seconds (Get-Random -Minimum 3 -Maximum 20) }   # no coincidir con la sincronizacion de configuracion

    # --- Requisitos
    $db =Read-JsonFile (Join-Path $cfgDir 'db_api.json')
    if ($null -eq $db -or [string]::IsNullOrWhiteSpace([string]$db.apiUrl) -or [string]::IsNullOrWhiteSpace([string]$db.token)) {
        Write-Log 'db_api.json incompleto (falta apiUrl o token); no se puede consultar actualizaciones.'; exit 0
    }
    $token = [string]$db.token
    $baseUrl = $null
    try { $baseUrl = [Uri]::new([Uri]$db.apiUrl, 'actualizar.php').AbsoluteUri } catch { }
    if (-not $baseUrl) { Write-Log ('No se pudo derivar la URL de actualizar.php a partir de "{0}".' -f $db.apiUrl); exit 0 }
    $u = [Uri]$baseUrl
    $esLocal = ($u.Host -eq 'localhost') -or ($u.Host -eq '127.0.0.1')
    if (($u.Scheme -ne 'https') -and -not $esLocal) { Write-Log ('Se rechaza {0}: la actualizacion automatica exige HTTPS.' -f $baseUrl); exit 0 }
    if (-not (Test-Path -LiteralPath $pubFile)) {
        $msg = 'Sin config\update_pubkey.xml: la actualizacion automatica esta deshabilitada en esta PC (reinstale con el paquete 1.12 o superior).'
        Write-Log $msg; Save-State 'sin_clave' '' $msg
        Send-ReportIfDue $baseUrl $token 'sin_clave' $false $msg
        exit 0
    }

    # --- Manifiesto firmado
    $mbytes = $null; $sigTxt = $null
    try {
        $mbytes = Get-Bytes ($baseUrl + '?accion=manifiesto') $token
        $sigTxt = $utf8.GetString((Get-Bytes ($baseUrl + '?accion=firma') $token)).Trim()
    } catch {
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 404) { Save-State 'al_dia' '' 'El servidor no tiene ninguna actualizacion publicada.'; Send-ReportIfDue $baseUrl $token 'al_dia' $true 'Sin actualizacion publicada.' }
        else { Write-Log ('No se pudo consultar el manifiesto: ' + $_.Exception.Message) }
        exit 0
    }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $firmaOk = $false
    try {
        $rsa.FromXmlString([System.IO.File]::ReadAllText($pubFile, $utf8))
        $firmaOk = $rsa.VerifyData($mbytes, 'SHA256', [Convert]::FromBase64String($sigTxt))
    } catch { $firmaOk = $false } finally { $rsa.Dispose() }
    if (-not $firmaOk) {
        Write-Log 'FIRMA INVALIDA del manifiesto: se ignora la actualizacion.'
        Save-State 'firma_invalida' '' 'La firma del manifiesto no es valida; no se aplico nada.'
        Send-ReportIfDue $baseUrl $token 'firma_invalida' $false 'La firma del manifiesto no es valida; no se aplico nada.'
        exit 0
    }

    $m = $utf8.GetString($mbytes) | ConvertFrom-Json
    if ($m.schemaVersion -ne 1 -or ([string]$m.version -notmatch '^\d+(\.\d+){1,3}$')) { Write-Log 'Manifiesto con formato no reconocido.'; exit 0 }
    $remota = [string]$m.version
    $local = Get-LocalVersion
    if ([version]$remota -le [version]$local) { Save-State 'al_dia' $remota 'Sin cambios.'; Send-ReportIfDue $baseUrl $token 'al_dia' $true 'Sin cambios.'; exit 0 }
    # Una version que ya se intento y fue revertida no se reintenta en cada ciclo (solo con -Force o cuando se publique otra mayor).
    if (-not $Force -and $prev -and ($prev.resultado -eq 'revertida') -and ([string]$prev.versionRemota -eq $remota)) { exit 0 }

    # --- Validar la lista de archivos (nombres y destinos permitidos)
    $files = @($m.files)
    if (($files.Count -eq 0) -or ($files.Count -gt $MAX_ARCHIVOS)) { Write-Log 'Manifiesto con lista de archivos invalida.'; exit 0 }
    foreach ($f in $files) {
        $ext = ([System.IO.Path]::GetExtension([string]$f.name)).ToLowerInvariant()
        if (([string]$f.name -notmatch '^[A-Za-z0-9_.-]{1,80}$') -or ($EXT_OK -notcontains $ext) -or (@('bin', 'root') -notcontains [string]$f.dest) `
            -or ([string]$f.sha256 -notmatch '^[0-9a-f]{64}$') -or ([int64]$f.size -le 0) -or ([int64]$f.size -gt $MAX_BYTES)) {
            Write-Log ('Entrada de manifiesto rechazada: {0}' -f $f.name); Save-State 'manifiesto_invalido' $remota ('Entrada rechazada: ' + $f.name); Send-ReportIfDue $baseUrl $token 'manifiesto_invalido' $false ('Entrada rechazada: ' + $f.name); exit 0
        }
    }

    Write-Log ('Actualizacion disponible: {0} -> {1}' -f $local, $remota)

    # --- Descarga y verificacion (solo lo que cambio)
    $stage = Join-Path $tmpRoot $remota
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $cambios = @()
    foreach ($f in $files) {
        $dest = Get-TargetPath ([string]$f.dest) ([string]$f.name)
        if ((Test-Path -LiteralPath $dest) -and ((Get-FileSha256 $dest) -eq [string]$f.sha256)) { continue }
        $tmp = Join-Path $stage ([string]$f.name)
        [System.IO.File]::WriteAllBytes($tmp, (Get-Bytes ('{0}?accion=archivo&nombre={1}' -f $baseUrl, [Uri]::EscapeDataString([string]$f.name)) $token))
        if (((Get-Item -LiteralPath $tmp).Length -ne [int64]$f.size) -or ((Get-FileSha256 $tmp) -ne [string]$f.sha256)) {
            throw ('El archivo descargado {0} no coincide con el manifiesto (tamano/SHA-256).' -f $f.name)
        }
        if ([System.IO.Path]::GetExtension($tmp).ToLowerInvariant() -eq '.ps1') {
            $err = $null; $tok = $null
            [System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tok, [ref]$err) | Out-Null
            if ($err -and $err.Count) { throw ('{0} no compila (linea {1}): {2}' -f $f.name, $err[0].Extent.StartLineNumber, $err[0].Message) }
        }
        $cambios += @{ Name = [string]$f.name; Dest = $dest; Tmp = $tmp }
    }

    # --- Respaldo y reemplazo (Actualizar_Script.ps1, que es este mismo archivo, va al final)
    $bak = Join-Path $bakRoot $local
    if (Test-Path -LiteralPath $bakRoot) { Remove-Item -LiteralPath $bakRoot -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $bak -Force | Out-Null
    $monitorCambio = $false
    $orden = @($cambios | Where-Object { $_.Name -ne 'Actualizar_Script.ps1' }) + @($cambios | Where-Object { $_.Name -eq 'Actualizar_Script.ps1' })
    $aplicados = @()
    try {
        foreach ($c in $orden) {
            if (Test-Path -LiteralPath $c.Dest) { Copy-Item -LiteralPath $c.Dest -Destination (Join-Path $bak $c.Name) -Force }
            $dir = Split-Path -Parent $c.Dest
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Atomic $c.Tmp $c.Dest
            $aplicados += $c
            if ($c.Name -eq 'Monitor_Red.ps1') { $monitorCambio = $true }
        }
    } catch {
        Write-Log ('Fallo al reemplazar archivos ({0}); se restaura la copia.' -f $_.Exception.Message)
        foreach ($c in $aplicados) { $b = Join-Path $bak $c.Name; if (Test-Path -LiteralPath $b) { try { Copy-Atomic $b $c.Dest } catch { } } }
        throw
    }

    # --- Reinicio del monitor y comprobacion; si no vuelve, rollback
    $sano = $true
    if ($monitorCambio) {
        $reinicio = Restart-Monitor
        if ($reinicio) {
            $sano = Test-MonitorSano
            if (-not $sano) {
                Write-Log 'El monitor no volvio a escribir status.json tras la actualizacion: se restaura la version anterior.'
                foreach ($c in $aplicados) { $b = Join-Path $bak $c.Name; if (Test-Path -LiteralPath $b) { try { Copy-Atomic $b $c.Dest } catch { } } }
                [void](Restart-Monitor)
            }
        }
    }
    if (-not $sano) {
        Save-State 'revertida' $remota 'El monitor no arranco con la nueva version; se restauro la anterior.'
        Send-Confirm $baseUrl $token $local $false ('Revertida: la version {0} no arranco.' -f $remota) 'revertida'
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        exit 0
    }

    ([ordered]@{ schemaVersion = 1; version = $remota; actualizadoEn = (Get-Date).ToString('s') } | ConvertTo-Json) | Out-File -LiteralPath $verFile -Encoding utf8 -Force
    Save-State 'actualizada' $remota ('{0} archivo(s) actualizados.' -f $cambios.Count)
    Write-Log ('Actualizacion aplicada: {0} -> {1} ({2} archivo(s)).' -f $local, $remota, $cambios.Count)
    Send-Confirm $baseUrl $token $remota $true ('{0} archivo(s)' -f $cambios.Count) 'actualizada'
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    Write-Log ('Error en la actualizacion automatica: ' + $_.Exception.Message)
    $errMsg = $_.Exception.Message
    try { Save-State 'error' '' $errMsg } catch { }
    try { if ($baseUrl -and $token) { Send-ReportIfDue $baseUrl $token 'error' $false $errMsg } } catch { }
    try { if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
} finally {
    if ($mutex) { try { if ($haveMutex) { $mutex.ReleaseMutex() } } catch { } try { $mutex.Dispose() } catch { } }
}
