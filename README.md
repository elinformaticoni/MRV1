# 📡 MRV1 — Monitor de Red

**Monitoreo continuo de conectividad para Windows, con historial en CSV, consola web en tiempo real con gráfico de latencia, respaldo por FTP, análisis web de caídas entre varias PC, configuración remota y actualización automática.**

[![Versión](https://img.shields.io/badge/versión-1.13.7-blue)](#)
[![Plataforma](https://img.shields.io/badge/plataforma-Windows-0078D6?logo=windows)](#)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](#)
[![PHP](https://img.shields.io/badge/backend-PHP%208.3%20%2B%20MySQL-777BB4?logo=php&logoColor=white)](#)
[![Licencia](https://img.shields.io/badge/licencia-MIT-green)](LICENSE)

---

## ✨ ¿Qué es MR?

MR vigila la conectividad de uno o más destinos (IP o dominio) las 24 horas, sin intervención humana. Detecta caídas reales, mide su duración y deja un historial limpio y fácil de leer — nada de un archivo saturado con una línea por cada ping.

Se instala en minutos con un asistente, sobrevive a reinicios de Windows y funciona de forma genérica en cualquier equipo. Opcionalmente, cada PC envía sus registros a un servidor central donde un formulario web grafica la semana y muestra **si varias estaciones se cayeron al mismo tiempo**, y desde donde se puede **configurar las PC a distancia**. Los scripts se **actualizan solos** cuando se publica una versión nueva.

## 📦 Instalación

1. [⬇️ Descarga o clona este repositorio](https://github.com/elinformaticoni/MRV1/archive/refs/heads/main.zip).
2. Ejecuta **`Instalar_Monitor.bat`** como administrador.
3. Indica el **alias** de la PC (nombre descriptivo, p. ej. «Laboratorio 2 - Edificio A»), el destino a monitorear, el intervalo de ping y, si quieres, destinos adicionales.
4. Al finalizar se abre la consola y el asistente ofrece configurar también:
   - el respaldo por **FTP** (`Instalar_FTP.bat`), y
   - el envío a la **API de análisis** (`Instalar_DB.bat`).

El sistema queda instalado en `C:\ProgramData\MRV1`, corriendo como tareas programadas desde el arranque de Windows. Los instaladores y desinstaladores quedan copiados ahí mismo para reconfigurar sin el paquete original.

```powershell
git clone https://github.com/elinformaticoni/MRV1.git
cd MRV1
.\Instalar_Monitor.bat
```

> Para desinstalar: `Desinstalar_Monitor.bat` (pregunta si quita también FTP y API). Los registros históricos nunca se borran.
>
> Reinstalar solo hace falta una vez por PC con la 1.13.7 o posterior; después las mejoras llegan por **actualización automática**.

## 🚀 Características

| | |
|---|---|
| 🎯 **Múltiples destinos** | Cada IP o dominio lleva su propio estado, intervalo y umbral de confirmación. |
| 📉 **Registro inteligente** | Solo se escribe en el CSV cuando algo cambia — no cada ping. |
| 🌐 **Detección de red local** | Cambios de adaptador (Wi-Fi / cable), IP o interfaz quedan registrados como eventos. |
| 🖥️ **Consola web** | Se abre en el navegador (solo en esa PC): tarjeta por destino, **gráfico de líneas de latencia** (en vivo o del día), cargas al servidor y cambios del día con filtro y selector de fecha. Incluye la consola de texto clásica. |
| 🔘 **Botones en la consola** | «Buscar y actualizar ahora» y «Enviar datos ahora» (a la API), sin salir de la consola. |
| 🔄 **Actualización automática** | Cada PC detecta una **etiqueta nueva** del repositorio, verifica su firma, reemplaza los scripts y **vuelve atrás sola** si el monitor no arranca. |
| ☁️ **Respaldo por FTP** | Sube el historial a una carpeta con el alias de la PC, sin bloquear el monitoreo. |
| 🗄️ **API de análisis (opcional)** | Replica los registros a MySQL, sin duplicados, cada 3 horas. |
| 📊 **Análisis semanal web** | Gráfico por máquina y destino, coincidencias entre PC, filtro Cable/Wi-Fi, **IP de cada tramo del día**, versión de scripts junto al nombre de cada PC y reporte HTML descargable. |
| 🛰️ **Configuración remota** | Desde `zombie.php` se corrige la configuración de una PC (destinos, frecuencias) y se **copia** a otras con «COPIAR A…». |
| 🔁 **Resiliente** | Un fallo en la consola, el FTP, la API o la actualización nunca detiene el monitor. |
| ⚙️ **Arranque automático** | Se inicia con Windows mediante tareas programadas, sin sesión abierta. |

## 🧱 Arquitectura

```text
Monitor_Red.ps1 ──► CSV (logs\) ──► Cargador_FTP.ps1 ──► Servidor FTP
       │                 │                  └──► logs\cargados\
       │                 ├──► Cargador_DB.ps1 [opcional] ──► API (registros.php) ──► MySQL
       │                 │                                                              │
       │                 │                                    index.php: análisis semanal + HTML descargable
       │                 │                                    zombie.php: configuración remota ──► Sincronizar_Config.ps1
       │                 └──► Servidor_Consola.ps1 ──► Consola_Web.html (navegador, solo localhost)
       └──► status.json ────────► (la misma consola)

GitHub (etiquetas vX.Y.Z + manifiesto firmado) ──► Actualizar_Script.ps1 ──► bin\ de cada PC
```

| Componente | Dónde | Función |
|---|---|---|
| **Monitor** | PC · `Monitor_Red.ps1` | Hace ping, detecta cambios, escribe el CSV y `status.json` |
| **Consola web** | PC · `Servidor_Consola.ps1` + `Consola_Web.html` | Estado en tiempo real y gráfico de latencia (solo lectura, salvo los dos botones que le piden algo al monitor) |
| **Consola de texto** | PC · `Monitor_Red_Console.ps1` | Misma información en la ventana de comandos (`Abrir_Consola.bat texto`) |
| **Cargador FTP** | PC · `Cargador_FTP.ps1` | Sube el historial y archiva lo ya enviado |
| **Cargador API** | PC · `Cargador_DB.ps1` | Envía las filas del CSV a la API de análisis (opcional) |
| **Configuración remota** | PC · `Sincronizar_Config.ps1` | Aplica la instrucción que el servidor tiene para esa PC |
| **Actualizador** | PC · `Actualizar_Script.ps1` | Se actualiza desde las etiquetas de GitHub |
| **Instaladores** | PC · `Instalar_*.bat` / `.ps1` | Configuran cada componente como tarea programada |
| **API + BD** | Servidor · `backend/api/registros.php` | Recibe filas y hace upsert en MySQL |
| **Análisis semanal** | Servidor · `backend/api/index.php` | Formulario y gráfico de caídas, reporte HTML |
| **Configuración remota** | Servidor · `backend/api/zombie.php` | Edita y copia la configuración de cada PC |

## 🖥️ Uso

**Consola** — doble clic en `Abrir_Consola.bat` o en el acceso directo del escritorio. Se abre el navegador en `http://localhost:8765/` con:

- una **tarjeta por destino** (estado, latencia, promedio del día, disponibilidad, caídas);
- el **gráfico de latencia**: *En vivo* (un punto por ping mientras la página está abierta, de 5 min a 3 h) o *Día completo* (promedio por tramo con conexión; las bandas rojas son caídas);
- las **cargas al servidor** y la **actualización de scripts**, cada una con su botón;
- los **cambios del día** con filtro por tipo y selector de fecha para ver días anteriores.

`Abrir_Consola.bat texto` abre la consola de texto de siempre. Cerrar la consola **no** detiene el monitoreo.

**Análisis semanal** — en `https://mrv1.solucionesnicaragua.com/`: elige la semana, los días (lunes a viernes por defecto), el horario (07:00–15:00 por defecto) y las máquinas, y pulsa **Generar gráfico**.

- Verde tenue = conectado · rojo = sin conexión · blanco = sin datos · azul = eventos e inicios.
- **Franja naranja** = 2 o más máquinas caídas a la vez: indica un problema de la red común, no de una estación.
- Botones **Cable / Wi-Fi** (Wi-Fi oculto por defecto) para no mezclar caídas de señal inalámbrica.
- Una **barra tenue con la IP** sobre cada máquina: se extiende mientras la IP no cambie y empieza otra cuando cambia.
- La etiqueta `v1.13.7` junto al nombre de cada máquina es la versión de scripts que confirmó esa PC (ámbar = atrasada, roja = falló su última actualización).
- **Descargar HTML** genera un archivo autocontenido para compartir por correo, con los mismos botones.

**Configuración remota** — en `https://mrv1.solucionesnicaragua.com/zombie.php` (con clave): elige una PC, corrige sus valores guardados y guarda; con **COPIAR A…** aplicas la misma configuración a otros equipos.

## 🔄 Versiones y actualización automática

La versión se escribe **X.Y.Z**: el primer número no cambia, el segundo sube con cambios importantes del monitor (por ejemplo, los que afectan la base de datos) y el tercero con cada cambio. La fuente única es `version = '…'` en `sistema/Instalar_Monitor.ps1`.

- **Las PC solo miran las etiquetas** `vX.Y.Z` de este repositorio: una etiqueta nueva significa «versión lista para desplegar»; los commits intermedios no afectan a ninguna PC.
- El manifiesto de cada etiqueta (`update/manifest.json`) está **firmado**; cada PC lo verifica con una clave pública instalada, así que nadie puede enviar código a las PC sin la clave privada del desarrollador.
- Si la versión nueva no arranca, la PC restaura la anterior sola.

**Publicar una versión (desarrollador):** commitear los cambios, subir el número de versión en `Instalar_Monitor.ps1` y ejecutar `backend\tools\Publicar_Actualizacion.bat`. La primera vez, `Publicar_Actualizacion.bat -NuevaClave` crea el par de claves (la privada queda en `%USERPROFILE%\.mrv1\` y nunca se sube). El script pregunta antes de crear la etiqueta y subirla.

## 📁 Estructura

**Repositorio**

```text
MRV1\
    Instalar_Monitor.bat, Desinstalar_Monitor.bat, Abrir_Consola.bat
    README.md, LICENSE
    update\           manifest.json y manifest.sig de cada versión publicada (los genera Publicar_Actualizacion)
    sistema\          Scripts del monitor, consola web, cargadores, instaladores, actualizador y la guía MRV1.11.md
    backend\          API + base de datos + formularios + herramienta de publicación (se sube al hosting;
                      ningún instalador la copia a las PC)
```

**Instalación en cada PC**

```text
C:\ProgramData\MRV1\
    bin\              Monitor_Red.ps1, Monitor_Red_Console.ps1, Servidor_Consola.ps1, Consola_Web.html,
                      Cargador_FTP.ps1, Cargador_DB.ps1, Sincronizar_Config.ps1, Actualizar_Script.ps1
    config\           monitor.json, ftp.json, db_api.json, version.json, update_pubkey.xml
    cmd\              solicitudes de la consola al monitor (update.request, db.request)
    logs\             CSV activos: [PC] [IP] [FECHA].csv
        cargados\     CSV de días anteriores ya subidos por FTP
    diag\             monitor.log, ftp_worker.log, db_worker.log, update.log, consola_web.log
    status.json, ftp_status.json, db_status.json
```

## 📊 Formato del historial (CSV)

```text
FECHA;HORA;TIPO;TIEMPO (s);LATENCIA (ms);MENSAJE
2026-09-20;07:00:00;INICIO;0;0;LABORATORIO-PC - Profesor1 - Ethernet - 192.168.2.13 - MR V1.13.7
2026-09-20;07:00:05;OK;252;32;Conectividad disponible [Success]
2026-09-20;07:04:17;ERROR;45;0;Destino no responde [TimedOut]
```

Un archivo por destino y por día, delimitado por `;`, listo para Excel, PowerShell o Python.

## 🛠️ Requisitos

- Windows con PowerShell 5.1 (incluido de fábrica); permisos de administrador solo al instalar.
- Un navegador para la consola web (solo se usa en la propia PC).
- Acceso a `github.com` para la actualización automática (el repositorio es público).
- FTP (opcional) para el respaldo remoto.
- Para el análisis web (opcional): hosting con PHP 8.3+, `pdo_mysql` y MySQL/MariaDB.

## 📄 Documentación técnica

- [`sistema/MRV1.11.md`](./sistema/MRV1.11.md) — guía maestra: arquitectura, decisiones de diseño, consola web, actualización automática, criterios de aceptación.
- [`backend/IA.md`](./backend/IA.md) y [`backend/README.md`](./backend/README.md) — servidor: base de datos, API, formularios y puesta en marcha.

## 🗺️ Estado actual (1.13.7)

- ✅ Monitor, consola (web y de texto), cargador FTP y cargador API.
- ✅ API y base de datos en `mrv1.solucionesnicaragua.com`; análisis semanal con coincidencias, filtro Cable/Wi-Fi, barra de IP y reporte HTML.
- ✅ Configuración remota con edición por PC y «COPIAR A…».
- ✅ Actualización automática desde etiquetas de GitHub, con firma y retroceso (la etiqueta `v1.13.7` ya está publicada y verificada; el retroceso del monitor falta probarlo en una PC real).
- ⏳ Reinstalar las PC una vez con la 1.13.7 (o posterior) y desplegar `zombie.php`, `actualizar.php` e `index.php` al hosting.
- ⏳ Probar el reinicio y el retroceso del monitor en una PC real, la clave de acceso al formulario en producción y varias PC a la vez.

## 📝 Licencia

Distribuido bajo licencia [MIT](LICENSE). © 2026 Bismarck Sevilla.
