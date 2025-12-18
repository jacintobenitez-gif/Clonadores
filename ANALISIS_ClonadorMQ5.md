# Análisis Funcional Detallado: ClonadorMQ5.py

## Resumen Funcional Detallado

### Propósito del Sistema

`ClonadorMQ5.py` es un sistema de **clonación automática de operaciones de trading** que actúa como puente entre una cuenta maestra (MT4) y una cuenta esclava (MT5). Su función principal es **sincronizar automáticamente** todas las operaciones de trading (aperturas, cierres y modificaciones de SL/TP) desde la cuenta maestra hacia la cuenta esclava, permitiendo operar en múltiples plataformas de forma simultánea y coordinada.

### Flujo de Negocio Completo

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. CUENTA MAESTRA (MT4)                                         │
│    - Trader ejecuta operaciones manualmente o mediante EA        │
│    - LectorOrdenes.mq4 detecta cambios cada 1 segundo           │
│    - Escribe eventos a TradeEvents.txt (UTF-8)                  │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. ARCHIVO COMPARTIDO (TradeEvents.txt)                        │
│    - Ubicación: COMMON\Files\TradeEvents.txt                    │
│    - Formato: event_type;ticket;order_type;lots;symbol;sl;tp   │
│    - Ejemplos:                                                  │
│      • OPEN;39924291;BUY;0.04;XAUUSD;4288.04;4290.00           │
│      • CLOSE;39924292;SELL;0.02;EURUSD;1.0850;1.0800           │
│      • MODIFY;39924291;BUY;0.04;XAUUSD;4290.00;4295.00         │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. CLONADORMQ5.PY (Python Script)                              │
│    - Lee TradeEvents.txt cada 1 segundo                         │
│    - Procesa cada evento según su tipo                          │
│    - Ejecuta operaciones en MT5                                 │
│    - Registra resultados en TradeEvents_historico.txt          │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. CUENTA ESCLAVA (MT5)                                        │
│    - Operaciones clonadas automáticamente                       │
│    - Mismo símbolo, dirección y SL/TP                          │
│    - Lotaje ajustado según configuración (multiplicador)       │
└─────────────────────────────────────────────────────────────────┘
```

### Tipos de Operaciones y su Comportamiento

#### 1. OPEN (Apertura de Posición)

**Propósito**: Abrir una nueva posición en MT5 basada en una operación del maestro.

**Flujo de Negocio**:
1. Llega un evento `OPEN` con los datos de la operación maestra
2. **Se ejecuta directamente** sin verificaciones previas (el ticket del origen es único)
3. Calcula el lotaje esclavo:
   - Si `CUENTA_FONDEO = True`: `lotaje_esclavo = lotaje_maestro × multiplicador` (1x, 2x o 3x)
   - Si `CUENTA_FONDEO = False`: Usa `FIXED_LOTS` ajustado a los límites del símbolo
4. Ejecuta la orden de mercado en MT5 (BUY o SELL)
5. **Resultado**:
   - **Éxito**: Elimina del CSV, registra "EXITOSO" en histórico
   - **Fallo**: Elimina del CSV, registra "ERROR: [mensaje del broker]" en histórico

**Características**:
- No hay reintentos (si falla, se registra el error y se elimina)
- El ticket maestro se guarda como comentario en MT5 para identificación
- Respeta los límites de volumen del símbolo (min, max, step)

---

#### 2. CLOSE (Cierre de Posición)

**Propósito**: Cerrar una posición abierta en MT5 cuando se cierra en el maestro.

**Flujo de Negocio**:
1. Llega un evento `CLOSE` con el ticket maestro
2. **Busca solo en posiciones abiertas** (no en historial)
3. Si encuentra la posición abierta:
   - Ejecuta orden contraria (BUY → SELL, SELL → BUY)
   - Cierra al precio de mercado actual
4. **Resultado**:
   - **Éxito**: Elimina del CSV, registra "CLOSE OK" en histórico
   - **No existe operación abierta**: Elimina del CSV, registra "No existe operacion abierta" en histórico
   - **Fallo (cualquier error)**: Mantiene en CSV para reintento, registra "ERROR: Fallo al cerrar (reintento)" en histórico

**Características**:
- **Reintentos automáticos**: Si falla (incluyendo errores de red), se mantiene en CSV y se reintenta en el siguiente ciclo hasta que se cierre exitosamente
- Solo busca en posiciones abiertas (no puede cerrar algo que ya está cerrado)
- Manejo especial de errores de red (10031) para garantizar el cierre

---

#### 3. MODIFY (Modificación de SL/TP)

**Propósito**: Actualizar los niveles de Stop Loss y Take Profit de una posición abierta en MT5 cuando se modifican en el maestro.

**Flujo de Negocio**:
1. Llega un evento `MODIFY` con el ticket maestro y nuevos valores de SL/TP
2. **Busca solo en posiciones abiertas** (no en historial)
3. Si encuentra la posición abierta:
   - Actualiza SL y TP con los nuevos valores
4. **Resultado**:
   - **Éxito**: Elimina del CSV, registra "MODIFY OK" en histórico
   - **No existe operación abierta**: Elimina del CSV, registra "No existe operacion abierta" en histórico
   - **Fallo (cualquier error)**: Mantiene en CSV para reintento, registra "ERROR: Fallo al modificar (reintento)" en histórico

**Características**:
- **Reintentos automáticos**: Si falla (incluyendo errores de red), se mantiene en CSV y se reintenta en el siguiente ciclo hasta que se actualice exitosamente o se cierre la operación
- Solo modifica posiciones abiertas (no puede modificar algo que ya está cerrado)
- `TRADE_RETCODE_NO_CHANGES` se considera éxito (mismo SL/TP)

---

### Gestión de Errores y Reintentos

#### Estrategia de Reintentos

| Operación | Éxito | No Existe | Error |
|-----------|-------|-----------|-------|
| **OPEN** | Elimina del CSV | N/A | Elimina del CSV (no reintenta) |
| **CLOSE** | Elimina del CSV | Elimina del CSV | **Mantiene en CSV** (reintenta) |
| **MODIFY** | Elimina del CSV | Elimina del CSV | **Mantiene en CSV** (reintenta) |

**Filosofía**:
- **OPEN**: No reintenta porque el ticket es único. Si falla, se registra el error y se elimina.
- **CLOSE/MODIFY**: Reintenta automáticamente porque son operaciones críticas que deben ejecutarse. Se mantienen en CSV hasta éxito o hasta que la operación se cierre.

#### Manejo de Errores de Red (10031)

- **Código**: `10031` = "Request rejected due to absence of network connection"
- **Comportamiento**: Se trata igual que cualquier otro error para CLOSE y MODIFY
- **Acción**: Mantener en CSV para reintento automático en el siguiente ciclo
- **Razón**: Errores de red son temporales y pueden resolverse automáticamente

---

### Configuración de Lotajes

#### Modo Fondeo (`CUENTA_FONDEO = True`)

- **Comportamiento**: Copia el lotaje del maestro aplicando un multiplicador
- **Multiplicadores disponibles**: 1x, 2x, 3x (configurado al inicio del script)
- **Ejemplo**: 
  - Maestro abre 0.04 lots con multiplicador 2x → Esclavo abre 0.08 lots
  - Maestro abre 0.10 lots con multiplicador 3x → Esclavo abre 0.30 lots

#### Modo Lote Fijo (`CUENTA_FONDEO = False`)

- **Comportamiento**: Usa un lote fijo (`FIXED_LOTS`) independientemente del lotaje maestro
- **Ajustes automáticos**: Respeta límites del símbolo (min, max, step)
- **Ejemplo**: 
  - `FIXED_LOTS = 0.10` → Siempre abre 0.10 lots (ajustado a step del símbolo)

---

### Registro y Trazabilidad

#### Archivo Histórico (`TradeEvents_historico.txt`)

**Propósito**: Registro completo de todas las ejecuciones para auditoría y depuración.

**Formato**:
```
timestamp_ejecucion;resultado;event_type;ticket;order_type;lots;symbol;sl;tp
```

**Ejemplos de Resultados**:
- `2025-12-16 08:03:01;EXITOSO;OPEN;39924291;BUY;0.04;XAUUSD;;;;;0.00`
- `2025-12-16 08:17:20;CLOSE OK;CLOSE;39924292;SELL;0.02;EURUSD;;;;;0.00`
- `2025-12-16 08:41:58;MODIFY OK;MODIFY;39924291;BUY;0.04;XAUUSD;;;;;0.00`
- `2025-12-16 09:15:33;ERROR: retcode=10004 comment=Invalid price;OPEN;39924293;BUY;0.05;GBPUSD;;;;;0.00`
- `2025-12-16 09:20:45;No existe operacion abierta;CLOSE;39924294;SELL;0.03;USDJPY;;;;;0.00`

**Casos Registrados**:
- ✅ Operaciones exitosas
- ❌ Errores del broker con mensaje descriptivo
- ⚠️ Operaciones omitidas (no existe operación abierta)
- 🔄 Reintentos (errores que se mantienen en CSV)

---

### Ventajas del Sistema

1. **Automatización Completa**: No requiere intervención manual para clonar operaciones
2. **Sincronización en Tiempo Real**: Lee cada 1 segundo, respuesta rápida a cambios
3. **Flexibilidad de Lotajes**: Permite multiplicar lotajes para estrategias de fondeo
4. **Robustez**: Manejo inteligente de errores con reintentos automáticos para operaciones críticas
5. **Trazabilidad**: Registro completo de todas las ejecuciones para auditoría
6. **Simplicidad**: Ejecuta directamente sin verificaciones innecesarias (OPEN)
7. **Persistencia**: Reintenta automáticamente operaciones críticas (CLOSE/MODIFY) hasta éxito

---

### Casos de Uso Típicos

#### Caso 1: Clonación Simple MT4 → MT5
- **Escenario**: Trader opera en MT4, quiere replicar operaciones en MT5
- **Configuración**: `CUENTA_FONDEO = True`, `LOT_MULTIPLIER = 1.0`
- **Resultado**: Operaciones idénticas en ambas plataformas

#### Caso 2: Fondeo con Multiplicador
- **Escenario**: Cuenta de fondeo que requiere multiplicar lotajes
- **Configuración**: `CUENTA_FONDEO = True`, `LOT_MULTIPLIER = 2.0` o `3.0`
- **Resultado**: Operaciones clonadas con el doble o triple del volumen maestro

#### Caso 3: Gestión de Errores de Red
- **Escenario**: Error de conexión al intentar cerrar una posición
- **Comportamiento**: Se mantiene en CSV y se reintenta automáticamente
- **Resultado**: La posición se cierra cuando se restablece la conexión

---

## Información General

- **Tipo**: Script Python 3
- **Propósito**: Clonar operaciones de trading desde un archivo compartido (`TradeEvents.txt`) hacia MetaTrader 5
- **Versión**: V3 (optimizada para leer en 1 segundo, sin lecturas al historial de MQL5)
- **Archivo de entrada**: `TradeEvents.txt` (en carpeta COMMON\Files)
- **Archivo de salida**: `TradeEvents_historico.txt` (registro de todas las ejecuciones)
- **Codificación**: UTF-8 exclusivamente

---

## Arquitectura General

### Flujo Principal

1. **Inicialización** (`main_loop()`)
   - Conecta a MT5
   - Si `CUENTA_FONDEO = True`: Solicita multiplicador de lotaje al usuario (1x, 2x, 3x)
   - Configura rutas de archivos

2. **Bucle Principal** (`main_loop()`)
   - Cada `TIMER_SECONDS` segundos (por defecto: 1 segundo)
   - Lee `TradeEvents.txt`
   - Procesa cada evento (OPEN, CLOSE, MODIFY)
   - Ejecuta operaciones en MT5
   - Actualiza archivos (CSV principal e histórico)

3. **Finalización**
   - Maneja `KeyboardInterrupt` (Ctrl+C)
   - Desconecta de MT5

---

## Componentes Principales

### 1. Configuración Global

```python
CSV_NAME = "TradeEvents.txt"              # Archivo de entrada
CSV_HISTORICO = "TradeEvents_historico.txt"  # Archivo histórico de salida
TIMER_SECONDS = 1                         # Intervalo de lectura (segundos)
SLIPPAGE_POINTS = 30                      # Slippage permitido en puntos
CUENTA_FONDEO = True                      # True = copia lots del maestro
FIXED_LOTS = 0.10                         # Lote fijo si NO es fondeo
MAGIC = 0                                 # Magic number para órdenes
LOT_MULTIPLIER = 1.0                      # Multiplicador de lotaje (configurado al inicio)
```

**Parámetros clave**:
- `CUENTA_FONDEO`: Determina si se copia el lotaje del maestro o se usa un lote fijo
- `LOT_MULTIPLIER`: Multiplicador aplicado al lotaje maestro (1x, 2x, 3x)
- `TIMER_SECONDS`: Frecuencia de lectura del archivo (1 segundo)

---

### 2. Estructura de Datos

#### `Ev` (Evento)
```python
@dataclass
class Ev:
    event_type: str      # "OPEN", "CLOSE", "MODIFY"
    master_ticket: str   # Ticket maestro (del sistema origen)
    order_type: str      # "BUY", "SELL"
    master_lots: float   # Volumen maestro
    symbol: str          # Símbolo del instrumento
    sl: float            # Stop Loss
    tp: float            # Take Profit
