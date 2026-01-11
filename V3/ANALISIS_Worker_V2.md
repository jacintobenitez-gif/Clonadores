# ANÁLISIS FUNCIONAL – Worker.mq4 V2

## 1. OBJETIVO

Rediseño completo del Worker.mq4 para usar una única estructura en memoria (`OpenLogInfo`) que refleje la realidad de las operaciones abiertas en MetaTrader 4. Eliminación de redundancias y simplificación del código manteniendo toda la funcionalidad esencial.

---

## 2. ESTRUCTURA ÚNICA EN MEMORIA

### 2.1. Estructura `OpenLogInfo`

```mql5
struct OpenLogInfo
{
   int ticketMaster;         // MagicNumber (int) - identificador del maestro
   int ticketWorker;         // Ticket de la orden en MT4
   int magicNumber;          // MagicNumber (para verificación/visualización)
   
   // Campos de la orden abierta
   string symbol;
   int orderType;            // OP_BUY o OP_SELL
   double lots;
   double openPrice;
   datetime openTime;
   double sl;                // Stop Loss actual
   double tp;                // Take Profit actual
};
```

**Observaciones:**
- `ticketMaster` es `int` (MagicNumber), no string
- `profit` NO se guarda en la estructura (se calcula al cerrar)
- No hay campo `isTemporary` (si OPEN falla, simplemente no se guarda)

### 2.2. Array global en memoria

```mql5
OpenLogInfo g_openLogs[];     // Array dinámico para guardar operaciones abiertas
int g_openLogsCount = 0;      // Contador de operaciones guardadas
```

**Características:**
- Sin límite máximo (array dinámico)
- Se sincroniza con la realidad de MT4 al iniciar
- Se actualiza en tiempo real con cada evento

---

## 3. CARGA INICIAL EN `OnInit()`

### 3.1. Proceso de carga

1. **Recorrer todas las órdenes abiertas** (`OrdersTotal()`)
2. **Para cada orden** (TODAS las órdenes abiertas):
   - Obtener `ticketWorker` = `OrderTicket()`
   - Obtener `magicNumber` = `OrderMagicNumber()`
   - `ticketMaster` = `magicNumber`
   - **Nota:** No habrá órdenes manuales, todas tienen MagicNumber asignado
   - Obtener resto de campos de la orden:
     - `symbol` = `OrderSymbol()`
     - `orderType` = `OrderType()`
     - `lots` = `OrderLots()`
     - `openPrice` = `OrderOpenPrice()`
     - `openTime` = `OrderOpenTime()`
     - `sl` = `OrderStopLoss()`
     - `tp` = `OrderTakeProfit()`
   - Guardar en `g_openLogs[]`
3. **Mostrar en pantalla** todas las operaciones cargadas

### 3.2. Visualización inicial

Formato: `TM: ticketMaster || TW: ticketWorker || MN: magicNumber`

Ejemplo:
```
=== POSICIONES EN MEMORIA ===
TM: 12345 || TW: 67890 || MN: 12345
TM: 12346 || TW: 67891 || MN: 12346
TM: 0 || TW: 67892 || MN: 0
Total: 3 posiciones
```

**Características:**
- Color: **rojo** (`clrRed`)
- Actualización: tiempo real
- Se muestra en el gráfico usando objetos gráficos (`OBJ_LABEL`)

---

## 4. PROCESAMIENTO DE EVENTOS

### 4.1. OPEN

#### 4.1.1. Proceso completo

1. **Parser lee línea del archivo:**
   ```
   OPEN;ticketMaster;orderType;lots;symbol;sl;tp
   ```

2. **Calcular lotaje del worker:**
   - Usar función `ComputeWorkerLots(symbol, lots)` que:
     - Si `InpFondeo = true`: `lots * InpLotMultiplier`
     - Si `InpFondeo = false`: `LotFromCapital(AccountBalance(), symbol)`

