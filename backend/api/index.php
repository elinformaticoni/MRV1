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
 *   POST index.php  (clave=…)                          → inicio de sesión (si hay clave configurada)
 *   GET  index.php?salir=1                             → cerrar sesión
 *
 * Control de acceso: si config.php trae 'reporte' => ['clave' => '…'] (no vacía),
 * la página y los endpoints exigen iniciar sesión con esa clave. Si no está
 * configurada, el acceso queda abierto y la página muestra un aviso.
 *
 * Solo LECTURA de la base de datos: este archivo nunca inserta ni modifica filas.
 */

declare(strict_types=1);

require __DIR__ . '/lib/util.php';
require __DIR__ . '/lib/db.php';

ini_set('display_errors', '0');

const MR_MAX_DIAS_RANGO   = 31;      // rango máximo por consulta (la SPA pide 7)
const MR_MAX_PCS_CONSULTA = 100;     // máquinas por consulta de datos
const MR_MAX_FILAS        = 200000;  // tope de filas por consulta de datos
const MR_URL_PAQUETE      = 'https://github.com/elinformaticoni/MRV1/archive/refs/heads/main.zip'; // instalador del monitor

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

// --- Endpoints JSON -----------------------------------------------------
$accion = (string) ($_GET['accion'] ?? '');
if ($accion !== '') {
    mr_instalar_manejador_errores();
    if (!$autenticado) {
        mr_error(401, 'Sesión no iniciada.');
    }
    header('Cache-Control: no-store');

    [$desde, $hasta] = mr_rango_fechas();

    try {
        $pdo = mr_db();
        if ($accion === 'maquinas') {
            mr_json_response(200, mr_consultar_maquinas($pdo, $desde, $hasta));
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
    usort($lista, fn($a, $b) => strcasecmp($a['alias'] ?: $a['pc'], $b['alias'] ?: $b['pc']));

    return ['ok' => true, 'desde' => $desde, 'hasta' => $hasta, 'maquinas' => $lista];
}

/**
 * Filas de las máquinas pedidas en el rango, agrupadas por pc → destino.
 * Cada fila: [fecha, hora, tipo, tiempo_s|null, latencia_ms|null, mensaje|null]
 */
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
            $lista[] = $maq[$pc];
        }
    }

    return ['ok' => true, 'desde' => $desde, 'hasta' => $hasta, 'filas' => $n, 'maquinas' => $lista];
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
  --ok:rgba(22,163,74,.16); --ok-wifi:rgba(22,163,74,.38); --err:#d92d20; --inc:#9aa4b1; --wifi:#2f6fde; --cable:#7a4cc2; --sinred:#b8c0ca;
  --ev:#2563eb; --ini:#60a5fa; --coin:rgba(234,88,12,.16); --coin-borde:rgba(234,88,12,.75); --verde:#16a34a; --banda-ok:rgba(22,163,74,.09); --banda-ok-borde:rgba(22,163,74,.35);
  --pista:#f8fafc; --sombra:0 1px 2px rgba(16,24,40,.06),0 1px 3px rgba(16,24,40,.08);
  color-scheme:light;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    --bg:#11161c; --panel:#1a2129; --texto:#e6ebf0; --suave:#a9b4c0; --tenue:#7b8794;
    --borde:#2c3642; --grid:#27313c; --acento:#4c9be8; --acento-t:#0b1520;
    --ok:rgba(50,213,131,.10); --ok-wifi:rgba(50,213,131,.26); --err:#f04438; --inc:#5e6a77; --wifi:#5b8def; --cable:#a07ae0; --sinred:#4a5561;
    --ev:#5b8def; --ini:#93b8f5; --coin:rgba(251,146,60,.16); --coin-borde:rgba(251,146,60,.8); --verde:#32d583; --banda-ok:rgba(50,213,131,.08); --banda-ok-borde:rgba(50,213,131,.35);
    --pista:#151b22; --sombra:none; color-scheme:dark;
  }
}
:root[data-theme="dark"]{
  --bg:#11161c; --panel:#1a2129; --texto:#e6ebf0; --suave:#a9b4c0; --tenue:#7b8794;
  --borde:#2c3642; --grid:#27313c; --acento:#4c9be8; --acento-t:#0b1520;
  --ok:rgba(50,213,131,.10); --ok-wifi:rgba(50,213,131,.26); --err:#f04438; --inc:#5e6a77; --wifi:#5b8def; --cable:#a07ae0; --sinred:#4a5561;
  --ev:#5b8def; --ini:#93b8f5; --coin:rgba(251,146,60,.16); --coin-borde:rgba(251,146,60,.8); --verde:#32d583; --banda-ok:rgba(50,213,131,.08); --banda-ok-borde:rgba(50,213,131,.35);
  --pista:#151b22; --sombra:none; color-scheme:dark;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--texto);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,Ubuntu,sans-serif}
button,select,input{font:inherit;color:inherit}
</style>
<style id="estilos-app">
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
input[type=date],select{border:1px solid var(--borde);background:var(--panel);border-radius:7px;padding:5px 8px}
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
.maq{display:flex;gap:9px;align-items:flex-start;border:1px solid var(--borde);border-radius:8px;padding:8px 10px;cursor:pointer}
.maq:has(input:checked){border-color:var(--acento);background:color-mix(in srgb,var(--acento) 8%,transparent)}
.maq input{margin-top:3px}
.maq .nom{font-weight:600;overflow-wrap:anywhere}
.maq .pc{font-size:12px;color:var(--suave)}
.maq .dests{display:flex;gap:4px;flex-wrap:wrap;margin-top:4px}
.chip{font-size:11px;border:1px solid var(--borde);border-radius:999px;padding:1px 7px;color:var(--suave);white-space:nowrap}
.chip.err{border-color:color-mix(in srgb,var(--err) 50%,transparent);color:var(--err)}
.vacio{color:var(--suave);font-size:13px;padding:10px 0}
.opciones{display:flex;gap:16px;flex-wrap:wrap;align-items:center}
.opciones label{display:flex;gap:6px;align-items:center;cursor:pointer}
.acciones{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.estado{font-size:13px;color:var(--suave)}
.estado.error{color:var(--err)}
@media (max-width:900px){.form{grid-template-columns:1fr}}
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

.mr-lbl{font-size:12px;color:var(--suave);padding-left:10px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mr-pista{position:relative;height:16px;background:transparent;box-shadow:inset 0 0 0 1px var(--grid);border-radius:3px;overflow:hidden}
.mr-cuerpo{position:relative}
.mr-cuerpo>.mr-fila,.mr-cuerpo>.mr-maq{position:relative;z-index:1}
.mr-coin-capa{position:absolute;top:0;bottom:0;left:var(--col-lbl);right:var(--col-tot);z-index:0;pointer-events:none}
.mr-coin{position:absolute;top:0;bottom:0;min-width:2px;background:var(--coin);border-left:1px solid var(--coin-borde);border-right:1px solid var(--coin-borde)}
.mr-eje .mr-coin-tk{position:absolute;bottom:-2px;height:6px;min-width:4px;background:var(--coin-borde);border-radius:2px;z-index:2;cursor:help}
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
<div class="app" style="max-width:380px;padding-top:12vh">
  <div class="panel">
    <h1 style="font-size:18px;margin:0 0 4px">MRV1 · Análisis semanal</h1>
    <p class="estado" style="margin:0 0 14px">Ingrese la clave de acceso a los reportes.</p>
    <form method="post" autocomplete="off">
      <input type="password" name="clave" required autofocus
             style="width:100%;border:1px solid var(--borde);background:var(--panel);border-radius:7px;padding:8px 10px;margin-bottom:10px">
      <?php if ($errorLogin !== ''): ?><p class="estado error" style="margin:0 0 10px"><?= $h($errorLogin) ?></p><?php endif; ?>
      <button class="btn prim" type="submit" style="width:100%">Entrar</button>
    </form>
  </div>
  <div class="panel descarga">
    <p class="estado" style="margin:0 0 10px">¿Solo necesita instalar el monitor en una PC?</p>
    <a class="btn descargar-mon" href="<?= $h(MR_URL_PAQUETE) ?>" rel="noopener">⬇ DESCARGA EL MONITOR</a>
    <p class="estado" style="margin:10px 0 0;font-size:12px">Paquete MRV1 (ZIP desde GitHub). Descomprima y ejecute <code>Instalar_Monitor.bat</code> como administrador.</p>
  </div>
</div>
<?php else: ?>
<div class="app">
  <div class="barra">
    <h1>Monitor de Red · Análisis semanal</h1>
    <span class="sub">Caídas de conectividad por máquina y destino</span>
    <div class="der"><a href="<?= $h(MR_URL_PAQUETE) ?>" rel="noopener" title="Paquete MRV1 (ZIP desde GitHub)">⬇ Descargar el monitor</a><?php if ($requiereLog): ?><a href="?salir=1">Cerrar sesión</a><?php endif; ?></div>
  </div>
  <?php if (!$requiereLog): ?>
  <div class="aviso">Acceso sin clave: cualquiera que abra esta dirección puede ver los registros. Para protegerla, agregue <code>'reporte' => ['clave' => '…']</code> en <code>config/config.php</code>.</div>
  <?php endif; ?>

  <div class="panel">
    <div class="form">
      <div class="bloque">
        <span class="etq">Semana</span>
        <div class="fila-ctl">
          <button class="btn" id="semAnt" type="button" title="Semana anterior" aria-label="Semana anterior">◀</button>
          <input type="date" id="semFecha" aria-label="Cualquier día de la semana">
          <button class="btn" id="semSig" type="button" title="Semana siguiente" aria-label="Semana siguiente">▶</button>
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
        <span class="etq" style="display:flex;gap:10px;align-items:center">Máquinas con registros en la semana
          <span style="margin-left:auto;display:flex;gap:6px;text-transform:none;letter-spacing:0;font-weight:400">
            <button class="btn chico" id="maqTodas" type="button">Todas</button>
            <button class="btn chico" id="maqNinguna" type="button">Ninguna</button>
          </span>
        </span>
        <div class="maqs" id="maqs"><div class="vacio">Cargando…</div></div>
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
      var filasPorDia = {};
      m.destinos.forEach(function (de) {
        de.filas.forEach(function (f) {
          if (!porDia[f[0]]) return;
          var fd = filasPorDia[f[0]] || (filasPorDia[f[0]] = {});
          (fd[de.destino] || (fd[de.destino] = [])).push(f);
        });
      });
      opc.dias.forEach(function (d) {
        var dia = porDia[d], fd = filasPorDia[d] || {};
        var maq = { pc: m.pc, alias: m.alias, destinos: [], adapt: [], hayDatos: false, caidas: 0, completa: false };
        var todas = [], cobertura = [], crudos = [];
        m.destinos.forEach(function (de) {
          var filas = fd[de.destino] || [];
          var r = segmentosDia(filas, d, ahora);
          r.segs.forEach(function (sg) { cobertura.push({ a: sg.a, b: sg.b }); });
          filas.forEach(function (f) { todas.push(f); });
          crudos.push({ destino: de.destino, filas: filas, r: r });
        });
        maq.adapt = adaptadoresDia(todas, unir(cobertura));
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
      if (m.alias && m.alias !== m.pc) nom.appendChild(el('small', null, m.pc));
      if (m.completa) nom.appendChild(el('small', 'ok', '✓ sin caídas'));
      bloque.appendChild(nom);

      if (!m.destinos.length) {
        var fv = el('div', 'mr-fila'); fv.appendChild(el('div', 'mr-lbl', '—'));
        var pv = pista(ini, fin); pv.appendChild(el('div', 'mr-nodata', 'sin registros')); fv.appendChild(pv);
        fv.appendChild(el('div', 'mr-tot cero', '—')); bloque.appendChild(fv);
      }
      m.destinos.forEach(function (de) {
        var f = el('div', 'mr-fila');
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
    lunes: lunesDe(hoyISO()),
    dias: [true, true, true, true, true, false, false],   // Lun–Vie por defecto
    ini: 7 * 3600, fin: 15 * 3600,                        // 7:00 a 15:00 por defecto
    maquinas: [], seleccion: {}, datos: null, datosClave: '',
    redes: { cable: true, wifi: false }   // Wi-Fi oculto por defecto (se cambia en el reporte)
  };

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
    estado.ini = a; estado.fin = b; pintarHorario(); rerender();
  }
  $('horaIni').onchange = function () { cambiarHorario('ini'); };
  $('horaFin').onchange = function () { cambiarHorario('fin'); };
  $('horaJornada').onclick = function () { estado.ini = 7 * 3600; estado.fin = 15 * 3600; pintarHorario(); rerender(); };
  $('horaDia').onclick = function () { estado.ini = 0; estado.fin = 86400; pintarHorario(); rerender(); };

  // ---- Semana y días ----------------------------------------------------
  function diasConDatos() {
    var c = {};
    estado.maquinas.forEach(function (m) { if (estado.seleccion[m.pc]) m.dias.forEach(function (d) { c[d] = true; }); });
    return c;
  }
  function pintarSemana() {
    var l = estado.lunes, dmg = sumar(l, 6);
    $('semFecha').value = l;
    $('semTxt').textContent = 'Semana ' + semanaISO(l) + ' · lunes ' + dm(l) + ' a domingo ' + dm(dmg) + ' ' + parseISO(dmg).getUTCFullYear() +
      (l === lunesDe(hoyISO()) ? ' (semana actual)' : '');
    var cont = $('dias'); cont.textContent = '';
    var cd = diasConDatos();
    DIAS_C.forEach(function (n, i) {
      var f = sumar(l, i);
      var lab = document.createElement('label'); lab.className = 'dia-chk' + (cd[f] ? ' con-datos' : '');
      lab.title = cd[f] ? 'Con registros' : 'Sin registros de las máquinas seleccionadas';
      var c = document.createElement('input'); c.type = 'checkbox'; c.checked = estado.dias[i];
      c.onchange = function () { estado.dias[i] = c.checked; rerender(); };
      var a = document.createElement('span'); a.className = 'n'; a.textContent = n;
      var b = document.createElement('span'); b.className = 'd'; b.textContent = parseISO(f).getUTCDate();
      var p = document.createElement('span'); p.className = 'pt';
      lab.append(c, a, b, p); cont.appendChild(lab);
    });
  }
  function irSemana(lunes) {
    estado.lunes = lunes; estado.datos = null; estado.datosClave = '';
    $('reporte').textContent = ''; $('descargar').disabled = true;
    pintarSemana(); cargarMaquinas();
  }
  $('semAnt').onclick = function () { irSemana(sumar(estado.lunes, -7)); };
  $('semSig').onclick = function () { irSemana(sumar(estado.lunes, 7)); };
  $('semHoy').onclick = function () { irSemana(lunesDe(hoyISO())); };
  $('semFecha').onchange = function () { if (this.value) irSemana(lunesDe(this.value)); };

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
    var n = ++pedidoMaq, l = estado.lunes;
    $('maqs').innerHTML = '<div class="vacio">Cargando máquinas…</div>';
    api({ accion: 'maquinas', desde: l, hasta: sumar(l, 6) }).then(function (j) {
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
  function pintarMaquinas() {
    var c = $('maqs'); c.textContent = '';
    if (!estado.maquinas.length) {
      var v = document.createElement('div'); v.className = 'vacio'; v.textContent = 'Ninguna máquina envió registros en esta semana.'; c.appendChild(v);
      return;
    }
    estado.maquinas.forEach(function (m) {
      var lab = document.createElement('label'); lab.className = 'maq';
      var chk = document.createElement('input'); chk.type = 'checkbox'; chk.checked = !!estado.seleccion[m.pc];
      chk.onchange = function () { estado.seleccion[m.pc] = chk.checked; pintarSemana(); };
      var info = document.createElement('div'); info.style.minWidth = '0';
      var nom = document.createElement('div'); nom.className = 'nom'; nom.textContent = m.alias || m.pc;
      var pc = document.createElement('div'); pc.className = 'pc';
      pc.textContent = (m.alias && m.alias !== m.pc ? m.pc + ' · ' : '') + m.dias.length + (m.dias.length === 1 ? ' día' : ' días') + ' con datos';
      var ds = document.createElement('div'); ds.className = 'dests';
      m.destinos.forEach(function (d) {
        var ch = document.createElement('span'); ch.className = 'chip' + (d.errores ? ' err' : '');
        ch.textContent = d.destino + (d.errores ? ' · ' + d.errores + ' err' : '');
        ch.title = d.registros + ' registros, ' + d.errores + ' con ERROR en la semana';
        ds.appendChild(ch);
      });
      info.append(nom, pc, ds); lab.append(chk, info); c.appendChild(lab);
    });
  }
  $('maqTodas').onclick = function () { estado.maquinas.forEach(function (m) { estado.seleccion[m.pc] = true; }); pintarMaquinas(); pintarSemana(); };
  $('maqNinguna').onclick = function () { estado.maquinas.forEach(function (m) { estado.seleccion[m.pc] = false; }); pintarMaquinas(); pintarSemana(); };

  // ---- Generar -----------------------------------------------------------
  function seleccionadas() { return estado.maquinas.filter(function (m) { return estado.seleccion[m.pc]; }).map(function (m) { return m.pc; }); }
  function diasElegidos() { var r = []; estado.dias.forEach(function (on, i) { if (on) r.push(sumar(estado.lunes, i)); }); return r; }
  function opciones() {
    var n = new Date(), dms = sumar(estado.lunes, 6);
    return {
      dias: diasElegidos(), ini: estado.ini, fin: estado.fin,
      coincidencias: $('optCoin').checked, redes: estado.redes, eventos: $('optEventos').checked, vacias: $('optVacias').checked,
      ahora: { fecha: hoyISO(), s: n.getHours() * 3600 + n.getMinutes() * 60 + n.getSeconds() },
      titulo: 'Semana ' + semanaISO(estado.lunes) + ' · ' + dm(estado.lunes) + ' al ' + dm(dms) + ' ' + parseISO(dms).getUTCFullYear(),
      generado: hoyISO() + ' ' + pad(n.getHours()) + ':' + pad(n.getMinutes())
    };
  }
  function rerender() {
    if (!estado.datos) return;
    var o = opciones();
    if (!o.dias.length) { $('reporte').textContent = ''; aviso('Seleccione al menos un día.', true); return; }
    aviso('');
    MR.render(estado.datos, o, $('reporte'));
  }
  ['optCoin', 'optEventos', 'optVacias'].forEach(function (id) { $(id).onchange = rerender; });

  $('generar').onclick = function () {
    var pcs = seleccionadas();
    if (!pcs.length) { aviso('Seleccione al menos una máquina.', true); return; }
    if (!diasElegidos().length) { aviso('Seleccione al menos un día.', true); return; }
    var clave = estado.lunes + '|' + pcs.join('|');
    var btn = this; btn.disabled = true; aviso('Consultando registros…');
    api({ accion: 'datos', desde: estado.lunes, hasta: sumar(estado.lunes, 6), 'pc[]': pcs }).then(function (j) {
      estado.datos = { desde: j.desde, hasta: j.hasta, maquinas: j.maquinas };
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
    a.download = 'MRV1 analisis ' + estado.lunes + ' al ' + sumar(estado.lunes, 6) + '.html';
    document.body.appendChild(a); a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  };

  // ---- Inicio -------------------------------------------------------------
  pintarHorario(); pintarSemana(); cargarMaquinas();
})();
</script>
<?php endif; ?>
</body>
</html>