```

**Propósito**: Representar un evento de trading leído del archivo CSV.

**Campos**:
- `event_type`: Tipo de operación a ejecutar
- `master_ticket`: Identificador único del sistema origen (usado como comentario en MT5)
- `order_type`: Dirección de la operación
- `master_lots`: Volumen original del maestro
- `symbol`: Instrumento financiero
- `sl`, `tp`: Niveles de Stop Loss y Take Profit

---

### 3. Funciones de Utilidad

#### `upper(s: str) -> str`
**Propósito**: Normalizar strings a mayúsculas y eliminar espacios.

**Parámetros**:
- `s`: String a normalizar

**Retorno**: String en mayúsculas sin espacios iniciales/finales

**Uso**: Normalizar `event_type`, `order_type`, `symbol` del CSV.

---

#### `f(s: str) -> float`
**Propósito**: Convertir string a float, manejando comas y valores vacíos.

**Parámetros**:
- `s`: String a convertir

**Proceso**:
1. Elimina espacios
2. Reemplaza comas por puntos (formato europeo)
3. Retorna `0.0` si está vacío

**Retorno**: Float convertido o `0.0` si está vacío

**Uso**: Convertir `lots`, `sl`, `tp` del CSV.

---

#### `ensure_symbol(symbol: str)`
**Propósito**: Asegurar que un símbolo esté disponible en MT5.

**Parámetros**:
- `symbol`: Símbolo a seleccionar

**Proceso**:
1. Llama a `mt5.symbol_select(symbol, True)`
2. Si falla, lanza `RuntimeError` con el error de MT5

**Uso**: Antes de ejecutar operaciones, asegurar que el símbolo esté disponible.

---

#### `clone_comment(master_ticket: str) -> str`
**Propósito**: Generar el comentario para las órdenes clonadas.

**Parámetros**:
- `master_ticket`: Ticket maestro

**Retorno**: El mismo `master_ticket` (sin modificaciones)

**Razón**: Evitar truncamiento de comentarios en MT5. El comentario es simplemente el ticket maestro.

---

### 4. Funciones de Búsqueda en MT5

#### `find_open_clone(symbol: str, comment: str, master_ticket: str = None) -> Optional[Position]`
**Propósito**: Buscar una posición abierta por símbolo y comentario (ticket maestro).

**Parámetros**:
- `symbol`: Símbolo a buscar
- `comment`: Comentario (ticket maestro)
- `master_ticket`: Ticket maestro (alternativo)

**Proceso**:
1. Obtiene todas las posiciones abiertas del símbolo (`mt5.positions_get(symbol=symbol)`)
2. Compara el comentario de cada posición con el ticket maestro
3. Retorna la primera posición que coincida

**Retorno**: Objeto `Position` si existe, `None` si no existe

**Uso**: Verificar si una posición ya está abierta antes de ejecutar OPEN o para encontrar la posición a cerrar/modificar.

---

#### `find_ticket_in_history(symbol: str, master_ticket: str) -> bool`
**Propósito**: Buscar el ticket maestro en el historial de MT5 (deals y órdenes).

**Parámetros**:
- `symbol`: Símbolo a buscar
- `master_ticket`: Ticket maestro a buscar

**Proceso**:
1. Define rango de búsqueda: últimos 90 días
2. Busca en **deals** del historial:
   - Obtiene todos los deals con `mt5.history_deals_get(from_date, to_date)`
   - Compara símbolo y busca el ticket maestro en el comentario
3. Busca en **órdenes** del historial:
   - Obtiene todas las órdenes con `mt5.history_orders_get(from_date, to_date)`
   - Compara símbolo y busca el ticket maestro en el comentario

**Retorno**: `True` si encuentra el ticket en deals u órdenes, `False` si no

**Uso**: Verificar si una operación ya fue ejecutada anteriormente (aunque ya esté cerrada).

---

#### `ticket_exists_anywhere(symbol: str, master_ticket: str) -> bool`
**Propósito**: Verificar si el ticket maestro existe en posiciones abiertas O en historial.

**Parámetros**:
- `symbol`: Símbolo a verificar
- `master_ticket`: Ticket maestro a buscar

**Proceso**:
1. Busca en posiciones abiertas con `find_open_clone()`
2. Si no encuentra, busca en historial con `find_ticket_in_history()`

**Retorno**: `True` si existe en abiertas o historial, `False` si no existe en ningún lado

**Uso**: Verificación de existencia antes de ejecutar CLOSE y MODIFY (no se usa para OPEN, ya que el ticket del origen es único).

---

### 5. Funciones de Cálculo de Lotaje

#### `compute_slave_lots(symbol: str, master_lots: float) -> float`
**Propósito**: Calcular el volumen de la orden esclava basado en el volumen maestro.

**Parámetros**:
- `symbol`: Símbolo del instrumento
- `master_lots`: Volumen maestro

**Lógica**:

**Si `CUENTA_FONDEO = True`**:
```python
return float(master_lots) * LOT_MULTIPLIER
```
- Aplica multiplicador directamente al lotaje maestro
- No valida límites del símbolo (se asume que el multiplicador es razonable)

**Si `CUENTA_FONDEO = False`**:
1. Obtiene información del símbolo (`mt5.symbol_info(symbol)`)
2. Extrae límites:
   - `volume_min`: Volumen mínimo permitido
   - `volume_max`: Volumen máximo permitido
   - `volume_step`: Incremento mínimo de volumen
3. Aplica `FIXED_LOTS`:
   - Redondea al `volume_step` más cercano hacia abajo
   - Ajusta a `volume_min` si es menor
   - Ajusta a `volume_max` si es mayor
4. Normaliza decimales según `volume_step` (típicamente 2-4 decimales)

**Retorno**: Volumen calculado y validado

**Ejemplo**:
- `master_lots = 0.04`, `LOT_MULTIPLIER = 2.0` → `slave_lots = 0.08`
- `FIXED_LOTS = 0.10`, `volume_step = 0.01` → `slave_lots = 0.10`

---

### 6. Funciones de Ejecución de Operaciones

#### `open_clone(ev: Ev) -> tuple[bool, str]`
**Propósito**: Ejecutar operación OPEN (BUY/SELL) en MT5 directamente sin verificaciones previas.

**Parámetros**:
- `ev`: Evento con datos de la operación

**Proceso**:

1. **Preparación**:
   - Asegura que el símbolo esté disponible (`ensure_symbol()`)
   - Calcula lotaje esclavo (`compute_slave_lots()`)
   - Obtiene tick actual (`mt5.symbol_info_tick()`)

2. **Determinación de tipo y precio**:
   - `BUY` → `ORDER_TYPE_BUY`, precio = `tick.ask`
   - `SELL` → `ORDER_TYPE_SELL`, precio = `tick.bid`

3. **Construcción de request**:
   ```python
   req = {
       "action": mt5.TRADE_ACTION_DEAL,
       "symbol": ev.symbol,
       "volume": lots,
       "type": otype,
       "price": price,
       "sl": ev.sl if ev.sl > 0 else 0.0,
       "tp": ev.tp if ev.tp > 0 else 0.0,
       "deviation": SLIPPAGE_POINTS,
       "magic": MAGIC,
       "comment": comment,  # ticket maestro
       "type_time": mt5.ORDER_TIME_GTC,
       "type_filling": mt5.ORDER_FILLING_FOK,
   }
   ```

4. **Ejecución**:
   - Envía orden con `mt5.order_send(req)`
   - Verifica `retcode`:
     - `TRADE_RETCODE_DONE` o `TRADE_RETCODE_PLACED` → Éxito
     - Otro → Error (con mensaje descriptivo del MT5)

**Retorno**:
- `(True, "EXITOSO")`: Operación ejecutada exitosamente
- `(False, "ERROR: [mensaje]")`: Error del broker (mensaje descriptivo del MT5)

**Comportamiento**:
- **Si éxito**: Se elimina del CSV y se escribe al histórico como "EXITOSO"
- **Si error**: Se elimina del CSV y se escribe al histórico como "ERROR: [mensaje descriptivo del MT5]"

**Nota**: 
- **No hay verificaciones previas**: Se ejecuta directamente sin buscar duplicados (el ticket del origen es único)
- **No hay reintentos**: Si falla, se registra el error y se elimina del CSV
- **Mensaje de error**: Incluye `retcode` y `comment` del MT5 para diagnóstico

---

#### `close_clone(ev: Ev) -> tuple[bool, str]`
**Propósito**: Ejecutar operación CLOSE (cerrar posición abierta) en MT5.

**Parámetros**:
- `ev`: Evento con datos de la operación

**Proceso**:

1. **Control de existencia**:
   ```python
   if not ticket_exists_anywhere(ev.symbol, ev.master_ticket):
       return (False, "NO_EXISTE")
   ```
   - Si no existe en abiertas ni historial → retorna `(False, "NO_EXISTE")`

2. **Búsqueda de posición abierta**:
   ```python
   p = find_open_clone(ev.symbol, comment, ev.master_ticket)
   if p is None:
       return (False, "NO_EXISTE")
   ```
   - Si existe en historial pero no está abierta → retorna `(False, "NO_EXISTE")` (ya estaba cerrada)

3. **Preparación**:
   - Asegura que el símbolo esté disponible
   - Obtiene tick actual

4. **Determinación de tipo y precio**:
   - Si posición es `BUY` → cierra con `SELL` a precio `bid`
   - Si posición es `SELL` → cierra con `BUY` a precio `ask`

5. **Construcción de request**:
   ```python
   req = {
       "action": mt5.TRADE_ACTION_DEAL,
       "symbol": ev.symbol,
       "position": int(p.ticket),  # Ticket de la posición a cerrar
       "volume": float(p.volume),  # Volumen completo de la posición
       "type": otype,              # Operación contraria
       "price": price,
       "deviation": SLIPPAGE_POINTS,
       "magic": int(p.magic),
       "comment": comment,
       "type_time": mt5.ORDER_TIME_GTC,
       "type_filling": mt5.ORDER_FILLING_FOK,
   }
   ```

6. **Ejecución**:
   - Envía orden con `mt5.order_send(req)`
   - Verifica `retcode`:
     - `TRADE_RETCODE_DONE` → Éxito
     - `10031` → Error de red (mantener en CSV para reintento)
     - Otro → Error

**Retorno**:
- `(True, "EXITOSO")`: Operación ejecutada exitosamente
- `(False, "NO_EXISTE")`: No existe o ya estaba cerrada
- `(False, "ERROR_RED_10031")`: Error de red (mantener en CSV)
- `(False, "ERROR")`: Otro error (se lanza excepción)

**Comportamiento**:
- **Si éxito**: Se elimina del CSV y se escribe al histórico como "EXITOSO"
- **Si no existe**: Se elimina del CSV y se escribe al histórico como "OMITIDO (ya existe en MT5)"
- **Si error 10031**: Se mantiene en CSV para reintento en el próximo ciclo
- **Si otro error**: Se elimina del CSV y se escribe al histórico como "ERROR: [mensaje]"

**Manejo especial de error 10031**:
- **Código**: `10031` = "Request rejected due to absence of network connection"
- **Acción**: Mantener la línea en el CSV para reintento automático en el próximo ciclo
- **Razón**: Errores de red son temporales y pueden resolverse en el siguiente intento

---

#### `modify_clone(ev: Ev) -> tuple[bool, str]`
**Propósito**: Ejecutar operación MODIFY (modificar SL/TP de posición abierta) en MT5.

**Parámetros**:
- `ev`: Evento con datos de la operación

**Proceso**:

1. **Control de existencia**:
   ```python
   if not ticket_exists_anywhere(ev.symbol, ev.master_ticket):
       return (False, "NO_EXISTE")
   ```
   - Si no existe en abiertas ni historial → retorna `(False, "NO_EXISTE")`

2. **Búsqueda de posición abierta**:
   ```python
   p = find_open_clone(ev.symbol, comment, ev.master_ticket)
   if p is None:
       return (False, "NO_EXISTE")
   ```
   - Si existe en historial pero no está abierta → retorna `(False, "NO_EXISTE")` (no se puede modificar una posición cerrada)

3. **Construcción de request**:
   ```python
   req = {
       "action": mt5.TRADE_ACTION_SLTP,
       "position": int(p.ticket),
       "symbol": ev.symbol,
       "sl": ev.sl if ev.sl > 0 else 0.0,
       "tp": ev.tp if ev.tp > 0 else 0.0,
       "comment": comment,
   }
   ```

4. **Ejecución**:
   - Envía orden con `mt5.order_send(req)`
   - Verifica `retcode`:
     - `TRADE_RETCODE_DONE` → Éxito
     - `TRADE_RETCODE_NO_CHANGES` → Éxito (sin cambios, pero válido)
     - `10031` → Error de red (mantener en CSV)
     - Otro → Error

**Retorno**:
- `(True, "EXITOSO")`: Operación ejecutada exitosamente
- `(False, "NO_EXISTE")`: No existe o no está abierta
- `(False, "ERROR_RED_10031")`: Error de red (mantener en CSV)
- `(False, "FALLO")`: Otro error (mantener en CSV para reintento)

**Comportamiento**:
- **Si éxito**: Se elimina del CSV y se escribe al histórico como "EXITOSO"
- **Si no existe**: Se elimina del CSV y se escribe al histórico como "OMITIDO (ya existe en MT5)"
- **Si error 10031**: Se mantiene en CSV para reintento
- **Si otro error**: Se mantiene en CSV para reintento (comportamiento conservador)

**Nota**: `TRADE_RETCODE_NO_CHANGES` se considera éxito porque puede ocurrir si se intenta modificar con los mismos valores de SL/TP.

---

### 7. Funciones de Lectura y Escritura de Archivos

#### `read_events_from_csv(path: str) -> tuple[list[Ev], list[str], str]`
**Propósito**: Leer el archivo CSV y parsear eventos.

**Parámetros**:
- `path`: Ruta completa del archivo CSV

**Proceso**:

1. **Verificación de existencia**:
   - Verifica si el archivo existe
   - Verifica si el archivo está vacío

2. **Lectura binaria**:
   ```python
   with open(path, "rb") as file_handle:
       raw_content = file_handle.read()
   ```
   - Lee el archivo como binario para detectar codificación

3. **Decodificación UTF-8**:
   ```python
   file_content = raw_content.decode('utf-8')
   ```
   - Decodifica como UTF-8 (única codificación soportada)
   - Elimina BOM si existe (`\ufeff`)

4. **Detección de header**:
   ```python
   if "event_type" in first_line.lower() or "ticket" in first_line.lower():
       header_line = first_line
       start_idx = 1
   else:
       header_line = "event_type;ticket;order_type;lots;symbol;sl;tp"
       start_idx = 0
   ```
   - Si la primera línea parece header → la usa como header
   - Si no → usa header por defecto

5. **Parseo de líneas**:
   ```python
   for line in all_lines[start_idx:]:
       row = line.split(";")
       # Parsear campos:
       # 0=event_type, 1=ticket, 2=order_type, 3=lots, 4=symbol, 5=sl, 6=tp
   ```
   - Divide cada línea por `;`
   - Crea objeto `Ev` con los campos parseados
   - Guarda línea original para reescritura

**Retorno**:
- `events`: Lista de objetos `Ev` parseados
- `lines`: Lista de líneas originales (sin header)
- `header_line`: Header del CSV

**Formato esperado**:
```
event_type;ticket;order_type;lots;symbol;sl;tp
OPEN;39924291;BUY;0.04;XAUUSD;4288.04;4290.00
CLOSE;39924292;SELL;0.02;EURUSD;1.0850;1.0800
```

**Manejo de errores**:
- Archivo no existe → Lanza `RuntimeError`
- Archivo vacío → Retorna listas vacías
- Error de decodificación → Lanza `RuntimeError` con detalles

---

#### `write_csv(path: str, header: str, lines: list[str])`
**Propósito**: Reescribir el CSV con header y líneas especificadas.

**Parámetros**:
- `path`: Ruta del archivo CSV
- `header`: Línea de cabecera
- `lines`: Lista de líneas a escribir (sin header)

**Proceso**:
1. Abre archivo en modo escritura (`"w"`)
2. Escribe header seguido de salto de línea
3. Escribe cada línea seguida de salto de línea
4. Codificación: UTF-8

**Uso**: Actualizar el CSV principal eliminando líneas procesadas exitosamente.

---

#### `append_to_history_csv(csv_line: str, resultado: str = "EXITOSO")`
**Propósito**: Añadir una línea al archivo histórico con timestamp y resultado.

**Parámetros**:
- `csv_line`: Línea original del CSV
- `resultado`: Resultado de la ejecución ("EXITOSO", "OMITIDO", "ERROR: ...")

**Proceso**:

1. **Crear línea histórica**:
   ```python
   timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
   hist_line = f"{timestamp};{resultado};{csv_line}\n"
   ```

2. **Crear archivo si no existe**:
   ```python
   if not os.path.exists(hist_path):
       with open(hist_path, "w", encoding="utf-8", newline="") as f:
           f.write("timestamp_ejecucion;resultado;event_type;ticket;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit\n")
   ```
   - Escribe header histórico (compatible con formato antiguo)

3. **Añadir línea**:
   ```python
   with open(hist_path, "a", encoding="utf-8", newline="") as f:
       f.write(hist_line)
   ```

**Formato de línea histórica**:
```
2025-12-16 08:03:01;EXITOSO;OPEN;39924291;BUY;0.04;XAUUSD;;;;;0.00
2025-12-16 08:17:20;ERROR: retcode=10004;OPEN;39924292;SELL;0.02;EURUSD;;;;;0.00
```

**Nota**: El header histórico incluye campos antiguos (`open_price`, `open_time`, etc.) para compatibilidad, pero los nuevos eventos solo tienen los campos simplificados.

---

#### `common_files_csv_path(csv_name: str) -> str`
**Propósito**: Obtener la ruta completa del archivo CSV en la carpeta COMMON\Files.

**Parámetros**:
- `csv_name`: Nombre del archivo CSV

**Proceso**:
1. Obtiene información del terminal con `mt5.terminal_info()`
2. Construye ruta: `<commondata_path>\Files\<csv_name>`

**Retorno**: Ruta completa del archivo

**Ejemplo**:
```
C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files\TradeEvents.txt
```

---

### 8. Función Principal

#### `main_loop()`
**Propósito**: Bucle principal del clonador.

**Proceso**:

1. **Inicialización de MT5**:
   ```python
   if not mt5.initialize():
       raise SystemExit(f"MT5 init failed: {mt5.last_error()}")
   ```

2. **Configuración de multiplicador de lotaje** (si `CUENTA_FONDEO = True`):
   ```python
   if CUENTA_FONDEO:
       print("Seleccione el multiplicador para el lotaje origen:")
       print("  1. Multiplicar por 1 (lotaje original)")
       print("  2. Multiplicar por 2 (doble del lotaje)")
       print("  3. Multiplicar por 3 (triple del lotaje)")
       opcion = input("Ingrese su opción (1, 2 o 3): ").strip()
       # Configura LOT_MULTIPLIER según opción
   ```
   - Muestra menú interactivo
   - Solicita opción al usuario
   - Configura `LOT_MULTIPLIER` globalmente

3. **Bucle principal**:
   ```python
   while True:
       # Leer CSV
       events, lines, header = read_events_from_csv(path)
       
       # Procesar cada evento
       remaining_lines = []
       for idx, ev in enumerate(events):
           # Ejecutar operación según event_type
           # Manejar resultados y actualizar remaining_lines
       
       # Reescribir CSV con líneas pendientes
       if len(remaining_lines) != len(lines):
           write_csv(path, header, remaining_lines)
       
       time.sleep(TIMER_SECONDS)
   ```

4. **Procesamiento de eventos**:

   **OPEN**:
   ```python
   executed_successfully, resultado = open_clone(ev)
   if executed_successfully:
       print(f"[OPEN] {ev.symbol} {ev.order_type} {ev.master_lots} lots (maestro: {ev.master_ticket})")
   # Siempre elimina del CSV (éxito o fallo) y escribe al histórico
   append_to_history_csv(original_line, resultado)
   ```

   **CLOSE**:
   ```python
   executed_successfully, motivo = close_clone(ev)
   if executed_successfully:
       append_to_history_csv(original_line, "EXITOSO")
   elif motivo == "ERROR_RED_10031":
       remaining_lines.append(original_line)  # Mantener en CSV
       append_to_history_csv(original_line, "ERROR RED 10031: ...")
   elif motivo == "NO_EXISTE":
       append_to_history_csv(original_line, "OMITIDO (ya existe en MT5)")
   else:
       append_to_history_csv(original_line, f"ERROR: {motivo}")
   ```

   **MODIFY**:
   ```python
   executed_successfully, motivo = modify_clone(ev)
   if executed_successfully:
       append_to_history_csv(original_line, "EXITOSO")
   elif motivo == "ERROR_RED_10031":
       remaining_lines.append(original_line)  # Mantener en CSV
   elif motivo == "NO_EXISTE":
       append_to_history_csv(original_line, "OMITIDO (ya existe en MT5)")
   elif motivo == "FALLO":
       remaining_lines.append(original_line)  # Mantener en CSV
   ```

5. **Manejo de errores**:
   - Errores de lectura → Imprime error y continúa
   - Errores de ejecución → Mantiene línea en CSV y registra en histórico
   - `KeyboardInterrupt` → Detiene bucle y desconecta MT5

6. **Finalización**:
   ```python
   finally:
       mt5.shutdown()
       print("MT5 desconectado")
   ```

---

## Tipos de Operaciones

### 1. OPEN
**Propósito**: Abrir una nueva posición en MT5.

**Flujo**:
1. Se ejecuta directamente sin verificaciones previas (el ticket del origen es único)
2. Calcular lotaje esclavo (maestro × multiplicador o lote fijo)
3. Obtener precio actual (ask para BUY, bid para SELL)
4. Enviar orden de mercado
5. Registrar resultado en histórico

**Comportamiento**:
- **Éxito**: Elimina del CSV, escribe "EXITOSO" al histórico
- **Error**: Elimina del CSV, escribe "ERROR: [mensaje descriptivo del MT5]" al histórico

**Características**:
- **Sin verificaciones previas**: Se ejecuta directamente (el ticket del origen es único)
- **No hay reintentos**: Si falla, se registra el error y se elimina del CSV
- **Mensaje de error**: Incluye `retcode` y `comment` del MT5 para diagnóstico completo

---

### 2. CLOSE
**Propósito**: Cerrar una posición abierta en MT5.

**Flujo**:
1. Buscar solo en posiciones abiertas (no en historial)
2. Si no encuentra → No existe operación abierta (eliminar del CSV)
3. Si encuentra → Obtener precio actual (bid para cerrar BUY, ask para cerrar SELL)
4. Enviar orden contraria con `position=ticket`
5. Registrar resultado en histórico

**Comportamiento**:
- **Éxito**: Elimina del CSV, escribe "CLOSE OK" al histórico
- **No existe operación abierta**: Elimina del CSV, escribe "No existe operacion abierta" al histórico
- **Error (cualquier tipo, incluyendo 10031)**: Mantiene en CSV para reintento, escribe "ERROR: Fallo al cerrar (reintento)" al histórico

**Reintentos**: Para cualquier error. Se mantiene en CSV y se reintenta automáticamente hasta que se cierre exitosamente.

---

### 3. MODIFY
**Propósito**: Modificar SL/TP de una posición abierta en MT5.

**Flujo**:
1. Buscar solo en posiciones abiertas (no en historial)
2. Si no encuentra → No existe operación abierta (eliminar del CSV)
3. Si encuentra → Enviar orden de modificación SL/TP
4. Registrar resultado en histórico

**Comportamiento**:
- **Éxito**: Elimina del CSV, escribe "MODIFY OK" al histórico
- **No existe operación abierta**: Elimina del CSV, escribe "No existe operacion abierta" al histórico
- **Error (cualquier tipo, incluyendo 10031)**: Mantiene en CSV para reintento, escribe "ERROR: Fallo al modificar (reintento)" al histórico

**Reintentos**: Para cualquier error. Se mantiene en CSV y se reintenta automáticamente hasta que se actualice exitosamente o se cierre la operación.

---

## Manejo de Errores

### Errores de Lectura
- **Archivo no existe**: Lanza `RuntimeError`, imprime error, continúa en siguiente ciclo
- **Archivo vacío**: Retorna listas vacías, continúa normalmente
- **Error de decodificación**: Lanza `RuntimeError` con detalles, continúa en siguiente ciclo

### Errores de Ejecución
- **OPEN fallido**: Se registra en histórico como "ERROR: [mensaje descriptivo del MT5]", se elimina del CSV (no reintenta)
- **CLOSE fallido (cualquier error)**: Se mantiene en CSV para reintento, se registra "ERROR: Fallo al cerrar (reintento)" en histórico
- **MODIFY fallido (cualquier error)**: Se mantiene en CSV para reintento, se registra "ERROR: Fallo al modificar (reintento)" en histórico

### Errores de Red (10031)
- **Código**: `10031` = "Request rejected due to absence of network connection"
- **Manejo**: Se trata igual que cualquier otro error para CLOSE y MODIFY
- **Aplicable a**: CLOSE y MODIFY (no OPEN)
- **Comportamiento**: Se mantiene en CSV para reintento automático hasta éxito
- **Razón**: Errores de red son temporales y pueden resolverse automáticamente

---

## Flujo de Datos

```
LectorOrdenes.mq4 (MT4)
    │
    └─ Escribe eventos → TradeEvents.txt (UTF-8)
        │
        └─ ClonadorMQ5.py (Python)
            │
            ├─ Lee TradeEvents.txt cada 1 segundo
            │
            ├─ Procesa cada evento:
            │   ├─ OPEN → Ejecuta en MT5
            │   ├─ CLOSE → Ejecuta en MT5
            │   └─ MODIFY → Ejecuta en MT5
            │
            ├─ Actualiza TradeEvents.txt (elimina procesados)
            │
            └─ Escribe TradeEvents_historico.txt (registro completo)
