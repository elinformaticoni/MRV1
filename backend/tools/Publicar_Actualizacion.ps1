<#
.SYNOPSIS
    Monitor de Red (MR) - Publicar_Actualizacion.ps1  [v1.13.6]
.DESCRIPTION
    Herramienta del DESARROLLADOR (no se instala en las PC). Publica una version para la actualizacion
    automatica usando GitHub como origen: las PC consultan las ETIQUETAS del repositorio (publico) y,
    si hay una version mayor, descargan los archivos de esa etiqueta. No hace falta subir nada a ningun servidor.

    Que hace:
      1. Comprueba que los archivos de la actualizacion estan commiteados y que los .ps1 compilan y,
         si tienen acentos, llevan BOM.
      2. Lee cada archivo tal como quedo en el commit (HEAD) y genera update\manifest.json (version,
         ruta, SHA-256 y tamano de cada archivo) y update\manifest.sig (firma RSA-SHA256).
      3. Si se le indica (-Publicar, o respondiendo S a la pregunta), commitea el manifiesto, crea la
         etiqueta vX.Y.Z y la sube junto con la rama. Esa etiqueta ES el despliegue: las PC la veran.

    La clave PRIVADA nunca se sube: vive en %USERPROFILE%\.mrv1\update_private.xml (haga respaldo). Las PC
    verifican la firma con la clave PUBLICA instalada en config\update_pubkey.xml, asi que ni siquiera
    quien controle el repositorio puede mandar codigo a las PC sin esa clave.

    Primera vez:   .\Publicar_Actualizacion.ps1 -NuevaClave      (crea el par y sistema\update_pubkey.xml)
    Cada version:  commitear los cambios, subir el numero de version en Instalar_Monitor.ps1 y ejecutar
                   .\Publicar_Actualizacion.ps1                 (pregunta antes de etiquetar y subir)
#>
param(
    [string]$Version,
    [string]$KeyFile = (Join-Path $env:USERPROFILE '.mrv1\update_private.xml'),
    [string]$OutDir,      # solo para pruebas: carpeta de salida distinta de <repo>\update
    [string]$PubFile,     # solo para pruebas: clave publica distinta de sistema\update_pubkey.xml
    [switch]$NuevaClave,
    [switch]$Forzar,
    [switch]$Publicar     # commitea el manifiesto, crea la etiqueta y sube, sin preguntar
)

$ErrorActionPreference = 'Stop'
$esPrueba = [bool]$OutDir   # PowerShell no distingue mayusculas: $outDir (abajo) pisa a $OutDir, por eso se guarda antes
$repo    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sistema = Join-Path $repo 'sistema'
$outDir  = if ($OutDir) { $OutDir } else { Join-Path $repo 'update' }
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

