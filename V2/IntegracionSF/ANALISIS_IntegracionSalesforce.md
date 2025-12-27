# Análisis: Integración con Salesforce

## Contexto

Una vez que tenemos `Historico_Master.txt` e `historico_clonacion.txt` generados por el Distribuidor.py, necesitamos un mecanismo para enviar esa información a Salesforce.

**Requisitos:**
- Volumen: 200-300 eventos por día
- Tiempo real: procesar conforme aparecen nuevos registros
- Solo código: sin herramientas pagas
- Eliminación: borrar líneas procesadas exitosamente para evitar crecimiento de archivos
- **Arquitectura**: Salesforce está en otro cloud, no en la VPS donde corre el servicio Python

**Nota importante:** La REST API de Salesforce funciona perfectamente de forma remota. El servicio Python en tu VPS se conectará a Salesforce vía HTTPS usando las credenciales de autenticación. No requiere que Salesforce esté en la misma máquina o red.

---

## Opciones para Enviar Datos a Salesforce

### 1. Salesforce REST API (Recomendado)

**Cómo funciona:**
- Usar la REST API de Salesforce para insertar/actualizar registros
- Autenticación con OAuth 2.0 (usuario/password o JWT)
- Endpoints: `/services/data/vXX.0/sobjects/ObjectName/`

**Ventajas:**
- Control total sobre qué y cuándo enviar
- Manejo de errores y reintentos
- No requiere licencias adicionales
- Permite transformaciones antes de enviar

**Desventajas:**
- Requiere desarrollo de código Python
- Límites de API (24h: 5,000-1,000,000+ según edición)
- Gestión manual de autenticación

**Implementación Python:**
```python
# Usar simple-salesforce o requests directamente
from simple_salesforce import Salesforce
import pandas as pd

# Conectar
sf = Salesforce(username='user', password='pass', security_token='token')

# Leer archivos históricos
df_master = pd.read_csv('Historico_Master.txt', sep=';')
df_clonacion = pd.read_csv('historico_clonacion.txt', sep=';')

# Insertar registros
for _, row in df_master.iterrows():
    sf.Evento_Master__c.create({
        'Event_Type__c': row['event_type'],
        'Ticket__c': row['ticket'],
        'Symbol__c': row['symbol'],
        # ... más campos
    })
```

---

### 2. Salesforce Bulk API

**Cuándo usar:**
- Volúmenes grandes (miles de registros)
- Operaciones batch más eficientes

**Cómo funciona:**
- Subir CSV/JSON en lotes
- Procesamiento asíncrono
- Consultar estado del job

**Ventajas:**
- Más eficiente para grandes volúmenes
- Menos llamadas API
- Mejor para datos históricos acumulados

**Desventajas:**
- Más complejo de implementar
- Requiere manejo de jobs asíncronos

---

### 3. Salesforce Data Loader (CLI)

**Cómo funciona:**
- Herramienta oficial de Salesforce
- Se ejecuta desde línea de comandos
- Lee CSV y carga datos

**Ventajas:**
- Herramienta oficial y estable
- No requiere código Python
- Buen manejo de errores

**Desventajas:**
- Menos flexible que API
- Requiere configuración manual
- Menos automatizable

**Implementación:**
```bash
# Desde Python puedes ejecutar Data Loader
import subprocess
subprocess.run([
    'dataloader',
    'process',
    'config.properties',
    'operation=insert',
    'object=Evento_Master__c'
])
```

---

### 4. Salesforce Connect (External Objects)

**Cuándo usar:**
- Si quieres que Salesforce lea directamente los archivos
- Sin necesidad de copiar datos

**Cómo funciona:**
- Salesforce se conecta a una fuente externa
- Los datos se leen bajo demanda
- No se almacenan en Salesforce

**Ventajas:**
- Datos siempre actualizados
- No duplicación de datos
- Menos mantenimiento

**Desventajas:**
- Requiere servidor OData/REST
- Más complejo de configurar
- Puede ser más lento

---

### 5. ETL/Integración con herramientas intermedias

**Opciones:**
- MuleSoft (oficial de Salesforce)
- Talend
- Informatica
- Zapier/Make (low-code)

