ANÁLISIS FUNCIONAL – Worker.mq4 / Worker.mq5 (V2)
===================================================

Objetivo
--------
- EA "worker" que ejecuta eventos OPEN/CLOSE/MODIFY en la cuenta local a partir de un archivo de cola.
- Usa el comentario de la orden como ticket maestro para identificar y evitar duplicados.
- Escribe histórico de ejecución y envía notificaciones push directas con `SendNotification()`.
- **Nota**: El Worker recibe símbolos ya mapeados del Distribuidor.py; no realiza mapeos de símbolos, solo ejecuta órdenes lo más rápido posible.

Entradas / Parámetros (Inputs)
------------------------------
- `Fondeo` (bool): 
  - Si `true`: el lote worker = lote maestro × `LotMultiplier`.
  - Si `false`: el lote worker se calcula con `LotFromCapital()` basado en `AccountBalance()` (compounding por bloques: +0.01 por cada 1000€ de capital).
- `LotMultiplier` (double): solo se aplica cuando `Fondeo=true`.
- `FixedLots` (double): **Ya no se usa** (mantenido por compatibilidad, pero ignorado cuando `Fondeo=false`).
- `Slippage` (int, pips).
- `MagicNumber` (int, recomendado configurable; 0 si no se define otro).
- `TimerSeconds` (int, recomendado 1s).

- Archivos y rutas
-----------------
- Carpeta base: `C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files\V2\Phoenix`
  - Se asume que ya existe; el EA no crea carpetas.
- `worker_id`: `AccountNumber()`.
- Entrada: `cola_WORKER_<worker_id>.txt`.
- Histórico: `historico_WORKER_<worker_id>.txt` (UTF-8).
- Formato de línea (entrada): `event_type;ticket;order_type;lots;symbol;sl;tp;contract_size`
  - `event_type`: OPEN | CLOSE | MODIFY (case-insensitive).
  - `order_type`: BUY | SELL.
  - `lots`: lote origen (double).
  - `symbol`: string.
  - `sl`/`tp`: pueden venir vacíos -> tratar como 0.
  - `contract_size`: tamaño de contrato en el origen (double). Si no viene, se asume 0 y no se escala.
- Formato de histórico (salida), una línea por intento:
  `timestamp_ejecucion;resultado;event_type;ticket;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit`
  - OPEN: rellenar `open_price`, `open_time`; `close_*` y `profit` vacíos.
  - CLOSE: rellenar `close_price`, `close_time`, `profit`; `open_*` vacíos.
  - MODIFY: rellenar `sl`/`tp` nuevos; precios/tiempos pueden quedar vacíos si no aplican. En el histórico se detalla `SL=` y `TP=` en el resultado.

Gestión de símbolos
-------------------
- **El símbolo viene ya mapeado del Distribuidor.py**: El Distribuidor aplica los mapeos específicos por worker antes de escribir en la cola (ej: `XAUUSD-STD` → `GOLD` para un worker específico).
- El Worker solo realiza normalización básica de formato:
  - Eliminar espacios (trim)
  - Convertir a mayúsculas (upper)
- El símbolo recibido en la cola es el que se usa directamente para operar:
  - `SymbolSelect(symbol, true)` usa el símbolo tal como viene de la cola
  - Operaciones (OrderSend/Close/Modify) usan el símbolo sin transformaciones adicionales
- **Ventaja**: Los Workers son más rápidos al no procesar lógica de mapeo; toda la lógica de mapeo está centralizada en el Distribuidor.

**Flujo completo de símbolos:**
```
1. LectorOrdenes.mq4 → Escribe símbolo original: "XAUUSD-STD"
   ↓
2. Distribuidor.py → Lee "XAUUSD-STD" y mapea según worker:
   - Worker 3037589: "XAUUSD-STD" → "GOLD"
   - Worker 71617942: "XAUUSD-STD" → "XAUUSD"
   ↓
3. Workers → Reciben símbolo ya mapeado y ejecutan directamente:
   - Worker 3037589 ejecuta con "GOLD"
   - Worker 71617942 ejecuta con "XAUUSD"
```

