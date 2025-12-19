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
2. **Verifica y reconecta automáticamente** con MT5 si es necesario (`ensure_mt5_connection()`)
3. **Se ejecuta directamente** sin verificaciones previas (el ticket del origen es único)
4. Calcula el lotaje esclavo:
   - Si `CUENTA_FONDEO = True`: `lotaje_esclavo = lotaje_maestro × multiplicador` (1x, 2x o 3x)
   - Si `CUENTA_FONDEO = False`: Usa `FIXED_LOTS` ajustado a los límites del símbolo
5. Ejecuta la orden de mercado en MT5 (BUY o SELL)
6. **Resultado**:
   - **Éxito**: Elimina del CSV, registra "EXITOSO" en histórico, **envía notificación push de éxito**
   - **Fallo**: Elimina del CSV, registra "ERROR: [mensaje del broker]" en histórico, **envía notificación push de fallo**

**Características**:
- No hay reintentos (si falla, se registra el error y se elimina)
- El ticket maestro se guarda como comentario en MT5 para identificación
- Respeta los límites de volumen del símbolo (min, max, step)
- **Reconexión automática**: Verifica y reconecta con MT5 antes de ejecutar si se perdió la conexión
- **Notificaciones push**: 
  - Envía notificación push cuando se ejecuta exitosamente: "Ticket: XXXXX - OPEN EXITOSO: SYMBOL ORDER_TYPE LOTS lots"
  - Envía notificación push cuando falla (cada fallo se notifica): "Ticket: XXXXX - OPEN FALLO: (retcode, 'comment')"

---

#### 2. CLOSE (Cierre de Posición)

**Propósito**: Cerrar una posición abierta en MT5 cuando se cierra en el maestro.

**Flujo de Negocio**:
1. Llega un evento `CLOSE` con el ticket maestro
2. **Verifica y reconecta automáticamente** con MT5 si es necesario (`ensure_mt5_connection()`)
3. **Busca solo en posiciones abiertas** (no en historial)
4. Si encuentra la posición abierta:
   - Ejecuta orden contraria (BUY → SELL, SELL → BUY)
   - Cierra al precio de mercado actual
5. **Resultado**:
   - **Éxito**: Elimina del CSV, registra "CLOSE OK" en histórico, remueve del set de notificaciones
   - **No existe operación abierta**: Elimina del CSV, registra "No existe operacion abierta" en histórico, remueve del set de notificaciones
   - **Fallo (cualquier error)**: Mantiene en CSV para reintento, registra "ERROR: Fallo al cerrar (reintento)" en histórico, **envía notificación push solo en el primer fallo**

**Características**:
- **Reintentos automáticos**: Si falla (incluyendo errores de red), se mantiene en CSV y se reintenta en el siguiente ciclo hasta que se cierre exitosamente
- Solo busca en posiciones abiertas (no puede cerrar algo que ya está cerrado)
- Manejo especial de errores de red (10031) para garantizar el cierre
- **Reconexión automática**: Verifica y reconecta con MT5 antes de ejecutar si se perdió la conexión
- **Notificaciones push**: Envía notificación push usando `SendNotification()` de MetaTrader solo en el primer fallo por ticket (evita duplicados en reintentos)

---

#### 3. MODIFY (Modificación de SL/TP)

**Propósito**: Actualizar los niveles de Stop Loss y Take Profit de una posición abierta en MT5 cuando se modifican en el maestro.

**Flujo de Negocio**:
1. Llega un evento `MODIFY` con el ticket maestro y nuevos valores de SL/TP
2. **Verifica y reconecta automáticamente** con MT5 si es necesario (`ensure_mt5_connection()`)
3. **Busca solo en posiciones abiertas** (no en historial)
4. Si encuentra la posición abierta:
   - Actualiza SL y TP con los nuevos valores
5. **Resultado**:
   - **Éxito**: Elimina del CSV, registra "MODIFY OK" en histórico, remueve del set de notificaciones
   - **No existe operación abierta**: Elimina del CSV, registra "No existe operacion abierta" en histórico, remueve del set de notificaciones
   - **Fallo (cualquier error)**: Mantiene en CSV para reintento, registra "ERROR: Fallo al modificar (reintento)" en histórico, **envía notificación push solo en el primer fallo**

