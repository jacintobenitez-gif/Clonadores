# Análisis: Solución al Problema de Pérdida de Comandos CLOSE

**Fecha**: 2026-01-13  
**Versión**: 1.0  
**Estado**: Aprobado para implementación

---

## 1. Contexto del Problema

### 1.1 Síntomas observados

- El Worker 3037589 muestra "4 operaciones en memoria" cuando solo hay 1 abierta realmente
- Los tickets 17889609, 17889312, 17889270 no se cerraron en la cuenta 3037589
- El archivo `historico_clonacion.csv` marcó estos cierres como "OK"
- El archivo `historico_WORKER_3037589.csv` NO tiene registro de CLOSE para estos tickets
- La cola `cola_WORKER_3037589.csv` está vacía

### 1.2 Causa raíz identificada

**Race condition entre Distribuidor y Worker al acceder al mismo archivo.**

Secuencia del fallo:

```
T0: Worker lee cola_WORKER_XXX.csv (snapshot con N comandos)
T1: Distribuidor hace append de nuevo comando CLOSE
T2: Worker procesa los N comandos del snapshot
T3: Worker reescribe (TRUNCA) la cola con comandos pendientes
    → El comando CLOSE añadido en T1 SE PIERDE
```

El mecanismo "defensivo" de re-lectura (líneas 961-995 de WorkerV2.mq4) no es suficiente porque existe una ventana de tiempo entre la re-lectura y la reescritura donde el Distribuidor puede escribir.

### 1.3 Por qué unas órdenes cerraron y otras no

Los cierres llegaron en ráfaga (~1 segundo entre ellos):

| Ticket | Hora llegada a cola | Resultado |
|--------|---------------------|-----------|
| 17889153 | 20:15:32.897 | ✅ CLOSE OK |
| 17889270 | 20:15:33.160 | ❌ Perdido |
| 17889281 | 20:15:33.674 | ✅ CLOSE OK |
| 17889312 | 20:15:34.190 | ❌ Perdido |
| 17889609 | 20:15:34.192 | ❌ Perdido |

Los comandos que llegaron mientras el Worker estaba reescribiendo la cola se perdieron.

---

## 2. Solución Propuesta

### 2.1 Principio fundamental

**Separar archivos por proceso escritor:**

| Archivo | Quién escribe | Operación |
|---------|---------------|-----------|
| `cola_WORKER_XXX.csv` | Solo Distribuidor | Append |
| `estados_WORKER_XXX.csv` | Solo Worker | Append |

**Ningún proceso trunca archivos durante el horario de trading.**

### 2.2 Beneficios

1. **Elimina race condition**: Cada proceso escribe en su propio archivo
2. **Append es atómico**: El sistema de archivos garantiza integridad de líneas completas
3. **Recuperación ante caídas**: Los estados persisten y permiten reconstruir reintentos
4. **Trazabilidad mejorada**: Se puede saber el resultado real de cada comando

---

## 3. Diseño Detallado

### 3.1 Formato de archivos

#### cola_WORKER_XXX.csv (sin cambios)

```csv
OPEN;17889270;BUY;0.01;GOLD;0;0
MODIFY;17889270;4600;0
CLOSE;17889270;;;;;;
```

**Campos:** `event_type;ticketMaster;order_type;lots;symbol;sl;tp`

#### estados_WORKER_XXX.csv (NUEVO)

```csv
17889270;OPEN;2;2026.01.12 19:16:20;OK;103150965
17889270;MODIFY;2;2026.01.12 19:45:00;OK;
17889270;CLOSE;2;2026.01.12 20:15:33;OK;
17889312;CLOSE;1;2026.01.12 20:15:34;RETRY;ERR_134
```

**Campos:** `ticketMaster;event_type;estado;timestamp;resultado;extra`

**Valores de estado:**
- `0` = Pendiente (procesado por Distribuidor, no usado en este archivo)
- `1` = En proceso (Worker intentando, política de reintentos activa)
- `2` = Completado (éxito o fallo definitivo)

**Valores de resultado:**
- `OK` = Ejecutado exitosamente
- `RETRY` = En reintentos (estado=1)
- `ERR_XXX` = Fallo definitivo con código de error (estado=2)

**Campo extra:**
- Para OPEN exitoso: ticketWorker generado
- Para errores: descripción del error

### 3.2 Flujo del Distribuidor

#### Durante el día (cambios mínimos)

```python
def process_spool_event(event_path, config):
    # Sin cambios en la lógica principal
    # Sigue haciendo append a cola_WORKER_XXX.csv
    # Sigue registrando en historico_clonacion.csv (significa "llegó a la cola")
    pass
```

