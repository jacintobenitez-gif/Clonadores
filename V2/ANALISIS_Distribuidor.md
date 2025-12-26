# Funcional — Distribuidor.py (Master → colas de Workers)

## 1. Propósito

**Distribuidor.py** es un servicio que actúa como “central de reparto” entre un **maestro** que escribe eventos de trading en un fichero compartido y múltiples **Workers** que consumen esos eventos desde sus propias colas.

Su misión es:

* **Detectar eventos nuevos** generados por el maestro.
* **Validar** que cada evento está completo y es interpretable.
* **Distribuir** el evento a **todas** las colas de los Workers.
* **Eliminar del fichero maestro** los eventos ya distribuidos para evitar crecimiento ilimitado.

---

## 2. Entradas y salidas

### 2.1 Entrada (origen)

El origen es un fichero único:

* **Nombre**: `Master.txt`
* **Ubicación**: `Common\Files`
* **Estructura**: cada evento está representado por **una línea**
* **Regla de “commit”**: una línea es un evento válido **solo si termina con salto de línea (`\n`)**
* **Cabecera**: puede existir una primera línea que actúa como cabecera y **no se debe procesar**
* **Campos por evento**: **7 u 8 campos**, separados por `;`, en el siguiente orden:

`event_type;ticket;order_type;lots;symbol;sl;tp[;contract_size]`

---

### 2.2 Salidas (destinos)

Por cada Worker existe una cola dedicada:

* **Formato**: ficheros TXT (UTF-8)
* **Naming**: `cola_WORKER_XX.txt` (una por cada Worker configurado)
* **Regla**: cada evento se escribe en una única línea con salto de línea al final (sin concatenar eventos).
* **Finalidad**: cada Worker lee **solo su propia cola** y ejecuta lo que corresponda.

---

## 3. Comportamiento general

Distribuidor.py se ejecuta como un servicio continuo (24/7) y repite el siguiente ciclo:

1. **Revisa si hay eventos nuevos** en Master.txt
2. **Identifica y extrae únicamente los eventos no procesados**
3. **Ignora la cabecera** (si existe)
4. **Valida cada evento** antes de distribuirlo
5. **Distribuye cada evento válido a todas las colas** (una línea por evento por cola)
6. **Recorta Master.txt** eliminando los eventos que ya fueron distribuidos
7. **Registra actividad y anomalías** (para trazabilidad)

---

## 4. Reglas funcionales de lectura y selección

### 4.1 Lectura incremental

* Distribuidor.py **no reprocesa eventos antiguos**.
* Solo trabaja con los eventos “nuevos” desde el último punto de procesamiento conocido.

### 4.2 Líneas completas (commit)

* Una línea solo se considera candidata si está **completa**, lo que significa:

  * termina en `\n`
* Si una línea está “a medio escribir” (sin `\n`), Distribuidor.py:

  * **no la procesa**
  * la deja para el siguiente ciclo, cuando ya esté completa

### 4.3 Cabecera

* Si existe cabecera, Distribuidor.py:

  * **la ignora**
  * nunca la distribuye a ningún Worker

---

## 5. Reglas funcionales de validación

Un evento se considera **válido** si cumple:

1. Es una línea completa (termina en `\n`)
2. No es la cabecera
3. Contiene **7 u 8 campos** separados por `;`
4. Los campos se interpretan en el orden definido:

   * `event_type`
   * `ticket`
   * `order_type`
   * `lots`
   * `symbol`
   * `sl`
   * `tp`
   * `contract_size` (opcional; si existe, es el tamaño de contrato del origen)

### 5.1 Eventos inválidos

Si una línea no cumple lo anterior:

* No se distribuye
* Se registra como inválida para diagnóstico
* El servicio continúa sin bloquearse

---

## 6. Reglas funcionales de distribución (fan-out)

### 6.1 Distribución a todas las colas

* Cada evento válido se copia **a todas** las colas `cola_WORKER_XX.csv`.
* Se mantiene la regla “1 evento = 1 línea” también en cada cola.

### 6.2 Consistencia de reparto

* El objetivo funcional es que un evento válido:

  * **llegue a cada Worker** a través de su cola
  * manteniendo el mismo contenido de evento

---

## 7. Reglas funcionales de recorte del fichero maestro

### 7.1 Objetivo del recorte

Tras distribuir eventos, Distribuidor.py realiza una limpieza del origen:

* Elimina del `Master.txt` los eventos que ya han sido distribuidos a las colas.
* Esto previene crecimiento infinito del fichero y facilita operación estable.

### 7.2 Condición para recortar

* Solo se recorta aquello que se considera **ya distribuido**.
* Nunca se recorta una línea incompleta.
* El recorte respeta el límite de “commit”: siempre a fin de línea.

---

## 8. Registro y trazabilidad (logging funcional)

Distribuidor.py deja trazabilidad operativa de:

* inicio del servicio
* detección de nuevos eventos
* número de eventos leídos
* número de eventos distribuidos
* número de líneas inválidas y motivo general
* ejecución de recortes (cuánto se recorta)
* tiempo empleado en el ciclo de distribución + recorte (ms)
* errores durante reparto (sin detener el servicio)

---

## 9. Resultado esperado

Con Distribuidor.py funcionando:

* `Master.txt` actúa como un “log de eventos” simple y robusto.
* Cada Worker recibe los eventos por su **cola dedicada**.
* El origen se mantiene controlado en tamaño mediante recorte.
* El sistema resiste escrituras parciales, formatos incorrectos y cabeceras sin romperse.

---

## 10. Configuración (externa y hot-reload)

### 10.1 Fichero de configuración (txt)

* **Nombre**: `distribuidor_config.txt`
* **Ubicación**: misma carpeta donde reside `Distribuidor.py`
* **Formato**: fichero plano `clave=valor`, una clave por línea. Líneas vacías o que empiezan por `#` se ignoran.
* **Campos**:
  * `common_files_dir`: ruta a `Common\Files`. Si está vacío se usa la ruta por defecto de MetaTrader.
  * `master_filename`: nombre del fichero maestro (por defecto `Master.txt`).
  * `worker_id`: se puede repetir una línea por cada worker, p.ej. tres líneas `worker_id=01`, `worker_id=02`, `worker_id=03` significan 3 workers. (Compatibilidad: si existe `worker_ids` con comas se usa, pero la forma preferida es una línea por worker).
  * `poll_seconds`: intervalo de sondeo en segundos, p.ej. `1.0`.
  * `reload_minutes`: intervalo en minutos para recargar la configuración en caliente (por defecto 15).

### 10.2 Variables de entorno (prioridad máxima)

* `COMMON_FILES_DIR`: sobrescribe `common_files_dir`.
* `MASTER_FILENAME`: sobrescribe `master_filename`.
* `WORKER_IDS`: sobrescribe `worker_ids` con formato `01,02,03`.
* `POLL_SECONDS`: sobrescribe `poll_seconds`.
* `CONFIG_RELOAD_MINUTES`: sobrescribe `reload_minutes`.

### 10.3 Orden de prioridad

1. Variables de entorno
2. Fichero `distribuidor_config.txt`
3. Valores por defecto

### 10.4 Hot-reload

* El servicio recarga la configuración cada `reload_minutes` (por defecto 15 minutos).
* Permite modificar `distribuidor_config.txt` (añadir/quitar workers) o las variables de entorno sin reiniciar.

