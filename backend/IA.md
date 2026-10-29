# BACKEND DE ANÁLISIS (MRV1 → MySQL) — GUÍA DE PROYECTO

| | |
|---|---|
| Estado | [v1.11] Capa de análisis funcionando en producción (BD + API) y `Cargador_DB.ps1` integrado al instalador de MRV1 (paquete 1.8). Formulario de análisis semanal (`api/index.php`) construido — pendiente de desplegar y probar con datos reales. Configuración remota (`zombie.php` + `Sincronizar_Config.ps1`, sección 5.1) completa en servidor y cliente — pendiente desplegar `sql/002_config_remota.sql` y `zombie.php`/`zombie/` en producción (sección 9). |
| Ubicación en el repositorio | `MRV1/backend/` — vive **dentro** del paquete `MRV1/` para mantener todo en el mismo repositorio, pero es una capa independiente: **el instalador de MRV1 nunca copia ni toca esta carpeta** al instalar en una PC cliente. |
| Repositorio | `https://github.com/elinformaticoni/MRV1.git` |
| API en producción | `https://mrv1.solucionesnicaragua.com/registros.php` — hosting DirectAdmin, base de datos `soluci12_MRV1`, PHP 8.3.33. |
| Guía del monitor | `MRV1/sistema/MRV1.10.md` — arquitectura completa de MRV1, incluyendo `Cargador_DB.ps1` y el instalador (`Instalar_DB.ps1`). Este documento cubre solo el lado servidor (BD + API). |

---

## 0. Reglas para cualquier IA

1. Este documento es el contexto maestro del lado servidor (BD + API). El lado cliente (`Cargador_DB.ps1`, `Instalar_DB.ps1`, integración con el instalador de MRV1) está documentado en `MRV1/sistema/MRV1.10.md`, sección "Carga a la API de análisis".
2. **No eliminar funcionalidad existente.** El Cargador FTP y el CSV local de MRV1 siguen funcionando exactamente igual; esta capa es un agregado opcional.
3. Si se cambia algo de esta arquitectura, actualizar este documento y, si el cambio afecta al cliente, también `MRV1/sistema/MRV1.10.md`.

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
| `Cargador_DB.ps1` + `Instalar_DB.ps1` | PC del cliente, dentro de `MRV1/` | Ver `MRV1/sistema/MRV1.10.md` |
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

`api/index.php` — se abre directo en `https://mrv1.solucionesnicaragua.com/` (junto a `registros.php`). Un solo archivo: página SPA + endpoints JSON de consulta. Prácticamente de solo lectura de la BD; la única excepción es `accion=eliminar_pc` [v1.11], ver más abajo.

**Formulario (de arriba abajo):**

1. **Semana** — se trabaja por semana (lunes a domingo) para no saturar de datos: calendario (cualquier día elige su semana), ◀ ▶ y «Esta semana». Por defecto, la semana actual.
2. **Días** — checklist Lun…Dom, **Lun–Vie marcados por defecto**. Un punto verde indica los días con registros de las máquinas seleccionadas.
3. **Horario (eje horizontal)** — desde/hasta cada 30 min, **07:00–15:00 por defecto**; botones «Jornada» (7–15) y «Día completo» (0–24).
4. **Máquinas** — solo las que tienen registros en la semana (alias + nombre de PC, días con datos, un chip por destino con su cantidad de ERROR). Todas marcadas por defecto; «Todas» / «Ninguna». Son el eje vertical. Con sesión iniciada, cada tarjeta tiene un menú «⋯» con **«Eliminar computadora…»** [v1.11]: borra esa PC y todos sus registros de la base de datos (irreversible, pide confirmación) — ver más abajo.
5. Opciones: marcar coincidencias (activo), mostrar eventos e inicios (activo), incluir días sin registros.
6. **Generar gráfico** consulta los datos de la semana; cambiar días, horario u opciones redibuja al instante sin volver a consultar. **Descargar HTML** genera el reporte autocontenido.
7. **Persistencia de la cabecera [v1.11]:** semana, días, horario, selección de máquinas y las tres casillas de opciones se guardan en `localStorage` (`mrv1_form_v1`) cada vez que cambian, y se restauran al cargar la página — de mejor esfuerzo (si `localStorage` no está disponible, el formulario simplemente vuelve a los valores por defecto). No aplica a las máquinas mismas (siguen viniendo del servidor por semana) ni a la visibilidad Cable/Wi-Fi del reporte descargable.

