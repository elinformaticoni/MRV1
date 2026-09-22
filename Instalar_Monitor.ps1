<#
.SYNOPSIS
    Asistente de instalacion/configuracion del Monitor de Red (MR).
.DESCRIPTION
    Reutilizable: si ya existe config\monitor.json, muestra los valores actuales como
    valores por defecto y permite modificarlos, agregar o quitar destinos. Copia los
    scripts a bin\, crea/actualiza la tarea programada "MRV1 Monitor" y deja el monitor
    en marcha con una parada ordenada antes de reiniciarlo con la nueva configuracion.
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
    targets       = @($targets)
    detection     = [ordered]@{ timeoutMs = $timeoutMs; networkCheckSec = $netSec }
}
($cfgObj | ConvertTo-Json -Depth 5) | Out-File -LiteralPath $monitorCfgPath -Encoding utf8 -Force

$verPath = Join-Path $cfgDir 'version.json'
([ordered]@{ schemaVersion = 1; version = '1.6' } | ConvertTo-Json) | Out-File -LiteralPath $verPath -Encoding utf8 -Force

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
foreach ($f in @('Monitor_Red.ps1', 'Monitor_Red_Console.ps1', 'Cargador_FTP.ps1')) {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $binDir $f) -Force
}

# ---- Copiar tambien los BAT de desinstalacion y el lanzador de la consola a la raiz de $Root,
# para que quede todo lo necesario dentro de C:\ProgramData\MRV1 aunque se borre despues el
# paquete de descarga original (por ejemplo, la carpeta de Descargas).
foreach ($f in @('Desinstalar_Monitor.bat', 'Desinstalar_FTP.bat', 'Abrir_Consola.bat', 'Instalar_Monitor.bat', 'Instalar_Monitor.ps1', 'Instalar_FTP.bat', 'Instalar_FTP.ps1')) {
    $bakSrc = Join-Path $src $f
    if (Test-Path -LiteralPath $bakSrc) { Copy-Item -LiteralPath $bakSrc -Destination (Join-Path $Root $f) -Force }
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
    $ftpScript = Join-Path $src 'Instalar_FTP.ps1'
    if (Test-Path -LiteralPath $ftpScript) {
        Write-Host ''
        & $ftpScript -Root $Root
    } else {
        Write-Host ('No se encontró Instalar_FTP.ps1 junto a este instalador (se esperaba en {0}).' -f $src) -ForegroundColor Yellow
    }
}
Write-Host ''