**Características**:
- **Reintentos automáticos**: Si falla (incluyendo errores de red), se mantiene en CSV y se reintenta en el siguiente ciclo hasta que se actualice exitosamente o se cierre la operación
- Solo modifica posiciones abiertas (no puede modificar algo que ya está cerrado)
- `TRADE_RETCODE_NO_CHANGES` se considera éxito (mismo SL/TP)
- **Reconexión automática**: Verifica y reconecta con MT5 antes de ejecutar si se perdió la conexión
- **Notificaciones push**: Envía notificación push usando `SendNotification()` de MetaTrader solo en el primer fallo por ticket (evita duplicados en reintentos)

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

#### `ensure_mt5_connection()`
**Propósito**: Verificar la conexión con MT5 y reconectar automáticamente si es necesario.

**Proceso**:
1. Verifica la conexión llamando a `mt5.terminal_info()`
2. Si retorna `None` (conexión perdida):
   - Imprime mensaje de reconexión
   - Cierra la conexión actual con `mt5.shutdown()`
   - Espera 1 segundo para dar tiempo al sistema
   - Intenta reconectar con `mt5.initialize()`
   - Si falla la reconexión, lanza `RuntimeError` con el error descriptivo
   - Si tiene éxito, imprime confirmación de reconexión

**Retorno**: `True` si la conexión está activa o se reconectó exitosamente

**Uso**: Antes de cualquier operación crítica con MT5 (lectura de archivos, ejecución de órdenes, búsqueda de posiciones).

**Manejo de errores**:
- Formatea correctamente los errores de MT5 que vienen como tupla `(code, description)`
- Proporciona mensajes descriptivos para facilitar el diagnóstico

---

#### `ensure_symbol(symbol: str)`
**Propósito**: Asegurar que un símbolo esté disponible en MT5, con verificación y reconexión automática.

**Parámetros**:
- `symbol`: Símbolo a seleccionar

**Proceso**:
1. Verifica la conexión con MT5 (`ensure_mt5_connection()`)
2. Intenta seleccionar el símbolo con `mt5.symbol_select(symbol, True)`
3. Si falla:
   - Obtiene el error de MT5 (`mt5.last_error()`)
   - Si es error IPC (-10001): "IPC send failed"
     - Imprime mensaje de reconexión específico
     - Intenta reconectar automáticamente (`ensure_mt5_connection()`)
     - Reintenta la selección del símbolo
     - Si falla nuevamente, lanza `RuntimeError` con el error descriptivo
   - Si es otro error, lanza `RuntimeError` con el error descriptivo

**Uso**: Antes de ejecutar operaciones, asegurar que el símbolo esté disponible y que la conexión con MT5 esté activa.

**Características**:
- Manejo específico del error IPC (-10001) para reconexión automática
- Formatea correctamente los errores de MT5 como tuplas `(code, description)`
- Proporciona mensajes descriptivos para facilitar el diagnóstico

---

#### `clone_comment(master_ticket: str) -> str`
**Propósito**: Generar el comentario para las órdenes clonadas.

**Parámetros**:
- `master_ticket`: Ticket maestro

**Retorno**: El mismo `master_ticket` (sin modificaciones)

**Razón**: Evitar truncamiento de comentarios en MT5. El comentario es simplemente el ticket maestro.

---

#### `send_push_notification(message: str) -> bool`
**Propósito**: Enviar una notificación push usando `SendNotification()` de MetaTrader mediante archivo intermedio.

**Nota importante**: La API de Python de MetaTrader5 NO incluye `send_notification()`. La función `SendNotification()` solo existe en MQL5. Por lo tanto, esta función escribe el mensaje en un archivo que es leído por el EA `EnviarNotificacion.mq5`.

**Parámetros**:
- `message`: Mensaje a enviar (máximo 255 caracteres)

