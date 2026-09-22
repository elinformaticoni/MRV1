# BACKEND DE ANÁLISIS (MRV1 → MySQL) — GUÍA DE PROYECTO

| | |
|---|---|
| Estado | Capa de análisis funcionando en producción (BD + API) y `Cargador_DB.ps1` integrado al instalador de MRV1 (paquete 1.8). Formulario de análisis semanal (`api/index.php`) construido — pendiente de desplegar y probar con datos reales. |
| Ubicación en el repositorio | `MRV1/backend/` — vive **dentro** del paquete `MRV1/` para mantener todo en el mismo repositorio, pero es una capa independiente: **el instalador de MRV1 nunca copia ni toca esta carpeta** al instalar en una PC cliente. |
| Repositorio | `https://github.com/elinformaticoni/MRV1.git` |
| API en producción | `https://mrv1.solucionesnicaragua.com/registros.php` — hosting DirectAdmin, base de datos `soluci12_MRV1`, PHP 8.3.33. |
| Guía del monitor | `MRV1/MRV1.8.md` — arquitectura completa de MRV1, incluyendo `Cargador_DB.ps1` y el instalador (`Instalar_DB.ps1`). Este documento cubre solo el lado servidor (BD + API). |

---

## 0. Reglas para cualquier IA

1. Este documento es el contexto maestro del lado servidor (BD + API). El lado cliente (`Cargador_DB.ps1`, `Instalar_DB.ps1`, integración con el instalador de MRV1) está documentado en `MRV1/MRV1.8.md`, sección "Carga a la API de análisis".
2. **No eliminar funcionalidad existente.** El Cargador FTP y el CSV local de MRV1 siguen funcionando exactamente igual; esta capa es un agregado opcional.
3. Si se cambia algo de esta arquitectura, actualizar este documento y, si el cambio afecta al cliente, también `MRV1/MRV1.8.md`.

---

## 1. Objetivo

Permitir análisis de fallas de red con **rango de fechas dinámico** y datos de **varias PCs/ubicaciones**, sin depender de reprocesar CSV manualmente. Los registros que ya produce MRV1 se replican (opcionalmente, por PC) a una base de datos MySQL vía una API simple; un formulario (pendiente de construir) consulta esa base y genera, bajo demanda, un HTML de reporte autocontenido y fácil de compartir (incluso por correo).

---

## 2. Arquitectura general

```text
Monitor_Red.ps1 ──► CSV local
       │
       ├──► Cargador_FTP.ps1 ──► Servidor FTP                    (sin cambios, ver MRV1.8.md)
       │
       └──► Cargador_DB.ps1 (opcional) ──► API (PHP) ──► MySQL
            cada 3 h (configurable)                          │
                                              formulario de análisis (index.php, SPA)
                                                               │
                                              HTML autocontenido generado al vuelo ──► descarga / correo
```

| Componente | Dónde corre | Responsabilidad |
|---|---|---|
| Tablas MySQL (`computadoras`, `registros`) | Hosting `solucionesnicaragua.com` (BD `soluci12_MRV1`) | Almacenan los registros de todas las PCs |
| API de recepción (PHP) | `https://mrv1.solucionesnicaragua.com/registros.php` | Recibe filas, valida token, hace upsert en MySQL |
| `Cargador_DB.ps1` + `Instalar_DB.ps1` | PC del cliente, dentro de `MRV1/` | Ver `MRV1/MRV1.8.md` |
| Formulario de análisis semanal (SPA) + descarga del reporte HTML | `https://mrv1.solucionesnicaragua.com/` (`api/index.php`) | Selector de semana/días/horario/máquinas, gráfico y HTML autocontenido |

---

## 3. Base de datos MySQL

Script: `sql/001_crear_base.sql` (usa `CREATE TABLE IF NOT EXISTS`, seguro de reejecutar).

