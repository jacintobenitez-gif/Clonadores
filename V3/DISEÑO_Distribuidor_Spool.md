# Diseño: Adaptación de Distribuidor.py para Sistema Spool

## Arquitectura Actual vs Nueva

### Arquitectura Actual (V2/V3 con Master.txt)
```
Extractor.mq4 → Master.txt (CSV, múltiples eventos)
                ↓
            Distribuidor.py
                ↓
        cola_WORKER_XX.txt
                ↓
            Worker.mq4/mq5
```

### Nueva Arquitectura (V3 Spool)
```
Extractor.mq4 → Spool/V3/Phoenix/Spool/
                ├─ 20250115_103045_123__000001__123456__OPEN.txt
                ├─ 20250115_103046_456__000002__123456__MODIFY.txt
                └─ 20250115_103047_789__000003__123456__CLOSE.txt
                ↓
            Distribuidor.py (adaptado)
                ↓
        cola_WORKER_XX.txt
                ↓
            Worker.mq4/mq5
```

---

## Proceso Propuesto

### 1. **Lectura de Eventos del Spool**

**Ubicación**: `Common\Files\V3\Phoenix\Spool\`

**Formato de archivos**:
- Nombre: `YYYYMMDD_HHMMSS_mmm__SEQ__TICKET__EVENT.txt`
- Contenido: Una línea pipe-separated
  - OPEN: `EVT|EVENT=OPEN|TICKET=123|SYMBOL=EURUSD|TYPE=BUY|LOTS=0.10|SL=1.0850|TP=1.0900`
  - MODIFY: `EVT|EVENT=MODIFY|TICKET=123|SL_OLD=1.0850|SL_NEW=1.0860|TP_OLD=1.0900|TP_NEW=1.0910`
  - CLOSE: `EVT|EVENT=CLOSE|TICKET=123`

**Estrategia de lectura**:
1. Escanear carpeta `V3\Phoenix\Spool\` cada `poll_seconds`
2. Ordenar archivos por nombre (ya incluye timestamp)
3. Procesar archivos en orden cronológico
4. Leer contenido del archivo (una línea)
5. Parsear formato pipe-separated
6. Convertir a formato CSV compatible con workers

---

### 2. **Conversión de Formato**

**De Pipe-Separated a CSV**:

#### OPEN
```
Entrada: EVT|EVENT=OPEN|TICKET=123|SYMBOL=EURUSD|TYPE=BUY|LOTS=0.10|SL=1.0850|TP=1.0900
Salida:  OPEN;123;BUY;0.10;EURUSD;1.0850;1.0900
```

#### MODIFY
```
Entrada: EVT|EVENT=MODIFY|TICKET=123|SL_OLD=1.0850|SL_NEW=1.0860|TP_OLD=1.0900|TP_NEW=1.0910
Salida:  MODIFY;123;BUY;0.10;EURUSD;1.0860;1.0910
```
**Nota**: Para MODIFY, necesitamos obtener `order_type` y `lots` del estado actual. 
Si no están disponibles, podemos usar valores por defecto o leer del histórico.

#### CLOSE
```
Entrada: EVT|EVENT=CLOSE|TICKET=123
Salida:  CLOSE;123;;;EURUSD;;
```
**Nota**: Para CLOSE, necesitamos `symbol` del histórico o estado previo.

---

### 3. **Procesamiento de Eventos**

**Flujo**:
1. Leer archivo de evento
2. Parsear formato pipe
3. Validar evento (ticket válido, campos requeridos)
4. Convertir a CSV
5. Distribuir a workers (igual que ahora)
6. **Borrar archivo de evento** ✅
7. Registrar en histórico master
8. Registrar en histórico clonación

---

### 4. **Histórico Master.txt**

**Ubicación**: `Common\Files\V3\Phoenix\Historico_Master.txt`

**Formato**: Igual que antes (CSV con timestamp)
```
event_type;ticket;order_type;lots;symbol;sl;tp;distribucion_time
OPEN;123;BUY;0.10;EURUSD;1.0850;1.0900;2025.01.15 10:30:45.123
MODIFY;123;BUY;0.10;EURUSD;1.0860;1.0910;2025.01.15 10:30:46.456
CLOSE;123;BUY;0.10;EURUSD;;;2025.01.15 10:30:47.789
```

**Cuándo escribir**:
- Después de distribuir exitosamente a workers
- Una línea por evento procesado

---

### 5. **Histórico Clonación**

**Ubicación**: `Common\Files\V3\Phoenix\historico_clonacion.txt`

**Formato**: Igual que antes
```
ticket;worker_id;resultado;clonacion_time
123;01;OK;2025.01.15 10:30:45.123
123;02;OK;2025.01.15 10:30:45.124
```

**Cuándo escribir**:
- Después de escribir en cada cola de worker
- Una línea por worker por evento

---

### 6. **Borrado de Archivos de Evento**

**Estrategia**:
- ✅ Borrar **inmediatamente después** de procesar exitosamente
- ✅ Si falla el procesamiento, **NO borrar** (para reintento)
- ✅ Archivos `.tmp` pueden ignorarse (son temporales)

**Orden de operaciones**:
1. Leer archivo
2. Parsear y validar
3. Distribuir a workers
4. Escribir históricos
5. **Borrar archivo de evento** ← Último paso

---

## Estructura de Código Propuesta

### Funciones Nuevas

```python
def scan_spool_directory(spool_dir: Path) -> List[Path]:
    """Escanea carpeta spool y retorna archivos .txt ordenados por nombre"""
    pass

