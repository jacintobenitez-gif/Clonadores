"""
trazabilidad.py (Produccion V2)
-------------------------------
Script que genera trazabilidad completa de eventos desde Master hasta Workers.

Lee:
- Historico_Master.csv: event_time, export_time, read_time, distribute_time
- estados_WORKER_XXX.csv: timestamp de ejecución del Worker (PROD V2)

Genera:
- trazabilidad.txt: ticket+evento | event_time | export_time | read_time | distribute_time | worker_timestamp | total_ms

NOTA: En PROD V2 el Worker usa estados_WORKER_XXX.csv en lugar de historico_WORKER_XXX.csv.
      El formato de estados es: ticketMaster;eventType;estado;timestamp;resultado;extra
      Solo tenemos UN timestamp por evento (no worker_read_time y worker_exec_time separados).
"""

from pathlib import Path
from typing import Dict, List, Optional
import csv
import os
from datetime import datetime
import math

# Configuración por defecto - PRODUCCION V2
DEFAULT_COMMON_FILES_DIR = Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"
PROD_PHOENIX_DIR = Path("PROD") / "Phoenix" / "V2"  # Cambiado de V3/Phoenix
HIST_MASTER_FILE = "Historico_Master.csv"
TRACEABILITY_FILE = "trazabilidad.txt"


def get_common_files_dir() -> Path:
    """Obtiene el directorio Common\\Files desde variable de entorno o por defecto."""
    env_dir = os.getenv("COMMON_FILES_DIR")
    if env_dir:
        return Path(env_dir)
    return DEFAULT_COMMON_FILES_DIR


def parse_hist_master_line(line: str) -> Optional[Dict[str, str]]:
    """
    Parsea una línea de Historico_Master.csv.
    Formato normal: event_type;ticket;order_type;lots;symbol;sl;tp;event_time;export_time;read_time;distribute_time
    Formato OPEN_INVALIDATE_BYTIME30SEG: event_type;ticket;order_type;lots;symbol;sl;tp;invalidation_reason;seconds_elapsed;event_time;export_time;read_time;distribute_time
    """
    parts = line.strip().split(";")
    # Mínimo: event_type;ticket;... (el resto puede variar en número de campos vacíos)
    if len(parts) < 2:
        return None
    
    event_type = parts[0]
    
    # Excluir eventos OPEN_INVALIDATE_BYTIME30SEG
    if event_type == "OPEN_INVALIDATE_BYTIME30SEG":
        return None

    # Por ahora, ignorar MODIFY: solo interesa la latencia de OPEN/CLOSE
    if event_type == "MODIFY":
        return None
    
    # IMPORTANTE:
    # En Historico_Master.csv los eventos (OPEN/MODIFY/CLOSE) pueden tener distinto número de
    # columnas vacías antes de los timestamps (p.ej. CLOSE suele venir con ";;;;;;;").
    # Por eso NO podemos confiar en índices fijos (7-10). Tomamos SIEMPRE los 4 últimos campos:
    # event_time;export_time;read_time;distribute_time
    if len(parts) >= 4:
        event_time, export_time, read_time, distribute_time = parts[-4:]
    else:
        event_time = export_time = read_time = distribute_time = ""

    return {
        "event_type": event_type,
        "ticket": parts[1],
        "event_time": event_time,
        "export_time": export_time,
        "read_time": read_time,
        "distribute_time": distribute_time,
    }


def parse_worker_estados_line(line: str) -> Optional[Dict[str, str]]:
    """
    Parsea una línea del archivo estados_WORKER_XXX.csv (PROD V2).
    Formato: ticketMaster;eventType;estado;timestamp;resultado;extra
    
    Solo consideramos estados completados (estado=2) para la trazabilidad.
    """
    parts = line.strip().split(";")
    if len(parts) < 4:  # Mínimo ticketMaster;eventType;estado;timestamp
        return None
    
    ticket = parts[0].strip()
    event_type = parts[1].strip().upper()
    try:
        estado = int(parts[2].strip())
    except ValueError:
        return None
    
    timestamp = parts[3].strip()
    resultado = parts[4].strip() if len(parts) > 4 else ""
    
    # Solo considerar estados completados (estado=2) con resultado OK
    if estado != 2:
        return None
    if not resultado.startswith("OK"):
        return None
    
    return {
        "ticket": ticket,
        "event_type": event_type,
        "worker_timestamp": timestamp,  # Este es el único timestamp disponible en PV2
    }