**Proceso**:
1. Trunca el mensaje a 255 caracteres si es muy largo (límite de MT5)
2. Obtiene la ruta del archivo `NotificationQueue.txt` en `Common\Files\` usando `common_files_csv_path()`
3. Escribe el mensaje en el archivo en modo binario (UTF-8)
4. Fuerza sincronización del sistema de archivos si está disponible
5. Muestra mensajes informativos en consola con la ruta del archivo

**Retorno**: 
- `True` si se escribió exitosamente en el archivo
- `False` si falló (con mensaje de error en consola)

**Uso**: Enviar notificaciones push cuando:
- Se inicia el sistema
- OPEN se ejecuta exitosamente o falla
- CLOSE falla (solo primer fallo por ticket)
- MODIFY falla (solo primer fallo por ticket)

**Características**:
- Trunca automáticamente mensajes largos
- Escribe en modo binario para compatibilidad UTF-8
- Maneja errores de manera segura sin interrumpir el flujo principal
- Muestra mensajes informativos en consola con la ruta del archivo
- Requiere que el EA `EnviarNotificacion.mq5` esté ejecutándose para procesar las notificaciones

---

### 4. Funciones de Búsqueda en MT5

#### `find_open_clone(symbol: str, comment: str, master_ticket: str = None) -> Optional[Position]`
**Propósito**: Buscar una posición abierta por símbolo y comentario (ticket maestro).

**Parámetros**:
- `symbol`: Símbolo a buscar
- `comment`: Comentario (ticket maestro)
- `master_ticket`: Ticket maestro (alternativo)

**Proceso**:
1. Verifica la conexión con MT5 (`ensure_mt5_connection()`) antes de buscar
2. Obtiene todas las posiciones abiertas del símbolo (`mt5.positions_get(symbol=symbol)`)
3. Compara el comentario de cada posición con el ticket maestro
4. Retorna la primera posición que coincida

**Retorno**: Objeto `Position` si existe, `None` si no existe

**Uso**: Verificar si una posición ya está abierta antes de ejecutar OPEN o para encontrar la posición a cerrar/modificar.

**Características**:
- Verifica la conexión antes de buscar posiciones para evitar errores IPC

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
   - Verifica la conexión con MT5 (`ensure_mt5_connection()`)
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
   - Verifica la conexión con MT5 antes de enviar (`ensure_mt5_connection()`)
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
- **Verificación de conexión**: Verifica y reconecta automáticamente antes de ejecutar la operación
- **Notificaciones push**: Envía notificación push con `SendNotification()` de MetaTrader cuando falla (ver sección "Sistema de Notificaciones Push")

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
   - Verifica la conexión con MT5 (`ensure_mt5_connection()`)
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
   - Verifica la conexión con MT5 antes de enviar (`ensure_mt5_connection()`)
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

**Verificación de conexión**: Verifica y reconecta automáticamente antes de ejecutar la operación

**Notificaciones push**: Envía notificación push con `SendNotification()` de MetaTrader cuando se ejecuta exitosamente o cuando falla (ver sección "Sistema de Notificaciones Push")

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
   - Verifica la conexión con MT5 antes de enviar (`ensure_mt5_connection()`)
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

**Verificación de conexión**: Verifica y reconecta automáticamente antes de ejecutar la operación

**Notificaciones push**: Envía notificación push con `SendNotification()` de MetaTrader cuando se ejecuta exitosamente o cuando falla (ver sección "Sistema de Notificaciones Push")

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
1. Verifica la conexión con MT5 (`ensure_mt5_connection()`) antes de obtener la ruta
2. Obtiene información del terminal con `mt5.terminal_info()`
3. Construye ruta: `<commondata_path>\Files\<csv_name>`

**Retorno**: Ruta completa del archivo

**Ejemplo**:
```
C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files\TradeEvents.txt
```

**Características**:
- Verifica la conexión antes de obtener la ruta para evitar errores IPC

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

3. **Notificación de inicio**:
   ```python
   # Enviar notificación push de inicio
   send_push_notification("Activado ClonadorMQ5.py")
   ```
   - Envía una notificación push indicando que el clonador se ha activado
   - Mensaje: `"Activado ClonadorMQ5.py"`
   - Se envía después de configurar el multiplicador de lotaje y antes de iniciar el bucle principal

4. **Bucle principal**:
   ```python
   while True:
       # Verificar conexión antes de cada ciclo
       ensure_mt5_connection()
       
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
- **Verificación de conexión**: Verifica y reconecta automáticamente antes de ejecutar
- **Notificaciones push**: Envía notificación push cuando falla (cada fallo se notifica)

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

**Verificación de conexión**: Verifica y reconecta automáticamente antes de ejecutar

**Notificaciones push**: Envía notificación push solo en el primer fallo por ticket (evita duplicados en reintentos)

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

**Verificación de conexión**: Verifica y reconecta automáticamente antes de ejecutar

**Notificaciones push**: Envía notificación push solo en el primer fallo por ticket (evita duplicados en reintentos)

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

### Errores de Conexión IPC (-10001)
- **Código**: `-10001` = "IPC send failed"
- **Manejo**: Detectado automáticamente en `ensure_symbol()` y otras funciones críticas
- **Comportamiento**: 
  - Se detecta el error IPC
  - Se intenta reconectar automáticamente con `ensure_mt5_connection()`
  - Se reintenta la operación después de reconectar
  - Si falla nuevamente, se lanza `RuntimeError` con el error descriptivo