```sql
CREATE TABLE computadoras (
  pc             VARCHAR(100) NOT NULL PRIMARY KEY,
  alias          VARCHAR(150) NULL,
  creado_en      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  actualizado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE registros (
  id             BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  pc             VARCHAR(100) NOT NULL,
  destino        VARCHAR(100) NOT NULL,
  fecha          DATE NOT NULL,
  hora           TIME NOT NULL,
  tipo           ENUM('INICIO','OK','ERROR','EVENTO') NOT NULL,
  tiempo_s       INT UNSIGNED NULL,
  latencia_ms    INT UNSIGNED NULL,
  mensaje        VARCHAR(500) NULL,
  creado_en      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  actualizado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY registro_unico (pc, destino, fecha, hora, tipo, mensaje(190)),
  KEY idx_pc_fecha (pc, fecha),
  KEY idx_fecha (fecha),
  FOREIGN KEY (pc) REFERENCES computadoras(pc)
);
```

- **Clave única de `registros`:** `pc, destino, fecha, hora, tipo, mensaje`. Necesaria porque con `fecha, hora, tipo` solamente puede haber colisiones (p. ej. dos filas `EVENTO` en el mismo segundo para el mismo destino); `mensaje` desambigua. La clave la calcula `Cargador_DB.ps1` a partir de datos que ya existen en el CSV — no requiere cambios en `Monitor_Red.ps1` ni en el formato del CSV.
- El `UPSERT` (`INSERT ... ON DUPLICATE KEY UPDATE` sobre `registro_unico`) permite que una fila que se abre (tiempo/latencia en blanco) y luego se cierra (completa) se actualice sola, sin duplicarse.
- `computadoras.alias` se autoregistra: la API hace upsert en `computadoras` en cada envío que traiga un alias no vacío (`Cargador_DB.ps1` lo manda siempre) — sin pasos manuales en la base.
- `idx_pc_fecha` e `idx_fecha` existen para que las consultas del reporte (rango de fechas + PCs/ubicaciones) no recorran toda la tabla a medida que crezca.

---

## 4. API de recepción (PHP)

Carpeta `api/`, desplegada en `https://mrv1.solucionesnicaragua.com/registros.php` (hosting DirectAdmin, PHP 8.3.33):

- `registros.php` — `POST /registros.php`: recibe `{ pc, alias, destino, filas: [...] }`, valida el token global (header `X-MR-Token`), valida forma y tipos de cada fila, hace upsert de `computadoras` y de cada fila dentro de una transacción. Responde `{ ok, insertadas, actualizadas, sin_cambios, total }`.
- `lib/db.php` — conexión PDO a MySQL a partir de `config/config.php` (`mr_config()`, `mr_db()`).
- `lib/util.php` — respuestas JSON (`mr_json_response`), errores (`mr_error`), validación de token (`mr_validar_token`, `hash_equals`), lectura y límite de tamaño del cuerpo (`mr_leer_cuerpo_json`), y el manejador global de errores (`mr_instalar_manejador_errores`): instala `set_exception_handler`, `set_error_handler` y `register_shutdown_function` para que **cualquier** error no controlado responda JSON en vez de dejar una página en blanco. Necesario porque la conexión a MySQL y cualquier otra operación deben quedar siempre dentro del `try/catch` de `registros.php`; un fallo fuera de ese bloque produce una página en blanco con 500 en hosting con `display_errors` apagado.
- `config/config.example.php` — plantilla (sí va a git). `config/config.php` — credenciales reales, **no va a git** (excluido por `.gitignore`), solo existe en el servidor.
- `config/.htaccess` — bloquea acceso HTTP directo a la carpeta `config/`.
- Token de autenticación: **único y global** (no por PC), vive en `config.php` del servidor y se copia igual en `config\db_api.json` de cada PC cliente.
- Límites anti-abuso configurables en `config.php`: tamaño máximo del cuerpo (256 KB) y cantidad máxima de filas por envío (500). `Cargador_DB.ps1` respeta ese límite enviando en lotes de 300.
- `config.php` incluye la clave `'debug' => false` — si se pone en `true` temporalmente, las respuestas de error incluyen el detalle real (mensaje de PDO, excepción, etc.); debe quedar siempre en `false` en producción.

