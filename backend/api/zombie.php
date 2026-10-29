<?php
/**
 * Monitor de Red — Backend de análisis
 * zombie.php — Configuración remota de las PC monitoreadas (MRV1.11).
 *
 * El servidor MANDA y la PC OBEDECE: si existe un archivo config.<pc>.json para una
 * PC, esa PC lo descarga (Sincronizar_Config.ps1), sobrescribe su configuración local
 * y confirma la revisión aplicada. Sin archivo = sin instrucción (la PC no hace nada).
 * Volver a otra configuración = guardar otra instrucción desde este formulario.
 *
 *   GET  zombie.php?accion=config&pc=NOMBRE   → JSON de esa PC (X-MR-Token); 404 si no hay
 *   POST zombie.php?accion=confirmar          → { "pc": "...", "revision": N } (X-MR-Token)
 *   GET  zombie.php                           → formulario de administración (sesión con clave)
 *
 * Las instrucciones viven en api/zombie/config.<pc>.json (carpeta protegida por
 * .htaccess: nunca se sirven directo, así el token siempre controla el acceso).
 * Ver backend/IA.md sección 5.1.
 *
 * La instrucción NUNCA puede traer credenciales FTP, token, URL ni alias: solo
 * destinos, tiempos y frecuencias, dentro de los rangos de MR_Z_LIM.
 */

declare(strict_types=1);

require __DIR__ . '/lib/util.php';
require __DIR__ . '/lib/db.php';

ini_set('display_errors', '0');

const MR_ZOMBIE_DIR   = __DIR__ . '/zombie';
const MR_Z_MAX_DEST   = 8;   // filas de destinos en el formulario
const MR_Z_SECCIONES  = ['targets' => 'Destinos', 'db' => 'API de análisis', 'ftp' => 'FTP'];

/**
 * Rangos permitidos. La frecuencia de la API tiene un máximo de 720 min a propósito:
 * como la PC sobrescribe de verdad su configuración, una frecuencia absurda la dejaría
 * sin volver a consultar al servidor y ya no se podría corregir desde aquí.
 */
const MR_Z_LIM = [
    'intervalSec'     => [1, 3600],
    'confirmPings'    => [1, 10],
    'timeoutMs'       => [500, 10000],
    'networkCheckSec' => [1, 300],
    'dbRunEveryMin'   => [5, 720],
    'ftpRunEveryMin'  => [5, 1440],
    'retries'         => [1, 10],
];

// =====================================================================
// Utilidades de archivo
// =====================================================================

/** Ruta del archivo de una PC, o null si el nombre no es seguro como nombre de archivo. */
function mr_z_ruta(string $pc): ?string
{
    if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/', $pc) || str_contains($pc, '..')) {
        return null;
    }
    return MR_ZOMBIE_DIR . '/config.' . strtolower($pc) . '.json';
}

function mr_z_leer(string $pc): ?array
{
    $ruta = mr_z_ruta($pc);
    if ($ruta === null || !is_file($ruta)) {
        return null;
    }
    $crudo = @file_get_contents($ruta);
    $json  = $crudo === false ? null : json_decode($crudo, true);
    return is_array($json) ? $json : null;
}

/** Escritura atómica: archivo temporal y renombrado, para que nadie lea un JSON a medias. */
function mr_z_guardar(string $pc, array $cfg): void
{
    $ruta = mr_z_ruta($pc);
    if ($ruta === null) {
        throw new RuntimeException("Nombre de PC no válido para archivo: $pc");
    }
    if (!is_dir(MR_ZOMBIE_DIR)) {
        mkdir(MR_ZOMBIE_DIR, 0755, true);
    }
    $htaccess = MR_ZOMBIE_DIR . '/.htaccess';
    if (!is_file($htaccess)) {
        file_put_contents($htaccess, "Require all denied\n");
    }
    $tmp = $ruta . '.' . bin2hex(random_bytes(4)) . '.tmp';
    $json = json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if (file_put_contents($tmp, $json . "\n", LOCK_EX) === false || !rename($tmp, $ruta)) {
        @unlink($tmp);
        throw new RuntimeException("No se pudo escribir la instrucción de $pc.");
    }
}

function mr_z_borrar(string $pc): bool
{
    $ruta = mr_z_ruta($pc);
    return $ruta !== null && is_file($ruta) && @unlink($ruta);
}

// =====================================================================
// API para las PC (token, sin sesión)
// =====================================================================

$accion = (string) ($_GET['accion'] ?? '');
if ($accion === 'config' || $accion === 'confirmar') {
    mr_instalar_manejador_errores();
    mr_validar_token();
    header('Cache-Control: no-store');

    if ($accion === 'config') {
        if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') {
            mr_error(405, 'Método no permitido. Usa GET.');
        }
        $pc   = trim((string) ($_GET['pc'] ?? ''));
        $ruta = mr_z_ruta($pc);
        if ($ruta === null) {
            mr_error(422, 'Parámetro "pc" inválido.');
        }
        $crudo = is_file($ruta) ? file_get_contents($ruta) : false;
        if ($crudo === false || !is_array(json_decode($crudo, true))) {
            mr_error(404, 'Sin instrucción de configuración para esta PC.');
        }
        http_response_code(200);
        header('Content-Type: application/json; charset=utf-8');
        echo $crudo;
        exit;
    }

    // accion === 'confirmar'
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        mr_error(405, 'Método no permitido. Usa POST.');
    }
    $body = mr_leer_cuerpo_json();
    $pc   = trim((string) ($body['pc'] ?? ''));
    $rev  = $body['revision'] ?? null;
    if (mr_z_ruta($pc) === null) {
        mr_error(422, 'Falta "pc" o no es válido.');
    }
    if (!is_int($rev) || $rev < 1) {
        mr_error(422, '"revision" debe ser un entero positivo.');
    }
    try {
        $st = mr_db()->prepare(
            'INSERT INTO computadoras (pc, config_rev_aplicada, config_aplicada_en)
             VALUES (:pc, :rev, NOW())
             ON DUPLICATE KEY UPDATE config_rev_aplicada = VALUES(config_rev_aplicada),
                                     config_aplicada_en  = VALUES(config_aplicada_en)'
        );
        $st->execute(['pc' => $pc, 'rev' => $rev]);
    } catch (Throwable $e) {
        error_log('[MR zombie.php confirmar] ' . $e->getMessage());
        $extra = mr_debug_habilitado() ? ['detalle' => $e->getMessage()] : [];
        mr_error(500, 'Error interno al registrar la confirmación (¿se ejecutó sql/002_config_remota.sql?).', $extra);
    }
    mr_json_response(200, ['ok' => true, 'pc' => $pc, 'revision' => $rev]);
}

