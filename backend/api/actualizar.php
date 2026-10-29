<?php
/**
 * Monitor de Red — Backend de análisis
 * actualizar.php — Actualización automática de los scripts de las PC (MRV1.12).
 *
 * El servidor PUBLICA una versión (manifiesto firmado + archivos) y cada PC, por su
 * cuenta (Actualizar_Script.ps1), la descarga, verifica la firma y los hash y reemplaza
 * sus scripts. Sin reinstalar. Ver backend/IA.md sección 5.2.
 *
 *   GET  actualizar.php?accion=manifiesto          → manifest.json (X-MR-Token)
 *   GET  actualizar.php?accion=firma               → manifest.sig, firma RSA-SHA256 en base64 (X-MR-Token)
 *   GET  actualizar.php?accion=archivo&nombre=X    → un archivo del manifiesto (X-MR-Token)
 *   POST actualizar.php?accion=confirmar           → { "pc", "version", "ok", "detalle" } (X-MR-Token)
 *   GET  actualizar.php?accion=versiones           → versión que informó cada PC (X-MR-Token)
 *
 * Todo vive en api/update/ (protegida por .htaccess: nunca se sirve directo, así el token
 * siempre controla el acceso). El contenido lo genera backend/tools/Publicar_Actualizacion.ps1.
 * El servidor NUNCA firma nada: la clave privada solo existe en la PC de quien publica, y las
 * PC verifican la firma con la clave pública que se instaló con el paquete. Un servidor
 * comprometido no puede, por tanto, mandar código a las PC.
 */

declare(strict_types=1);

require __DIR__ . '/lib/util.php';
require __DIR__ . '/lib/db.php';   // mr_config() (token); no se abre ninguna conexión a la base

const MR_UPD_DIR     = __DIR__ . '/update';
const MR_UPD_PAQUETE = MR_UPD_DIR . '/paquete';
const MR_UPD_PCS     = MR_UPD_DIR . '/pcs';

mr_instalar_manejador_errores();
mr_validar_token();
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

$accion = (string) ($_GET['accion'] ?? '');
$metodo = (string) ($_SERVER['REQUEST_METHOD'] ?? '');

/** Devuelve el manifiesto decodificado o corta con 404 si todavía no se publicó nada. */
function mr_upd_manifiesto(): array
{
    $ruta = MR_UPD_DIR . '/manifest.json';
    $crudo = is_file($ruta) ? file_get_contents($ruta) : false;
    $m = $crudo === false ? null : json_decode($crudo, true);
    if (!is_array($m) || !is_array($m['files'] ?? null)) {
        mr_error(404, 'No hay ninguna actualización publicada.');
    }
    return $m;
}

function mr_upd_enviar(string $ruta, string $tipo): void
{
    http_response_code(200);
    header('Content-Type: ' . $tipo);
    header('Content-Length: ' . (string) filesize($ruta));
    readfile($ruta);
    exit;
}

if ($accion === 'manifiesto' || $accion === 'firma') {
    if ($metodo !== 'GET') { mr_error(405, 'Método no permitido. Usa GET.'); }
    mr_upd_manifiesto();
    if ($accion === 'manifiesto') {
        mr_upd_enviar(MR_UPD_DIR . '/manifest.json', 'application/json; charset=utf-8');
    }
    $sig = MR_UPD_DIR . '/manifest.sig';
    if (!is_file($sig)) { mr_error(404, 'El manifiesto publicado no tiene firma.'); }
    mr_upd_enviar($sig, 'text/plain; charset=utf-8');
}

if ($accion === 'archivo') {
    if ($metodo !== 'GET') { mr_error(405, 'Método no permitido. Usa GET.'); }
    $nombre = (string) ($_GET['nombre'] ?? '');
    if (!preg_match('/^[A-Za-z0-9_.-]{1,80}$/', $nombre)) { mr_error(422, 'Parámetro "nombre" inválido.'); }
    $enManifiesto = false;
    foreach (mr_upd_manifiesto()['files'] as $f) {
        if (is_array($f) && ($f['name'] ?? null) === $nombre) { $enManifiesto = true; break; }
    }
    $ruta = MR_UPD_PAQUETE . '/' . $nombre;
    if (!$enManifiesto || !is_file($ruta)) { mr_error(404, 'Archivo no publicado.'); }
    mr_upd_enviar($ruta, 'application/octet-stream');
}

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
    if (!is_dir(MR_UPD_PCS) && !@mkdir(MR_UPD_PCS, 0755, true) && !is_dir(MR_UPD_PCS)) {
        mr_error(500, 'No se pudo crear la carpeta de registro de versiones.');
    }
    $registro = [
        'pc'      => $pc,
        'version' => $ver,
        'ok'      => (bool) ($body['ok'] ?? true),
        'resultado' => $resultado,
        'detalle' => $detalle,
        'en'      => date('Y-m-d H:i:s'),
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