#### Purga nocturna (00:01) - NUEVO

```python
def purga_nocturna(config):
    for worker_id in config.worker_ids:
        cola_path = f"cola_WORKER_{worker_id}.csv"
        estados_path = f"estados_WORKER_{worker_id}.csv"
        
        # 1. Bloquear archivos
        renombrar(cola_path, cola_path.replace('.csv', '.lck'))
        renombrar(estados_path, estados_path.replace('.csv', '.lck'))
        
        # 2. Leer ambos archivos
        comandos = leer_csv(cola_path.lck)
        estados = leer_csv(estados_path.lck)
        
        # 3. Construir mapa de estados por (ticketMaster, event_type)
        estados_map = {}
        for linea in estados:
            key = (linea.ticketMaster, linea.event_type)
            estados_map[key] = linea.estado  # Último estado prevalece
        
        # 4. Filtrar comandos: mantener solo los NO completados
        comandos_pendientes = []
        for cmd in comandos:
            key = (cmd.ticketMaster, cmd.event_type)
            if estados_map.get(key) != 2:  # No completado
                comandos_pendientes.append(cmd)
        
        # 5. Filtrar estados: mantener solo estado 0 y 1
        estados_activos = [e for e in estados if e.estado != 2]
        
        # 6. Escribir archivos limpios
        escribir_csv(cola_path, comandos_pendientes)
        escribir_csv(estados_path, estados_activos)
        
        # 7. Desbloquear (borrar .lck)
        borrar(cola_path.lck)
        borrar(estados_path.lck)
```

### 3.3 Flujo del Worker

#### OnInit() - Recuperación tras caída

```mql4
int OnInit()
{
    // 1. Cargar posiciones abiertas de MT4 (sin cambios)
    LoadOpenPositionsFromMT4();
    
    // 2. NUEVO: Reconstruir arrays de reintentos desde estados
    ReconstruirReintentosDesdeEstados();
    
    // 3. Resto sin cambios
    DisplayOpenLogsInChart();
    EventSetTimer(InpTimerSeconds);
    return INIT_SUCCEEDED;
}

void ReconstruirReintentosDesdeEstados()
{
    // Leer estados_WORKER_XXX.csv
    // Para cada línea con estado=1:
    //   - Si event_type=MODIFY → agregar a g_notifModifyTickets
    //   - Si event_type=CLOSE → agregar a g_notifCloseTickets
}
```

#### OnTimer() - Procesamiento principal

```mql4
void OnTimer()
{
    // 1. Si existe .lck, es purga nocturna → salir
    if(FileIsExist(g_queueFile + ".lck", FILE_COMMON))
        return;
    
    // 2. Cargar estados procesados en memoria
    // Map: (ticketMaster, event_type) → estado
    CargarEstadosProcesados();
    
    // 3. Leer cola completa (sin cambios en lectura)
    string lines[];
    int total = ReadQueue(g_queueFile, lines);
    
    // 4. Procesar cada línea
    for(int i = startIdx; i < total; i++)
    {
        // Parsear línea (sin cambios)
        if(!ParseLine(lines[i], eventType, ticketMaster, ...))
            continue;
        
        // Construir key para buscar estado
        string key = IntegerToString(ticketMaster) + "_" + eventType;
        int estadoActual = ObtenerEstado(key);
        
        // Si ya completado (estado=2), saltar
        if(estadoActual == 2)
            continue;
        
        // Si en proceso (estado=1), es reintento
        if(estadoActual == 1)
        {
            ProcesarReintento(eventType, ticketMaster, ...);
            continue;
        }
        
        // Estado=0 o no existe → nuevo comando
        if(eventType == "OPEN")
            ProcesarOpen(ticketMaster, ...);
        else if(eventType == "MODIFY")
            ProcesarModify(ticketMaster, ...);
        else if(eventType == "CLOSE")
            ProcesarClose(ticketMaster, ...);
    }
    
    // 5. ELIMINADO: Ya no hay RewriteQueue
    // 6. ELIMINADO: Ya no hay merge defensivo
}
```

#### Funciones de procesamiento (ejemplo CLOSE)

