# Backend de análisis — Monitor de Red (MRV1 → MySQL)

Estado (MRV1.10): base de datos, API de recepción y formulario de análisis semanal funcionando. En producción: `https://mrv1.solucionesnicaragua.com/` (formulario) y `https://mrv1.solucionesnicaragua.com/registros.php` (API).

Contexto y decisiones de diseño completas: [`IA.md`](./IA.md). Lado cliente (`Cargador_DB.ps1`, instaladores): [`../sistema/MRV1.10.md`](../sistema/MRV1.10.md), sección 10. Este README cubre la puesta en marcha.

## 1. Crear la base de datos

En el hosting (phpMyAdmin o consola MySQL), sobre la base de datos que ya te dieron:

```bash
mysql -u usuario -p nombre_de_la_base < sql/001_crear_base.sql
```

Esto crea las tablas `computadoras` y `registros`. Es seguro volver a ejecutarlo (usa `CREATE TABLE IF NOT EXISTS`).

## 2. Configurar la API

1. Sube el contenido de `api/` a la raíz del subdominio (en producción, la raíz de `mrv1.solucionesnicaragua.com`).
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
curl -X POST "https://mrv1.solucionesnicaragua.com/registros.php" \
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
4. En el reporte, los botones **Cable / Wi-Fi** muestran u ocultan los registros según la red que usaba cada máquina (Wi-Fi oculto por defecto). Funcionan también en el HTML descargado.

Qué muestra el gráfico: verde tenue = conectado, rojo = sin conexión, blanco = sin datos, azul = eventos e inicios, franja naranja = 2 o más máquinas caídas a la vez.

## 5. Configuración remota (`zombie.php`) [v1.11]

1. Ejecuta `sql/002_config_remota.sql` sobre la misma base (es idempotente).
2. Sube `api/zombie.php` y la carpeta `api/zombie/` (con su `.htaccess`, que bloquea el acceso directo). Necesita la clave `reporte.clave` de `config.php`: sin ella la página se deshabilita.
3. Abre `https://mrv1.solucionesnicaragua.com/zombie.php`, marca una o varias PC, elige qué secciones enviar y guarda. El archivo de cada PC queda en `api/zombie/config.<pc>.json`.
4. Prueba con `curl`:
   ```bash
   curl -H "X-MR-Token: TU_TOKEN_AQUI" "https://mrv1.solucionesnicaragua.com/zombie.php?accion=config&pc=NOMBRE-PC"
   ```
   Responde el JSON de esa PC, o `404` si no tiene instrucción.

Las PC la aplicarán cuando exista `Sincronizar_Config.ps1` (cliente, pendiente). Detalle: `IA.md` sección 5.1.

## 6. Pendiente

- Configurar `'reporte' => ['clave' => …]` en el `config.php` de producción.
- Prueba de punta a punta con varias PC reales enviando datos a la vez.
- Antes de distribuir el paquete a más PC: regenerar el token y actualizarlo en `config.php` y en `sistema/Instalar_DB.ps1` (ver `IA.md` sección 6).

Detalle del gráfico y de los endpoints de consulta: `IA.md` sección 5.

## Estructura de esta carpeta

```
backend/
├── IA.md                        Guía técnica del backend (contexto para IA)
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