**Gráfico (motor en `<script id="motor">`, reutilizado tal cual en el HTML descargable):**

- Un bloque por día; dentro, una franja por máquina y, si la máquina tiene varios destinos, **una fila por destino, una encima de la otra en el mismo eje**. Sin filas auxiliares: solo destinos.
- Colores: **verde tenue translúcido** = hay registros y conectado (OK); **rojo** = sin conexión (ERROR, mín. 2 px para que se vea una caída corta); **en blanco** = sin datos (sin registros, o fila sin cerrar por apagado abrupto hasta la fila siguiente). Estado en curso de hoy: su color con rayado claro hasta la hora actual (no se suma). **Azul** = marcas verticales de eventos (cambio de adaptador, IP, interfaz) y, más claro, inicios del monitor.
- **Coincidencias (ámbar):** franja vertical que atraviesa todo el día donde **2 o más máquinas distintas** están en ERROR al mismo tiempo (cualquiera de sus destinos; varios destinos de una misma máquina no cuentan como coincidencia), con tolerancia de 5 s a cada lado porque cada monitor hace ping con su propio intervalo. Sirve para ubicar el problema en la red común y no en una estación. Marca en el eje con tooltip (hora, duración, máquinas) y contador en la cabecera del día. Color ámbar (`--coin`/`--coin-borde`, deliberadamente alejado del rojo de ERROR) para que no se confundan a simple vista [v1.11].
- Tooltip de cada tramo: destino, estado, hora inicio–fin, duración, latencia, mensaje y la red que usaba la máquina en ese momento (Wi-Fi/cable, tomado del `INICIO` y de los `EVENTO` «Cambio de adaptador: A -> B»).
- **Ajuste visual [v1.11]:** ambas redes (Cable/Wi-Fi) visibles por defecto (antes Wi-Fi quedaba oculto), con el tramo por Wi-Fi bandeado (verde con bandas claras) para distinguirlo del cable sin ocultar datos; se subió la opacidad del verde OK (`--ok`/`--ok-wifi`) para que se note con el tramo ya cerrado.
- Días / máquinas sin caídas en el horario: distintivo «✓ Sin caídas» en la cabecera del día o junto al nombre de la máquina.
- Columna derecha **«Desconectado»**: suma de `ERROR` cerrados dentro del horario por destino, con la cantidad de caídas. Cabecera del día: caídas y suma total.
- Al final, **resumen del periodo**: máquina × destino × día seleccionado, total, caídas y disponibilidad (% OK sobre OK+ERROR dentro del horario).
- La duración de cada estado se toma de `tiempo_s`, limitada al inicio de la fila siguiente (que no sea `EVENTO`); todo se recorta al horario elegido.

**Endpoints JSON** (mismo archivo):

| Acción | Método | Parámetros | Respuesta |
|---|---|---|---|
| `?accion=maquinas` | GET | `desde`, `hasta` (AAAA-MM-DD, máx. 31 días) | `{ ok, maquinas: [{ pc, alias, destinos: [{ destino, registros, errores }], dias: [...] }] }` |
| `?accion=datos` | GET | `desde`, `hasta`, `pc[]` (1–100) | `{ ok, filas, maquinas: [{ pc, alias, destinos: [{ destino, filas: [[fecha, hora, tipo, tiempo_s, latencia_ms, mensaje], ...] }] }] }` — tope 200 000 filas |
| `?accion=eliminar_pc` [v1.11] | POST, cuerpo JSON `{ pc, csrf }` | — | `{ ok, pc, registros_eliminados }`. Borra, en una transacción, todas las filas de `registros` de esa PC y su fila en `computadoras`; también retira (mejor esfuerzo) cualquier instrucción de configuración remota pendiente (`zombie/config.<pc>.json`, sección 5.1). Exige sesión iniciada (403 sin ella, sin importar el modo de acceso) y el token CSRF de sesión (`$_SESSION['mr_rep_csrf']`, el mismo patrón que `zombie.php`); `404` si la PC no existe. |

