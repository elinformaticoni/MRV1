# MONITOR DE RED (MR) — GUÍA DE PROYECTO

| | |
|---|---|
| Versión | MR V1.11 |
| Cambios en 1.11 | **Configuración remota** ("zombie", sección 10.6): nuevo componente `Sincronizar_Config.ps1` en la PC del cliente que descarga la instrucción de `zombie.php` (servidor, ya en 1.10), valida rangos, sobrescribe solo las secciones recibidas de `monitor.json`/`ftp.json`/`db_api.json`, reinicia el monitor con parada ordenada si cambian destinos/detección, ajusta la frecuencia de las tareas `MRV1 FTP`/`MRV1 DB` si corresponde, escribe el `EVENTO` de aplicación y confirma la revisión al servidor. Se invoca al terminar `Cargador_DB.ps1` y en cada `INICIO` del monitor; una PC sin la API de análisis habilitada no lo recibe (P3). `status.json` y la consola muestran la revisión aplicada. `version.json` = `1.11`. |
| Nombre del paquete | `MRV1.11` — el paquete (carpeta/ZIP) y esta guía llevan siempre el mismo nombre y la misma versión, esquema `MRV1.<sub>` (igual que la carpeta de instalación `C:\ProgramData\MRV1`, ver 3.4); la guía viaja **dentro** del paquete, no se entrega suelta. |
| Repositorio | `https://github.com/elinformaticoni/MRV1.git` |

---

## 0. Reglas para cualquier IA

1. Esta guía es el **contexto maestro** del proyecto y tiene prioridad sobre implementaciones anteriores.
2. **Regla principal: no elimines funcionalidades existentes para implementar una mejora. Siempre pregunta.** Si una solicitud entra en conflicto con una característica existente, identifica el conflicto, pregunta y modifica únicamente lo necesario, preservando el resto de la arquitectura y del comportamiento.
3. Si se cambia la arquitectura, actualiza esta guía para que siga siendo el contexto maestro.
4. Antes de entregar una versión, completa la lista de la sección 13.

---

## 1. Objetivo

Sistema para Windows, basado en PowerShell y tareas programadas, que monitorea de forma continua la conectividad de uno o más destinos IP/DNS y genera un historial compacto y útil para diagnóstico. Los registros pueden además replicarse a una base de datos central (capa opcional, sección 10) para análisis con rango de fechas dinámico entre varias PC/ubicaciones.

Debe:

- monitorear uno o más destinos, cada uno con su propio estado e intervalo;
- detectar cambios reales de conectividad y calcular la duración de cada estado;
- registrar eventos en CSV (no cada ping);
- detectar cambios relevantes de la red local;
- mostrar el estado en una consola visual que se pueda abrir en cualquier momento;
- subir automáticamente los registros a un servidor FTP y moverlos a una carpeta de cargados;
- opcionalmente, replicar los registros a una API/base de datos central (sección 10) y analizarlos en un formulario web con gráfico semanal y reporte HTML descargable (sección 10.5);
- instalarse y desinstalarse con archivos BAT;
- seguir funcionando tras reiniciar Windows;
- ser reutilizable en distintas computadoras.

---

## 2. Principios de diseño

**Reglas arquitectónicas (no negociables)**

- **P1.** Solo `Monitor_Red.ps1` hace ping.
- **P2.** Se monitorea continuamente pero se registran solo cambios significativos: un estado que no cambia no genera líneas nuevas.
- **P3.** Los componentes son independientes: el fallo de uno (FTP, carga a la API, consola) no detiene a los demás.
- **P4.** La consola es solo lectura: no hace ping, no modifica nada, no guarda información y cerrarla no afecta al monitor.
- **P5.** Instalación genérica: nada codificado (IP, nombre de PC, rutas personales).

**Principios de desarrollo**

- **Modularidad:** separar responsabilidades.
- **No duplicación:** no crear dos mecanismos para la misma función sin razón técnica.
- **Compatibilidad:** priorizar lo que trae Windows (PowerShell, BAT, Programador de tareas) y evitar dependencias innecesarias.
- **Robustez:** seguir funcionando aunque falle un componente externo.
- **Mantenibilidad:** nombres claros, comentarios útiles, estructuras fáciles de modificar.
- **Escalabilidad:** permitir agregar después estadísticas, reportes, otros protocolos u otros destinos de almacenamiento sin reescribir todo.
- **Legibilidad de la información:** claridad, diagnóstico, bajo volumen, fácil lectura y procesamiento automático; no duplicar datos derivables del contexto.

---

## 3. Arquitectura

### 3.1 Componentes

| Componente | Archivo | Responsabilidad | Escribe | Lee |
|---|---|---|---|---|
| Monitor | `Monitor_Red.ps1` | Ping, estados, detección de eventos y de red local, CSV | CSV, `status.json` | `monitor.json` |
| Consola | `Monitor_Red_Console.ps1` | Visualización en tiempo real | nada | CSV, `status.json`, `ftp_status.json`, `db_status.json`; `ftp.json` y `db_api.json` solo para saber si cada carga está configurada |
| Cargador FTP | `Cargador_FTP.ps1` | Subir CSV, verificar, mover días cerrados a `cargados` | `ftp_worker.log`, `ftp_status.json`, `logs\cargados\` | CSV, `ftp.json` |
| Cargador API (opcional) | `Cargador_DB.ps1` | Replicar filas de CSV a la API de análisis (sección 10) | `db_worker.log`, `db_status.json`, `db_sync_state.json` | CSV, `logs\cargados\`, `db_api.json` |
| Configuración remota (opcional) | `Sincronizar_Config.ps1` | Aplicar la configuración enviada desde el servidor (sección 10.6) | `zombie_worker.log`, `zombie_state.json`, `monitor.json`/`ftp.json`/`db_api.json` (solo secciones recibidas), EVENTO en CSV | `db_api.json` |
| Instaladores / desinstaladores | `.BAT` / `.ps1` | Copiar archivos, configuración, tareas programadas | configuración, tareas | — |
| Tareas programadas | Windows | Arranque automático del monitor y de los cargadores | — | — |

### 3.2 Flujo de datos

```text
Monitor_Red.ps1 ──► CSV (logs\) ──► Cargador_FTP.ps1 ──► Servidor FTP
       │                 │                  └──► logs\cargados\ (días anteriores, solo tras confirmar la subida)
       │                 ├──► Cargador_DB.ps1 [opcional] ──► API/MySQL ──► index.php: análisis semanal (sección 10.5)
       │                 └──────────────────► Monitor_Red_Console.ps1 (lee: historial y totales)
       └──► status.json ────────────────────► Monitor_Red_Console.ps1 (lee: estado instantáneo)
```

### 3.3 Estructura de carpetas

**En la PC del cliente (lo que instala el paquete), `C:\ProgramData\MRV1\`:**

```text
C:\ProgramData\MRV1\
    bin\              Monitor_Red.ps1, Monitor_Red_Console.ps1, Cargador_FTP.ps1, Cargador_DB.ps1, Sincronizar_Config.ps1
    config\           monitor.json, ftp.json, db_api.json, version.json
    logs\             CSV activos (planos): [PC] [IP] [FECHA].csv
        cargados\     CSV de días anteriores ya subidos
    diag\             monitor.log, ftp_worker.log, db_worker.log, db_sync_state.json, zombie_worker.log, zombie_state.json (con rotación por tamaño)
    status.json
    ftp_status.json
    db_status.json
```

- `MRV1` = *Monitor de Red Versión 1*. La carpeta es la misma para toda la serie 1.x; la subversión (1.0, 1.1, 1.2…) es para mejoras internas que no afectan la estructura y se guarda en `config\version.json` (ver 3.4). Solo una versión mayor cambiaría la carpeta y migraría logs y configuración.
- `ftp.json` y `db_api.json` están separados de los scripts: se pueden actualizar credenciales sin tocar `bin\`, y reinstalar los scripts no las sobrescribe.
- Permisos: `status.json`, `bin\` y `logs\` legibles por usuarios; `config\` editable solo por SYSTEM y Administradores.

**En el paquete/repositorio de origen (no se instala en la PC del cliente):**

```text
MRV1\                         Raíz del paquete / repositorio (solo lo que usa una persona)
    Instalar_Monitor.bat       Instalador principal (al final ofrece instalar FTP y DB)
    Desinstalar_Monitor.bat    Desinstalador principal (pregunta si quita también FTP y DB)
    Abrir_Consola.bat          Abre la consola
    README.md, LICENSE         Presentación del repositorio (GitHub)
    backend\                   API + base de datos del servidor (sección 10.3) — vive en el
                               mismo repositorio para mantener todo junto, pero NINGÚN
                               instalador de MRV1 la copia ni la toca en la PC del cliente.
        README.md, IA.md
        sql\001_crear_base.sql
        api\index.php (formulario de análisis [v1.10]), registros.php, lib\, config\
    sistema\                   Todo lo demás [v1.9]
        MRV1.10.md             Esta guía
        Monitor_Red.ps1, Monitor_Red_Console.ps1, Cargador_FTP.ps1, Cargador_DB.ps1
        Instalar_Monitor.ps1, Instalar_FTP.ps1 / .bat, Instalar_DB.ps1 / .bat
        Desinstalar_FTP.bat, Desinstalar_DB.bat
        config\ftp.json, config\db_api.json (referencia; los asistentes no los leen)