if ($accion !== '') {
    mr_instalar_manejador_errores();
    mr_error(400, 'Acción desconocida.');
}

// =====================================================================
// Administración (sesión con la misma clave y cookie que index.php)
// =====================================================================

function h(string $s): string
{
    return htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

header('Cache-Control: no-store');
header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');

$cfg      = mr_config();
$claveRep = (string) ($cfg['reporte']['clave'] ?? '');

if ($claveRep === '') {
    // Esta página cambia la configuración de todas las PC: no se deja abierta.
    http_response_code(403);
    mr_z_pagina('Configuración remota', '<div class="aviso err">Esta página está deshabilitada mientras no exista una clave de acceso. '
        . 'Agregue <code>\'reporte\' =&gt; [\'clave\' =&gt; \'…\']</code> en <code>config/config.php</code> del servidor.</div>', false, true);
    exit;
}

session_name('MRV1REP'); // la misma sesión que index.php: se inicia sesión una sola vez
session_set_cookie_params([
    'httponly' => true,
    'secure'   => !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off',
    'samesite' => 'Lax',
]);
session_start();

$urlBase = strtok($_SERVER['REQUEST_URI'] ?? 'zombie.php', '?');

if (isset($_GET['salir'])) {
    $_SESSION = [];
    session_destroy();
    header('Location: ' . $urlBase);
    exit;
}

$errorLogin = '';
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST' && isset($_POST['clave'])) {
    if (hash_equals($claveRep, (string) $_POST['clave'])) {
        session_regenerate_id(true);
        $_SESSION['mr_rep_ok'] = true;
        header('Location: ' . $urlBase);
        exit;
    }
    usleep(700000); // frena intentos repetidos
    $errorLogin = 'Clave incorrecta.';
}

if (empty($_SESSION['mr_rep_ok'])) {
    mr_z_pagina('Configuración remota', '<form method="post" class="login"><h2>Iniciar sesión</h2>'
        . ($errorLogin !== '' ? '<div class="aviso err" role="alert">' . h($errorLogin) . '</div>' : '')
        . '<label>Clave<input type="password" name="clave" autofocus required autocomplete="current-password"></label>'
        . '<button class="pri" type="submit">Entrar</button></form>', false, true);
    exit;
}

if (empty($_SESSION['mr_z_csrf'])) {
    $_SESSION['mr_z_csrf'] = bin2hex(random_bytes(16));
}
$csrf = (string) $_SESSION['mr_z_csrf'];

// --- Datos: PC registradas ------------------------------------------------
try {
    $pdo = mr_db();
    $falta002 = false;
    try {
        $filas = $pdo->query(
            'SELECT pc, alias, config_rev_aplicada, config_aplicada_en FROM computadoras ORDER BY COALESCE(NULLIF(alias, \'\'), pc), pc'
        )->fetchAll();
    } catch (PDOException $e) {
        if ((int) ($e->errorInfo[1] ?? 0) !== 1054) { // 1054 = columna desconocida (falta el 002)
            throw $e;
        }
        $falta002 = true;
        $filas = $pdo->query('SELECT pc, alias FROM computadoras ORDER BY COALESCE(NULLIF(alias, \'\'), pc), pc')->fetchAll();
    }
} catch (Throwable $e) {
    error_log('[MR zombie.php] ' . $e->getMessage());
    mr_z_pagina('Configuración remota', '<div class="aviso err">No se pudo consultar la base de datos.'
        . (mr_debug_habilitado() ? ' ' . h($e->getMessage()) : '') . '</div>', true);
    exit;
}

$pcsValidas = [];
$porPc = [];
foreach ($filas as $f) {
    $nombre = (string) $f['pc'];
    $porPc[$nombre] = $f;
    if (mr_z_ruta($nombre) !== null) {
        $pcsValidas[] = $nombre;
    }
}

// --- Formulario: valores por defecto, desde archivo o desde POST ----------
function mr_z_destino_vacio(): array
{
    return ['address' => '', 'intervalSec' => '', 'confirmPings' => ''];
}

function mr_z_form_defecto(): array
{
    return [
        'inc'     => ['targets' => true, 'db' => true, 'ftp' => true],
        'targets' => [['address' => '8.8.8.8', 'intervalSec' => '5', 'confirmPings' => '1']],
        'db'      => ['runEveryMin' => '180', 'retries' => '3'],
        'ftp'     => ['runEveryMin' => '120', 'retries' => '3', 'uploadCurrentDay' => true],
    ];
}

