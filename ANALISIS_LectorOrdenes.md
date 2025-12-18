# Análisis Funcional Detallado: LectorOrdenes.mq4

## Información General

- **Versión**: 1.6
- **Tipo**: Expert Advisor (EA) para MetaTrader 4
- **Propósito**: Monitorear operaciones en MT4 y escribir eventos (OPEN, CLOSE, MODIFY) en un archivo compartido
- **Archivo de salida**: `TradeEvents.txt` (en carpeta COMMON\Files)
- **Codificación**: UTF-8

---

## Arquitectura General

### Flujo Principal

1. **Inicialización** (`OnInit()`)
   - Configura arrays de estado
   - Crea archivo CSV si no existe
   - Configura timer

2. **Ejecución Periódica** (`OnTimer()`)
   - Cada `InpTimerSeconds` segundos (por defecto: 1 segundo)
   - Detecta cambios en órdenes abiertas
   - Escribe eventos al archivo compartido

3. **Finalización** (`OnDeinit()`)
   - Limpia recursos del timer

---

## Componentes Principales

### 1. Estructuras de Datos

#### `OrderState`
```mql4
struct OrderState
{
   int    ticket;  // Ticket de la orden
   double sl;      // Stop Loss
   double tp;      // Take Profit
}
```
**Propósito**: Almacenar el estado previo de cada orden para detectar cambios en SL/TP.

#### Arrays Globales
- `g_prevTickets[MAX_ORDERS]`: Lista de tickets abiertos en el ciclo anterior
- `g_prevOrders[MAX_ORDERS]`: Estado completo (SL/TP) de cada orden
- `g_prevCount`: Contador de órdenes previas
- `g_initialized`: Flag para evitar disparar eventos en el primer ciclo

---

### 2. Funciones de Utilidad

#### `TicketInArray(int ticket, int &arr[], int size)`
**Propósito**: Verificar si un ticket existe en un array.

**Parámetros**:
- `ticket`: Ticket a buscar
- `arr[]`: Array donde buscar
- `size`: Tamaño del array

**Retorno**: `true` si existe, `false` si no existe

**Uso**: Verificar si un ticket ya estaba en el ciclo anterior (para detectar nuevas aperturas) o si ya no está (para detectar cierres).

---

#### `FindOrderStateIndex(int ticket, OrderState &states[], int size)`
**Propósito**: Encontrar el índice de un ticket en el array de estados previos.

**Parámetros**:
- `ticket`: Ticket a buscar
- `states[]`: Array de estados previos
- `size`: Tamaño del array

**Retorno**: Índice del ticket si existe, `-1` si no existe

**Uso**: Localizar el estado previo de una orden para comparar SL/TP y detectar modificaciones.

---

#### `DoubleChanged(double val1, double val2)`
**Propósito**: Comparar dos valores double con tolerancia para evitar falsos positivos por redondeo.

**Parámetros**:
- `val1`: Primer valor
- `val2`: Segundo valor

**Retorno**: `true` si los valores difieren más de la tolerancia (0.00001), `false` si son iguales dentro de la tolerancia

**Uso**: Detectar cambios reales en SL/TP, ignorando diferencias mínimas por redondeo.

**Tolerancia**: 0.00001 (1 punto para pares de 5 decimales)

---

### 3. Funciones de Codificación UTF-8

#### `StringToUTF8Bytes(string str, uchar &bytes[])`
**Propósito**: Convertir un string Unicode (UTF-16 de MQL4) a bytes UTF-8.

**Parámetros**:
- `str`: String a convertir
- `bytes[]`: Array de bytes de salida (se redimensiona automáticamente)

**Algoritmo**:
1. **ASCII (0x00-0x7F)**: 1 byte directo
2. **2 bytes UTF-8 (0x80-0x7FF)**: 
   - Byte 1: `110xxxxx` (0xC0 | (ch >> 6))
   - Byte 2: `10xxxxxx` (0x80 | (ch & 0x3F))
3. **3 bytes UTF-8 (0x800-0xFFFF)**:
   - Byte 1: `1110xxxx` (0xE0 | (ch >> 12))
   - Byte 2: `10xxxxxx` (0x80 | ((ch >> 6) & 0x3F))
   - Byte 3: `10xxxxxx` (0x80 | (ch & 0x3F))