- **Aplicable a**: Todas las operaciones que requieren comunicación con MT5
- **Razón**: Errores IPC indican pérdida de conexión con MT5, requieren reconexión

### Reconexión Automática
- **Función**: `ensure_mt5_connection()`
- **Comportamiento**:
  - Verifica conexión con `mt5.terminal_info()`
  - Si retorna `None`, intenta reconectar automáticamente
  - Cierra conexión actual, espera 1 segundo, y reinicializa MT5
  - Proporciona mensajes informativos durante el proceso de reconexión
- **Uso**: Antes de operaciones críticas (lectura de archivos, ejecución de órdenes, búsqueda de posiciones)
- **Ventaja**: Mayor robustez ante desconexiones temporales sin intervención manual

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

### 5. Reconexión automática con MT5
- **Ventaja**: Mayor robustez ante desconexiones temporales
- **Comportamiento**: Verifica conexión antes de operaciones críticas y reconecta automáticamente si se pierde
- **Manejo específico**: Detecta errores IPC (-10001) y reconecta automáticamente
- **Uso**: Antes de leer archivos, ejecutar órdenes, buscar posiciones

### 6. Sistema de notificaciones push
- **Ventaja**: Alertas inmediatas de inicio del sistema y fallos en operaciones críticas
- **Comportamiento**: Envía notificaciones push usando `SendNotification()` de MetaTrader
- **Uso**: 
  - Notificar inicio del sistema ("Activado ClonadorMQ5.py")
  - Notificar éxitos y fallos en OPEN, CLOSE y MODIFY (ver sección "Sistema de Notificaciones Push")

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

## Sistema de Notificaciones Push

### Propósito
Enviar notificaciones push al dispositivo móvil para:
- **Inicio del sistema**: Notificar cuando el clonador se activa
- **Éxitos en operaciones**: Notificar cuando OPEN, CLOSE y MODIFY se ejecutan exitosamente
- **Fallos en operaciones**: Notificar cuando fallan operaciones críticas (OPEN, CLOSE, MODIFY), permitiendo al usuario estar informado inmediatamente de problemas en el sistema de clonación

### Implementación Técnica

**Problema**: La API de Python de MetaTrader5 NO incluye la función `send_notification()`. La función `SendNotification()` solo existe en MQL5.

