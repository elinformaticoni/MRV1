-- =====================================================================
-- MRV1 - 004: eliminar las filas duplicadas "[INCOMPLETO]"
-- ---------------------------------------------------------------------
-- Hasta la 1.13.11, al arrancar tras un apagado abrupto el monitor añadía " [INCOMPLETO]" al mensaje de la
-- fila OK/ERROR que había quedado abierta. Como el mensaje forma parte de la clave única de `registros`
-- (pc, destino, fecha, hora, tipo, mensaje), la carga creaba una fila NUEVA y dejaba la original: dos filas
-- para el mismo estado, sin información adicional en la copia marcada.
-- Desde la 1.13.12 el monitor cierra esa fila con su duración real (hasta el último latido) y no cambia su
-- mensaje, así que ya no se generan.
--
-- Este script borra solo las copias "[INCOMPLETO]" que tienen su fila original (mismo pc, destino, fecha,
-- hora y tipo, con el mensaje sin el sufijo). Las "[INCOMPLETO]" sin original NO se tocan.
-- Es idempotente: se puede ejecutar más de una vez.
--
-- Para ver antes cuántas se borrarían, ejecute solo esta consulta:
--   SELECT COUNT(*) FROM registros r2 JOIN registros r1
--     ON r1.pc = r2.pc AND r1.destino = r2.destino AND r1.fecha = r2.fecha AND r1.hora = r2.hora AND r1.tipo = r2.tipo
--    WHERE r2.mensaje = CONCAT(r1.mensaje, ' [INCOMPLETO]');
-- =====================================================================
DELETE r2
  FROM registros r2
  JOIN registros r1
    ON r1.pc = r2.pc AND r1.destino = r2.destino AND r1.fecha = r2.fecha AND r1.hora = r2.hora AND r1.tipo = r2.tipo
 WHERE r2.mensaje = CONCAT(r1.mensaje, ' [INCOMPLETO]');