Inicialización (OnInit)
-----------------------
1) Construir ruta base Common\Files + `V2\Phoenix` y crear carpeta si falta.
2) `worker_id = AccountNumber()`.
3) Definir rutas de entrada/salida según `worker_id`.
4) `EventSetTimer(TimerSeconds)`.

Bucle principal (OnTimer)
-------------------------
1) Abrir `cola_WORKER_<id>.txt` en Common\Files (UTF-8). Si no existe o vacío, salir del ciclo.
2) Leer líneas completas; ignorar vacías.
3) Parsear por `;` en el orden: event_type, ticket, order_type, lots, symbol, sl, tp.
4) Para cada evento:
   - Normalizar `event_type` (OPEN/CLOSE/MODIFY) y `order_type` (BUY/SELL) a mayúsculas.
   - Normalizar `symbol` básicamente: eliminar espacios y convertir a mayúsculas (el símbolo ya viene mapeado del Distribuidor).
   - **Calcular `lots_worker` SOLO para eventos OPEN**:
     - Si `Fondeo=true`: 
       - `lots_worker = lots * LotMultiplier` (sin normalización por contract size).
     - Si `Fondeo=false`: 
       - `capital = AccountBalance()` (balance actual de la cuenta).
       - `lots_worker = LotFromCapital(capital, symbol)`.
       - `LotFromCapital()` calcula el lote según "compounding por bloques":
         - Bloques = `floor(capital / 1000.0)` (miles completos de capital).
         - Lote base = `blocks * 0.01` (mínimo 0.01 si blocks < 1).
         - Ajusta automáticamente a MIN/MAX/STEP del broker.
         - El lote del maestro (`lots`) y `contract_size` se ignoran completamente.
   - `comment` = ticket maestro (string).
   - OPEN:
     - Asegurar símbolo en MarketWatch (`SymbolSelect(symbol, true)`).
     - Calcular `lots_worker` usando `ComputeWorkerLots()`.
     - Precio: `Ask` si BUY, `Bid` si SELL.
     - `OrderSend(OP_BUY/OP_SELL, lots_worker, price, Slippage, sl, tp, comment, MagicNumber)` sobre el símbolo recibido.
     - Si éxito: histórico `resultado=EXITOSO`, set `open_price`, `open_time=TimeCurrent()`, `sl`, `tp`.
     - Si fallo: histórico `resultado=ERROR: <código/texto>`, **no se reintenta** (se elimina de la cola).
   - CLOSE:
     - **Buscar orden/posición abierta SOLO por `OrderComment()==ticket`** (el ticket origen es la clave única).
     - **NO se verifica el símbolo** para encontrar la posición (el símbolo puede diferir entre OPEN y CLOSE).
     - **NO se requiere `SymbolSelect()`** antes de cerrar.
     - Si no existe: histórico `resultado=No existe operacion abierta`; eliminar línea.
     - Si existe:
       - Orden contraria (BUY→SELL, SELL→BUY) por el mismo volumen; precio Bid/Ask.
       - `OrderClose` con `Slippage`, `MagicNumber`.
       - Si éxito: histórico `resultado=CLOSE OK`, `close_price`, `close_time`, `profit=OrderProfit()`.
       - Si fallo: histórico `resultado=ERROR: ...`, mantener línea para reintento.
  - MODIFY:
     - **Buscar posición abierta SOLO por `OrderComment()==ticket`** (el ticket origen es la clave única).
     - **NO se verifica el símbolo** para encontrar la posición.
     - **NO se requiere `SymbolSelect()`** antes de modificar.
     - Si no existe: histórico `resultado=No existe operacion abierta`; eliminar línea.
     - Si existe: `OrderModify` con nuevos `sl`/`tp` (0 si no vienen).
       - Si éxito: histórico `resultado=MODIFY OK SL=<...> TP=<...>` (sl/tp nuevos).
       - Si fallo: histórico `resultado=ERROR: MODIFY SL=<...> TP=<...>`, mantener línea para reintento.
5) Reescritura de la cola:
   - Reescribir el archivo de entrada solo con las líneas que FALLARON **en CLOSE/MODIFY**.
   - Eliminar de la cola:
     - EXITOSO (cualquier tipo)
     - No existe operacion abierta
     - OPEN con error (no se reintenta)
