<#
.SYNOPSIS
    Monitor de Red (MR) - Cargador_FTP.ps1
.DESCRIPTION
    Componente independiente (P3): un fallo aqui no afecta al monitor.
    - Archivos de dias anteriores en logs\: se suben a la carpeta remota configurada
      (por defecto, el nombre de esta PC), se verifica el tamano y se mueven a logs\cargados\.
    - Archivo del dia en curso: se sube una copia, SOBRESCRIBIENDO al del servidor, y NO se
      mueve (el monitor lo sigue escribiendo). Se ejecuta al iniciar Windows, de inmediato al
      instalar/reinstalar y cada runEveryMin minutos (tarea programada).
    - Al terminar, escribe Root\ftp_status.json (ultima subida, cantidad de archivos, proxima
      hora estimada y error si lo hubo) para que Monitor_Red_Console.ps1 lo muestre, sin que la
      consola necesite hablar con el servidor FTP.
#>
param([string]$Root)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$cfgDir     = Join-Path $Root 'config'
$logDir     = Join-Path $Root 'logs'
$upDir      = Join-Path $logDir 'cargados'
$diagDir    = Join-Path $Root 'diag'
$statusFile = Join-Path $Root 'ftp_status.json'
$pc         = $env:COMPUTERNAME
$utf8       = New-Object System.Text.UTF8Encoding($false)
$script:LastFtpError = $null

function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path -LiteralPath $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
        $f = Join-Path $diagDir 'ftp_worker.log'
        if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).Length -gt 1MB)) {
            Move-Item -LiteralPath $f -Destination ($f + '.1') -Force
        }
        [System.IO.File]::AppendAllText($f, ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) + "`r`n", $utf8)
    } catch { }
}

# [v1.9] Carpeta remota = alias de la PC (config\monitor.json), convertido a un nombre seguro
# para FTP: sin acentos (a/e/i/o/u/n), sin / \ : * ? " < > | # % ; , y sin espacios dobles.
# Si no hay alias se usa el nombre de la PC. Si el alias cambia, la carpeta nueva se crea sola y
# la anterior queda en el servidor con su contenido (no se mueve ni se borra nada).
function Get-FtpFolderName([string]$cfgDirPath) {
    $alias = ''
    try {
        $mp = Join-Path $cfgDirPath 'monitor.json'
        if (Test-Path -LiteralPath $mp) {
            $mc = [System.IO.File]::ReadAllText($mp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($mc.alias) { $alias = [string]$mc.alias }
        }
    } catch { }
    $n = $alias.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $n.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
    }
    $n = ($sb.ToString() -replace '[\\/:*?"<>|#%;,\x00-\x1F]', ' ' -replace '\s{2,}', ' ').Trim().TrimEnd('.').Trim()
    if ([string]::IsNullOrWhiteSpace($n)) { $n = $env:COMPUTERNAME }
    return $n
}

