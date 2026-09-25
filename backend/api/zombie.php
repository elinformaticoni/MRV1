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
const MR_Z_SECCIONES  = ['targets' => 'Destinos', 'detection' => 'Detección', 'db' => 'API de análisis', 'ftp' => 'FTP'];

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
        . 'Agregue <code>\'reporte\' =&gt; [\'clave\' =&gt; \'…\']</code> en <code>config/config.php</code> del servidor.</div>');
    exit;
}

session_name('MRV1REP'); // la misma sesión que index.php: se inicia sesión una sola vez
session_set_cookie_params([
    'httponly' => true,
    'secure'   => !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off',
    'samesite' => 'Lax',
]);
session_start();

if (isset($_GET['salir'])) {
    $_SESSION = [];
    session_destroy();
    header('Location: ' . strtok($_SERVER['REQUEST_URI'] ?? 'zombie.php', '?'));
    exit;
}

$errorLogin = '';
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST' && isset($_POST['clave'])) {
    if (hash_equals($claveRep, (string) $_POST['clave'])) {
        session_regenerate_id(true);
        $_SESSION['mr_rep_ok'] = true;
        header('Location: ' . strtok($_SERVER['REQUEST_URI'] ?? 'zombie.php', '?'));
        exit;
    }
    usleep(700000); // frena intentos repetidos
    $errorLogin = 'Clave incorrecta.';
}

if (empty($_SESSION['mr_rep_ok'])) {
    mr_z_pagina('Configuración remota', '<form method="post" class="login"><h2>Iniciar sesión</h2>'
        . ($errorLogin !== '' ? '<div class="aviso err">' . h($errorLogin) . '</div>' : '')
        . '<label>Clave<input type="password" name="clave" autofocus required></label>'
        . '<button class="pri">Entrar</button></form>');
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
        . (mr_debug_habilitado() ? ' ' . h($e->getMessage()) : '') . '</div>');
    exit;
}

$pcsValidas = [];
foreach ($filas as $f) {
    if (mr_z_ruta((string) $f['pc']) !== null) {
        $pcsValidas[] = (string) $f['pc'];
    }
}

// --- Formulario: valores por defecto, desde archivo o desde POST ----------
function mr_z_form_defecto(): array
{
    $t = [];
    for ($i = 0; $i < MR_Z_MAX_DEST; $i++) {
        $t[] = ['address' => $i === 0 ? '8.8.8.8' : '', 'intervalSec' => $i === 0 ? '5' : '', 'confirmPings' => $i === 0 ? '1' : ''];
    }
    return [
        'inc'       => ['targets' => true, 'detection' => true, 'db' => true, 'ftp' => true],
        'targets'   => $t,
        'detection' => ['timeoutMs' => '2000', 'networkCheckSec' => '5'],
        'db'        => ['runEveryMin' => '180', 'retries' => '3'],
        'ftp'       => ['runEveryMin' => '120', 'retries' => '3', 'uploadCurrentDay' => true],
    ];
}

