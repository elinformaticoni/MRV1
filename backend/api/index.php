<?php
/**
 * Monitor de Red — Backend de análisis
 * index.php — Formulario SPA de análisis semanal + endpoints JSON de consulta.
 *
 * Se abre directo en el subdominio (https://mrv1.solucionesnicaragua.com/),
 * junto a registros.php. Ver backend/IA.md sección 5.
 *
 *   GET  index.php                                     → página (SPA)
 *   GET  index.php?accion=maquinas&desde=&hasta=       → máquinas con registros en el rango
 *   GET  index.php?accion=datos&desde=&hasta=&pc[]=…   → filas de esas máquinas en el rango
 *   GET  index.php?accion=dias&desde=&hasta=           → fechas del rango con algún registro (puntito del calendario)
 *   POST index.php?accion=eliminar_pc  {pc, csrf}      → borra una computadora y TODOS sus registros
 *   POST index.php?accion=nombre_guardar {pc, nombre, csrf} → corrige el nombre (alias) de una PC y se lo manda por la configuración remota
 *   POST index.php  (clave=…)                          → inicio de sesión (si hay clave configurada)
 *   GET  index.php?salir=1                             → cerrar sesión
 *
 * Control de acceso: si config.php trae 'reporte' => ['clave' => '…'] (no vacía),
 * la página y los endpoints exigen iniciar sesión con esa clave. Si no está
 * configurada, el acceso queda abierto y la página muestra un aviso.
 *
 * Prácticamente de solo lectura: la única excepción es "eliminar_pc" (borra la
 * computadora y sus registros a pedido explícito del usuario desde el formulario,
 * ver sección "Máquinas"). Esa acción exige sesión iniciada (no está disponible en
 * modo de acceso abierto) y un token CSRF de un solo formulario, igual que zombie.php.
 */

declare(strict_types=1);

require __DIR__ . '/lib/util.php';
require __DIR__ . '/lib/db.php';

ini_set('display_errors', '0');

const MR_MAX_DIAS_RANGO   = 31;      // rango máximo por consulta (la SPA pide 7)
const MR_MAX_PCS_CONSULTA = 100;     // máquinas por consulta de datos
const MR_MAX_FILAS        = 200000;  // tope de filas por consulta de datos
const MR_URL_PAQUETE      = 'https://github.com/elinformaticoni/MRV1/archive/refs/heads/main.zip'; // instalador del monitor
const MR_ZOMBIE_DIR       = __DIR__ . '/zombie'; // instrucciones de configuración remota pendientes (ver zombie.php)

/** Ruta del archivo de instrucción pendiente de una PC (mismo criterio que mr_z_ruta en zombie.php), o null si el nombre no es válido como nombre de archivo. */
function mr_ruta_zombie(string $pc): ?string
{
    if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/', $pc) || str_contains($pc, '..')) {
        return null;
    }
    return MR_ZOMBIE_DIR . '/config.' . strtolower($pc) . '.json';
}

$cfg         = mr_config();
$claveRep    = (string) ($cfg['reporte']['clave'] ?? '');
$requiereLog = $claveRep !== '';

// --- Sesión (solo si hay clave) ---------------------------------------
if ($requiereLog) {
    session_name('MRV1REP');
    session_set_cookie_params([
        'httponly' => true,
        'secure'   => !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off',
        'samesite' => 'Lax',
    ]);
    session_start();

    if (isset($_GET['salir'])) {
        $_SESSION = [];
        session_destroy();
        header('Location: ' . strtok($_SERVER['REQUEST_URI'] ?? 'index.php', '?'));
        exit;
    }
}

$errorLogin = '';
if ($requiereLog && ($_SERVER['REQUEST_METHOD'] ?? '') === 'POST' && isset($_POST['clave'])) {
    if (hash_equals($claveRep, (string) $_POST['clave'])) {
        session_regenerate_id(true);
        $_SESSION['mr_rep_ok'] = true;
        header('Location: ' . strtok($_SERVER['REQUEST_URI'] ?? 'index.php', '?'));
        exit;
    }
    usleep(700000); // frena intentos repetidos
    $errorLogin = 'Clave incorrecta.';
}
$autenticado = !$requiereLog || !empty($_SESSION['mr_rep_ok']);

// --- Token CSRF del formulario (solo tiene sentido con sesión: "eliminar_pc" lo exige) ----
$csrf = '';
if ($requiereLog && $autenticado) {
    if (empty($_SESSION['mr_rep_csrf'])) {
        $_SESSION['mr_rep_csrf'] = bin2hex(random_bytes(16));
    }
    $csrf = (string) $_SESSION['mr_rep_csrf'];
}

// --- Endpoints JSON -----------------------------------------------------
$accion = (string) ($_GET['accion'] ?? '');
if ($accion !== '') {
    mr_instalar_manejador_errores();
    if (!$autenticado) {
        mr_error(401, 'Sesión no iniciada.');
    }
    header('Cache-Control: no-store');

    // "eliminar_pc" no necesita rango de fechas y es la única acción que escribe en la
    // base de datos: se resuelve aparte, antes de exigir "desde"/"hasta".
    if ($accion === 'eliminar_pc') {
        if (!$requiereLog) {
            mr_error(403, 'Configure una clave de acceso ("reporte" => ["clave" => "…"] en config.php) para poder eliminar computadoras.');
        }
        if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
            mr_error(405, 'Método no permitido. Use POST.');
        }
        $body = mr_leer_cuerpo_json();
        if (!hash_equals($csrf, (string) ($body['csrf'] ?? ''))) {
            mr_error(403, 'La sesión del formulario venció. Recargue la página e intente de nuevo.');
        }
        $pc = trim((string) ($body['pc'] ?? ''));
        if ($pc === '' || mb_strlen($pc) > 100) {
            mr_error(422, 'Parámetro "pc" inválido.');
        }
        try {
            mr_json_response(200, mr_eliminar_pc(mr_db(), $pc));
        } catch (Throwable $e) {
            error_log('[MR index.php eliminar_pc] ' . $e->getMessage());
            $extra = mr_debug_habilitado() ? ['detalle' => $e->getMessage()] : [];
            mr_error(500, 'Error interno al eliminar la computadora.', $extra);
        }
    }

    // Bitácora de notas manuales y nombre corregido de una PC: escritura (POST + sesión + CSRF, igual que "eliminar_pc").
    if ($accion === 'nota_guardar' || $accion === 'nota_borrar' || $accion === 'nombre_guardar') {
        if (!$requiereLog) {
            mr_error(403, 'Configure una clave de acceso ("reporte" => ["clave" => "…"] en config.php) para poder anotar en la bitácora o cambiar nombres.');
        }
        if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
            mr_error(405, 'Método no permitido. Use POST.');
        }
        $body = mr_leer_cuerpo_json();
        if (!hash_equals($csrf, (string) ($body['csrf'] ?? ''))) {
            mr_error(403, 'La sesión del formulario venció. Recargue la página e intente de nuevo.');
        }
        try {
            $r = match ($accion) {
                'nota_guardar'   => mr_nota_guardar(mr_db(), $body),
                'nota_borrar'    => mr_nota_borrar(mr_db(), $body),
                default          => mr_nombre_guardar(mr_db(), $body),
            };
            mr_json_response(200, $r);
        } catch (Throwable $e) {
            error_log('[MR index.php ' . $accion . '] ' . $e->getMessage());
            if (stripos($e->getMessage(), "doesn't exist") !== false || stripos($e->getMessage(), 'no such table') !== false) {
                mr_error(500, 'Falta la tabla de notas: ejecute sql/003_notas.sql en la base de datos.');
            }
            $extra = mr_debug_habilitado() ? ['detalle' => $e->getMessage()] : [];
            mr_error(500, $accion === 'nombre_guardar' ? 'Error interno al guardar el nombre.' : 'Error interno al guardar la nota.', $extra);
        }
    }

    [$desde, $hasta] = mr_rango_fechas();

    try {
        $pdo = mr_db();
        if ($accion === 'maquinas') {
            mr_json_response(200, mr_consultar_maquinas($pdo, $desde, $hasta));
        }
        if ($accion === 'dias') {
            $st = $pdo->prepare('SELECT DISTINCT fecha FROM registros WHERE fecha BETWEEN :desde AND :hasta ORDER BY fecha');
            $st->execute(['desde' => $desde, 'hasta' => $hasta]);
            mr_json_response(200, ['ok' => true, 'dias' => array_map(fn($f) => substr((string) $f, 0, 10), $st->fetchAll(PDO::FETCH_COLUMN))]);
        }
        if ($accion === 'notas') {
            $r = mr_consultar_notas($pdo, $desde, $hasta, mr_lista_pcs());
            mr_json_response(200, ['ok' => true, 'notas' => $r['notas'], 'notas_ok' => $r['ok']]);
        }
        if ($accion === 'datos') {
            mr_json_response(200, mr_consultar_datos($pdo, $desde, $hasta, mr_lista_pcs()));
        }
    } catch (Throwable $e) {
        error_log('[MR index.php] ' . $e->getMessage());
        $extra = mr_debug_habilitado() ? ['detalle' => $e->getMessage()] : [];
        mr_error(500, 'Error interno al consultar los registros.', $extra);
    }
    mr_error(400, 'Acción desconocida.');
}

/** Lee y valida ?desde=AAAA-MM-DD&hasta=AAAA-MM-DD. */
function mr_rango_fechas(): array
{
    $leer = function (string $clave): string {
        $v = (string) ($_GET[$clave] ?? '');
        if (!preg_match('/^(\d{4})-(\d{2})-(\d{2})$/', $v, $m) || !checkdate((int) $m[2], (int) $m[3], (int) $m[1])) {
            mr_error(422, "Parámetro \"$clave\" inválido (esperado AAAA-MM-DD).");
        }
        return $v;
    };
    $desde = $leer('desde');
    $hasta = $leer('hasta');
    $dias  = (int) ((strtotime($hasta . ' 00:00:00 UTC') - strtotime($desde . ' 00:00:00 UTC')) / 86400);
    if ($dias < 0) {
        mr_error(422, '"hasta" es anterior a "desde".');
    }
    if ($dias >= MR_MAX_DIAS_RANGO) {
        mr_error(422, 'El rango no puede superar ' . MR_MAX_DIAS_RANGO . ' días.');
    }
    return [$desde, $hasta];
}

/** Lee ?pc[]=…&pc[]=… */
function mr_lista_pcs(): array
{
    $pcs = $_GET['pc'] ?? [];
    if (!is_array($pcs)) {
        $pcs = [$pcs];
    }
    $pcs = array_values(array_unique(array_filter(array_map(
        fn($p) => mb_substr(trim((string) $p), 0, 100),
        $pcs
    ), fn($p) => $p !== '')));
    if (count($pcs) === 0) {
        mr_error(422, 'Seleccione al menos una máquina.');
    }
    if (count($pcs) > MR_MAX_PCS_CONSULTA) {
        mr_error(422, 'Demasiadas máquinas en una sola consulta (máx. ' . MR_MAX_PCS_CONSULTA . ').');
    }
    return $pcs;
}

/**
 * Elimina una computadora por completo: todos sus registros (tabla `registros`) y su fila
 * en `computadoras`, dentro de una transacción (todo o nada). También retira, de mejor
 * esfuerzo, cualquier instrucción de configuración remota pendiente para esa PC (zombie.php,
 * ver backend/IA.md 5.1) — si esa PC volviera a usarse, no debe recibir una instrucción de
 * un "alguien" que ya no existe en la base de datos. Acción irreversible a pedido explícito
 * del usuario desde el formulario (accion=eliminar_pc, exige sesión y CSRF).
 */
function mr_eliminar_pc(PDO $pdo, string $pc): array
{
    $chk = $pdo->prepare('SELECT 1 FROM computadoras WHERE pc = :pc');
    $chk->execute(['pc' => $pc]);
    if (!$chk->fetchColumn()) {
        mr_error(404, 'No existe ninguna computadora con ese nombre.');
    }

    $pdo->beginTransaction();
    try {
        $delReg = $pdo->prepare('DELETE FROM registros WHERE pc = :pc');
        $delReg->execute(['pc' => $pc]);
        $eliminados = $delReg->rowCount();

        $delPc = $pdo->prepare('DELETE FROM computadoras WHERE pc = :pc');
        $delPc->execute(['pc' => $pc]);

        $pdo->commit();
    } catch (Throwable $e) {
        $pdo->rollBack();
        throw $e;
    }

    try {
        $pdo->prepare('DELETE FROM notas WHERE pc = :pc')->execute(['pc' => $pc]);
    } catch (Throwable $e) {
        // La tabla de notas puede no existir todavía (sql/003_notas.sql): no es un error.
    }

    $rutaZombie = mr_ruta_zombie($pc);
    if ($rutaZombie !== null && is_file($rutaZombie)) {
        @unlink($rutaZombie);
    }

    return ['ok' => true, 'pc' => $pc, 'registros_eliminados' => $eliminados];
}

/**
 * Deja para la PC una instrucción de configuración remota (la misma que lee zombie.php y descarga
 * Sincronizar_Config.ps1) con el campo "alias": la PC lo escribe en config\monitor.json y lo manda
 * en sus próximos envíos. Si ya había una instrucción SIN aplicar, conserva sus secciones para no
 * perderla; si ya estaba aplicada, la deja solo con el alias (así la PC no repite cambios ni se reinicia).
 * Devuelve false si el nombre de la PC no sirve como nombre de archivo.
 */
function mr_nombre_instruir(PDO $pdo, string $pc, string $nombre): bool
{
    $ruta = mr_ruta_zombie($pc);
    if ($ruta === null) {
        return false;
    }
    $ant = null;
    if (is_file($ruta)) {
        $j = json_decode((string) @file_get_contents($ruta), true);
        $ant = is_array($j) ? $j : null;
    }
    $secciones = [];
    if ($ant !== null) {
        $aplicada = false;
        try {
            $st = $pdo->prepare('SELECT config_rev_aplicada FROM computadoras WHERE pc = ?');
            $st->execute([$pc]);
            $aplicada = (int) $st->fetchColumn() >= (int) ($ant['revision'] ?? 0);
        } catch (Throwable $e) {
            // Sin la columna (falta sql/002) no se sabe: se conservan las secciones por prudencia.
        }
        if (!$aplicada) {
            foreach (['targets', 'detection', 'db', 'ftp'] as $k) {
                if (isset($ant[$k])) {
                    $secciones[$k] = $ant[$k];
                }
            }
        }
    }
    // Revisión monótona por PC (igual que zombie.php): la PC solo aplica si es mayor a la que ya aplicó.
    $rev = max(time(), (int) ($ant['revision'] ?? 0) + 1);
    $cfg = array_merge(['schemaVersion' => 1, 'revision' => $rev, 'generadoEn' => date('c', $rev)], $secciones, ['alias' => $nombre]);

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
    return true;
}

/**
 * Corrige el nombre (alias) de una PC: lo cambia ya en la base, para verlo de inmediato, y lo manda
 * a la PC dentro de la configuración remota para que ella lo adopte (si no, su próximo envío lo
 * devolvería al nombre anterior).
 */
function mr_nombre_guardar(PDO $pdo, array $body): array
{
    $pc = trim((string) ($body['pc'] ?? ''));
    if ($pc === '' || mb_strlen($pc) > 100) {
        mr_error(422, 'Parámetro "pc" inválido.');
    }
    $nombre = trim(preg_replace('/\s+/u', ' ', (string) ($body['nombre'] ?? '')));
    if ($nombre === '') {
        mr_error(422, 'Escriba el nombre del equipo.');
    }
    if (mb_strlen($nombre) > 150) {
        mr_error(422, 'El nombre no puede superar 150 caracteres.');
    }
    if (preg_match('/[\x00-\x1F\x7F]/', $nombre)) {
        mr_error(422, 'El nombre tiene caracteres no válidos.');
    }
    $chk = $pdo->prepare('SELECT 1 FROM computadoras WHERE pc = ?');
    $chk->execute([$pc]);
    if (!$chk->fetchColumn()) {
        mr_error(404, 'No existe ninguna computadora con ese nombre.');
    }

    $enviada = mr_nombre_instruir($pdo, $pc, $nombre);
    $pdo->prepare('UPDATE computadoras SET alias = ? WHERE pc = ?')->execute([$nombre, $pc]);
    return ['ok' => true, 'pc' => $pc, 'alias' => $nombre, 'instruccion' => $enviada];
}

/** Máquinas (pc + alias) con registros en el rango, con sus destinos y días con datos. */
function mr_consultar_maquinas(PDO $pdo, string $desde, string $hasta): array
{
    $st = $pdo->prepare(
        "SELECT r.pc, c.alias, r.destino,
                COUNT(*) AS registros,
                SUM(CASE WHEN r.tipo = 'ERROR' THEN 1 ELSE 0 END) AS errores
           FROM registros r
           LEFT JOIN computadoras c ON c.pc = r.pc
          WHERE r.fecha BETWEEN :desde AND :hasta
          GROUP BY r.pc, c.alias, r.destino
          ORDER BY r.pc, r.destino"
    );
    $st->execute(['desde' => $desde, 'hasta' => $hasta]);

    $maq = [];
    foreach ($st as $f) {
        $pc = (string) $f['pc'];
        if (!isset($maq[$pc])) {
            $maq[$pc] = ['pc' => $pc, 'alias' => (string) ($f['alias'] ?? ''), 'destinos' => [], 'dias' => []];
        }
        $maq[$pc]['destinos'][] = [
            'destino'   => (string) $f['destino'],
            'registros' => (int) $f['registros'],
            'errores'   => (int) $f['errores'],
        ];
    }

    $st = $pdo->prepare(
        'SELECT DISTINCT pc, fecha FROM registros WHERE fecha BETWEEN :desde AND :hasta ORDER BY pc, fecha'
    );
    $st->execute(['desde' => $desde, 'hasta' => $hasta]);
    foreach ($st as $f) {
        if (isset($maq[$f['pc']])) {
            $maq[$f['pc']]['dias'][] = (string) $f['fecha'];
        }
    }

    $lista = array_values($maq);
    foreach ($lista as &$m) {
        $m['version'] = mr_version_pc($m['pc']);   // versión de scripts confirmada por la PC (actualizar.php)
    }
    unset($m);
    usort($lista, fn($a, $b) => strcasecmp($a['alias'] ?: $a['pc'], $b['alias'] ?: $b['pc']));

    return ['ok' => true, 'desde' => $desde, 'hasta' => $hasta, 'maquinas' => $lista];
}