def parse_event_file(event_path: Path) -> dict:
    """Lee y parsea archivo de evento pipe-separated"""
    pass

def convert_pipe_to_csv(event_dict: dict) -> str:
    """Convierte evento pipe a formato CSV para workers"""
    pass

def process_spool_event(event_path: Path, config: Config) -> bool:
    """Procesa un evento completo: leer, distribuir, historizar, borrar"""
    pass
```

### Modificaciones a Funciones Existentes

```python
def run_service() -> None:
    """Modificado para escanear spool en lugar de leer Master.txt"""
    while True:
        # Escanear spool
        event_files = scan_spool_directory(spool_dir)
        
        for event_file in event_files:
            try:
                success = process_spool_event(event_file, config)
                if success:
                    # Archivo ya borrado en process_spool_event
                    pass
            except Exception as exc:
                print(f"[ERROR] Evento {event_file.name}: {exc}")
                # NO borrar archivo si falla
        
        time.sleep(poll_seconds)
```

---

## Consideraciones Especiales

### 1. **Manejo de MODIFY**

**Problema**: MODIFY solo tiene SL_OLD/SL_NEW y TP_OLD/TP_NEW, pero los workers necesitan:
- `order_type` (BUY/SELL)
- `lots`
- `symbol`

**Soluciones**:
- **Opción A**: Mantener caché en memoria de eventos OPEN previos
- **Opción B**: Leer del histórico master
- **Opción C**: Workers pueden manejar MODIFY sin estos campos (solo necesitan ticket)

**Recomendación**: Opción A + Opción C (workers adaptados)

### 2. **Manejo de CLOSE**

**Problema**: CLOSE solo tiene ticket, pero workers necesitan `symbol`

**Soluciones**:
- **Opción A**: Caché en memoria
- **Opción B**: Leer del histórico
- **Opción C**: Workers pueden buscar por ticket sin symbol

**Recomendación**: Opción A

### 3. **Orden de Procesamiento**

**Garantía**: Los archivos se procesan en orden cronológico gracias al nombre con timestamp.

**Ventaja**: No hay riesgo de procesar eventos fuera de orden.

### 4. **Rendimiento**

**Ventajas del spool**:
- ✅ Procesamiento paralelo posible (múltiples workers pueden leer simultáneamente)
- ✅ Sin bloqueos de archivo compartido
- ✅ Fácil debugging (un evento = un archivo)

**Consideraciones**:
- Escaneo de directorio puede ser más lento que leer archivo único
- Muchos archivos pequeños vs un archivo grande

---

## Configuración

### Nuevos Parámetros

```python
# En distribuidor_config.txt
spool_folder=V3\Phoenix\Spool
historico_master=V3\Phoenix\Historico_Master.txt
historico_clonacion=V3\Phoenix\historico_clonacion.txt
```

### Compatibilidad

**Modo Legacy** (opcional):
- Si `master_filename` está configurado, usar modo antiguo
- Si `spool_folder` está configurado, usar modo spool
- Permite migración gradual

---

## Flujo Completo

```
1. Distribuidor.py inicia
   ↓
2. Escanea V3\Phoenix\Spool\ cada poll_seconds
   ↓
3. Encuentra archivos .txt ordenados
   ↓
4. Para cada archivo:
   ├─ Leer contenido (una línea)
   ├─ Parsear formato pipe
   ├─ Validar evento
   ├─ Convertir a CSV
   ├─ Distribuir a workers (con mapeo de símbolos)
   ├─ Escribir histórico master
   ├─ Escribir histórico clonación
   └─ Borrar archivo de evento ✅
   ↓
5. Esperar poll_seconds
   ↓
6. Repetir desde paso 2
```

---

## Ventajas del Nuevo Sistema

1. ✅ **Atomicidad**: Cada evento en su propio archivo
2. ✅ **Trazabilidad**: Nombre de archivo incluye timestamp y secuencia
3. ✅ **Sin bloqueos**: Múltiples procesos pueden leer simultáneamente
4. ✅ **Debugging fácil**: Ver exactamente qué evento se generó cuándo
5. ✅ **Escalabilidad**: Fácil procesamiento paralelo
6. ✅ **Limpieza automática**: Archivos se borran después de procesar

---

## Próximos Pasos

1. ✅ Implementar `scan_spool_directory()`
2. ✅ Implementar `parse_event_file()`
3. ✅ Implementar `convert_pipe_to_csv()`
4. ✅ Implementar caché para MODIFY/CLOSE
5. ✅ Modificar `run_service()` para usar spool
6. ✅ Mantener compatibilidad con modo legacy (opcional)
7. ✅ Testing con eventos reales