3. **Ejecutar `OrderSend()`:**
   ```mql5
   int type = (orderType=="BUY" ? OP_BUY : OP_SELL);
   double price = (type==OP_BUY ? Ask : Bid);
   string commentStr = IntegerToString(ticketMaster);  // Comment = ticketMaster como string
   int ticketNew = OrderSend(symbol, type, lotsWorker, price, InpSlippage, sl, tp, commentStr, ticketMaster, 0, clrNONE);
   ```

4. **Si OPEN es exitoso (`ticketNew > 0`):**
   - Obtener `ticketWorker` = `ticketNew`
   - Seleccionar orden: `OrderSelect(ticketWorker, SELECT_BY_TICKET)`
   - Obtener `openPrice` = `OrderOpenPrice()`
   - Obtener `openTime` = `OrderOpenTime()`
   - **Crear entrada en `g_openLogs[]`** con todos los campos:
     - `ticketMaster` = valor del archivo
     - `ticketWorker` = ticket obtenido
     - `magicNumber` = `ticketMaster`
     - `symbol`, `orderType`, `lots`, `sl`, `tp` = valores del archivo
     - `openPrice`, `openTime` = valores de la orden
   - Actualizar visualización en gráfico
   - Escribir en histórico: formato actual + `ticketWorker` + "EXITOSO"

5. **Si OPEN falla (`ticketNew < 0`):**
   - Obtener código de error: `GetLastError()`
   - Obtener descripción: `ErrorText(errorCode)`
   - **Enviar notificación push:** `Notify("Ticket: [ticketMaster] - ERROR: OPEN (código) descripción")`
   - **Escribir en histórico:** formato actual + `ticketWorker` = 0 + "ERROR: OPEN (código) descripción"
   - **NO crear entrada en `g_openLogs[]`**
   - **NO reintentar** (continuar con siguiente línea)

#### 4.1.2. Validaciones previas

**a) Verificar que el símbolo existe:**
- Ejecutar `SymbolSelect(symbol, true)`
- Si falla:
  - Obtener código de error: `GetLastError()`
  - Obtener descripción: `ErrorText(errorCode)`
  - **Enviar notificación push:** `Notify("Ticket: [ticketMaster] - OPEN FALLO: SymbolSelect (código) descripción")`
  - **Escribir en histórico:** formato actual + `ticketWorker` = 0 + mensaje de error completo
  - **NO crear entrada en `g_openLogs[]`**
  - **NO reintentar** (continuar con siguiente línea)

**b) Verificar que no existe ya una orden abierta:**
- Buscar en `g_openLogs[]` por `ticketMaster`
- Si existe:
  - **NO enviar notificación push** (no es un error crítico, solo información)
  - **Escribir en histórico:** formato actual + `ticketWorker` = valor de memoria + "Ya existe operacion abierta"
  - **NO crear nueva entrada** (ya existe)
  - **NO reintentar** (continuar con siguiente línea)

---

### 4.2. MODIFY

#### 4.2.1. Proceso completo

1. **Parser lee línea del archivo:**
   ```
   MODIFY;ticketMaster;sl;tp
   ```

2. **Buscar en `g_openLogs[]` por `ticketMaster`:**
   - Función `FindOpenLog(int ticketMaster)` retorna índice o -1

3. **Si encontrado en memoria:**
   - Obtener `ticketWorker` = `g_openLogs[index].ticketWorker`
   - **Verificar si `ticketWorker` sigue en operaciones abiertas:**
     - Intentar seleccionar orden: `OrderSelect(ticketWorker, SELECT_BY_TICKET)`
     - Si NO se puede seleccionar (orden cerrada):
       - Eliminar entrada de `g_openLogs[]` (ya no está abierta)
       - Actualizar visualización
       - Escribir en histórico: formato actual + `ticketWorker` + "MODIFY fallido: Orden ya cerrada"
       - **NO reintentar** (la orden ya no existe)
     - Si SÍ se puede seleccionar (orden sigue abierta):
       - Ejecutar `OrderModify(ticketWorker, sl, tp)`

