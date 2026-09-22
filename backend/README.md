# Backend de análisis — Monitor de Red (MRV1 → MySQL)

Ver `IA.md` en el proyecto de Claude para el contexto y las decisiones de diseño completas. Este README cubre solo la puesta en marcha de lo ya construido: la base de datos y la API de recepción.

## 1. Crear la base de datos

En el hosting (phpMyAdmin o consola MySQL), sobre la base de datos que ya te dieron:

```bash
mysql -u usuario -p nombre_de_la_base < sql/001_crear_base.sql
```

Esto crea las tablas `computadoras` y `registros`. Es seguro volver a ejecutarlo (usa `CREATE TABLE IF NOT EXISTS`).

## 2. Configurar la API

1. Sube la carpeta `api/` al hosting (por ejemplo a `/public_html/mrv1-api/` o donde prefieras).
2. Copia `api/config/config.example.php` como `api/config/config.php` (mismo directorio) y completa:
   - Credenciales de MySQL (host, nombre de la base, usuario, clave).
   - Un token propio, largo y aleatorio. Se puede generar así:
     ```bash
     php -r "echo bin2hex(random_bytes(32));"
     ```
3. **No subas `config.php` a git** — solo `config.example.php` va al repositorio (`.gitignore` ya lo excluye).
4. Verifica que `api/config/.htaccess` haya llegado al servidor (bloquea el acceso HTTP directo a esa carpeta) — solo aplica en hosting Apache; en otro tipo de servidor, restringir el acceso a `api/config/` por su cuenta.

## 3. Probar el endpoint

```bash
curl -X POST "https://solucionesnicaragua.com/mrv1-api/registros.php" \
  -H "Content-Type: application/json" \
  -H "X-MR-Token: TU_TOKEN_AQUI" \
  -d '{
    "pc": "PRUEBA-PC",
    "alias": "Prueba - Oficina",
    "destino": "8.8.8.8",
    "filas": [
      { "fecha": "2026-09-22", "hora": "07:00:00", "tipo": "INICIO", "tiempo_s": 0, "latencia_ms": 0, "mensaje": "Inicio de monitoreo" },
      { "fecha": "2026-09-22", "hora": "07:00:05", "tipo": "OK", "tiempo_s": 252, "latencia_ms": 32, "mensaje": "Conectividad disponible [Success]" }
    ]
  }'
```

Respuesta esperada:

```json
{"ok":true,"insertadas":2,"actualizadas":0,"sin_cambios":0,"total":2}
```

Si vuelves a correr exactamente el mismo `curl`, la respuesta debería cambiar a `"sin_cambios":2` (nada se duplica) — así se comprueba en la práctica la clave de sincronización D5 de `IA.md` antes de conectar `Cargador_DB.ps1` real.

Para simular que una fila `OK` se "cierra" (como pasaría con la última fila del día cuando cambia de estado), reenvíala con `tiempo_s`/`latencia_ms` distintos y debe salir `"actualizadas":1`.

## 4. Formulario de análisis semanal (`index.php`)

1. Sube `api/index.php` junto a `registros.php` (misma carpeta; usa `lib/` y `config/`). Se abre directo en la raíz del subdominio: `https://mrv1.solucionesnicaragua.com/`.
2. En `config/config.php` agrega la clave de acceso (recomendado):
   ```php
   'reporte' => ['clave' => 'una-clave-propia'],
   ```
   Sin esa entrada la página funciona igual, pero abierta a cualquiera (muestra un aviso).
3. Elige semana, días (Lun–Vie por defecto), horario (07:00–15:00 por defecto) y máquinas → **Generar gráfico** → **Descargar HTML** para compartir el reporte.

Detalle del gráfico y de los endpoints de consulta: `IA.md` sección 5.

## Estructura de esta carpeta

```
backend/
├── IA.md                        (vive en el proyecto de Claude, no aquí)
├── README.md                    (este archivo)
├── .gitignore
├── sql/
│   └── 001_crear_base.sql       Crea las tablas computadoras y registros
└── api/
    ├── index.php                Formulario SPA de análisis semanal (GET, solo lectura)
    ├── registros.php            Endpoint POST que reciben los datos
    ├── lib/
    │   ├── db.php                Conexión PDO a MySQL
    │   └── util.php              Respuestas JSON, validación de token, lectura de cuerpo
    └── config/
        ├── config.example.php   Plantilla de configuración (sí va a git)
        ├── config.php           Configuración real (NO va a git, la crea cada instalación)
        └── .htaccess             Bloquea acceso HTTP directo a esta carpeta
```
