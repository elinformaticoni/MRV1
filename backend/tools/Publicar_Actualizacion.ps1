<#
.SYNOPSIS
    Monitor de Red (MR) - Publicar_Actualizacion.ps1  [v1.12]
.DESCRIPTION
    Herramienta del DESARROLLADOR (no se instala en las PC). Prepara la carpeta backend\api\update\
    que luego se sube al servidor junto con actualizar.php:

        update\manifest.json   version + lista de archivos con su SHA-256
        update\manifest.sig    firma RSA-SHA256 (base64) de manifest.json
        update\paquete\        los archivos

    Las PC (Actualizar_Script.ps1) verifican esa firma con la clave PUBLICA que se instala con el
    paquete (config\update_pubkey.xml). La clave PRIVADA nunca se sube ni se guarda en el repositorio:
    por defecto vive en %USERPROFILE%\.mrv1\update_private.xml. Haga respaldo de ella: si se pierde,
    hay que generar un par nuevo y reinstalar a mano las PC (la clave publica de las PC no cambia sola).

    Primera vez:   .\Publicar_Actualizacion.ps1 -NuevaClave      (crea el par y sistema\update_pubkey.xml)
    Cada mejora:   .\Publicar_Actualizacion.ps1                  (usa la version de Instalar_Monitor.ps1)
                   .\Publicar_Actualizacion.ps1 -Version 1.13

    Antes de publicar se comprueba la sintaxis de todos los .ps1; si alguno falla no se publica nada.
#>
param(
    [string]$Version,
    [string]$KeyFile = (Join-Path $env:USERPROFILE '.mrv1\update_private.xml'),
    [string]$OutDir,      # solo para pruebas: carpeta de salida distinta de backend\api\update
    [string]$PubFile,     # solo para pruebas: clave publica distinta de sistema\update_pubkey.xml
    [switch]$NuevaClave,
    [switch]$Forzar
)

$ErrorActionPreference = 'Stop'
$repo    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sistema = Join-Path $repo 'sistema'
$outDir  = if ($OutDir) { $OutDir } else { Join-Path $repo 'backend\api\update' }
$paqDir  = Join-Path $outDir 'paquete'
$pubFile = if ($PubFile) { $PubFile } else { Join-Path $sistema 'update_pubkey.xml' }
$utf8    = New-Object System.Text.UTF8Encoding($false)

# Archivos que viajan en la actualizacion. dest: 'bin' = C:\ProgramData\MRV1\bin ; 'root' = C:\ProgramData\MRV1
$archivos = @(
    @{ n = 'Monitor_Red.ps1';          d = 'bin' },
    @{ n = 'Monitor_Red_Console.ps1';  d = 'bin' },
    @{ n = 'Servidor_Consola.ps1';     d = 'bin' },
    @{ n = 'Consola_Web.html';         d = 'bin' },
    @{ n = 'Cargador_FTP.ps1';         d = 'bin' },
    @{ n = 'Cargador_DB.ps1';          d = 'bin' },
    @{ n = 'Sincronizar_Config.ps1';   d = 'bin' },
    @{ n = 'Actualizar_Script.ps1';    d = 'bin' },
    @{ n = 'Abrir_Consola.bat';        d = 'root' },
    @{ n = 'Instalar_Monitor.bat';     d = 'root' },
    @{ n = 'Instalar_Monitor.ps1';     d = 'root' },
    @{ n = 'Instalar_FTP.bat';         d = 'root' },
    @{ n = 'Instalar_FTP.ps1';         d = 'root' },
    @{ n = 'Instalar_DB.bat';          d = 'root' },
    @{ n = 'Instalar_DB.ps1';          d = 'root' },
    @{ n = 'Desinstalar_Monitor.bat';  d = 'root' },
    @{ n = 'Desinstalar_FTP.bat';      d = 'root' },
    @{ n = 'Desinstalar_DB.bat';       d = 'root' }
)