def get_worker_ids_from_config(config_path: Path) -> List[str]:
    """Lee worker_ids del archivo de configuración."""
    worker_ids = []
    if not config_path.exists():
        return worker_ids
    
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("worker_id="):
                    value = line.split("=", 1)[1].strip()
                    # Formato: worker_id=<id>|<mappings>
                    if "|" in value:
                        worker_id = value.split("|")[0].strip()
                    else:
                        worker_id = value
                    if worker_id:
                        worker_ids.append(worker_id)
    except Exception as exc:
        print(f"[WARN] No se pudo leer config: {exc}")
    
    return worker_ids


def read_master_hist(hist_path: Path) -> Dict[str, Dict[str, str]]:
    """
    Lee Historico_Master.csv y retorna diccionario indexado por ticket+evento.
    Retorna: { "ticket_event": { "event_time": ..., "export_time": ..., ... } }
    """
    master_data = {}
    
    if not hist_path.exists():
        print(f"[WARN] No existe {hist_path}")
        return master_data
    
    try:
        with open(hist_path, "r", encoding="utf-8") as f:
            for line_num, line in enumerate(f, 1):
                if line_num == 1:  # Saltar header si existe
                    if "event_type" in line.lower():
                        continue
                
                parsed = parse_hist_master_line(line)
                if not parsed or not parsed.get("ticket") or not parsed.get("event_type"):
                    continue
                
                key = f"{parsed['ticket']}_{parsed['event_type']}"
                master_data[key] = parsed
    except Exception as exc:
        print(f"[ERROR] Error leyendo {hist_path}: {exc}")
    
    return master_data


def read_worker_estados(estados_path: Path) -> Dict[str, Dict[str, str]]:
    """
    Lee archivo estados_WORKER_XXX.csv (PROD V2) y retorna diccionario.
    Retorna: { "ticket_event": { "worker_timestamp": ... } }
    """
    worker_data = {}
    
    if not estados_path.exists():
        return worker_data
    
    def _open_text_auto(p: Path):
        """
        Algunos archivos pueden estar en UTF-16 (BOM 0xFF 0xFE / 0xFE 0xFF).
        Detectar BOM en binario y abrir con la codificación correcta.
        """
        try:
            with open(p, "rb") as bf:
                head = bf.read(4)
            if head.startswith(b"\xff\xfe") or head.startswith(b"\xfe\xff"):
                return open(p, "r", encoding="utf-16")
            # utf-8-sig cubre BOM UTF-8 si existiera
            return open(p, "r", encoding="utf-8-sig")
        except Exception:
            # fallback ultra-permisivo
            return open(p, "r", encoding="latin-1", errors="replace")

    try:
        with _open_text_auto(estados_path) as f:
            for line_num, line in enumerate(f, 1):
                if line_num == 1:  # Saltar header si existe
                    if "ticketmaster" in line.lower() or "timestamp" in line.lower():
                        continue
                
                parsed = parse_worker_estados_line(line)
                if not parsed or not parsed.get("ticket") or not parsed.get("event_type"):
                    continue
                
                key = f"{parsed['ticket']}_{parsed['event_type']}"
                # Si ya existe, mantener el primero (o podríamos actualizar al último)
                if key not in worker_data:
                    worker_data[key] = {
                        "worker_timestamp": parsed.get("worker_timestamp", ""),
                    }
    except Exception as exc:
        print(f"[ERROR] Error leyendo {estados_path}: {exc}")
    
    return worker_data


