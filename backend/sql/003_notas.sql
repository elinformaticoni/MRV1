-- =====================================================================
-- MRV1 - 003: bitácora de notas manuales sobre la línea de tiempo
-- ---------------------------------------------------------------------
-- Una nota = un texto breve en una fecha y hora para UNA computadora
-- (ej. "Desconecté el switch del lab", "Cambié el cable para prueba").
-- Si se anota para varias PC a la vez, se guarda una fila por PC.
-- Se crea desde el formulario de análisis (index.php) y se dibuja como
-- bandera sobre la línea de tiempo de esa PC.
-- Es idempotente: se puede ejecutar más de una vez. Sin esta tabla el
-- formulario funciona igual, pero avisa que falta y no permite anotar.
-- =====================================================================
CREATE TABLE IF NOT EXISTS notas (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  pc             VARCHAR(100) NOT NULL,
  fecha          DATE NOT NULL,
  hora           TIME NOT NULL,
  texto          VARCHAR(300) NOT NULL,
  creado_en      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  actualizado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_notas_pc_fecha (pc, fecha),
  KEY idx_notas_fecha (fecha)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
