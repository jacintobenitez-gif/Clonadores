"""
trazabilidad.py
---------------
Script que genera trazabilidad completa de eventos desde Master hasta Workers.

Lee:
- Historico_Master.csv: event_time, export_time, read_time, distribute_time
- Históricos de Workers: worker_read_time, worker_exec_time

Genera:
- trazabilidad.txt: ticket+evento | event_time | export_time | read_time | distribute_time | worker_read_time | worker_exec_time
"""

from pathlib import Path
from typing import Dict, List, Optional
import csv
import os
from datetime import datetime

# Configuración por defecto
DEFAULT_COMMON_FILES_DIR = Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"
V3_PHOENIX_DIR = Path("V3") / "Phoenix"
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


def parse_worker_hist_line(line: str) -> Optional[Dict[str, str]]:
    """
    Parsea una línea del histórico de un Worker.
    Formato esperado: worker_exec_time;worker_read_time;resultado;event_type;ticket;order_type;lots;symbol;...
    """
    parts = line.strip().split(";")
    if len(parts) < 5:  # Mínimo worker_exec_time;worker_read_time;resultado;event_type;ticket
        return None
    
    return {
        "worker_exec_time": parts[0],
        "worker_read_time": parts[1],
        "event_type": parts[3] if len(parts) > 3 else "",
        "ticket": parts[4] if len(parts) > 4 else "",
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


def read_worker_hist(hist_path: Path) -> Dict[str, Dict[str, str]]:
    """
    Lee histórico de un Worker y retorna diccionario indexado por ticket+evento.
    Retorna: { "ticket_event": { "worker_read_time": ..., "worker_exec_time": ... } }
    """
    worker_data = {}
    
    if not hist_path.exists():
        return worker_data
    
    try:
        with open(hist_path, "r", encoding="utf-8") as f:
            for line_num, line in enumerate(f, 1):
                if line_num == 1:  # Saltar header si existe
                    if "worker_exec_time" in line.lower() or "timestamp_ejecucion" in line.lower():
                        continue
                
                parsed = parse_worker_hist_line(line)
                if not parsed or not parsed.get("ticket") or not parsed.get("event_type"):
                    continue
                
                key = f"{parsed['ticket']}_{parsed['event_type']}"
                # Si ya existe, mantener el primero (o podríamos promediar/concatenar)
                if key not in worker_data:
                    worker_data[key] = {
                        "worker_read_time": parsed.get("worker_read_time", ""),
                        "worker_exec_time": parsed.get("worker_exec_time", ""),
                    }
    except Exception as exc:
        print(f"[ERROR] Error leyendo {hist_path}: {exc}")
    
    return worker_data


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
    v3_phoenix = common_dir / V3_PHOENIX_DIR
    hist_master_path = v3_phoenix / HIST_MASTER_FILE
    config_path = v3_phoenix.parent / "distribuidor_config.txt"
    
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
        worker_ids = []  # Intentar buscar históricos manualmente
    
    # Leer históricos de workers
    all_worker_data = []
    for worker_id in worker_ids:
        worker_hist_path = v3_phoenix / f"historico_WORKER_{worker_id}.csv"
        worker_data = read_worker_hist(worker_hist_path)
        if worker_data:
            print(f"[INFO] Worker {worker_id}: {len(worker_data)} eventos")
            all_worker_data.append(worker_data)
    
    # Agregar datos de workers
    aggregated_worker_data = aggregate_worker_data(all_worker_data)
    print(f"[INFO] Total eventos agregados de workers: {len(aggregated_worker_data)}")
    
    # Generar trazabilidad
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(output_path, "w", encoding="utf-8") as f:
        # Header con diferencias y total
        f.write("ticket_event|event_time|export_time|read_time|distribute_time|worker_read_time|worker_exec_time|diff_export_ms|diff_read_ms|diff_distribute_ms|diff_worker_read_ms|diff_worker_exec_ms|total_ms\n")
        
        # Escribir todos los eventos del master
        for key, master_info in sorted(master_data.items()):
            worker_info = aggregated_worker_data.get(key, {})
            
            event_time = master_info.get("event_time", "")
            export_time = master_info.get("export_time", "")
            read_time = master_info.get("read_time", "")
            distribute_time = master_info.get("distribute_time", "")
            worker_read_time = worker_info.get("worker_read_time", "")
            worker_exec_time = worker_info.get("worker_exec_time", "")
            
            # Convertir todos los timestamps a milisegundos
            event_time_ms = timestamp_to_ms(event_time)
            export_time_ms = timestamp_to_ms(export_time)
            read_time_ms = timestamp_to_ms(read_time)
            distribute_time_ms = timestamp_to_ms(distribute_time)
            worker_read_time_ms = timestamp_to_ms(worker_read_time)
            worker_exec_time_ms = timestamp_to_ms(worker_exec_time)
            
            # Encontrar el timestamp más antiguo (el que representa el evento original)
            # Si event_time es mayor que los demás, usar el más antiguo disponible como referencia
            timestamps = [t for t in [export_time_ms, read_time_ms, distribute_time_ms, worker_read_time_ms, worker_exec_time_ms] if t is not None]
            
            if timestamps and event_time_ms:
                # Si event_time es mayor que todos los demás, usar el más antiguo como referencia
                oldest_timestamp = min(timestamps)
                if event_time_ms > oldest_timestamp:
                    # event_time parece ser incorrecto, usar el más antiguo como referencia
                    base_time_ms = oldest_timestamp
                else:
                    # event_time es el más antiguo, usarlo como referencia
                    base_time_ms = event_time_ms
            elif event_time_ms:
                base_time_ms = event_time_ms
            elif timestamps:
                base_time_ms = min(timestamps)
            else:
                base_time_ms = None
            
            # Calcular diferencias en milisegundos desde el timestamp base
            diff_export_ms = calculate_diff_ms(base_time_ms, export_time) if base_time_ms else None
            diff_read_ms = calculate_diff_ms(base_time_ms, read_time) if base_time_ms else None
            diff_distribute_ms = calculate_diff_ms(base_time_ms, distribute_time) if base_time_ms else None
            diff_worker_read_ms = calculate_diff_ms(base_time_ms, worker_read_time) if base_time_ms else None
            diff_worker_exec_ms = calculate_diff_ms(base_time_ms, worker_exec_time) if base_time_ms else None
            
            # Calcular total_ms (tiempo desde export_time hasta worker_exec_time)
            # Es la diferencia entre el último timestamp y export_time
            total_ms = None
            if export_time_ms is not None:
                # Buscar el último timestamp disponible (prioridad: worker_exec > worker_read > distribute > read > export)
                if worker_exec_time_ms is not None:
                    total_ms = worker_exec_time_ms - export_time_ms
                elif worker_read_time_ms is not None:
                    total_ms = worker_read_time_ms - export_time_ms
                elif distribute_time_ms is not None:
                    total_ms = distribute_time_ms - export_time_ms
                elif read_time_ms is not None:
                    total_ms = read_time_ms - export_time_ms
            
            # Formatear diferencias (mostrar "N/A" si es None, o valor con unidad ms/s)
            def format_diff(diff):
                if diff is None:
                    return "N/A"
                # Si es menor a 1000, mostrar en milisegundos
                if abs(diff) < 1000:
                    return f"{diff}ms"
                # Si es mayor o igual a 1000, convertir a segundos y mostrar
                else:
                    seconds = diff / 1000.0
                    # Si es un número entero, mostrar sin decimales
                    if seconds == int(seconds):
                        return f"{int(seconds)}s"
                    else:
                        # Mostrar con 2 decimales máximo
                        return f"{seconds:.2f}s"
            
            f.write(f"{key}|{event_time}|{export_time}|{read_time}|{distribute_time}|{worker_read_time}|{worker_exec_time}|{format_diff(diff_export_ms)}|{format_diff(diff_read_ms)}|{format_diff(diff_distribute_ms)}|{format_diff(diff_worker_read_ms)}|{format_diff(diff_worker_exec_ms)}|{format_diff(total_ms)}\n")
    
    print(f"[OK] Trazabilidad generada: {output_path}")
    print(f"[INFO] Total eventos procesados: {len(master_data)}")


def main():
    """Función principal."""
    common_dir = get_common_files_dir()
    v3_phoenix = common_dir / V3_PHOENIX_DIR
    output_path = v3_phoenix / TRACEABILITY_FILE
    
    print(f"[INIT] Generando trazabilidad...")
    print(f"[INIT] Common dir: {common_dir}")
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
