<?php
/**
 * Monitor de Red — Backend de análisis
 * Configuración de la API (config.php)
 *
 * 1. Copia este archivo como "config.php" en la misma carpeta.
 * 2. Rellena los valores reales del hosting.
 * 3. NO subas config.php a git — agrégalo a .gitignore. Solo este
 *    archivo de ejemplo (config.example.php) va al repositorio.
 *
 * Ver backend/IA.md sección 5 y 8 (D7 — token único y global).
 */

return [
    // Credenciales de MySQL (el mismo hosting que ya usan para FTP: solucionesnicaragua.com)
    'db' => [
        'host'    => '127.0.0.1',
        'nombre'  => 'nombre_de_la_base',
        'usuario' => 'usuario_mysql',
        'clave'   => 'clave_mysql',
        'charset' => 'utf8mb4',
    ],

    // Token único y global (D7): el mismo valor se copia en db_api.json de cada PC.
    // Generar uno robusto, por ejemplo con: php -r "echo bin2hex(random_bytes(32));"
    'token' => 'CAMBIAR_ESTE_TOKEN_POR_UNO_PROPIO',

    // Límites básicos anti-abuso (sección 5 de IA.md)
    'limites' => [
        'max_filas_por_envio' => 500,   // filas que puede traer un solo POST
        'max_bytes_body'      => 262144, // 256 KB, de sobra para 500 filas de texto
    ],

    // Acceso al formulario de análisis (index.php). Si la clave queda vacía, la página
    // se abre sin pedir nada (y muestra un aviso). Recomendado: poner una clave propia.
    'reporte' => [
        'clave' => '',
    ],

    // Solo para diagnosticar problemas puntuales: si es true, las respuestas de error
    // incluyen el detalle real (mensaje de PDO, excepción, etc.). Dejar SIEMPRE en
    // false en producción — el detalle no debe ser visible a quien llame la API.
    'debug' => false,
];