function mr_z_form_desde_config(array $c): array
{
    $f = mr_z_form_defecto();
    $f['inc'] = ['targets' => isset($c['targets']), 'db' => isset($c['db']), 'ftp' => isset($c['ftp'])];
    if (isset($c['targets']) && is_array($c['targets'])) {
        $t = [];
        foreach (array_slice($c['targets'], 0, MR_Z_MAX_DEST) as $x) {
            $t[] = ['address' => (string) ($x['address'] ?? ''), 'intervalSec' => (string) ($x['intervalSec'] ?? ''), 'confirmPings' => (string) ($x['confirmPings'] ?? '')];
        }
        if ($t) {
            $f['targets'] = $t;
        }
    }
    foreach (['db' => ['runEveryMin', 'retries'], 'ftp' => ['runEveryMin', 'retries']] as $sec => $claves) {
        foreach ($claves as $k) {
            if (isset($c[$sec][$k])) {
                $f[$sec][$k] = (string) $c[$sec][$k];
            }
        }
    }
    if (isset($c['ftp']['uploadCurrentDay'])) {
        $f['ftp']['uploadCurrentDay'] = (bool) $c['ftp']['uploadCurrentDay'];
    }
    return $f;
}

function mr_z_form_desde_post(array $p): array
{
    $s = fn($k) => trim((string) ($p[$k] ?? ''));
    $inc = is_array($p['inc'] ?? null) ? $p['inc'] : [];
    $f = [
        'inc'     => [],
        'targets' => [],
        'db'      => ['runEveryMin' => $s('db_run'), 'retries' => $s('db_ret')],
        'ftp'     => ['runEveryMin' => $s('ftp_run'), 'retries' => $s('ftp_ret'), 'uploadCurrentDay' => isset($p['ftp_cur'])],
    ];
    foreach (array_keys(MR_Z_SECCIONES) as $sec) {
        $f['inc'][$sec] = isset($inc[$sec]);
    }
    $a = is_array($p['t_addr'] ?? null) ? array_values($p['t_addr']) : [];
    $i = is_array($p['t_int'] ?? null) ? array_values($p['t_int']) : [];
    $c = is_array($p['t_conf'] ?? null) ? array_values($p['t_conf']) : [];
    for ($n = 0; $n < MR_Z_MAX_DEST; $n++) {
        $fila = [
            'address'      => trim((string) ($a[$n] ?? '')),
            'intervalSec'  => trim((string) ($i[$n] ?? '')),
            'confirmPings' => trim((string) ($c[$n] ?? '')),
        ];
        if ($fila['address'] !== '' || $fila['intervalSec'] !== '' || $fila['confirmPings'] !== '') {
            $f['targets'][] = $fila;
        }
    }
    return $f;
}

function mr_z_entero(string $v, array $rango, string $etq, array &$err): ?int
{
    if (!preg_match('/^\d{1,6}$/', $v)) {
        $err[] = "$etq: ingrese un número entero.";
        return null;
    }
    $n = (int) $v;
    if ($n < $rango[0] || $n > $rango[1]) {
        $err[] = "$etq: debe estar entre {$rango[0]} y {$rango[1]}.";
        return null;
    }
    return $n;
}

/** Valida el formulario y arma solo las secciones marcadas. Los errores van a $err. */
function mr_z_construir(array $f, array &$err): array
{
    $sec = [];
    if (!array_filter($f['inc'])) {
        $err[] = 'Marque al menos una sección para enviar.';
        return $sec;
    }

    if ($f['inc']['targets']) {
        $t = [];
        $vistos = [];
        $hayErrorDestino = false;
        foreach ($f['targets'] as $n => $r) {
            $et = 'Destino ' . ($n + 1);
            if ($r['address'] === '') {
                $err[] = "$et: falta la dirección.";
                $hayErrorDestino = true;
                continue;
            }
            if (!preg_match('/^[A-Za-z0-9._:\-]{1,100}$/', $r['address'])) {
                $err[] = "$et: dirección no válida (solo letras, números, punto, guion y dos puntos).";
                $hayErrorDestino = true;
                continue;
            }
            if (isset($vistos[strtolower($r['address'])])) {
                $err[] = "$et: la dirección {$r['address']} está repetida.";
                $hayErrorDestino = true;
                continue;
            }
            $vistos[strtolower($r['address'])] = true;
            $iv = mr_z_entero($r['intervalSec'] === '' ? '5' : $r['intervalSec'], MR_Z_LIM['intervalSec'], "$et, intervalo (s)", $err);
            $cf = mr_z_entero($r['confirmPings'] === '' ? '1' : $r['confirmPings'], MR_Z_LIM['confirmPings'], "$et, pings de confirmación", $err);
            if ($iv !== null && $cf !== null) {
                $t[] = ['address' => $r['address'], 'intervalSec' => $iv, 'confirmPings' => $cf];
            }
        }
        if (!$t && !$hayErrorDestino) {
            $err[] = 'Destinos: indique al menos un destino (o desmarque la sección).';
        }
        $sec['targets'] = $t;
    }
    if ($f['inc']['db']) {
        $a = mr_z_entero($f['db']['runEveryMin'], MR_Z_LIM['dbRunEveryMin'], 'API, frecuencia (min)', $err);
        $b = mr_z_entero($f['db']['retries'], MR_Z_LIM['retries'], 'API, reintentos', $err);
        $sec['db'] = ['runEveryMin' => $a, 'retries' => $b];
    }
    if ($f['inc']['ftp']) {
        $a = mr_z_entero($f['ftp']['runEveryMin'], MR_Z_LIM['ftpRunEveryMin'], 'FTP, frecuencia (min)', $err);
        $b = mr_z_entero($f['ftp']['retries'], MR_Z_LIM['retries'], 'FTP, reintentos', $err);
        $sec['ftp'] = ['runEveryMin' => $a, 'retries' => $b, 'uploadCurrentDay' => (bool) $f['ftp']['uploadCurrentDay']];
    }
    return $sec;
}