4. **Si MODIFY es exitoso:**
   - Actualizar `sl` y `tp` en `g_openLogs[index]`
   - Actualizar visualización en gráfico
   - Escribir en histórico: formato actual + `ticketWorker` + "MODIFY OK SL=X TP=Y"
   - Eliminar de lista de notificaciones de fallos

5. **Si MODIFY falla (error de MT4):**
   - Obtener código y descripción del error de MT4
   - Escribir en histórico: formato actual + `ticketWorker` + mensaje de error de MT4
   - Mantener en memoria para reintento
   - Añadir a lista de notificaciones de fallos (evitar spam)

6. **Si NO encontrado en memoria:**
   - Escribir en histórico: formato actual + `ticketWorker` = 0 + "MODIFY fallido. No se encontro: [ticketMaster]"
   - **NO reintentar** (la orden no existe en memoria)

**Reglas de reintento para MODIFY:**
- **SÍ se reintenta:** Si `OrderModify()` retorna `false` (error de MT4) Y la orden sigue abierta
- **NO se reintenta:** Si la orden ya está cerrada (no se puede seleccionar por ticketWorker)
- **NO se reintenta:** Si la orden no se encuentra en memoria

**Observaciones:**
- Debe existir en `open_logs` normalmente (solo se modifica lo abierto)
- Si no existe, verificar historial antes de error
- Si la orden se cerró mientras había MODIFY pendiente, detectar y parar reintentos

---

### 4.3. CLOSE

#### 4.3.1. Proceso completo

1. **Parser lee línea del archivo:**
   ```
   CLOSE;ticketMaster
   ```

2. **Buscar en `g_openLogs[]` por `ticketMaster`:**
   - Función `FindOpenLog(int ticketMaster)` retorna índice o -1

3. **Si encontrado en memoria:**
   - Obtener `ticketWorker` = `g_openLogs[index].ticketWorker`
   - Seleccionar orden: `OrderSelect(ticketWorker, SELECT_BY_TICKET)`
   - Obtener `profit` = `OrderProfit()`
   - Obtener `volume` = `OrderLots()`
   - Obtener precio de cierre según tipo de orden:
     - Si `OP_BUY`: `closePrice` = `Bid`
     - Si `OP_SELL`: `closePrice` = `Ask`
   - Ejecutar `OrderClose(ticketWorker, volume, closePrice, InpSlippage, clrNONE)`

4. **Si CLOSE es exitoso:**
   - **Eliminar entrada de `g_openLogs[]` inmediatamente**
   - Actualizar visualización en gráfico
   - Escribir en histórico: formato actual + `ticketWorker` + `profit` + "CLOSE OK"
   - Eliminar de lista de notificaciones de fallos

5. **Si CLOSE falla:**
   - Obtener código y descripción del error de MT4
   - **Verificar si la orden ya no existe** (pasó al historial por cierre manual):
     - Buscar en historial por `ticketMaster` (MagicNumber)
     - Si está en historial:
       - Escribir en histórico: formato actual + `ticketWorker` + "CLOSE fallido: Orden ya cerrada"
       - Eliminar entrada de `g_openLogs[]` (ya no está abierta)
       - Actualizar visualización
       - **NO reintentar** (la orden ya no existe)
     - Si NO está en historial:
       - Escribir en histórico: formato actual + `ticketWorker` + mensaje de error de MT4
       - Mantener en memoria para reintento
       - Añadir a lista de notificaciones de fallos (evitar spam)

6. **Si NO encontrado en memoria:**
   - Verificar si está en historial (ya cerrada):
     - Buscar en historial por `ticketMaster` (MagicNumber)
   - Si está en historial:
     - Escribir en histórico: formato actual + `ticketWorker` = 0 + "Orden ya estaba cerrada"
     - **NO reintentar** (la orden ya está cerrada)
   - Si no está en historial:
     - Escribir en histórico: formato actual + `ticketWorker` = 0 + "Close fallido. No se encontro: [ticketMaster]"
     - **NO reintentar** (la orden no existe)