**Uso**: Convertir líneas de texto antes de escribir al archivo en modo binario.

---

### 4. Funciones de Escritura de Archivo

#### `AppendEventToCSV(...)`
**Propósito**: Escribir una línea de evento al archivo `TradeEvents.txt` en UTF-8.

**Parámetros**:
- `eventType`: Tipo de evento ("OPEN", "CLOSE", "MODIFY")
- `ticket`: Ticket maestro (del sistema origen)
- `orderTypeStr`: Tipo de orden ("BUY", "SELL", "BUYLIMIT", "SELLLIMIT", "BUYSTOP", "SELLSTOP")
- `lots`: Volumen de la operación
- `symbol`: Símbolo del instrumento
- `sl`: Stop Loss (0.0 si no tiene)
- `tp`: Take Profit (0.0 si no tiene)

**Formato de línea**:
```
event_type;ticket;order_type;lots;symbol;sl;tp
```

**Ejemplo**:
```
OPEN;39924291;BUY;0.04;XAUUSD;4288.04;4290.00
```

**Proceso**:
1. Abre archivo en modo binario (`FILE_BIN`) con permisos de lectura/escritura compartida
2. Se posiciona al final del archivo (`FileSeek(handle, 0, SEEK_END)`)
3. Construye la línea con delimitador `;`
4. Convierte la línea a UTF-8 usando `StringToUTF8Bytes()`
5. Escribe los bytes UTF-8 al archivo
6. Escribe salto de línea (`\n` = 0x0A)
7. Cierra el archivo

**Características**:
- **Codificación**: UTF-8 (sin BOM)
- **Delimitador**: Punto y coma (`;`)
- **Salto de línea**: `\n` (LF, 0x0A)
- **Ubicación**: `COMMON\Files\TradeEvents.txt` (compartido entre todos los MT4/MT5)

---

#### `InitCSVIfNeeded()`
**Propósito**: Crear el archivo `TradeEvents.txt` con la cabecera si no existe.

**Proceso**:
1. Intenta abrir el archivo en modo lectura
2. Si existe → cierra y retorna (no hace nada)
3. Si no existe → crea el archivo y escribe la cabecera

**Cabecera**:
```
event_type;ticket;order_type;lots;symbol;sl;tp
```

**Codificación**: UTF-8 (sin BOM)

---

### 5. Funciones de Inicialización y Finalización

#### `OnInit()`
**Propósito**: Inicializar el EA cuando se carga en el gráfico.

**Proceso**:
1. Imprime información de inicialización
2. Inicializa arrays globales:
   - `g_prevTickets[]` → todos a 0
   - `g_prevOrders[]` → todos los tickets a 0, SL/TP a 0.0
   - `g_prevCount` → 0
   - `g_initialized` → false
3. Llama a `InitCSVIfNeeded()` para crear el archivo si no existe
4. Configura el timer con `EventSetTimer(InpTimerSeconds)`
5. Retorna `INIT_SUCCEEDED`

**Parámetros de entrada**:
- `InpCSVFileName`: Nombre del archivo (por defecto: "TradeEvents.txt")
- `InpTimerSeconds`: Intervalo del timer en segundos (por defecto: 1)

---

#### `OnDeinit(const int reason)`
**Propósito**: Limpiar recursos cuando el EA se desactiva.

**Proceso**:
1. Detiene el timer con `EventKillTimer()`
2. Imprime mensaje de finalización con el motivo

**Motivos comunes**:
- `REASON_REMOVE`: EA eliminado del gráfico
- `REASON_CHARTCHANGE`: Cambio de gráfico
- `REASON_PARAMETERS`: Cambio de parámetros
- `REASON_ACCOUNT`: Cambio de cuenta
- `REASON_TEMPLATE`: Aplicación de plantilla
- `REASON_INITFAILED`: Fallo en inicialización
- `REASON_CLOSE`: Terminal cerrado

---

### 6. Función Principal de Procesamiento