/** Guarda la misma instrucción en cada PC de $pcs. Devuelve las PC que se guardaron bien. */
function mr_z_aplicar(array $pcs, array $secciones, array &$errores): array
{
    $hechas = [];
    foreach ($pcs as $pc) {
        try {
            $ant = mr_z_leer($pc);
            // Revisión monótona por PC: aunque se borre y se vuelva a crear el archivo,
            // nunca retrocede (la PC solo aplica si la revisión es mayor a la que ya aplicó).
            $rev = max(time(), (int) ($ant['revision'] ?? 0) + 1);
            mr_z_guardar($pc, array_merge(
                ['schemaVersion' => 1, 'revision' => $rev, 'generadoEn' => date('c', $rev)],
                $secciones
            ));
            $hechas[] = $pc;
        } catch (Throwable $e) {
            error_log('[MR zombie.php guardar] ' . $e->getMessage());
            $errores[] = "No se pudo guardar la instrucción de $pc.";
        }
    }
    return $hechas;
}

/** true si la instrucción guardada ya trae exactamente estas secciones. */
function mr_z_igual_a_guardada(?array $guardada, array $secciones): bool
{
    if ($guardada === null) {
        return false;
    }
    foreach ($secciones as $k => $v) {
        if (json_encode($guardada[$k] ?? null) !== json_encode($v)) {
            return false;
        }
    }
    return true;
}

/** Estado de una PC respecto de su instrucción: [clase, texto]. */
function mr_z_estado(?array $c, array $f, bool $falta002): array
{
    if ($c === null) {
        return ['off', 'Sin instrucción'];
    }
    if ($falta002) {
        return ['pend', 'Guardada'];
    }
    $revSrv = (int) ($c['revision'] ?? 0);
    $revApl = (int) ($f['config_rev_aplicada'] ?? 0);
    return ($revApl >= $revSrv && $revApl > 0) ? ['ok', 'Aplicada'] : ['pend', 'Pendiente'];
}

/** Etiqueta HTML con la versión de scripts que confirmó la PC (o cadena vacía). */
function mr_z_badge_version(?array $v): string
{
    if ($v === null) {
        return '';
    }
    $t = 'Versión de los scripts confirmada por la PC: ' . $v['v'] . ($v['en'] !== '' ? "\n" . $v['en'] : '');
    if ($v['estado'] === 'vieja') {
        $t .= "\nHay una versión más nueva publicada: " . $v['publicada'];
    }
    if ($v['estado'] === 'falla') {
        $t .= "\nLa última actualización falló" . ($v['resultado'] !== '' ? ' (' . $v['resultado'] . ')' : '') . ($v['detalle'] !== '' ? ': ' . $v['detalle'] : '');
    }
    return '<span class="ver ' . h($v['estado']) . '" title="' . h($t) . '">v' . h($v['v']) . '</span>';
}

// --- Acciones del formulario -------------------------------------------------
$mensajes = [];
$errores  = [];
$form     = null;
$flash    = $_SESSION['mr_z_flash'] ?? null;
unset($_SESSION['mr_z_flash']);
if (is_array($flash)) {
    $mensajes = array_map('strval', $flash);
}

$pcSel = trim((string) ($_POST['pc'] ?? $_GET['pc'] ?? ''));
if (!in_array($pcSel, $pcsValidas, true)) {
    $pcSel = '';
}

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST' && !isset($_POST['clave'])) {
    $op = (string) ($_POST['op'] ?? '');
    if (!hash_equals($csrf, (string) ($_POST['csrf'] ?? ''))) {
        $errores[] = 'La sesión del formulario venció. Vuelva a intentarlo.';
        $form = mr_z_form_desde_post($_POST);
    } elseif ($pcSel === '') {
        $errores[] = 'Seleccione primero un equipo de la lista.';
    } elseif ($op === 'quitar') {
        $quitada = mr_z_borrar($pcSel);
        $_SESSION['mr_z_flash'] = [$quitada
            ? "Instrucción retirada de $pcSel. El equipo conserva la última configuración que ya aplicó."
            : "$pcSel no tenía instrucción guardada."];
        header('Location: ' . $urlBase . '?pc=' . rawurlencode($pcSel));
        exit;
    } elseif ($op === 'guardar' || $op === 'copiar') {
        $form = mr_z_form_desde_post($_POST);
        $secciones = mr_z_construir($form, $errores);
        $destinos = [];
        if ($op === 'copiar') {
            $marcadas = is_array($_POST['copiar_a'] ?? null) ? array_map('strval', $_POST['copiar_a']) : [];
            $destinos = array_values(array_diff(array_intersect($pcsValidas, $marcadas), [$pcSel]));
            if (!$destinos) {
                $errores[] = 'Marque al menos un equipo en «Copiar a».';
            }
        }
        if (!$errores) {
            $guardada = mr_z_leer($pcSel);
            $objetivo = $op === 'copiar' ? $destinos : [$pcSel];
            $hechas = mr_z_aplicar($objetivo, $secciones, $errores);
            if ($hechas) {
                $msg = [];
                if ($op === 'copiar') {
                    $msg[] = 'Configuración copiada a ' . count($hechas) . (count($hechas) === 1 ? ' equipo: ' : ' equipos: ') . implode(', ', $hechas) . '. Cada uno la aplicará en su próxima carga a la API (o al reiniciar).';
                    if (!mr_z_igual_a_guardada($guardada, $secciones)) {
                        $msg[] = "La instrucción de $pcSel no se modificó. Use «Guardar» si también quiere aplicarle estos valores.";
                    }
                } else {
                    $msg[] = "Instrucción guardada para $pcSel. Se aplicará en su próxima carga a la API (o al reiniciar).";
                }
                if (!$errores) {
                    $_SESSION['mr_z_flash'] = $msg;
                    header('Location: ' . $urlBase . '?pc=' . rawurlencode($pcSel));
                    exit;
                }
                $mensajes = array_merge($mensajes, $msg);
            }
        }
    }
}

$cSel = $pcSel !== '' ? mr_z_leer($pcSel) : null;
if ($form === null && $pcSel !== '') {
    $form = $cSel !== null ? mr_z_form_desde_config($cSel) : mr_z_form_defecto();
}
$otras = array_values(array_diff($pcsValidas, [$pcSel]));