**Reglas de reintento para CLOSE:**
- **SÍ se reintenta:** Si `OrderClose()` retorna `false` (error de MT4) Y la orden sigue existiendo
- **NO se reintenta:** Si la orden ya está cerrada (encontrada en historial)
- **NO se reintenta:** Si la orden no se encuentra en memoria ni en historial

**Observaciones:**
- Eliminación inmediata de memoria tras CLOSE exitoso
- Si no existe en memoria, verificar historial antes de decidir si reintentar

---

## 5. HISTÓRICO: `historico_WORKER_{workerid}.csv`

### 5.1. Formato actualizado

**Header:**
```
worker_exec_time;worker_read_time;resultado;event_type;ticketMaster;ticketWorker;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit
```

**Cambios respecto al formato actual:**
- Añadida columna `ticketWorker` después de `ticketMaster`
- Mantener resto de columnas igual

### 5.2. Valores por tipo de evento

#### OPEN exitoso:
- `ticketMaster` = valor del archivo
- `ticketWorker` = ticket obtenido de `OrderSend()`
- `resultado` = "EXITOSO"
- Resto de campos según orden abierta

#### OPEN fallido:
- `ticketMaster` = valor del archivo
- `ticketWorker` = 0 o -1
- `resultado` = "ERROR: OPEN (código) descripción"
- Resto de campos vacíos o con valores del intento

#### MODIFY:
- `ticketMaster` = valor del archivo
- `ticketWorker` = valor de memoria
- `resultado` = "MODIFY OK SL=X TP=Y" o mensaje de error
- Resto de campos según orden modificada

#### CLOSE:
- `ticketMaster` = valor del archivo
- `ticketWorker` = valor de memoria
- `resultado` = "CLOSE OK" o mensaje de error
- `profit` = profit de la orden cerrada
- Resto de campos según orden cerrada

---

## 6. FUNCIONES A MANTENER

### 6.1. Inputs (parámetros de entrada)

```mql5
input bool   InpFondeo        = false;
input double InpLotMultiplier = 1.0;
input double InpFixedLots     = 0.10;
input int    InpSlippage      = 30;     // pips
input int    InpMagicNumber   = 0;
input int    InpTimerSeconds  = 1;
```

**Todos los inputs se mantienen igual.**

### 6.2. Funciones de cálculo de lotaje

#### `LotFromCapital(double capital, string symbol)`
- Calcula lotaje según "compounding por bloques"
- +0.01 por cada 1000€ de capital
- Ajustado a MIN/MAX/STEP del símbolo
- **Se mantiene igual**

#### `ComputeWorkerLots(string symbol, double masterLots)`
- Si `InpFondeo = true`: `masterLots * InpLotMultiplier`
- Si `InpFondeo = false`: `LotFromCapital(AccountBalance(), symbol)`
- **Se mantiene igual**

### 6.3. Gestión de codificación UTF-8

#### Funciones de conversión UTF-8:
- `UTF8BytesToString(uchar &bytes[], int startPos, int length)`
- `StringToUTF8Bytes(string str, uchar &bytes[])`
- **Se mantienen igual**

#### Función `ReadQueue()`:
- Lee archivo con codificación UTF-8
- Maneja BOM UTF-8
- Convierte bytes UTF-8 a strings
- **Se mantiene igual**

### 6.4. Gestión de archivos

#### Funciones de archivo:
- `FileOpen()` - apertura de archivos
- `FileRead()` / `FileReadString()` - lectura
- `FileWrite()` - escritura
- `FileClose()` - cierre
- `FileSeek()` - posicionamiento
- `FileIsExist()` - verificación de existencia
- **Todas se mantienen igual**

#### Gestión de histórico:
- `EnsureHistoryHeader()` - crear header si no existe
- `AppendHistory()` - añadir línea al histórico
- **Se mantienen igual** (solo se actualiza para incluir `ticketWorker`)

### 6.5. Funciones de utilidad

#### Manejo de errores:
- `ErrorText(int code)` - descripción de errores de MT4
- `FormatLastError(string prefix)` - formatear último error
- **Se mantienen igual**

