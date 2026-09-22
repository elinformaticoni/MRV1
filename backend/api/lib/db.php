<?php
/**
 * Monitor de Red — Backend de análisis
 * Conexión PDO a MySQL, a partir de config/config.php
 */

declare(strict_types=1);

function mr_config(): array
{
    static $config = null;
    if ($config === null) {
        $ruta = __DIR__ . '/../config/config.php';
        if (!file_exists($ruta)) {
            http_response_code(500);
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode([
                'ok' => false,
                'error' => 'Falta config/config.php. Copia config/config.example.php como config.php y complétalo.',
            ]);
            exit;
        }
        $config = require $ruta;
    }
    return $config;
}

function mr_db(): PDO
{
    static $pdo = null;
    if ($pdo === null) {
        $cfg = mr_config()['db'];
        $dsn = sprintf(
            'mysql:host=%s;dbname=%s;charset=%s',
            $cfg['host'],
            $cfg['nombre'],
            $cfg['charset'] ?? 'utf8mb4'
        );
        $pdo = new PDO($dsn, $cfg['usuario'], $cfg['clave'], [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]);
    }
    return $pdo;
}