// --- Vista ---------------------------------------------------------------------
ob_start();
?>
<?php if ($falta002): ?>
<div class="aviso err">Falta ejecutar <code>sql/002_config_remota.sql</code>: sin él no se puede mostrar la confirmación de cada PC.</div>
<?php endif; ?>
<?php foreach ($mensajes as $m): ?><div class="aviso ok" role="status"><?= h($m) ?></div><?php endforeach; ?>
<?php if ($errores): ?><div class="aviso err" role="alert"><ul><?php foreach ($errores as $e): ?><li><?= h($e) ?></li><?php endforeach; ?></ul></div><?php endif; ?>

<div class="app">
<aside class="lista" aria-label="Equipos">
  <div class="lista-cab">
    <input type="search" id="filtro" placeholder="Buscar equipo…" aria-label="Buscar equipo">
    <div class="mut" id="cuenta"><?= count($filas) ?> equipo<?= count($filas) === 1 ? '' : 's' ?></div>
  </div>
  <nav id="pcs">
<?php foreach ($filas as $f):
    $pc = (string) $f['pc'];
    $valida = mr_z_ruta($pc) !== null;
    $c = $valida ? mr_z_leer($pc) : null;
    [$clase, $texto] = mr_z_estado($c, $f, $falta002);
    $alias = (string) ($f['alias'] ?? '');
    ?>
    <?php if ($valida): ?>
    <a class="pc<?= $pc === $pcSel ? ' sel' : '' ?>" href="<?= h($urlBase . '?pc=' . rawurlencode($pc)) ?>" data-buscar="<?= h(strtolower($pc . ' ' . $alias)) ?>"<?= $pc === $pcSel ? ' aria-current="page"' : '' ?>>
    <?php else: ?>
    <span class="pc nula" title="Nombre de PC no válido para archivo" data-buscar="<?= h(strtolower($pc . ' ' . $alias)) ?>">
    <?php endif; ?>
      <span class="pc-nom"><strong><?= h($alias !== '' ? $alias : $pc) ?></strong><?= mr_z_badge_version($valida ? mr_version_pc($pc) : null) ?></span>
      <?php if ($alias !== '' && $alias !== $pc): ?><span class="mono mut"><?= h($pc) ?></span><?php endif; ?>
      <span class="pill <?= h($clase) ?>"><?= h($texto) ?></span>
    <?= $valida ? '</a>' : '</span>' ?>
<?php endforeach; ?>
<?php if (!$filas): ?><p class="mut">Todavía no hay PC registradas (se registran solas al enviar datos a la API).</p><?php endif; ?>
  </nav>
</aside>

<section class="editor" aria-live="polite">
<?php if ($pcSel === ''): ?>
  <div class="vacio">
    <h2>Seleccione un equipo</h2>
    <p class="mut">Al elegirlo se cargan los valores guardados para corregirlos. Después podrá copiar esa misma configuración a otros equipos.</p>
  </div>