```

- **Reubicación [v1.9]:** `Instalar_Monitor.bat` busca su asistente en `sistema\Instalar_Monitor.ps1` y, si no existe, junto a sí mismo (así funciona igual la copia plana de `C:\ProgramData\MRV1`). Los tres asistentes `.ps1` buscan cada archivo que copian (`Find-SourceFile`) en su propia carpeta, la carpeta superior, `sistema\` y `bin\`, y nunca copian un archivo sobre sí mismo; así funcionan desde el paquete nuevo, desde un paquete antiguo plano y en la reinstalación desde `C:\ProgramData\MRV1` (donde los scripts están en `bin\`).
- La estructura instalada en `C:\ProgramData\MRV1` **no cambia** (sigue plana, ver arriba).

### 3.4 Versión y empaquetado

- La versión es un control interno, guardada en `config\version.json`. A partir de la entrega 1.0, todo cambio posterior avanza solo la subversión (1.1, 1.2… 1.9, 1.10…): correcciones, mejoras y ajustes se numeran así y no cambian de versión mayor ni de carpeta de instalación (`C:\ProgramData\MRV1`). Una versión mayor (2.x) quedaría reservada para un cambio de arquitectura que rompa compatibilidad, y en ese caso sí migraría carpeta, logs y configuración.
- Reinstalar sobrescribe la versión anterior de forma transparente (ver 4.6); el asistente de instalación es quien actualiza `version.json`.
- El paquete que se entrega (carpeta/ZIP) y esta guía comparten siempre el mismo nombre y la misma subversión: esquema `MRV1.<sub>` (por ejemplo `MRV1.10`, con la guía `MRV1.10.md` dentro; desde que el proyecto vive en GitHub, cada entrega se marca con una etiqueta de git — `v1.10` — en lugar de armar un ZIP renombrado) — el mismo nombre que la carpeta de instalación `C:\ProgramData\MRV1`. La guía se entrega **dentro** del paquete, nunca suelta. Esto es solo una convención de empaquetado/entrega; no cambia `C:\ProgramData\MRV1`, que nunca lleva número de subversión en su nombre.

---

## 4. Instalación, configuración y ejecución automática

### 4.1 Instaladores y desinstaladores BAT

Siempre deben existir, porque ejecutar un `.ps1` con doble clic puede abrirlo en el Bloc de notas. Cada BAT invoca PowerShell correctamente y solicita elevación de administrador.

```text
Instalar_Monitor.bat        Desinstalar_Monitor.bat
Instalar_FTP.bat            Desinstalar_FTP.bat
Instalar_DB.bat             Desinstalar_DB.bat
Abrir_Consola.bat           lanzador de la consola
```

**Copias de respaldo dentro de `C:\ProgramData\MRV1`**: además de copiar los `.ps1` a `bin\`, `Instalar_Monitor.ps1` copia también a la raíz de `$Root` los tres pares de instaladores/desinstaladores (`Instalar_Monitor.bat`/`.ps1`, `Instalar_FTP.bat`/`.ps1`, `Instalar_DB.bat`/`.ps1`, y los tres `Desinstalar_*.bat`) y `Abrir_Consola.bat`. Cada instalador de componente (`Instalar_FTP.ps1`, `Instalar_DB.ps1`) hace la misma copia si se ejecuta por separado. Así, si se borra el paquete de descarga original, sigue estando todo lo necesario dentro de `C:\ProgramData\MRV1` — no solo para desinstalar o abrir la consola, sino también para **reinstalar/reconfigurar** cualquier componente ejecutando su BAT directamente desde ahí. `Desinstalar_Monitor.bat` quita todas esas copias (y el acceso directo del escritorio) al desinstalar el monitor.

**Acceso directo en el escritorio**: `Instalar_Monitor.ps1` crea `Monitor de Red - Consola.lnk` en el escritorio de todos los usuarios (`CommonDesktopDirectory`), apuntando a la copia de `Abrir_Consola.bat` dentro de `$Root`. Un fallo al crearlo (por ejemplo, por permisos) solo se avisa; no interrumpe el resto de la instalación. `Desinstalar_Monitor.bat` lo quita.

Detalles para generar: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..."`, ruta relativa al BAT, autoelevación, y si el usuario rechaza la elevación se informa y se sale sin dejar cambios parciales.

### 4.2 Preguntas del instalador del monitor (`Instalar_Monitor.ps1`)

Lo primero que pregunta es el **alias de esta PC** [v1.9] (Enter = el alias ya guardado; en una instalación anterior, el de `db_api.json`; si no hay, el nombre de la PC). Se pide **una sola vez**, aquí: queda en `config\monitor.json`, se muestra en el encabezado de la consola y lo usa la carga a la API. No puede quedar vacío; se le quitan `;`, `,`, comillas y saltos de línea y se limita a 60 caracteres.

Luego los destinos. El destino 1 es obligatorio; los demás son opcionales.

```text
Alias de esta PC: (Enter = actual / nombre de la PC)
IP/Dominio a monitorear:
Intervalo de ping en segundos: (Valor predeterminado: 5 segundos)
Pings consecutivos para confirmar un cambio de estado: (Valor predeterminado: 1)
¿Desea agregar otro destino? [S/N]
```

Si responde S:

```text
Nuevo IP/Dominio:
Intervalo de ping en segundos:
Pings consecutivos para confirmar un cambio de estado:
¿Desea agregar otro destino? [S/N]
```

Validaciones: destino no vacío ni repetido; intervalo entero entre 1 y 3600, vacío = 5; umbral entero entre 1 y 10, vacío = 1. El umbral se pregunta por destino, igual que el intervalo.

Al terminar, `Instalar_Monitor.ps1` abre la consola automáticamente y luego pregunta, en este orden:

```text
¿Desea instalar/configurar también el Cargador FTP ahora? [S/N] (Enter = N)
¿Desea habilitar también el envío de registros a la API de análisis ahora? [S/N] (Enter = N)
```

Cada una, si se responde S, invoca al asistente correspondiente (`Instalar_FTP.ps1` / `Instalar_DB.ps1`) sin pedir elevación de nuevo.

### 4.3 Preguntas del instalador FTP (`Instalar_FTP.ps1`)

Servidor, puerto (21 por defecto), usuario, contraseña y frecuencia (cada 2 horas por defecto). FTP plano, sin cifrado. Servidor de fábrica: `solucionesnicaragua.com`, puerto 21.