function Find-Source([string]$name) {
    foreach ($d in @($sistema, $repo)) {
        $p = Join-Path $d $name
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

# ---- Clave
if ($NuevaClave) {
    if ((Test-Path -LiteralPath $KeyFile) -and -not $Forzar) {
        throw ("Ya existe una clave privada en {0}. Si la regenera, las PC ya instaladas dejaran de aceptar actualizaciones hasta reinstalarlas. Use -Forzar para confirmarlo." -f $KeyFile)
    }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(3072)
    try {
        $keyDir = Split-Path -Parent $KeyFile
        if (-not (Test-Path -LiteralPath $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
        [System.IO.File]::WriteAllText($KeyFile, $rsa.ToXmlString($true), $utf8)
        [System.IO.File]::WriteAllText($pubFile, $rsa.ToXmlString($false), $utf8)
    } finally { $rsa.Dispose() }
    Write-Host ('Clave privada creada en: {0}  (HAGA RESPALDO; no la suba a ningun repositorio)' -f $KeyFile) -ForegroundColor Yellow
    Write-Host ('Clave publica creada en: {0}  (viaja con el paquete; el instalador la copia a config\)' -f $pubFile) -ForegroundColor Green
}
if (-not (Test-Path -LiteralPath $KeyFile)) { throw ("No hay clave privada en {0}. Ejecute primero con -NuevaClave." -f $KeyFile) }
if (-not (Test-Path -LiteralPath $pubFile)) { throw ("Falta {0}. Ejecute con -NuevaClave (o copie la clave publica que corresponde a su clave privada)." -f $pubFile) }

# ---- Version
if ([string]::IsNullOrWhiteSpace($Version)) {
    $inst = Get-Content -LiteralPath (Join-Path $sistema 'Instalar_Monitor.ps1') -Raw -Encoding UTF8
    if ($inst -match "version\s*=\s*'(\d+(?:\.\d+){1,3})'") { $Version = $Matches[1] }
    else { throw 'No se pudo leer la version de Instalar_Monitor.ps1; indiquela con -Version.' }
}
if ($Version -notmatch '^\d+(\.\d+){1,3}$') { throw ('Version invalida: {0}' -f $Version) }

# ---- Comprobaciones previas: todo existe y los .ps1 compilan
$lista = @()
foreach ($a in $archivos) {
    $src = Find-Source $a.n
    if (-not $src) { throw ('No se encontro {0} (se busco en sistema\ y en la raiz del repositorio).' -f $a.n) }
    if ($a.n -like '*.ps1') {
        $err = $null; $tok = $null
        [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tok, [ref]$err) | Out-Null
        if ($err -and $err.Count) { throw ('Error de sintaxis en {0} (linea {1}): {2}' -f $a.n, $err[0].Extent.StartLineNumber, $err[0].Message) }
        # Windows PowerShell 5.1 lee como ANSI un .ps1 sin BOM: los acentos saldrian rotos (ConfiguraciÃ³n) en CSV y logs.
        $raw = [System.IO.File]::ReadAllBytes($src)
        $tieneBom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
        if ((-not $tieneBom) -and ($raw | Where-Object { $_ -gt 127 } | Select-Object -First 1)) {
            throw ('{0} tiene caracteres no ASCII pero no esta guardado como UTF-8 con BOM; los acentos se verian mal. Guardelo con BOM.' -f $a.n)
        }
    }
    $lista += @{ n = $a.n; d = $a.d; src = $src }
}

# ---- Paquete
if (Test-Path -LiteralPath $paqDir) { Remove-Item -LiteralPath $paqDir -Recurse -Force }
New-Item -ItemType Directory -Path $paqDir -Force | Out-Null
$sha = [System.Security.Cryptography.SHA256]::Create()
$files = @()
foreach ($x in $lista) {
    $dst = Join-Path $paqDir $x.n
    Copy-Item -LiteralPath $x.src -Destination $dst -Force
    $bytes = [System.IO.File]::ReadAllBytes($dst)
    $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    $files += [ordered]@{ name = $x.n; dest = $x.d; sha256 = $hash; size = $bytes.Length }
}
$manifest = [ordered]@{
    schemaVersion = 1
    version       = $Version
    generado      = (Get-Date).ToString('s')
    files         = $files
}
$mjson = $manifest | ConvertTo-Json -Depth 5
$mbytes = $utf8.GetBytes($mjson)
[System.IO.File]::WriteAllBytes((Join-Path $outDir 'manifest.json'), $mbytes)

# ---- Firma (se verifica con la publica antes de dar el trabajo por bueno)
$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
try {
    $rsa.FromXmlString([System.IO.File]::ReadAllText($KeyFile, $utf8))
    $sig = $rsa.SignData($mbytes, 'SHA256')
} finally { $rsa.Dispose() }
[System.IO.File]::WriteAllText((Join-Path $outDir 'manifest.sig'), [Convert]::ToBase64String($sig), $utf8)

$pub = New-Object System.Security.Cryptography.RSACryptoServiceProvider
try {
    $pub.FromXmlString([System.IO.File]::ReadAllText($pubFile, $utf8))
    if (-not $pub.VerifyData($mbytes, 'SHA256', $sig)) { throw 'La firma no verifica con sistema\update_pubkey.xml: la clave privada y la publica no son un par.' }
} finally { $pub.Dispose() }

Write-Host ''
Write-Host ('Actualizacion {0} preparada: {1} archivos, firma verificada.' -f $Version, $files.Count) -ForegroundColor Green
Write-Host ('Suba al servidor la carpeta: {0}' -f $outDir)
Write-Host '  (junto con actualizar.php, y .htaccess dentro de update\ si todavia no esta). Las PC la aplican solas en su proximo ciclo.'