**Ventajas:**
- Menos código propio
- Herramientas visuales
- Manejo de errores incluido

**Desventajas:**
- Coste adicional
- Dependencia de terceros
- Menos control

---

## Arquitectura Recomendada

### Opción A: Script Python Periódico (Simple)

```
┌─────────────────────┐
│ Historico_Master.txt│
│ historico_clonacion │
│      .txt           │
└──────────┬──────────┘
           │
           │ (lectura incremental)
           ▼
    ┌──────────────┐
    │ Script Python │
    │  (cron/job)   │
    └──────┬───────┘
           │
           │ (REST API)
           ▼
    ┌──────────────┐
    │  Salesforce   │
    │  (Objects)    │
    └──────────────┘
```

**Flujo:**
1. Script Python se ejecuta cada X minutos/horas
2. Lee solo líneas nuevas (marcador de última línea procesada)
3. Transforma datos al formato de Salesforce
4. Inserta/actualiza registros vía REST API
5. Guarda posición de última línea procesada

**Ventajas:**
- Simple de implementar
- Control total
- Fácil debugging
- Bajo costo

---

### Opción B: Servicio Python Continuo (Avanzado)

```
┌─────────────────────┐
│ Historico_Master.txt│
│ historico_clonacion │
│      .txt           │
└──────────┬──────────┘
           │
           │ (monitoreo de cambios)
           ▼
    ┌──────────────┐
    │  Service.py   │
    │  (24/7)       │
    └──────┬───────┘
           │
           │ (cola de mensajes)
           ▼
    ┌──────────────┐
    │   Queue/DB    │
    │  (opcional)   │
    └──────┬───────┘
           │
           │ (REST API)
           ▼
    ┌──────────────┐
    │  Salesforce   │
    └──────────────┘
```

**Ventajas:**
- Tiempo real o casi real
- Manejo de errores robusto
- Escalable

**Desventajas:**
- Más complejo
- Requiere más infraestructura

---

## Arquitectura Propuesta para Requisitos Específicos

### Características del Diseño

- **Volumen**: 200-300 eventos por día (bajo-medio)
- **Tiempo real**: procesar conforme aparecen
- **Solo código**: Python + simple-salesforce
- **Eliminación**: borrar líneas procesadas exitosamente

---

## Arquitectura Recomendada: Servicio Python en Tiempo Real

```
┌─────────────────────────┐
│ Historico_Master.txt    │ ← Archivo que crece
│ historico_clonacion.txt │ ← Archivo que crece
└───────────┬─────────────┘
            │
            │ (monitoreo continuo)
            ▼
    ┌───────────────────────┐
    │   VPS (tu servidor)    │
    │ ┌───────────────────┐ │
    │ │ salesforce_        │ │
    │ │ sync_service       │ │ ← Servicio Python 24/7
    │ │   .py              │ │
    │ └─────────┬──────────┘ │
    └───────────┼─────────────┘
                │
                │ (HTTPS REST API)
                │ (Internet/Cloud)
                ▼
    ┌───────────────────────┐
    │   Salesforce Cloud     │
    │   (otro servidor)      │
    │ ┌───────────────────┐ │
    │ │  Salesforce API    │ │
    │ │  (REST endpoints) │ │
    │ └───────────────────┘ │
    └───────────────────────┘
```

**Nota:** La conexión es completamente remota vía HTTPS. No requiere VPN ni red privada.

---

## Funcionamiento del Servicio

### Flujo de Procesamiento

```
1. Servicio arranca y lee posición inicial
   ↓
2. Monitorea archivos cada X segundos (ej: 5-10s)
   ↓
3. Detecta líneas nuevas (comparando tamaño/posición)
   ↓
4. Lee solo líneas nuevas
   ↓
5. Para cada evento nuevo:
   a) Inserta Evento_Master__c en Salesforce
   b) Busca clonaciones relacionadas
   c) Inserta Clonacion_Worker__c (múltiples)
   d) Si TODO OK → Marca líneas para eliminar
   e) Si ERROR → Mantiene líneas para reintento
   ↓
6. Elimina líneas procesadas exitosamente
   ↓
7. Guarda nueva posición
   ↓
8. Espera y repite (ciclo continuo)
```