#### Notificaciones push:
- `Notify(string msg)` - enviar notificación push vía `SendNotification()` de MT4
- Arrays de control de spam:
  - `g_notifCloseTickets[]` - tickets de CLOSE que ya se notificaron (evitar spam)
  - `g_notifModifyTickets[]` - tickets de MODIFY que ya se notificaron (evitar spam)
- Funciones auxiliares: `TicketInArray()`, `AddTicket()`, `RemoveTicket()`
- **Se mantienen igual**

#### Utilidades de arrays:
- `TicketInArray()`, `AddTicket()`, `RemoveTicket()`
- **Se mantienen igual**

#### Otras utilidades:
- `Trim()`, `Upper()`, `GetTimestampWithMillis()`
- `CommonRelative()`, `EnsureBaseFolder()`
- `FindOpenOrder()` - buscar orden por MagicNumber/Comment
- `FindOrderInHistory()` - buscar en historial
- **Se mantienen igual**

### 6.6. Manejo de reintentos

**Reglas de reintento:**

- **OPEN:** NO se reintenta
  - Si falla (error de SymbolSelect, OrderSend, etc.), se escribe en histórico y se descarta
  - No se añade a `remaining[]`

- **MODIFY:** Reintento condicional
  - **SÍ se reintenta:** Si `OrderModify()` retorna `false` (error de MT4) Y la orden sigue abierta
    - Se añade a `remaining[]` para reintento
    - Se mantiene en memoria para siguiente intento
    - Se reintenta indefinidamente hasta que la operación tenga éxito
  - **NO se reintenta:** Si la orden ya está cerrada (no se puede seleccionar por ticketWorker)
    - Se elimina de memoria
    - Se escribe en histórico "MODIFY fallido: Orden ya cerrada"
  - **NO se reintenta:** Si la orden no se encuentra en memoria
    - Se escribe error y NO se reintenta

- **CLOSE:** Reintento condicional
  - **SÍ se reintenta:** Si `OrderClose()` retorna `false` (error de MT4) Y la orden sigue existiendo
    - Se añade a `remaining[]` para reintento
    - Se mantiene en memoria para siguiente intento
    - Se reintenta indefinidamente hasta que la operación tenga éxito
  - **NO se reintenta:** Si la orden ya está cerrada (encontrada en historial)
    - Se elimina de memoria
    - Se escribe en histórico "CLOSE fallido: Orden ya cerrada"
  - **NO se reintenta:** Si la orden no se encuentra en memoria
    - Se busca en historial
    - Si está en historial: escribir "Orden ya estaba cerrada" y NO reintentar
    - Si no está: escribir "Close fallido. No se encontro: [ticketMaster]" y NO reintentar

- **Líneas inválidas:** NO aplica normalmente
  - El origen siempre envía información completa y correcta
  - No existen líneas con formato incorrecto desde el origen
  - Si el parser falla, sería por problemas técnicos (archivo corrupto, lectura incompleta) que son casos excepcionales
  - Las validaciones se mantienen como protección

**Proceso:**
- Líneas que fallan y son reintentables se guardan en array `remaining[]`
- Al final del ciclo (`OnTimer()`), se escriben de vuelta al archivo de cola con `RewriteQueue()`
- En el siguiente ciclo (cada `InpTimerSeconds` segundos, normalmente 1 segundo), se vuelven a leer y procesar
- **No hay límite máximo de reintentos** - se reintenta indefinidamente hasta éxito o eliminación
- **Se mantiene igual que en versión actual**

### 6.7. Validación de datos al parsear

La función `ParseLine()` incluye validaciones para asegurar que los datos son correctos:

- **Validación de número de campos:**
  - Mínimo 2 campos requeridos (eventType, ticket)
  - OPEN requiere al menos 5 campos
  - MODIFY y CLOSE requieren mínimo 2 campos

- **Validación de campos requeridos:**
  - `eventType` no puede estar vacío
  - `ticket` no puede estar vacío
  - Para OPEN: `symbol` y `orderType` no pueden estar vacíos