6) Notificaciones push:
   - Usar `SendNotification()` directo.
   - Sin notificación de inicio.
   - Prefijo obligatorio en todos los mensajes: `W: <AccountNumber()> - ...`
   - OPEN: notificar siempre éxito y siempre fallo (sin deduplicación).
   - CLOSE: notificar éxito siempre; notificar fallo solo la primera vez por ticket (set de control).
   - MODIFY: notificar éxito siempre; notificar fallo solo la primera vez por ticket (set de control).
   - Mensajes breves: tipo, símbolo, ticket, resultado, lote/sl/tp según aplique.

Manejo de errores / supuestos
-----------------------------
- Sin lógica de reconexión de red: MQL4 opera dentro del terminal.
- Si fallo de parseo: se puede registrar en histórico como `ERROR PARSE` y descartar la línea.
- Si el archivo no existe o está vacío: no hace nada en el ciclo.
- Se asume UTF-8 sin BOM; si hay BOM, se ignora al inicio.

Cálculo de lotaje cuando NO es cuenta de fondeo (`Fondeo=false`)
----------------------------------------------------------------
Cuando `Fondeo=false`, el Worker usa la función `LotFromCapital()` que implementa un sistema de "compounding por bloques" basado en el capital disponible:

**Proceso de cálculo:**
1. **Obtener capital**: `capital = AccountBalance()` (balance actual de la cuenta).
2. **Calcular bloques**: `blocks = floor(capital / 1000.0)` (miles completos de capital).
   - Mínimo: si `blocks < 1`, se establece `blocks = 1` (garantiza mínimo 0.01 lots).
3. **Lote base**: `lot_base = blocks * 0.01` (+0.01 lots por cada 1000€ de capital).
4. **Leer restricciones del broker**:
   - `minLot = MarketInfo(symbol, MODE_MINLOT)`
   - `maxLot = MarketInfo(symbol, MODE_MAXLOT)`
   - `stepLot = MarketInfo(symbol, MODE_LOTSTEP)`
   - Si algún valor es ≤ 0, usa valores por defecto (min=0.01, max=100, step=0.01).
5. **Ajuste a límites**: Clamp a min/max del broker.
6. **Ajuste al step**: Redondea hacia abajo al step válido más cercano.
7. **Normalización**: Redondea a 2 decimales y re-valida límites.

**Características importantes:**
- **Ignora completamente** el lote del maestro (`lots`) y el `contract_size` del origen.
- **Solo depende del capital** disponible en el momento de ejecutar la orden.
- **Compounding automático**: A medida que crece el capital, el tamaño de lote aumenta proporcionalmente.
- **Respeta límites del broker**: Ajusta automáticamente a MIN/MAX/STEP del símbolo destino.

**Ejemplo práctico:**
- Capital: 3500€ → blocks = 3 → lote = 0.03
- Capital: 7500€ → blocks = 7 → lote = 0.07
- Capital: 500€ → blocks = 1 → lote = 0.01 (mínimo)

Búsqueda de posiciones/órdenes abiertas
---------------------------------------
- **CLAVE ÚNICA**: El ticket origen (guardado en `OrderComment()` o `PositionComment()`) es la única clave para identificar operaciones.
- **NO se verifica el símbolo** al buscar posiciones en CLOSE/MODIFY porque:
  - El símbolo puede cambiar entre OPEN y CLOSE (por mapeos diferentes, cambios de configuración, etc.).
  - El ticket origen es único e inmutable, garantizando la identificación correcta.
- **OPEN**: Requiere el símbolo para `SymbolSelect()` y `OrderSend()`/`PositionOpen()`.
- **CLOSE/MODIFY**: Solo requieren el ticket; no necesitan `SymbolSelect()` ni verificación de símbolo.

Decisiones abiertas (si se requieren ajustes)
---------------------------------------------
- Valor por defecto de `MagicNumber` (propuesto: 0 o input).
- `TimerSeconds` (propuesto: 1).
- Alcance de notificaciones (solo éxito/fallo inmediato vs. solo fallos). Propuesto: ambos.***