<?php else:
    $f = $porPc[$pcSel];
    $alias = (string) ($f['alias'] ?? '');
    [$clase, $texto] = mr_z_estado($cSel, $f, $falta002);
    $revSrv = $cSel !== null ? (int) ($cSel['revision'] ?? 0) : 0;
    $aplEn = (string) ($f['config_aplicada_en'] ?? '');
    $filasDest = $form['targets'];
    if (count($filasDest) < MR_Z_MAX_DEST) {
        $filasDest[] = mr_z_destino_vacio();
    }
    ?>
  <form method="post" id="form" autocomplete="off">
  <input type="hidden" name="csrf" value="<?= h($csrf) ?>">
  <input type="hidden" name="pc" value="<?= h($pcSel) ?>">

  <div class="ed-cab">
    <div>
      <h2><?= h($alias !== '' ? $alias : $pcSel) ?> <?= mr_z_badge_version(mr_version_pc($pcSel)) ?></h2>
      <div class="mut"><?php if ($alias !== '' && $alias !== $pcSel): ?><span class="mono"><?= h($pcSel) ?></span> · <?php endif; ?>
        <?php if ($cSel === null): ?>Sin instrucción guardada: se muestran valores sugeridos.
        <?php else: ?>Instrucción del <?= h(date('Y-m-d H:i', $revSrv)) ?><?php endif; ?></div>
    </div>
    <div class="estado">
      <span class="pill <?= h($clase) ?>"><?= h($texto) ?></span>
      <?php if ($aplEn !== '' && !$falta002): ?><span class="mut">última aplicada: <?= h($aplEn) ?></span><?php endif; ?>
      <span class="sucio" id="sucio" hidden>● Cambios sin guardar</span>
    </div>
  </div>

  <p class="mut">Solo se envían las secciones marcadas; la PC sobrescribe esos campos y deja intactos los demás. Nunca se envían credenciales, token, URL ni alias.</p>

  <fieldset class="sec" data-sec="targets"<?= $form['inc']['targets'] ? '' : ' disabled' ?>>
    <legend><label><input type="checkbox" name="inc[targets]" <?= $form['inc']['targets'] ? 'checked' : '' ?>> Destinos a monitorear</label></legend>
    <div class="dest cab"><span>Dirección (IP o dominio)</span><span>Intervalo (s)</span><span>Confirmar con (pings)</span><span></span></div>
    <div id="dest-filas">
    <?php foreach ($filasDest as $r): ?>
      <div class="dest fila">
        <input name="t_addr[]" value="<?= h($r['address']) ?>" maxlength="100" placeholder="8.8.8.8" aria-label="Dirección">
        <input name="t_int[]" value="<?= h($r['intervalSec']) ?>" inputmode="numeric" placeholder="5" aria-label="Intervalo en segundos">
        <input name="t_conf[]" value="<?= h($r['confirmPings']) ?>" inputmode="numeric" placeholder="1" aria-label="Pings de confirmación">
        <button type="button" class="x" aria-label="Quitar destino" title="Quitar destino">×</button>
      </div>
    <?php endforeach; ?>
    </div>
    <button type="button" id="dest-mas" class="suave">+ Agregar destino</button>
    <p class="mut">Intervalo <?= MR_Z_LIM['intervalSec'][0] ?>–<?= MR_Z_LIM['intervalSec'][1] ?> s · confirmación <?= MR_Z_LIM['confirmPings'][0] ?>–<?= MR_Z_LIM['confirmPings'][1] ?> · hasta <?= MR_Z_MAX_DEST ?> destinos. Los destinos reemplazan a la lista actual de la PC (al aplicarlos, el monitor se reinicia). Las filas vacías se ignoran.</p>
  </fieldset>

  <fieldset class="sec" data-sec="db"<?= $form['inc']['db'] ? '' : ' disabled' ?>>
    <legend><label><input type="checkbox" name="inc[db]" <?= $form['inc']['db'] ? 'checked' : '' ?>> Carga a la API de análisis</label></legend>
    <div class="grid2">
      <label>Frecuencia (min)<input name="db_run" value="<?= h($form['db']['runEveryMin']) ?>" inputmode="numeric"></label>
      <label>Reintentos<input name="db_ret" value="<?= h($form['db']['retries']) ?>" inputmode="numeric"></label>
    </div>
    <p class="mut">Frecuencia <?= MR_Z_LIM['dbRunEveryMin'][0] ?>–<?= MR_Z_LIM['dbRunEveryMin'][1] ?> min (máximo acotado para que la PC siempre vuelva a consultar al servidor) · reintentos <?= MR_Z_LIM['retries'][0] ?>–<?= MR_Z_LIM['retries'][1] ?>.</p>
  </fieldset>

  <fieldset class="sec" data-sec="ftp"<?= $form['inc']['ftp'] ? '' : ' disabled' ?>>
    <legend><label><input type="checkbox" name="inc[ftp]" <?= $form['inc']['ftp'] ? 'checked' : '' ?>> Carga por FTP</label></legend>
    <div class="grid2">
      <label>Frecuencia (min)<input name="ftp_run" value="<?= h($form['ftp']['runEveryMin']) ?>" inputmode="numeric"></label>
      <label>Reintentos<input name="ftp_ret" value="<?= h($form['ftp']['retries']) ?>" inputmode="numeric"></label>
    </div>
    <label class="chk"><input type="checkbox" name="ftp_cur" <?= $form['ftp']['uploadCurrentDay'] ? 'checked' : '' ?>> Subir también el día en curso</label>
    <p class="mut">Frecuencia <?= MR_Z_LIM['ftpRunEveryMin'][0] ?>–<?= MR_Z_LIM['ftpRunEveryMin'][1] ?> min · reintentos <?= MR_Z_LIM['retries'][0] ?>–<?= MR_Z_LIM['retries'][1] ?>.</p>
  </fieldset>

  <div class="acciones">
    <button class="pri" name="op" value="guardar" type="submit">Guardar instrucción</button>
    <?php if ($cSel !== null): ?>
    <button class="pel" name="op" value="quitar" type="submit" onclick="return confirm('¿Retirar la instrucción de este equipo? Conserva la configuración que ya aplicó.');">Quitar instrucción</button>
    <?php endif; ?>
  </div>

  <details class="copiar" id="copiar"<?= $otras ? '' : ' hidden' ?>>
    <summary>COPIAR A…</summary>
    <p class="mut">Copia los valores que ve arriba (aunque no estén guardados) a los equipos que marque. <?= h($alias !== '' ? $alias : $pcSel) ?> no se modifica.</p>
    <div class="lista-cab">
      <input type="search" id="filtro-copia" placeholder="Buscar equipo…" aria-label="Buscar equipo para copiar">
      <button type="button" id="copia-todas" class="suave">Marcar visibles</button>
      <button type="button" id="copia-ninguna" class="suave">Desmarcar</button>
    </div>
    <div class="copia-lista">
    <?php foreach ($otras as $pc):
        $al = (string) ($porPc[$pc]['alias'] ?? ''); ?>
      <label class="copia-item" data-buscar="<?= h(strtolower($pc . ' ' . $al)) ?>">
        <input type="checkbox" name="copiar_a[]" value="<?= h($pc) ?>">
        <span><strong><?= h($al !== '' ? $al : $pc) ?></strong><?php if ($al !== '' && $al !== $pc): ?> <span class="mono mut"><?= h($pc) ?></span><?php endif; ?></span>
      </label>
    <?php endforeach; ?>
    </div>
    <button type="submit" name="op" value="copiar" class="pri" id="copia-ir" disabled>Copiar a los marcados</button>
  </details>
  </form>
<?php endif; ?>
</section>
</div>