**Solución**: Sistema de pasarela mediante archivo intermedio:
1. **Python** (`ClonadorMQ5.py`): Escribe mensajes en `NotificationQueue.txt` ubicado en `Common\Files\`
2. **EA MQL5** (`EnviarNotificacion.mq5`): Lee el archivo cada segundo y llama a `SendNotification()` de MQL5
3. **Limpieza**: El EA limpia el archivo después de enviar exitosamente

**Componentes**:
- **Función Python**: `send_push_notification(message: str) -> bool`
  - Escribe el mensaje en `NotificationQueue.txt` (Common\Files)
  - Trunca mensajes a 255 caracteres (límite de MT5)
  - Maneja errores y muestra mensajes informativos en consola
  - Retorna `True` si se escribió exitosamente en el archivo, `False` si falló
- **EA MQL5**: `EnviarNotificacion.mq5`
  - Se ejecuta como Expert Advisor en cualquier gráfico de MT5
  - Verifica `NotificationQueue.txt` cada segundo (configurable)
  - Lee el archivo en modo binario y convierte UTF-8 a string
  - Llama a `SendNotification()` de MQL5 con el mensaje
  - Limpia el archivo después de enviar exitosamente
  - Maneja errores y muestra logs informativos
- **Sets globales en Python**: 
  - `notified_close_tickets: set[str]` - Tickets de CLOSE ya notificados
  - `notified_modify_tickets: set[str]` - Tickets de MODIFY ya notificados

**Rutas**:
- Python escribe en: `<commondata_path>\Files\NotificationQueue.txt`
- EA lee de: `<commondata_path>\Files\NotificationQueue.txt` (usando `FILE_COMMON` con solo el nombre del archivo)
- Ejemplo: `C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files\NotificationQueue.txt`

**Requisitos**:
- El EA `EnviarNotificacion.mq5` debe estar ejecutándose como Expert Advisor en MT5
- Las notificaciones deben estar habilitadas en el terminal MT5 (Configuración → Notificaciones)

### Comportamiento por Tipo de Evento

#### Inicio del Sistema
- **Cuándo se notifica**: Cada vez que se inicializa `ClonadorMQ5.py`
- **Formato del mensaje**: `"Activado ClonadorMQ5.py"`
- **Ubicación**: Se envía después de inicializar MT5 y configurar el multiplicador de lotaje, antes de iniciar el bucle principal
- **Características**:
  - Se envía una única vez al inicio del script
  - Confirma que el sistema está activo y funcionando
  - Permite al usuario verificar que el clonador está en ejecución

#### OPEN
- **Cuándo se notifica**: 
  - **Éxito**: Cada vez que se ejecuta exitosamente una operación OPEN
  - **Fallo**: Cada vez que falla una operación OPEN
- **Formato del mensaje**:
  - **Éxito**: `"Ticket: XXXXX - OPEN EXITOSO: SYMBOL ORDER_TYPE LOTS lots"`
  - **Fallo**: `"Ticket: XXXXX - OPEN FALLO: (retcode, 'comment')"`
- **Ejemplos**: 
  - Éxito: `"Ticket: 40014799 - OPEN EXITOSO: XAUUSD BUY 0.04 lots"`
  - Fallo: `"Ticket: 40014799 - OPEN FALLO: (10004, 'Invalid price')"`
  - Fallo: `"Ticket: 40014799 - OPEN FALLO: (None, 'order_send retornó None')"`
- **Características**:
  - **Notificación de éxito**: Se envía cuando `retcode` es `TRADE_RETCODE_DONE` o `TRADE_RETCODE_PLACED`
  - **Notificación de fallo**: Se envía cuando `order_send` retorna `None` o cuando `retcode` no es éxito
  - No hay rastreo de tickets notificados (cada operación se notifica independientemente)
  - Se notifica tanto éxito como fallo sin excepciones
  - Maneja tanto errores de `order_send` (cuando retorna objeto con `retcode` diferente de éxito) como cuando `order_send` retorna `None`
  - Las notificaciones se envían inmediatamente después de detectar el resultado, antes de retornar

#### CLOSE
- **Cuándo se notifica**: 
  - **Éxito**: Cada vez que se ejecuta exitosamente una operación CLOSE
  - **Fallo**: Solo el primer fallo por ticket (evita notificaciones duplicadas en reintentos)
- **Formato del mensaje**:
  - **Éxito**: `"Ticket: XXXXX - CLOSE EXITOSO: SYMBOL ORDER_TYPE LOTS lots"`
  - **Fallo**: `"Ticket: XXXXX - CLOSE FALLO: (retcode, 'comment')"`
- **Ejemplos**: 
  - Éxito: `"Ticket: 40014799 - CLOSE EXITOSO: XAUUSD BUY 0.04 lots"`
  - Fallo: `"Ticket: 40014799 - CLOSE FALLO: (10031, 'Request rejected due to absence of network connection')"`
  - Fallo: `"Ticket: 40014799 - CLOSE FALLO: (None, 'order_send retornó None')"`
- **Características**:
  - **Notificación de éxito**: Se envía cuando `retcode` es `TRADE_RETCODE_DONE`, se envía inmediatamente después de detectar el éxito, antes de retornar
  - **Notificación de fallo**: Usa un set en memoria (`notified_close_tickets`) para rastrear tickets ya notificados
  - Verifica si el ticket está en el set antes de enviar fallo: `if ev.master_ticket not in notified_close_tickets:`
  - Si no está en el set (fallo):
    - Envía la notificación push
    - Agrega el ticket al set: `notified_close_tickets.add(ev.master_ticket)`
  - Si ya está en el set: No envía notificación de fallo (ya se notificó antes)
  - Remueve el ticket del set cuando:
    - Se cierra exitosamente (CLOSE OK): `notified_close_tickets.discard(ev.master_ticket)`
    - Se elimina del CSV por cualquier motivo (ej: "No existe operacion abierta"): `notified_close_tickets.discard(ev.master_ticket)`
  - Evita notificaciones duplicadas de fallo en múltiples reintentos del mismo ticket
  - Maneja tanto errores de `order_send` como cuando retorna `None`

#### MODIFY
- **Cuándo se notifica**: 
  - **Éxito**: Cada vez que se ejecuta exitosamente una operación MODIFY
  - **Fallo**: Solo el primer fallo por ticket (evita notificaciones duplicadas en reintentos)
- **Formato del mensaje**:
  - **Éxito**: `"Ticket: XXXXX - MODIFY EXITOSO: SYMBOL ORDER_TYPE LOTS lots SL=XXX TP=YYY"`
  - **Fallo**: `"Ticket: XXXXX - MODIFY FALLO: (retcode, 'comment')"`
- **Ejemplos**: 
  - Éxito: `"Ticket: 40014799 - MODIFY EXITOSO: XAUUSD BUY 0.04 lots SL=4329.19 TP=4350.00"`
  - Fallo: `"Ticket: 40014799 - MODIFY FALLO: (10031, 'Request rejected due to absence of network connection')"`
  - Fallo: `"Ticket: 40014799 - MODIFY FALLO: (None, 'order_send retornó None')"`
- **Características**:
  - **Notificación de éxito**: Se envía cuando `retcode` es `TRADE_RETCODE_DONE` o `TRADE_RETCODE_NO_CHANGES`, se envía inmediatamente después de detectar el éxito, antes de retornar
  - **Notificación de fallo**: Usa un set en memoria (`notified_modify_tickets`) para rastrear tickets ya notificados
  - Verifica si el ticket está en el set antes de enviar fallo: `if ev.master_ticket not in notified_modify_tickets:`
  - Si no está en el set (fallo):
    - Envía la notificación push
    - Agrega el ticket al set: `notified_modify_tickets.add(ev.master_ticket)`
  - Si ya está en el set: No envía notificación de fallo (ya se notificó antes)
  - Remueve el ticket del set cuando:
    - Se modifica exitosamente (MODIFY OK): `notified_modify_tickets.discard(ev.master_ticket)`
    - Se elimina del CSV por cualquier motivo (ej: "No existe operacion abierta"): `notified_modify_tickets.discard(ev.master_ticket)`
  - Evita notificaciones duplicadas de fallo en múltiples reintentos del mismo ticket
  - Maneja tanto errores de `order_send` como cuando retorna `None`

### Gestión de Memoria
- **Sets en memoria**: `notified_close_tickets` y `notified_modify_tickets` (declarados como variables globales)
- **Limpieza automática**: Los tickets se remueven del set usando `discard()` cuando:
  - Se procesan exitosamente (CLOSE OK, MODIFY OK)
  - Se eliminan del CSV por cualquier motivo (NO_EXISTE)
- **Método de limpieza**: `notified_close_tickets.discard(ev.master_ticket)` y `notified_modify_tickets.discard(ev.master_ticket)`
- **Ventaja**: 
  - Evita consumo excesivo de memoria
  - Permite notificar nuevamente si el mismo ticket vuelve a fallar después de ser procesado
  - `discard()` es seguro (no lanza excepción si el elemento no existe)

### Flujo de Notificación

```
Operación ejecutada
    │
    ├─ OPEN → 
    │   ├─ Éxito → Notificar siempre: "Ticket: XXXXX - OPEN EXITOSO: ..."
    │   └─ Fallo → Notificar siempre: "Ticket: XXXXX - OPEN FALLO: ..."
    │
    ├─ CLOSE → 
    │   ├─ Éxito → Notificar siempre: "Ticket: XXXXX - CLOSE EXITOSO: ..."
    │   └─ Fallo → Verificar si ticket está en notified_close_tickets
    │       ├─ No está → Notificar y agregar al set
    │       └─ Está → No notificar (ya se notificó antes)
    │
    └─ MODIFY → 
        ├─ Éxito → Notificar siempre: "Ticket: XXXXX - MODIFY EXITOSO: ..."
        └─ Fallo → Verificar si ticket está en notified_modify_tickets
            ├─ No está → Notificar y agregar al set
            └─ Está → No notificar (ya se notificó antes)