```

---

## Configuración y Parámetros

### Parámetros Globales

| Parámetro | Valor por Defecto | Descripción |
|-----------|-------------------|-------------|
| `CSV_NAME` | `"TradeEvents.txt"` | Archivo de entrada |
| `CSV_HISTORICO` | `"TradeEvents_historico.txt"` | Archivo histórico |
| `TIMER_SECONDS` | `1` | Intervalo de lectura (segundos) |
| `SLIPPAGE_POINTS` | `30` | Slippage permitido |
| `CUENTA_FONDEO` | `True` | Copiar lotaje del maestro |
| `FIXED_LOTS` | `0.10` | Lote fijo si no es fondeo |
| `MAGIC` | `0` | Magic number |
| `LOT_MULTIPLIER` | `1.0` | Multiplicador (configurado al inicio) |

### Configuración Interactiva

Si `CUENTA_FONDEO = True`, al iniciar se solicita:
- **Opción 1**: Multiplicar por 1 (lotaje original)
- **Opción 2**: Multiplicar por 2 (doble del lotaje)
- **Opción 3**: Multiplicar por 3 (triple del lotaje)

---

## Limitaciones y Consideraciones

### Limitaciones

1. **Codificación única**: Solo lee archivos UTF-8 (sin soporte para otras codificaciones)
2. **Sin reintentos inmediatos**: OPEN no tiene reintentos (si falla, se registra y elimina)
3. **Sin verificaciones previas**: OPEN se ejecuta directamente sin buscar duplicados (ticket único)
4. **Reintentos solo para red**: CLOSE y MODIFY solo reintentan para error 10031
5. **Dependencia de MT5**: Requiere MT5 abierto y conectado
6. **Búsqueda en historial**: Solo para CLOSE y MODIFY (últimos 90 días, puede ser lento con muchos deals)

### Consideraciones

1. **Frecuencia de lectura**: 1 segundo puede ser suficiente para la mayoría de casos
2. **Ticket único**: El ticket del origen es único, por lo que OPEN se ejecuta directamente sin verificaciones previas
3. **Reintentos automáticos**: CLOSE y MODIFY reintentan automáticamente cualquier error hasta éxito
4. **Solo posiciones abiertas**: CLOSE y MODIFY solo buscan en posiciones abiertas (no en historial)
5. **Registro completo**: Todas las ejecuciones se registran en histórico (éxito o fallo)

---

## Casos de Uso

### Caso 1: Clonación Simple
- **Escenario**: Un MT4 genera eventos, Python los clona a MT5
- **Resultado**: Operaciones sincronizadas entre MT4 y MT5

### Caso 2: Multiplicador de Lotaje
- **Escenario**: Cuenta de fondeo con multiplicador 2x
- **Resultado**: Operaciones clonadas con el doble del volumen maestro

### Caso 3: Manejo de Errores de Red
- **Escenario**: Error 10031 al cerrar posición
- **Resultado**: La línea se mantiene en CSV y se reintenta automáticamente en el siguiente ciclo

### Caso 4: Ejecución Directa de OPEN
- **Escenario**: Llega un evento OPEN con ticket único del origen
- **Resultado**: Se ejecuta directamente en MT5, se registra resultado (éxito o error) en histórico

### Caso 5: Reintentos Automáticos de CLOSE/MODIFY
- **Escenario**: Error al cerrar o modificar una posición (error de red u otro)
- **Resultado**: Se mantiene en CSV y se reintenta automáticamente hasta éxito o hasta que la operación se cierre

---

## Dependencias

### Python
- **Versión**: Python 3.x
- **Librerías**:
  - `MetaTrader5`: API de MT5
  - `os`, `time`, `csv`, `dataclasses`, `typing`, `io`, `datetime`: Librerías estándar

### MetaTrader 5
- **Versión**: Build 3000+
- **Requisitos**: Terminal MT5 abierto y conectado a cuenta de trading

### Sistema Operativo
- **Windows**: Requerido (rutas COMMON\Files)
- **Permisos**: Lectura/escritura en carpeta común de MetaTrader

---

## Optimizaciones Implementadas

### 1. Lectura en 1 segundo
- **Ventaja**: Respuesta rápida a nuevos eventos
- **Consideración**: Puede aumentar carga del sistema si hay muchos eventos

### 2. Ejecución directa de OPEN sin verificaciones
- **Versión anterior**: Verificaba en abiertas e historial antes de ejecutar OPEN
- **Versión actual**: Ejecuta OPEN directamente sin verificaciones previas (el ticket del origen es único)
- **Ventaja**: Reduce tiempo de procesamiento y simplifica la lógica

### 3. Manejo conservador de errores
- **CLOSE/MODIFY**: Mantiene en CSV para reintento si falla (excepto si no existe)
- **Ventaja**: Mayor probabilidad de éxito en operaciones críticas

### 4. Registro completo en histórico
- **Ventaja**: Trazabilidad completa de todas las ejecuciones
- **Uso**: Auditoría y depuración

---

## Ejemplo de Ejecución

### Entrada (TradeEvents.txt)
```
event_type;ticket;order_type;lots;symbol;sl;tp
OPEN;39924291;BUY;0.04;XAUUSD;4288.04;4290.00
CLOSE;39924292;SELL;0.02;EURUSD;1.0850;1.0800
MODIFY;39924291;BUY;0.04;XAUUSD;4290.00;4295.00
```

### Salida (TradeEvents_historico.txt)
```
timestamp_ejecucion;resultado;event_type;ticket;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit
2025-12-16 08:03:01;EXITOSO;OPEN;39924291;BUY;0.04;XAUUSD;;;;;0.00
2025-12-16 08:17:20;EXITOSO;CLOSE;39924292;SELL;0.02;EURUSD;;;;;0.00
2025-12-16 08:41:58;EXITOSO;MODIFY;39924291;BUY;0.04;XAUUSD;;;;;0.00
```

### Salida (TradeEvents.txt después de procesar)
```
event_type;ticket;order_type;lots;symbol;sl;tp
```
(Archivo vacío o con líneas pendientes si hubo errores de red)

---

## Versiones y Evolución

### V1
- Lectura del historial de MQL5 antes de ejecutar operaciones
- Timer de 3 segundos

### V2
- Optimizado para leer en 1 segundo
- Eliminadas lecturas al historial de MQL5 (solo verificación inicial)
- Timer reducido a 1 segundo

### V3 (Actual)
- Lectura exclusiva de UTF-8
- Formato simplificado de campos (`event_type;ticket;order_type;lots;symbol;sl;tp`)
- Manejo especial de error 10031 (red) para CLOSE y MODIFY
- Multiplicador de lotaje configurable al inicio
- Registro completo en histórico de todas las ejecuciones

---

## Conclusión

`ClonadorMQ5.py` es un script Python robusto y eficiente que:

1. **Lee** eventos de trading desde un archivo compartido (`TradeEvents.txt`)
2. **Clona** operaciones (OPEN, CLOSE, MODIFY) a MetaTrader 5
3. **Ejecuta OPEN directamente** sin verificaciones previas (ticket único del origen)
4. **Reintenta automáticamente** CLOSE y MODIFY hasta éxito (cualquier error se mantiene en CSV)
5. **Busca solo en abiertas** para CLOSE y MODIFY (no en historial)
6. **Registra** todas las ejecuciones en un archivo histórico con mensajes descriptivos
7. **Optimiza** el rendimiento leyendo cada 1 segundo y ejecutando directamente

El script funciona como un puente entre sistemas de trading (MT4 → MT5) permitiendo la clonación automática de operaciones con configuración flexible de lotajes y manejo robusto de errores.

