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

* Cada evento válido se copia **a todas** las colas `cola_WORKER_XX.txt`.
* Se mantiene la regla "1 evento = 1 línea" también en cada cola.

### 6.2 Mapeo de símbolos por worker

* Antes de escribir en cada cola, Distribuidor.py aplica **mapeos de símbolos** específicos por worker.
* Los mapeos se configuran en `distribuidor_config.txt` con el formato:
  ```
  worker_id=<id>|<symbol_origen>=<symbol_destino>|<symbol_origen2>=<symbol_destino2>
  ```
* Ejemplo:
  ```
  worker_id=3037589|xaudusd-std=GOLD
  worker_id=71617942|xaudusd-std=XAUUSD
  ```
* **Proceso de mapeo**:
  1. Se lee el símbolo del evento (campo 4: `symbol`)
  2. Se consulta si existe mapeo para ese worker y símbolo
  3. Si existe mapeo, se reemplaza el símbolo original por el mapeado
  4. Si no existe mapeo, se mantiene el símbolo original
* Los símbolos se normalizan a **mayúsculas** para comparación (case-insensitive).
* **Ventaja**: Permite que diferentes brokers/workers usen nombres de símbolos distintos (ej: `XAUUSD-STD` → `GOLD` para un broker específico).

### 6.3 Consistencia de reparto

* El objetivo funcional es que un evento válido:

  * **llegue a cada Worker** a través de su cola
  * con el símbolo **mapeado según la configuración** de ese worker
  * manteniendo el resto del contenido del evento sin cambios

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

Distribuidor.py mantiene dos archivos históricos separados para trazabilidad:

### 8.1 Historico_Master.txt

* **Ubicación**: `Common\Files\Historico_Master.txt`
* **Contenido**: Líneas de eventos distribuidos con timestamp
* **Formato**: `event_type;ticket;order_type;lots;symbol;sl;tp;timestamp`
* **Ejemplo**:
  ```
  OPEN;123;BUY;0.1;XAUUSD-STD;0;0;2025.01.15 14:30:25.123
  CLOSE;456;SELL;0.2;EURUSD;1.0850;1.0900;2025.01.15 14:30:26.456
  ```
* **Relación**: 1 evento = 1 línea
* **Propósito**: Registro de eventos distribuidos (tabla de eventos para Salesforce)

### 8.2 historico_clonacion.txt

* **Ubicación**: `Common\Files\historico_clonacion.txt`
* **Contenido**: Resultados de clonación por worker (una línea por worker por evento)
* **Formato**: `ticket;worker_id;resultado;timestamp`
* **Ejemplo**:
  ```
  123;71617942;OK;2025.01.15 14:30:25.123
  123;511029358;OK;2025.01.15 14:30:25.123
  123;3037589;NOK;2025.01.15 14:30:25.123
  ```
* **Relación**: 1 evento = N líneas (una por cada worker configurado)
* **Propósito**: Registro de resultados de clonación por worker (tabla de clonaciones para Salesforce)
* **Relación 1 a N**: Cada evento en `Historico_Master.txt` tiene múltiples entradas en `historico_clonacion.txt` (una por worker)

### 8.3 Campos de resultado

* `OK`: El evento se escribió correctamente en la cola del worker
* `NOK`: Falló la escritura en la cola (el evento se guardó en `pendientes_worker_XX.txt`)

### 8.4 Timestamp de clonación

* Formato: `YYYY.MM.DD HH:MM:SS.mmm` (milisegundos)
* Todos los eventos distribuidos en el mismo ciclo comparten el mismo timestamp
* Permite correlacionar eventos entre ambos archivos históricos mediante `ticket` + `timestamp`

### 8.5 Trazabilidad operativa adicional

Distribuidor.py también registra en consola:

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
  * `worker_id`: se puede repetir una línea por cada worker. Dos formatos soportados:
    * **Sin mapeos**: `worker_id=71617942` (solo ID del worker)
    * **Con mapeos**: `worker_id=71617942|xaudusd-std=XAUUSD|eurusd-std=EURUSD` (ID + mapeos de símbolos separados por `|`)
    * Cada mapeo tiene formato `symbol_origen=symbol_destino`
    * Se pueden definir múltiples mapeos por worker separados por `|`
    * Los símbolos se normalizan automáticamente a mayúsculas
    * Ejemplo completo:
      ```
      worker_id=3037589|xaudusd-std=GOLD
      worker_id=71617942|xaudusd-std=XAUUSD|eurusd-std=EURUSD
      worker_id=511029358
      ```
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

