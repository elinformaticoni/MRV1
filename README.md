# 📡 MRV1 — Monitor de Red

**Monitoreo continuo de conectividad para Windows, con historial en CSV, consola en vivo, respaldo por FTP y análisis web de caídas entre varias PC.**

[![Versión](https://img.shields.io/badge/versión-MRV1.10-blue)](#)
[![Plataforma](https://img.shields.io/badge/plataforma-Windows-0078D6?logo=windows)](#)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](#)
[![PHP](https://img.shields.io/badge/backend-PHP%208.3%20%2B%20MySQL-777BB4?logo=php&logoColor=white)](#)
[![Licencia](https://img.shields.io/badge/licencia-MIT-green)](LICENSE)

---

## ✨ ¿Qué es MR?

MR vigila la conectividad de uno o más destinos (IP o dominio) las 24 horas, sin intervención humana. Detecta caídas reales, mide su duración y deja un historial limpio y fácil de leer — nada de un archivo saturado con una línea por cada ping.

Se instala en minutos con un asistente, sobrevive a reinicios de Windows y funciona de forma genérica en cualquier equipo. Opcionalmente, cada PC envía sus registros a un servidor central donde un formulario web grafica la semana y muestra **si varias estaciones se cayeron al mismo tiempo**.

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

## 🚀 Características

| | |
|---|---|
| 🎯 **Múltiples destinos** | Cada IP o dominio lleva su propio estado, intervalo y umbral de confirmación. |
| 📉 **Registro inteligente** | Solo se escribe en el CSV cuando algo cambia — no cada ping. |
| 🌐 **Detección de red local** | Cambios de adaptador (Wi-Fi / cable), IP o interfaz quedan registrados como eventos. |
| 🖥️ **Consola en vivo** | Estado actual, historial del día y estado de las cargas FTP y API, con colores. |
| ☁️ **Respaldo por FTP** | Sube el historial a una carpeta con el alias de la PC, sin bloquear el monitoreo. |
| 🗄️ **API de análisis (opcional)** | Replica los registros a MySQL, sin duplicados, cada 3 horas. |
| 📊 **Análisis semanal web** | Gráfico por máquina y destino, coincidencias entre PC, filtro Cable/Wi-Fi y reporte HTML descargable. |
| 🔁 **Resiliente** | Un fallo en la consola, el FTP o la API nunca detiene el monitor. |
| ⚙️ **Arranque automático** | Se inicia con Windows mediante tareas programadas, sin sesión abierta. |

## 🧱 Arquitectura

```text
Monitor_Red.ps1 ──► CSV (logs\) ──► Cargador_FTP.ps1 ──► Servidor FTP
       │                 │                  └──► logs\cargados\
       │                 ├──► Cargador_DB.ps1 [opcional] ──► API (registros.php) ──► MySQL
       │                 │                                                              │
       │                 │                                    index.php: análisis semanal + HTML descargable
       │                 └──────────────────► Monitor_Red_Console.ps1
       └──► status.json ────────────────────► Monitor_Red_Console.ps1
```

| Componente | Dónde | Función |
|---|---|---|
| **Monitor** | PC · `Monitor_Red.ps1` | Hace ping, detecta cambios, escribe el CSV y `status.json` |
| **Consola** | PC · `Monitor_Red_Console.ps1` | Estado en tiempo real (solo lectura) |
| **Cargador FTP** | PC · `Cargador_FTP.ps1` | Sube el historial y archiva lo ya enviado |
| **Cargador API** | PC · `Cargador_DB.ps1` | Envía las filas del CSV a la API de análisis (opcional) |
| **Instaladores** | PC · `Instalar_*.bat` / `.ps1` | Configuran cada componente como tarea programada |
| **API + BD** | Servidor · `backend/api/registros.php` | Recibe filas y hace upsert en MySQL |
| **Análisis semanal** | Servidor · `backend/api/index.php` | Formulario y gráfico de caídas, reporte HTML |

## 🖥️ Uso

**Consola** — doble clic en `Abrir_Consola.bat` o en el acceso directo del escritorio:

```text
MONITOR DE RED MR V1.10   ·   LABORATORIO 2 - EDIFICIO A     PC-01 · Profesor1 · Wi-Fi 192.168.1.103
Sesión desde 07:00:00 (05:35:10)

DESTINO 1: 8.8.8.8      ESTADO: OK  desde 12:33:10 (00:02:00)
  Latencia: 24 ms (prom. 27 ms)   Última respuesta: 12:35:10
  Hoy: OK 05:30:00 · ERROR 00:03:20 · 3 caídas

CARGAS AL SERVIDOR
  FTP  OK   Última carga: 10:28:58 (hace 02:06:12)   Próxima: 12:28:58 (en breve)
  DB   OK   Última carga: 09:30:02 (hace 03:05:08)   Próxima: 12:30:02 (en breve)
```

Cerrar la consola **no** detiene el monitoreo.

**Análisis semanal** — en `https://mrv1.solucionesnicaragua.com/`: elige la semana, los días (lunes a viernes por defecto), el horario (07:00–15:00 por defecto) y las máquinas, y pulsa **Generar gráfico**.

- Verde tenue = conectado · rojo = sin conexión · blanco = sin datos · azul = eventos e inicios.
- **Franja naranja** = 2 o más máquinas caídas a la vez: indica un problema de la red común, no de una estación.
- Botones **Cable / Wi-Fi** (Wi-Fi oculto por defecto) para no mezclar caídas de señal inalámbrica.
- **Descargar HTML** genera un archivo autocontenido para compartir por correo, con los mismos botones.

## 📁 Estructura

**Repositorio**

```text
MRV1\
    Instalar_Monitor.bat, Desinstalar_Monitor.bat, Abrir_Consola.bat
    README.md, LICENSE
    sistema\          Scripts del monitor, cargadores, instaladores y la guía MRV1.10.md
    backend\          API + base de datos + formulario de análisis (se sube al hosting;
                      ningún instalador la copia a las PC)
```

**Instalación en cada PC**

```text
C:\ProgramData\MRV1\
    bin\              Monitor_Red.ps1, Monitor_Red_Console.ps1, Cargador_FTP.ps1, Cargador_DB.ps1
    config\           monitor.json, ftp.json, db_api.json, version.json
    logs\             CSV activos: [PC] [IP] [FECHA].csv
        cargados\     CSV de días anteriores ya subidos por FTP
    diag\             monitor.log, ftp_worker.log, db_worker.log
    status.json, ftp_status.json, db_status.json
```

## 📊 Formato del historial (CSV)

```text
FECHA;HORA;TIPO;TIEMPO (s);LATENCIA (ms);MENSAJE
2026-09-20;07:00:00;INICIO;0;0;LABORATORIO-PC - Profesor1 - Ethernet - 192.168.2.13 - MR V1.10
2026-09-20;07:00:05;OK;252;32;Conectividad disponible [Success]
2026-09-20;07:04:17;ERROR;45;0;Destino no responde [TimedOut]
```

Un archivo por destino y por día, delimitado por `;`, listo para Excel, PowerShell o Python.

## 🛠️ Requisitos

- Windows con PowerShell 5.1 (incluido de fábrica); permisos de administrador solo al instalar.
- FTP (opcional) para el respaldo remoto.
- Para el análisis web (opcional): hosting con PHP 8.3+, `pdo_mysql` y MySQL/MariaDB.

## 📄 Documentación técnica

- [`sistema/MRV1.10.md`](./sistema/MRV1.10.md) — guía maestra: arquitectura, decisiones de diseño, criterios de aceptación.
- [`backend/IA.md`](./backend/IA.md) y [`backend/README.md`](./backend/README.md) — servidor: base de datos, API y formulario de análisis.

## 🗺️ Estado actual (MRV1.10)

- ✅ Monitor, consola, cargador FTP y cargador API en producción.
- ✅ API y base de datos en `mrv1.solucionesnicaragua.com`.
- ✅ Formulario de análisis semanal con coincidencias, filtro Cable/Wi-Fi y reporte HTML.
- ⏳ Clave de acceso al formulario en producción y prueba con varias PC reales a la vez.

## 📝 Licencia

Distribuido bajo licencia [MIT](LICENSE). © 2026 Bismarck Sevilla.