---

## 5. Formulario de análisis semanal (`index.php`)

`api/index.php` — se abre directo en `https://mrv1.solucionesnicaragua.com/` (junto a `registros.php`). Un solo archivo: página SPA + endpoints JSON de consulta (solo lectura de la BD).

**Formulario (de arriba abajo):**

1. **Semana** — se trabaja por semana (lunes a domingo) para no saturar de datos: calendario (cualquier día elige su semana), ◀ ▶ y «Esta semana». Por defecto, la semana actual.
2. **Días** — checklist Lun…Dom, **Lun–Vie marcados por defecto**. Un punto verde indica los días con registros de las máquinas seleccionadas.
3. **Horario (eje horizontal)** — desde/hasta cada 30 min, **07:00–15:00 por defecto**; botones «Jornada» (7–15) y «Día completo» (0–24).
4. **Máquinas** — solo las que tienen registros en la semana (alias + nombre de PC, días con datos, un chip por destino con su cantidad de ERROR). Todas marcadas por defecto; «Todas» / «Ninguna». Son el eje vertical.
5. Opciones: mostrar Wi-Fi/cable (activo), mostrar eventos e inicios, incluir días sin registros.
6. **Generar gráfico** consulta los datos de la semana; cambiar días, horario u opciones redibuja al instante sin volver a consultar. **Descargar HTML** genera el reporte autocontenido.

**Gráfico (motor en `<script id="motor">`, reutilizado tal cual en el HTML descargable):**

- Un bloque por día; dentro, una franja por máquina y, si la máquina tiene varios destinos, **una fila por destino, una encima de la otra en el mismo eje**. Encima de los destinos, una tira fina con el adaptador (azul Wi-Fi / morado cable), tomado del mensaje de `INICIO` (tercer campo) y de los `EVENTO` «Cambio de adaptador: A -> B».
- Colores: gris = conectado (OK), rojo = sin conexión (ERROR, mín. 2 px para que se vea una caída corta), rayado gris = incompleto (fila sin cerrar por apagado abrupto, hasta la siguiente fila), rayado claro = estado en curso de hoy (hasta la hora actual, no se suma). Eventos/inicios como marcas verticales (opcional). Tooltip con destino, estado, hora inicio–fin, duración, latencia y mensaje.
- **Franja verde transparente**: el día completo si ninguna máquina seleccionada tuvo caídas en el horario; si el día sí tuvo, cada máquina sin caídas lleva su propia franja verde y «✓ sin caídas».
- Columna derecha **«Desconectado»**: suma de `ERROR` cerrados dentro del horario por destino, con la cantidad de caídas. Cabecera del día: caídas y suma total.
- Al final, **resumen del periodo**: máquina × destino × día seleccionado, total, caídas y disponibilidad (% OK sobre OK+ERROR dentro del horario).
- La duración de cada estado se toma de `tiempo_s`, limitada al inicio de la fila siguiente (que no sea `EVENTO`); todo se recorta al horario elegido.

**Endpoints JSON** (mismo archivo, `GET`):

| Acción | Parámetros | Respuesta |
|---|---|---|
| `?accion=maquinas` | `desde`, `hasta` (AAAA-MM-DD, máx. 31 días) | `{ ok, maquinas: [{ pc, alias, destinos: [{ destino, registros, errores }], dias: [...] }] }` |
| `?accion=datos` | `desde`, `hasta`, `pc[]` (1–100) | `{ ok, filas, maquinas: [{ pc, alias, destinos: [{ destino, filas: [[fecha, hora, tipo, tiempo_s, latencia_ms, mensaje], ...] }] }] }` — tope 200 000 filas |

Usan `idx_fecha` / `idx_pc_fecha`, el mismo manejador de errores JSON que `registros.php` y respetan `debug`.

**Control de acceso:** `config.php` → `'reporte' => ['clave' => '…']`. Con clave: pide iniciar sesión (sesión PHP, cookie `HttpOnly`/`SameSite=Lax`, `Secure` bajo HTTPS; comparación con `hash_equals`; «Cerrar sesión» = `?salir=1`); los endpoints responden 401 sin sesión. Sin clave (o si falta la entrada): acceso abierto con un aviso amarillo en la página.