def _nearest_hour_offset_ms(delta_ms: int, max_jitter_ms: int = 120_000) -> Optional[int]:
    """
    Si delta_ms está cerca de un múltiplo de 1 hora (3600s), devuelve ese offset en ms.
    Sirve para corregir desfaces UTC vs hora servidor MT4 cuando se comparan timestamps de distintos sistemas.
    """
    hour_ms = 3_600_000
    if delta_ms == 0:
        return 0
    k = int(round(delta_ms / hour_ms))
    if k == 0:
        return 0
    candidate = k * hour_ms
    if abs(delta_ms - candidate) <= max_jitter_ms:
        return candidate
    return None


def aggregate_worker_data(all_worker_data: List[Dict[str, Dict[str, str]]]) -> Dict[str, Dict[str, str]]:
    """
    Agrega datos de múltiples workers.
    Para cada ticket+evento, toma los valores del primer worker que tenga datos.
    """
    aggregated = {}
    
    for worker_data in all_worker_data:
        for key, values in worker_data.items():
            if key not in aggregated:
                aggregated[key] = values
    
    return aggregated


def timestamp_to_ms(timestamp_str: str) -> Optional[int]:
    """
    Convierte timestamp a milisegundos.
    Acepta formato: milisegundos (string numérico) o fecha (YYYY.MM.DD HH:MM:SS.mmm)
    """
    if not timestamp_str or timestamp_str.strip() == "":
        return None
    
    timestamp_str = timestamp_str.strip()
    
    # Si es numérico, asumir que ya está en milisegundos
    try:
        ms = int(float(timestamp_str))
        # Si el número es muy pequeño (< 1000000000), asumir que está en segundos
        if ms < 1000000000:
            ms = ms * 1000
        return ms
    except ValueError:
        pass
    
    # Intentar parsear como fecha: YYYY.MM.DD HH:MM:SS.mmm
    try:
        # Formato: 2026.01.05 20:04:09.433
        dt = datetime.strptime(timestamp_str, "%Y.%m.%d %H:%M:%S.%f")
        return int(dt.timestamp() * 1000)
    except ValueError:
        try:
            # Formato sin milisegundos: 2026.01.05 20:04:09
            dt = datetime.strptime(timestamp_str, "%Y.%m.%d %H:%M:%S")
            return int(dt.timestamp() * 1000)
        except ValueError:
            pass
    
    return None


def calculate_diff_ms(event_time_ms: Optional[int], timestamp_str: str) -> Optional[int]:
    """
    Calcula la diferencia en milisegundos entre event_time y otro timestamp.
    Retorna None si alguno de los valores es inválido.
    """
    if event_time_ms is None:
        return None
    
    timestamp_ms = timestamp_to_ms(timestamp_str)
    if timestamp_ms is None:
        return None
    
    return timestamp_ms - event_time_ms


def filter_today_events(master_data: Dict[str, Dict[str, str]]) -> Dict[str, Dict[str, str]]:
    """
    Filtra eventos para mostrar solo los de hoy.
    Usa export_time como referencia (momento en que se exportó el evento).
    """
    from datetime import datetime, timezone
    
    today_start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    today_start_ms = int(today_start.timestamp() * 1000)
    
    filtered = {}
    for key, event_info in master_data.items():
        export_time = event_info.get("export_time", "")
        export_time_ms = timestamp_to_ms(export_time)
        
        # Si export_time es de hoy o posterior, incluir el evento
        if export_time_ms is not None and export_time_ms >= today_start_ms:
            filtered[key] = event_info
    
    return filtered


