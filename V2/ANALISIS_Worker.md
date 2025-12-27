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
- `Fondeo` (bool): si true, el lote worker = lote maestro × `LotMultiplier`.
- `LotMultiplier` (double): solo se aplica cuando `Fondeo=true`.
- `FixedLots` (double): usado cuando `Fondeo=false`; se ajusta a min/max/step del símbolo.
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
- Calcular `lots_worker` (con escalado por contract size):
     - `cs_dest = MarketInfo(symbol, MODE_TRADECONTRACTSIZE)` (si ≤0 usar 1.0).
     - Si la línea trae `contract_size` (>0), `ratio = cs_origin / cs_dest`, si no, ratio=1.
     - Base lote:
         - Si `Fondeo=true`: `base = lots * LotMultiplier`.
         - Si `Fondeo=false`: `base = FixedLots`.
     - `lots_worker = AdjustFixedLots(symbol, base * ratio)` respetando min/max/step del destino.
   - `comment` = ticket maestro (string).
   - OPEN:
     - Asegurar símbolo en MarketWatch (`SymbolSelect(symbol, true)`).
     - Precio: `Ask` si BUY, `Bid` si SELL.
     - `OrderSend(OP_BUY/OP_SELL, lots_worker, price, Slippage, sl, tp, comment, MagicNumber)` sobre el símbolo recibido.
     - Si éxito: histórico `resultado=EXITOSO`, set `open_price`, `open_time=TimeCurrent()`, `sl`, `tp`.
     - Si fallo: histórico `resultado=ERROR: <código/texto>`, **no se reintenta** (se elimina de la cola).
   - CLOSE:
     - Buscar orden/posición abierta con `OrderComment()==ticket` y símbolo coincide (usando el símbolo recibido).
     - Si no existe: histórico `resultado=No existe operacion abierta`; eliminar línea.
     - Si existe:
       - Orden contraria (BUY→SELL, SELL→BUY) por el mismo volumen; precio Bid/Ask.
       - `OrderClose` con `Slippage`, `MagicNumber`.
       - Si éxito: histórico `resultado=CLOSE OK`, `close_price`, `close_time`, `profit=OrderProfit()`.
       - Si fallo: histórico `resultado=ERROR: ...`, mantener línea para reintento.
  - MODIFY:
     - Buscar posición abierta (mismo criterio, símbolo recibido).
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

Decisiones abiertas (si se requieren ajustes)
---------------------------------------------
- Valor por defecto de `MagicNumber` (propuesto: 0 o input).
- `TimerSeconds` (propuesto: 1).
- Alcance de notificaciones (solo éxito/fallo inmediato vs. solo fallos). Propuesto: ambos.***