# Escritura atomica de ftp_status.json, para que la consola nunca lea un archivo a medias.
function Write-FtpStatus([bool]$ok, [int]$uploadedOld, [int]$failedOld, [int]$uploadedToday, [int]$failedToday, [int]$runEveryMin, [string]$errorMsg) {
    try {
        $now = Get-Date
        $obj = [ordered]@{
            schemaVersion  = 1
            timestamp      = $now.ToString('s')
            ok             = $ok
            uploadedOld    = $uploadedOld
            failedOld      = $failedOld
            uploadedToday  = $uploadedToday
            failedToday    = $failedToday
            runEveryMin    = $runEveryMin
            nextRun        = $now.AddMinutes($runEveryMin).ToString('s')
            lastError      = $errorMsg
            remoteDir      = $script:RemoteDir
        }
        $json = $obj | ConvertTo-Json -Depth 4
        $tmp = $statusFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        if (Test-Path -LiteralPath $statusFile) { [System.IO.File]::Replace($tmp, $statusFile, [NullString]::Value) }
        else { [System.IO.File]::Move($tmp, $statusFile) }
    } catch { Write-Log ('No se pudo escribir ftp_status.json: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------------------------
# Instancia unica (evita solaparse con la ejecucion anterior si el servidor esta lento)
# ---------------------------------------------------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\MRV1_FTP', [ref]$createdNew)
if (-not $createdNew) { Write-Log 'Ya hay otra ejecucion del cargador FTP en curso; se omite esta.'; exit 0 }

try {
    foreach ($d in @($logDir, $upDir, $diagDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    $cfgPath = Join-Path $cfgDir 'ftp.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { Write-Log 'No existe config\ftp.json; el cargador no puede ejecutarse.'; exit 0 }
    $cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$cfg.host)) { Write-Log 'ftp.json no tiene "host" configurado; sin servidor no se puede subir nada.'; exit 0 }

    $host_ = [string]$cfg.host
    $port  = 21; if ($cfg.port) { $port = [int]$cfg.port }
    $user  = [string]$cfg.user
    $pass  = [string]$cfg.password
    # [v1.9] La carpeta remota ya no se configura: es el alias de la PC (ver Get-FtpFolderName).
    # Un remoteDir que haya quedado en ftp.json de versiones anteriores se ignora.
    $remoteDir = '/' + (Get-FtpFolderName $cfgDir) + '/'
    $script:RemoteDir = $remoteDir
    $retries = 3; if ($cfg.retries) { $retries = [int]$cfg.retries }
    $uploadToday = $true; if ($null -ne $cfg.uploadCurrentDay) { $uploadToday = [bool]$cfg.uploadCurrentDay }
    $runEveryMin = 120; if ($cfg.runEveryMin) { $runEveryMin = [int]$cfg.runEveryMin }

    # ---------------------------------------------------------------------------------------
    # Utilidades FTP (System.Net.FtpWebRequest - FTP plano, sin cifrar, segun D7)
    # ---------------------------------------------------------------------------------------
    function New-FtpUri([string]$remotePath) {
        $p = $remotePath.TrimStart('/')
        return ('ftp://{0}:{1}/{2}' -f $host_, $port, $p)
    }

    function New-FtpRequest([string]$remotePath, [string]$method) {
        $req = [System.Net.FtpWebRequest]::Create((New-FtpUri $remotePath))
        $req.Credentials = New-Object System.Net.NetworkCredential($user, $pass)
        $req.UseBinary = $true
        $req.UsePassive = $true
        $req.KeepAlive = $false
        $req.Method = $method
        $req.Timeout = 30000
        return $req
    }

    # Prueba de conexion real (login + comando), independiente de si hay o no archivos que subir.
    # Sirve para que una primera ejecucion sin archivos pendientes tambien verifique host/usuario/
    # contrasena/puerto, y para no confundir "nada que subir" con "conexion agotada".
    function Test-FtpConnection {
        try {
            $req = New-FtpRequest '/' ([System.Net.WebRequestMethods+Ftp]::PrintWorkingDirectory)
            $resp = $req.GetResponse()
            $resp.Close()
            return @{ Ok = $true; Error = $null }
        } catch [System.Net.WebException] {
            $detail = $_.Exception.Message
            if ($_.Exception.Response) {
                try { $detail = [string]$_.Exception.Response.StatusDescription } catch { }
            }
            return @{ Ok = $false; Error = ('No se pudo conectar al FTP ({0}:{1}): {2}' -f $host_, $port, $detail) }
        } catch {
            return @{ Ok = $false; Error = ('No se pudo conectar al FTP ({0}:{1}): {2}' -f $host_, $port, $_.Exception.Message) }
        }
    }

    function Ensure-RemoteDir([string]$dir) {
        $parts = $dir.Trim('/').Split('/') | Where-Object { $_ -ne '' }
        $cur = ''
        foreach ($p in $parts) {
            $cur = $cur + $p + '/'
            try {
                $req = New-FtpRequest $cur ([System.Net.WebRequestMethods+Ftp]::MakeDirectory)
                $resp = $req.GetResponse(); $resp.Close()
            } catch [System.Net.WebException] {
                # 550 = ya existe u otro problema de permisos; se ignora y se sigue, el intento de subida dira si hay error real
            }
        }
    }

    function Get-RemoteSize([string]$remotePath) {
        try {
            $req = New-FtpRequest $remotePath ([System.Net.WebRequestMethods+Ftp]::GetFileSize)
            $resp = $req.GetResponse()
            $size = $resp.ContentLength
            $resp.Close()
            return [long]$size
        } catch { return -1 }
    }

    function Send-File([string]$localPath, [string]$remotePath) {
        $req = New-FtpRequest $remotePath ([System.Net.WebRequestMethods+Ftp]::UploadFile)
        $bytes = [System.IO.File]::ReadAllBytes($localPath)
        $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream()
        try { $st.Write($bytes, 0, $bytes.Length) } finally { $st.Close() }
        $resp = $req.GetResponse(); $resp.Close()
    }

    function Rename-Remote([string]$fromPath, [string]$toName) {
        $req = New-FtpRequest $fromPath ([System.Net.WebRequestMethods+Ftp]::Rename)
        $req.RenameTo = $toName
        $resp = $req.GetResponse(); $resp.Close()
    }

    function Remove-Remote([string]$remotePath) {
        try {
            $req = New-FtpRequest $remotePath ([System.Net.WebRequestMethods+Ftp]::DeleteFile)
            $resp = $req.GetResponse(); $resp.Close()
        } catch { }
    }

    # Sube con nombre temporal .part y renombra al terminar; verifica tamano remoto contra local.
    function Publish-File([string]$localPath, [string]$remoteDirPath, [string]$remoteName, [switch]$Overwrite) {
        $localLen = (Get-Item -LiteralPath $localPath).Length
        $partName = $remoteName + '.part'
        $partPath = $remoteDirPath + $partName
        $finalPath = $remoteDirPath + $remoteName

        $lastErr = $null
        for ($i = 1; $i -le $retries; $i++) {
            try {
                Send-File $localPath $partPath
                $size = Get-RemoteSize $partPath
                if ($size -ne $localLen) { throw ('Tamano remoto ({0}) distinto al local ({1})' -f $size, $localLen) }
                if ($Overwrite) { Remove-Remote $finalPath }
                Rename-Remote $partPath $remoteName
                return $true
            } catch {
                $lastErr = $_.Exception.Message
                Write-Log ('Intento {0}/{1} fallido para {2}: {3}' -f $i, $retries, $remoteName, $lastErr)
                Start-Sleep -Seconds 2
            }
        }
        Write-Log ('No se pudo subir {0} tras {1} intentos: {2}' -f $remoteName, $retries, $lastErr)
        $script:LastFtpError = ('{0}: {1}' -f $remoteName, $lastErr)
        return $false
    }

    # ---------------------------------------------------------------------------------------
    # Ejecucion
    # ---------------------------------------------------------------------------------------
    # Se prueba la conexion primero, incluso si no hay archivos pendientes: asi una instalacion
    # nueva (todavia sin CSV de dias anteriores) tambien queda verificada de punta a punta, y un
    # host/usuario/contrasena incorrectos se reportan como error real en vez de "nada que hacer".
    $conn = Test-FtpConnection
    if (-not $conn.Ok) {
        Write-Log $conn.Error
        Write-FtpStatus $false 0 0 0 0 $runEveryMin $conn.Error
        Write-Log 'Ciclo cancelado: no fue posible conectar al servidor FTP.'
        return
    }

    try { Ensure-RemoteDir $remoteDir } catch {
        Write-Log ('No se pudo preparar la carpeta remota: ' + $_.Exception.Message)
        $script:LastFtpError = 'No se pudo preparar la carpeta remota (' + $remoteDir + '): ' + $_.Exception.Message
    }

    $today = (Get-Date).ToString('yyyy-MM-dd')
    $allCsv = Get-ChildItem -LiteralPath $logDir -Filter '*.csv' -File -ErrorAction SilentlyContinue

    $moved = 0; $failedOld = 0
    foreach ($f in $allCsv) {
        if ($f.Name -match '(\d{4}-\d{2}-\d{2})\.csv$') {
            $fileDate = $Matches[1]
            if ($fileDate -lt $today) {
                $ok = Publish-File $f.FullName $remoteDir $f.Name
                if ($ok) {
                    $dest = Join-Path $upDir $f.Name
                    try {
                        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
                        Move-Item -LiteralPath $f.FullName -Destination $dest -Force
                        $moved++
                    } catch { Write-Log ('Subido pero no se pudo mover a cargados: ' + $f.Name + ' - ' + $_.Exception.Message) }
                } else { $failedOld++ }
            }
        }
    }

    $sentToday = 0; $failedToday = 0
    if ($uploadToday) {
        $todayCsv = $allCsv | Where-Object { $_.Name -match [regex]::Escape($today + '.csv') + '$' }
        foreach ($f in $todayCsv) {
            $tmp = $null
            try {
                # Copia de lectura compartida para no interferir con el monitor mientras escribe
                $tmp = Join-Path $env:TEMP ('mrv1_' + [Guid]::NewGuid().ToString('N') + '.csv')
                $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $out = [System.IO.File]::Create($tmp)
                try { $fs.CopyTo($out) } finally { $out.Dispose(); $fs.Dispose() }
                $ok = Publish-File $tmp $remoteDir $f.Name -Overwrite
                if ($ok) { $sentToday++ } else { $failedToday++ }
            } catch {
                $failedToday++
                $script:LastFtpError = ('{0}: {1}' -f $f.Name, $_.Exception.Message)
                Write-Log ('No se pudo preparar la copia del dia en curso ({0}): {1}' -f $f.Name, $_.Exception.Message)
            } finally {
                if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    $okOverall = (($failedOld + $failedToday) -eq 0)
    Write-FtpStatus $okOverall $moved $failedOld $sentToday $failedToday $runEveryMin $script:LastFtpError
    Write-Log ('Ciclo terminado (conexion OK). Movidos a cargados: {0} (fallidos: {1}). Dia en curso enviado: {2} (fallidos: {3}).' -f $moved, $failedOld, $sentToday, $failedToday)
}
catch {
    Write-Log ('Error general del cargador FTP: ' + $_.Exception.Message)
    try { Write-FtpStatus $false 0 0 0 0 120 $_.Exception.Message } catch { }
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
}
exit 0