def generate_traceability(common_dir: Path, output_path: Path, filter_today: bool = False):
    """Genera archivo de trazabilidad."""
    prod_phoenix = common_dir / PROD_PHOENIX_DIR
    hist_master_path = prod_phoenix / HIST_MASTER_FILE
    
    # El config suele vivir en el repo (Produccion/V2/distribuidor_config.txt)
    config_candidates = [
        common_dir / "PROD" / "Phoenix" / "V2" / "distribuidor_config.txt",
        Path(__file__).resolve().parent / "distribuidor_config.txt",
    ]
    config_path = next((p for p in config_candidates if p.exists()), config_candidates[-1])
    
    print(f"[INFO] Leyendo {hist_master_path}")
    master_data = read_master_hist(hist_master_path)
    print(f"[INFO] Encontrados {len(master_data)} eventos en Master")
    
    # Filtrar eventos de hoy si se solicita
    if filter_today:
        master_data = filter_today_events(master_data)
        print(f"[INFO] Filtrados eventos de hoy: {len(master_data)} eventos")
    
    # Obtener worker IDs
    worker_ids = get_worker_ids_from_config(config_path)
    if not worker_ids:
        print("[WARN] No se encontraron worker_ids en config")
        worker_ids = []
    
    # Leer estados de workers (PROD V2 usa estados_WORKER_XXX.csv en lugar de historico_WORKER)
    all_worker_data = []
    for worker_id in worker_ids:
        worker_estados_path = prod_phoenix / f"estados_WORKER_{worker_id}.csv"
        worker_data = read_worker_estados(worker_estados_path)
        if worker_data:
            print(f"[INFO] Worker {worker_id}: {len(worker_data)} eventos completados")
            all_worker_data.append(worker_data)
    
    # Agregar datos de workers
    aggregated_worker_data = aggregate_worker_data(all_worker_data)
    print(f"[INFO] Total eventos agregados de workers: {len(aggregated_worker_data)}")
    
    # Generar trazabilidad
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(output_path, "w", encoding="utf-8") as f:
        # Header adaptado para PROD V2 (solo un timestamp del worker)
        f.write("ticket_event|event_time|export_time|read_time|distribute_time|worker_timestamp|diff_export_ms|diff_read_ms|diff_distribute_ms|diff_worker_ms|total_ms\n")
        
        # Escribir todos los eventos del master
        for key, master_info in sorted(master_data.items()):
            worker_info = aggregated_worker_data.get(key, {})
            
            event_time = master_info.get("event_time", "")
            export_time = master_info.get("export_time", "")
            read_time = master_info.get("read_time", "")
            distribute_time = master_info.get("distribute_time", "")
            worker_timestamp = worker_info.get("worker_timestamp", "")
            
            # Convertir todos los timestamps a milisegundos
            event_time_ms = timestamp_to_ms(event_time)
            export_time_ms = timestamp_to_ms(export_time)
            read_time_ms = timestamp_to_ms(read_time)
            distribute_time_ms = timestamp_to_ms(distribute_time)
            worker_timestamp_ms = timestamp_to_ms(worker_timestamp)

            # NORMALIZACIÓN DE ZONAS HORARIAS:
            # - event_time viene del servidor MT4 (puede ser UTC+2 o UTC+3)
            # - export/read/distribute vienen de Python/Extractor (hora local del PC)
            # - worker_timestamp: 
            #   * Formato antiguo: fecha/hora del servidor MT4 (necesita normalización)
            #   * Formato nuevo: milisegundos epoch UTC (no necesita normalización)
            #
            # Estrategia: usar export_time como referencia (T=0) ya que es el primer
            # timestamp controlado por nuestro sistema (momento en que Extractor exporta).
            
            # Normalizar event_time si hay desfase horario con export_time
            if event_time_ms is not None and export_time_ms is not None:
                event_delta = event_time_ms - export_time_ms
                hour_off = _nearest_hour_offset_ms(event_delta)
                if hour_off is not None and hour_off != 0:
                    event_time_ms = event_time_ms - hour_off  # Corregir a zona export_time
            
            # Normalizar worker_timestamp SOLO si hay desfase horario significativo
            # (timestamps en ms epoch UTC no deberían tener desfase de horas)
            if worker_timestamp_ms is not None and distribute_time_ms is not None:
                worker_delta = worker_timestamp_ms - distribute_time_ms
                # Solo normalizar si el desfase es cercano a múltiplos de 1 hora
                # (indica formato antiguo fecha/hora vs nuevo formato ms epoch)
                hour_off = _nearest_hour_offset_ms(worker_delta)
                if hour_off is not None and hour_off != 0:
                    worker_timestamp_ms = worker_timestamp_ms - hour_off
            
            # BASE: usar export_time como T=0 (momento de exportación del evento)
            base_time_ms = export_time_ms
            
            # Calcular diferencias INCREMENTALES (cada paso respecto al anterior)
            # Flujo: event → export → read → distribute → worker
            diff_export_ms = None
            diff_read_ms = None  
            diff_distribute_ms = None
            diff_worker_ms = None
            
            if export_time_ms is not None:
                # diff_export = export - event (tiempo desde evento hasta exportación)
                if event_time_ms is not None:
                    diff_export_ms = export_time_ms - event_time_ms
                else:
                    diff_export_ms = 0  # Si no hay event_time, export es T=0
                
                # diff_read = read - export (tiempo de lectura del spool)
                if read_time_ms is not None:
                    diff_read_ms = read_time_ms - export_time_ms
                
                # diff_distribute = distribute - export (tiempo hasta distribución)
                if distribute_time_ms is not None:
                    diff_distribute_ms = distribute_time_ms - export_time_ms
                
                # diff_worker = worker - export (tiempo hasta ejecución en worker)
                if worker_timestamp_ms is not None:
                    diff_worker_ms = worker_timestamp_ms - export_time_ms
            
            # total_ms = tiempo end-to-end desde export hasta worker
            total_ms = diff_worker_ms if diff_worker_ms is not None else diff_distribute_ms
            
            # Corregir valores negativos pequeños (desfase de reloj entre sistemas)
            # Valores entre -1000ms y 0ms se consideran ~0ms (ejecución casi instantánea)
            def clamp_negative(val):
                if val is not None and val < 0:
                    if val > -1000:  # Pequeño desfase de reloj
                        return 0
                    # Valores muy negativos indican error de zona horaria no corregido
                return val
            
            diff_export_ms = clamp_negative(diff_export_ms)
            diff_read_ms = clamp_negative(diff_read_ms)
            diff_distribute_ms = clamp_negative(diff_distribute_ms)
            diff_worker_ms = clamp_negative(diff_worker_ms)
            total_ms = clamp_negative(total_ms)
            
            # Formatear diferencias
            def format_diff(diff):
                if diff is None:
                    return "N/A"
                if abs(diff) < 1000:
                    return f"{diff}ms"
                else:
                    seconds = diff / 1000.0
                    if seconds == int(seconds):
                        return f"{int(seconds)}s"
                    else:
                        return f"{seconds:.2f}s"
            
            f.write(f"{key}|{event_time}|{export_time}|{read_time}|{distribute_time}|{worker_timestamp}|{format_diff(diff_export_ms)}|{format_diff(diff_read_ms)}|{format_diff(diff_distribute_ms)}|{format_diff(diff_worker_ms)}|{format_diff(total_ms)}\n")
    
    print(f"[OK] Trazabilidad generada: {output_path}")
    print(f"[INFO] Total eventos procesados: {len(master_data)}")


def main():
    """Función principal."""
    common_dir = get_common_files_dir()
    prod_phoenix = common_dir / PROD_PHOENIX_DIR
    output_path = prod_phoenix / TRACEABILITY_FILE
    
    print(f"[INIT] Generando trazabilidad PROD V2...")
    print(f"[INIT] Common dir: {common_dir}")
    print(f"[INIT] Phoenix dir: {prod_phoenix}")
    print(f"[INIT] Output: {output_path}")
    print("\nOpciones:")
    print("1. Calcular diferencia hoy (solo operaciones de hoy)")
    print("2. Calcular diferencias histórico (todas las operaciones)")
    
    while True:
        try:
            opcion = input("\nSeleccione opción (1 o 2): ").strip()
            if opcion == "1":
                filter_today = True
                print("[INFO] Modo: Solo eventos de hoy")
                break
            elif opcion == "2":
                filter_today = False
                print("[INFO] Modo: Histórico completo")
                break
            else:
                print("[ERROR] Por favor seleccione 1 o 2")
        except (EOFError, KeyboardInterrupt):
            print("\n[INFO] Usando opción por defecto: Histórico completo")
            filter_today = False
            break
    
    generate_traceability(common_dir, output_path, filter_today)


if __name__ == "__main__":
    main()