```

### Ejemplos de Mensajes

**OPEN exitoso**:
```
Ticket: 40014799 - OPEN EXITOSO: XAUUSD BUY 0.04 lots
```

**OPEN fallido**:
```
Ticket: 40014799 - OPEN FALLO: (10004, 'Invalid price')
```

**CLOSE exitoso**:
```
Ticket: 40014799 - CLOSE EXITOSO: XAUUSD BUY 0.04 lots
```

**CLOSE fallido (primer intento)**:
```
Ticket: 40014799 - CLOSE FALLO: (10031, 'Request rejected due to absence of network connection')
```

**CLOSE fallido (reintento)**:
```
(No se envía notificación - ya fue notificado en el primer fallo)
```

**MODIFY fallido (primer intento)**:
```
Ticket: 40014799 - MODIFY FALLO: (10031, 'Request rejected due to absence of network connection')
```

**MODIFY fallido (reintento)**:
```
(No se envía notificación - ya fue notificado en el primer fallo)
```

### Detalles de Implementación

#### Función `send_push_notification(message: str) -> bool`
```python
def send_push_notification(message: str) -> bool:
    """
    Envía una notificación push usando SendNotification() de MetaTrader mediante archivo intermedio.
    
    La API de Python de MetaTrader5 NO incluye send_notification(). La función SendNotification()
    solo existe en MQL5. Por lo tanto:
    - Python escribe el mensaje en NotificationQueue.txt (Common\Files)
    - El EA MQL5 EnviarNotificacion.mq5 debe estar ejecutándose para leer el archivo
    - El EA MQL5 llama a SendNotification() y limpia el archivo
    
    Parámetros:
        message: Mensaje a enviar (máximo 255 caracteres)
    
    Retorno:
        True si se escribió exitosamente en el archivo, False si falló
    
    Nota: El EA EnviarNotificacion.mq5 debe estar ejecutándose como Expert Advisor en MT5
    para procesar las notificaciones.
    """
    try:
        # Truncar mensaje si es muy largo (límite de MT5)
        if len(message) > 255:
            message = message[:252] + "..."
        
        # Obtener ruta del archivo de notificaciones en Common\Files
        notification_path = common_files_csv_path(NOTIFICATION_FILE)
        
        # Escribir el mensaje en el archivo (el EA MQL5 lo leerá y enviará)
        # Usar modo binario y asegurar que el archivo se cierre correctamente
        with open(notification_path, "wb") as f:
            f.write(message.encode('utf-8'))
        
        # Forzar sincronización del sistema de archivos
        if hasattr(os, 'sync'):
            os.sync()
        
        print(f"[NOTIFICACION] Mensaje escrito en archivo para envío: {message}")
        print(f"[NOTIFICACION] Ruta del archivo: {notification_path}")
        return True
    except Exception as e:
        print(f"[ERROR NOTIFICACION] Excepción al escribir notificación en archivo: {e}")
        return False