<script>
(function () {
  function q(s, r) { return (r || document).querySelector(s); }
  function qa(s, r) { return [].slice.call((r || document).querySelectorAll(s)); }

  // Buscador de equipos (lista lateral)
  var filtro = q('#filtro');
  if (filtro) filtro.addEventListener('input', function () {
    var t = filtro.value.trim().toLowerCase();
    qa('#pcs [data-buscar]').forEach(function (e) { e.style.display = e.getAttribute('data-buscar').indexOf(t) === -1 ? 'none' : ''; });
  });

  var form = q('#form');
  if (!form) return;

  // Cambios sin guardar: aviso en pantalla, al cambiar de equipo y al cerrar la pestaña
  var sucio = false, enviando = false, marca = q('#sucio');
  function ensuciar() { sucio = true; if (marca) marca.hidden = false; }
  form.addEventListener('input', function (e) { if (!e.target.closest('.copiar')) ensuciar(); });
  form.addEventListener('change', function (e) { if (!e.target.closest('.copiar')) ensuciar(); });
  form.addEventListener('submit', function () { enviando = true; });
  window.addEventListener('beforeunload', function (e) { if (sucio && !enviando) { e.preventDefault(); e.returnValue = ''; } });
  qa('#pcs a.pc').forEach(function (a) {
    a.addEventListener('click', function (e) {
      if (sucio && !a.classList.contains('sel') && !confirm('Hay cambios sin guardar. ¿Descartarlos y cambiar de equipo?')) e.preventDefault();
      else enviando = true;
    });
  });

  // Secciones: al desmarcar "enviar" los campos quedan deshabilitados (el checkbox del título sigue activo)
  qa('fieldset.sec').forEach(function (fs) {
    var chk = q('legend input[type=checkbox]', fs);
    if (chk) chk.addEventListener('change', function () { fs.disabled = !chk.checked; });
  });

  // Destinos: agregar y quitar filas
  var cont = q('#dest-filas'), mas = q('#dest-mas'), MAX = <?= (int) MR_Z_MAX_DEST ?>;
  function filas() { return qa('.fila', cont); }
  function actualizarMas() { if (mas) mas.disabled = filas().length >= MAX; }
  function nuevaFila() {
    var base = filas()[0];
    var f = base.cloneNode(true);
    qa('input', f).forEach(function (i) { i.value = ''; });
    cont.appendChild(f);
    return f;
  }
  if (mas) mas.addEventListener('click', function () {
    if (filas().length >= MAX) return;
    var f = nuevaFila(); q('input', f).focus(); ensuciar(); actualizarMas();
  });
  if (cont) cont.addEventListener('click', function (e) {
    var b = e.target.closest('.x'); if (!b) return;
    var f = b.closest('.fila');
    if (filas().length > 1) f.parentNode.removeChild(f); else qa('input', f).forEach(function (i) { i.value = ''; });
    ensuciar(); actualizarMas();
  });
  actualizarMas();

  // COPIAR A…
  var items = qa('.copia-item'), ir = q('#copia-ir'), fc = q('#filtro-copia');
  function marcadas() { return qa('.copia-item input:checked').length; }
  function refrescar() {
    if (!ir) return;
    var n = marcadas();
    ir.disabled = n === 0;
    ir.textContent = n === 0 ? 'Copiar a los marcados' : 'Copiar a ' + n + (n === 1 ? ' equipo' : ' equipos');
  }
  if (fc) fc.addEventListener('input', function () {
    var t = fc.value.trim().toLowerCase();
    items.forEach(function (i) { i.style.display = i.getAttribute('data-buscar').indexOf(t) === -1 ? 'none' : ''; });
  });
  var bt = q('#copia-todas'), bn = q('#copia-ninguna');
  if (bt) bt.addEventListener('click', function () { items.forEach(function (i) { if (i.style.display !== 'none') q('input', i).checked = true; }); refrescar(); });
  if (bn) bn.addEventListener('click', function () { items.forEach(function (i) { q('input', i).checked = false; }); refrescar(); });
  items.forEach(function (i) { q('input', i).addEventListener('change', refrescar); });
  if (ir) ir.addEventListener('click', function (e) {
    if (!confirm('¿Copiar esta configuración a ' + marcadas() + ' equipo(s)? Sustituye la instrucción que tengan guardada.')) e.preventDefault();
  });
  refrescar();
})();
</script>
<?php
mr_z_pagina('Configuración remota', (string) ob_get_clean(), true);