---

## Estructura del Código Python

### Archivo Principal: `salesforce_sync_service.py`

```python
"""
Servicio que sincroniza históricos con Salesforce en tiempo real.
- Monitorea Historico_Master.txt e historico_clonacion.txt
- Procesa líneas nuevas conforme aparecen
- Inserta en Salesforce
- Elimina líneas procesadas exitosamente
"""

import time
import os
from pathlib import Path
from simple_salesforce import Salesforce
from datetime import datetime

# Configuración
MASTER_FILE = Path("V2/Phoenix/Historico_Master.txt")
CLONACION_FILE = Path("V2/Phoenix/historico_clonacion.txt")
POLL_INTERVAL = 5  # segundos entre verificaciones
STATE_FILE = Path("sync_state.json")  # Guarda última posición procesada

# Conectar a Salesforce (remoto vía HTTPS)
# IMPORTANTE: NUNCA hardcodees credenciales en el código
# Usa variables de entorno o archivo de configuración protegido

import os
from simple_salesforce import Salesforce

# Opción 1: Variables de entorno (RECOMENDADO)
sf = Salesforce(
    username=os.getenv('SALESFORCE_USERNAME'),
    password=os.getenv('SALESFORCE_PASSWORD'),
    security_token=os.getenv('SALESFORCE_SECURITY_TOKEN'),
    domain='test'  # Usar 'test' para sandbox, 'login' para producción
)

# Opción 2: Archivo de configuración (alternativa)
# Crear archivo config.json (añadir a .gitignore)
# {
#   "username": "tu_usuario",
#   "password": "tu_password",
#   "security_token": "tu_token",
#   "domain": "test"
# }

def load_state():
    """Carga última posición procesada"""
    # Implementar lectura de estado
    pass

def save_state(position_master, position_clonacion):
    """Guarda posición actual"""
    # Implementar guardado de estado
    pass

def read_new_lines(file_path, last_position):
    """Lee solo líneas nuevas desde última posición"""
    # Implementar lectura incremental
    pass

def process_master_event(line):
    """Procesa un evento del Master y sus clonaciones"""
    # Parsear línea
    # Insertar en Salesforce
    # Buscar clonaciones relacionadas
    # Insertar clonaciones
    # Retornar éxito/error
    pass

def delete_processed_lines(file_path, lines_to_delete):
    """Elimina líneas ya procesadas del archivo"""
    # Reescribir archivo sin líneas procesadas
    pass

def main_loop():
    """Bucle principal del servicio"""
    state = load_state()
    
    while True:
        try:
            # Verificar si hay líneas nuevas
            new_master_lines = read_new_lines(MASTER_FILE, state['master_pos'])
            
            if new_master_lines:
                processed_lines = []
                
                for line in new_master_lines:
                    success = process_master_event(line)
                    if success:
                        processed_lines.append(line)
                
                # Eliminar líneas procesadas
                if processed_lines:
                    delete_processed_lines(MASTER_FILE, processed_lines)
                    state['master_pos'] += len(processed_lines)
                    save_state(state)
            
            time.sleep(POLL_INTERVAL)
            
        except Exception as e:
            print(f"Error: {e}")
            time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    main_loop()
```

---

## Detalles de Implementación

### 1. Lectura Incremental de Archivos

**Problema:** Leer solo líneas nuevas sin reprocesar.

**Solución:** Guardar posición (byte offset o número de línea).

```python
def read_new_lines(file_path, last_position):
    """Lee líneas nuevas desde última posición"""
    with open(file_path, 'r', encoding='utf-8') as f:
        f.seek(last_position)  # Ir a última posición
        new_lines = f.readlines()
        new_position = f.tell()  # Nueva posición
    return new_lines, new_position
```

**Alternativa:** Comparar tamaño del archivo.

```python
def has_new_data(file_path, last_size):
    """Verifica si hay datos nuevos comparando tamaño"""
    current_size = file_path.stat().st_size
    return current_size > last_size
```