/**
 * Filas de las máquinas pedidas en el rango, agrupadas por pc → destino.
 * Cada fila: [fecha, hora, tipo, tiempo_s|null, latencia_ms|null, mensaje|null]
 */
/**
 * Notas manuales (bitácora) de las PC pedidas en el rango: { pc: [[id, fecha, hora, texto], …] }.
 * Si la tabla `notas` aún no existe (falta sql/003_notas.sql) devuelve ok=false y el resto sigue funcionando.
 */
function mr_consultar_notas(PDO $pdo, string $desde, string $hasta, array $pcs): array
{
    $marcas = implode(',', array_fill(0, count($pcs), '?'));
    try {
        $st = $pdo->prepare(
            "SELECT id, pc, fecha, hora, texto FROM notas
              WHERE fecha BETWEEN ? AND ? AND pc IN ($marcas)
              ORDER BY pc, fecha, hora, id"
        );
        $st->execute(array_merge([$desde, $hasta], $pcs));
    } catch (Throwable $e) {
        error_log('[MR index.php notas] ' . $e->getMessage());
        return ['ok' => false, 'notas' => new stdClass()];
    }
    $porPc = [];
    foreach ($st as $f) {
        $porPc[(string) $f['pc']][] = [
            (int) $f['id'], substr((string) $f['fecha'], 0, 10), substr((string) $f['hora'], 0, 8), (string) $f['texto'],
        ];
    }
    return ['ok' => true, 'notas' => $porPc ?: new stdClass()];
}

/** Valida y normaliza fecha (AAAA-MM-DD) y hora (HH:MM o HH:MM:SS) de una nota. */
function mr_nota_fecha_hora(array $body): array
{
    $fecha = trim((string) ($body['fecha'] ?? ''));
    if (!preg_match('/^(\d{4})-(\d{2})-(\d{2})$/', $fecha, $m) || !checkdate((int) $m[2], (int) $m[3], (int) $m[1])) {
        mr_error(422, 'Fecha inválida (esperado AAAA-MM-DD).');
    }
    $hora = trim((string) ($body['hora'] ?? ''));
    if (!preg_match('/^([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?$/', $hora, $h)) {
        mr_error(422, 'Hora inválida (esperado HH:MM).');
    }
    return [$fecha, sprintf('%s:%s:%s', $h[1], $h[2], $h[3] ?? '00')];
}

/**
 * Crea una nota por cada PC indicada (`pcs`) o, si viene `id`, corrige fecha, hora y texto de esa nota.
 * El texto es libre y breve (máx. 300 caracteres); se guarda tal cual y se escapa al dibujarlo.
 */
function mr_nota_guardar(PDO $pdo, array $body): array
{
    [$fecha, $hora] = mr_nota_fecha_hora($body);
    $texto = trim(preg_replace('/\s+/u', ' ', (string) ($body['texto'] ?? '')));
    if ($texto === '') {
        mr_error(422, 'Escriba el texto de la nota.');
    }
    if (mb_strlen($texto) > 300) {
        mr_error(422, 'La nota no puede superar 300 caracteres.');
    }

    $id = (int) ($body['id'] ?? 0);
    if ($id > 0) {
        $st = $pdo->prepare('UPDATE notas SET fecha = ?, hora = ?, texto = ? WHERE id = ?');
        $st->execute([$fecha, $hora, $texto, $id]);
        return ['ok' => true, 'guardadas' => 1];
    }

    $pcs = $body['pcs'] ?? [];
    if (!is_array($pcs)) {
        $pcs = [$pcs];
    }
    $pcs = array_values(array_unique(array_filter(array_map(fn($p) => mb_substr(trim((string) $p), 0, 100), $pcs), fn($p) => $p !== '')));
    if (!$pcs) {
        mr_error(422, 'Seleccione al menos una máquina.');
    }
    if (count($pcs) > MR_MAX_PCS_CONSULTA) {
        mr_error(422, 'Demasiadas máquinas en una sola nota (máx. ' . MR_MAX_PCS_CONSULTA . ').');
    }
    $marcas = implode(',', array_fill(0, count($pcs), '?'));
    $st = $pdo->prepare("SELECT pc FROM computadoras WHERE pc IN ($marcas)");
    $st->execute($pcs);
    $validas = $st->fetchAll(PDO::FETCH_COLUMN);
    if (!$validas) {
        mr_error(404, 'Ninguna de las máquinas existe.');
    }

    $pdo->beginTransaction();
    try {
        $ins = $pdo->prepare('INSERT INTO notas (pc, fecha, hora, texto) VALUES (?, ?, ?, ?)');
        foreach ($validas as $pc) {
            $ins->execute([(string) $pc, $fecha, $hora, $texto]);
        }
        $pdo->commit();
    } catch (Throwable $e) {
        $pdo->rollBack();
        throw $e;
    }
    return ['ok' => true, 'guardadas' => count($validas)];
}

/** Borra una nota por id. */
function mr_nota_borrar(PDO $pdo, array $body): array
{
    $id = (int) ($body['id'] ?? 0);
    if ($id <= 0) {
        mr_error(422, 'Parámetro "id" inválido.');
    }
    $st = $pdo->prepare('DELETE FROM notas WHERE id = ?');
    $st->execute([$id]);
    return ['ok' => true, 'borradas' => $st->rowCount()];
}

/**
 * Última IP conocida de la máquina ANTES de $desde (para los días del rango que no traen ningún
 * evento con IP). Solo cuentan INICIO, "Cambio de dirección IP" y "Cambio de adaptador"; los demás
 * mensajes pueden citar IP de destinos. Devuelve null si no hay ninguna.
 */
function mr_ip_previa(PDO $pdo, string $pc, string $desde): ?string
{
    $st = $pdo->prepare(
        "SELECT tipo, mensaje FROM registros
          WHERE pc = ? AND fecha < ? AND tipo IN ('INICIO','EVENTO')
            AND (tipo = 'INICIO' OR mensaje LIKE 'Cambio de dirección IP:%' OR mensaje LIKE 'Cambio de adaptador:%')
          ORDER BY fecha DESC, hora DESC, id DESC
          LIMIT 40"
    );
    $st->execute([$pc, $desde]);
    foreach ($st as $f) {
        $msg = (string) ($f['mensaje'] ?? '');
        if ($f['tipo'] === 'EVENTO' && preg_match('/->\s*(.*)$/u', $msg, $m)) {
            $msg = $m[1];
        }
        if (preg_match_all('/\b\d{1,3}(?:\.\d{1,3}){3}\b/', $msg, $ips) && $ips[0]) {
            return end($ips[0]);
        }
    }
    return null;
}

function mr_consultar_datos(PDO $pdo, string $desde, string $hasta, array $pcs): array
{
    $marcas = implode(',', array_fill(0, count($pcs), '?'));

    $st = $pdo->prepare("SELECT pc, alias FROM computadoras WHERE pc IN ($marcas)");
    $st->execute($pcs);
    $alias = [];
    foreach ($st as $f) {
        $alias[(string) $f['pc']] = (string) ($f['alias'] ?? '');
    }

    $st = $pdo->prepare(
        "SELECT pc, destino, fecha, hora, tipo, tiempo_s, latencia_ms, mensaje
           FROM registros
          WHERE fecha BETWEEN ? AND ? AND pc IN ($marcas)
          ORDER BY pc, destino, fecha, hora, id
          LIMIT " . (MR_MAX_FILAS + 1)
    );
    $st->execute(array_merge([$desde, $hasta], $pcs));

    $maq = [];
    $n = 0;
    foreach ($st as $f) {
        if (++$n > MR_MAX_FILAS) {
            mr_error(413, 'La consulta supera ' . MR_MAX_FILAS . ' registros; reduzca las máquinas o el rango.');
        }
        $pc = (string) $f['pc'];
        $de = (string) $f['destino'];
        $maq[$pc] ??= ['pc' => $pc, 'alias' => $alias[$pc] ?? '', 'destinos' => []];
        $maq[$pc]['destinos'][$de] ??= ['destino' => $de, 'filas' => []];
        $maq[$pc]['destinos'][$de]['filas'][] = [
            substr((string) $f['fecha'], 0, 10),
            substr((string) $f['hora'], 0, 8),
            (string) $f['tipo'],
            $f['tiempo_s'] === null ? null : (int) $f['tiempo_s'],
            $f['latencia_ms'] === null ? null : (int) $f['latencia_ms'],
            $f['mensaje'] === null ? null : (string) $f['mensaje'],
        ];
    }

    // Respeta el orden en que se pidieron las máquinas
    $lista = [];
    foreach ($pcs as $pc) {
        if (isset($maq[$pc])) {
            $maq[$pc]['destinos'] = array_values($maq[$pc]['destinos']);
            $maq[$pc]['version'] = mr_version_pc($pc);
            $maq[$pc]['ip_previa'] = mr_ip_previa($pdo, $pc, $desde);
            $lista[] = $maq[$pc];
        }
    }

    $notas = mr_consultar_notas($pdo, $desde, $hasta, $pcs);
    return ['ok' => true, 'desde' => $desde, 'hasta' => $hasta, 'filas' => $n, 'maquinas' => $lista,
            'notas' => $notas['notas'], 'notas_ok' => $notas['ok']];
}