- **Validación de formato:**
  - Conversión de tipos (string a int, string a double)
  - Normalización de decimales (reemplazar "," por ".")
  - Normalización de texto (trim, uppercase)

- **Todas estas validaciones se mantienen igual**

---

## 7. FUNCIONES NUEVAS NECESARIAS

### 7.1. Gestión de `OpenLogInfo`

#### `LoadOpenPositionsFromMT4()`
- Carga todas las órdenes abiertas al iniciar
- Llena `g_openLogs[]` con datos de MT4
- Llama a `DisplayOpenLogsInChart()` al final

#### `DisplayOpenLogsInChart()`
- Muestra todas las operaciones en memoria en el gráfico
- Formato: "TM: X || TW: Y || MN: Z"
- Color rojo (`clrRed`)
- Usa objetos gráficos (`OBJ_LABEL`)
- Se actualiza en tiempo real

#### `AddOpenLog(OpenLogInfo &log)`
- Añade nueva entrada a `g_openLogs[]`
- Redimensiona array dinámicamente si es necesario (`ArrayResize()`)
- Se llama después de OPEN exitoso
- Llama a `DisplayOpenLogsInChart()` al final

#### `UpdateOpenLog(int ticketMaster, double sl, double tp)`
- Actualiza `sl` y `tp` en `g_openLogs[]`
- Se llama después de MODIFY exitoso
- Llama a `DisplayOpenLogsInChart()` al final

#### `RemoveOpenLog(int ticketMaster)`
- Elimina entrada de `g_openLogs[]`
- Se llama después de CLOSE exitoso
- Llama a `DisplayOpenLogsInChart()` al final

#### `FindOpenLog(int ticketMaster)`
- Busca en `g_openLogs[]` por `ticketMaster`
- Retorna índice si encuentra, -1 si no encuentra

### 7.2. Parser actualizado

#### `ParseLine(string line, OpenLogInfo &log)`
- Reemplaza la función actual que retorna `EventRec`
- Retorna `OpenLogInfo` directamente
- **Mantiene todas las validaciones actuales:**
  - Verificar número mínimo de campos
  - Verificar campos requeridos no vacíos
  - Validar formato y conversión de tipos
- **Inicialización de campos:**
  - Todos los campos se inicializan a valores por defecto (0, "", etc.)
  - Solo se llenan los campos correspondientes al tipo de evento
- Para OPEN: parsea todos los campos (`ticketMaster`, `orderType`, `lots`, `symbol`, `sl`, `tp`)
- Para MODIFY: parsea solo `ticketMaster`, `sl`, `tp` (resto queda en valores por defecto)
- Para CLOSE: parsea solo `ticketMaster` (resto queda en valores por defecto)

---

## 8. FUNCIONES A ELIMINAR

### 8.1. Estructura `EventRec`
- **Eliminar completamente**
- Sustituida por `OpenLogInfo`

### 8.2. Persistencia en archivo (ya no necesaria)

#### Funciones a eliminar:
- `WriteOpenLogToFile()` - escribir mapeo a archivo
- `ReadOpenLogFromFile()` - leer mapeo de archivo
- `RemoveOpenLogFromFile()` - eliminar mapeo de archivo
- `GetOpenLogsFileName()` - obtener nombre de archivo

**Razón:** MT4 ya mantiene las órdenes abiertas, no necesitamos archivo de respaldo.

### 8.3. Funciones de verificación de OPEN (opcionales)

#### Funciones que podrían eliminarse si no se usan:
- `GetOpenLog()` - obtener información de OPEN (sustituida por `FindOpenLog()`)
- Funciones de verificación de OPEN (si no se necesitan)

---

## 9. FLUJO COMPLETO DEL EA

### 9.1. Inicialización (`OnInit()`)

1. Obtener `workerId` = `AccountNumber()`
2. Construir rutas de archivos:
   - `cola_WORKER_{workerId}.csv`
   - `historico_WORKER_{workerId}.csv`