```

**Características**:
- Trunca automáticamente mensajes largos a 255 caracteres (límite de MT5)
- Escribe el mensaje en `NotificationQueue.txt` ubicado en `Common\Files\`
- Usa modo binario para escribir UTF-8 correctamente
- Maneja errores de manera segura sin interrumpir el flujo principal
- Muestra mensajes informativos en consola con la ruta del archivo

#### EA MQL5 `EnviarNotificacion.mq5`

**Propósito**: Leer `NotificationQueue.txt` y enviar notificaciones usando `SendNotification()` de MQL5.

**Funcionamiento**:
1. Se ejecuta como Expert Advisor en cualquier gráfico de MT5
2. Configura un timer que verifica el archivo cada segundo (configurable)
3. En `OnTimer()`:
   - Intenta abrir `NotificationQueue.txt` usando `FILE_COMMON` (busca en `Common\Files\`)
   - Si el archivo no existe (error 5004), continúa sin mostrar error (comportamiento normal)
   - Si el archivo existe, lo lee en modo binario
   - Convierte los bytes UTF-8 a string
   - Verifica que las notificaciones estén habilitadas en el terminal
   - Llama a `SendNotification(message)`
   - Limpia el archivo escribiendo cadena vacía después de enviar exitosamente
   - Muestra logs informativos en la pestaña "Expert"

**Parámetros configurables**:
- `InpNotificationFile`: Nombre del archivo (por defecto: "NotificationQueue.txt")
- `InpTimerSeconds`: Intervalo de verificación en segundos (por defecto: 1)

**Manejo de errores**:
- Error 5004 (FILE_NOT_FOUND): No muestra error (archivo no existe todavía, comportamiento normal)
- Otros errores: Muestra mensaje de error en logs
- Si `SendNotification()` falla: Muestra error pero mantiene el mensaje en el archivo para reintento

**Requisitos**:
- Debe estar ejecutándose como Expert Advisor en MT5
- Las notificaciones deben estar habilitadas en el terminal (Configuración → Notificaciones)

#### Ubicación de las Notificaciones en el Código

**OPEN** (`open_clone()`):
- Se envía notificación de éxito cuando `retcode` es `TRADE_RETCODE_DONE` o `TRADE_RETCODE_PLACED`
- Se envía notificación de fallo cuando `order_send` retorna `None`
- Se envía notificación de fallo cuando `retcode` no es `TRADE_RETCODE_DONE` ni `TRADE_RETCODE_PLACED`
- Las notificaciones se envían inmediatamente después de detectar el resultado, antes de retornar

**CLOSE** (`close_clone()`):
- **Éxito**: Se envía siempre cuando `retcode` es `TRADE_RETCODE_DONE`, formato: `"Ticket: XXXXX - CLOSE EXITOSO: SYMBOL ORDER_TYPE LOTS lots"`
- **Fallo**: Se verifica si el ticket está en `notified_close_tickets` antes de enviar
  - Se envía cuando `order_send` retorna `None` (si no está en el set)
  - Se envía cuando `retcode` no es `TRADE_RETCODE_DONE` (si no está en el set)
  - Se agrega al set después de enviar la notificación de fallo

**MODIFY** (`modify_clone()`):
- **Éxito**: Se envía siempre cuando `retcode` es `TRADE_RETCODE_DONE` o `TRADE_RETCODE_NO_CHANGES`, formato: `"Ticket: XXXXX - MODIFY EXITOSO: SYMBOL ORDER_TYPE LOTS lots SL=XXX TP=YYY"`
- **Fallo**: Se verifica si el ticket está en `notified_modify_tickets` antes de enviar
  - Se envía cuando `order_send` retorna `None` o cuando `retcode` no es éxito (si no está en el set)
  - Se agrega al set después de enviar la notificación de fallo

**Limpieza de Sets** (`main_loop()`):
- Se remueven tickets de `notified_close_tickets` cuando CLOSE es exitoso o se elimina del CSV
- Se remueven tickets de `notified_modify_tickets` cuando MODIFY es exitoso o se elimina del CSV
- Se usa `discard()` para evitar excepciones si el elemento no existe

### Ventajas del Sistema
1. **Alertas inmediatas**: El usuario recibe notificaciones push en tiempo real cuando algo ocurre (éxito o fallo)
2. **Confirmación de operaciones**: Notifica cuando OPEN, CLOSE y MODIFY se ejecutan exitosamente, permitiendo verificar que las operaciones se están clonando correctamente y tener control total sobre todas las operaciones
3. **Sin spam**: Evita notificaciones duplicadas para CLOSE y MODIFY en múltiples reintentos
4. **Información completa**: Incluye número de error y mensaje descriptivo de MetaTrader para diagnóstico
5. **Gestión eficiente de memoria**: Limpia automáticamente los sets cuando los tickets se procesan exitosamente
6. **Manejo robusto de errores**: Trunca mensajes largos y maneja excepciones sin interrumpir el flujo principal
7. **Limpieza segura**: Usa `discard()` para evitar excepciones al remover elementos del set
8. **Sistema de pasarela robusto**: Usa archivo intermedio que permite que Python y MQL5 se comuniquen de forma asíncrona y confiable

---

## Versiones y Evolución

### V1
- Lectura del historial de MQL5 antes de ejecutar operaciones
- Timer de 3 segundos

### V2
- Optimizado para leer en 1 segundo
- Eliminadas lecturas al historial de MQL5 (solo verificación inicial)
- Timer reducido a 1 segundo

### V3
- Lectura exclusiva de UTF-8
- Formato simplificado de campos (`event_type;ticket;order_type;lots;symbol;sl;tp`)
- Manejo especial de error 10031 (red) para CLOSE y MODIFY
- Multiplicador de lotaje configurable al inicio
- Registro completo en histórico de todas las ejecuciones

### V4 (Actual)
- **Reconexión automática con MT5**: Sistema robusto de verificación y reconexión automática ante pérdida de conexión
- **Manejo específico de errores IPC**: Detección y reconexión automática para errores -10001 (IPC send failed)
- **Sistema de notificaciones push**: 
  - Sistema de pasarela mediante archivo intermedio (`NotificationQueue.txt`)
  - EA MQL5 `EnviarNotificacion.mq5` para leer archivo y enviar notificaciones usando `SendNotification()` de MQL5
  - Notificaciones de inicio del sistema
  - Notificaciones de éxito y fallo para OPEN
  - Notificaciones de fallo para CLOSE y MODIFY (solo primer fallo por ticket)
- **Gestión inteligente de notificaciones**: Evita notificaciones duplicadas para CLOSE y MODIFY en múltiples reintentos usando sets en memoria

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
8. **Reconecta automáticamente** con MT5 si se pierde la conexión (verificación antes de operaciones críticas)
9. **Notifica** mediante sistema de pasarela usando archivo intermedio y EA MQL5:
   - Notificación de inicio del sistema
   - Notificación de éxito y fallo para OPEN
   - Notificación de fallo para CLOSE y MODIFY (solo primer fallo por ticket, evita duplicados)

El script funciona como un puente entre sistemas de trading (MT4 → MT5) permitiendo la clonación automática de operaciones con configuración flexible de lotajes y manejo robusto de errores.