`maquinas`/`datos` usan `idx_fecha` / `idx_pc_fecha`, el mismo manejador de errores JSON que `registros.php` y respetan `debug`.

**Control de acceso:** `config.php` → `'reporte' => ['clave' => '…']`. Con clave: pide iniciar sesión (sesión PHP, cookie `HttpOnly`/`SameSite=Lax`, `Secure` bajo HTTPS; comparación con `hash_equals`; «Cerrar sesión» = `?salir=1`); los endpoints responden 401 sin sesión. Sin clave (o si falta la entrada): acceso abierto con un aviso amarillo en la página — pero `eliminar_pc` sigue exigiendo sesión (403) en ese modo: sin clave configurada, nadie puede eliminar computadoras desde el formulario.

**HTML descargable:** un solo archivo (`MRV1 analisis AAAA-MM-DD al AAAA-MM-DD.html`) con CSS, motor y datos embebidos; sin dependencias externas, funciona sin conexión, modo claro/oscuro y en celular. Es un snapshot cerrado (días, horario y opciones del momento de generarlo).

---

## 5.1 Configuración remota (`zombie.php` + `Sincronizar_Config.ps1`) [v1.11]

`api/zombie.php` permite cambiar la configuración de las PC observadas (destinos, tiempos de ping, detección, frecuencia y reintentos de la API y del FTP) sin visitarlas. **El servidor manda y la PC obedece:** no existe modo «zombie sí/no» ni doble configuración local.

**Instrucción por PC.** Un archivo real `api/zombie/config.<pc>.json` (nombre de PC en minúsculas y saneado a `[A-Za-z0-9._-]`), creado por el formulario al guardar. La carpeta lleva `.htaccess` con `Require all denied`: nunca se sirve directo, el acceso es solo por `zombie.php?accion=config` con token. Los archivos no van a git (`.gitignore`).

```json
{
  "schemaVersion": 1,
  "revision": 1790314268,
  "generadoEn": "2026-09-24T22:31:08-06:00",
  "targets":   [ { "address": "8.8.8.8", "intervalSec": 5, "confirmPings": 1 } ],
  "detection": { "timeoutMs": 2000, "networkCheckSec": 5 },
  "db":        { "runEveryMin": 180, "retries": 3 },
  "ftp":       { "runEveryMin": 120, "retries": 3, "uploadCurrentDay": true }
}
```

- Cada sección es **opcional**: la PC sobrescribe solo las que vengan y deja intactas las demás. Nunca hay credenciales FTP, token, URL ni alias.
- `revision` es la marca de tiempo Unix del guardado, forzada a ser mayor que la anterior de esa PC (`max(time(), anterior + 1)`): no retrocede aunque se borre y se recree el archivo. La PC solo aplica si `revision` es mayor a la que ya aplicó.
- **Rangos** (constante `MR_Z_LIM`): intervalo 1–3600 s, confirmación 1–10, timeout 500–10000 ms, revisión de red 1–300 s, frecuencia de la API **5–720 min** (acotada para que la PC siempre vuelva a consultar y una instrucción errónea pueda corregirse), frecuencia FTP 5–1440 min, reintentos 1–10, hasta 8 destinos.

**Endpoints**

| Acción | Autenticación | Respuesta |
|---|---|---|
| `GET zombie.php?accion=config&pc=NOMBRE` | `X-MR-Token` | El JSON de esa PC; `404` si no tiene instrucción; `422` si el nombre no es válido |
| `POST zombie.php?accion=confirmar` `{ "pc", "revision" }` | `X-MR-Token` | `{ ok, pc, revision }`; guarda `config_rev_aplicada` y `config_aplicada_en` en `computadoras` |
| `GET/POST zombie.php` | Sesión (misma clave y cookie que `index.php`) | Formulario de administración |