---

### 2. Procesamiento de Eventos Maestro + Clonaciones

**Relación 1 a N:**
- Insertar `Evento_Master__c` primero
- Obtener ID generado
- Insertar múltiples `Clonacion_Worker__c` con referencia

```python
def process_master_event(master_line):
    """Procesa evento maestro y sus clonaciones"""
    # 1. Parsear línea del Master
    evento = parse_master_line(master_line)
    
    # 2. Insertar Evento_Master__c
    try:
        result = sf.Evento_Master__c.create({
            'Event_Type__c': evento['event_type'],
            'Ticket__c': evento['ticket'],
            'Symbol__c': evento['symbol'],
            'Timestamp__c': evento['timestamp'],
            # ... más campos
        })
        evento_id = result['id']
    except Exception as e:
        print(f"Error insertando evento maestro: {e}")
        return False
    
    # 3. Buscar clonaciones relacionadas
    clonaciones = find_clonaciones_for_ticket(evento['ticket'], evento['timestamp'])
    
    # 4. Insertar cada clonación
    for clon_line in clonaciones:
        clon = parse_clonacion_line(clon_line)
        try:
            sf.Clonacion_Worker__c.create({
                'Evento_Master__r': evento_id,  # Relación
                'Worker_ID__c': clon['worker_id'],
                'Resultado__c': clon['resultado'],
                'Timestamp__c': clon['timestamp'],
            })
        except Exception as e:
            print(f"Error insertando clonación: {e}")
            # Si falla una clonación, ¿qué hacer?
            # Opción A: Rollback del evento maestro
            # Opción B: Marcar para reintento
            return False
    
    return True  # Todo OK
```

---

### 3. Eliminación de Líneas Procesadas

**Problema:** Eliminar líneas específicas sin reescribir todo el archivo.

**Solución:** Reescribir el archivo excluyendo las líneas procesadas.

```python
def delete_processed_lines(file_path, lines_to_delete):
    """Elimina líneas procesadas del archivo"""
    # Leer todas las líneas
    with open(file_path, 'r', encoding='utf-8') as f:
        all_lines = f.readlines()
    
    # Filtrar líneas a eliminar
    lines_to_keep = [line for line in all_lines if line not in lines_to_delete]
    
    # Reescribir archivo
    with open(file_path, 'w', encoding='utf-8') as f:
        f.writelines(lines_to_keep)
```

**Alternativa:** Usar archivo temporal.

```python
def delete_processed_lines(file_path, lines_to_delete):
    """Elimina líneas usando archivo temporal"""
    temp_file = file_path.with_suffix('.tmp')
    
    with open(file_path, 'r', encoding='utf-8') as f_in, \
         open(temp_file, 'w', encoding='utf-8') as f_out:
        for line in f_in:
            if line not in lines_to_delete:
                f_out.write(line)
    
    temp_file.replace(file_path)  # Reemplazar original
```

---

### 4. Manejo de Estado (Posición Procesada)

**Guardar estado en JSON:**

```python
import json

def load_state():
    """Carga estado desde archivo JSON"""
    if STATE_FILE.exists():
        with open(STATE_FILE, 'r') as f:
            return json.load(f)
    return {'master_pos': 0, 'clonacion_pos': 0}

def save_state(state):
    """Guarda estado en archivo JSON"""
    with open(STATE_FILE, 'w') as f:
        json.dump(state, f)
```

---

### 5. Manejo de Errores y Reintentos

**Estrategia:**
- Si falla inserción → mantener línea para reintento
- Reintentar después de X minutos
- Log de errores

```python
def process_with_retry(line, max_retries=3):
    """Procesa con reintentos"""
    for attempt in range(max_retries):
        try:
            success = process_master_event(line)
            if success:
                return True
        except Exception as e:
            if attempt < max_retries - 1:
                time.sleep(60 * (attempt + 1))  # Esperar 1min, 2min, 3min
            else:
                log_error(line, e)
    return False
```

---

## Estructura de Objetos en Salesforce

### Objeto: `Evento_Master__c`