```mql4
void ProcesarClose(int ticketMaster, long workerReadTimeMs)
{
    int idx = FindOpenLog(ticketMaster);
    
    if(idx < 0)
    {
        // No está en memoria, verificar si ya cerrada
        int historyTicket = FindOrderInHistory(ticketMaster);
        if(historyTicket >= 0)
        {
            // Ya cerrada por SL/TP/manual
            AppendEstado(ticketMaster, "CLOSE", 2, "OK_YA_CERRADA", "");
        }
        else
        {
            // No encontrada en ningún lado
            AppendEstado(ticketMaster, "CLOSE", 2, "ERR_NO_ENCONTRADA", "");
        }
        return;
    }
    
    int ticketWorker = g_openLogs[idx].ticketWorker;
    
    // Intentar cerrar
    RefreshRates();
    bool ok = OrderClose(ticketWorker, OrderLots(), closePrice, InpSlippage, clrNONE);
    
    if(ok)
    {
        AppendEstado(ticketMaster, "CLOSE", 2, "OK", DoubleToString(profit, 2));
        RemoveOpenLog(ticketMaster);
        DisplayOpenLogsInChart();
    }
    else
    {
        int err = GetLastError();
        // Primera vez: marcar estado=1 y agregar a reintentos
        AppendEstado(ticketMaster, "CLOSE", 1, "RETRY", "ERR_" + IntegerToString(err));
        AddTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
    }
}
```

#### Nueva función: AppendEstado

```mql4
void AppendEstado(int ticketMaster, string eventType, int estado, string resultado, string extra)
{
    string estadosFile = CommonRelative("estados_WORKER_" + g_workerId + ".csv");
    
    int h = FileOpen(estadosFile, FILE_BIN|FILE_READ|FILE_WRITE|FILE_COMMON|FILE_SHARE_WRITE);
    if(h == INVALID_HANDLE)
    {
        // Crear archivo si no existe
        h = FileOpen(estadosFile, FILE_BIN|FILE_WRITE|FILE_COMMON);
    }
    else
    {
        FileSeek(h, 0, SEEK_END);
    }
    
    if(h == INVALID_HANDLE)
    {
        Print("ERROR: No se pudo abrir estados: ", estadosFile);
        return;
    }
    
    string timestamp = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
    string line = IntegerToString(ticketMaster) + ";" +
                  eventType + ";" +
                  IntegerToString(estado) + ";" +
                  timestamp + ";" +
                  resultado + ";" +
                  extra;
    
    uchar utf8[];
    StringToUTF8Bytes(line, utf8);
    FileWriteArray(h, utf8);
    uchar nl[] = {0x0A};
    FileWriteArray(h, nl);
    FileClose(h);
}
```

---

## 4. Casos de Recuperación

### 4.1 EA crashea después de ejecutar OrderClose pero antes de AppendEstado

**Situación:** La orden se cerró en MT4 pero no se registró en estados_XXX.csv

**Recuperación:**
1. OnInit llama a `LoadOpenPositionsFromMT4()` → la orden ya no está
2. OnInit llama a `ReconstruirReintentosDesdeEstados()` → no hay estado=1 para este ticket
3. OnTimer lee la cola → encuentra comando CLOSE
4. `ProcesarClose()` → `FindOpenLog()` retorna -1 (no está en memoria)
5. `FindOrderInHistory()` → encuentra la orden cerrada
6. Registra `estado=2, resultado=OK_YA_CERRADA`

**Resultado:** ✅ No se pierde, se registra como cerrada

### 4.2 EA crashea durante reintentos de CLOSE

**Situación:** Hay un estado=1 para un CLOSE que estaba reintentando

**Recuperación:**
1. OnInit llama a `ReconstruirReintentosDesdeEstados()`
2. Encuentra línea con estado=1 y event_type=CLOSE
3. Agrega ticketMaster a `g_notifCloseTickets`
4. OnTimer continúa reintentando

**Resultado:** ✅ Reintentos continúan donde quedaron

### 4.3 Distribuidor escribe mientras Worker procesa

**Situación:** Distribuidor hace append a cola mientras Worker está en OnTimer

**Recuperación:**
- El Worker lee la cola al inicio del ciclo
- Si el comando llegó después, lo verá en el próximo ciclo
- Ningún archivo se trunca → nada se pierde

**Resultado:** ✅ El comando se procesa en el siguiente ciclo

### 4.4 Purga nocturna mientras Worker está activo

**Situación:** Son las 00:01, Distribuidor inicia purga

**Recuperación:**
1. Distribuidor renombra archivos a .lck
2. Worker detecta .lck en OnTimer → `return` inmediato
3. Distribuidor completa purga → renombra de vuelta a .csv
4. Worker continúa normalmente en siguiente ciclo

**Resultado:** ✅ Worker espera a que termine la purga

---

## 5. Eliminación de Código

### 5.1 Código a eliminar en WorkerV2.mq4

```mql4
// ELIMINAR: Función RewriteQueue completa (líneas 409-427)

// ELIMINAR: Bloque de rewrite defensivo en OnTimer (líneas 961-995)
// Este bloque:
//   string merged[];
//   int mergedCount = 0;
//   ... merge logic ...
//   RewriteQueue(g_queueFile, merged, mergedCount);

// ELIMINAR: Lógica de "remaining" array
//   string remaining[];
//   int remainingCount = 0;
//   ... ArrayResize(remaining, ...) ...
```