**Formulario [rediseñado en 1.13.1].** Pantalla de dos paneles: a la izquierda la lista de equipos (buscador, estado «Aplicada» / «Pendiente» / «Sin instrucción» y la **versión de scripts confirmada** de cada PC); a la derecha el editor del equipo elegido. Se trabaja **una PC por vez**: al seleccionarla (`zombie.php?pc=NOMBRE`) el formulario carga la instrucción guardada para corregirla (o valores sugeridos si no tiene). Secciones con casilla «enviar» (al desmarcarla sus campos se deshabilitan): destinos (filas que se agregan y quitan, hasta 8), API y FTP. «Guardar instrucción» escribe el archivo de esa PC (con su propia revisión) y «Quitar instrucción» lo borra (la PC conserva lo que ya aplicó). **«COPIAR A…»**, al pie, abre la lista de los demás equipos con buscador: lo que se ve en el formulario (guardado o no) se copia a los marcados y el equipo de origen no se modifica (si hay diferencias con lo guardado, avisa). Avisa de cambios sin guardar al cambiar de equipo o cerrar la pestaña, y tras guardar/copiar redirige a la misma página con el mensaje (sin reenviar el formulario). La sección **«Detección»** (`timeoutMs`, `networkCheckSec`) se quitó del formulario: no tenía un uso práctico y las PC conservan sus valores (2000 ms y 5 s por defecto); la API y el cliente siguen aceptándola si algún archivo antiguo la trae. Protegido con CSRF; **queda deshabilitado si no hay `reporte.clave`** en `config.php` (a diferencia de `index.php`, no se deja abierto).

**Base de datos.** `sql/002_config_remota.sql` agrega `computadoras.config_rev_aplicada` (BIGINT) y `config_aplicada_en` (DATETIME); es idempotente. Sin él, el formulario funciona pero avisa que falta y no muestra la confirmación.

**Comportamiento de la PC (cliente):** implementado en `Sincronizar_Config.ps1` — ver `sistema/MRV1.11.md`, sección 10.6.

---

## 5.2 Actualización automática de los scripts (`actualizar.php` + `Actualizar_Script.ps1`) [v1.12]

`api/actualizar.php` publica a las PC la versión más reciente de los scripts. **El servidor no firma nada**: la firma RSA-SHA256 del manifiesto se hace en la PC del desarrollador con `tools/Publicar_Actualizacion.ps1` (clave privada en `%USERPROFILE%\.mrv1\update_private.xml`, nunca en el repositorio ni en el servidor). Las PC verifican esa firma con la clave pública que instaló el paquete (`config\update_pubkey.xml`), así que quien comprometa el servidor o el token no puede ejecutar código en las PC.

**Contenido publicado** (`api/update/`, con `.htaccess` `Require all denied`: solo se sirve por `actualizar.php` con token):

| Ruta | Qué es |
|---|---|
| `update/manifest.json` | `{ schemaVersion, version, generado, files:[{ name, dest ('bin'\|'root'), sha256, size }] }` |
| `update/manifest.sig` | Firma RSA-SHA256 (base64) de los bytes exactos de `manifest.json` |
| `update/paquete/` | Los archivos |
| `update/pcs/<pc>.json` | Versión que informó cada PC (datos de cada instalación; no va a git) |

**Endpoints** (todos con `X-MR-Token`):

| Petición | Respuesta |
|---|---|
| `GET actualizar.php?accion=manifiesto` / `?accion=firma` | El manifiesto / su firma; `404` si todavía no hay nada publicado |
| `GET actualizar.php?accion=archivo&nombre=X` | Un archivo del paquete, solo si está en el manifiesto (`^[A-Za-z0-9_.-]{1,80}$`) |
| `POST actualizar.php?accion=confirmar` `{ pc, version, ok, detalle }` | Guarda lo que informó la PC |
| `GET actualizar.php?accion=versiones` | `{ publicada, pcs:[…] }` |

**Publicar una mejora:** subir el número de `version` en `sistema/Instalar_Monitor.ps1`, ejecutar `tools/Publicar_Actualizacion.ps1` y subir `api/update/` (y `actualizar.php` la primera vez) al hosting. Las PC la toman en su siguiente ciclo (cada `INICIO` y cada corrida de `Cargador_DB.ps1`, máx. una consulta cada 30 min). Lado cliente, flujo y rollback: `sistema/MRV1.11.md` sección 10.7.