#### `OnTimer()`
**Propósito**: Procesar cambios en órdenes cada `InpTimerSeconds` segundos.

**Frecuencia**: Cada 1 segundo (configurable)

**Proceso detallado**:

##### **Fase 1: Construir lista de tickets actuales**
```mql4
int total = OrdersTotal();
for(int i = 0; i < total && curCount < MAX_ORDERS; i++)
{
   if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      continue;
   curTickets[curCount] = OrderTicket();
   curCount++;
}
```
- Recorre todas las órdenes abiertas (`MODE_TRADES`)
- Almacena los tickets en `curTickets[]`
- Máximo: `MAX_ORDERS` (500)

---

##### **Fase 1.5: Primera ejecución - Registrar órdenes ya abiertas**
```mql4
if(!g_initialized)
{
   // Para cada orden abierta actualmente:
   // 1. Escribe evento OPEN al CSV
   // 2. Guarda estado inicial (SL/TP) en g_prevOrders[]
   // 3. Guarda ticket en g_prevTickets[]
   g_initialized = true;
   return; // No procesa más en el primer ciclo
}
```

**Propósito**: Evitar escribir eventos OPEN para órdenes que ya estaban abiertas antes de iniciar el EA.

**Proceso**:
1. Para cada orden abierta:
   - Determina el tipo de orden (BUY/SELL/etc.)
   - Escribe evento `OPEN` al CSV con los datos actuales
   - Guarda el ticket y estado (SL/TP) en los arrays previos
2. Marca `g_initialized = true`
3. Retorna (no procesa más en este ciclo)

**Ejemplo de evento escrito**:
```
OPEN;39924291;BUY;0.04;XAUUSD;4288.04;4290.00
```

---

##### **Fase 2: Detectar nuevas APERTURAS**
```mql4
for(int j = 0; j < curCount; j++)
{
   int t = curTickets[j];
   if(!TicketInArray(t, g_prevTickets, g_prevCount))
   {
      // Nueva orden detectada
      // Escribe evento OPEN
   }
}
```

**Lógica**:
- Si un ticket está en `curTickets[]` pero NO está en `g_prevTickets[]` → es una nueva apertura
- Escribe evento `OPEN` al CSV

**Datos escritos**:
- `eventType`: "OPEN"
- `ticket`: Ticket maestro
- `orderTypeStr`: BUY/SELL/etc.
- `lots`: Volumen
- `symbol`: Símbolo
- `sl`: Stop Loss actual
- `tp`: Take Profit actual

---

##### **Fase 2.5: Detectar MODIFICACIONES de SL/TP**
```mql4
for(int mod = 0; mod < curCount; mod++)
{
   int t = curTickets[mod];
   if(TicketInArray(t, g_prevTickets, g_prevCount))
   {
      // Orden que ya existía antes
      // Comparar SL/TP actual vs previo
      if(slChanged || tpChanged)
      {
         // Escribe evento MODIFY
      }
   }
}
```

**Lógica**:
1. Solo revisa órdenes que ya existían antes (no nuevas)
2. Busca el estado previo usando `FindOrderStateIndex()`
3. Compara SL/TP actual vs previo usando `DoubleChanged()` (con tolerancia)
4. Si hay cambio → escribe evento `MODIFY`

**Datos escritos**:
- `eventType`: "MODIFY"
- `ticket`: Ticket maestro
- `orderTypeStr`: BUY/SELL/etc.
- `lots`: Volumen actual
- `symbol`: Símbolo
- `sl`: **Nuevo** Stop Loss
- `tp`: **Nuevo** Take Profit

**Tolerancia**: 0.00001 (evita falsos positivos por redondeo)

**Actualización inmediata**: Después de escribir MODIFY, actualiza `g_prevOrders[]` con los nuevos valores para evitar escribir múltiples eventos MODIFY.

---

##### **Fase 3: Detectar CIERRES**
```mql4
for(int p = 0; p < g_prevCount; p++)
{
   int oldTicket = g_prevTickets[p];
   if(!TicketInArray(oldTicket, curTickets, curCount))
   {
      // Ticket que estaba antes pero ya no está
      // Buscar en historial para obtener datos de cierre
      if(OrderSelect(oldTicket, SELECT_BY_TICKET, MODE_HISTORY))
      {
         // Escribe evento CLOSE
      }
   }
}
```