### 5.2 Funcionalidad a mantener

- `ReadQueue()` - Se sigue usando para leer la cola
- `ParseLine()` - Sin cambios
- `FindOpenLog()`, `FindOpenOrder()`, `FindOrderInHistory()` - Sin cambios
- Toda la lógica de `OrderSend()`, `OrderModify()`, `OrderClose()` - Sin cambios
- `AppendHistory()` - OPCIONAL: Se puede mantener o eliminar según preferencia

---

## 6. Impacto en Históricos

### 6.1 Archivos de histórico actuales

| Archivo | Propósito | ¿Mantener? |
|---------|-----------|------------|
| `Historico_Master.csv` | Eventos distribuidos con timestamps | ✅ Mantener |
| `historico_clonacion.csv` | Confirmación de escritura en colas | ✅ Mantener |
| `historico_WORKER_XXX.csv` | Log detallado del Worker | ⚠️ Opcional |

### 6.2 Decisión sobre historico_WORKER_XXX.csv

**Opción A: Eliminar** (recomendación del usuario)
- El archivo `estados_WORKER_XXX.csv` proporciona información equivalente
- Ahorra tiempo de I/O en cada operación
- La purga nocturna limpia automáticamente

**Opción B: Mantener (modo reducido)**
- Solo escribir en caso de errores críticos
- Útil para debugging post-mortem

**Decisión:** Implementar Opción A inicialmente. Si se necesita más detalle, añadir logging condicional.

---

## 7. Plan de Implementación

### Fase 1: WorkerV2.mq4

1. Crear función `AppendEstado()`
2. Crear función `CargarEstadosProcesados()`
3. Crear función `ReconstruirReintentosDesdeEstados()`
4. Modificar `OnInit()` para llamar a reconstrucción
5. Modificar `OnTimer()` para usar estados en lugar de reescribir cola
6. Eliminar `RewriteQueue()` y bloque de merge defensivo
7. Testing unitario

### Fase 2: DistribuidorV3.py

1. Crear función `purga_nocturna()`
2. Añadir scheduler para ejecutar a las 00:01
3. Manejar caso de archivos .lck al escribir (esperar o crear .pending)
4. Testing unitario

### Fase 3: Testing integral

1. Simular ráfaga de comandos CLOSE
2. Simular caída del EA durante procesamiento
3. Simular caída del EA durante reintentos
4. Verificar purga nocturna
5. Verificar recuperación post-purga

---

## 8. Checklist de Validación

- [ ] Ningún comando CLOSE se pierde en ráfagas
- [ ] EA recupera reintentos pendientes tras reinicio
- [ ] Purga nocturna limpia correctamente ambos archivos
- [ ] Worker espera durante purga (.lck)
- [ ] Estados reflejan resultado real de ejecución
- [ ] Memoria del Worker coincide con órdenes reales en MT4

---

## 9. Diagrama de Arquitectura Final

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              MASTER MT4                                      │
│  ┌─────────────────┐                                                        │
│  │  Extractor.mq4  │──────► Spool/*.txt (eventos pipe-separated)            │
│  └─────────────────┘                                                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SERVIDOR PYTHON                                    │
│  ┌──────────────────┐                                                       │
│  │ DistribuidorV3.py│──────► cola_WORKER_XXX.csv (append only)              │
│  │                  │──────► Historico_Master.csv                           │
│  │                  │──────► historico_clonacion.csv                        │
│  │                  │                                                       │
│  │  [Purga 00:01]   │──────► Limpia cola_XXX + estados_XXX                  │
│  └──────────────────┘                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            WORKERS MT4                                       │
│  ┌─────────────────┐                                                        │
│  │  WorkerV2.mq4   │◄────── cola_WORKER_XXX.csv (solo lectura)              │
│  │                 │──────► estados_WORKER_XXX.csv (append only)            │
│  │                 │                                                        │
│  │  [OnInit]       │──────► Reconstruye memoria + reintentos                │
│  │  [OnTimer]      │──────► Procesa comandos, registra estados              │
│  └─────────────────┘                                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 10. Conclusión

Este diseño elimina la causa raíz del problema de pérdida de comandos CLOSE al separar las responsabilidades de escritura entre procesos. La arquitectura append-only garantiza que ningún comando se pierda por race conditions, y el sistema de estados proporciona trazabilidad completa del ciclo de vida de cada operación.

La purga nocturna mantiene los archivos en tamaño manejable sin interferir con las operaciones durante el horario de trading.


