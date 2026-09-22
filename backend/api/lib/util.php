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
