# 📡 MRV1 — Monitor de Red 

**Herramienta de monitoreo continuo de conectividad para Windows, con historial en CSV, consola en vivo y respaldo automático por FTP.**

[![Versión](https://img.shields.io/badge/versión-MRV1.6-blue)](#)
[![Plataforma](https://img.shields.io/badge/plataforma-Windows-0078D6?logo=windows)](#)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](#)
[![Licencia](https://img.shields.io/badge/licencia-MIT-green)](LICENSE)

---

## ✨ ¿Qué es MR?

MR vigila la conectividad de uno o más destinos (IP o dominio) las 24 horas, sin intervención humana. Detecta caídas reales, mide su duración, y deja un historial limpio y fácil de leer — nada de un archivo saturado con una línea por cada ping.

Pensado para instalarse en minutos con un asistente gráfico, sobrevivir a reinicios de Windows, y funcionar de forma totalmente genérica en cualquier equipo.

## 📦 Instalación

1. [⬇️ Descarga o clona este repositorio](https://github.com/elinformaticoni/MRV1/archive/refs/heads/main.zip)
3. Ejecuta **`Instalar_Monitor.bat`** como administrador.
4. Indica el destino a monitorear (IP o dominio), el intervalo de ping y, si quieres, destinos adicionales.
5. Al finalizar, la consola se abre automáticamente y te preguntará si deseas configurar también el respaldo por FTP (`Instalar_FTP.bat`).

Con eso el sistema queda instalado en `C:\ProgramData\MRV1`, corriendo como tarea programada desde el arranque de Windows.

```powershell
git clone https://github.com/elinformaticoni/MRV1.git
cd MRV1
.\Instalar_Monitor.bat
```

> Para desinstalar en cualquier momento: `Desinstalar_Monitor.bat` y `Desinstalar_FTP.bat`. Los registros históricos nunca se borran.


## 🚀 Características

| | |
|---|---|
| 🎯 **Múltiples destinos** | Cada IP o dominio monitoreado lleva su propio estado, intervalo y umbral de confirmación. |
| 📉 **Registro inteligente** | Solo se escribe en el CSV cuando algo cambia — no cada ping. |
| 🌐 **Detección de red local** | Cambios de adaptador, IP o estado de interfaz quedan registrados como eventos. |
| 🖥️ **Consola en vivo** | Ventana de solo lectura que muestra el estado actual y el historial del día, con colores. |
| ☁️ **Respaldo por FTP** | Sube el historial automáticamente cada cierto tiempo, sin bloquear el monitoreo. |
| 🧩 **Instalación genérica** | Nada de IPs o rutas fijas en el código: todo se configura al instalar. |
| 🔁 **Resiliente** | Un fallo en la consola o el FTP nunca detiene el monitor. |
| ⚙️ **Arranque automático** | Se inicia con Windows mediante tareas programadas, sin sesión abierta. |

## 🧱 Arquitectura

```text
Monitor_Red.ps1 ──► CSV (logs\) ──► Cargador_FTP.ps1 ──► Servidor FTP
       │                 │                  └──► logs\cargados\
       │                 └──────────────────► Monitor_Red_Console.ps1
       └──► status.json ────────────────────► Monitor_Red_Console.ps1
```

| Componente | Archivo | Función |
|---|---|---|
| **Monitor** | `Monitor_Red.ps1` | Hace ping, detecta cambios y escribe el CSV y `status.json` |
| **Consola** | `Monitor_Red_Console.ps1` | Muestra el estado en tiempo real (solo lectura) |
| **Cargador FTP** | `Cargador_FTP.ps1` | Sube el historial al servidor y archiva lo ya enviado |
| **Instaladores** | `Instalar_*.bat` / `.ps1` | Configuran e instalan cada componente como tarea programada |


## 🖥️ Uso

Abre la consola cuando quieras revisar el estado actual — con doble clic en **`Abrir_Consola.bat`** o en el acceso directo que se crea en el escritorio:

```text
MONITOR DE RED MR V1.0        PC-01 · Profesor1 · Wi-Fi 192.168.1.103        Actualizado 22:35:10
Sesión desde 07:00:00 (15:35:10)

DESTINO 1: 8.8.8.8      ESTADO: OK  desde 22:33:10 (00:02:00)
  Latencia: 24 ms (prom. 27 ms)   Última respuesta: 22:35:10
  Hoy: OK 04:10:00 · ERROR 00:03:20 · 3 caídas

TODOS LOS CAMBIOS DE HOY
22:34:01  192.168.1.1  ERROR   Destino no responde [TimedOut]
22:33:10  8.8.8.8      OK      Conectividad restaurada [Success]
```

Cerrar la consola **no** detiene el monitoreo: sigue corriendo en segundo plano.

## 📁 Estructura de instalación

```text
C:\ProgramData\MRV1\
    bin\              Monitor_Red.ps1, Monitor_Red_Console.ps1, Cargador_FTP.ps1
    config\           monitor.json, ftp.json, version.json
    logs\             CSV activos: [PC] [IP] [FECHA].csv
        cargados\     CSV de días anteriores ya subidos por FTP
    diag\             Registros técnicos (monitor.log, ftp_worker.log)
    status.json       Estado instantáneo del monitor
```

## 📊 Formato del historial (CSV)

```text
FECHA;HORA;TIPO;TIEMPO (s);LATENCIA (ms);MENSAJE
2026-09-20;22:00:00;INICIO;0;0;LABORATORIO-PC - Profesor1 - LAN2 - 192.168.2.13 - MR V1.0
2026-09-20;22:00:05;OK;252;32;Conectividad disponible [Success]
2026-09-20;22:04:17;ERROR;45;0;Destino no responde [TimedOut]
```

Un archivo por destino y por día, delimitado por `;`, listo para abrir en Excel, PowerShell o Python.

## 🛠️ Requisitos

- Windows con PowerShell 5.1 (incluido de fábrica).
- Permisos de administrador solo durante la instalación.
- Acceso a un servidor FTP si se desea el respaldo remoto (opcional).

## 📄 Documentación técnica

La guía completa del proyecto — arquitectura, decisiones de diseño e historial de versiones — está en [`MRV1.6.md`](./MRV1.6.md).

## 📝 Licencia

Distribuido bajo licencia [MIT](LICENSE). © 2026 Bismarck Sevilla.