**Seguimiento de versiones y fallos [1.13.1].** `confirmar` guarda por PC `{ pc, version, ok, resultado, detalle, en }` (`resultado`: `actualizada`, `al_dia`, `revertida`, `error`, `firma_invalida`, `manifiesto_invalido`, `sin_clave`). El actualizador informa al cambiar de versión, ante **cada fallo** (sin repetir el mismo más de una vez al día) y como «latido» diario aunque no haya cambios, para que la versión se vea aunque la PC nunca se haya actualizado. `index.php` muestra esa versión como una etiqueta `v1.13.1` **junto al nombre de cada máquina** (lista de máquinas y gráfico de cada día): gris si está al día, ámbar si hay una versión publicada más nueva, roja si el último intento falló (con el detalle al pasar el mouse). `zombie.php` la muestra también en la lista de equipos. Funciones: `mr_version_pc()` / `mr_version_publicada()` en `lib/util.php`.

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
│   ├── 001_crear_base.sql       Crea computadoras y registros (CREATE TABLE IF NOT EXISTS)
│   └── 002_config_remota.sql    [v1.11] Columnas de confirmación de configuración remota (idempotente)
└── api/                          Desplegada en https://mrv1.solucionesnicaragua.com/
    ├── index.php                Formulario SPA de análisis semanal + endpoints GET de consulta
    ├── assets/                  Logos oficiales (kore_sula_claro.svg / kore_sula_oscuro.svg) — ver sección 10
    ├── registros.php            Endpoint POST — recibe y hace upsert de las filas
    ├── zombie.php               [v1.11] Configuración remota: formulario por PC con COPIAR A + descarga/confirmación (5.1)
    ├── zombie/                  [v1.11] config.<pc>.json generados (no van a git); .htaccess bloquea el acceso directo
    ├── actualizar.php           [v1.12] Actualización automática de scripts: manifiesto firmado + archivos + versiones (5.2)
    ├── update/                  [v1.12] Lo que genera tools/Publicar_Actualizacion.ps1 (manifest.json/.sig, paquete/); pcs/ no va a git; .htaccess bloquea el acceso directo
    ├── lib/
    │   ├── db.php                Conexión PDO a MySQL
    │   └── util.php              Respuestas JSON, validación de token, límite de tamaño del cuerpo,
    │                              manejador global de errores (mr_instalar_manejador_errores)
    └── config/
        ├── config.example.php   Plantilla de configuración (sí va a git) — incluye 'debug' y 'reporte' => ['clave']
        ├── config.php           Configuración real con credenciales (solo en el servidor, no va a git)
        └── .htaccess             Bloquea acceso HTTP directo a esta carpeta
