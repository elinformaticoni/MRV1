-- =====================================================================
-- Monitor de Red — Backend de análisis (MRV1 → MySQL)
-- 001_crear_base.sql
--
-- Crea las tablas `computadoras` y `registros` descritas en backend/IA.md
-- (sección 4, decisiones D5 y D6). Ejecutar una sola vez contra la base
-- de datos del hosting (phpMyAdmin, o `mysql -u usuario -p nombre_bd < 001_crear_base.sql`).
--
-- No borra ni modifica nada existente: usa CREATE TABLE IF NOT EXISTS,
-- así se puede volver a ejecutar sin riesgo.
-- =====================================================================

SET NAMES utf8mb4;
SET time_zone = '-06:00'; -- America/Managua

-- ---------------------------------------------------------------------
-- computadoras
-- Un registro por PC. `alias` se autoregistra solo desde Cargador_DB.ps1
-- en cada envío (D6/D9 de IA.md) — no requiere carga manual.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS computadoras (
  pc             VARCHAR(100) NOT NULL,
  alias          VARCHAR(150) NULL,
  creado_en      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  actualizado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (pc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- registros
-- Un registro por fila de CSV enviada. La clave única (registro_unico)
-- es la clave de sincronización D5 de IA.md: permite reenviar el CSV del
-- día en curso completo en cada carga sin duplicar filas — una fila que
-- se abre (tiempo/latencia en blanco) y luego se cierra (completa) se
-- actualiza sola vía INSERT ... ON DUPLICATE KEY UPDATE.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS registros (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
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
  PRIMARY KEY (id),
  UNIQUE KEY registro_unico (pc, destino, fecha, hora, tipo, mensaje(190)),
  KEY idx_pc_fecha (pc, fecha),
  KEY idx_fecha (fecha),
  CONSTRAINT fk_registros_pc FOREIGN KEY (pc) REFERENCES computadoras(pc)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