**Lógica**:
- Si un ticket está en `g_prevTickets[]` pero NO está en `curTickets[]` → se cerró
- Busca la orden en el historial (`MODE_HISTORY`) para obtener datos completos
- Escribe evento `CLOSE` al CSV

**Datos escritos**:
- `eventType`: "CLOSE"
- `ticket`: Ticket maestro
- `orderTypeStr`: BUY/SELL/etc.
- `lots`: Volumen cerrado
- `symbol`: Símbolo
- `sl`: Stop Loss al momento del cierre
- `tp`: Take Profit al momento del cierre

**Nota**: Los campos `close_price`, `close_time` y `profit` ya no se escriben en la versión 1.6 (formato simplificado).

---

##### **Fase 4: Actualizar lista previa**
```mql4
g_prevCount = curCount;
for(int m = 0; m < curCount; m++)
{
   g_prevTickets[m] = curTickets[m];
   // Actualizar SL/TP en g_prevOrders[]
}
```

**Propósito**: Preparar el estado para el próximo ciclo del timer.

**Proceso**:
1. Actualiza `g_prevCount` con el número actual de órdenes
2. Copia todos los tickets actuales a `g_prevTickets[]`
3. Actualiza `g_prevOrders[]` con los SL/TP actuales de cada orden

---

## Tipos de Eventos Generados

### 1. OPEN
**Cuándo se genera**:
- Primera ejecución: Para todas las órdenes ya abiertas
- Ejecuciones posteriores: Cuando se detecta una nueva orden abierta

**Formato**:
```
OPEN;ticket;order_type;lots;symbol;sl;tp
```

**Ejemplo**:
```
OPEN;39924291;BUY;0.04;XAUUSD;4288.04;4290.00
```

---

### 2. CLOSE
**Cuándo se genera**:
- Cuando una orden que estaba abierta ya no aparece en la lista de órdenes abiertas

**Formato**:
```
CLOSE;ticket;order_type;lots;symbol;sl;tp
```

**Ejemplo**:
```
CLOSE;39924291;BUY;0.04;XAUUSD;4288.04;4290.00
```

**Nota**: Los datos (lots, sl, tp) son los que tenía la orden al momento del cierre (obtenidos del historial).

---

### 3. MODIFY
**Cuándo se genera**:
- Cuando se detecta un cambio en SL o TP de una orden que ya existía

**Formato**:
```
MODIFY;ticket;order_type;lots;symbol;sl;tp
```

**Ejemplo**:
```
MODIFY;39924291;BUY;0.04;XAUUSD;4290.00;4295.00
```

**Nota**: Los valores de `sl` y `tp` son los **nuevos** valores después del cambio.

---

## Tipos de Órdenes Soportados

El EA detecta y procesa los siguientes tipos de órdenes:

| Tipo MT4 | String Escrito |
|----------|----------------|
| `OP_BUY` | "BUY" |
| `OP_SELL` | "SELL" |
| `OP_BUYLIMIT` | "BUYLIMIT" |
| `OP_SELLLIMIT` | "SELLLIMIT" |
| `OP_BUYSTOP` | "BUYSTOP" |
| `OP_SELLSTOP` | "SELLSTOP" |
| Otros | "OTRO" |

---

## Manejo de Archivos

