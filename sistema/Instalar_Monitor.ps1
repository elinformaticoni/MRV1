<#
.SYNOPSIS
    Asistente de instalacion/configuracion del Monitor de Red (MR).
.DESCRIPTION
    Reutilizable: si ya existe config\monitor.json, muestra los valores actuales como
    valores por defecto y permite modificarlos, agregar o quitar destinos. Copia los
    scripts a bin\, crea/actualiza la tarea programada "MRV1 Monitor" y deja el monitor
    en marcha con una parada ordenada antes de reiniciarlo con la nueva configuracion.
    Al final ofrece instalar/configurar tambien el Cargador FTP y la carga a la API de
    analisis (Cargador_DB.ps1), cada uno con su propio asistente (Instalar_FTP.ps1 /
    Instalar_DB.ps1).
#>
param([string]$Root = 'C:\ProgramData\MRV1')

$ErrorActionPreference = 'Stop'
Write-Host ''
Write-Host '=== Instalador del Monitor de Red (MR) ===' -ForegroundColor Cyan
Write-Host ''

$cfgDir = Join-Path $Root 'config'
$binDir = Join-Path $Root 'bin'
$logDir = Join-Path $Root 'logs'
foreach ($d in @($Root, $cfgDir, $binDir, $logDir, (Join-Path $logDir 'cargados'), (Join-Path $Root 'diag'))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$monitorCfgPath = Join-Path $cfgDir 'monitor.json'
$existing = $null
if (Test-Path -LiteralPath $monitorCfgPath) {
    try { $existing = Get-Content -LiteralPath $monitorCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
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

function Get-CleanAlias([string]$a) {
    # Sin ; , comillas ni saltos de linea (viaja en JSON y en la API), maximo 60 caracteres.
    $a = ($a -replace '[;,"\r\n\t]', ' ' -replace '\s{2,}', ' ').Trim()
    if ($a.Length -gt 60) { $a = $a.Substring(0, 60).Trim() }
    return $a
}

# ---- Alias de esta PC [v1.9]: se pide una sola vez, aqui, al principio. Queda en config\monitor.json
# y lo usan la consola (encabezado) y la carga a la API de analisis (Cargador_DB.ps1).
# Valor por defecto: el alias ya guardado; si no hay, el que tuviera db_api.json (instalaciones
# anteriores a v1.9, donde solo lo pedia Instalar_DB); si tampoco, el nombre de la PC.
$defAlias = $env:COMPUTERNAME
$dbCfgOld = Join-Path $cfgDir 'db_api.json'
if (Test-Path -LiteralPath $dbCfgOld) {
    try { $dbOld = Get-Content -LiteralPath $dbCfgOld -Raw -Encoding UTF8 | ConvertFrom-Json; if ($dbOld.alias) { $defAlias = [string]$dbOld.alias } } catch { }
}
if ($existing -and $existing.alias) { $defAlias = [string]$existing.alias }
Write-Host 'Alias de esta PC: nombre descriptivo del lugar observado (ej. "Laboratorio 2 - Edificio A").' -ForegroundColor Gray
Write-Host 'Se muestra en la consola y se envia con los registros a la API de analisis.' -ForegroundColor Gray
$alias = ''
while ([string]::IsNullOrWhiteSpace($alias)) {
    $alias = Get-CleanAlias (Read-Default 'Alias de esta PC' $defAlias)
    if ([string]::IsNullOrWhiteSpace($alias)) { Write-Host '  El alias no puede quedar vacio.' -ForegroundColor Yellow }
}
Write-Host ''

# ---- Destinos: si ya hay configuracion, se ofrece conservarla, editarla o empezar de nuevo
$targets = New-Object System.Collections.ArrayList
$existingList = @()
if ($existing -and $existing.targets) { $existingList = @($existing.targets) }

if ($existingList.Count -gt 0) {
    Write-Host 'Configuracion actual de destinos:' -ForegroundColor Cyan
    $i = 0
    foreach ($t in $existingList) {
        $i++
        $cp = 1; if ($t.confirmPings) { $cp = $t.confirmPings }
        Write-Host ('  {0}. {1}  intervalo={2}s  umbral={3}' -f $i, $t.address, $t.intervalSec, $cp)
    }
    Write-Host ''
    $mode = Read-Host 'Que desea hacer? [C]onservar igual / [E]ditar destinos / [N]uevo desde cero (C/E/N, Enter = C)'
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'C' }
    $mode = $mode.Trim().ToUpper().Substring(0,1)
} else {
    $mode = 'N'
}

if ($mode -eq 'C') {
    foreach ($t in $existingList) {
        $cp = 1; if ($t.confirmPings) { $cp = $t.confirmPings }
        [void]$targets.Add(@{ address = [string]$t.address; intervalSec = [int]$t.intervalSec; confirmPings = [int]$cp })
    }
} else {
    if ($mode -eq 'E') {
        foreach ($t in $existingList) {
            Write-Host ''
            Write-Host ('--- Destino: {0} ---' -f $t.address) -ForegroundColor Cyan
            $keep = Read-Host '  Conservar este destino? [S/N] (Enter = S)'
            if ([string]::IsNullOrWhiteSpace($keep)) { $keep = 'S' }
            if ($keep.Trim().ToUpper().StartsWith('N')) { continue }
            $addr = Read-Default '  IP/Dominio' ([string]$t.address)
            $iv = 5; if ($t.intervalSec) { $iv = [int]$t.intervalSec }
            $interval = Read-IntDefault '  Intervalo de ping en segundos' $iv 1 3600
            $cp = 1; if ($t.confirmPings) { $cp = [int]$t.confirmPings }
            $confirm = Read-IntDefault '  Pings consecutivos para confirmar un cambio de estado' $cp 1 10
            [void]$targets.Add(@{ address = $addr; intervalSec = $interval; confirmPings = $confirm })
        }
        Write-Host ''
        $more = Read-Host 'Desea agregar otro destino nuevo? [S/N] (Enter = N)'
        if ([string]::IsNullOrWhiteSpace($more)) { $more = 'N' }
    } else {
        Write-Host ''
        Write-Host 'Destino 1 (obligatorio):' -ForegroundColor Cyan
        $more = 'S'
    }

    while ($more.Trim().ToUpper().StartsWith('S')) {
        while ($true) {
            $addr = (Read-Host '  IP/Dominio a monitorear').Trim()
            if ([string]::IsNullOrWhiteSpace($addr)) { Write-Host '  No puede estar vacio.' -ForegroundColor Yellow; continue }
            $dup = $false
            foreach ($x in $targets) { if ($x.address -ieq $addr) { $dup = $true } }
            if ($dup) { Write-Host '  Ese destino ya fue agregado.' -ForegroundColor Yellow; continue }
            break
        }
        $interval = Read-IntDefault '  Intervalo de ping en segundos' 5 1 3600
        $confirm  = Read-IntDefault '  Pings consecutivos para confirmar un cambio de estado' 1 1 10
        [void]$targets.Add(@{ address = $addr; intervalSec = $interval; confirmPings = $confirm })
        Write-Host ''
        $more = Read-Host '¿Desea agregar otro destino? [S/N] (Enter = N)'
        if ([string]::IsNullOrWhiteSpace($more)) { $more = 'N' }
        if ($more.Trim().ToUpper().StartsWith('S')) { Write-Host ''; Write-Host 'Nuevo destino:' -ForegroundColor Cyan }
    }
}

if ($targets.Count -eq 0) { throw 'Debe configurarse al menos un destino.' }

$timeoutMs = 2000; $netSec = 5
if ($existing -and $existing.detection) {
    if ($existing.detection.timeoutMs)       { $timeoutMs = [int]$existing.detection.timeoutMs }
    if ($existing.detection.networkCheckSec) { $netSec = [int]$existing.detection.networkCheckSec }
}

$cfgObj = [ordered]@{
    schemaVersion = 1
    alias         = $alias
    targets       = @($targets)
    detection     = [ordered]@{ timeoutMs = $timeoutMs; networkCheckSec = $netSec }
}
($cfgObj | ConvertTo-Json -Depth 5) | Out-File -LiteralPath $monitorCfgPath -Encoding utf8 -Force

$verPath = Join-Path $cfgDir 'version.json'
([ordered]@{ schemaVersion = 1; version = '1.9' } | ConvertTo-Json) | Out-File -LiteralPath $verPath -Encoding utf8 -Force

# ---- Parada ordenada (y, si hace falta, forzada) de una instancia previa, antes de copiar los
# scripts nuevos. Todo el bloque va en try/catch: un fallo aqui (por ejemplo, el proceso no responde)
# NUNCA debe impedir que se copien los scripts nuevos y se reinicie la tarea mas abajo, porque eso
# dejaria el monitor viejo corriendo indefinidamente con la configuracion/version anterior.
$stopFlag = Join-Path $Root 'stop.flag'
try {
    $task = Get-ScheduledTask -TaskName 'MRV1 Monitor' -ErrorAction SilentlyContinue
    if ($task -and ($task.State -eq 'Running')) {
        Write-Host ''
        Write-Host 'Deteniendo el monitor en ejecucion de forma ordenada...' -ForegroundColor Cyan
        New-Item -ItemType File -Path $stopFlag -Force | Out-Null
        $waited = 0
        while ((($t2 = Get-ScheduledTask -TaskName 'MRV1 Monitor' -ErrorAction SilentlyContinue).State -eq 'Running') -and ($waited -lt 15)) {
            Start-Sleep -Seconds 1; $waited++
        }
        if ($t2 -and ($t2.State -eq 'Running')) {
            Write-Host 'El monitor no respondio a la parada ordenada en 15s; forzando la detencion...' -ForegroundColor Yellow
            try { Stop-ScheduledTask -TaskName 'MRV1 Monitor' -ErrorAction SilentlyContinue } catch { }
            Start-Sleep -Seconds 1
            # Ultimo recurso: si el proceso powershell.exe que ejecuta el Monitor_Red.ps1 anterior
            # sigue vivo (task ya no aparece "Running" pero el proceso quedo huerfano), se mata
            # directamente, para garantizar que la reinstalacion no deje dos versiones a la vez.
            try {
                Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -and ($_.CommandLine -match [regex]::Escape((Join-Path $binDir 'Monitor_Red.ps1'))) } |
                    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            } catch { }
        }
    }
} catch {
    Write-Host ('Aviso: no se pudo detener limpiamente el monitor anterior ({0}). Se continua con la instalacion.' -f $_.Exception.Message) -ForegroundColor Yellow
} finally {
    Remove-Item -LiteralPath $stopFlag -Force -ErrorAction SilentlyContinue
}

# ---- Copiar scripts (bin\)
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
foreach ($f in @('Monitor_Red.ps1', 'Monitor_Red_Console.ps1', 'Cargador_FTP.ps1', 'Cargador_DB.ps1')) {
    Copy-FromSource $f (Join-Path $binDir $f) -Required
}

# ---- Copiar tambien los BAT de desinstalacion y el lanzador de la consola a la raiz de $Root,
# para que quede todo lo necesario dentro de C:\ProgramData\MRV1 aunque se borre despues el
# paquete de descarga original (por ejemplo, la carpeta de Descargas).
foreach ($f in @('Desinstalar_Monitor.bat', 'Desinstalar_FTP.bat', 'Desinstalar_DB.bat', 'Abrir_Consola.bat', 'Instalar_Monitor.bat', 'Instalar_Monitor.ps1', 'Instalar_FTP.bat', 'Instalar_FTP.ps1', 'Instalar_DB.bat', 'Instalar_DB.ps1')) {
    Copy-FromSource $f (Join-Path $Root $f)
}

# ---- Acceso directo en el escritorio (todos los usuarios) hacia la consola de monitoreo
try {
    $desktopDir = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $lnkPath = Join-Path $desktopDir 'Monitor de Red - Consola.lnk'
    $wshell = New-Object -ComObject WScript.Shell
    $shortcut = $wshell.CreateShortcut($lnkPath)
    $shortcut.TargetPath = Join-Path $Root 'Abrir_Consola.bat'
    $shortcut.WorkingDirectory = $Root
    $shortcut.IconLocation = 'imageres.dll,109'
    $shortcut.Description = 'Abrir la consola de monitoreo del Monitor de Red (MR)'
    $shortcut.Save()
} catch {
    Write-Host ('Aviso: no se pudo crear el acceso directo del escritorio ({0}).' -f $_.Exception.Message) -ForegroundColor Yellow
}

# ---- Tarea programada del monitor
$exe = (Get-Command powershell.exe).Source
$scriptPath = Join-Path $binDir 'Monitor_Red.ps1'
$action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Root "{1}"' -f $scriptPath, $Root)
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'MRV1 Monitor' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host ''
Write-Host 'Iniciando el monitor...' -ForegroundColor Cyan
Start-ScheduledTask -TaskName 'MRV1 Monitor'
Start-Sleep -Seconds 1
$final = Get-ScheduledTask -TaskName 'MRV1 Monitor'
Write-Host ('Estado de la tarea: {0}' -f $final.State) -ForegroundColor Green
Write-Host ''
Write-Host 'Instalacion del monitor completada.' -ForegroundColor Green
Write-Host ''

# ---- La consola de monitoreo se abre automaticamente (ya no se pregunta) y luego se ofrece
# instalar/configurar el FTP a continuacion.
Write-Host 'Abriendo la consola de monitoreo...' -ForegroundColor Cyan
$consoleScript = Join-Path $binDir 'Monitor_Red_Console.ps1'
if (Test-Path -LiteralPath $consoleScript) {
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $consoleScript), '-Root', ('"{0}"' -f $Root)) -WindowStyle Normal
} else {
    Write-Host 'No se encontró Monitor_Red_Console.ps1 en bin\.' -ForegroundColor Yellow
}

Write-Host ''
$installFtp = Read-Host '¿Desea instalar/configurar también el Cargador FTP ahora? [S/N] (Enter = N)'
if ($installFtp -and $installFtp.Trim().ToUpper().StartsWith('S')) {
    $ftpScript = Find-SourceFile 'Instalar_FTP.ps1'
    if ($ftpScript) {
        Write-Host ''
        & $ftpScript -Root $Root
    } else {
        Write-Host ('No se encontró Instalar_FTP.ps1 junto a este instalador (se esperaba en {0}).' -f $src) -ForegroundColor Yellow
    }
}

Write-Host ''
$installDb = Read-Host '¿Desea habilitar también el envío de registros a la API de análisis ahora? [S/N] (Enter = N)'
if ($installDb -and $installDb.Trim().ToUpper().StartsWith('S')) {
    $dbScript = Find-SourceFile 'Instalar_DB.ps1'
    if ($dbScript) {
        Write-Host ''
        & $dbScript -Root $Root
    } else {
        Write-Host ('No se encontró Instalar_DB.ps1 junto a este instalador (se esperaba en {0}).' -f $src) -ForegroundColor Yellow
    }
}
Write-Host ''