# Ejecuta git y devuelve la salida como TEXTO (lineas) o, con -Bytes, como bytes exactos (sin que PowerShell los toque).
function Invoke-Git([string[]]$GitArgs, [switch]$Bytes, [switch]$AllowFail) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.WorkingDirectory = $repo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.Arguments = (($GitArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $p = [System.Diagnostics.Process]::Start($psi)
    $ms = New-Object System.IO.MemoryStream
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.StandardOutput.BaseStream.CopyTo($ms)
    $p.WaitForExit()
    $err = $errTask.Result
    if ($p.ExitCode -ne 0 -and -not $AllowFail) { throw ('git {0} fallo: {1}' -f ($GitArgs -join ' '), $err.Trim()) }
    if ($Bytes) { return , $ms.ToArray() }
    return $utf8.GetString($ms.ToArray())
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
$tag = 'v' + $Version

# ---- Comprobaciones previas: todo existe, esta commiteado, los .ps1 compilan y los acentos llevan BOM
$lista = @()
foreach ($a in $archivos) {
    $src = Find-Source $a.n
    if (-not $src) { throw ('No se encontro {0} (se busco en sistema\ y en la raiz del repositorio).' -f $a.n) }
    $rel = ($src.Substring($repo.Length).TrimStart('\', '/')) -replace '\\', '/'
    $lista += @{ n = $a.n; d = $a.d; src = $src; rel = $rel }
}
$sucios = (Invoke-Git (@('status', '--porcelain', '--') + @($lista | ForEach-Object { $_.rel })) ).Trim()
if ($sucios) { throw ("Hay cambios sin commitear en archivos de la actualizacion; haga commit primero (la actualizacion se publica desde lo commiteado):`n{0}" -f $sucios) }
$noRastreados = @($lista | Where-Object { (Invoke-Git @('ls-files', '--error-unmatch', '--', $_.rel) -AllowFail).Trim() -eq '' })
if ($noRastreados.Count) { throw ('Estos archivos no estan en git: {0}' -f (($noRastreados | ForEach-Object { $_.rel }) -join ', ')) }

$files = @()
$sha = [System.Security.Cryptography.SHA256]::Create()
function Get-Hex([byte[]]$b) { return ([System.BitConverter]::ToString($sha.ComputeHash($b)) -replace '-', '').ToLowerInvariant() }
foreach ($x in $lista) {
    [byte[]]$blob = Invoke-Git @('cat-file', 'blob', ('HEAD:' + $x.rel)) -Bytes
    if ($x.n -like '*.ps1') {
        $text = $utf8.GetString($blob)
        $err = $null; $tok = $null
        [System.Management.Automation.Language.Parser]::ParseInput($text.TrimStart([char]0xFEFF), [ref]$tok, [ref]$err) | Out-Null
        if ($err -and $err.Count) { throw ('Error de sintaxis en {0} (linea {1}): {2}' -f $x.n, $err[0].Extent.StartLineNumber, $err[0].Message) }
        $tieneBom = ($blob.Length -ge 3 -and $blob[0] -eq 0xEF -and $blob[1] -eq 0xBB -and $blob[2] -eq 0xBF)
        if ((-not $tieneBom) -and ($blob | Where-Object { $_ -gt 127 } | Select-Object -First 1)) {
            throw ('{0} tiene caracteres no ASCII pero no esta guardado como UTF-8 con BOM; los acentos se verian mal. Guardelo con BOM.' -f $x.n)
        }
    }
    # sha256 = bytes exactos del commit (lo que descarga la PC); sha256lf = sin retornos de carro (para comparar con la copia
    # instalada, que en Windows puede tener CRLF).
    $sinCr = New-Object System.Collections.Generic.List[byte]
    foreach ($bt in $blob) { if ($bt -ne 13) { $sinCr.Add($bt) } }
    $files += [ordered]@{ name = $x.n; dest = $x.d; path = $x.rel; sha256 = (Get-Hex $blob); sha256lf = (Get-Hex $sinCr.ToArray()); size = $blob.Length }
}
$commit = (Invoke-Git @('rev-parse', 'HEAD')).Trim()
$manifest = [ordered]@{
    schemaVersion = 2
    version       = $Version
    generado      = (Get-Date).ToString('s')
    commit        = $commit
    files         = $files
}
# Saltos de linea LF y sin conversion de git (ver .gitattributes mas abajo): la firma es sobre estos bytes EXACTOS, y con
# core.autocrlf=true git guardaba el manifiesto con LF distinto de lo firmado y las PC lo rechazaban.
$mbytes = $utf8.GetBytes((($manifest | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"))
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
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
Write-Host ('Version {0}: manifiesto de {1} archivos generado desde el commit {2} y firmado (firma verificada).' -f $Version, $files.Count, $commit.Substring(0, 7)) -ForegroundColor Green

# ---- Etiquetar y subir (solo con la carpeta de salida normal; con -OutDir es una prueba)
if ($esPrueba) { Write-Host ('Prueba: salida en {0}; no se etiqueta ni se sube nada.' -f $outDir); return }
if (-not $Publicar) {
    $r = Read-Host ("Crear la etiqueta {0} y subirla a GitHub AHORA (las PC la aplicaran en su proximo ciclo)? [S/N]" -f $tag)
    if ($r -notmatch '^[sS]') {
        Write-Host ('No se publico nada. Para hacerlo mas tarde: git add update; git commit; git tag -a {0} -m "MRV1 {1}"; git push origin main --follow-tags' -f $tag, $Version)
        return
    }
}
if ((Invoke-Git @('tag', '-l', $tag)).Trim()) { throw ('La etiqueta {0} ya existe: suba el numero de version en Instalar_Monitor.ps1 (y commitee) antes de publicar.' -f $tag) }
# El manifiesto y su firma se guardan tal cual (sin normalizar saltos de linea): si no, la firma no verificaria en las PC.
$ga = Join-Path $repo '.gitattributes'
$gaTxt = if (Test-Path -LiteralPath $ga) { [System.IO.File]::ReadAllText($ga) } else { '' }
foreach ($linea in @('update/manifest.json -text', 'update/manifest.sig -text')) {
    if ($gaTxt -notmatch [regex]::Escape($linea)) { $gaTxt = $gaTxt.TrimEnd() + "`n" + $linea + "`n" }
}
[System.IO.File]::WriteAllText($ga, $gaTxt.TrimStart(), $utf8)
Invoke-Git @('add', '--', '.gitattributes', 'update') | Out-Null
$pendiente = (Invoke-Git @('status', '--porcelain', '--', '.gitattributes', 'update')).Trim()
if ($pendiente) { Invoke-Git @('commit', '-q', '-m', ('Publicar actualizacion {0}: manifiesto firmado' -f $Version), '--', '.gitattributes', 'update') | Out-Null }
# Comprobacion antes de etiquetar: lo que quedo en el commit debe ser EXACTAMENTE lo que se firmo.
[byte[]]$enGit = Invoke-Git @('cat-file', 'blob', 'HEAD:update/manifest.json') -Bytes
if ((Get-Hex $enGit) -ne (Get-Hex $mbytes)) { throw 'El manifiesto guardado en git no es identico al que se firmo (conversion de saltos de linea); no se etiqueta ni se sube.' }
Invoke-Git @('tag', '-a', $tag, '-m', ('MRV1 ' + $Version)) | Out-Null
Invoke-Git @('push', 'origin', 'HEAD', $tag) | Out-Null
Write-Host ('Publicada: etiqueta {0} subida a GitHub. Las PC la tomaran en su proximo ciclo (o con "Buscar y actualizar ahora").' -f $tag) -ForegroundColor Green
