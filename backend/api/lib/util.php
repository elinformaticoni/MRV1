<?php
/**
 * Monitor de Red — Backend de análisis
 * Utilidades comunes de la API: respuestas JSON, validación de token,
 * lectura de cuerpo JSON.
 */

declare(strict_types=1);

function mr_json_response(int $codigoHttp, array $payload): void
{
    if (!headers_sent()) {
        http_response_code($codigoHttp);
        header('Content-Type: application/json; charset=utf-8');
    }
    echo json_encode($payload, JSON_UNESCAPED_UNICODE);
    exit;
}

function mr_error(int $codigoHttp, string $mensaje, array $extra = []): void
{
    mr_json_response($codigoHttp, array_merge(['ok' => false, 'error' => $mensaje], $extra));
}

/**
 * Convierte CUALQUIER error no controlado (excepción no capturada, error fatal de
 * PHP, warning que antes hubiera dejado una pagina en blanco) en una respuesta JSON
 * en vez de una pantalla en blanco con 500 sin cuerpo. Llamar una sola vez, al
 * principio de cada script publico de la API (ver registros.php).
 *
 * El detalle real del error va SOLO al log del servidor (error_log), nunca al
 * cliente, salvo que mr_debug_habilitado() este activo (ver mas abajo).
 */
function mr_instalar_manejador_errores(): void
{
    ini_set('display_errors', '0');
    error_reporting(E_ALL);

    set_exception_handler(function (Throwable $e): void {
        error_log('[MR] Excepcion no controlada: ' . $e->getMessage() . ' en ' . $e->getFile() . ':' . $e->getLine());
        $extra = mr_debug_habilitado() ? ['detalle' => $e->getMessage()] : [];
        mr_error(500, 'Error interno del servidor.', $extra);
    });

    set_error_handler(function (int $severidad, string $mensaje, string $archivo, int $linea): bool {
        if (!(error_reporting() & $severidad)) { return false; }
        throw new ErrorException($mensaje, 0, $severidad, $archivo, $linea);
    });

    register_shutdown_function(function (): void {
        $err = error_get_last();
        if ($err && in_array($err['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) {
            error_log('[MR] Error fatal: ' . $err['message'] . ' en ' . $err['file'] . ':' . $err['line']);
            if (!headers_sent()) {
                http_response_code(500);
                header('Content-Type: application/json; charset=utf-8');
            }
            $extra = mr_debug_habilitado() ? ['detalle' => $err['message']] : [];
            echo json_encode(array_merge(['ok' => false, 'error' => 'Error interno del servidor.'], $extra), JSON_UNESCAPED_UNICODE);
        }
    });
}

/**
 * true solo si config.php trae "debug" => true (nunca activarlo en produccion:
 * expondria detalles internos - rutas, mensajes de PDO, etc. - a quien llame la API).
 */
function mr_debug_habilitado(): bool
{
    try {
        return (bool) (mr_config()['debug'] ?? false);
    } catch (Throwable $e) {
        return false;
    }
}

/**
 * Valida el token global (D7 de IA.md) leído del header "X-MR-Token".
 * Usa hash_equals para evitar timing attacks.
 */
function mr_validar_token(): void
{
    $cfg = mr_config();
    $recibido = $_SERVER['HTTP_X_MR_TOKEN'] ?? '';
    if ($recibido === '' || !hash_equals((string) $cfg['token'], (string) $recibido)) {
        mr_error(401, 'Token inválido o ausente.');
    }
}

/**
 * Lee y decodifica el cuerpo JSON del request, con límite de tamaño (D
 * "Validar tamaño y frecuencia de envío razonable" de IA.md sección 5).
 */
function mr_leer_cuerpo_json(): array
{
    $cfg = mr_config();
    $maxBytes = (int) ($cfg['limites']['max_bytes_body'] ?? 262144);

    $crudo = file_get_contents('php://input', false, null, 0, $maxBytes + 1);
    if ($crudo === false || $crudo === '') {
        mr_error(400, 'Cuerpo de la solicitud vacío.');
    }
    if (strlen($crudo) > $maxBytes) {
        mr_error(413, 'Cuerpo de la solicitud demasiado grande.');
    }

    $datos = json_decode($crudo, true);
    if (!is_array($datos)) {
        mr_error(400, 'JSON inválido.');
    }
    return $datos;
}

/**
 * Versión de los scripts más reciente que alguna PC vio en las etiquetas de GitHub (campo "remota" de
 * api/update/pcs/<pc>.json), o null si ninguna la informó.
 */
function mr_version_publicada(): ?string
{
    static $v = false;
    if ($v === false) {
        $v = null;
        foreach (glob(__DIR__ . '/../update/pcs/*.json') ?: [] as $f) {
            $d = json_decode((string) @file_get_contents($f), true);
            $r = is_array($d) ? (string) ($d['remota'] ?? '') : '';
            if (preg_match('/^\d+(\.\d+){1,3}$/', $r) && ($v === null || version_compare($r, $v, '>'))) {
                $v = $r;
            }
        }
    }
    return $v;
}

/**
 * Último envío de datos de una PC (api/update/envios/<pc>.json, protegido por el .htaccess de update/): la hora LOCAL de
 * la PC al enviar (la misma base de tiempo que las filas de sus CSV, no la del servidor) y la frecuencia configurada
 * (runEveryMin). El análisis lo usa para no pintar como "en curso" el estado abierto de una PC que dejó de enviar.
 * Devuelve false si el nombre de la PC no sirve como nombre de archivo.
 */
function mr_envio_ruta(string $pc): ?string
{
    if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/', $pc) || str_contains($pc, '..')) {
        return null;
    }
    return __DIR__ . '/../update/envios/' . strtolower($pc) . '.json';
}

function mr_envio_guardar(string $pc, string $enviado, int $frecuenciaMin): bool
{
    $ruta = mr_envio_ruta($pc);
    if ($ruta === null || !preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/', $enviado) || $frecuenciaMin < 5 || $frecuenciaMin > 1440) {
        return false;
    }
    $dir = dirname($ruta);
    if (!is_dir($dir) && !@mkdir($dir, 0755, true) && !is_dir($dir)) {
        return false;
    }
    $ant = is_file($ruta) ? json_decode((string) @file_get_contents($ruta), true) : null;
    if (is_array($ant) && is_string($ant['enviado'] ?? null) && $ant['enviado'] > $enviado) {
        return true;   // llegó fuera de orden: se conserva el más reciente
    }
    $json = json_encode(['enviado' => $enviado, 'frecuencia' => $frecuenciaMin, 'recibido' => date('c')], JSON_UNESCAPED_UNICODE);
    return @file_put_contents($ruta, $json, LOCK_EX) !== false;
}

/** { enviado: 'AAAA-MM-DDTHH:MM:SS' (hora de la PC), frecuencia: minutos } o null si la PC nunca lo informó. */
function mr_envio_pc(string $pc): ?array
{
    $ruta = mr_envio_ruta($pc);
    $d = ($ruta !== null && is_file($ruta)) ? json_decode((string) @file_get_contents($ruta), true) : null;
    if (!is_array($d) || !preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/', (string) ($d['enviado'] ?? '')) || (int) ($d['frecuencia'] ?? 0) < 5) {
        return null;
    }
    return ['enviado' => (string) $d['enviado'], 'frecuencia' => (int) $d['frecuencia']];
}

/**
 * Versión de scripts que informó una PC (api/update/pcs/<pc>.json, lo escribe
 * actualizar.php?accion=confirmar). Devuelve null si la PC nunca informó.
 *   estado: 'ok' al día · 'vieja' hay una versión publicada más nueva · 'falla' el último intento falló
 */
function mr_version_pc(string $pc): ?array
{
    if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/', $pc) || str_contains($pc, '..')) {
        return null;
    }
    $ruta = __DIR__ . '/../update/pcs/' . strtolower($pc) . '.json';
    $d = is_file($ruta) ? json_decode((string) @file_get_contents($ruta), true) : null;
    if (!is_array($d) || !is_string($d['version'] ?? null) || !preg_match('/^\d+(\.\d+){1,3}$/', $d['version'])) {
        return null;
    }
    $estado = 'ok';
    $pub = mr_version_publicada();
    if (($d['ok'] ?? true) === false) {
        $estado = 'falla';
    } elseif ($pub !== null && version_compare($d['version'], $pub, '<')) {
        $estado = 'vieja';
    }
    return [
        'v'         => $d['version'],
        'estado'    => $estado,
        'resultado' => (string) ($d['resultado'] ?? ''),
        'detalle'   => (string) ($d['detalle'] ?? ''),
        'en'        => (string) ($d['en'] ?? ''),
        'publicada' => $pub,
    ];
}