```

El lado cliente (`Cargador_DB.ps1`, `Instalar_DB.ps1`, `Instalar_DB.bat`, `Desinstalar_DB.bat`, `config/db_api.example.json`) vive en `MRV1/` junto a los demás componentes del monitor — ver `MRV1/sistema/MRV1.10.md`.

---

## 8. Replicar / poner en marcha en un hosting nuevo

1. Ejecutar `sql/001_crear_base.sql` contra la base de datos MySQL del hosting.
2. Copiar `api/` completo al hosting (dominio o subdominio con PHP 8.3+ y `pdo_mysql`).
3. Copiar `api/config/config.example.php` a `api/config/config.php` y completar credenciales de BD y un token generado con `openssl rand -hex 32`. Confirmar que `config/.htaccess` bloquea el acceso directo a esa carpeta.
4. Probar con `curl` (ver `README.md`): un `POST` a `registros.php` con `X-MR-Token` correcto debe responder `{"ok":true,...}`.
5. En cada PC cliente, ejecutar `MRV1/Instalar_DB.ps1` (o responder "sí" a la pregunta correspondiente en `Instalar_Monitor.ps1`) con la URL y el token de este hosting.

## 9. Pendiente

- **[v1.11] Cliente de la configuración remota — listo:** `Sincronizar_Config.ps1` (descarga, valida, sobrescribe `monitor.json`/`ftp.json`/`db_api.json`, reinicia el monitor con la parada ordenada, ajusta los disparadores de `MRV1 FTP`/`MRV1 DB`, escribe el `EVENTO` y confirma la revisión), llamado al terminar `Cargador_DB.ps1` y en cada `INICIO`. Ver `sistema/MRV1.11.md` 10.6. Falta probar con una PC real contra `zombie.php`.
- **[v1.12] Actualización automática — lista, falta estrenarla:** generar el par de claves (`tools/Publicar_Actualizacion.ps1 -NuevaClave`; respaldar la privada), reinstalar a mano las PC con el paquete que trae `sistema/update_pubkey.xml` (última reinstalación manual), subir `actualizar.php` + `update/` y publicar. Falta probar el reinicio/rollback del monitor en una PC real. Ver 5.2.
- **[v1.11] Desplegar en producción:** ejecutar `sql/002_config_remota.sql`, subir `zombie.php` y `zombie/` (con su `.htaccess`) y tener `reporte.clave` configurada (ya están en el repositorio, solo falta llevarlos al hosting).
- **Recordatorio — optimizar cuándo se descarga la configuración** (hoy: al terminar la carga a la API y en cada `INICIO`; para una urgencia se pide reiniciar la estación).

- Desplegar `api/index.php`, poner la clave de `reporte` en `config.php` del servidor y validar el gráfico con datos reales.
- Si se necesita más de una semana a la vez: el endpoint ya acepta hasta 31 días; faltaría el selector en la página.
- Prueba de punta a punta con al menos 2 PCs reales enviando datos simultáneamente.

---

## 10. Línea gráfica (marca Kore-Sula)

Guía para que cualquier IA mantenga la identidad visual al tocar `index.php`, `zombie.php` o páginas nuevas del backend.

### 10.1 Recursos de marca

| Recurso | Ruta | Cuándo usarlo |
|---|---|---|
| Logo para fondo **claro** (texto negro + pulpo naranja) | `api/assets/kore_sula_claro.svg` | Tema claro |
| Logo para fondo **oscuro** (texto blanco + pulpo naranja) | `api/assets/kore_sula_oscuro.svg` | Tema oscuro |

- Origen oficial: `D:\git\csadm\front\public\` (`kore_sula_*.svg`; `logo_kore_sula_*.png` de 470×170 si se necesita raster; `logo_kore_sula.pdf` para impresión). Proporción 470:170; no deformar ni recolorear.
- El logo de un tema sobre el fondo del otro es ilegible: siempre poner **ambos `<img>`** y alternarlos con CSS (mismos selectores que las variables de tema: `prefers-color-scheme` + `[data-theme]`). Ver `.lg-claro` / `.lg-oscuro` en `index.php`. El `<img>` decorativo lleva `alt=""` y `aria-hidden`.
- Tamaño: ~235 px de ancho en pantallas de acceso; no menos de ~120 px. Dejar aire alrededor (≥ la altura de la "K").
- En la cabecera de la app de análisis el logo es opcional; en pantallas de acceso y reportes compartidos, sí.

### 10.2 Color

| Token | Valor | Uso |
|---|---|---|
| `--kore` | `#dc672b` (naranja del pulpo) | Acento de **marca**: botón principal del login, foco de campos, franja superior de la tarjeta. Degradado a `#c2531a` / `--kore-2 #f08a4b`. |
| `--acento` | `#0f6cbd` claro / `#4c9be8` oscuro | Acento **funcional** del análisis (selección, enlaces, `.btn.prim` dentro de la app). No mezclar con `--kore` en la misma acción. |
| Verde (`--verde`, `#15803d`) | verde | Estado "todo bien" y descarga del monitor. |
| `--err` | rojo | Errores y caídas de red. |

Fondos, paneles, bordes y textos: siempre variables del tema (`--bg`, `--panel`, `--borde`, `--texto`, `--suave`, `--tenue`). Nunca colores fijos fuera de los de marca de arriba; todo debe verse bien en claro y oscuro.

### 10.3 Estilo

- Moderno y sobrio: tarjetas de esquinas 16–20 px, vidrio translúcido (`backdrop-filter`), sombras suaves, fondo con dos halos difuminados (naranja y azul) y rejilla tenue. Tipografía del sistema (`system-ui`), titulares con `letter-spacing` negativo, etiquetas pequeñas en mayúsculas espaciadas.
- Movimiento discreto (entrada de tarjeta, pulso del punto de estado, sacudida en error), siempre desactivado con `prefers-reduced-motion`.
- Iconos: SVG en línea, trazo 1.8–2, `currentColor`, sin librerías de terceros (el backend no carga recursos externos).
- Accesibilidad: `label` real por campo, `role="alert"` en errores, foco visible, contraste AA.
- Pendiente: aplicar esta línea al login de `zombie.php` (hoy usa `mr_z_pagina`, aspecto antiguo).