**Campos:**
- `Event_Type__c` (Text)
- `Ticket__c` (Text, único)
- `Order_Type__c` (Text)
- `Lots__c` (Number)
- `Symbol__c` (Text)
- `SL__c` (Number)
- `TP__c` (Number)
- `Timestamp__c` (DateTime)
- `External_ID__c` (Text, único) → `Ticket__c + Timestamp__c`

### Objeto: `Clonacion_Worker__c`

**Campos:**
- `Evento_Master__r` (Lookup a Evento_Master__c)
- `Worker_ID__c` (Text)
- `Resultado__c` (Text: OK/NOK)
- `Timestamp__c` (DateTime)
- `External_ID__c` (Text, único) → `Ticket__c + Worker_ID__c + Timestamp__c`

---

## Ventajas de Esta Arquitectura

1. ✅ **Tiempo real**: procesa conforme aparecen eventos
2. ✅ **Sin crecimiento**: elimina líneas procesadas
3. ✅ **Robusto**: manejo de errores y reintentos
4. ✅ **Simple**: solo Python, sin dependencias complejas
5. ✅ **Eficiente**: lectura incremental, no reprocesa
6. ✅ **Escalable**: fácil ajustar intervalo de polling

---

## Consideraciones Adicionales

### Infraestructura

**Arquitectura de Red:**
- **VPS (tu servidor)**: Ejecuta el servicio Python que lee los archivos históricos
- **Salesforce Cloud**: Servidor remoto de Salesforce (no requiere acceso directo)
- **Conexión**: HTTPS vía Internet (REST API)

**Opciones de despliegue del servicio Python:**
- **Misma VPS del Distribuidor**: Recomendado - aprovecha la infraestructura existente
- **Servidor dedicado**: Si necesitas separar servicios
- **VPS compartida**: Si tienes múltiples servicios

**Recomendación:** Ejecutar en la misma VPS donde corre `Distribuidor.py` (siempre activa). El servicio Python se conecta remotamente a Salesforce vía HTTPS, no requiere que Salesforce esté en la misma máquina.

**Consideraciones de red:**
- ✅ La REST API de Salesforce funciona perfectamente vía Internet
- ✅ Solo necesitas conectividad HTTPS saliente desde tu VPS
- ✅ No requiere VPN ni configuración de firewall especial (solo salida HTTPS estándar)
- ✅ Latencia típica: 100-500ms por llamada API (aceptable para 200-300 eventos/día)

---

### Ejecución del Servicio

**Opción A: Script Python directo**
```bash
python salesforce_sync_service.py
```

**Opción B: Servicio Windows (si es Windows)**
```bash
# Usar NSSM o Task Scheduler
```

**Opción C: Docker (si usas contenedores)**
```dockerfile
# Dockerfile para el servicio
```

---

## Configuración de Credenciales (Seguridad)

### ⚠️ IMPORTANTE: Seguridad de Credenciales

**NUNCA hardcodees credenciales en el código fuente.** Usa una de estas opciones:

### Opción 1: Variables de Entorno (Recomendado)

**En Linux/Mac:**
```bash
# Crear archivo .env (añadir a .gitignore)
export SALESFORCE_USERNAME="tu_usuario@salesforce.com"
export SALESFORCE_PASSWORD="tu_password"
export SALESFORCE_SECURITY_TOKEN="tu_token"
export SALESFORCE_DOMAIN="test"  # 'test' para sandbox, 'login' para producción

# Cargar antes de ejecutar el servicio
source .env
python salesforce_sync_service.py
```

**En Windows (PowerShell):**
```powershell
# Establecer variables de entorno
$env:SALESFORCE_USERNAME="tu_usuario@salesforce.com"
$env:SALESFORCE_PASSWORD="tu_password"
$env:SALESFORCE_SECURITY_TOKEN="tu_token"
$env:SALESFORCE_DOMAIN="test"

# Ejecutar servicio
python salesforce_sync_service.py
```

**En Windows (Task Scheduler):**
- Configurar variables de entorno en las propiedades del task
- O usar archivo batch que establece variables antes de ejecutar

### Opción 2: Archivo de Configuración Protegido