**HTML descargable:** un solo archivo (`MRV1 analisis AAAA-MM-DD al AAAA-MM-DD.html`) con CSS, motor y datos embebidos; sin dependencias externas, funciona sin conexión, modo claro/oscuro y en celular. Es un snapshot cerrado (días, horario y opciones del momento de generarlo).

---

## 6. Seguridad

- HTTPS obligatorio (el subdominio tiene TLS 1.3 con certificado Let's Encrypt). `Cargador_DB.ps1` fuerza `TLS 1.2` como mínimo en el cliente.
- Token de autenticación único y global — comparación timing-safe (`hash_equals`) en cada request.
- Límite de tamaño de cuerpo y de filas por envío en la API, respetado por `Cargador_DB.ps1` (envío en lotes).
- **Antes de distribuir el paquete MRV1 a más PCs**, regenerar el token de producción (`openssl rand -hex 32`), actualizar `config.php` en el servidor y actualizar los valores predeterminados (`$defToken`, `$defApiUrl`) en `MRV1/Instalar_DB.ps1`.

---

## 7. Archivos del proyecto

`MRV1/backend/` (dentro del repositorio de MRV1; el instalador del monitor no toca esta carpeta):

```
MRV1/backend/
├── README.md                    Puesta en marcha: crear la BD, configurar la API, probar con curl
├── .gitignore                   Excluye api/config/config.php (credenciales reales)
├── sql/
│   └── 001_crear_base.sql       Crea computadoras y registros (CREATE TABLE IF NOT EXISTS)
└── api/                          Desplegada en https://mrv1.solucionesnicaragua.com/
    ├── index.php                Formulario SPA de análisis semanal + endpoints GET de consulta
    ├── registros.php            Endpoint POST — recibe y hace upsert de las filas
    ├── lib/
    │   ├── db.php                Conexión PDO a MySQL
    │   └── util.php              Respuestas JSON, validación de token, límite de tamaño del cuerpo,
    │                              manejador global de errores (mr_instalar_manejador_errores)
    └── config/
        ├── config.example.php   Plantilla de configuración (sí va a git) — incluye 'debug' y 'reporte' => ['clave']
        ├── config.php           Configuración real con credenciales (solo en el servidor, no va a git)
        └── .htaccess             Bloquea acceso HTTP directo a esta carpeta
```

El lado cliente (`Cargador_DB.ps1`, `Instalar_DB.ps1`, `Instalar_DB.bat`, `Desinstalar_DB.bat`, `config/db_api.example.json`) vive en `MRV1/` junto a los demás componentes del monitor — ver `MRV1/MRV1.8.md`.

---

## 8. Replicar / poner en marcha en un hosting nuevo

1. Ejecutar `sql/001_crear_base.sql` contra la base de datos MySQL del hosting.
2. Copiar `api/` completo al hosting (dominio o subdominio con PHP 8.3+ y `pdo_mysql`).
3. Copiar `api/config/config.example.php` a `api/config/config.php` y completar credenciales de BD y un token generado con `openssl rand -hex 32`. Confirmar que `config/.htaccess` bloquea el acceso directo a esa carpeta.
4. Probar con `curl` (ver `README.md`): un `POST` a `registros.php` con `X-MR-Token` correcto debe responder `{"ok":true,...}`.
5. En cada PC cliente, ejecutar `MRV1/Instalar_DB.ps1` (o responder "sí" a la pregunta correspondiente en `Instalar_Monitor.ps1`) con la URL y el token de este hosting.

## 9. Pendiente

- Desplegar `api/index.php`, poner la clave de `reporte` en `config.php` del servidor y validar el gráfico con datos reales.
- Si se necesita más de una semana a la vez: el endpoint ya acepta hasta 31 días; faltaría el selector en la página.
- Prueba de punta a punta con al menos 2 PCs reales enviando datos simultáneamente.