### Ubicación
- **Carpeta**: `COMMON\Files\`
- **Ruta completa típica**: `C:\Users\[Usuario]\AppData\Roaming\MetaQuotes\Terminal\Common\Files\TradeEvents.txt`
- **Compartido**: Sí, accesible por todos los MT4 y MT5 en el mismo terminal

### Modo de Apertura
```mql4
FILE_BIN | FILE_READ | FILE_WRITE | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE
```

**Explicación**:
- `FILE_BIN`: Modo binario (permite escribir bytes UTF-8)
- `FILE_READ | FILE_WRITE`: Permite leer y escribir
- `FILE_COMMON`: Carpeta común (compartida)
- `FILE_SHARE_READ | FILE_SHARE_WRITE`: Permite acceso simultáneo desde otros procesos

### Estrategia de Escritura
- **Modo**: Append (añadir al final)
- **Método**: `FileSeek(handle, 0, SEEK_END)` antes de escribir
- **Ventaja**: Múltiples instancias pueden escribir simultáneamente sin conflictos

---

## Codificación UTF-8

### ¿Por qué UTF-8?
- **Estándar universal**: Compatible con todos los sistemas y herramientas
- **Eficiencia**: Ocupa menos espacio que UTF-16 para texto ASCII
- **Compatibilidad**: Python y MQL5 pueden leerlo fácilmente

### Implementación
- **Conversión manual**: `StringToUTF8Bytes()` convierte UTF-16 (MQL4) → UTF-8
- **Escritura binaria**: `FileWriteArray()` escribe bytes directamente
- **Sin BOM**: No se escribe BOM UTF-8 (EF BB BF)

### Caracteres Especiales
- **ASCII (0-127)**: 1 byte
- **Caracteres extendidos (128-2047)**: 2 bytes UTF-8
- **Caracteres Unicode (2048-65535)**: 3 bytes UTF-8

---

## Limitaciones y Consideraciones

### Limitación de Órdenes
- **Máximo**: `MAX_ORDERS = 500`
- **Razón**: Arrays de tamaño fijo para eficiencia
- **Consecuencia**: Si hay más de 500 órdenes, las adicionales no se procesan

### Tolerancia de Cambios SL/TP
- **Valor**: 0.00001
- **Propósito**: Evitar falsos positivos por redondeo de punto flotante
- **Consecuencia**: Cambios menores a 0.00001 no se detectan como MODIFY

### Primera Ejecución
- **Comportamiento**: Escribe eventos OPEN para todas las órdenes ya abiertas
- **Razón**: Sincronizar el estado inicial
- **Consecuencia**: Puede generar muchos eventos OPEN al iniciar

### Detección de Cierres
- **Método**: Comparación de listas (tickets que estaban y ya no están)
- **Dependencia**: Requiere acceso al historial (`MODE_HISTORY`)
- **Limitación**: Si el historial no está disponible, no se pueden obtener datos del cierre

---

## Flujo de Datos

```
MT4 Terminal
    │
    ├─ OnTimer() (cada 1 segundo)
    │   │
    │   ├─ Lee órdenes abiertas (MODE_TRADES)
    │   │
    │   ├─ Compara con estado previo
    │   │   ├─ Nuevas → OPEN
    │   │   ├─ Modificadas (SL/TP) → MODIFY
    │   │   └─ Cerradas → CLOSE
    │   │
    │   └─ Escribe eventos al archivo
    │
    └─ TradeEvents.txt (UTF-8)
        │
        └─ Leído por ClonadorMQ5.py / ClonadorMQ5.mq5