// =====================================================================
// Plantilla de página
// =====================================================================
function mr_z_pagina(string $titulo, string $cuerpo, bool $conSalir = false, bool $angosta = false): void
{
    ?>
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title><?= h($titulo) ?> · MRV1</title>
<style>
:root{--bg:#f4f6f8;--panel:#fff;--tx:#1f2933;--mut:#5f6b7a;--tenue:#8a95a3;--bd:#dde3ea;--grid:#e8edf2;--pri:#0f6cbd;--kore:#dc672b;
  --ok:#15803d;--okbg:rgba(22,163,74,.11);--err:#c62828;--errbg:rgba(220,38,38,.09);--pend:#9a5b00;--pendbg:rgba(217,119,6,.13);--sombra:0 1px 2px rgba(15,23,42,.06),0 6px 20px rgba(15,23,42,.05)}
@media (prefers-color-scheme:dark){:root{--bg:#11161c;--panel:#1a2129;--tx:#e6ebf0;--mut:#a9b4c0;--tenue:#7b8794;--bd:#2c3642;--grid:#27313c;--pri:#4c9be8;
  --ok:#32d583;--okbg:rgba(50,213,131,.12);--err:#f87171;--errbg:rgba(248,113,113,.13);--pend:#fbbf24;--pendbg:rgba(251,191,36,.13);--sombra:0 1px 2px rgba(0,0,0,.3),0 6px 20px rgba(0,0,0,.25)}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:<?= $angosta ? '460px' : '1180px' ?>;margin:0 auto;padding:16px}
header.top{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:14px}
header.top .marca{display:flex;align-items:center;gap:12px;min-width:0}
.logo{height:30px;width:auto}.logo.oscuro{display:none}
@media (prefers-color-scheme:dark){.logo.claro{display:none}.logo.oscuro{display:inline}}
h1{font-size:18px;margin:0;font-weight:700;letter-spacing:-.01em}
h2{font-size:17px;margin:0}
a{color:var(--pri)}code,.mono{font-family:ui-monospace,Consolas,monospace;font-size:12.5px}
.mut{color:var(--mut);font-size:13px}
nav.menu{display:flex;gap:8px;align-items:center;font-size:13px}
nav.menu a{display:inline-block;border:1px solid var(--bd);border-radius:8px;padding:4px 11px;text-decoration:none;color:var(--tx);background:var(--panel)}
nav.menu a:hover{border-color:var(--pri);color:var(--pri)}
.aviso{padding:10px 12px;border-radius:10px;margin:0 0 10px;border:1px solid var(--bd);background:var(--panel)}
.aviso.ok{background:var(--okbg);color:var(--ok);border-color:var(--ok)}
.aviso.err{background:var(--errbg);color:var(--err);border-color:var(--err)}
.aviso ul{margin:0;padding-left:18px}
input:not([type=checkbox]){width:100%;padding:8px 10px;border:1px solid var(--bd);border-radius:8px;background:var(--panel);color:var(--tx);font:inherit}
input:focus-visible,button:focus-visible,summary:focus-visible,a:focus-visible{outline:2px solid var(--pri);outline-offset:2px}
input[type=checkbox]{width:16px;height:16px;accent-color:var(--pri)}
button{padding:8px 14px;border:1px solid var(--bd);border-radius:8px;background:var(--panel);color:var(--tx);font:inherit;cursor:pointer}
button:disabled{opacity:.45;cursor:default}
button.pri{background:var(--pri);border-color:var(--pri);color:#fff;font-weight:600}
button.pel{color:var(--err);border-color:var(--err);background:transparent}
button.suave{padding:5px 10px;font-size:13px;color:var(--mut)}
.app{display:grid;grid-template-columns:300px minmax(0,1fr);gap:16px;align-items:start}
.lista{background:var(--panel);border:1px solid var(--bd);border-radius:14px;box-shadow:var(--sombra);padding:10px;position:sticky;top:12px}
.lista-cab{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:8px}
.lista-cab input{flex:1;min-width:120px}
#pcs{display:flex;flex-direction:column;gap:4px;max-height:calc(100vh - 150px);overflow:auto}
.pc{display:flex;flex-direction:column;gap:2px;padding:8px 10px;border-radius:10px;border:1px solid transparent;color:var(--tx);text-decoration:none}
a.pc:hover{background:var(--grid)}
.pc.sel{background:color-mix(in srgb,var(--pri) 12%,transparent);border-color:var(--pri)}
.pc.nula{opacity:.55}
.pc-nom{display:flex;gap:6px;align-items:center;flex-wrap:wrap;overflow-wrap:anywhere}
.pill{align-self:flex-start;display:inline-block;padding:1px 9px;border-radius:99px;font-size:12px;font-weight:600;background:var(--grid);color:var(--mut)}
.pill.ok{background:var(--okbg);color:var(--ok)}.pill.pend{background:var(--pendbg);color:var(--pend)}
.ver{display:inline-block;font-size:10.5px;font-weight:600;line-height:1.5;padding:0 6px;border:1px solid var(--bd);border-radius:99px;color:var(--tenue);cursor:help;white-space:nowrap;vertical-align:middle}
.ver.vieja{color:var(--pend);border-color:var(--pend)}.ver.falla{color:var(--err);border-color:var(--err)}
.editor{background:var(--panel);border:1px solid var(--bd);border-radius:14px;box-shadow:var(--sombra);padding:16px;min-width:0}
.vacio{padding:40px 12px;text-align:center}.vacio h2{margin-bottom:6px}
.ed-cab{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;align-items:flex-start;margin-bottom:6px}
.ed-cab h2{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.estado{display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:flex-end}
.sucio{color:var(--pend);font-weight:600;font-size:12.5px}
fieldset.sec{border:1px solid var(--bd);border-radius:12px;margin:12px 0;padding:10px 14px 12px;min-width:0}
fieldset.sec[disabled]{opacity:.5}
legend{font-weight:600;padding:0 6px}
legend label{display:flex;gap:8px;align-items:center;cursor:pointer}
.dest{display:grid;grid-template-columns:minmax(0,2fr) minmax(0,1fr) minmax(0,1fr) 34px;gap:8px;margin-bottom:6px;align-items:center}
.dest.cab{font-size:12px;color:var(--mut);margin-bottom:4px}
button.x{padding:0;width:34px;height:34px;font-size:18px;line-height:1;color:var(--mut)}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.grid2 label{display:block;font-size:13px;color:var(--mut)}.grid2 input{margin-top:3px}
.chk{display:flex;gap:8px;align-items:center;margin-top:10px}
.acciones{display:flex;gap:8px;flex-wrap:wrap;margin:14px 0}
details.copiar{border:1px dashed var(--bd);border-radius:12px;padding:10px 14px;margin-top:6px}
details.copiar[open]{border-style:solid}
details.copiar summary{cursor:pointer;font-weight:700;letter-spacing:.06em;color:var(--kore)}
.copia-lista{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:4px 12px;max-height:240px;overflow:auto;margin:6px 0 10px}
.copia-item{display:flex;gap:8px;align-items:center;padding:5px 6px;border-radius:8px;cursor:pointer}
.copia-item:hover{background:var(--grid)}
.login{background:var(--panel);border:1px solid var(--bd);border-radius:16px;box-shadow:var(--sombra);padding:20px;margin-top:30px}
.login h2{margin-bottom:10px}.login label{display:block;margin:12px 0;color:var(--mut)}.login button{width:100%}
@media (max-width:860px){.app{grid-template-columns:1fr}.lista{position:static}#pcs{max-height:240px}}
@media (max-width:560px){.dest{grid-template-columns:minmax(0,1.6fr) minmax(0,1fr) minmax(0,1fr) 34px}.grid2{grid-template-columns:1fr}main{padding:12px}}
@media (prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
</style>
</head>
<body><main>
<header class="top">
  <div class="marca">
    <img class="logo claro" src="assets/kore_sula_claro.svg" alt="" aria-hidden="true"><img class="logo oscuro" src="assets/kore_sula_oscuro.svg" alt="" aria-hidden="true">
    <h1><?= h($titulo) ?></h1>
  </div>
  <nav class="menu"><a href="index.php">⌂ Inicio · Análisis semanal</a><?php if ($conSalir): ?><a href="?salir=1">Cerrar sesión</a><?php endif; ?></nav>
</header>
<?= $cuerpo ?>
</main></body></html>
<?php
}
