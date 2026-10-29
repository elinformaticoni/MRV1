<?php
/**
 * Monitor de Red — Backend de análisis
 * actualizar.php — Versión de scripts que informa cada PC (MRV1.13.6).
 *
 * Las actualizaciones NO se publican aquí: las PC las toman de las etiquetas vX.Y.Z del
 * repositorio de GitHub (ver sistema/MRV1.11.md 10.7). Este archivo solo registra qué
 * versión tiene cada PC y cómo le fue en su última consulta, para mostrarlo junto al
 * nombre de cada máquina en index.php y zombie.php.
 *
 *   POST actualizar.php?accion=confirmar   → { "pc", "version", "ok", "resultado", "detalle", "remota" } (X-MR-Token)
 *   GET  actualizar.php?accion=versiones   → versión que informó cada PC (X-MR-Token)
 *
 * Los registros viven en api/update/pcs/<pc>.json (carpeta protegida por .htaccess: nunca se
 * sirve directo, así el token siempre controla el acceso). Ver backend/IA.md sección 5.2.
 */

declare(strict_types=1);

require __DIR__ . '/lib/util.php';
require __DIR__ . '/lib/db.php';   // mr_config() (token); no se abre ninguna conexión a la base

const MR_UPD_DIR = __DIR__ . '/update';
const MR_UPD_PCS = MR_UPD_DIR . '/pcs';

mr_instalar_manejador_errores();
mr_validar_token();
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

$accion = (string) ($_GET['accion'] ?? '');
$metodo = (string) ($_SERVER['REQUEST_METHOD'] ?? '');

if ($accion === 'confirmar') {
    if ($metodo !== 'POST') { mr_error(405, 'Método no permitido. Usa POST.'); }
    $body = mr_leer_cuerpo_json();
    $pc  = trim((string) ($body['pc'] ?? ''));
    $ver = trim((string) ($body['version'] ?? ''));
    if (!preg_match('/^[A-Za-z0-9._-]{1,63}$/', $pc)) { mr_error(422, 'Campo "pc" inválido.'); }
    if (!preg_match('/^\d+(\.\d+){1,3}$/', $ver)) { mr_error(422, 'Campo "version" inválido.'); }
    $detalle = mb_substr(trim((string) ($body['detalle'] ?? '')), 0, 300);
    $resultado = (string) ($body['resultado'] ?? '');
    if (!in_array($resultado, ['actualizada', 'al_dia', 'revertida', 'error', 'firma_invalida', 'manifiesto_invalido', 'sin_clave'], true)) {
        $resultado = '';
    }
    // Versión más reciente que la PC vio en las etiquetas de GitHub (sirve para marcar a las que están atrasadas).
    $remota = trim((string) ($body['remota'] ?? ''));
    if (!preg_match('/^\d+(\.\d+){1,3}$/', $remota)) { $remota = ''; }
    if (!is_dir(MR_UPD_PCS) && !@mkdir(MR_UPD_PCS, 0755, true) && !is_dir(MR_UPD_PCS)) {
        mr_error(500, 'No se pudo crear la carpeta de registro de versiones.');
    }
    $registro = [
        'pc'        => $pc,
        'version'   => $ver,
        'ok'        => (bool) ($body['ok'] ?? true),
        'resultado' => $resultado,
        'detalle'   => $detalle,
        'remota'    => $remota,
        'en'        => date('Y-m-d H:i:s'),
    ];
    $destino = MR_UPD_PCS . '/' . strtolower($pc) . '.json';
    if (file_put_contents($destino, json_encode($registro, JSON_UNESCAPED_UNICODE), LOCK_EX) === false) {
        mr_error(500, 'No se pudo guardar el registro.');
    }
    mr_json_response(200, ['ok' => true]);
}

if ($accion === 'versiones') {
    if ($metodo !== 'GET') { mr_error(405, 'Método no permitido. Usa GET.'); }
    $lista = [];
    foreach (glob(MR_UPD_PCS . '/*.json') ?: [] as $f) {
        $d = json_decode((string) file_get_contents($f), true);
        if (is_array($d)) { $lista[] = $d; }
    }
    mr_json_response(200, ['ok' => true, 'publicada' => mr_version_publicada(), 'pcs' => $lista]);
}

mr_error(400, 'Acción no reconocida.');