**Crear `config.json` (añadir a `.gitignore`):**
```json
{
  "salesforce": {
    "username": "tu_usuario@salesforce.com",
    "password": "tu_password",
    "security_token": "tu_token",
    "domain": "test"
  }
}
```

**Código Python:**
```python
import json
from pathlib import Path

def load_config():
    """Carga configuración desde archivo protegido"""
    config_path = Path("config.json")
    if not config_path.exists():
        raise FileNotFoundError("config.json no encontrado")
    
    with open(config_path, 'r') as f:
        return json.load(f)

config = load_config()
sf = Salesforce(
    username=config['salesforce']['username'],
    password=config['salesforce']['password'],
    security_token=config['salesforce']['security_token'],
    domain=config['salesforce']['domain']
)
```

### Opción 3: Archivo .env con python-dotenv

**Instalar:**
```bash
pip install python-dotenv
```

**Crear `.env` (añadir a `.gitignore`):**
```
SALESFORCE_USERNAME=tu_usuario@salesforce.com
SALESFORCE_PASSWORD=tu_password
SALESFORCE_SECURITY_TOKEN=tu_token
SALESFORCE_DOMAIN=test
```

**Código Python:**
```python
from dotenv import load_dotenv
import os

load_dotenv()  # Carga variables desde .env

sf = Salesforce(
    username=os.getenv('SALESFORCE_USERNAME'),
    password=os.getenv('SALESFORCE_PASSWORD'),
    security_token=os.getenv('SALESFORCE_SECURITY_TOKEN'),
    domain=os.getenv('SALESFORCE_DOMAIN', 'login')  # default 'login'
)
```

### Obtener Security Token

1. Inicia sesión en Salesforce
2. Ve a: **Setup** → **My Personal Information** → **Reset My Security Token**
3. Haz clic en **Reset Security Token**
4. Revisa tu email (el token se envía por correo)
5. Copia el token (típicamente 24 caracteres)

### Determinar Domain (Sandbox vs Producción)

- **Sandbox**: `domain='test'` o URL contiene `test.salesforce.com`
- **Producción**: `domain='login'` o URL contiene `login.salesforce.com`
- **Custom Domain**: Usar `instance_url` directamente

**Ejemplo basado en tu URL:**
```
URL: https://trailsignup-beb5322842f86c.my.salesforce.com
→ Es un custom domain, usar instance_url directamente
```

---

## Próximos Pasos

1. ✅ Crear objetos en Salesforce (`Evento_Master__c`, `Clonacion_Worker__c`)
2. ✅ Configurar credenciales de forma segura (variables de entorno o archivo protegido)
3. ✅ Obtener Security Token de Salesforce
4. ✅ Implementar el servicio Python paso a paso
5. ✅ Probar con datos de prueba
6. ✅ Desplegar como servicio continuo con credenciales seguras

---

## Resumen de Decisión

**Solución elegida:** Servicio Python continuo con REST API

**Razones:**
- ✅ Cumple requisito de tiempo real
- ✅ Elimina líneas procesadas (no crece archivo)
- ✅ Solo código Python (sin costes adicionales)
- ✅ Volumen adecuado (200-300 eventos/día es manejable)
- ✅ Control total sobre el proceso
- ✅ **Funciona perfectamente con Salesforce remoto** (REST API vía HTTPS)

**Arquitectura de Red:**
- Servicio Python en tu VPS → Conecta vía HTTPS → Salesforce Cloud (remoto)
- No requiere VPN, red privada ni configuración especial de firewall
- Solo necesita conectividad HTTPS saliente estándar

**Tecnologías:**
- Python 3.x
- `simple-salesforce` (librería para REST API remota)
- `python-dotenv` (opcional, para manejo de variables de entorno)
- Archivos JSON para estado
- Manejo de archivos con `pathlib`
- Conexión HTTPS estándar (no requiere configuración especial)

**Seguridad:**
- ✅ Credenciales en variables de entorno o archivo protegido
- ✅ Archivos de credenciales en `.gitignore`
- ✅ No hardcodear credenciales en código fuente
- ✅ Usar permisos de archivo restrictivos (chmod 600 en Linux)