3. Asegurar carpeta base (`EnsureBaseFolder()`)
4. Configurar timer (`EventSetTimer(InpTimerSeconds)`)
5. **Cargar posiciones abiertas** (`LoadOpenPositionsFromMT4()`)
6. Mostrar mensaje de inicialización

### 9.2. Bucle principal (`OnTimer()`)

1. Capturar `worker_read_time` (milisegundos)
2. Leer cola de eventos (`ReadQueue()`)
3. Detectar cabecera opcional (saltar si existe)
4. Para cada línea:
   - Parsear línea → `OpenLogInfo`
   - Según `eventType`:
     - **OPEN**: procesar OPEN
     - **MODIFY**: procesar MODIFY
     - **CLOSE**: procesar CLOSE
   - Si hay error y es reintentable: añadir a `remaining[]`
5. Escribir líneas restantes (reintentos) de vuelta al archivo

### 9.3. Finalización (`OnDeinit()`)

1. Eliminar timer (`EventKillTimer()`)
2. **Limpiar objetos gráficos de visualización:**
   - Eliminar todos los objetos `OBJ_LABEL` con nombre que empiece por "OpenLog_"
   - Esto incluye: título, líneas de posiciones, resumen

---

## 10. CASOS ESPECIALES Y MANEJO DE ERRORES

### 10.1. OPEN duplicado

- Verificar si ya existe orden con ese `ticketMaster` antes de ejecutar
- Buscar en `g_openLogs[]` por `ticketMaster`
- Si existe: escribir en histórico "Ya existe operacion abierta" y continuar (no ejecutar OPEN)

### 10.2. MODIFY sin orden abierta o orden cerrada

- Si no se encuentra en `g_openLogs[]`:
  - Verificar si está en historial (puede estar ya cerrada)
  - Si está en historial: escribir "MODIFY fallido: Orden ya cerrada" y **NO reintentar**
  - Si no está: escribir "No existe operacion abierta" y **NO reintentar**
- Si se encuentra pero `OrderModify()` falla:
  - **Verificar si la orden pasó al historial** (se cerró mientras había MODIFY pendiente)
  - Si está en historial: eliminar de memoria, escribir "MODIFY fallido: Orden ya cerrada" y **NO reintentar**
  - Si sigue existiendo: **SÍ reintentar** (error de MT4 que puede resolverse)

### 10.3. CLOSE sin orden abierta

- Si no se encuentra en `g_openLogs[]`:
  - Verificar historial (puede estar ya cerrada)
  - Si está en historial: escribir "Orden ya estaba cerrada" y **NO reintentar**
  - Si no está: escribir "Close fallido. No se encontro: [ticketMaster]" y **NO reintentar**
- Si se encuentra pero `OrderClose()` falla:
  - **Verificar si la orden pasó al historial** (se cerró manualmente mientras había CLOSE pendiente)
  - Si está en historial: eliminar de memoria, escribir "CLOSE fallido: Orden ya cerrada" y **NO reintentar**
  - Si sigue existiendo: **SÍ reintentar** (error de MT4 que puede resolverse)

### 10.4. Errores de MT4

- Capturar código y descripción con `GetLastError()` y `ErrorText()`
- Escribir en histórico con formato: "ERROR: OPERACION (código) descripción"
- Enviar notificación push
- **Reintentar solo si es error de MT4** (OrderModify/OrderClose retorna false)
- **NO reintentar si la orden no existe** (no encontrada en memoria ni historial)

### 10.5. Gestión de memoria

- Array dinámico sin límite máximo
- Se redimensiona automáticamente según necesidad con `ArrayResize()`

### 10.6. Órdenes cerradas mientras EA estaba apagado

**Escenario:** El EA estaba apagado, se cerró una orden manualmente, luego se enciende el EA.

**Proceso:**
1. Al iniciar el EA (`OnInit()`):
   - Se cargan TODAS las órdenes abiertas en memoria
   - Si la orden se cerró manualmente mientras el EA estaba apagado, **NO estará en la lista de órdenes abiertas**
   - Por lo tanto, **NO se cargará en memoria**