function mr_z_form_desde_config(array $c): array
{
    $f = mr_z_form_defecto();
    $f['inc'] = ['targets' => isset($c['targets']), 'detection' => isset($c['detection']), 'db' => isset($c['db']), 'ftp' => isset($c['ftp'])];
    if (isset($c['targets']) && is_array($c['targets'])) {
        $t = [];
        foreach (array_slice($c['targets'], 0, MR_Z_MAX_DEST) as $x) {
            $t[] = ['address' => (string) ($x['address'] ?? ''), 'intervalSec' => (string) ($x['intervalSec'] ?? ''), 'confirmPings' => (string) ($x['confirmPings'] ?? '')];
        }
        while (count($t) < MR_Z_MAX_DEST) {
            $t[] = ['address' => '', 'intervalSec' => '', 'confirmPings' => ''];
        }
        $f['targets'] = $t;
    }
    foreach (['detection' => ['timeoutMs', 'networkCheckSec'], 'db' => ['runEveryMin', 'retries'], 'ftp' => ['runEveryMin', 'retries']] as $sec => $claves) {
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
        'inc'       => [],
        'targets'   => [],
        'detection' => ['timeoutMs' => $s('det_timeout'), 'networkCheckSec' => $s('det_net')],
        'db'        => ['runEveryMin' => $s('db_run'), 'retries' => $s('db_ret')],
        'ftp'       => ['runEveryMin' => $s('ftp_run'), 'retries' => $s('ftp_ret'), 'uploadCurrentDay' => isset($p['ftp_cur'])],
    ];
    foreach (array_keys(MR_Z_SECCIONES) as $sec) {
        $f['inc'][$sec] = isset($inc[$sec]);
    }
    $a = is_array($p['t_addr'] ?? null) ? array_values($p['t_addr']) : [];
    $i = is_array($p['t_int'] ?? null) ? array_values($p['t_int']) : [];
    $c = is_array($p['t_conf'] ?? null) ? array_values($p['t_conf']) : [];
    for ($n = 0; $n < MR_Z_MAX_DEST; $n++) {
        $f['targets'][] = [
            'address'      => trim((string) ($a[$n] ?? '')),
            'intervalSec'  => trim((string) ($i[$n] ?? '')),
            'confirmPings' => trim((string) ($c[$n] ?? '')),
        ];
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
        foreach ($f['targets'] as $n => $r) {
            if ($r['address'] === '') {
                continue;
            }
            $et = 'Destino ' . ($n + 1);
            if (!preg_match('/^[A-Za-z0-9._:\-]{1,100}$/', $r['address'])) {
                $err[] = "$et: dirección no válida (solo letras, números, punto, guion y dos puntos).";
                continue;
            }
            if (isset($vistos[strtolower($r['address'])])) {
                $err[] = "$et: la dirección {$r['address']} está repetida.";
                continue;
            }
            $vistos[strtolower($r['address'])] = true;
            $iv = mr_z_entero($r['intervalSec'] === '' ? '5' : $r['intervalSec'], MR_Z_LIM['intervalSec'], "$et, intervalo (s)", $err);
            $cf = mr_z_entero($r['confirmPings'] === '' ? '1' : $r['confirmPings'], MR_Z_LIM['confirmPings'], "$et, pings de confirmación", $err);
            if ($iv !== null && $cf !== null) {
                $t[] = ['address' => $r['address'], 'intervalSec' => $iv, 'confirmPings' => $cf];
            }
        }
        if (!$t && !array_filter($err, fn($e) => str_starts_with($e, 'Destino'))) {
            $err[] = 'Destinos: indique al menos un destino.';
        }
        $sec['targets'] = $t;
    }
    if ($f['inc']['detection']) {
        $a = mr_z_entero($f['detection']['timeoutMs'], MR_Z_LIM['timeoutMs'], 'Detección, timeout (ms)', $err);
        $b = mr_z_entero($f['detection']['networkCheckSec'], MR_Z_LIM['networkCheckSec'], 'Detección, revisión de red (s)', $err);
        $sec['detection'] = ['timeoutMs' => $a, 'networkCheckSec' => $b];
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

// --- Acciones del formulario -------------------------------------------------
$mensajes = [];
$errores  = [];
$form     = null;
$sel      = [];
$op       = '';

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST' && !isset($_POST['clave'])) {
    if (!hash_equals($csrf, (string) ($_POST['csrf'] ?? ''))) {
        $errores[] = 'La sesión del formulario venció. Vuelva a intentarlo.';
    } else {
        $op  = (string) ($_POST['op'] ?? '');
        $pcs = is_array($_POST['pcs'] ?? null) ? $_POST['pcs'] : [];
        $sel = array_values(array_intersect($pcsValidas, array_map('strval', $pcs)));

        if (!$sel) {
            $errores[] = 'Seleccione al menos una PC.';
            $form = mr_z_form_desde_post($_POST);
        } elseif ($op === 'cargar') {
            foreach ($sel as $pc) {
                $c = mr_z_leer($pc);
                if ($c !== null) {
                    $form = mr_z_form_desde_config($c);
                    $mensajes[] = 'Valores cargados de la instrucción actual de ' . $pc . '.';
                    break;
                }
            }
            if ($form === null) {
                $mensajes[] = 'Ninguna de las PC seleccionadas tiene instrucción: se muestran los valores predeterminados.';
            }
        } elseif ($op === 'quitar') {
            $q = 0;
            foreach ($sel as $pc) {
                $q += mr_z_borrar($pc) ? 1 : 0;
            }
            $mensajes[] = "Instrucción retirada de $q PC. Las PC conservan la última configuración que ya aplicaron.";
        } elseif ($op === 'guardar') {
            $form = mr_z_form_desde_post($_POST);
            $secciones = mr_z_construir($form, $errores);
            if (!$errores) {
                $ok = 0;
                foreach ($sel as $pc) {
                    try {
                        $ant = mr_z_leer($pc);
                        // Revisión monótona por PC: aunque se borre y se vuelva a crear el archivo,
                        // nunca retrocede (la PC solo aplica si la revisión es mayor a la que ya aplicó).
                        $rev = max(time(), (int) ($ant['revision'] ?? 0) + 1);
                        mr_z_guardar($pc, array_merge(
                            ['schemaVersion' => 1, 'revision' => $rev, 'generadoEn' => date('c', $rev)],
                            $secciones
                        ));
                        $ok++;
                    } catch (Throwable $e) {
                        error_log('[MR zombie.php guardar] ' . $e->getMessage());
                        $errores[] = "No se pudo guardar la instrucción de $pc.";
                    }
                }
                if ($ok > 0) {
                    $mensajes[] = "Instrucción guardada para $ok PC. Cada una la aplicará en su próxima carga a la API (o al reiniciar).";
                }
            }
        }
    }
}
if ($form === null) {
    $form = mr_z_form_defecto();
}

// --- Vista ---------------------------------------------------------------------
$nombresSec = MR_Z_SECCIONES;
ob_start();
?>
<?php if ($falta002): ?>
<div class="aviso err">Falta ejecutar <code>sql/002_config_remota.sql</code>: sin él no se puede mostrar la confirmación de cada PC.</div>
<?php endif; ?>
<?php foreach ($mensajes as $m): ?><div class="aviso ok"><?= h($m) ?></div><?php endforeach; ?>
<?php if ($errores): ?><div class="aviso err"><ul><?php foreach ($errores as $e): ?><li><?= h($e) ?></li><?php endforeach; ?></ul></div><?php endif; ?>

<form method="post" autocomplete="off">
<input type="hidden" name="csrf" value="<?= h($csrf) ?>">

<h2>1. Equipos</h2>
<div class="barra">
  <input type="search" id="filtro" placeholder="Filtrar por nombre o alias…" aria-label="Filtrar equipos">
  <button type="button" id="todas">Marcar visibles</button>
  <button type="button" id="ninguna">Desmarcar todas</button>
  <span id="cuenta" class="mut"></span>
</div>
<div class="tabla"><table>
<thead><tr><th></th><th>PC / alias</th><th>Instrucción en el servidor</th><th>Estado en la PC</th></tr></thead>
<tbody>
<?php foreach ($filas as $f):
    $pc = (string) $f['pc'];
    $ruta = mr_z_ruta($pc);
    $c = $ruta !== null ? mr_z_leer($pc) : null;
    $revSrv = $c !== null ? (int) ($c['revision'] ?? 0) : 0;
    $revApl = isset($f['config_rev_aplicada']) ? (int) $f['config_rev_aplicada'] : 0;
    $aplEn  = (string) ($f['config_aplicada_en'] ?? '');
    $secs = $c !== null ? array_values(array_intersect_key($nombresSec, $c)) : [];
    ?>
<tr data-buscar="<?= h(strtolower($pc . ' ' . (string) ($f['alias'] ?? ''))) ?>">
  <td><input type="checkbox" name="pcs[]" value="<?= h($pc) ?>" <?= in_array($pc, $sel, true) ? 'checked' : '' ?> <?= $ruta === null ? 'disabled title="Nombre de PC no válido para archivo"' : '' ?> aria-label="Seleccionar <?= h($pc) ?>"></td>
  <td><strong class="mono"><?= h($pc) ?></strong><?php if (($f['alias'] ?? '') !== ''): ?><br><span class="mut"><?= h((string) $f['alias']) ?></span><?php endif; ?></td>
  <td><?php if ($c === null): ?><span class="mut">sin instrucción</span><?php else: ?>
      <span class="mono"><?= h(date('Y-m-d H:i', $revSrv)) ?></span><br><span class="mut"><?= h(implode(', ', $secs)) ?></span><?php endif; ?></td>
  <td><?php if ($falta002): ?><span class="mut">—</span>
      <?php elseif ($c !== null && $revApl >= $revSrv && $revApl > 0): ?><span class="pill ok">Aplicada</span> <span class="mut"><?= h($aplEn) ?></span>
      <?php elseif ($c !== null): ?><span class="pill pend">Pendiente</span><?php if ($aplEn !== ''): ?><br><span class="mut">última aplicada: <?= h($aplEn) ?></span><?php endif; ?>
      <?php elseif ($aplEn !== ''): ?><span class="mut">última aplicada: <?= h($aplEn) ?></span>
      <?php else: ?><span class="mut">—</span><?php endif; ?></td>
</tr>
<?php endforeach; ?>
<?php if (!$filas): ?><tr><td colspan="4" class="mut">Todavía no hay PC registradas (se registran solas al enviar datos a la API).</td></tr><?php endif; ?>
</tbody></table></div>

<h2>2. Instrucción</h2>
<p class="mut">Solo se envían las secciones marcadas; la PC sobrescribe esos campos de su configuración local y deja intactos los demás. Nunca se envían credenciales, token, URL ni alias.</p>

<fieldset>
  <legend><label><input type="checkbox" name="inc[targets]" <?= $form['inc']['targets'] ? 'checked' : '' ?>> Destinos a monitorear</label></legend>
  <div class="grid3 cab"><span>Dirección (IP o dominio)</span><span>Intervalo (s)</span><span>Pings de confirmación</span></div>
  <?php foreach ($form['targets'] as $r): ?>
  <div class="grid3">
    <input name="t_addr[]" value="<?= h($r['address']) ?>" maxlength="100" placeholder="8.8.8.8">
    <input name="t_int[]" value="<?= h($r['intervalSec']) ?>" inputmode="numeric" placeholder="5">
    <input name="t_conf[]" value="<?= h($r['confirmPings']) ?>" inputmode="numeric" placeholder="1">
  </div>
  <?php endforeach; ?>
  <p class="mut">Intervalo <?= MR_Z_LIM['intervalSec'][0] ?>–<?= MR_Z_LIM['intervalSec'][1] ?> s · confirmación <?= MR_Z_LIM['confirmPings'][0] ?>–<?= MR_Z_LIM['confirmPings'][1] ?> · hasta <?= MR_Z_MAX_DEST ?> destinos. Los destinos reemplazan a la lista actual de la PC (al aplicarlos, el monitor se reinicia).</p>
</fieldset>

<fieldset>
  <legend><label><input type="checkbox" name="inc[detection]" <?= $form['inc']['detection'] ? 'checked' : '' ?>> Detección</label></legend>
  <div class="grid2">
    <label>Timeout del ping (ms)<input name="det_timeout" value="<?= h($form['detection']['timeoutMs']) ?>" inputmode="numeric"></label>
    <label>Revisión de red local (s)<input name="det_net" value="<?= h($form['detection']['networkCheckSec']) ?>" inputmode="numeric"></label>
  </div>
  <p class="mut">Timeout <?= MR_Z_LIM['timeoutMs'][0] ?>–<?= MR_Z_LIM['timeoutMs'][1] ?> ms · revisión <?= MR_Z_LIM['networkCheckSec'][0] ?>–<?= MR_Z_LIM['networkCheckSec'][1] ?> s.</p>
</fieldset>

<fieldset>
  <legend><label><input type="checkbox" name="inc[db]" <?= $form['inc']['db'] ? 'checked' : '' ?>> Carga a la API de análisis</label></legend>
  <div class="grid2">
    <label>Frecuencia (min)<input name="db_run" value="<?= h($form['db']['runEveryMin']) ?>" inputmode="numeric"></label>
    <label>Reintentos<input name="db_ret" value="<?= h($form['db']['retries']) ?>" inputmode="numeric"></label>
  </div>
  <p class="mut">Frecuencia <?= MR_Z_LIM['dbRunEveryMin'][0] ?>–<?= MR_Z_LIM['dbRunEveryMin'][1] ?> min (máximo acotado para que la PC siempre vuelva a consultar al servidor) · reintentos <?= MR_Z_LIM['retries'][0] ?>–<?= MR_Z_LIM['retries'][1] ?>.</p>
</fieldset>

<fieldset>
  <legend><label><input type="checkbox" name="inc[ftp]" <?= $form['inc']['ftp'] ? 'checked' : '' ?>> Carga por FTP</label></legend>
  <div class="grid2">
    <label>Frecuencia (min)<input name="ftp_run" value="<?= h($form['ftp']['runEveryMin']) ?>" inputmode="numeric"></label>
    <label>Reintentos<input name="ftp_ret" value="<?= h($form['ftp']['retries']) ?>" inputmode="numeric"></label>
  </div>
  <label class="chk"><input type="checkbox" name="ftp_cur" <?= $form['ftp']['uploadCurrentDay'] ? 'checked' : '' ?>> Subir también el día en curso</label>
  <p class="mut">Frecuencia <?= MR_Z_LIM['ftpRunEveryMin'][0] ?>–<?= MR_Z_LIM['ftpRunEveryMin'][1] ?> min · reintentos <?= MR_Z_LIM['retries'][0] ?>–<?= MR_Z_LIM['retries'][1] ?>.</p>
</fieldset>

<div class="acciones">
  <button class="pri" name="op" value="guardar">Guardar instrucción en las seleccionadas</button>
  <button name="op" value="cargar">Cargar valores de la primera seleccionada</button>
  <button class="pel" name="op" value="quitar" onclick="return confirm('¿Retirar la instrucción de las PC seleccionadas? Las PC conservan la configuración que ya aplicaron.');">Quitar instrucción</button>
</div>
</form>

<script>
(function () {
  var filas = [].slice.call(document.querySelectorAll('tbody tr[data-buscar]'));
  var filtro = document.getElementById('filtro'), cuenta = document.getElementById('cuenta');
  function visible(f) { return f.style.display !== 'none'; }
  function contar() {
    var n = document.querySelectorAll('input[name="pcs[]"]:checked').length;
    cuenta.textContent = n + ' seleccionada' + (n === 1 ? '' : 's') + ' de ' + filas.length;
  }
  filtro.addEventListener('input', function () {
    var q = filtro.value.trim().toLowerCase();
    filas.forEach(function (f) { f.style.display = f.getAttribute('data-buscar').indexOf(q) === -1 ? 'none' : ''; });
  });
  document.getElementById('todas').addEventListener('click', function () {
    filas.filter(visible).forEach(function (f) { var c = f.querySelector('input[type=checkbox]'); if (!c.disabled) c.checked = true; });
    contar();
  });
  document.getElementById('ninguna').addEventListener('click', function () {
    filas.forEach(function (f) { f.querySelector('input[type=checkbox]').checked = false; });
    contar();
  });
  document.addEventListener('change', function (e) { if (e.target.name === 'pcs[]') contar(); });
  contar();
})();
</script>
<?php
mr_z_pagina('Configuración remota', (string) ob_get_clean(), true);

// =====================================================================
// Plantilla de página
// =====================================================================
function mr_z_pagina(string $titulo, string $cuerpo, bool $conSalir = false): void
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
:root{--bg:#f6f7f9;--card:#fff;--tx:#1b1f24;--mut:#66707c;--bd:#d9dde3;--pri:#1d6fd6;--ok:#1a7f45;--okbg:#e5f5ec;--err:#b3261e;--errbg:#fdecea;--pend:#8a5a00;--pendbg:#fff3d6}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#14171b;--card:#1c2026;--tx:#e6e9ee;--mut:#98a2b0;--bd:#2f3640;--pri:#5b9cf0;--ok:#63d391;--okbg:#14301f;--err:#f2867e;--errbg:#3a1a18;--pend:#f0c15a;--pendbg:#3a2e10}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:980px;margin:0 auto;padding:16px}
header{display:flex;justify-content:space-between;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:8px}
h1{font-size:20px;margin:8px 0}h2{font-size:16px;margin:24px 0 8px}
a{color:var(--pri)}code,.mono{font-family:ui-monospace,Consolas,monospace;font-size:13px}
.mut{color:var(--mut);font-size:13px}
.aviso{padding:10px 12px;border-radius:8px;margin:10px 0;border:1px solid var(--bd)}
.aviso.ok{background:var(--okbg);color:var(--ok);border-color:var(--ok)}
.aviso.err{background:var(--errbg);color:var(--err);border-color:var(--err)}
.aviso ul{margin:0;padding-left:18px}
.barra{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:8px}
.barra input[type=search]{flex:1;min-width:180px}
input:not([type=checkbox]){width:100%;padding:8px;border:1px solid var(--bd);border-radius:6px;background:var(--card);color:var(--tx);font:inherit}
button{padding:8px 12px;border:1px solid var(--bd);border-radius:6px;background:var(--card);color:var(--tx);font:inherit;cursor:pointer}
button.pri{background:var(--pri);border-color:var(--pri);color:#fff}
button.pel{color:var(--err);border-color:var(--err)}
.tabla{overflow-x:auto;border:1px solid var(--bd);border-radius:8px;background:var(--card);max-height:340px;overflow-y:auto}
table{border-collapse:collapse;width:100%}
th,td{padding:8px 10px;text-align:left;border-bottom:1px solid var(--bd);vertical-align:top}
th{position:sticky;top:0;background:var(--card);font-size:13px;color:var(--mut)}
tr:last-child td{border-bottom:0}
.pill{display:inline-block;padding:1px 8px;border-radius:99px;font-size:12px;font-weight:600}
.pill.ok{background:var(--okbg);color:var(--ok)}.pill.pend{background:var(--pendbg);color:var(--pend)}
fieldset{border:1px solid var(--bd);border-radius:8px;background:var(--card);margin:12px 0;padding:8px 14px 12px}
legend{font-weight:600;padding:0 6px}
.grid3{display:grid;grid-template-columns:2fr 1fr 1fr;gap:8px;margin-bottom:6px}
.grid3.cab{font-size:12px;color:var(--mut)}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.grid2 label{display:block;font-size:13px;color:var(--mut)}.grid2 input{margin-top:3px}
.chk{display:block;margin-top:8px}
.acciones{display:flex;gap:8px;flex-wrap:wrap;margin:16px 0}
.login{max-width:320px;margin:40px auto;background:var(--card);border:1px solid var(--bd);border-radius:10px;padding:18px}
.login label{display:block;margin:12px 0}
@media (max-width:560px){.grid3{grid-template-columns:1.5fr 1fr 1fr}.grid2{grid-template-columns:1fr}main{padding:16px 12px}}
</style>
</head>
<body><main>
<header><h1>Configuración remota</h1>
<span class="mut"><a href="index.php">Análisis semanal</a><?php if ($conSalir): ?> · <a href="?salir=1">Cerrar sesión</a><?php endif; ?></span></header>
<?= $cuerpo ?>
</main></body></html>
<?php
}