- **Carpeta remota = alias de la PC [v1.9]:** ya no se pregunta. El asistente solo la muestra; `Cargador_FTP.ps1` la calcula en cada ejecución a partir del alias de `config\monitor.json` (ver 4.2), convertido a un nombre seguro para FTP: sin acentos (á→a, ñ→n), sin `/ \ : * ? " < > | # % ; ,` y sin espacios dobles (ej. «Dirección Área Niño #3» → `/Direccion Area Nino 3/`). Sin alias se usa el nombre de la PC. Si el alias cambia, la siguiente carga crea la carpeta nueva y **la anterior queda en el servidor con su contenido** (no se mueve ni se borra nada). Un `remoteDir` que haya quedado en `ftp.json` de versiones anteriores se ignora. Los nombres de los CSV no cambian (siguen llevando el nombre de la PC, ver 6.4).
- **Verificación inmediata:** al terminar de guardar la configuración, el asistente ejecuta el cargador una vez, ahí mismo, y espera el resultado para mostrarlo en pantalla (conexión correcta y cuántos archivos se subieron, o el error concreto), sin esperar a la primera ejecución programada.

### 4.4 Preguntas del instalador de la API de análisis (`Instalar_DB.ps1`)

Todos los campos tienen un valor predeterminado; basta con Enter en cada uno para dejarlo funcionando con la configuración de fábrica del paquete.

```text
URL de la API de análisis: (Enter = URL de fábrica del paquete)
Token de la API: (Enter = mantener el actual / el de fábrica)
Frecuencia de envío en minutos: (Enter = 180, cada 3 horas)
Reintentos ante fallo: (Enter = 3)
```

- [v1.9] `Instalar_DB.ps1` ya **no pregunta el alias** si `monitor.json` lo tiene: lo muestra y lo copia a `db_api.json`; solo lo pregunta si el monitor se instaló con una versión anterior sin alias. `Cargador_DB.ps1` usa siempre el de `monitor.json` y solo si falta recurre al de `db_api.json`. Para cambiarlo se vuelve a ejecutar `Instalar_Monitor.bat`.
- El **alias** identifica el punto observado con un nombre descriptivo (ej. "Laboratorio 2 - Edificio A"); el nombre de la PC no siempre lo es. Se envía en cada carga junto con los registros (ver 10.2) y se autoregistra solo en el servidor, sin pasos manuales.
- Al igual que el instalador FTP, al terminar prueba el envío en primer plano de inmediato y muestra el resultado (envío correcto y cuántas filas se sincronizaron, o el error concreto).
- El token y la URL de fábrica que trae el asistente deben mantenerse actualizados en el propio script (`Instalar_DB.ps1`) antes de distribuir el paquete a otras PC — ver 10.4.

### 4.5 Tareas programadas

| Tarea | Disparador | Cuenta | Ajustes |
|---|---|---|---|
| Monitor (`MRV1 Monitor`) | Inicio de Windows | SYSTEM | Sin depender de que haya sesión abierta; sin límite de tiempo; reinicio automático si falla; una sola instancia; ventana oculta; se inicia al terminar la instalación sin reiniciar |
| FTP (`MRV1 FTP`) | Inicio de Windows y cada `runEveryMin` minutos (2 horas por defecto) | SYSTEM | Una sola instancia; límite de tiempo razonable; no depende de ventanas abiertas |
| API de análisis (`MRV1 DB`, opcional) | Inicio de Windows y cada `runEveryMin` minutos (3 horas por defecto) | SYSTEM | Una sola instancia; límite de tiempo razonable; no depende de ventanas abiertas |

Flujo esperado: `Windows inicia → Programador de tareas → Monitor_Red.ps1 → monitoreo automático`. El usuario no abre PowerShell manualmente. El monitor debe seguir funcionando aunque nadie haya iniciado sesión, Windows se haya reiniciado o la sesión esté cerrada.

### 4.6 Reinstalación y cambio de configuración

Cada asistente BAT es reutilizable tantas veces como haga falta, con la misma versión o con una nueva, y sirve también para cambiar solo la configuración.

- Si ya existe configuración, el asistente la muestra como valores por defecto en lugar de preguntarlo todo desde cero, y permite modificarla.
- Sobrescribe scripts en `bin\` y actualiza `version.json` sin intervención del usuario; recrea la tarea si no existe y la deja en marcha.
- El instalador del monitor hace una parada ordenada: crea un archivo de señal de parada, el monitor cierra sus estados y termina, y solo si no responde en unos segundos se detiene la tarea a la fuerza (y, como último recurso, se mata cualquier proceso `powershell.exe` huérfano ejecutando el monitor anterior). Al arrancar con la nueva configuración se escribe un nuevo `INICIO`.
- Nunca borra registros (los CSV de destinos que ya no se monitorean se conservan). Migra la configuración si `schemaVersion` cambió.

### 4.7 Desinstalación

Cada `Desinstalar_*.bat` elimina la tarea programada, los scripts y la configuración de su propio componente (los desinstaladores de FTP y de la API eliminan también sus credenciales/token). **Ninguno borra los registros históricos** (`logs\`, `logs\cargados\`) ni los logs de diagnóstico. Deben tolerar que la tarea ya no exista. `Desinstalar_Monitor.bat` además quita el acceso directo del escritorio y las copias de los BAT de instalación/desinstalación en `$Root`.

- **Eliminación verificada de la tarea [v1.9]:** cada desinstalador detiene la tarea, termina cualquier `powershell.exe` que siga ejecutando el script del componente, la elimina con `Unregister-ScheduledTask` y, si sigue existiendo, con `schtasks /Delete /F`; al final **comprueba** que ya no exista y, si no se pudo, lo muestra en rojo en lugar de decir que se desinstaló. Todos recuerdan pulsar F5 si el Programador de tareas estaba abierto (no refresca la lista solo).
- Los desinstaladores de FTP y DB borran también su archivo de estado (`ftp_status.json` / `db_status.json`).
- **`Desinstalar_Monitor.bat` y los cargadores [v1.9]:** si el Cargador FTP o la carga a la API siguen instalados, pregunta «¿Desea desinstalarlos también? [S/N] (Enter = S)». Con S los desinstala igual que sus propios BAT; con N conserva sus tareas y las copias de `Instalar_FTP/DB` y `Desinstalar_FTP/DB` en `C:\ProgramData\MRV1` (antes esas copias se borraban siempre y la tarea `MRV1 FTP`/`MRV1 DB` quedaba huérfana, sin desinstalador a mano).
- Los `.bat` se guardan en ASCII con CRLF y **sin BOM** (un BOM al inicio rompe `@echo off`).

### 4.8 Configuración persistente e instalación genérica

- La configuración se guarda en archivos estructurados, uno por componente (así cada uno se instala y desinstala de forma independiente). Los scripts no dependen de variables que solo existan durante la instalación.
- El nombre del equipo se obtiene en ejecución (`$env:COMPUTERNAME`), **no** se guarda ni se codifica.
- La estructura puede evolucionar sin romper instalaciones existentes (`schemaVersion`).

```json
// config\monitor.json
{
  "schemaVersion": 1,
  "alias": "Laboratorio 2 - Edificio A",
  "targets": [
    { "address": "8.8.8.8", "intervalSec": 5, "confirmPings": 1 },
    { "address": "192.168.2.1", "intervalSec": 5, "confirmPings": 1 }
  ],
  "detection": { "timeoutMs": 2000, "networkCheckSec": 5 }
}
```

```json
// config\ftp.json
{
  "schemaVersion": 1,
  "protocol": "ftp",
  "host": "solucionesnicaragua.com", "port": 21,
  "user": "", "password": "",
  "runEveryMin": 120, "retries": 3, "uploadCurrentDay": true
}
```

```json
// config\db_api.json (opcional — solo si se habilitó la carga a la API de análisis)
{
  "schemaVersion": 1,
  "apiUrl": "https://mrv1.solucionesnicaragua.com/registros.php",
  "token": "…",
  "alias": "Laboratorio 2 - Edificio A",
  "runEveryMin": 180,
  "retries": 3,
  "maxFilasPorEnvio": 300
}
```

---

## 5. Monitor de red (`Monitor_Red.ps1`)

### 5.1 Ciclo de monitoreo

- Cada destino mantiene su propio estado y se comprueba con su propio intervalo.
- Es válido que el destino 1 esté OK y el destino 2 en ERROR a la vez; el cambio de uno nunca modifica el otro.
- Estado interno por destino:

```text
Destino N
 ├── dirección
 ├── estado actual
 ├── inicio del estado
 ├── última respuesta
 └── estadísticas (suma y cantidad de latencias, contadores, totales por estado)
```

Notas de implementación: dirigido a Windows PowerShell 5.1 (viene con Windows); usa `System.Net.NetworkInformation.Ping` con envío asíncrono para que un destino lento no retrase a los demás; timeout = mínimo entre 2000 ms y el intervalo; las duraciones se miden con `Stopwatch` (no con el reloj, que puede saltar por sincronización horaria) y las marcas de fecha/hora con el reloj local.

### 5.2 Tipos de registro

| Tipo | Cuándo se escribe | TIEMPO y LATENCIA |
|---|---|---|
| `INICIO` | Al comenzar cada sesión del monitor (cada arranque de la tarea) | `0` y `0` |
| `OK` | Al comenzar un estado de conectividad operativa (primer estado o recuperación de un ERROR) | vacíos mientras el estado está abierto; se completan al cerrarlo |
| `ERROR` | Al comenzar un estado sin respuesta o con fallo | vacíos mientras el estado está abierto; se completan al cerrarlo |
| `EVENTO` | Cambio relevante que no es OK/ERROR: adaptador, dirección IP, interfaz, pausa, etc. | `0` y `0` |

**No existe el evento APAGADO**: no se escribe nada especial al apagar Windows ni al terminar la tarea (ver 5.7 sobre cómo se cierra el estado). La siguiente ejecución comienza con `INICIO`.

### 5.3 Detección de cambios de estado

- El cambio de estado se confirma tras `confirmPings` pings consecutivos que difieran del estado actual. El valor es configurable por destino desde el asistente y por defecto es 1 (cada cambio se registra de inmediato).
- El tiempo de detección es `confirmPings × intervalo`. Ejemplo: umbral 2 con intervalo de 3 s confirma el cambio en unos 6 s.
- El inicio del nuevo estado se toma del primer ping que lo originó, no del que lo confirmó.
- Con umbral 1, un solo ping perdido genera una fila ERROR; puede subirse el umbral por destino si aparece ruido.

### 5.4 Duración y latencia

- Al cambiar de estado se calculan la duración y el promedio de latencia del estado que termina y se completan en su fila (ver 6.1); el nuevo estado se abre y se mantiene hasta el siguiente cambio.
- La latencia se obtiene cuando es posible, se usa en consola, `status.json`, diagnóstico y estadísticas, y **no se registra ping a ping en el CSV**: se calcula la media (con suma y contador acumulados, sin guardar cada valor). En un estado ERROR la latencia promedio es 0.

### 5.5 Mensaje concreto del ping

Siempre se guarda el resultado concreto del ping, porque distingue tipos de error. Se usa el código de `IPStatus` (independiente del idioma de Windows, a diferencia del texto de `ping.exe`):

| Situación | Mensaje de ejemplo |
|---|---|
| Respuesta correcta | `Conectividad disponible [Success]` |
| Sin respuesta | `Destino no responde [TimedOut]` |
| Host o red inalcanzable | `Destino inalcanzable [DestinationHostUnreachable]` |
| Nombre no resuelto | `No se resuelve el nombre [DNS]` |
| Otros | `[TtlExpired]`, `[DestinationNetworkUnreachable]`, etc. |

Los mensajes no deben contener coma, punto y coma ni comillas (ver 6.3).

### 5.6 Detección de red local

Además del ping, el monitor detecta, cuando sea posible, cambios relevantes de red. La finalidad es explicar cambios de conectividad y alimentar el análisis, por eso cada cambio se registra como fila `EVENTO` (no como `INICIO`).

| Cambio | Ejemplo de mensaje |
|---|---|
| Adaptador (Ethernet, Wi-Fi) | `Cambio de adaptador: Wi-Fi -> Ethernet - PC01 - Profesor1 - Ethernet - 192.168.1.35 - MR V1.0` (incluye los 5 datos de identificación) |
| Dirección IP | `Cambio de dirección IP: 192.168.1.20 -> 192.168.1.35` |
| Estado de interfaz | `Interfaz conectada`, `Interfaz desconectada`, `Adaptador habilitado`, `Adaptador deshabilitado` |

- Adaptador activo = el que posee la ruta por defecto con menor métrica; se ignoran adaptadores virtuales (Hyper-V, VMware, etc.).
- Se registra el tipo de adaptador (Wi-Fi o cableado) y, en Wi-Fi, el SSID.
- Los eventos de red se escriben en el CSV de **todos** los destinos.
- Frecuencia de revisión: `networkCheckSec` (5 s por defecto).

### 5.7 Inicio de sesión y apagado

Al iniciar, el monitor escribe en el CSV de cada destino una fila `INICIO` (con `0;0`) cuyo mensaje contiene, separados por ` - `:

```text
NOMBRE DE PC - NOMBRE DE USUARIO - ADAPTADOR DE RED ACTIVO - DIRECCION IP ACTUAL - Versión del monitor
```

- El nombre de usuario es el del usuario interactivo de la sesión activa (la tarea corre como SYSTEM, así que se obtiene de la sesión); si no hay ninguna se escribe `(sin sesión)`.
- **Apagado normal de Windows:** el monitor intenta detectarlo, calcula y cierra los estados abiertos (completa TIEMPO y LATENCIA) y no escribe ningún evento. Es un intento con el tiempo limitado que Windows concede al cerrar; si no alcanza, se trata como apagado abrupto.
- **Apagado abrupto:** los campos del estado abierto quedan en blanco y no se intenta recuperar información. Esa fila se considera **INCOMPLETA** y los informes y la consola la excluyen de promedios y totales. Al arrancar, el monitor revisa la última fila del CSV más reciente de cada destino y, si quedó abierta (campos vacíos), le añade `[INCOMPLETO]` al final del mensaje, para poder filtrarla fácilmente en Excel o similar.

### 5.8 Suspensión o pausa

Si transcurre entre ciclos más de `max(3 × intervalo, 30 s)` (suspensión de Windows o proceso detenido), el monitor cierra el estado abierto con la duración hasta la última actividad conocida, escribe un `EVENTO` con la duración de la pausa y abre un estado nuevo al reanudar. Así la pausa no se cuenta como conectividad ni como caída.

### 5.9 Instancia única

El script usa un mutex con nombre para impedir dos monitores simultáneos (dos procesos haciendo ping contradicen P1).

---

## 6. Registros CSV

### 6.1 Formato y ciclo de vida de una fila

Delimitador `;`. Columnas:

```text
FECHA;HORA;TIPO;TIEMPO (s);LATENCIA (ms);MENSAJE
```

- `FECHA` y `HORA`: momento en que **comienza** el estado o ocurre el evento.
- `TIPO`: `INICIO`, `OK`, `ERROR` o `EVENTO`.
- `TIEMPO (s)`: duración del estado descrito en esa misma fila.
- `LATENCIA (ms)`: promedio de latencia de ese mismo estado (0 si no hubo respuestas).
- `MENSAJE`: ver 5.5, 5.6 y 5.7.

Ciclo de vida de una fila de estado (`OK` / `ERROR`):

1. **Al comenzar el estado** se escribe la fila de inmediato con `TIEMPO` y `LATENCIA` en blanco (`;;`).
2. **Al terminar el estado**, antes de escribir la fila del estado siguiente, el monitor edita esa fila y completa `TIEMPO` y `LATENCIA`.
3. Solo se reescribe la **última fila abierta** (el monitor recuerda su posición); nunca se reescribe el archivo entero.
4. Si el archivo está bloqueado, la edición se encola en memoria y se reintenta (ver 6.3).

Consecuencias: `TIPO` y `TIEMPO` describen el mismo estado, por lo que el tiempo total en OK es simplemente la suma de `TIEMPO` de las filas `OK` (y análogo para `ERROR`). La única fila abierta al final del último archivo es el estado actual; su duración es «ahora − FECHA HORA».

### 6.2 Ejemplo

```text
FECHA;HORA;TIPO;TIEMPO (s);LATENCIA (ms);MENSAJE
2026-09-20;22:00:00;INICIO;0;0;LABORATORIO-PC - Profesor1 - LAN2 - 192.168.2.13 - MR V1.0
2026-09-20;22:00:05;OK;252;32;Conectividad disponible [Success]
2026-09-20;22:04:17;ERROR;45;0;Destino no responde [TimedOut]
2026-09-20;22:05:02;OK;;;Conectividad restaurada [Success]
2026-09-20;22:10:00;EVENTO;0;0;Cambio de adaptador: Wi-Fi -> Ethernet - LABORATORIO-PC - Profesor1 - Ethernet - 192.168.2.20 - MR V1.0
```

La última fila `OK` está abierta (estado en curso).

### 6.3 Reglas de escritura

- **Un estado sin cambios no genera líneas.** Ejemplo de lo que NO se debe hacer: una línea `OK` cada 5 segundos durante dos horas.
- Evitar coma y punto y coma dentro de los mensajes (ambiguos en CSV); sustituirlos y eliminar comillas y saltos de línea.
- Sin espacios alrededor de `;`.
- El CSV debe poder leerse con Excel, PowerShell y Python; fechas y horas claras (`aaaa-mm-dd` y `hh:mm:ss`); estructura consistente y sin información repetitiva.
- Codificación UTF-8 con BOM para que Excel muestre bien los acentos.
- Se escribe con acceso compartido de lectura. Si el archivo está bloqueado (por ejemplo, abierto en Excel), las líneas y las ediciones se guardan en memoria y se reintentan; nunca se pierden.
- Primera línea de cada archivo nuevo: nombres de columna (`0;0` = evento instantáneo; vacío = estado sin cerrar).
- Si al arrancar la última fila de un archivo no se puede leer bien (corte de energía durante una reescritura), el monitor la marca como incompleta y sigue.

### 6.4 Organización y nombres de archivo

Los registros permiten identificar **computadora + destino + fecha** sin mezclar computadoras ni destinos. Estructura local plana, con la información clave en el nombre:

```text
[PC] [IP] [FECHA].csv        →   PC01 8.8.8.8 2026-09-20.csv
```

- Un archivo por destino y por día, en `C:\ProgramData\MRV1\logs\`; los días anteriores ya subidos pasan a `logs\cargados\`.
- Se sanea el destino para el nombre de archivo (caracteres no válidos como `:` de IPv6 pasan a `_`).
- **Cambio de día:** el monitor no se reinicia a medianoche, pero al detectarla (revisión cada ciclo) cierra el estado abierto en el archivo del día anterior con duración hasta las 00:00:00, crea el archivo nuevo y escribe en él una fila `INICIO` normal (igual que en cualquier otro arranque), seguida de una fila del estado vigente (sin tipo especial de continuidad). Así cada archivo diario queda cerrado y es interpretable por sí solo, y el FTP nunca mueve un archivo con una fila abierta.

---

## 7. `status.json`

Representa el estado **instantáneo**: lo que los CSV no pueden dar (latencia actual, última respuesta, adaptador, latido del monitor). Lo escribe únicamente el monitor. Se mantiene simple a propósito: no guarda historial ni buffer de pings; el historial, los totales y todos los cambios de la consola salen de los CSV, con alcance del día que se está observando.

- Un archivo por computadora con lista `targets` (un elemento por destino).
- Se actualiza en cada ciclo, así que también sirve de señal de actividad del monitor (los CSV solo cambian cuando hay un cambio de estado).
- Escritura atómica (archivo temporal y reemplazo) para que la consola nunca lea un archivo a medias.

```json
{
  "schemaVersion": 1,
  "version": "MR V1.0",
  "computer": "PC-01",
  "alias": "Laboratorio 2 - Edificio A",
  "user": "Profesor1",
  "adapter": { "name": "Wi-Fi", "type": "Wi-Fi", "ip": "192.168.1.103", "status": "Up" },
  "sessionStart": "2026-09-20T07:00:00",
  "timestamp": "2026-09-20T22:35:10",
  "targets": [
    {
      "address": "8.8.8.8",
      "intervalSec": 5,
      "status": "OK",
      "stateSince": "2026-09-20T22:33:10",
      "stateDuration": 120,
      "latency": 25,
      "lastResponse": "2026-09-20T22:35:10",
      "lastMessage": "Success"
    },
    {
      "address": "192.168.2.10",
      "intervalSec": 5,
      "status": "ERROR",
      "stateSince": "2026-09-20T22:34:10",
      "stateDuration": 1120,
      "latency": null,
      "lastResponse": "2026-09-20T22:34:10",
      "lastMessage": "TimedOut"
    }
  ]
}
```

---

## 8. Consola (`Monitor_Red_Console.ps1`)

Interfaz visual que se puede abrir en cualquier momento. **No hace ping** y no guarda nada: en cada actualización lee los CSV y `status.json` y presenta los cálculos hechos en el momento. No bloquea la recolección de registros (abre los archivos con acceso compartido de lectura).

**Cerrar la consola no detiene el monitor.** El monitor sigue con `PING → CSV → status.json`; la consola no controla su vida.

La consola muestra:

**Arriba (resumen)**
- el **alias** de la PC en la primera línea, en mayúsculas y color cian, y también en el título de la ventana [v1.9] (de `status.json`; si el monitor en marcha es anterior y no lo trae, de `config\monitor.json`);
- computadora, usuario, adaptador actual (tipo y nombre) e IP, versión;
- tiempo desde el inicio de la sesión;
- por destino: dirección, estado actual, desde cuándo y duración, latencia actual y promedio, última respuesta;
- totales y promedios por destino, del día que se está observando: suma de tiempo por estado, cantidad de errores, latencia media (calculados de las filas cerradas; las filas `[INCOMPLETO]` se excluyen).

**Cargas al servidor (FTP y DB)** [v1.9]

Bloque «CARGAS AL SERVIDOR» con una línea por cargador (`FTP` y `DB`), para ver de un vistazo cómo va todo. La consola no se conecta ni al FTP ni a la API: solo comprueba si existe la configuración del componente (`config\ftp.json` / `config\db_api.json`) y lee el archivo de estado que escribe cada cargador (`Root\ftp_status.json` / `Root\db_status.json`, ver 9.3 y 10.2).

| Situación | Qué muestra |
|---|---|
| No existe el archivo de configuración | gris: `NO CONFIGURADO` — «La carga FTP no está configurada» / «La carga al servidor DB no está configurada», con el BAT que la habilita (`Instalar_FTP.bat` / `Instalar_DB.bat`) |
| Configuración sin datos obligatorios (`host` en FTP; `apiUrl` o `token` en DB) | amarillo: `CONFIGURACIÓN INCOMPLETA` y el BAT para completarla |
| Configurada pero todavía sin archivo de estado | amarillo: `SIN EJECUTAR` y el nombre de la tarea programada que debe correr |
| Última ejecución correcta | verde `OK`, **última carga** (hora; fecha y hora si no fue hoy) y hace cuánto, **próxima** carga y en cuánto falta; debajo, en gris, archivos subidos (FTP) o sincronizados y filas nuevas/actualizadas (DB) |
| Última ejecución fallida | rojo «\*\*\* ERROR \*\*\*», hora del último intento, próxima, el mensaje concreto del error y la sugerencia de volver a ejecutar el BAT del componente |
| La hora prevista ya pasó | hasta 15 min: «Próxima: en breve»; más de 15 min: amarillo «ATRASADA desde …» y aviso de verificar la tarea programada (`MRV1 FTP` / `MRV1 DB`) |

- Si el archivo de configuración existe pero no se puede leer (permisos), se da por configurado y decide el archivo de estado.
- Un `*_status.json` que quedó de una instalación anterior no engaña: si la configuración ya no existe (componente desinstalado), se muestra `NO CONFIGURADO`.

```text
CARGAS AL SERVIDOR
  FTP  OK   Última carga: 10:28:58 (hace 00:40:01)   Próxima: 12:28:58 (en 01:19:59)
         Archivos subidos: 3 (días anteriores 1 + hoy 2)
  DB   NO CONFIGURADO   La carga al servidor DB no está configurada (ejecute Instalar_DB.bat para habilitarla).
```

**Abajo (historial)**
- **todos los cambios de estado del día que estén disponibles** (sin tope), del más reciente al más antiguo, con el destino indicado (unificados si hay varios). El buffer de la consola se agranda al abrir (hasta ~3000 líneas) para que un día con muchas caídas no rompa el redibujado; si la lista no cabe en la ventana visible, se recorre con la barra de desplazamiento.

**Colores:** verde = OK, rojo = ERROR, amarillo = EVENTO, cian = INICIO, gris = INCOMPLETO.

```text
MONITOR DE RED MR V1.0   ·   LABORATORIO 2 - EDIFICIO A     PC-01 · Profesor1 · Wi-Fi 192.168.1.103        Actualizado 22:35:10
Sesión desde 07:00:00 (15:35:10)

DESTINO 1: 8.8.8.8      ESTADO: OK  desde 22:33:10 (00:02:00)
  Latencia: 24 ms (prom. 27 ms)   Última respuesta: 22:35:10
  Hoy: OK 04:10:00 · ERROR 00:03:20 · 3 caídas

DESTINO 2: 192.168.1.1  ESTADO: ERROR  desde 22:34:01 (00:01:09)
  Última respuesta: 22:34:01
  Hoy: OK 04:08:00 · ERROR 00:05:20 · 4 caídas

TODOS LOS CAMBIOS DE HOY
22:34:01  192.168.1.1  ERROR   Destino no responde [TimedOut]
22:33:10  8.8.8.8      OK      Conectividad restaurada [Success]
22:10:00  todos        EVENTO  Cambio de adaptador: Wi-Fi -> Ethernet
```

- Si `timestamp` de `status.json` tiene más antigüedad que 3 × el intervalo, se muestra el aviso «MONITOR NO ACTIVO / DATOS DESACTUALIZADOS».
- Se actualiza reposicionando el cursor, sin `Clear-Host`, para evitar parpadeo; relee un CSV solo si cambió.
- Funciona con permisos de usuario normal (solo lectura).
- Se abre con `Abrir_Consola.bat`.

---

## 9. Cargador FTP (`Cargador_FTP.ps1`)

Componente independiente. **Los problemas del FTP no deben detener el monitoreo**, y el proceso de ping nunca espera por una transferencia.

### 9.1 Flujo

Se ejecuta al iniciar Windows y cada `runEveryMin` minutos (2 horas por defecto). En cada ejecución:

1. **Días anteriores:** buscar en `logs\` los CSV con fecha anterior a hoy → conectar → subir → verificar que la transferencia fue exitosa (tamaño remoto igual al local) → mover a `logs\cargados\`.
2. **Día en curso:** subir una copia de cada CSV de hoy, **sobrescribiendo** el del servidor. Estos archivos **no se mueven**: siguen en `logs\` porque el monitor continúa escribiendo.

Se sube con nombre temporal (`.part`) y se renombra al terminar, para no dejar archivos parciales con nombre válido; para el día en curso se sube una copia temporal del archivo (lectura compartida) para no chocar con el monitor.

```text
logs\
    PC01 8.8.8.8 2026-09-20.csv          (día en curso: se sube copia, no se mueve)
logs\cargados\
    PC01 8.8.8.8 2026-09-19.csv          (día cerrado: subido y movido)
```

### 9.2 Reglas

- FTP plano, puerto 21, con .NET (`FtpWebRequest`), sin cifrar. Credenciales en `config\ftp.json`, separado de los scripts.
- **No mover a `cargados` un archivo cuya transferencia no fue confirmada.**
- Reintentos controlados ante fallo; el archivo queda disponible para el siguiente intento. No se pierde información ni se borran registros pendientes.
- Si el servidor está apagado, sin conexión, temporalmente inaccesible o rechaza la transferencia, el monitor sigue funcionando normalmente.
- Log del cargador (`ftp_worker.log`), con rotación por tamaño.
- En el servidor, los archivos van en una carpeta con el **alias** de la PC (ver 4.3); el cargador la crea automáticamente si no existe. `ftp_status.json` incluye `remoteDir` y la consola la muestra en la línea de detalle del FTP.

### 9.3 Verificación de conexión y estado visible

- **Antes de intentar subir nada**, el cargador prueba la conexión (login + un comando simple al servidor), incluso cuando no hay ningún CSV pendiente, para que un host/usuario/contraseña/puerto incorrectos se detecten como error real y no se confundan con «no había nada que subir».
- `Instalar_FTP.ps1` ejecuta el cargador una vez, en primer plano, justo al terminar de guardar la configuración, y espera su resultado (hasta 20 s) para mostrarlo de inmediato en pantalla.
- Cada ejecución escribe `Root\ftp_status.json` con la última subida, cuántos archivos se subieron, la hora estimada de la próxima ejecución y el último error si lo hubo. La consola solo lee ese archivo; nunca se conecta ella misma al servidor FTP.

---

## 10. Carga a la API de análisis (`Cargador_DB.ps1`, opcional)

Componente independiente y **opcional**: si no se habilita en el instalador, MRV1 funciona exactamente igual que sin esta sección (CSV local + FTP). Su función es replicar los mismos registros a una base de datos central (MySQL, vía una API HTTP propia) para poder generar reportes con rango de fechas dinámico y de varias PC/ubicaciones a la vez — algo que el CSV plano y el FTP no permiten por sí solos.

### 10.1 Flujo

Se ejecuta al iniciar Windows y cada `runEveryMin` minutos (3 horas por defecto). En cada ejecución revisa tanto `logs\` como `logs\cargados\` (sin tocar ni mover nada de lo que administra `Cargador_FTP.ps1`):

1. **Días anteriores (cerrados):** se leen y se envían **una sola vez**; una vez confirmados por la API se marcan como sincronizados en `diag\db_sync_state.json`, para no releerlos ni reenviarlos en corridas futuras.
2. **Día en curso:** se reenvía completo en cada corrida, porque su última fila puede seguir cambiando (copia de lectura compartida, igual que hace el FTP, para no chocar con el monitor).

El envío es por **filas**, no por archivo: cada fila del CSV se traduce a un objeto JSON y se manda en lotes (`maxFilasPorEnvio`, 300 por defecto) por HTTPS, con el header `X-MR-Token` y TLS 1.2. La API deduplica del lado del servidor (ver 10.3), así reenviar el archivo del día en curso completo en cada corrida nunca genera filas repetidas.

### 10.2 Configuración, log y estado

- `config\db_api.json` (ver 4.8) — URL de la API, token, alias del PC, frecuencia y reintentos. Separado de los scripts, no se pisa al reinstalar.
- El **alias** (nombre descriptivo del punto observado) se envía en **cada** carga, no solo cuando cambia — así el servidor lo mantiene al día solo, sin pasos manuales, y el primer envío fallido tras instalar se autocorrige en la siguiente corrida.
- Log propio: `diag\db_worker.log` (misma rotación por tamaño que `ftp_worker.log`).
- Estado propio para la consola: `Root\db_status.json` (última corrida, archivos sincronizados/fallidos, filas insertadas/actualizadas, próxima hora estimada) — mismo patrón que `ftp_status.json`; la consola lo muestra en el bloque «CARGAS AL SERVIDOR» (ver 8).

### 10.3 Backend (API + base de datos)

El servidor vive en `MRV1\backend\` (mismo repositorio, junto a los scripts, pero **el instalador de MRV1 nunca copia ni toca esta carpeta en la PC del cliente** — ver 3.3). Documentación completa de puesta en marcha, esquema de base de datos y referencia de la API: `backend/README.md` y `backend/IA.md`.

Resumen:

- **Base de datos MySQL** — tablas `computadoras` (PC → alias) y `registros` (una fila por evento del CSV), con una clave única que permite el `UPSERT` (una fila que se abre y luego se cierra se actualiza sola, sin duplicarse).
- **API (PHP)** — un único endpoint, `POST registros.php`, que valida el token, valida cada fila, y hace upsert de `computadoras` y `registros` en una transacción.
- **Formulario de análisis [v1.10]** — `index.php`, en la raíz del mismo subdominio; solo lee la base de datos (sección 10.5).

### 10.4 Seguridad

- HTTPS obligatorio para la API (a nivel de hosting/dominio); `Cargador_DB.ps1` fuerza TLS 1.2 en el cliente.
- Token único y global (no uno por PC), para simplificar la configuración: el mismo valor vive en el `config.php` del servidor y en el `db_api.json` de cada PC.
- **El token y la URL de fábrica que trae `Instalar_DB.ps1` deben actualizarse antes de distribuir el paquete** a otras PC o a otro cliente — no deben quedar apuntando al servidor/token de otra instalación.

### 10.5 Formulario de análisis semanal [v1.10]

`backend/api/index.php`, publicado en la raíz del subdominio de la API (`https://mrv1.solucionesnicaragua.com/`). Página de una sola vista (SPA), prácticamente de solo lectura de la base de datos — la única excepción es eliminar una computadora [v1.11], más abajo. Detalle completo (endpoints, reglas de cálculo, control de acceso): `backend/IA.md` sección 5.

- **Filtros:** semana (lunes a domingo, por defecto la actual), días (Lun–Vie por defecto), horario del eje horizontal (07:00–15:00 por defecto) y máquinas con registros en esa semana (eje vertical; todas marcadas por defecto).
- **Recuerda la cabecera [v1.11]:** semana, días, horario, selección de máquinas y las tres casillas de opciones (coincidencias, eventos, días sin registros) se guardan en el navegador (`localStorage`) y se restauran al recargar la página, por PC/navegador — no viaja al servidor ni se comparte entre equipos.
- **Eliminar computadora [v1.11]:** con sesión iniciada, cada máquina tiene un menú «⋯» con «Eliminar computadora…» — borra esa PC y **todos** sus registros de la base de datos (irreversible, pide confirmación) y retira cualquier instrucción de configuración remota pendiente para ella. Sin clave de acceso configurada en el servidor, la opción no está disponible (la acción exige sesión).
- **Gráfico:** un bloque por día, una franja por máquina y una fila por destino (varios destinos, uno encima del otro). Verde = conectado con registros (sólido por cable, bandeado con bandas claras por Wi-Fi); rojo = sin conexión; blanco = sin datos; azul = eventos de red e inicios del monitor. A la derecha, el tiempo desconectado dentro del horario y la cantidad de caídas; al final, un resumen de la semana con disponibilidad.
- **Coincidencias:** franja en ámbar/naranja (deliberadamente distinta del rojo de error) donde 2 o más máquinas distintas están sin conexión al mismo tiempo (tolerancia 5 s) — ayuda a ubicar el problema en la red común.
- **Filtro por red (Cable / Wi-Fi):** botones dentro del reporte; **ambas redes visibles por defecto**. La red de cada tramo sale del `INICIO` (tercer campo del mensaje) y de los `EVENTO` «Cambio de adaptador» (5.6, 5.7). Los tramos por Wi-Fi se ven bandeados para distinguirlos del cable sin necesidad de ocultarlos.
- **«✓ Sin caídas»** solo si hay registros de conexión durante todo el horario, sin ningún ERROR.
- **Descargar HTML:** un solo archivo autocontenido (datos + gráfico + botones Cable/Wi-Fi), sin conexión a internet, para compartir por correo.
- **Acceso:** clave opcional en `config.php` del servidor (`'reporte' => ['clave' => '…']`); sin ella la página queda abierta y lo advierte.

Pendiente: probar con datos reales de varias PC y dejar configurada la clave de acceso en producción.

### 10.6 Configuración remota (`Sincronizar_Config.ps1`) [v1.11]

Permite cambiar desde el servidor los destinos, tiempos de ping y otros datos de una o varias PC. **El servidor manda y la PC obedece**: no hay modo «zombie sí/no» ni configuración local paralela. Si quiere volver a otra configuración, se corrige de igual manera en el servidor. Detalle del servidor (archivo por PC, endpoints, rangos, formulario multi-selección): `backend/IA.md` sección 5.1.

**Comportamiento de la PC (`Sincronizar_Config.ps1`, en `bin\`, junto a los demás componentes):**

| Situación | Qué hace |
|---|---|
| No existe `config\db_api.json` (API de análisis no habilitada) | No hace nada: no hay a dónde preguntar (P3, igual que el resto de la sección 10) |
| Queda una revisión aplicada sin confirmar de una corrida anterior | Reintenta primero `POST zombie.php?accion=confirmar` antes de consultar nada nuevo |
| El servidor entrega una instrucción con `revision` mayor a la ya aplicada y todos sus valores dentro de los rangos válidos | La **sobrescribe**: aplica los campos permitidos de `monitor.json`, `ftp.json` y `db_api.json`, solo en las secciones que vengan |
| Algún valor recibido está fuera de rango | No aplica nada de la instrucción (ni siquiera las secciones válidas) y lo registra en `diag\zombie_worker.log`; queda pendiente hasta que se corrija en el servidor |
| `404` (sin instrucción), sin red, servidor caído, JSON inválido o revisión no mayor | No hace nada: sigue con la última configuración guardada |

Al aplicar:

1. Si cambiaron destinos o `detection`, escribe un `EVENTO` «Configuración remota aplicada (rev. N)» en el CSV de hoy de cada destino anterior y reinicia el monitor con la parada ordenada de 4.6 (nuevo `INICIO` al arrancar). El monitor puede trabajar sin la API ni esta función (P3); un cambio solo de frecuencia de `db`/`ftp` no lo reinicia.
2. Si cambió la frecuencia de `db` o `ftp`, ajusta el disparador de repetición de la tarea `MRV1 DB` / `MRV1 FTP` correspondiente (sin tocar su disparador de inicio de Windows ni ninguna otra propiedad).
3. Confirma la revisión aplicada al servidor (`POST zombie.php?accion=confirmar`), que la muestra como «Aplicada» / «Pendiente» por PC, y guarda el resultado en `diag\zombie_state.json` (si el servidor no respondió, la próxima corrida reintenta confirmar antes de seguir).
4. `status.json` suma `configRevision` y `configAppliedAt` (leídos de `diag\zombie_state.json`); la consola los muestra bajo el adaptador, como «CONFIGURACIÓN REMOTA: rev. N (aplicada …)», solo si ya se aplicó alguna.

**Cuándo corre:** en un proceso aparte (oculto, sin bloquear al que lo lanza), al terminar cada corrida de `Cargador_DB.ps1` (inicio de Windows y cada `runEveryMin`) y cada vez que el monitor escribe una fila `INICIO` (arranque y cambio de día). Para una urgencia se pide al usuario que reinicie la estación o ejecute manualmente el script. La nueva configuración **no** puede tocar credenciales FTP, token, URL ni alias. Reutiliza la URL (deriva `zombie.php` de la carpeta de `apiUrl`) y el token de `db_api.json`, así que una PC sin la API habilitada no recibe instrucciones (el monitor funciona igual).

**Pendiente (recordatorio):** optimizar cuándo se descarga la configuración (hoy: en cada `INICIO` y al terminar la carga a la API; ver también `backend/IA.md` sección 9).

---

## 11. Manejo de errores

Un error en un componente no debe provocar innecesariamente el cierre de todo el sistema.

| Situación | Comportamiento esperado |
|---|---|
| Destino inexistente | ERROR con el mensaje concreto (por ejemplo, DNS); se sigue intentando |
| Destino sin respuesta | Transición a ERROR según el umbral configurado |
| Pérdida de Internet o de red local | Los destinos afectados pasan a ERROR; `EVENTO` de red si corresponde |
| Adaptador desconectado | `EVENTO` de interfaz; el ping continúa |
| Apagado normal de Windows | Se cierran los estados abiertos; sin evento APAGADO |
| Apagado abrupto | Estado abierto queda en blanco (incompleto, fuera de métricas); nuevo `INICIO` al arrancar |
| Archivo bloqueado | Cola en memoria y reintento; sin pérdida |
| Error al crear CSV | Reintento, registro en `monitor.log`, datos retenidos en memoria |
| Error de permisos | Registro en `monitor.log`; el instalador verifica y ajusta permisos |
| Error de FTP, servidor inaccesible o archivo parcial | Reintentos; el archivo sigue pendiente; se anota en `ftp_worker.log` |
| Error de la API de análisis, servidor inaccesible o token inválido | Reintentos; el archivo/fila sigue pendiente para la próxima corrida; se anota en `db_worker.log`; el monitor y el FTP no se ven afectados |
| Tarea programada inexistente | El desinstalador lo tolera; el instalador la crea |
| Ejecución sin privilegios suficientes | El BAT solicita elevación; si se rechaza, avisa y sale sin cambios parciales |

---

## 12. Criterios de aceptación

Una versión es correcta si cumple como mínimo:

**Instalación y ejecución**
- [ ] Solicita IP/dominio durante la instalación.
- [ ] Solicita intervalo y usa 5 segundos por defecto.
- [ ] Solicita el umbral de confirmación y usa 1 por defecto.
- [ ] Cada asistente puede reejecutarse para cambiar la configuración sin perder registros.
- [ ] Existen las tareas programadas de monitor, FTP y (si está habilitada) API de análisis.
- [ ] Existen instaladores y desinstaladores BAT para monitor, FTP y API de análisis.
- [ ] El monitor continúa después de reiniciar Windows.
- [ ] El sistema no depende de una computadora específica.
- [ ] Solo corre una instancia de cada componente (monitor, FTP, API de análisis).

**Monitor y registros**
- [ ] Monitorea continuamente y mantiene estados independientes por destino.
- [ ] No registra cada ping.
- [ ] Detecta cambios OK → ERROR y ERROR → OK.
- [ ] Calcula la duración del estado.
- [ ] Genera y actualiza el CSV con las columnas establecidas.
- [ ] La fila de estado se escribe al iniciar con tiempo y latencia en blanco y se completa al cerrarlo.
- [ ] Registra INICIO y permite EVENTO.
- [ ] NO genera APAGADO.
- [ ] Un apagado abrupto deja el estado en blanco y no afecta las métricas.
- [ ] Detecta cambios relevantes de red y los registra como EVENTO.
- [ ] Guarda el mensaje concreto del ping.
- [ ] Un archivo CSV bloqueado no pierde registros.
- [ ] Un fallo de red no destruye los registros.

**Estado y consola**
- [ ] Actualiza `status.json`.
- [ ] La consola muestra el estado en tiempo real, totales arriba y todos los cambios de hoy con colores.
- [ ] La consola no hace ping ni guarda información.
- [ ] Cerrar la consola no detiene el monitor.
- [ ] La consola avisa cuando el monitor no está activo.
- [ ] La consola muestra, para FTP y DB, si la carga está configurada o no, la última carga, si fue correcta y la próxima ejecución.

**FTP**
- [ ] El FTP funciona independientemente.
- [ ] Los CSV de días anteriores enviados se mueven a `logs\cargados\`.
- [ ] El CSV del día en curso se sube periódicamente sobrescribiendo el del servidor y no se mueve.
- [ ] Existen logs del cargador FTP.
- [ ] Un fallo FTP no detiene el monitoreo.
- [ ] No se pierden archivos pendientes de FTP.

**API de análisis (si está habilitada)**
- [ ] Funciona independientemente del monitor y del FTP.
- [ ] Reenviar el mismo archivo/fila no duplica registros en el servidor (upsert confirmado).
- [ ] El alias del PC se refleja en el servidor tras el primer envío.
- [ ] Existen logs del cargador de la API.
- [ ] Un fallo de la API no detiene el monitoreo ni al FTP.

**Formulario de análisis (servidor) [v1.10]**
- [ ] Lista solo las máquinas con registros en la semana elegida.
- [ ] El gráfico muestra un destino por fila, las caídas en rojo y la suma desconectada dentro del horario.
- [ ] Marca en naranja las caídas simultáneas de 2 o más máquinas.
- [ ] Los botones Cable / Wi-Fi funcionan en la página y en el HTML descargado.

**Configuración remota (si la API está habilitada) [v1.11]**
- [ ] Sin `config\db_api.json`, `Sincronizar_Config.ps1` no hace ninguna solicitud (P3).
- [ ] Una instrucción nueva (revisión mayor) se aplica solo en las secciones recibidas, sin tocar credenciales FTP, token, URL ni alias.
- [ ] Un valor fuera de rango no aplica nada de la instrucción y queda registrado en `zombie_worker.log`.
- [ ] Cambiar destinos/`detection` reinicia el monitor con parada ordenada y deja el `EVENTO` de aplicación antes del nuevo `INICIO`.
- [ ] Cambiar la frecuencia de `db`/`ftp` ajusta la tarea correspondiente sin reiniciar el monitor.
- [ ] La revisión aplicada se confirma al servidor y se refleja en `status.json` y en el encabezado de la consola.
- [ ] Repetir la misma revisión (o un `404`) no hace nada.

---

## 13. Lista de verificación antes de entregar (para IA)

1. Leer esta guía.
2. Identificar qué componente se modifica.
3. Mantener todas las funcionalidades existentes.
4. Modificar solamente lo necesario.
5. Verificar instaladores y desinstaladores de los tres componentes (monitor, FTP, API de análisis).
6. Verificar las tres tareas programadas.
7. Verificar que el monitor funciona sin la consola, sin el FTP y sin la API de análisis.
8. Verificar que ni el FTP ni la API de análisis bloquean al monitor.
9. Verificar que el CSV registra cambios y no cada ping.
10. Probar el flujo completo: instalación → monitoreo → registro → consola → FTP → API de análisis.
11. Si se cambia la arquitectura, actualizar esta guía.

---

## 14. Archivos del paquete (versión 1.11)

Ver la estructura completa en 3.3. Resumen:

```text
MRV1\                         Raíz del paquete / repositorio (solo lo que usa una persona)
    Instalar_Monitor.bat       Instalador principal (al final ofrece instalar FTP y DB)
    Desinstalar_Monitor.bat    Desinstalador principal (pregunta si quita también FTP y DB)
    Abrir_Consola.bat          Abre la consola
    README.md, LICENSE         Presentación del repositorio (GitHub)
    backend\                   API + base de datos del servidor (sección 10.3) — vive en el
                               mismo repositorio para mantener todo junto, pero NINGÚN
                               instalador de MRV1 la copia ni la toca en la PC del cliente.
        README.md, IA.md
        sql\001_crear_base.sql, sql\002_config_remota.sql [v1.11]
        api\index.php (formulario de análisis [v1.10]), registros.php, zombie.php [v1.11], lib\, config\
    sistema\                   Todo lo demás
        MRV1.11.md             Esta guía
        Monitor_Red.ps1, Monitor_Red_Console.ps1, Cargador_FTP.ps1, Cargador_DB.ps1, Sincronizar_Config.ps1 [v1.11]
        Instalar_Monitor.ps1, Instalar_FTP.ps1 / .bat, Instalar_DB.ps1 / .bat
        Desinstalar_FTP.bat, Desinstalar_DB.bat
        config\ftp.json, config\db_api.json (referencia; los asistentes no los leen)
```

Notas:

- Los `.ps1` y `.bat` están en CRLF (final de línea de Windows) y los `.ps1` se leen como UTF-8 con BOM; guardar cualquier edición manteniendo esa codificación.
- Cada `Instalar_*.bat` invoca a su asistente `.ps1` correspondiente (mismo nombre, misma carpeta; excepción: `Instalar_Monitor.bat` de la raíz lo busca en `sistema\`) con `powershell -NoProfile -ExecutionPolicy Bypass -File`, así que cada par `.ps1`/`.bat` debe copiarse junto con los cinco scripts del sistema (`Monitor_Red.ps1`, `Monitor_Red_Console.ps1`, `Cargador_FTP.ps1`, `Cargador_DB.ps1`, `Sincronizar_Config.ps1`), que `Instalar_Monitor.ps1` copia solo a `bin\`.

### Lista de pruebas sugerida

1. **Instalación limpia**: ejecutar `Instalar_Monitor.bat` (raíz del paquete) en una carpeta vacía de `C:\ProgramData\MRV1`, con 2 destinos (uno que responda y uno que no). Confirmar que la tarea `MRV1 Monitor` queda en ejecución, que aparecen los CSV con las filas `INICIO` y `OK`/`ERROR` esperadas, que `C:\ProgramData\MRV1` (raíz) contiene también los desinstaladores, `Abrir_Consola.bat` y los instaladores de los tres componentes, y que aparece el acceso directo en el escritorio.
2. **Reinstalación**: volver a ejecutar `Instalar_Monitor.bat` desde la copia en `C:\ProgramData\MRV1`, cambiar el intervalo de un destino. Confirmar que el monitor se detiene y reinicia solo, sin perder los CSV existentes.
3. **Consola**: ejecutar `Abrir_Consola.bat` mientras el monitor corre, con más de un destino configurado; verificar un bloque `DESTINO n` por cada uno. Provocar una caída y verificar que el estado, los totales y la lista de cambios de hoy se actualizan en vivo con los colores esperados. Cerrar la consola y confirmar que el monitor sigue. Verificar el bloque «CARGAS AL SERVIDOR»: sin `ftp.json`/`db_api.json` muestra `NO CONFIGURADO` en cada uno; tras instalar FTP/DB muestra `OK` con última carga y próxima, o `*** ERROR ***` con el mensaje si la conexión falla.
4. **Apagado y arranque**: reiniciar Windows con el monitor en marcha; verificar que no aparece ningún evento `APAGADO`, que el estado abierto se cerró (o quedó `[INCOMPLETO]` si el apagado fue forzado) y que hay un nuevo `INICIO` tras el arranque.
5. **FTP**: ejecutar `Instalar_FTP.bat` presionando solo Enter en cada pregunta. Confirmar que el asistente ya no pregunta la carpeta remota y muestra la del alias, que el instalador muestra «CONEXIÓN FTP CORRECTA» y cuántos archivos subió, y que en el servidor el archivo de hoy quedó en esa carpeta. Esperar a que la tarea corra sola y, al pasar la medianoche, confirmar que el archivo del día anterior aparece en `logs\cargados\` local y en el servidor.
6. **API de análisis**: ejecutar `Instalar_DB.bat` presionando solo Enter en cada pregunta. Confirmar que el instalador muestra «ENVÍO A LA API CORRECTO» con filas insertadas, y que las filas aparecen en la base de datos. Repetir la corrida y confirmar que no se duplican (deduplicación por upsert). Abrir `https://mrv1.solucionesnicaragua.com/`, elegir la semana y confirmar que la PC aparece en la lista de máquinas y que el gráfico y la descarga HTML funcionan.
7. **Archivo bloqueado**: abrir un CSV activo en Excel mientras el monitor sigue corriendo; provocar un cambio de estado y confirmar que, al cerrar Excel, la fila pendiente se completa sin perder datos.
8. **Desinstalación**: ejecutar `Desinstalar_Monitor.bat`, `Desinstalar_FTP.bat` y `Desinstalar_DB.bat`; confirmar que las tareas desaparecen, que `logs\` y `logs\cargados\` permanecen intactos, y que desaparecen el acceso directo del escritorio y las copias de los BAT en `C:\ProgramData\MRV1`.
9. **Configuración remota**: con la API habilitada, crear una instrucción en `zombie.php` para esta PC cambiando un destino y la frecuencia del FTP. Confirmar que, en la siguiente corrida de `Cargador_DB.ps1` (o forzando `Sincronizar_Config.ps1 -Root C:\ProgramData\MRV1`), el monitor se reinicia con el destino nuevo, la tarea `MRV1 FTP` queda con la frecuencia nueva, aparece el `EVENTO` de aplicación en el CSV, `zombie.php` muestra la revisión como «Aplicada» y la consola la muestra en el encabezado. Repetir la corrida y confirmar que no vuelve a reiniciar el monitor (misma revisión).
