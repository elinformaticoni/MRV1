-- MRV1.11 — Configuración remota: confirmación de recepción por PC.
--
-- Agrega a `computadoras` la revisión de configuración remota que cada PC
-- confirma haber aplicado y cuándo. Lo escribe zombie.php (POST accion=confirmar)
-- y lo lee el propio zombie.php para mostrar «Aplicada» / «Pendiente».
--
-- Seguro de reejecutar: cada columna solo se agrega si todavía no existe
-- (no depende de ADD COLUMN IF NOT EXISTS, que es solo de MariaDB).

SET @db := DATABASE();

SET @sql := IF(
  (SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = @db AND TABLE_NAME = 'computadoras' AND COLUMN_NAME = 'config_rev_aplicada') = 0,
  'ALTER TABLE computadoras ADD COLUMN config_rev_aplicada BIGINT UNSIGNED NULL',
  'SELECT 1'
);
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;

SET @sql := IF(
  (SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = @db AND TABLE_NAME = 'computadoras' AND COLUMN_NAME = 'config_aplicada_en') = 0,
  'ALTER TABLE computadoras ADD COLUMN config_aplicada_en DATETIME NULL',
  'SELECT 1'
);
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;