```

---

## Ejemplo de Archivo Generado

```
event_type;ticket;order_type;lots;symbol;sl;tp
OPEN;39924291;BUY;0.04;XAUUSD;4288.04;4290.00
OPEN;39924292;SELL;0.02;EURUSD;1.0850;1.0800
MODIFY;39924291;BUY;0.04;XAUUSD;4290.00;4295.00
CLOSE;39924292;SELL;0.02;EURUSD;1.0850;1.0800
```

---

## Parámetros Configurables

### `InpCSVFileName`
- **Tipo**: `string`
- **Valor por defecto**: `"TradeEvents.txt"`
- **Propósito**: Nombre del archivo donde se escriben los eventos
- **Ubicación**: Carpeta COMMON\Files

### `InpTimerSeconds`
- **Tipo**: `int`
- **Valor por defecto**: `1`
- **Propósito**: Intervalo en segundos entre ejecuciones de `OnTimer()`
- **Rango recomendado**: 1-5 segundos
- **Consideración**: Valores muy bajos pueden aumentar la carga del sistema

---

## Optimizaciones Implementadas

### 1. Uso de `OnTimer()` en lugar de `OnTick()`
- **Ventaja**: No se ejecuta en cada tick de precio
- **Eficiencia**: Reduce carga del sistema significativamente
- **Adecuado para**: Monitoreo periódico (no necesita tiempo real)

### 2. Arrays de tamaño fijo
- **Ventaja**: Evita redimensionamiento dinámico (más rápido)
- **Limitación**: Máximo 500 órdenes

### 3. Comparación con tolerancia
- **Ventaja**: Evita falsos positivos por redondeo
- **Eficiencia**: Reduce escrituras innecesarias al archivo

### 4. Escritura en modo append
- **Ventaja**: Múltiples instancias pueden escribir simultáneamente
- **Eficiencia**: No necesita leer todo el archivo para añadir una línea

---

## Casos de Uso

### Caso 1: Monitoreo de una cuenta MT4
- **Escenario**: Un EA en un gráfico monitorea todas las operaciones de la cuenta
- **Resultado**: Archivo `TradeEvents.txt` con todos los eventos de la cuenta

### Caso 2: Múltiples instancias
- **Escenario**: Varios EAs en diferentes gráficos escriben al mismo archivo
- **Resultado**: Todos los eventos se acumulan en el mismo archivo (modo append)

### Caso 3: Clonación de operaciones
- **Escenario**: `ClonadorMQ5.py` o `ClonadorMQ5.mq5` leen el archivo y clonan operaciones
- **Resultado**: Sistema de clonación automática entre MT4 y MT5

---

## Dependencias

### MetaTrader 4
- **Versión mínima**: MT4 Build 600+
- **Funciones utilizadas**:
  - `OrdersTotal()`
  - `OrderSelect()`
  - `OrderTicket()`
  - `OrderType()`
  - `OrderLots()`
  - `OrderSymbol()`
  - `OrderStopLoss()`
  - `OrderTakeProfit()`
  - `FileOpen()`
  - `FileWriteArray()`
  - `FileSeek()`
  - `FileClose()`
  - `EventSetTimer()`
  - `EventKillTimer()`

### Sistema Operativo
- **Windows**: Requerido (rutas COMMON\Files)
- **Permisos**: Escritura en carpeta común de MetaTrader

---

## Errores Potenciales y Manejo

### Error al abrir archivo
```mql4
if(handle == INVALID_HANDLE)
{
   Print("ERROR al abrir TXT '", InpCSVFileName, "' err=", GetLastError());
   return;
}
```
**Manejo**: Imprime error y retorna (no bloquea el EA)

### Error al crear archivo
```mql4
if(handle == INVALID_HANDLE)
{
   Print("ERROR al crear TXT '", InpCSVFileName, "' err=", GetLastError());
   return;
}
```
**Manejo**: Imprime error y retorna (el EA continúa funcionando)

### Orden no seleccionable
```mql4
if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
   continue; // Salta esta orden
```
**Manejo**: Continúa con la siguiente orden (no bloquea)

---

## Versiones y Evolución

### v1.1
- Añade columnas SL y TP

### v1.2
- Detecta cambios en SL/TP y escribe eventos MODIFY

### v1.3
- Elimina campos magic y comment
- Usa FILE_TXT

### v1.4
- Escribe en UTF-8 usando FILE_BIN
- Conversión manual UTF-16 → UTF-8

### v1.5
- Cambia OnTick() por OnTimer() para mayor eficiencia
- Timer configurable

### v1.6
- Simplifica campos a: `event_type;ticket;order_type;lots;symbol;sl;tp`
- Elimina campos: open_price, open_time, close_price, close_time, profit

---

## Conclusión

`LectorOrdenes.mq4` es un EA eficiente y robusto que:

1. **Monitorea** operaciones en MT4 de forma periódica (cada 1 segundo)
2. **Detecta** cambios (aperturas, cierres, modificaciones de SL/TP)
3. **Escribe** eventos en formato CSV UTF-8 a un archivo compartido
4. **Permite** que otros sistemas (Python, MQL5) lean y procesen estos eventos
5. **Optimiza** el rendimiento usando timer en lugar de OnTick()
6. **Maneja** errores de forma robusta sin bloquear el EA

El archivo generado (`TradeEvents.txt`) sirve como punto de integración entre MT4 y sistemas externos para clonación automática de operaciones.