2. Cuando llega el CLOSE del Spool:
   - **No se encontrará en memoria** (porque no estaba abierta cuando se inició el EA)
   - Se buscará en historial
   - Si está en historial: escribir "Orden ya estaba cerrada" y **NO reintentar**
   - Si no está: escribir "Close fallido. No se encontro: [ticketMaster]" y **NO reintentar**

**Nota:** Este es el caso menos común. El caso más común es que la orden siga abierta cuando se enciende el EA, se carga en memoria, y el CLOSE la encuentra y la cierra normalmente.

---

## 11. RESUMEN DE CAMBIOS PRINCIPALES

### 11.1. Estructura única
- ✅ Una sola estructura `OpenLogInfo` en memoria
- ✅ Eliminada `EventRec`
- ✅ Sincronización con realidad de MT4

### 11.2. Carga inicial
- ✅ Cargar todas las órdenes abiertas al iniciar
- ✅ Sin filtro por MagicNumber
- ✅ Visualización inmediata

### 11.3. Procesamiento simplificado
- ✅ OPEN: crear en memoria solo si exitoso
- ✅ MODIFY: buscar en memoria, actualizar si exitoso
- ✅ CLOSE: buscar en memoria, eliminar si exitoso

### 11.4. Histórico actualizado
- ✅ Añadida columna `ticketWorker`
- ✅ Mantener formato actual

### 11.5. Eliminaciones
- ✅ Eliminada persistencia en archivo
- ✅ Eliminada estructura `EventRec`
- ✅ Simplificación general

### 11.6. Mantenido
- ✅ Todos los inputs
- ✅ Funciones de cálculo de lotaje (`LotFromCapital`, `ComputeWorkerLots`)
- ✅ Gestión UTF-8 (lectura/escritura con codificación UTF-8)
- ✅ Gestión de archivos (apertura, lectura, escritura, cierre)
- ✅ Notificaciones push (`Notify()` con `SendNotification()`)
- ✅ Control de spam de notificaciones (arrays `g_notifCloseTickets[]`, `g_notifModifyTickets[]`)
- ✅ Manejo de errores (`ErrorText()`, `FormatLastError()`)
- ✅ Manejo de reintentos (array `remaining[]`)
- ✅ Validaciones de datos al parsear (todas las validaciones actuales)

---

## 12. PREGUNTAS PENDIENTES

1. **Visualización en OPEN:** ¿Mostrar entrada temporal antes de ejecutar `OrderSend()` o solo después de éxito?
   - **Respuesta:** Solo después de éxito (no crear entrada si falla)

2. **Parser para MODIFY/CLOSE:** ¿Crear entrada temporal mínima o buscar directamente?
   - **Respuesta:** Buscar directamente en `g_openLogs[]` (debe existir siempre)

3. **Límite de memoria:** ¿Qué hacer si se alcanzan 100 operaciones?
   - **Respuesta:** No hay límite (array dinámico), se redimensiona automáticamente

---

## 13. IMPLEMENTACIÓN

### 13.1. Orden de implementación sugerido

1. Crear estructura `OpenLogInfo` simplificada
2. Crear función `LoadOpenPositionsFromMT4()`
3. Crear función `DisplayOpenLogsInChart()`
4. Actualizar `OnInit()` para cargar posiciones
5. Crear funciones de gestión: `AddOpenLog()`, `UpdateOpenLog()`, `RemoveOpenLog()`, `FindOpenLog()`
6. Actualizar parser `ParseLine()` para retornar `OpenLogInfo`
7. Actualizar procesamiento de OPEN
8. Actualizar procesamiento de MODIFY
9. Actualizar procesamiento de CLOSE
10. Actualizar `AppendHistory()` para incluir `ticketWorker`
11. Eliminar funciones de persistencia en archivo
12. Eliminar estructura `EventRec`
13. Pruebas y validación

### 13.2. Archivos afectados

- `V3/Worker.mq4` - archivo principal a modificar
- `V3/ANALISIS_Worker_V2.md` - este documento

---

**FIN DEL ANÁLISIS**

