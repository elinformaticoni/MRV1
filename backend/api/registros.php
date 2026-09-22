<?php
/**
 * Monitor de Red — Backend de análisis
 * POST /api/registros.php
 *
 * Recibido desde Cargador_DB.ps1 (ver backend/IA.md secciones 3 y 5).
 *
 * Cuerpo esperado:
 * {
 *   "pc": "LABORATORIO-PC",
 *   "alias": "Laboratorio 2 - Edificio A",   // opcional, se envía siempre (D9)
 *   "destino": "8.8.8.8",
 *   "filas": [
 *     { "fecha": "2026-09-22", "hora": "07:00:05", "tipo": "OK",
 *       "tiempo_s": 252, "latencia_ms": 32, "mensaje": "Conectividad disponible [Success]" }
 *   ]
 * }
 *
 * Header requerido: X-MR-Token: <token global>
 *
 * Respuesta:
 * { "ok": true, "insertadas": 3, "actualizadas": 1, "total": 4 }
 */

declare(strict_types=1);

require __DIR__ . '/lib/util.php';
require __DIR__ . '/lib/db.php';

// A partir de aqui, cualquier error no controlado (incluida una conexion a MySQL
// fallida) responde JSON en vez de dejar una pagina en blanco con 500.
mr_instalar_manejador_errores();

// --- Método y token -------------------------------------------------
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    mr_error(405, 'Método no permitido. Usa POST.');
}
mr_validar_token();

// --- Cuerpo y validación de forma ------------------------------------
$body = mr_leer_cuerpo_json();

$pc      = trim((string) ($body['pc'] ?? ''));
$alias   = array_key_exists('alias', $body) ? trim((string) $body['alias']) : '';
$destino = trim((string) ($body['destino'] ?? ''));
$filas   = $body['filas'] ?? null;

if ($pc === '') {
    mr_error(422, 'Falta "pc".');
}
if ($destino === '') {
    mr_error(422, 'Falta "destino".');
}
if (!is_array($filas) || count($filas) === 0) {
    mr_error(422, 'Falta "filas" (debe ser un arreglo no vacío).');
}

$cfg = mr_config();
$maxFilas = (int) ($cfg['limites']['max_filas_por_envio'] ?? 500);
if (count($filas) > $maxFilas) {
    mr_error(413, "El envío trae más de $maxFilas filas; divídelo en varias cargas.");
}

$tiposValidos = ['INICIO', 'OK', 'ERROR', 'EVENTO'];
$fechaRe = '/^\d{4}-\d{2}-\d{2}$/';
$horaRe  = '/^\d{2}:\d{2}:\d{2}$/';

$filasValidas = [];
foreach ($filas as $i => $f) {
    if (!is_array($f)) {
        mr_error(422, "La fila $i no es un objeto válido.");
    }
    $fecha = (string) ($f['fecha'] ?? '');
    $hora  = (string) ($f['hora'] ?? '');
    $tipo  = strtoupper((string) ($f['tipo'] ?? ''));

    if (!preg_match($fechaRe, $fecha)) {
        mr_error(422, "Fila $i: \"fecha\" inválida (esperado AAAA-MM-DD).");
    }
    if (!preg_match($horaRe, $hora)) {
        mr_error(422, "Fila $i: \"hora\" inválida (esperado HH:MM:SS).");
    }
    if (!in_array($tipo, $tiposValidos, true)) {
        mr_error(422, "Fila $i: \"tipo\" inválido ($tipo).");
    }

    $tiempo_s    = isset($f['tiempo_s']) && $f['tiempo_s'] !== '' ? (int) $f['tiempo_s'] : null;
    $latencia_ms = isset($f['latencia_ms']) && $f['latencia_ms'] !== '' ? (int) $f['latencia_ms'] : null;
    $mensaje     = isset($f['mensaje']) && $f['mensaje'] !== '' ? (string) $f['mensaje'] : null;

    $filasValidas[] = [
        'fecha'       => $fecha,
        'hora'        => $hora,
        'tipo'        => $tipo,
        'tiempo_s'    => $tiempo_s,
        'latencia_ms' => $latencia_ms,
        'mensaje'     => $mensaje,
    ];
}

// --- Escritura en MySQL ----------------------------------------------
// mr_db() tambien va dentro del try: si la conexion falla (credenciales, host,
// extension pdo_mysql no habilitada, etc.) ahora responde JSON 500 en vez de
// dejar pasar una excepcion no controlada (causaba pagina en blanco).
try {
    $pdo = mr_db();
    $pdo->beginTransaction();

    // computadoras: autoregistro del PC y, si vino, del alias (D6/D9).
    if ($alias !== '') {
        $stmtPc = $pdo->prepare(
            'INSERT INTO computadoras (pc, alias) VALUES (:pc, :alias)
             ON DUPLICATE KEY UPDATE alias = VALUES(alias)'
        );
        $stmtPc->execute(['pc' => $pc, 'alias' => $alias]);
    } else {
        $stmtPc = $pdo->prepare(
            'INSERT INTO computadoras (pc) VALUES (:pc)
             ON DUPLICATE KEY UPDATE pc = pc'
        );
        $stmtPc->execute(['pc' => $pc]);
    }

    // registros: upsert por la clave de sincronización (D5).
    // ROW_COUNT() de MySQL: 1 = insertada, 2 = actualizada (fila existía y cambió),
    // 0 = ya existía igual (no se tocó). Se usa para el resumen de la respuesta.
    $stmtReg = $pdo->prepare(
        'INSERT INTO registros (pc, destino, fecha, hora, tipo, tiempo_s, latencia_ms, mensaje)
         VALUES (:pc, :destino, :fecha, :hora, :tipo, :tiempo_s, :latencia_ms, :mensaje)
         ON DUPLICATE KEY UPDATE
            tiempo_s    = VALUES(tiempo_s),
            latencia_ms = VALUES(latencia_ms)'
    );

    $insertadas = 0;
    $actualizadas = 0;
    $sinCambios = 0;

    foreach ($filasValidas as $f) {
        $stmtReg->execute([
            'pc'          => $pc,
            'destino'     => $destino,
            'fecha'       => $f['fecha'],
            'hora'        => $f['hora'],
            'tipo'        => $f['tipo'],
            'tiempo_s'    => $f['tiempo_s'],
            'latencia_ms' => $f['latencia_ms'],
            'mensaje'     => $f['mensaje'],
        ]);
        switch ($stmtReg->rowCount()) {
            case 1:
                $insertadas++;
                break;
            case 2:
                $actualizadas++;
                break;
            default:
                $sinCambios++;
        }
    }

    $pdo->commit();
} catch (Throwable $e) {
    if (isset($pdo) && $pdo->inTransaction()) {
        $pdo->rollBack();
    }
    error_log('[MR registros.php] ' . $e->getMessage());
    $extra = mr_debug_habilitado() ? ['detalle' => $e->getMessage()] : [];
    mr_error(500, 'Error interno al guardar los registros.', $extra);
}

mr_json_response(200, [
    'ok'           => true,
    'insertadas'   => $insertadas,
    'actualizadas' => $actualizadas,
    'sin_cambios'  => $sinCambios,
    'total'        => count($filasValidas),
]);