$h = fn(string $s): string => htmlspecialchars($s, ENT_QUOTES, 'UTF-8');
header('Content-Type: text/html; charset=utf-8');
header('X-Frame-Options: SAMEORIGIN');
?>
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>MRV1 · Análisis semanal</title>
<style id="estilos-base">
:root{
  --bg:#f4f6f8; --panel:#ffffff; --texto:#1f2933; --suave:#5f6b7a; --tenue:#8a95a3;
  --borde:#dde3ea; --grid:#e8edf2; --acento:#0f6cbd; --acento-t:#ffffff;
  --ok:rgba(22,163,74,.34); --ok-wifi:rgba(22,163,74,.60); --err:#d92d20; --inc:#9aa4b1; --wifi:#2f6fde; --cable:#7a4cc2; --sinred:#b8c0ca;
  --ev:#2563eb; --ini:#60a5fa; --coin:rgba(245,158,11,.20); --coin-borde:rgba(217,119,6,.6); --verde:#16a34a; --banda-ok:rgba(22,163,74,.09); --banda-ok-borde:rgba(22,163,74,.35);
  --pista:#f8fafc; --sombra:0 1px 2px rgba(16,24,40,.06),0 1px 3px rgba(16,24,40,.08);
  color-scheme:light;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    --bg:#11161c; --panel:#1a2129; --texto:#e6ebf0; --suave:#a9b4c0; --tenue:#7b8794;
    --borde:#2c3642; --grid:#27313c; --acento:#4c9be8; --acento-t:#0b1520;
    --ok:rgba(50,213,131,.26); --ok-wifi:rgba(50,213,131,.48); --err:#f04438; --inc:#5e6a77; --wifi:#5b8def; --cable:#a07ae0; --sinred:#4a5561;
    --ev:#5b8def; --ini:#93b8f5; --coin:rgba(251,191,36,.20); --coin-borde:rgba(251,191,36,.6); --verde:#32d583; --banda-ok:rgba(50,213,131,.08); --banda-ok-borde:rgba(50,213,131,.35);
    --pista:#151b22; --sombra:none; color-scheme:dark;
  }
}
:root[data-theme="dark"]{
  --bg:#11161c; --panel:#1a2129; --texto:#e6ebf0; --suave:#a9b4c0; --tenue:#7b8794;
  --borde:#2c3642; --grid:#27313c; --acento:#4c9be8; --acento-t:#0b1520;
  --ok:rgba(50,213,131,.26); --ok-wifi:rgba(50,213,131,.48); --err:#f04438; --inc:#5e6a77; --wifi:#5b8def; --cable:#a07ae0; --sinred:#4a5561;
  --ev:#5b8def; --ini:#93b8f5; --coin:rgba(251,191,36,.20); --coin-borde:rgba(251,191,36,.6); --verde:#32d583; --banda-ok:rgba(50,213,131,.08); --banda-ok-borde:rgba(50,213,131,.35);
  --pista:#151b22; --sombra:none; color-scheme:dark;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--texto);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,Ubuntu,sans-serif}
button,select,input{font:inherit;color:inherit}
</style>
<style id="estilos-app">
/* --- Inicio de sesión (línea gráfica: ver backend/IA.md sección 10) --- */
:root{--kore:#dc672b;--kore-2:#f08a4b;--lg-vidrio:rgba(255,255,255,.78)}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--lg-vidrio:rgba(26,33,41,.72)}}
:root[data-theme="dark"]{--lg-vidrio:rgba(26,33,41,.72)}
.lg{position:relative;min-height:100vh;min-height:100dvh;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px 16px;overflow:hidden;isolation:isolate}
.lg-fondo{position:absolute;inset:0;z-index:-1;pointer-events:none}
.lg-fondo i{position:absolute;border-radius:50%;filter:blur(70px);opacity:.30}
.lg-o1{width:46vmax;height:46vmax;background:var(--kore);top:-18vmax;right:-14vmax;animation:lgFlota 18s ease-in-out infinite alternate}
.lg-o2{width:40vmax;height:40vmax;background:var(--acento);bottom:-20vmax;left:-14vmax;opacity:.22;animation:lgFlota 22s ease-in-out infinite alternate-reverse}
.lg-fondo .lg-rej{inset:0;border-radius:0;filter:none;opacity:.5;background-image:linear-gradient(var(--grid) 1px,transparent 1px),linear-gradient(90deg,var(--grid) 1px,transparent 1px);background-size:44px 44px;-webkit-mask-image:radial-gradient(ellipse at center,#000 10%,transparent 70%);mask-image:radial-gradient(ellipse at center,#000 10%,transparent 70%)}
@keyframes lgFlota{to{transform:translate(4vmax,3vmax) scale(1.08)}}
.lg-tarjeta{width:100%;max-width:400px;background:var(--lg-vidrio);-webkit-backdrop-filter:blur(18px) saturate(1.3);backdrop-filter:blur(18px) saturate(1.3);border:1px solid var(--borde);border-radius:20px;padding:30px 28px 24px;box-shadow:0 1px 2px rgba(16,24,40,.06),0 24px 60px -20px rgba(16,24,40,.28);animation:lgEntra .55s cubic-bezier(.2,.8,.2,1) both;position:relative}
.lg-tarjeta::before{content:"";position:absolute;left:28px;right:28px;top:-1px;height:3px;border-radius:0 0 4px 4px;background:linear-gradient(90deg,var(--kore),var(--kore-2),var(--acento))}
@keyframes lgEntra{from{opacity:0;transform:translateY(14px) scale(.985)}}
.lg-logo{display:block;width:min(235px,70%);height:auto;margin:0 auto 14px}
.lg-oscuro{display:none}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]) .lg-claro{display:none}:root:not([data-theme="light"]) .lg-oscuro{display:block}}
:root[data-theme="dark"] .lg-claro{display:none}
:root[data-theme="dark"] .lg-oscuro{display:block}
.lg-marca{display:flex;align-items:center;justify-content:center;gap:8px;font-size:11px;font-weight:650;letter-spacing:.16em;text-transform:uppercase;color:var(--suave)}
.lg-punto{width:7px;height:7px;border-radius:50%;background:var(--verde);box-shadow:0 0 0 0 var(--ok);animation:lgPulso 2.4s ease-out infinite}
@keyframes lgPulso{70%{box-shadow:0 0 0 8px transparent}100%{box-shadow:0 0 0 0 transparent}}
.lg-tarjeta h1{margin:10px 0 4px;text-align:center;font-size:26px;line-height:1.15;font-weight:700;letter-spacing:-.02em}
.lg-sub{margin:0 0 22px;text-align:center;color:var(--suave);font-size:13.5px}
.lg-etq{display:block;font-size:12px;font-weight:600;letter-spacing:.04em;color:var(--suave);margin-bottom:6px}
.lg-caja{display:flex;align-items:center;gap:10px;background:var(--panel);border:1px solid var(--borde);border-radius:12px;padding:0 6px 0 12px;color:var(--tenue);transition:border-color .15s,box-shadow .15s,color .15s}
.lg-caja:focus-within{border-color:var(--kore);color:var(--kore);box-shadow:0 0 0 4px rgba(220,103,43,.18)}
.lg-caja.mal{border-color:var(--err);box-shadow:0 0 0 4px rgba(217,45,32,.12);animation:lgSacude .4s}
@keyframes lgSacude{20%,60%{transform:translateX(-5px)}40%,80%{transform:translateX(5px)}}
.lg-caja input{flex:1;min-width:0;border:0;outline:0;background:transparent;padding:13px 0;font-size:15px;letter-spacing:.04em;color:var(--texto)}
.lg-caja input::placeholder{color:var(--tenue)}
.lg-ver{border:0;background:transparent;color:var(--tenue);border-radius:8px;width:34px;height:34px;display:grid;place-items:center;cursor:pointer}
.lg-ver:hover,.lg-ver[aria-pressed="true"]{color:var(--kore)}
.lg-error{margin:8px 2px 0;font-size:13px;color:var(--err);font-weight:550}
.lg-entrar{margin-top:16px;width:100%;display:flex;align-items:center;justify-content:center;gap:8px;border:0;border-radius:12px;padding:13px 16px;font-weight:650;font-size:15px;color:#fff;cursor:pointer;background:linear-gradient(135deg,var(--kore),#c2531a);box-shadow:0 8px 20px -8px rgba(220,103,43,.75);transition:transform .15s,box-shadow .15s,filter .15s}
.lg-entrar svg{transition:transform .2s}
.lg-entrar:hover{filter:brightness(1.07);box-shadow:0 12px 26px -8px rgba(220,103,43,.85)}
.lg-entrar:hover svg{transform:translateX(4px)}
.lg-entrar:active{transform:translateY(1px)}
.lg-entrar:focus-visible,.lg-dl:focus-visible{outline:3px solid var(--acento);outline-offset:2px}
.lg-sep{display:flex;align-items:center;gap:12px;margin:20px 0 16px;color:var(--tenue);font-size:12px}
.lg-sep::before,.lg-sep::after{content:"";flex:1;height:1px;background:var(--borde)}
.lg-descarga{text-align:center}
.lg-descarga p{margin:0 0 10px;color:var(--suave);font-size:13px}
.lg-dl{display:inline-flex;align-items:center;gap:8px;text-decoration:none;color:var(--texto);border:1px solid var(--borde);background:var(--panel);border-radius:12px;padding:10px 16px;font-weight:600;font-size:14px;transition:border-color .15s,transform .15s}
.lg-dl:hover{border-color:#15803d;color:#15803d;transform:translateY(-1px)}
.lg-descarga small{display:block;margin-top:10px;color:var(--tenue);font-size:11.5px;line-height:1.45}
.lg-pie{margin:18px 0 0;font-size:11.5px;letter-spacing:.06em;color:var(--tenue)}
@media (max-width:420px){.lg-tarjeta{padding:26px 20px 20px;border-radius:16px}.lg-tarjeta h1{font-size:23px}}
@media (prefers-reduced-motion: reduce){.lg *,.lg{animation:none!important;transition:none!important}}
.app{max-width:1280px;margin:0 auto;padding:16px}
.barra{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:14px}
.barra h1{font-size:18px;margin:0;font-weight:650;letter-spacing:.2px}
.barra .sub{color:var(--suave);font-size:13px}
.barra .der{margin-left:auto;display:flex;gap:10px;align-items:center}
.barra a{color:var(--suave);font-size:13px}
.descarga{text-align:center}
.btn.descargar-mon{display:block;text-decoration:none;background:#15803d;border-color:#15803d;color:#fff;font-weight:700;letter-spacing:.5px;padding:10px 16px}
.btn.descargar-mon:hover{background:#166534;border-color:#166534}
.aviso{background:#fff7e6;border:1px solid #f5c26b;color:#7a4b00;border-radius:8px;padding:8px 12px;margin-bottom:12px;font-size:13px}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]) .aviso{background:#2b2210;border-color:#6b5217;color:#f3d38b}}
.panel{background:var(--panel);border:1px solid var(--borde);border-radius:10px;box-shadow:var(--sombra);padding:14px 16px;margin-bottom:14px}
.form{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:14px 22px}
.form .bloque{min-width:0}
.form .ancho{grid-column:1/-1}
.etq{display:block;font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.5px;color:var(--suave);margin-bottom:6px}
.fila-ctl{display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.btn{border:1px solid var(--borde);background:var(--panel);border-radius:7px;padding:6px 10px;cursor:pointer;line-height:1.2}
.btn:hover{border-color:var(--acento)}
.btn:disabled{opacity:.5;cursor:default}
.btn.prim{background:var(--acento);border-color:var(--acento);color:var(--acento-t);font-weight:600;padding:8px 16px}
.btn.chico{padding:3px 8px;font-size:12px}
select{border:1px solid var(--borde);background:var(--panel);border-radius:7px;padding:5px 8px}
a.btn{text-decoration:none;color:inherit;display:inline-block}
.pk{position:relative}
.pk-btn{min-width:118px;text-align:left}
.pk-pop{position:absolute;top:100%;left:0;z-index:8;margin-top:4px;width:238px;background:var(--panel);border:1px solid var(--borde);border-radius:8px;box-shadow:0 4px 14px rgba(0,0,0,.2);padding:8px;display:none}
.pk-pop.abierto{display:block}
.pk-cab{display:flex;align-items:center;justify-content:space-between;margin-bottom:6px;font-weight:600;font-size:13px}
.pk-grid{display:grid;grid-template-columns:repeat(7,1fr);gap:2px;text-align:center}
.pk-grid .sem{font-size:11px;color:var(--tenue);padding:2px 0}
.pk-d{position:relative;border:1px solid transparent;background:transparent;color:var(--texto);border-radius:6px;padding:4px 0 8px;font:inherit;font-size:12px;cursor:pointer}
.pk-d:hover{border-color:var(--acento)}
.pk-d.rango{background:color-mix(in srgb,var(--acento) 14%,transparent)}
.pk-d.hoy{border-color:var(--borde);font-weight:700}
.pk-d.sel{background:var(--acento);color:var(--acento-t);font-weight:600}
.pk-d.datos::after{content:"";position:absolute;left:50%;bottom:2px;width:5px;height:5px;margin-left:-2.5px;border-radius:50%;background:var(--verde)}
.semana-txt{font-size:13px;color:var(--suave);margin-top:6px}
.dias{display:flex;gap:6px;flex-wrap:wrap}
.dia-chk{display:flex;flex-direction:column;align-items:center;min-width:48px;border:1px solid var(--borde);border-radius:8px;padding:5px 6px;cursor:pointer;user-select:none;position:relative}
.dia-chk input{position:absolute;opacity:0;pointer-events:none}
.dia-chk .n{font-weight:600;font-size:13px}
.dia-chk .d{font-size:11px;color:var(--suave)}
.dia-chk .pt{width:6px;height:6px;border-radius:50%;background:transparent;margin-top:3px}
.dia-chk.con-datos .pt{background:var(--verde)}
.dia-chk:has(input:checked){border-color:var(--acento);background:color-mix(in srgb,var(--acento) 12%,transparent)}
.dia-chk:has(input:focus-visible){outline:2px solid var(--acento);outline-offset:2px}
.maqs{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:8px}
.maq{position:relative;display:flex;gap:9px;align-items:flex-start;border:1px solid var(--borde);border-radius:8px;padding:8px 26px 8px 10px;cursor:pointer}
.maq:has(input:checked){border-color:var(--acento);background:color-mix(in srgb,var(--acento) 8%,transparent)}
.maq input{margin-top:3px}
.maq .nom{font-weight:600;overflow-wrap:anywhere}
.maq .pc{font-size:12px;color:var(--suave)}
.maq .dests{display:flex;gap:4px;flex-wrap:wrap;margin-top:4px}
.maq-menu-btn{position:absolute;top:3px;right:3px;width:20px;height:20px;padding:0;line-height:1;border:1px solid transparent;background:transparent;color:var(--tenue);border-radius:6px;cursor:pointer;font-size:14px}
.maq-menu-btn:hover{border-color:var(--borde);background:var(--grid);color:var(--suave)}
.maq-menu{position:absolute;top:25px;right:3px;z-index:6;min-width:200px;background:var(--panel);border:1px solid var(--borde);border-radius:8px;box-shadow:0 4px 14px rgba(0,0,0,.2);padding:4px;display:none}
.maq-menu.abierto{display:block}
.maq-menu button{display:block;width:100%;text-align:left;background:transparent;border:0;border-radius:6px;padding:7px 9px;font:inherit;font-size:13px;cursor:pointer;color:var(--texto)}
.maq-menu button:hover{background:var(--grid)}
.maq-menu button.pel{color:var(--err)}
.chip{font-size:11px;border:1px solid var(--borde);border-radius:999px;padding:1px 7px;color:var(--suave);white-space:nowrap}
.chip.err{border-color:color-mix(in srgb,var(--err) 50%,transparent);color:var(--err)}
.vacio{color:var(--suave);font-size:13px;padding:10px 0}
.opciones{display:flex;gap:16px;flex-wrap:wrap;align-items:center}
.opciones label{display:flex;gap:6px;align-items:center;cursor:pointer}
.acciones{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.estado{font-size:13px;color:var(--suave)}
.estado.error{color:var(--err)}
@media (max-width:900px){.form{grid-template-columns:1fr}}
.nota-fab{position:fixed;right:16px;bottom:16px;z-index:50;border:0;border-radius:999px;background:#f59e0b;color:#1f1300;font:inherit;font-weight:700;padding:12px 18px;box-shadow:0 4px 14px rgba(0,0,0,.3);cursor:pointer}
.nota-fondo{position:fixed;inset:0;z-index:100;background:rgba(0,0,0,.5);display:flex;align-items:center;justify-content:center;padding:12px}
.nota-caja{width:min(520px,100%);max-height:94vh;overflow:auto;background:var(--panel);color:var(--texto);border:1px solid var(--borde);border-radius:12px;padding:16px;box-shadow:0 10px 30px rgba(0,0,0,.35)}
.nota-caja h3{margin:0 0 10px;font-size:16px}
.nota-caja label.etq2{display:block;font-size:12px;color:var(--suave);margin:10px 0 4px}
.nota-caja textarea,.nota-caja input[type=date],.nota-caja input[type=time]{width:100%;box-sizing:border-box;font:inherit;font-size:16px;color:var(--texto);background:var(--panel);border:1px solid var(--borde);border-radius:8px;padding:9px 10px;min-height:44px}
.nota-caja textarea{resize:vertical}
.nota-cuando{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.nota-chips{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}
.nota-chips .btn{min-height:36px;padding:6px 12px}
.nota-maqs{display:grid;gap:4px;max-height:150px;overflow:auto;border:1px solid var(--borde);border-radius:8px;padding:6px}
.nota-maqs label{display:flex;gap:8px;align-items:center;min-height:30px}
.nota-pie{display:flex;gap:8px;margin-top:14px;flex-wrap:wrap}
.nota-pie .btn{min-height:44px;padding:8px 16px}
.nota-pie .sep{flex:1}
.nota-err{color:var(--err);font-size:13px;margin-top:8px;min-height:1em}
.nota-caja input[type=text]{width:100%;box-sizing:border-box;font:inherit;font-size:16px;color:var(--texto);background:var(--panel);border:1px solid var(--borde);border-radius:8px;padding:9px 10px;min-height:44px}
.nota-caja .dato{font-size:13px;color:var(--suave);margin:2px 0}
.mr-maq-opc{position:relative;align-self:center}
.mr-maq-opc>button{width:22px;height:22px;padding:0;line-height:1;border:1px solid transparent;background:transparent;color:var(--tenue);border-radius:6px;cursor:pointer;font-size:15px}
.mr-maq-opc>button:hover,.mr-maq-opc.abierto>button{border-color:var(--borde);background:var(--grid);color:var(--texto)}
.mr-maq-opc>button:focus-visible{outline:2px solid var(--acento);outline-offset:1px}
.mr-maq-opc .mr-menu{position:absolute;top:26px;left:0;z-index:8;min-width:170px;background:var(--panel);border:1px solid var(--borde);border-radius:8px;box-shadow:0 4px 14px rgba(0,0,0,.25);padding:4px;display:none}
.mr-maq-opc.abierto .mr-menu{display:block}
.mr-menu button{display:block;width:100%;text-align:left;background:transparent;border:0;border-radius:6px;padding:7px 9px;font:inherit;font-size:13px;font-weight:400;cursor:pointer;color:var(--texto)}
.mr-menu button:hover{background:var(--grid)}
.reg-caja{width:min(940px,100%)}
.reg-cab{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:6px}
.reg-cab h3{margin:0;flex:1;min-width:200px}
.reg-cab .btn{min-height:34px;padding:4px 10px}
.reg-sub{font-size:13px;color:var(--suave);margin-bottom:8px}
.reg-filtros{display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin-bottom:8px}
.reg-filtros select{font:inherit;font-size:13px;color:var(--texto);background:var(--panel);border:1px solid var(--borde);border-radius:8px;padding:4px 8px}
.reg-f{border:1px solid var(--borde);background:transparent;color:var(--suave);border-radius:999px;padding:3px 11px;font:inherit;font-size:12px;cursor:pointer}
.reg-f[aria-pressed=true]{color:var(--acento-t);background:var(--acento);border-color:var(--acento);font-weight:600}
.reg-tabla{max-height:min(55vh,460px);overflow:auto;border:1px solid var(--borde);border-radius:10px}
.reg-tabla table{border-collapse:collapse;width:100%;font-size:13px}
.reg-tabla th,.reg-tabla td{text-align:left;padding:5px 10px;border-bottom:1px solid var(--grid);vertical-align:top}
.reg-tabla th{position:sticky;top:0;background:var(--panel);color:var(--tenue);font-size:11px;letter-spacing:.06em;text-transform:uppercase;box-shadow:0 1px 0 var(--borde)}
.reg-tabla td.n,.reg-tabla th.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.reg-tabla td.h{white-space:nowrap;font-variant-numeric:tabular-nums;color:var(--suave)}
.reg-tabla td.m{overflow-wrap:anywhere;min-width:200px}
.reg-tabla .t-OK{color:var(--verde);font-weight:600}.reg-tabla .t-ERROR{color:var(--err);font-weight:600}.reg-tabla .t-EVENTO{color:#d97706;font-weight:600}.reg-tabla .t-INICIO{color:var(--ev);font-weight:600}.reg-tabla .t-inc{color:var(--tenue)}
.reg-tabla .vacio{text-align:center;padding:22px 8px}
.reg-nota{font-size:12px;color:var(--tenue);margin-top:8px}
</style>
<style id="estilos-reporte">
.mr{--col-lbl:170px;--col-tot:118px;position:relative}
.mr-cab{display:flex;flex-wrap:wrap;gap:6px 18px;align-items:baseline;margin-bottom:10px}
.mr-cab h2{margin:0;font-size:17px;font-weight:650}
.mr-cab .meta{color:var(--suave);font-size:13px}
.mr-ley{display:flex;flex-wrap:wrap;gap:6px 14px;font-size:12px;color:var(--suave);margin:0 0 12px}
.mr-ley span{display:inline-flex;align-items:center;gap:5px}
.mr-ley i{display:inline-block;width:18px;height:9px;border-radius:2px}
.mr-ley i.tk{width:3px;height:12px}
.mr-dia{background:var(--panel);border:1px solid var(--borde);border-radius:10px;padding:10px 12px 8px;margin-bottom:12px;box-shadow:var(--sombra)}
.mr-dia.vacio-dia{padding-bottom:4px;box-shadow:none;opacity:.75}
.mr-dia.vacio-dia .mr-dia-cab{margin-bottom:6px}
.mr-dia-cab{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:6px}
.mr-dia-cab h3{margin:0;font-size:15px;font-weight:650}
.mr-badge{font-size:12px;border-radius:999px;padding:2px 9px;border:1px solid var(--borde);color:var(--suave)}
.mr-badge.ok{border-color:var(--banda-ok-borde);color:var(--verde);font-weight:600}
.mr-badge.coin{border-color:var(--coin-borde);color:var(--coin-borde);font-weight:600}
.mr-badge.err{border-color:color-mix(in srgb,var(--err) 45%,transparent);color:var(--err);font-weight:600}
.mr-fila{display:grid;grid-template-columns:var(--col-lbl) minmax(0,1fr) var(--col-tot);align-items:center;min-height:20px}
.mr-eje{font-size:11px;color:var(--tenue);height:18px}
.mr-eje .mr-pista{background:none;box-shadow:none;height:18px;overflow:visible}
.mr-eje .tick{position:absolute;top:2px;transform:translateX(-50%);white-space:nowrap}
.mr-eje .tick.pri{transform:none}.mr-eje .tick.ult{transform:translateX(-100%)}
.mr-eje .tot{text-align:right;font-size:11px;padding-right:2px}
.mr-maq{border-top:1px solid var(--borde);padding:5px 0 4px}
.mr-maq-nom{font-weight:600;font-size:13px;display:flex;gap:8px;align-items:baseline;flex-wrap:wrap;padding:0 0 2px}
.mr-maq-nom small{font-weight:400;color:var(--suave);font-size:11px}
.mr-maq-nom small.ok{color:var(--verde);font-weight:600}
.ver{display:inline-block;font-size:10.5px;font-weight:600;line-height:1.5;padding:0 6px;border:1px solid var(--borde);border-radius:999px;color:var(--tenue);vertical-align:middle;cursor:help;white-space:nowrap}
.ver.vieja{color:var(--warn,#d97706);border-color:var(--warn,#d97706)}
.ver.falla{color:var(--err);border-color:var(--err)}

.mr-lbl{font-size:12px;color:var(--suave);padding-left:10px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mr-pista{position:relative;height:16px;background:transparent;box-shadow:inset 0 0 0 1px var(--grid);border-radius:3px;overflow:hidden}
.mr-cuerpo{position:relative}
.mr-cuerpo>.mr-fila,.mr-cuerpo>.mr-maq{position:relative;z-index:1}
.mr-coin-capa{position:absolute;top:0;bottom:0;left:var(--col-lbl);right:var(--col-tot);z-index:0;pointer-events:none}
.mr-coin{position:absolute;top:0;bottom:0;min-width:2px;background:var(--coin);border-left:1px solid var(--coin-borde);border-right:1px solid var(--coin-borde)}
.mr-eje .mr-coin-tk{position:absolute;bottom:-2px;height:6px;min-width:4px;background:var(--coin-borde);border-radius:2px;z-index:2;cursor:help}
.mr-ipfila{min-height:16px;margin-bottom:2px}
.mr-pista-ip{position:relative;height:14px}
.mr-ip{position:absolute;top:0;bottom:0;box-sizing:border-box;border:1px solid var(--borde);border-radius:3px;font-size:10px;line-height:12px;text-align:center;color:var(--tenue);white-space:nowrap;overflow:hidden;text-overflow:clip;cursor:help;direction:rtl}
.mr-ip span{direction:ltr;unicode-bidi:isolate;display:inline-block}
.mr-hora{position:absolute;top:0;bottom:0;width:1px;background:var(--grid)}
.mr-seg{position:absolute;top:0;bottom:0}
.mr-seg.ok{background:var(--ok)}
.mr-seg.err{background:var(--err);min-width:2px;z-index:2}
.mr-seg.abierto{opacity:.45}
.mr-seg.ok.wifi{background:repeating-linear-gradient(135deg,var(--ok-wifi) 0 3px,transparent 3px 6px)}
.mr-seg.err.wifi{background:repeating-linear-gradient(135deg,var(--err) 0 3px,color-mix(in srgb,var(--err) 35%,transparent) 3px 6px)}
.mr-redes{display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin-left:auto;font-size:12px;color:var(--suave)}
.mr-red-btn{font:inherit;border:1px solid var(--borde);background:transparent;color:var(--suave);border-radius:999px;padding:3px 11px;cursor:pointer}
.mr-red-btn.on{border-color:var(--acento);background:color-mix(in srgb,var(--acento) 16%,transparent);color:var(--texto);font-weight:600}
.mr-red-btn:focus-visible{outline:2px solid var(--acento);outline-offset:2px}
.mr-red-nota{color:var(--tenue)}
.mr-marca{position:absolute;top:-1px;bottom:-1px;width:2px;margin-left:-1px;z-index:3}
.mr-marca.ev{background:var(--ev)}
.mr-marca.ini{background:var(--ini)}
.mr-marca.nota{background:var(--nota,#f59e0b);opacity:.85}
.mr-pista.con-nota{overflow:visible}
.mr-fila-nota{margin-top:11px}
.mr-pista.anotable{-webkit-touch-callout:none}
.mr-marca.nota .bandera{position:absolute;left:-1px;bottom:100%;margin-bottom:-1px;font-style:normal;font-size:15px;line-height:1;color:var(--nota,#f59e0b);cursor:help;padding:0 3px 0 0}
.mr-marca.nota .bandera.edit{cursor:pointer}
.mr-nodata{position:absolute;inset:0;display:flex;align-items:center;padding-left:8px;font-size:11px;color:var(--tenue)}
.mr-tot{text-align:right;font-size:12px;font-variant-numeric:tabular-nums;padding-left:6px;white-space:nowrap}
.mr-tot.cero{color:var(--tenue)}
.mr-tot.hay{color:var(--err);font-weight:600}
.mr-tot small{font-weight:400;color:var(--suave)}
.mr-res{background:var(--panel);border:1px solid var(--borde);border-radius:10px;padding:10px 12px;box-shadow:var(--sombra);overflow-x:auto}
.mr-res h3{margin:0 0 8px;font-size:15px}
.mr-res table{border-collapse:collapse;width:100%;font-size:12px;font-variant-numeric:tabular-nums}
.mr-res th,.mr-res td{padding:5px 8px;border-bottom:1px solid var(--borde);text-align:right;white-space:nowrap}
.mr-res th:nth-child(-n+2),.mr-res td:nth-child(-n+2){text-align:left}
.mr-res th{font-weight:600;color:var(--suave);font-size:11px;text-transform:uppercase;letter-spacing:.3px}
.mr-res td.cero{color:var(--tenue)}
.mr-res td.hay{color:var(--err)}
.mr-res td.tot{font-weight:650}
.mr-res tr.grupo td{border-top:1px solid var(--borde)}
.mr-tip{position:fixed;z-index:50;pointer-events:none;background:var(--texto);color:var(--panel);font-size:12px;line-height:1.4;padding:6px 9px;border-radius:6px;max-width:340px;white-space:pre-line;box-shadow:0 4px 14px rgba(0,0,0,.25);display:none}
.mr-pie{color:var(--tenue);font-size:11px;margin-top:10px}
@media (max-width:700px){.mr{--col-lbl:92px;--col-tot:76px}.mr-eje .tick.sec{display:none}.mr-eje .tick{font-size:10px}.mr-eje .tot{font-size:0}.mr-eje .tot::after{content:'Desc.';font-size:10px}}
@media (max-width:480px){.mr-eje .tick.ter{display:none}.mr-lbl{padding-left:4px}.mr-tot small{display:none}}
@media print{.mr-dia,.mr-res{box-shadow:none;break-inside:avoid}}
</style>
</head>
<body>
<?php if (!$autenticado): ?>
<main class="lg">
  <div class="lg-fondo" aria-hidden="true"><i class="lg-o1"></i><i class="lg-o2"></i><i class="lg-rej"></i></div>
  <section class="lg-tarjeta">
    <img class="lg-logo lg-claro" src="assets/kore_sula_claro.svg" alt="Kore-Sula" width="235" height="85">
    <img class="lg-logo lg-oscuro" src="assets/kore_sula_oscuro.svg" alt="" width="235" height="85" aria-hidden="true">
    <div class="lg-marca"><span class="lg-punto"></span>Monitor de Red · MRV1</div>
    <h1>Análisis semanal</h1>
    <p class="lg-sub">Ingrese la clave de acceso para consultar los reportes de conectividad.</p>
    <form method="post" autocomplete="off" class="lg-form">
      <label class="lg-campo">
        <span class="lg-etq">Clave de acceso</span>
        <span class="lg-caja<?= $errorLogin !== '' ? ' mal' : '' ?>">
          <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="10.5" width="16" height="10" rx="2.5"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/></svg>
          <input type="password" name="clave" id="lgClave" required autofocus placeholder="••••••••" autocomplete="current-password">
          <button type="button" class="lg-ver" id="lgVer" aria-label="Mostrar u ocultar la clave" aria-pressed="false">
            <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>
          </button>
        </span>
      </label>
      <?php if ($errorLogin !== ''): ?><p class="lg-error" role="alert"><?= $h($errorLogin) ?></p><?php endif; ?>
      <button class="lg-entrar" type="submit"><span>Entrar</span><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6"/></svg></button>
    </form>
    <div class="lg-sep"><span>o</span></div>
    <div class="lg-descarga">
      <p>¿Solo necesita instalar el monitor en una PC?</p>
      <a class="lg-dl" href="<?= $h(MR_URL_PAQUETE) ?>" rel="noopener">
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11M7 11l5 5 5-5M5 20h14"/></svg>
        Descargar el monitor
      </a>
      <small>Paquete MRV1 (ZIP desde GitHub). Descomprima y ejecute <code>Instalar_Monitor.bat</code> como administrador.</small>
    </div>
  </section>
  <p class="lg-pie">Kore-Sula · Soluciones Nicaragua</p>
</main>
<script>
(function () {
  var b = document.getElementById('lgVer'), i = document.getElementById('lgClave');
  if (!b || !i) return;
  b.addEventListener('click', function () {
    var ver = i.type === 'password';
    i.type = ver ? 'text' : 'password';
    b.setAttribute('aria-pressed', ver ? 'true' : 'false');
    i.focus();
  });
})();
</script>
<?php else: ?>
<div class="app">
  <div class="barra">
    <h1>Monitor de Red · Análisis semanal</h1>
    <span class="sub">Caídas de conectividad por máquina y destino</span>
    <div class="der"><a href="zombie.php" title="Configuración remota de las PC (zombie.php)">⚙ Configuración remota</a><a href="<?= $h(MR_URL_PAQUETE) ?>" rel="noopener" title="Paquete MRV1 (ZIP desde GitHub)">⬇ Descargar el monitor</a><?php if ($requiereLog): ?><a href="?salir=1">Cerrar sesión</a><?php endif; ?></div>
  </div>
  <?php if (!$requiereLog): ?>
  <div class="aviso">Acceso sin clave: cualquiera que abra esta dirección puede ver los registros. Para protegerla, agregue <code>'reporte' => ['clave' => '…']</code> en <code>config/config.php</code>.</div>
  <?php endif; ?>

  <div class="panel">
    <div class="form">
      <div class="bloque">
        <span class="etq">Rango de fechas</span>
        <div class="fila-ctl">
          <span class="estado">Desde</span><div class="pk" id="pkDesde"></div>
          <span class="estado">Hasta</span><div class="pk" id="pkHasta"></div>
        </div>
        <div class="fila-ctl" style="margin-top:6px">
          <button class="btn" id="semAnt" type="button" title="Retroceder 7 días" aria-label="Retroceder 7 días">◀</button>
          <button class="btn" id="semSig" type="button" title="Avanzar 7 días" aria-label="Avanzar 7 días">▶</button>
          <button class="btn chico" id="semPas" type="button">Semana anterior</button>
          <button class="btn chico" id="semHoy" type="button">Esta semana</button>
        </div>
        <div class="semana-txt" id="semTxt"></div>
      </div>
      <div class="bloque">
        <span class="etq">Días</span>
        <div class="dias" id="dias"></div>
      </div>
      <div class="bloque">
        <span class="etq">Horario (eje horizontal)</span>
        <div class="fila-ctl">
          <select id="horaIni" aria-label="Desde"></select>
          <span class="estado">a</span>
          <select id="horaFin" aria-label="Hasta"></select>
          <button class="btn chico" id="horaJornada" type="button" title="7:00 a 15:00">Jornada</button>
          <button class="btn chico" id="horaDia" type="button" title="00:00 a 24:00">Día completo</button>
        </div>
      </div>
      <div class="bloque ancho">
        <span class="etq" style="display:flex;gap:10px;align-items:center">Máquinas con registros en el rango
          <span style="margin-left:auto;display:flex;gap:6px;text-transform:none;letter-spacing:0;font-weight:400">
            <button class="btn chico" id="maqTodas" type="button">Todas</button>
            <button class="btn chico" id="maqNinguna" type="button">Ninguna</button>
          </span>
        </span>
        <div class="maqs" id="maqs" data-csrf="<?= $h($csrf) ?>" data-puede-eliminar="<?= $requiereLog ? '1' : '0' ?>"><div class="vacio">Cargando…</div></div>
      </div>
      <div class="bloque ancho">
        <div class="opciones">
          <label><input type="checkbox" id="optCoin" checked> Marcar coincidencias (2+ máquinas caídas a la vez)</label>
          <label><input type="checkbox" id="optEventos" checked> Mostrar eventos e inicios</label>
          <label><input type="checkbox" id="optVacias" checked> Incluir días sin registros</label>
        </div>
      </div>
      <div class="bloque ancho acciones">
        <button class="btn prim" id="generar" type="button">Generar gráfico</button>
        <button class="btn" id="descargar" type="button" disabled>Descargar HTML</button>
        <span class="estado" id="estado"></span>
      </div>
    </div>
  </div>

  <div id="reporte"></div>
</div>

<script id="motor">
/* Motor del gráfico de análisis MRV1. Autocontenido: se reutiliza tal cual
   dentro del HTML descargable (ver descargar() en la app). */
(function () {
  'use strict';
  var DIAS = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];
  var MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

  function pad(n) { return String(n).padStart(2, '0'); }
  function secs(h) { var p = h.split(':'); return (+p[0]) * 3600 + (+p[1]) * 60 + (+p[2] || 0); }
  function hhmm(s) { s = Math.round(s); return s >= 86400 ? '24:00' : pad(Math.floor(s / 3600)) + ':' + pad(Math.floor(s % 3600 / 60)); }
  function hhmmss(s) { s = Math.round(s); return s >= 86400 ? '24:00:00' : hhmm(s) + ':' + pad(s % 60); }
  function dur(s) { s = Math.round(s); return pad(Math.floor(s / 3600)) + ':' + pad(Math.floor(s % 3600 / 60)) + ':' + pad(s % 60); }
  function durTexto(s) {
    s = Math.round(s);
    if (s < 60) return s + ' s';
    var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60;
    if (h) return h + ' h ' + m + ' min';
    return m + ' min' + (x ? ' ' + x + ' s' : '');
  }
  function parseISO(s) { var p = s.split('-'); return new Date(Date.UTC(+p[0], p[1] - 1, +p[2])); }
  function diaSemana(iso) { return (parseISO(iso).getUTCDay() + 6) % 7; }
  function fechaLarga(iso) { var d = parseISO(iso); return DIAS[diaSemana(iso)] + ' ' + d.getUTCDate() + ' ' + MESES[d.getUTCMonth()] + ' ' + d.getUTCFullYear(); }
  function fechaCorta(iso) { var d = parseISO(iso); return DIAS[diaSemana(iso)].slice(0, 3) + ' ' + d.getUTCDate() + ' ' + MESES[d.getUTCMonth()]; }

  function el(tag, cls, txt) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (txt != null) e.textContent = txt;
    return e;
  }

  /* Etiqueta con la versión de scripts confirmada por la PC (actualizar.php). v = { v, estado, resultado, detalle, en, publicada } */
  function verBadge(v) {
    if (!v || !v.v) return null;
    var b = el('span', 'ver' + (v.estado === 'vieja' ? ' vieja' : v.estado === 'falla' ? ' falla' : ''), 'v' + v.v);
    var t = 'Versión de los scripts confirmada por la PC: ' + v.v + (v.en ? '\n' + v.en : '');
    if (v.estado === 'vieja') t += '\nHay una versión más nueva publicada: ' + v.publicada;
    if (v.estado === 'falla') t += '\nLa última actualización falló' + (v.resultado ? ' (' + v.resultado + ')' : '') + (v.detalle ? ': ' + v.detalle : '');
    b.title = t;
    return b;
  }

  function tipoAdaptador(nombre) {
    if (!nombre) return null;
    if (/wi-?fi|wlan|wireless|inal[aá]mbric/i.test(nombre)) return 'wifi';
    if (/sin adaptador|sin red|ninguno|desconocid/i.test(nombre)) return 'otro';
    return 'cable';
  }

  /* Convierte las filas de un destino en un día en segmentos y marcas.
     fila = [fecha, hora, tipo, tiempo_s, latencia_ms, mensaje] */
  function segmentosDia(filas, fecha, ahora) {
    var segs = [], marcas = [];
    for (var i = 0; i < filas.length; i++) {
      var f = filas[i], s = secs(f[1]), tipo = f[2], msg = f[5] || '';
      if (tipo === 'INICIO' || tipo === 'EVENTO') { marcas.push({ s: s, tipo: tipo, msg: msg }); continue; }
      // siguiente fila que abre un estado o una sesión nueva (limita la duración)
      var sig = null;
      for (var j = i + 1; j < filas.length; j++) {
        if (filas[j][2] !== 'EVENTO') { sig = secs(filas[j][1]); break; }
      }
      var t = f[3];
      if (t !== null && t !== undefined) {
        var b = s + t;
        if (sig !== null && b > sig) b = sig;
        if (b > 86400) b = 86400;
        segs.push({ a: s, b: b, tipo: tipo, lat: f[4], msg: msg });
      } else if (sig === null && ahora && fecha === ahora.fecha && ahora.s > s) {
        segs.push({ a: s, b: ahora.s, tipo: tipo, abierto: true, msg: msg });
      } else if (sig !== null) {
        segs.push({ a: s, b: sig, tipo: 'INC', orig: tipo, msg: msg });
      } else {
        marcas.push({ s: s, tipo: 'INCOMPLETO', msg: msg + ' (sin cierre)' });
      }
    }
    return { segs: segs, marcas: marcas };
  }

  /* Tramos de adaptador (Wi-Fi / cable) de una máquina en un día, recortados a
     los intervalos donde hubo datos de algún destino. */
  function adaptadoresDia(filasPc, cobertura) {
    var cambios = [];
    filasPc.forEach(function (f) {
      var msg = f[5] || '', nombre = null;
      if (f[2] === 'INICIO') {
        var p = msg.split(' - ');
        if (p.length >= 3) nombre = p[2].trim();
      } else if (f[2] === 'EVENTO') {
        var m = /^Cambio de adaptador:\s*(.*?)\s*->\s*(.*)$/i.exec(msg);
        if (m) nombre = m[2].split(' - ')[0].trim();
      }
      if (nombre) cambios.push({ s: secs(f[1]), nombre: nombre });
    });
    cambios.sort(function (x, y) { return x.s - y.s; });
    var tramos = [];
    for (var i = 0; i < cambios.length; i++) {
      var a = cambios[i].s, b = i + 1 < cambios.length ? cambios[i + 1].s : 86400;
      if (b <= a) continue;
      var ult = tramos[tramos.length - 1];
      if (ult && ult.nombre === cambios[i].nombre && ult.b === a) { ult.b = b; continue; }
      tramos.push({ a: a, b: b, nombre: cambios[i].nombre, tipo: tipoAdaptador(cambios[i].nombre) });
    }
    var res = [];
    tramos.forEach(function (t) {
      cobertura.forEach(function (c) {
        var a = Math.max(t.a, c.a), b = Math.min(t.b, c.b);
        if (b > a) res.push({ a: a, b: b, nombre: t.nombre, tipo: t.tipo });
      });
    });
    return res.sort(function (x, y) { return x.a - y.a; });
  }

  /* IP que declara una fila del registro: { ip, antes } o null. Solo se miran los eventos que de verdad
     traen la IP de la máquina (INICIO, cambio de IP, cambio de adaptador); el resto de mensajes puede
     citar IP de destinos y no sirve. "antes" es la IP anterior cuando el propio evento la indica. */
  var RX_IP = /\b\d{1,3}(?:\.\d{1,3}){3}\b/g;
  function ipDeFila(f) {
    var msg = f[5] || '', m, r;
    function ultima(txt) { var x = txt.match(RX_IP); return x ? x[x.length - 1] : null; }
    if (f[2] === 'INICIO') { m = msg.match(RX_IP); return m ? { ip: m[0], antes: null } : null; }
    if (f[2] !== 'EVENTO') return null;
    m = /^Cambio de direcci[oó]n IP:\s*(.*?)\s*->\s*(.*)$/i.exec(msg);
    if (m) { var n = ultima(m[2]); if (!n) return null; r = m[1].match(RX_IP); return { ip: n, antes: r ? r[0] : null }; }
    m = /^Cambio de adaptador:\s*.*?->\s*(.*)$/i.exec(msg);
    if (m) { var n2 = ultima(m[1]); return n2 ? { ip: n2, antes: null } : null; }
    return null;
  }

  /* Tramos de IP de una máquina en un día. Orden de prioridad para saber en qué IP se observa:
     1) lo que dicen los registros del propio día (INICIO / cambio de IP / cambio de adaptador, y la IP
        anterior que indica un "A -> B");
     2) si el día no trae ninguno, la última IP conocida de días anteriores ("previa").
     El primer tramo arranca en el primer registro del día y el último llega hasta el final de la cobertura. */
  function ipsDia(filasPc, cobertura, previa) {
    var cambios = [], desde = null, hasta = 0;
    filasPc.forEach(function (f) {
      var s = secs(f[1]), d = ipDeFila(f);
      if (desde === null || s < desde) desde = s;
      if (d) cambios.push({ s: s, ip: d.ip, antes: d.antes });
    });
    cobertura.forEach(function (c) { if (c.b > hasta) hasta = c.b; });
    if (desde === null) return [];
    cambios.sort(function (x, y) { return x.s - y.s; });
    var tramos = [];
    function poner(a, b, ip) {
      var u = tramos[tramos.length - 1];
      if (u && u.ip === ip) { u.b = Math.max(u.b, b); return; }
      if (b > a) tramos.push({ a: a, b: b, ip: ip });
    }
    if (!cambios.length) {
      if (!previa) return [];
      poner(desde, Math.max(hasta, desde), previa);
      return tramos;
    }
    var fin = Math.max(hasta, cambios[cambios.length - 1].s);
    var inicial = cambios[0].antes || previa || cambios[0].ip;
    if (cambios[0].s > desde) poner(desde, cambios[0].s, inicial);
    cambios.forEach(function (c, i) {
      var a = (i === 0 && cambios[0].s <= desde) ? Math.min(desde, c.s) : c.s;
      poner(a, i + 1 < cambios.length ? cambios[i + 1].s : fin, c.ip);
    });
    return tramos;
  }

  function unir(intervalos) {
    var v = intervalos.slice().sort(function (x, y) { return x.a - y.a; }), r = [];
    v.forEach(function (i) {
      var u = r[r.length - 1];
      if (u && i.a <= u.b) u.b = Math.max(u.b, i.b); else r.push({ a: i.a, b: i.b });
    });
    return r;
  }

  /* Prepara todo lo necesario para dibujar: por día → máquina → destino. */
  function preparar(datos, opc) {
    var ahora = opc.ahora || null, ini = opc.ini, fin = opc.fin, redes = opc.redes;
    var porDia = {};
    opc.dias.forEach(function (d) { porDia[d] = { fecha: d, maquinas: [], errTotal: 0, caidas: 0, oculto: 0, hayDatos: false }; });

    datos.maquinas.forEach(function (m) {
      var filasPorDia = {}, histIp = [];
      m.destinos.forEach(function (de) {
        de.filas.forEach(function (f) {
          var di = ipDeFila(f);
          if (di) histIp.push({ k: f[0] + ' ' + f[1], f: f[0], ip: di.ip });
          if (!porDia[f[0]]) return;
          var fd = filasPorDia[f[0]] || (filasPorDia[f[0]] = {});
          (fd[de.destino] || (fd[de.destino] = [])).push(f);
        });
      });
      histIp.sort(function (x, y) { return x.k < y.k ? -1 : x.k > y.k ? 1 : 0; });
      opc.dias.forEach(function (d) {
        var dia = porDia[d], fd = filasPorDia[d] || {};
        var previa = m.ip_previa || null;   // última IP conocida antes del rango (la entrega la API)
        for (var hi = 0; hi < histIp.length && histIp[hi].f < d; hi++) previa = histIp[hi].ip;
        var maq = { pc: m.pc, alias: m.alias, version: m.version || null, destinos: [], adapt: [], hayDatos: false, caidas: 0, completa: false };
        var todas = [], cobertura = [], crudos = [];
        m.destinos.forEach(function (de) {
          var filas = fd[de.destino] || [];
          var r = segmentosDia(filas, d, ahora);
          r.segs.forEach(function (sg) { cobertura.push({ a: sg.a, b: sg.b }); });
          filas.forEach(function (f) { todas.push(f); });
          crudos.push({ destino: de.destino, filas: filas, r: r });
        });
        maq.adapt = adaptadoresDia(todas, unir(cobertura));
        maq.ips = ipsDia(todas, cobertura, previa);
        maq.notas = ((datos.notas && datos.notas[m.pc]) || []).filter(function (n) { return n[1] === d; }).map(function (n) {
          return { id: n[0], fecha: n[1], hora: n[2], s: secs(n[2]), texto: n[3], pc: m.pc, alias: m.alias };
        });
        var completa = crudos.length > 0;
        crudos.forEach(function (c) {
          var piezas = [], err = 0, ok = 0, oculto = 0, cuentan = {}, cubierto = [];
          c.r.segs.forEach(function (sg, idx) {
            partirPorRed(sg, maq.adapt).forEach(function (pz) {
              pz.idx = idx;
              pz.visible = redVisible(pz.red, redes);
              piezas.push(pz);
              var a = Math.max(pz.a, ini), b = Math.min(pz.b, fin);
              if (b <= a || pz.tipo === 'INC') return;
              if (!pz.visible) { oculto += b - a; return; }
              if (pz.abierto) return;
              cubierto.push({ a: a, b: b });
              if (pz.tipo === 'ERROR') { err += b - a; cuentan[idx] = true; }
              else if (pz.tipo === 'OK') ok += b - a;
            });
          });
          var caidas = Object.keys(cuentan).length;
          var tieneDatos = c.filas.length > 0;
          var visibles = piezas.some(function (pz) { return pz.visible && pz.tipo !== 'INC'; });
          var cub = unir(cubierto).reduce(function (t, x) { return t + x.b - x.a; }, 0);
          if (!(tieneDatos && caidas === 0 && cub >= (fin - ini) - HOLGURA)) completa = false;
          if (tieneDatos) maq.hayDatos = true;
          maq.caidas += caidas;
          maq.destinos.push({ destino: c.destino, segs: piezas, marcas: c.r.marcas, err: err, ok: ok, caidas: caidas,
            hayDatos: tieneDatos, oculto: oculto, soloOculto: tieneDatos && !visibles && oculto > 0 });
          dia.errTotal += err; dia.caidas += caidas; dia.oculto += oculto;
        });
        maq.completa = completa;
        if (maq.hayDatos) dia.hayDatos = true;
        dia.maquinas.push(maq);
      });
    });
    return opc.dias.map(function (d) { var x = porDia[d]; x.coin = coincidencias(x.maquinas, ini, fin); return x; });
  }

  /* Margen para considerar que un destino tuvo registros durante TODO el horario
     (arranque del monitor unos segundos después de la hora de inicio, etc.). */
  var HOLGURA = 60;

  function redVisible(red, redes) {
    if (red === 'wifi') return !!redes.wifi;
    if (red === 'cable') return !!redes.cable;
    return true; // red desconocida: siempre visible
  }

  /* Parte un segmento según los tramos de adaptador (Wi-Fi / cable) de la máquina. */
  function partirPorRed(sg, tramos) {
    var out = [], cur = sg.a;
    function pieza(a, b, red) {
      if (b <= a) return;
      var p = {}; for (var k in sg) p[k] = sg[k];
      p.a = a; p.b = b; p.red = red; out.push(p);
    }
    tramos.forEach(function (t) {
      if (t.b <= cur || t.a >= sg.b) return;
      if (t.a > cur) pieza(cur, t.a, null);
      var b = Math.min(t.b, sg.b);
      pieza(Math.max(t.a, cur), b, t.tipo === 'wifi' || t.tipo === 'cable' ? t.tipo : null);
      cur = b;
    });
    pieza(cur, sg.b, null);
    if (!out.length) pieza(sg.a, sg.b, null);
    return out;
  }

  function adaptadorEn(tramos, s) {
    for (var i = 0; i < tramos.length; i++) if (tramos[i].a <= s && s < tramos[i].b) return tramos[i];
    return null;
  }

  /* Coincidencias: tramos donde 2 o más máquinas distintas están sin conexión a la
     vez (cualquiera de sus destinos). Tolerancia TOL s a cada lado, porque cada
     monitor hace ping con su propio intervalo y reloj. */
  var TOL = 5;
  function coincidencias(maquinas, ini, fin) {
    var ev = [];
    maquinas.forEach(function (m, mi) {
      var iv = [];
      m.destinos.forEach(function (de) {
        de.segs.forEach(function (sg) {
          if (sg.tipo !== 'ERROR' || !sg.visible) return;
          var a = Math.max(sg.a - TOL, ini), b = Math.min(sg.b + TOL, fin);
          if (b > a) iv.push({ a: a, b: b });
        });
      });
      unir(iv).forEach(function (x) { ev.push({ t: x.a, d: 1, m: mi }); ev.push({ t: x.b, d: -1, m: mi }); });
    });
    ev.sort(function (x, y) { return x.t - y.t || x.d - y.d; });
    var activas = {}, n = 0, res = [], abierto = null;
    ev.forEach(function (e) {
      if (e.d > 0) { activas[e.m] = (activas[e.m] || 0) + 1; if (activas[e.m] === 1) n++; }
      else { activas[e.m]--; if (activas[e.m] === 0) n--; }
      if (n >= 2 && !abierto) abierto = { a: e.t, set: {} };
      if (abierto) Object.keys(activas).forEach(function (k) { if (activas[k] > 0) abierto.set[k] = true; });
      if (n < 2 && abierto) { if (e.t > abierto.a) { abierto.b = e.t; res.push(abierto); } abierto = null; }
    });
    return res.map(function (c) {
      return { a: c.a, b: c.b, maquinas: Object.keys(c.set).map(function (k) { var m = maquinas[k]; return m.alias || m.pc; }) };
    });
  }

  function pct(s, ini, fin) { return ((s - ini) / (fin - ini) * 100); }

  function pista(ini, fin) {
    var p = el('div', 'mr-pista');
    var paso = (fin - ini) > 12 * 3600 ? 7200 : 3600;
    for (var h = Math.ceil(ini / paso) * paso; h < fin; h += paso) {
      if (h <= ini) continue;
      var g = el('div', 'mr-hora'); g.style.left = pct(h, ini, fin) + '%'; p.appendChild(g);
    }
    return p;
  }

  function colocar(nodo, a, b, ini, fin) {
    var x = Math.max(a, ini), y = Math.min(b, fin);
    if (y <= x) return false;
    nodo.style.left = pct(x, ini, fin) + '%';
    nodo.style.width = ((y - x) / (fin - ini) * 100) + '%';
    return true;
  }

  function filaEje(ini, fin) {
    var f = el('div', 'mr-fila mr-eje');
    f.appendChild(el('div'));
    var p = el('div', 'mr-pista');
    var paso = (fin - ini) > 12 * 3600 ? 7200 : 3600;
    var marcas = [ini];
    for (var h = Math.ceil(ini / paso) * paso; h < fin; h += paso) if (h > ini) marcas.push(h);
    if (fin - marcas[marcas.length - 1] >= paso / 2) marcas.push(fin); else marcas[marcas.length - 1] = fin;
    marcas.forEach(function (h, i) {
      var ult = i === marcas.length - 1;
      var t = el('span', 'tick' + (i === 0 ? ' pri' : '') + (ult ? ' ult' : '') + (i % 2 === 1 && !ult ? ' sec' : '') + (i % 4 !== 0 && !ult ? ' ter' : ''), hhmm(h));
      t.style.left = pct(h, ini, fin) + '%'; p.appendChild(t);
    });
    f.appendChild(p);
    f.appendChild(el('div', 'tot', 'Desconectado'));
    return f;
  }

  var NOMBRE_TIPO = { OK: 'Conectado', ERROR: 'Sin conexión', INC: 'Incompleto' };

  /* Botón «⋮» junto al nombre del equipo (solo en la página, no en el HTML descargado):
     opc.accionesMaquina = [[id, texto], …] y opc.onMaquina(id, maq, fecha). */
  function cerrarMenusMaq() {
    var a = document.querySelectorAll('.mr-maq-opc.abierto');
    for (var i = 0; i < a.length; i++) {
      a[i].classList.remove('abierto'); a[i].firstChild.setAttribute('aria-expanded', 'false');
      var mq = a[i].closest('.mr-maq'); if (mq) mq.style.zIndex = '';
    }
  }
  function menuMaquina(m, dia, opc) {
    var caja = el('span', 'mr-maq-opc'), btn = el('button', null, '⋮'), menu = el('div', 'mr-menu');
    btn.type = 'button'; btn.title = 'Opciones de este equipo'; btn.setAttribute('aria-haspopup', 'true'); btn.setAttribute('aria-expanded', 'false');
    btn.setAttribute('aria-label', 'Opciones de ' + (m.alias || m.pc));
    btn.onclick = function (e) {
      e.stopPropagation();
      var abierto = caja.classList.contains('abierto');
      cerrarMenusMaq();
      if (!abierto) {
        caja.classList.add('abierto'); btn.setAttribute('aria-expanded', 'true');
        // Cada bloque de equipo es su propio nivel de apilamiento (z-index:1): se eleva el abierto para que el siguiente no tape el menu.
        var mq = caja.closest('.mr-maq'); if (mq) mq.style.zIndex = '5';
      }
    };
    opc.accionesMaquina.forEach(function (a) {
      var b = el('button', null, a[1]); b.type = 'button';
      b.onclick = function (e) { e.stopPropagation(); cerrarMenusMaq(); opc.onMaquina(a[0], m, dia.fecha); };
      menu.appendChild(b);
    });
    caja.appendChild(btn); caja.appendChild(menu);
    if (!window._mrMenuDoc) {
      window._mrMenuDoc = true;
      document.addEventListener('click', cerrarMenusMaq);
      document.addEventListener('keydown', function (e) { if (e.key === 'Escape') cerrarMenusMaq(); });
    }
    return caja;
  }

  function dibujarDia(dia, opc) {
    var ini = opc.ini, fin = opc.fin;
    var sec = el('section', 'mr-dia');
    var cab = el('div', 'mr-dia-cab');
    cab.appendChild(el('h3', null, fechaLarga(dia.fecha)));
    if (!dia.hayDatos) cab.appendChild(el('span', 'mr-badge', 'Sin registros'));
    else if (dia.caidas === 0) {
      if (dia.maquinas.every(function (m) { return m.completa; })) cab.appendChild(el('span', 'mr-badge ok', '✓ Sin caídas en el horario'));
    }
    else cab.appendChild(el('span', 'mr-badge err', dia.caidas + (dia.caidas === 1 ? ' caída' : ' caídas') + ' · ' + dur(dia.errTotal) + ' desconectado (suma)'));
    if (opc.coincidencias && dia.coin.length) {
      var tc = dia.coin.reduce(function (t, c) { return t + c.b - c.a; }, 0);
      cab.appendChild(el('span', 'mr-badge coin', dia.coin.length + (dia.coin.length === 1 ? ' coincidencia' : ' coincidencias') + ' · ' + dur(tc)));
    }
    sec.appendChild(cab);
    if (!dia.hayDatos) { sec.classList.add('vacio-dia'); return sec; }
    var cuerpo = el('div', 'mr-cuerpo');
    sec.appendChild(cuerpo);
    var eje = filaEje(ini, fin);
    cuerpo.appendChild(eje);
    if (opc.coincidencias && dia.coin.length) {
      var capa = el('div', 'mr-coin-capa'), pe = eje.querySelector('.mr-pista');
      dia.coin.forEach(function (c) {
        var b = el('div', 'mr-coin');
        if (!colocar(b, c.a, c.b, ini, fin)) return;
        capa.appendChild(b);
        var tk = el('div', 'mr-coin-tk'); colocar(tk, c.a, c.b, ini, fin);
        tk.setAttribute('data-tip', 'Coincidencia · ' + hhmmss(c.a) + ' – ' + hhmmss(c.b) + ' (' + durTexto(c.b - c.a) + ')\n' +
          c.maquinas.length + ' de ' + dia.maquinas.filter(function (m) { return m.hayDatos; }).length + ' máquinas sin conexión a la vez:\n• ' + c.maquinas.join('\n• '));
        pe.appendChild(tk);
      });
      cuerpo.insertBefore(capa, cuerpo.firstChild);
    }

    dia.maquinas.forEach(function (m) {
      var bloque = el('div', 'mr-maq');
      var nom = el('div', 'mr-maq-nom');
      nom.appendChild(el('span', null, m.alias || m.pc));
      var vb = verBadge(m.version); if (vb) nom.appendChild(vb);
      if (m.alias && m.alias !== m.pc) nom.appendChild(el('small', null, m.pc));
      if (m.completa) nom.appendChild(el('small', 'ok', '✓ sin caídas'));
      if (opc.onMaquina && opc.accionesMaquina && opc.accionesMaquina.length) nom.appendChild(menuMaquina(m, dia, opc));
      bloque.appendChild(nom);

      if (m.ips && m.ips.length) {
        var fi = el('div', 'mr-fila mr-ipfila');
        fi.appendChild(el('div'));
        var pi = el('div', 'mr-pista-ip');
        m.ips.forEach(function (t) {
          var b = el('div', 'mr-ip');
          b.appendChild(el('span', null, t.ip));
          if (!colocar(b, t.a, t.b, ini, fin)) return;
          b.setAttribute('data-tip', 'IP ' + t.ip + '\n' + hhmmss(t.a) + ' – ' + hhmmss(t.b) + '  (' + durTexto(t.b - t.a) + ')');
          pi.appendChild(b);
        });
        fi.appendChild(pi);
        fi.appendChild(el('div'));
        bloque.appendChild(fi);
      }

      var notasDia = (m.notas || []).filter(function (n) { return n.s >= ini && n.s <= fin; });
      if (!m.destinos.length) {
        var fv = el('div', 'mr-fila'); fv.appendChild(el('div', 'mr-lbl', '—'));
        var pv = pista(ini, fin); pv.appendChild(el('div', 'mr-nodata', 'sin registros')); fv.appendChild(pv);
        fv.appendChild(el('div', 'mr-tot cero', '—')); bloque.appendChild(fv);
      }
      m.destinos.forEach(function (de, di) {
        var f = el('div', 'mr-fila' + (di === 0 && notasDia.length ? ' mr-fila-nota' : ''));
        var lbl = el('div', 'mr-lbl', de.destino); lbl.title = de.destino;
        f.appendChild(lbl);
        var p = pista(ini, fin);
        if (!de.hayDatos) p.appendChild(el('div', 'mr-nodata', 'sin registros'));
        else if (de.soloOculto) p.appendChild(el('div', 'mr-nodata', 'solo registros por Wi-Fi (ocultos)'));
        de.segs.forEach(function (sg) {
          if (sg.tipo === 'INC' || !sg.visible) return; // sin datos / red oculta: en blanco
          var cls = sg.tipo === 'ERROR' ? 'err' : 'ok';
          var s = el('div', 'mr-seg ' + cls + (sg.abierto ? ' abierto' : '') + (sg.red === 'wifi' ? ' wifi' : ''));
          if (!colocar(s, sg.a, sg.b, ini, fin)) return;
          var tip = de.destino + ' · ' + (sg.tipo === 'INC' ? 'Incompleto (' + (NOMBRE_TIPO[sg.orig] || sg.orig) + ', sin cierre)' : NOMBRE_TIPO[sg.tipo]) +
            '\n' + hhmmss(sg.a) + ' – ' + hhmmss(sg.b) + '  (' + durTexto(sg.b - sg.a) + ')';
          if (sg.abierto) tip += '\nEstado en curso según el último envío (no se suma)';
          if (sg.tipo === 'OK' && sg.lat) tip += '\nLatencia promedio: ' + sg.lat + ' ms';
          if (sg.msg) tip += '\n' + sg.msg;
          var ad = adaptadorEn(m.adapt, sg.a);
          tip += '\nRed: ' + (sg.red === 'wifi' ? 'Wi-Fi' : sg.red === 'cable' ? 'cable' : 'desconocida') + (ad ? ' (' + ad.nombre + ')' : '');
          s.setAttribute('data-tip', tip);
          p.appendChild(s);
        });
        if (opc.eventos) {
          de.marcas.forEach(function (mk) {
            if (mk.s < ini || mk.s > fin) return;
            var k = el('div', 'mr-marca ' + (mk.tipo === 'INICIO' ? 'ini' : 'ev'));
            k.style.left = pct(mk.s, ini, fin) + '%';
            k.setAttribute('data-tip', mk.tipo + ' · ' + hhmmss(mk.s) + '\n' + mk.msg);
            p.appendChild(k);
          });
        }
        if (di === 0 && notasDia.length) p.classList.add('con-nota');
        if (opc.onNuevaNota) {
          p.classList.add('anotable');
          var pedir = function (clientX) {
            var r = p.getBoundingClientRect();
            if (!r.width) return;
            var fr = Math.min(1, Math.max(0, (clientX - r.left) / r.width));
            opc.onNuevaNota({ pc: m.pc, alias: m.alias, fecha: dia.fecha, s: ini + fr * (fin - ini) });
          };
          p.addEventListener('contextmenu', function (e) {
            if (e.target.closest && e.target.closest('.bandera')) return;
            e.preventDefault(); pedir(e.clientX);
          });
          var t0 = null, tx = 0, ty = 0;   // pulsación larga en pantalla táctil
          p.addEventListener('touchstart', function (e) {
            if (e.touches.length !== 1) return;
            tx = e.touches[0].clientX; ty = e.touches[0].clientY;
            clearTimeout(t0); t0 = setTimeout(function () { t0 = null; pedir(tx); }, 600);
          }, { passive: true });
          p.addEventListener('touchmove', function (e) {
            var t = e.touches[0];
            if (Math.abs(t.clientX - tx) > 10 || Math.abs(t.clientY - ty) > 10) { clearTimeout(t0); t0 = null; }
          }, { passive: true });
          ['touchend', 'touchcancel'].forEach(function (ev) { p.addEventListener(ev, function () { clearTimeout(t0); t0 = null; }); });
        }
        notasDia.forEach(function (n) {
          var k = el('div', 'mr-marca nota');
          k.style.left = pct(n.s, ini, fin) + '%';
          var tipN = '\u2691 ' + hhmmss(n.s) + '\n' + n.texto + (opc.onNota && di === 0 ? '\n(clic en la bandera: editar o borrar)' : '');
          k.setAttribute('data-tip', tipN);
          if (di === 0) {
            var bd = el('i', 'bandera' + (opc.onNota ? ' edit' : ''), '\u2691');
            bd.setAttribute('data-tip', tipN);
            if (opc.onNota) bd.onclick = function () { opc.onNota(n); };
            k.appendChild(bd);
          }
          p.appendChild(k);
        });
        f.appendChild(p);
        var tot = el('div', 'mr-tot ' + (de.err > 0 ? 'hay' : 'cero'));
        if (!de.hayDatos || de.soloOculto) tot.textContent = '—';
        else {
          tot.textContent = dur(de.err);
          if (de.caidas) { tot.appendChild(document.createTextNode(' ')); tot.appendChild(el('small', null, '(' + de.caidas + ')')); }
        }
        tot.title = de.caidas + ' caída(s) en el horario';
        f.appendChild(tot);
        bloque.appendChild(f);
      });
      cuerpo.appendChild(bloque);
    });
    return sec;
  }

  function dibujarResumen(dias, opc) {
    var box = el('section', 'mr-res');
    box.appendChild(el('h3', null, 'Resumen del periodo · tiempo desconectado de ' + hhmm(opc.ini) + ' a ' + hhmm(opc.fin)));
    var tb = el('table'), thead = el('thead'), tr = el('tr');
    ['Máquina', 'Destino'].concat(dias.map(function (d) { return fechaCorta(d.fecha); }), ['Total', 'Caídas', 'Disponib.'])
      .forEach(function (t) { tr.appendChild(el('th', null, t)); });
    thead.appendChild(tr); tb.appendChild(thead);
    var tbody = el('tbody');
    if (!dias.length) { box.appendChild(tb); return box; }
    dias[0].maquinas.forEach(function (m, mi) {
      m.destinos.forEach(function (de, di) {
        var r = el('tr', di === 0 ? 'grupo' : null);
        r.appendChild(el('td', null, di === 0 ? (m.alias || m.pc) : ''));
        r.appendChild(el('td', null, de.destino));
        var err = 0, ok = 0, caidas = 0, algun = false;
        dias.forEach(function (d) {
          var x = d.maquinas[mi].destinos[di];
          if (!x.hayDatos || x.soloOculto) { r.appendChild(el('td', 'cero', '—')); return; }
          algun = true; err += x.err; ok += x.ok; caidas += x.caidas;
          r.appendChild(el('td', x.err ? 'hay' : 'cero', dur(x.err)));
        });
        r.appendChild(el('td', 'tot ' + (err ? 'hay' : 'cero'), algun ? dur(err) : '—'));
        r.appendChild(el('td', caidas ? 'hay' : 'cero', algun ? String(caidas) : '—'));
        var disp = ok + err > 0 ? (ok / (ok + err) * 100) : null;
        r.appendChild(el('td', null, disp === null ? '—' : (disp >= 99.95 && err > 0 ? '99.9' : disp.toFixed(1)) + ' %'));
        tbody.appendChild(r);
      });
    });
    tb.appendChild(tbody); box.appendChild(tb);
    return box;
  }

  function barraRedes(datos, opc, raiz, dias) {
    var b = el('div', 'mr-redes');
    b.appendChild(el('span', null, 'Mostrar red:'));
    [['cable', 'Cable'], ['wifi', 'Wi-Fi']].forEach(function (x) {
      var on = !!opc.redes[x[0]];
      var bt = el('button', 'mr-red-btn' + (on ? ' on' : ''), (on ? '✓ ' : '') + x[1]);
      bt.type = 'button';
      bt.setAttribute('aria-pressed', on ? 'true' : 'false');
      bt.title = (on ? 'Ocultar' : 'Mostrar') + ' los registros tomados mientras la máquina usaba ' + x[1];
      bt.onclick = function () { opc.redes[x[0]] = !on; render(datos, opc, raiz); };
      b.appendChild(bt);
    });
    var oc = dias.reduce(function (t, d) { return t + d.oculto; }, 0);
    if (oc > 0) {
      var nt = el('span', 'mr-red-nota', 'Oculto: ' + durTexto(oc));
      nt.title = 'Tiempo de registros ocultos por el filtro de red, dentro del horario (suma de todos los destinos y días).';
      b.appendChild(nt);
    }
    return b;
  }

  function leyenda(opc) {
    var l = el('div', 'mr-ley');
    function it(color, txt, cls) {
      var s = el('span'), i = el('i', cls || null);
      i.style.background = color; s.appendChild(i); s.appendChild(document.createTextNode(txt)); l.appendChild(s);
    }
    it('var(--ok)', 'Conectado');
    it('var(--err)', 'Sin conexión');
    if (opc.redes.wifi) it('repeating-linear-gradient(135deg,var(--ok-wifi) 0 3px,transparent 3px 5px)', 'Por Wi-Fi (bandeado)');
    var sd = el('span'), isd = el('i'); isd.style.boxShadow = 'inset 0 0 0 1px var(--borde)'; sd.appendChild(isd); sd.appendChild(document.createTextNode('Sin datos')); l.appendChild(sd);
    if (opc.eventos) { it('var(--ev)', 'Evento de red', 'tk'); it('var(--ini)', 'Inicio del monitor', 'tk'); }
    if (opc.hayNotas) it('var(--nota,#f59e0b)', 'Nota manual (bitácora)', 'tk');
    if (opc.coincidencias) it('var(--coin)', 'Coincidencia (2+ máquinas caídas a la vez)');
    return l;
  }

  function instalarTooltip(raiz) {
    var tip = el('div', 'mr-tip'); document.body.appendChild(tip);
    var activo = null;
    function mostrar(t, x, y) {
      tip.textContent = t; tip.style.display = 'block';
      var w = tip.offsetWidth, hh = tip.offsetHeight;
      var px = x + 14, py = y + 16;
      if (px + w > window.innerWidth - 8) px = Math.max(8, x - w - 14);
      if (py + hh > window.innerHeight - 8) py = Math.max(8, y - hh - 12);
      tip.style.left = px + 'px'; tip.style.top = py + 'px';
    }
    raiz.addEventListener('mousemove', function (e) {
      var n = e.target.closest ? e.target.closest('[data-tip]') : null;
      if (!n || !raiz.contains(n)) { tip.style.display = 'none'; activo = null; return; }
      activo = n; mostrar(n.getAttribute('data-tip'), e.clientX, e.clientY);
    });
    raiz.addEventListener('mouseleave', function () { tip.style.display = 'none'; activo = null; });
    raiz.addEventListener('click', function (e) {
      var n = e.target.closest ? e.target.closest('[data-tip]') : null;
      if (n) mostrar(n.getAttribute('data-tip'), e.clientX, e.clientY); else tip.style.display = 'none';
    });
    window.addEventListener('scroll', function () { tip.style.display = 'none'; }, { passive: true });
  }

  /* opc: { dias:[fechas], ini:seg, fin:seg, coincidencias:bool, eventos:bool, redes:{cable,wifi}, vacias:bool,
            ahora:{fecha, s}, generado:'texto', titulo:'texto' } */
  function render(datos, opc, raiz) {
    raiz.textContent = '';
    raiz.classList.add('mr');
    if (!opc.redes) opc.redes = { cable: true, wifi: false };
    var dias = preparar(datos, opc);
    if (!opc.vacias) dias = dias.filter(function (d) { return d.hayDatos; });

    var cab = el('div', 'mr-cab');
    cab.appendChild(el('h2', null, opc.titulo || 'Análisis de conectividad'));
    var nMaq = datos.maquinas.length;
    cab.appendChild(el('span', 'meta', 'Horario ' + hhmm(opc.ini) + '–' + hhmm(opc.fin) + ' · ' + nMaq + (nMaq === 1 ? ' máquina' : ' máquinas') + ' · ' + dias.length + (dias.length === 1 ? ' día' : ' días')));
    cab.appendChild(barraRedes(datos, opc, raiz, dias));
    raiz.appendChild(cab);
    opc.hayNotas = !!(datos.notas && Object.keys(datos.notas).length);
    raiz.appendChild(leyenda(opc));

    if (!nMaq) { raiz.appendChild(el('div', 'vacio', 'Las máquinas seleccionadas no tienen registros en el periodo.')); return; }
    if (!dias.length) { raiz.appendChild(el('div', 'vacio', 'Ningún día seleccionado tiene registros.')); return; }

    dias.forEach(function (d) { raiz.appendChild(dibujarDia(d, opc)); });
    raiz.appendChild(dibujarResumen(dias, opc));
    raiz.appendChild(el('div', 'mr-pie', 'Tiempo desconectado = suma de estados ERROR cerrados dentro del horario, por destino. ' +
      'Sin datos (en blanco) = sin registros, filas incompletas por apagado abrupto o red oculta (' +
      (opc.redes.wifi ? '' : 'Wi-Fi') + (!opc.redes.wifi && !opc.redes.cable ? ' y ' : '') + (opc.redes.cable ? '' : 'cable') + (opc.redes.wifi && opc.redes.cable ? 'ninguna' : '') +
      '). «Sin caídas» solo si hay registros de todo el horario. El estado en curso no se suma. ' +
      'Coincidencia = 2 o más máquinas sin conexión a la vez (tolerancia ' + TOL + ' s). ' + (opc.generado ? 'Generado: ' + opc.generado + '.' : '')));
    if (!raiz._mrTip) { instalarTooltip(raiz); raiz._mrTip = true; }
  }

  window.MR = { render: render, fechaLarga: fechaLarga, fechaCorta: fechaCorta, hhmm: hhmm };
})();
</script>

<script id="app">
(function () {
  'use strict';
  var DIAS_C = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  var MAX_DIAS = <?= MR_MAX_DIAS_RANGO ?>;   // rango máximo que acepta el servidor
  var MESES_L = ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'];
  var MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
  var $ = function (id) { return document.getElementById(id); };
  function pad(n) { return String(n).padStart(2, '0'); }
  function parseISO(s) { var p = s.split('-'); return new Date(Date.UTC(+p[0], p[1] - 1, +p[2])); }
  function toISO(d) { return d.toISOString().slice(0, 10); }
  function sumar(s, n) { var d = parseISO(s); d.setUTCDate(d.getUTCDate() + n); return toISO(d); }
  function lunesDe(s) { var d = parseISO(s); d.setUTCDate(d.getUTCDate() - (d.getUTCDay() + 6) % 7); return toISO(d); }
  function hoyISO() { var n = new Date(); return n.getFullYear() + '-' + pad(n.getMonth() + 1) + '-' + pad(n.getDate()); }
  function semanaISO(s) {
    var d = parseISO(s); d.setUTCDate(d.getUTCDate() + 3 - (d.getUTCDay() + 6) % 7);
    var e = new Date(Date.UTC(d.getUTCFullYear(), 0, 4));
    return 1 + Math.round(((d - e) / 86400000 - 3 + (e.getUTCDay() + 6) % 7) / 7);
  }
  function dm(s) { var d = parseISO(s); return d.getUTCDate() + ' ' + MESES[d.getUTCMonth()]; }

  var estado = {
    desde: lunesDe(hoyISO()), hasta: sumar(lunesDe(hoyISO()), 6),
    dias: {},   // fecha → marcada; sin entrada = Lun–Vie sí, Sáb–Dom no
    ini: 7 * 3600, fin: 15 * 3600,                        // 7:00 a 15:00 por defecto
    maquinas: [], seleccion: {}, datos: null, datosClave: '',
    redes: { cable: true, wifi: true }   // Wi-Fi visible por defecto, bandeado para distinguirlo del cable (se cambia en el reporte)
  };

  // ---- Recordar la cabecera (semana, días, horario, máquinas, opciones) entre recargas -----
  // De mejor esfuerzo: si localStorage no está disponible (privado, cuota, etc.) el formulario
  // simplemente vuelve a los valores por defecto de siempre, sin romper nada.
  var LS_CLAVE = 'mrv1_form_v1';
  function guardarForm() {
    try {
      localStorage.setItem(LS_CLAVE, JSON.stringify({
        v: 2, desde: estado.desde, hasta: estado.hasta, dias: estado.dias, ini: estado.ini, fin: estado.fin, seleccion: estado.seleccion,
        opciones: { coin: $('optCoin').checked, eventos: $('optEventos').checked, vacias: $('optVacias').checked }
      }));
    } catch (e) { }
  }
  function cargarForm() {
    try {
      var raw = localStorage.getItem(LS_CLAVE);
      if (!raw) return;
      var g = JSON.parse(raw);
      var esISO = function (x) { return typeof x === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(x); };
      if (esISO(g.desde) && esISO(g.hasta) && g.hasta >= g.desde && g.hasta <= sumar(g.desde, MAX_DIAS - 1)) {
        estado.desde = g.desde; estado.hasta = g.hasta;
        if (g.dias && typeof g.dias === 'object' && !Array.isArray(g.dias)) estado.dias = g.dias;
      } else if (esISO(g.lunes)) {   // formato anterior (una sola semana)
        estado.desde = lunesDe(g.lunes); estado.hasta = sumar(estado.desde, 6);
        if (Array.isArray(g.dias) && g.dias.length === 7) g.dias.forEach(function (x, i) { estado.dias[sumar(estado.desde, i)] = !!x; });
      }
      if (typeof g.ini === 'number' && typeof g.fin === 'number' && g.ini >= 0 && g.fin <= 86400 && g.fin > g.ini) {
        estado.ini = g.ini; estado.fin = g.fin;
      }
      if (g.seleccion && typeof g.seleccion === 'object') estado.seleccion = g.seleccion;
      if (g.opciones) {
        if (typeof g.opciones.coin === 'boolean') $('optCoin').checked = g.opciones.coin;
        if (typeof g.opciones.eventos === 'boolean') $('optEventos').checked = g.opciones.eventos;
        if (typeof g.opciones.vacias === 'boolean') $('optVacias').checked = g.opciones.vacias;
      }
    } catch (e) { }
  }

  // ---- Horario --------------------------------------------------------
  (function () {
    for (var s = 0; s <= 86400; s += 1800) {
      var t = s === 86400 ? '24:00' : pad(Math.floor(s / 3600)) + ':' + pad(s % 3600 / 60);
      if (s < 86400) $('horaIni').add(new Option(t, s));
      if (s > 0) $('horaFin').add(new Option(t, s));
    }
  })();
  function pintarHorario() { $('horaIni').value = estado.ini; $('horaFin').value = estado.fin; }
  function cambiarHorario(cual) {
    var a = +$('horaIni').value, b = +$('horaFin').value;
    if (b <= a) { if (cual === 'ini') b = Math.min(86400, a + 3600); else a = Math.max(0, b - 3600); }
    estado.ini = a; estado.fin = b; pintarHorario(); rerender(); guardarForm();
  }
  $('horaIni').onchange = function () { cambiarHorario('ini'); };
  $('horaFin').onchange = function () { cambiarHorario('fin'); };
  $('horaJornada').onclick = function () { estado.ini = 7 * 3600; estado.fin = 15 * 3600; pintarHorario(); rerender(); guardarForm(); };
  $('horaDia').onclick = function () { estado.ini = 0; estado.fin = 86400; pintarHorario(); rerender(); guardarForm(); };

  // ---- Semana y días ----------------------------------------------------
  function diasConDatos() {
    var c = {};
    estado.maquinas.forEach(function (m) { if (estado.seleccion[m.pc]) m.dias.forEach(function (d) { c[d] = true; }); });
    return c;
  }
  function fechaDMA(s) { var p = s.split('-'); return p[2] + '/' + p[1] + '/' + p[0]; }
  function diasDelRango() {
    var r = [], f = estado.desde;
    for (var i = 0; i < MAX_DIAS && f <= estado.hasta; i++, f = sumar(estado.desde, i)) r.push(f);
    return r;
  }
  function diaMarcado(f) { return f in estado.dias ? !!estado.dias[f] : diaSemana(f) < 5; }
  function diaSemana(f) { return (parseISO(f).getUTCDay() + 6) % 7; }
  function esSemanaCompleta() { return diaSemana(estado.desde) === 0 && estado.hasta === sumar(estado.desde, 6); }
  function tituloRango() {
    var a = estado.desde, b = estado.hasta, y = parseISO(b).getUTCFullYear();
    if (esSemanaCompleta()) return 'Semana ' + semanaISO(a) + ' · ' + dm(a) + ' al ' + dm(b) + ' ' + y;
    return 'Del ' + dm(a) + ' ' + parseISO(a).getUTCFullYear() + ' al ' + dm(b) + ' ' + y;
  }
  function pintarSemana() {
    var l = estado.desde, n = diasDelRango().length;
    var actual = lunesDe(hoyISO());
    $('semTxt').textContent = (esSemanaCompleta()
      ? 'Semana ' + semanaISO(l) + ' · lunes ' + dm(l) + ' a domingo ' + dm(estado.hasta) + ' ' + parseISO(estado.hasta).getUTCFullYear()
      : n + (n === 1 ? ' día' : ' días') + ' · ' + dm(l) + ' a ' + dm(estado.hasta) + ' ' + parseISO(estado.hasta).getUTCFullYear()) +
      (esSemanaCompleta() && l === actual ? ' (semana actual)' : esSemanaCompleta() && l === sumar(actual, -7) ? ' (semana anterior)' : '');
    pkDesde.pintar(); pkHasta.pintar();
    var cont = $('dias'); cont.textContent = '';
    var cd = diasConDatos();
    diasDelRango().forEach(function (f) {
      var lab = document.createElement('label'); lab.className = 'dia-chk' + (cd[f] ? ' con-datos' : '');
      lab.title = cd[f] ? 'Con registros' : 'Sin registros de las máquinas seleccionadas';
      var c = document.createElement('input'); c.type = 'checkbox'; c.checked = diaMarcado(f);
      c.onchange = function () { estado.dias[f] = c.checked; rerender(); guardarForm(); };
      var a = document.createElement('span'); a.className = 'n'; a.textContent = DIAS_C[diaSemana(f)];
      var b = document.createElement('span'); b.className = 'd'; b.textContent = parseISO(f).getUTCDate();
      var p = document.createElement('span'); p.className = 'pt';
      lab.append(c, a, b, p); cont.appendChild(lab);
    });
  }
  function irRango(desde, hasta) {
    if (desde === estado.desde && hasta === estado.hasta) return;
    estado.desde = desde; estado.hasta = hasta; estado.datos = null; estado.datosClave = '';
    $('reporte').textContent = ''; $('descargar').disabled = true;
    pintarSemana(); cargarMaquinas(); guardarForm();
  }
  function irSemana(lunes) { irRango(lunes, sumar(lunes, 6)); }
  $('semAnt').onclick = function () { irRango(sumar(estado.desde, -7), sumar(estado.hasta, -7)); };
  $('semSig').onclick = function () { irRango(sumar(estado.desde, 7), sumar(estado.hasta, 7)); };
  $('semPas').onclick = function () { irSemana(sumar(lunesDe(hoyISO()), -7)); };
  $('semHoy').onclick = function () { irSemana(lunesDe(hoyISO())); };

  // ---- Calendario con puntito verde en los días que tienen registros ------------------------
  var diasConRegistros = {}, mesesPedidos = {};
  function cargarMesDatos(y, m, alTerminar) {
    var clave = y + '-' + pad(m + 1);
    if (mesesPedidos[clave]) return;
    mesesPedidos[clave] = true;
    var ult = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
    api({ accion: 'dias', desde: clave + '-01', hasta: clave + '-' + pad(ult) }).then(function (j) {
      j.dias.forEach(function (d) { diasConRegistros[d] = true; });
      alTerminar();
    }).catch(function () { delete mesesPedidos[clave]; });
  }
  function crearPicker(host, leer, escribir) {
    var btn = document.createElement('button'); btn.type = 'button'; btn.className = 'btn pk-btn';
    var pop = document.createElement('div'); pop.className = 'pk-pop';
    host.append(btn, pop);
    var vista = null;   // {y, m} del mes mostrado
    function pintar() {
      btn.textContent = '📅 ' + fechaDMA(leer());
      if (pop.classList.contains('abierto')) pintarPop();
    }
    function pintarPop() {
      pop.textContent = '';
      var cab = document.createElement('div'); cab.className = 'pk-cab';
      var ant = document.createElement('button'); ant.type = 'button'; ant.className = 'btn chico'; ant.textContent = '◀';
      var sig = document.createElement('button'); sig.type = 'button'; sig.className = 'btn chico'; sig.textContent = '▶';
      var tit = document.createElement('span'); tit.textContent = MESES_L[vista.m] + ' ' + vista.y;
      ant.onclick = function () { vista.m--; if (vista.m < 0) { vista.m = 11; vista.y--; } pintarPop(); };
      sig.onclick = function () { vista.m++; if (vista.m > 11) { vista.m = 0; vista.y++; } pintarPop(); };
      cab.append(ant, tit, sig); pop.appendChild(cab);
      var g = document.createElement('div'); g.className = 'pk-grid';
      DIAS_C.forEach(function (n) { var s = document.createElement('span'); s.className = 'sem'; s.textContent = n.charAt(0); g.appendChild(s); });
      var primero = new Date(Date.UTC(vista.y, vista.m, 1)), lead = (primero.getUTCDay() + 6) % 7;
      var total = new Date(Date.UTC(vista.y, vista.m + 1, 0)).getUTCDate();
      for (var i = 0; i < lead; i++) g.appendChild(document.createElement('span'));
      var hoy = hoyISO();
      for (var d = 1; d <= total; d++) (function (d) {
        var f = vista.y + '-' + pad(vista.m + 1) + '-' + pad(d);
        var b = document.createElement('button'); b.type = 'button'; b.textContent = d;
        b.className = 'pk-d' + (diasConRegistros[f] ? ' datos' : '') + (f === hoy ? ' hoy' : '') +
          (f === leer() ? ' sel' : (f >= estado.desde && f <= estado.hasta ? ' rango' : ''));
        b.title = diasConRegistros[f] ? 'Con registros' : 'Sin registros';
        b.onclick = function (e) { e.stopPropagation(); pop.classList.remove('abierto'); escribir(f); };
        g.appendChild(b);
      })(d);
      pop.appendChild(g);
      cargarMesDatos(vista.y, vista.m, function () { pintarSemana(); });
    }
    btn.onclick = function (e) {
      e.stopPropagation();
      var abierto = pop.classList.contains('abierto');
      document.querySelectorAll('.pk-pop.abierto').forEach(function (x) { x.classList.remove('abierto'); });
      if (abierto) return;
      var p = leer().split('-'); vista = { y: +p[0], m: p[1] - 1 };
      pop.classList.add('abierto'); pintarPop();
    };
    pop.onclick = function (e) { e.stopPropagation(); };
    document.addEventListener('click', function () { pop.classList.remove('abierto'); });
    return { pintar: pintar };
  }
  var pkDesde = crearPicker($('pkDesde'), function () { return estado.desde; }, function (f) {
    var h = estado.hasta;
    if (h < f || h > sumar(f, MAX_DIAS - 1)) h = h < f ? f : sumar(f, MAX_DIAS - 1);
    irRango(f, h);
  });
  var pkHasta = crearPicker($('pkHasta'), function () { return estado.hasta; }, function (f) {
    var d = estado.desde;
    if (d > f || f > sumar(d, MAX_DIAS - 1)) d = d > f ? f : sumar(f, -(MAX_DIAS - 1));
    irRango(d, f);
  });

  // ---- API ---------------------------------------------------------------
  function api(params) {
    var q = new URLSearchParams();
    Object.keys(params).forEach(function (k) {
      [].concat(params[k]).forEach(function (v) { q.append(k, v); });
    });
    return fetch('index.php?' + q.toString(), { credentials: 'same-origin', headers: { 'Accept': 'application/json' } })
      .then(function (r) {
        return r.json().catch(function () { throw new Error('Respuesta no válida del servidor (HTTP ' + r.status + ').'); })
          .then(function (j) {
            if (r.status === 401) { location.reload(); throw new Error('Sesión vencida.'); }
            if (!j.ok) throw new Error(j.error || ('Error HTTP ' + r.status));
            return j;
          });
      });
  }
  function aviso(txt, esError) { var e = $('estado'); e.textContent = txt || ''; e.className = 'estado' + (esError ? ' error' : ''); }

  // ---- Máquinas ----------------------------------------------------------
  var pedidoMaq = 0;
  function cargarMaquinas() {
    var n = ++pedidoMaq;
    $('maqs').innerHTML = '<div class="vacio">Cargando máquinas…</div>';
    api({ accion: 'maquinas', desde: estado.desde, hasta: estado.hasta }).then(function (j) {
      if (n !== pedidoMaq) return;
      var previa = estado.seleccion, habiaAlguna = Object.keys(previa).length > 0;
      estado.maquinas = j.maquinas; estado.seleccion = {};
      j.maquinas.forEach(function (m) { estado.seleccion[m.pc] = habiaAlguna && (m.pc in previa) ? previa[m.pc] : true; });
      pintarMaquinas(); pintarSemana(); aviso('');
    }).catch(function (e) {
      if (n !== pedidoMaq) return;
      $('maqs').innerHTML = ''; var d = document.createElement('div'); d.className = 'vacio'; d.textContent = 'No se pudo cargar: ' + e.message; $('maqs').appendChild(d);
    });
  }
  function cerrarMenusMaquina() {
    document.querySelectorAll('.maq-menu.abierto').forEach(function (x) { x.classList.remove('abierto'); });
  }
  document.addEventListener('click', cerrarMenusMaquina);

  function eliminarMaquina(m) {
    var nombre = (m.alias && m.alias !== m.pc) ? (m.alias + ' (' + m.pc + ')') : m.pc;
    if (!confirm('¿Eliminar "' + nombre + '" por completo?\n\nEsto borra TODOS sus registros históricos de la base de datos y no se puede deshacer.')) return;
    var csrf = $('maqs').dataset.csrf;
    aviso('Eliminando "' + nombre + '"…');
    fetch('index.php?accion=eliminar_pc', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pc: m.pc, csrf: csrf })
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) { return { ok: r.ok, j: j }; });
    }).then(function (res) {
      if (!res.ok || !res.j || !res.j.ok) { aviso('No se pudo eliminar: ' + (res.j && res.j.error ? res.j.error : 'error desconocido'), true); return; }
      delete estado.seleccion[m.pc];
      estado.maquinas = estado.maquinas.filter(function (x) { return x.pc !== m.pc; });
      pintarMaquinas(); pintarSemana();
      aviso('Se eliminó "' + nombre + '" y ' + res.j.registros_eliminados + ' registro(s).');
    }).catch(function (e) { aviso('No se pudo eliminar: ' + e.message, true); });
  }

  function pintarMaquinas() {
    var c = $('maqs'); var puedeEliminar = c.dataset.puedeEliminar === '1'; c.textContent = '';
    if (!estado.maquinas.length) {
      var v = document.createElement('div'); v.className = 'vacio'; v.textContent = 'Ninguna máquina envió registros en este rango.'; c.appendChild(v);
      return;
    }
    estado.maquinas.forEach(function (m) {
      var lab = document.createElement('label'); lab.className = 'maq';
      var chk = document.createElement('input'); chk.type = 'checkbox'; chk.checked = !!estado.seleccion[m.pc];
      chk.onchange = function () { estado.seleccion[m.pc] = chk.checked; pintarSemana(); guardarForm(); };
      var info = document.createElement('div'); info.style.minWidth = '0';
      var nom = document.createElement('div'); nom.className = 'nom'; nom.textContent = m.alias || m.pc;
      if (m.version && m.version.v) {
        var vb = document.createElement('span'); vb.className = 'ver' + (m.version.estado === 'vieja' ? ' vieja' : m.version.estado === 'falla' ? ' falla' : '');
        vb.textContent = 'v' + m.version.v; vb.style.marginLeft = '6px';
        vb.title = 'Versión de los scripts confirmada por la PC: ' + m.version.v + (m.version.en ? '\n' + m.version.en : '') +
          (m.version.estado === 'vieja' ? '\nHay una versión más nueva publicada: ' + m.version.publicada : '') +
          (m.version.estado === 'falla' ? '\nLa última actualización falló' + (m.version.resultado ? ' (' + m.version.resultado + ')' : '') + (m.version.detalle ? ': ' + m.version.detalle : '') : '');
        nom.appendChild(vb);
      }
      var pc = document.createElement('div'); pc.className = 'pc';
      pc.textContent = (m.alias && m.alias !== m.pc ? m.pc + ' · ' : '') + m.dias.length + (m.dias.length === 1 ? ' día' : ' días') + ' con datos';
      var ds = document.createElement('div'); ds.className = 'dests';
      m.destinos.forEach(function (d) {
        var ch = document.createElement('span'); ch.className = 'chip' + (d.errores ? ' err' : '');
        ch.textContent = d.destino + (d.errores ? ' · ' + d.errores + ' err' : '');
        ch.title = d.registros + ' registros, ' + d.errores + ' con ERROR en la semana';
        ds.appendChild(ch);
      });
      info.append(nom, pc, ds); lab.append(chk, info);
      if (puedeEliminar) {
        var menu = document.createElement('div'); menu.className = 'maq-menu';
        var elim = document.createElement('button'); elim.type = 'button'; elim.className = 'pel'; elim.textContent = 'Eliminar computadora…';
        elim.onclick = function (e) { e.preventDefault(); e.stopPropagation(); cerrarMenusMaquina(); eliminarMaquina(m); };
        menu.appendChild(elim);
        var menuBtn = document.createElement('button'); menuBtn.type = 'button'; menuBtn.className = 'maq-menu-btn';
        menuBtn.textContent = '⋯'; menuBtn.title = 'Más opciones';
        menuBtn.onclick = function (e) {
          e.preventDefault(); e.stopPropagation();
          var abierto = menu.classList.contains('abierto');
          cerrarMenusMaquina();
          if (!abierto) menu.classList.add('abierto');
        };
        lab.append(menuBtn, menu);
      }
      c.appendChild(lab);
    });
  }
  $('maqTodas').onclick = function () { estado.maquinas.forEach(function (m) { estado.seleccion[m.pc] = true; }); pintarMaquinas(); pintarSemana(); guardarForm(); };
  $('maqNinguna').onclick = function () { estado.maquinas.forEach(function (m) { estado.seleccion[m.pc] = false; }); pintarMaquinas(); pintarSemana(); guardarForm(); };

  // ---- Generar -----------------------------------------------------------
  function seleccionadas() { return estado.maquinas.filter(function (m) { return estado.seleccion[m.pc]; }).map(function (m) { return m.pc; }); }
  function diasElegidos() { return diasDelRango().filter(diaMarcado); }
  function opciones() {
    var n = new Date();
    return {
      onNota: puedeNotas ? abrirNota : null,
      onNuevaNota: puedeNotas ? function (pre) { abrirNota(null, pre); } : null,
      accionesMaquina: (puedeNotas ? [['nombre', 'Editar nombre']] : []).concat([['registro', 'Ver registro']]),
      onMaquina: function (id, m, fecha) { if (id === 'nombre') abrirNombre(m.pc); else abrirRegistro(m.pc, fecha); },
      dias: diasElegidos(), ini: estado.ini, fin: estado.fin,
      coincidencias: $('optCoin').checked, redes: estado.redes, eventos: $('optEventos').checked, vacias: $('optVacias').checked,
      ahora: { fecha: hoyISO(), s: n.getHours() * 3600 + n.getMinutes() * 60 + n.getSeconds() },
      titulo: tituloRango(),
      generado: hoyISO() + ' ' + pad(n.getHours()) + ':' + pad(n.getMinutes())
    };
  }
  // ---- Bitácora: notas manuales sobre la línea de tiempo ------------------------------
  var puedeNotas = $('maqs').dataset.puedeEliminar === '1';
  function fechaLocal(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function horaLocal(d) { return pad(d.getHours()) + ':' + pad(d.getMinutes()); }
  function enviarNota(accion, cuerpo) {
    cuerpo.csrf = $('maqs').dataset.csrf;
    return fetch('index.php?accion=' + accion, {
      method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(cuerpo)
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (!r.ok || !j.ok) throw new Error(j.error || ('Error HTTP ' + r.status));
        return j;
      });
    });
  }
  function recargarNotas(fechaNota) {
    if (!estado.datos) { aviso('Nota guardada. Genere el gráfico para verla.'); return; }
    var pcs = estado.datos.maquinas.map(function (m) { return m.pc; });
    if (!pcs.length) return;
    api({ accion: 'notas', desde: estado.desde, hasta: estado.hasta, 'pc[]': pcs }).then(function (j) {
      estado.datos.notas = j.notas;
      rerender();
      aviso(fechaNota && (fechaNota < estado.desde || fechaNota > estado.hasta) ? 'Nota guardada (cae fuera de la semana que se está viendo).' : 'Nota guardada.');
    }).catch(function (e) { aviso(e.message, true); });
  }
  function cerrarNota() { var f = document.querySelector('.nota-fondo'); if (f) f.remove(); }
  function abrirNota(nota, pre) {
    cerrarNota();
    var edit = !!(nota && nota.id);
    var fondo = document.createElement('div'); fondo.className = 'nota-fondo';
    var caja = document.createElement('div'); caja.className = 'nota-caja'; fondo.appendChild(caja);
    caja.innerHTML =
      '<h3></h3><div id="nMaqBox"></div>' +
      '<label class="etq2" for="nTexto">Nota (breve)</label>' +
      '<textarea id="nTexto" rows="3" maxlength="300" placeholder="Ej.: desconecté el switch del lab / cambié el cable para una prueba"></textarea>' +
      '<label class="etq2">Cuándo ocurrió</label>' +
      '<div class="nota-cuando"><input type="date" id="nFecha"><input type="time" id="nHora"></div>' +
      '<div class="nota-chips"></div><div class="nota-err" id="nErr"></div>' +
      '<div class="nota-pie"><button class="btn prim" id="nGuardar" type="button">Guardar</button>' +
      '<button class="btn" id="nCancelar" type="button">Cancelar</button><span class="sep"></span></div>';
    caja.querySelector('h3').textContent = edit ? 'Editar nota · ' + (nota.alias || nota.pc) : (pre ? 'Nueva nota · ' + (pre.alias || pre.pc) : 'Nueva nota en la bitácora');
    var texto = caja.querySelector('#nTexto'), fe = caja.querySelector('#nFecha'), ho = caja.querySelector('#nHora'), err = caja.querySelector('#nErr');
    var ahora = new Date();
    fe.value = edit ? nota.fecha : (pre ? pre.fecha : fechaLocal(ahora));
    ho.value = edit ? nota.hora.slice(0, 5) : (pre ? pad(Math.floor(pre.s / 3600)) + ':' + pad(Math.floor(pre.s % 3600 / 60)) : horaLocal(ahora));
    if (edit) texto.value = nota.texto;

    // Máquinas (solo al crear): por defecto las que están seleccionadas en el formulario
    var checks = [];
    if (!edit) {
      var box = caja.querySelector('#nMaqBox');
      var et = document.createElement('label'); et.className = 'etq2'; et.textContent = 'Máquinas observadas'; box.appendChild(et);
      var lista = document.createElement('div'); lista.className = 'nota-maqs'; box.appendChild(lista);
      estado.maquinas.forEach(function (m) {
        var l = document.createElement('label'), c = document.createElement('input'); c.type = 'checkbox'; c.checked = pre ? m.pc === pre.pc : !!estado.seleccion[m.pc]; c.value = m.pc;
        l.appendChild(c); l.appendChild(document.createTextNode(' ' + (m.alias && m.alias !== m.pc ? m.alias + ' (' + m.pc + ')' : m.pc)));
        lista.appendChild(l); checks.push(c);
      });
      if (!checks.length) lista.textContent = 'No hay máquinas con registros en el rango.';
    }

    // Ajuste rápido de la hora (cómodo desde el teléfono)
    function mover(min) {
      var base = new Date((fe.value || fechaLocal(ahora)) + 'T' + (ho.value || '00:00') + ':00');
      if (isNaN(base)) base = new Date();
      base.setMinutes(base.getMinutes() + min);
      fe.value = fechaLocal(base); ho.value = horaLocal(base);
    }
    var chips = caja.querySelector('.nota-chips');
    [['Ahora', null], ['−5 min', -5], ['−15 min', -15], ['−30 min', -30], ['−1 h', -60], ['+5 min', 5]].forEach(function (c) {
      var b = document.createElement('button'); b.type = 'button'; b.className = 'btn chico'; b.textContent = c[0];
      b.onclick = function () { if (c[1] === null) { var n = new Date(); fe.value = fechaLocal(n); ho.value = horaLocal(n); } else mover(c[1]); };
      chips.appendChild(b);
    });

    var pie = caja.querySelector('.nota-pie');
    if (edit) {
      var del = document.createElement('button'); del.type = 'button'; del.className = 'btn'; del.textContent = 'Eliminar';
      del.onclick = function () {
        if (!confirm('¿Eliminar esta nota?')) return;
        del.disabled = true;
        enviarNota('nota_borrar', { id: nota.id }).then(function () { cerrarNota(); recargarNotas(nota.fecha); })
          .catch(function (e) { err.textContent = e.message; del.disabled = false; });
      };
      pie.appendChild(del);
    }
    caja.querySelector('#nCancelar').onclick = cerrarNota;
    fondo.addEventListener('mousedown', function (e) { if (e.target === fondo) cerrarNota(); });
    caja.querySelector('#nGuardar').onclick = function () {
      var pcs = checks.filter(function (c) { return c.checked; }).map(function (c) { return c.value; });
      err.textContent = '';
      if (!edit && !pcs.length) { err.textContent = 'Seleccione al menos una máquina.'; return; }
      if (!texto.value.trim()) { err.textContent = 'Escriba la nota.'; texto.focus(); return; }
      if (!fe.value || !ho.value) { err.textContent = 'Indique fecha y hora.'; return; }
      var btn = this; btn.disabled = true;
      var cuerpo = { fecha: fe.value, hora: ho.value, texto: texto.value };
      if (edit) cuerpo.id = nota.id; else cuerpo.pcs = pcs;
      enviarNota('nota_guardar', cuerpo).then(function () { cerrarNota(); recargarNotas(fe.value); })
        .catch(function (e) { err.textContent = e.message; btn.disabled = false; });
    };
    document.addEventListener('keydown', function esc(e) {
      if (!document.body.contains(fondo)) { document.removeEventListener('keydown', esc); return; }
      if (e.key === 'Escape') cerrarNota();
    });
    document.body.appendChild(fondo);
    texto.focus();
  }
  // ---- Menú «⋮» del equipo: editar nombre y ver el registro del día --------------------
  function durHMS(s) { s = Math.round(s); return pad(Math.floor(s / 3600)) + ':' + pad(Math.floor(s % 3600 / 60)) + ':' + pad(s % 60); }
  function segHora(h) { var p = h.split(':'); return (+p[0]) * 3600 + (+p[1]) * 60 + (+p[2] || 0); }
  function esc2(fondo) {
    document.addEventListener('keydown', function esc(e) {
      if (!document.body.contains(fondo)) { document.removeEventListener('keydown', esc); return; }
      if (e.key === 'Escape') cerrarNota();
    });
    fondo.addEventListener('mousedown', function (e) { if (e.target === fondo) cerrarNota(); });
  }
  function buscarMaquina(pc) {
    var r = null;
    [estado.maquinas, estado.datos ? estado.datos.maquinas : []].forEach(function (a) { a.forEach(function (x) { if (!r && x.pc === pc) r = x; }); });
    return r;
  }

  // Filas del día de un equipo tal como las guarda el monitor (mismo criterio que la consola local):
  // los EVENTO/INICIO repetidos en varios destinos se unen en una sola fila «todos».
  function filasRegistro(m, fecha) {
    var esHoy = fecha === hoyISO(), lista = [], grupos = {}, seq = 0;
    m.destinos.forEach(function (de) {
      var fs = de.filas.filter(function (f) { return f[0] === fecha; });
      fs.forEach(function (f, i) {
        seq++;
        var tipo = f[2], o = { dest: de.destino, f: f, n: 1, seq: seq, seg: segHora(f[1]), tiempo: '', lat: '', inc: false };
        if (tipo === 'EVENTO' || tipo === 'INICIO') {
          var k = f[1] + '|' + tipo + '|' + (f[5] || '');
          if (grupos[k]) { grupos[k].n++; return; }
          grupos[k] = o;
        } else {
          o.lat = '--';
          if (f[3] !== null) { o.tiempo = durHMS(f[3]); if (tipo === 'OK' && f[4] !== null) o.lat = f[4] + ' ms'; }
          else {
            var cierra = false;
            for (var j = i + 1; j < fs.length; j++) if (fs[j][2] !== 'EVENTO') { cierra = true; break; }
            if (!cierra && esHoy) o.tiempo = 'en curso'; else { o.tiempo = 'incompleto'; o.inc = true; }
          }
        }
        lista.push(o);
      });
    });
    lista.sort(function (a, b) { return b.seg - a.seg || b.seq - a.seq; });
    return lista;
  }

  function abrirRegistro(pc, fecha) {
    cerrarNota();
    var m = estado.datos && estado.datos.maquinas.filter(function (x) { return x.pc === pc; })[0];
    if (!m) return;
    var dias = diasElegidos(), idx = dias.indexOf(fecha);
    if (idx < 0) { dias = [fecha]; idx = 0; }
    var filtro = 'todos', dest = '', MAX = 500;
    var fondo = document.createElement('div'); fondo.className = 'nota-fondo';
    var caja = document.createElement('div'); caja.className = 'nota-caja reg-caja'; fondo.appendChild(caja);
    caja.innerHTML =
      '<div class="reg-cab"><button class="btn" id="rAnt" type="button" aria-label="Día anterior">‹</button><h3></h3><button class="btn" id="rSig" type="button" aria-label="Día siguiente">›</button></div>' +
      '<div class="reg-sub"></div><div class="reg-filtros"></div>' +
      '<div class="reg-tabla" tabindex="0" aria-label="Registro del día"><table><thead><tr><th>Hora</th><th>Destino</th><th>Tipo</th><th class="n">Tiempo</th><th class="n">Lat.</th><th>Mensaje</th></tr></thead><tbody></tbody></table></div>' +
      '<div class="reg-nota"></div><div class="nota-pie"><span class="sep"></span><button class="btn" id="rCerrar" type="button">Cerrar</button></div>';
    var h3 = caja.querySelector('h3'), sub = caja.querySelector('.reg-sub'), filtros = caja.querySelector('.reg-filtros'),
        tb = caja.querySelector('tbody'), nota = caja.querySelector('.reg-nota'), ant = caja.querySelector('#rAnt'), sig = caja.querySelector('#rSig');

    function pintarFiltros() {
      filtros.textContent = '';
      FILTROS_REG.forEach(function (f) {
        var b = document.createElement('button'); b.type = 'button'; b.className = 'reg-f'; b.textContent = f[1];
        b.setAttribute('aria-pressed', filtro === f[0] ? 'true' : 'false');
        b.onclick = function () { filtro = f[0]; pintarFiltros(); pintar(); };
        filtros.appendChild(b);
      });
      if (m.destinos.length > 1) {
        var sel = document.createElement('select'); sel.setAttribute('aria-label', 'Destino');
        var o0 = document.createElement('option'); o0.value = ''; o0.textContent = 'Todos los destinos'; sel.appendChild(o0);
        m.destinos.forEach(function (d) { var o = document.createElement('option'); o.value = d.destino; o.textContent = d.destino; sel.appendChild(o); });
        sel.value = dest; sel.onchange = function () { dest = sel.value; pintar(); };
        filtros.appendChild(sel);
      }
    }
    function pintar() {
      var f = dias[idx], lista = filasRegistro(m, f);
      var vis = lista.filter(function (o) {
        return (filtro === 'todos' || o.f[2] === filtro) && (!dest || o.n > 1 || o.dest === dest);
      });
      h3.textContent = 'Registro · ' + (m.alias || m.pc);
      sub.textContent = MR.fechaLarga(f) + (m.alias && m.alias !== m.pc ? ' · ' + m.pc : '') + ' · ' + lista.length + (lista.length === 1 ? ' registro' : ' registros');
      ant.disabled = idx <= 0; sig.disabled = idx >= dias.length - 1;
      tb.textContent = '';
      var frag = document.createDocumentFragment();
      vis.slice(0, MAX).forEach(function (o) {
        var tr = document.createElement('tr'), tipo = o.f[2];
        function td(cls, txt) { var c = document.createElement('td'); if (cls) c.className = cls; c.textContent = txt; tr.appendChild(c); }
        td('h', o.f[1]); td('', o.n > 1 ? 'todos' : o.dest);
        td(o.inc ? 't-inc' : 't-' + tipo, tipo); td('n', o.tiempo); td('n', o.lat); td('m' + (o.inc ? ' t-inc' : ''), o.f[5] || '');
        frag.appendChild(tr);
      });
      tb.appendChild(frag);
      if (!vis.length) {
        var tr0 = document.createElement('tr'), c0 = document.createElement('td'); c0.colSpan = 6; c0.className = 'vacio';
        c0.textContent = lista.length ? 'Sin registros con este filtro.' : 'Sin registros este día.'; tr0.appendChild(c0); tb.appendChild(tr0);
      }
      nota.textContent = (vis.length > MAX ? 'Mostrando los ' + MAX + ' más recientes de ' + vis.length + '. ' : '') +
        'Cómo leer la barra: cada fila OK o ERROR abre un tramo que dura el «Tiempo» y la barra lo pinta (verde = OK, rojo = ERROR) desde su hora. ' +
        '«en curso» llega hasta el último envío y no se suma; «incompleto» (sin cierre) queda en blanco. Horario del análisis: ' +
        MR.hhmm(estado.ini) + '–' + MR.hhmm(estado.fin) + '.';
    }
    ant.onclick = function () { if (idx > 0) { idx--; pintar(); } };
    sig.onclick = function () { if (idx < dias.length - 1) { idx++; pintar(); } };
    caja.querySelector('#rCerrar').onclick = cerrarNota;
    esc2(fondo);
    pintarFiltros(); pintar();
    document.body.appendChild(fondo);
    caja.querySelector('#rCerrar').focus();
  }

  function abrirNombre(pc) {
    cerrarNota();
    var m = buscarMaquina(pc); if (!m) return;
    var fondo = document.createElement('div'); fondo.className = 'nota-fondo';
    var caja = document.createElement('div'); caja.className = 'nota-caja'; fondo.appendChild(caja);
    caja.innerHTML =
      '<h3>Editar nombre</h3><div class="dato" id="eEquipo"></div>' +
      '<label class="etq2" for="eNombre">Nombre del equipo (se muestra en el panel)</label>' +
      '<input type="text" id="eNombre" maxlength="150" autocomplete="off">' +
      '<div class="nota-err" id="eErr"></div>' +
      '<div class="nota-pie"><button class="btn prim" id="eGuardar" type="button">Guardar</button>' +
      '<button class="btn" id="eCancelar" type="button">Cancelar</button><span class="sep"></span></div>' +
      '<div class="reg-nota">El cambio se ve aquí al instante. El equipo lo adopta en su próxima sincronización de configuración remota (al terminar su siguiente envío de datos) y vuelve a enviar los datos con el nombre nuevo.</div>';
    caja.querySelector('#eEquipo').textContent = 'Equipo (nombre de Windows): ' + m.pc;
    var inp = caja.querySelector('#eNombre'), err = caja.querySelector('#eErr');
    inp.value = m.alias || m.pc;
    caja.querySelector('#eGuardar').onclick = function () {
      var v = inp.value.replace(/\s+/g, ' ').trim(), btn = this;
      if (!v) { err.textContent = 'Escriba el nombre del equipo.'; inp.focus(); return; }
      if (v === (m.alias || m.pc)) { cerrarNota(); return; }   // sin cambios
      err.textContent = ''; btn.disabled = true;
      enviarNota('nombre_guardar', { pc: m.pc, nombre: v }).then(function (j) {
        [estado.maquinas, estado.datos ? estado.datos.maquinas : []].forEach(function (a) {
          a.forEach(function (x) { if (x.pc === j.pc) x.alias = j.alias; });
        });
        cerrarNota(); pintarMaquinas(); rerender();
        aviso(j.instruccion ? 'Nombre actualizado. Se enviará al equipo en su próxima sincronización.' : 'Nombre actualizado en el panel, pero no se pudo enviar al equipo (su nombre no sirve como archivo de configuración remota).');
      }).catch(function (e) { err.textContent = e.message; btn.disabled = false; });
    };
    caja.querySelector('#eCancelar').onclick = cerrarNota;
    inp.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); caja.querySelector('#eGuardar').click(); } });
    esc2(fondo);
    document.body.appendChild(fondo);
    inp.focus(); inp.select();
  }
  var FILTROS_REG = [['todos', 'Todos'], ['ERROR', 'Caídas'], ['OK', 'Recuperaciones'], ['EVENTO', 'Eventos'], ['INICIO', 'Inicios']];

  if (puedeNotas) {
    var fab = document.createElement('button'); fab.type = 'button'; fab.className = 'nota-fab'; fab.textContent = '\u2691 Nota';
    fab.title = 'Anotar en la bitácora (se marca como bandera en la línea de tiempo)';
    fab.onclick = function () { abrirNota(null); };
    document.body.appendChild(fab);
  }

  function rerender() {
    if (!estado.datos) return;
    var o = opciones();
    if (!o.dias.length) { $('reporte').textContent = ''; aviso('Seleccione al menos un día.', true); return; }
    aviso('');
    MR.render(estado.datos, o, $('reporte'));
  }
  ['optCoin', 'optEventos', 'optVacias'].forEach(function (id) { $(id).onchange = function () { rerender(); guardarForm(); }; });

  $('generar').onclick = function () {
    var pcs = seleccionadas();
    if (!pcs.length) { aviso('Seleccione al menos una máquina.', true); return; }
    if (!diasElegidos().length) { aviso('Seleccione al menos un día.', true); return; }
    var clave = estado.desde + '|' + estado.hasta + '|' + pcs.join('|');
    var btn = this; btn.disabled = true; aviso('Consultando registros…');
    api({ accion: 'datos', desde: estado.desde, hasta: estado.hasta, 'pc[]': pcs }).then(function (j) {
      estado.datos = { desde: j.desde, hasta: j.hasta, maquinas: j.maquinas, notas: j.notas || {} };
      // Máquinas seleccionadas sin filas: se muestran igual, vacías
      var tiene = {}; j.maquinas.forEach(function (m) { tiene[m.pc] = true; });
      estado.maquinas.forEach(function (m) {
        if (estado.seleccion[m.pc] && !tiene[m.pc]) estado.datos.maquinas.push({ pc: m.pc, alias: m.alias, destinos: [] });
      });
      estado.datosClave = clave;
      rerender();
      aviso(j.filas + ' registros cargados.');
      $('descargar').disabled = false;
      $('reporte').scrollIntoView({ behavior: 'smooth', block: 'start' });
    }).catch(function (e) { aviso(e.message, true); }).then(function () { btn.disabled = false; });
  };

  // ---- Descargar HTML autocontenido -------------------------------------
  $('descargar').onclick = function () {
    if (!estado.datos) return;
    var o = opciones();
    var json = function (v) { return JSON.stringify(v).replace(/</g, '\\u003c').replace(/[\u2028\u2029]/g, function (c) { return c === '\u2028' ? '\\u2028' : '\\u2029'; }); };
    var css = $('estilos-base').textContent + $('estilos-reporte').textContent +
      '.rep{max-width:1280px;margin:0 auto;padding:16px}';
    var titulo = 'MRV1 · ' + o.titulo;
    var html = '<!DOCTYPE html>\n<html lang="es">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n' +
      '<title>' + titulo.replace(/&/g, '&amp;').replace(/</g, '&lt;') + '</title>\n<style>' + css + '</style>\n</head>\n<body>\n' +
      '<div class="rep"><div id="reporte"></div></div>\n' +
      '<script>' + $('motor').textContent + '<\/script>\n' +
      '<script>\nvar DATOS = ' + json(estado.datos) + ';\nvar OPCIONES = ' + json(o) + ';\n' +
      'MR.render(DATOS, OPCIONES, document.getElementById("reporte"));\n<\/script>\n</body>\n</html>\n';
    var blob = new Blob([html], { type: 'text/html;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'MRV1 analisis ' + estado.desde + ' al ' + estado.hasta + '.html';
    document.body.appendChild(a); a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  };

  // ---- Inicio -------------------------------------------------------------
  cargarForm();
  pintarHorario(); pintarSemana(); cargarMaquinas();
})();
</script>
<?php endif; ?>
</body>
</html>
