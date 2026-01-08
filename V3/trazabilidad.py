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

# Configuración por defecto
DEFAULT_COMMON_FILES_DIR = Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"
V3_PHOENIX_DIR = "V3" / "Phoenix"
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
    Formato esperado: event_type;ticket;order_type;lots;symbol;sl;tp;event_time;export_time;read_time;distribute_time
    """
    parts = line.strip().split(";")
    if len(parts) < 8:  # Mínimo event_type;ticket;...;event_time
        return None
    
    return {
        "event_type": parts[0],
        "ticket": parts[1],
        "event_time": parts[7] if len(parts) > 7 else "",
        "export_time": parts[8] if len(parts) > 8 else "",
        "read_time": parts[9] if len(parts) > 9 else "",
        "distribute_time": parts[10] if len(parts) > 10 else "",
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


def generate_traceability(common_dir: Path, output_path: Path):
    """Genera archivo de trazabilidad."""
    v3_phoenix = common_dir / V3_PHOENIX_DIR
    hist_master_path = v3_phoenix / HIST_MASTER_FILE
    config_path = v3_phoenix.parent / "distribuidor_config.txt"
    
    print(f"[INFO] Leyendo {hist_master_path}")
    master_data = read_master_hist(hist_master_path)
    print(f"[INFO] Encontrados {len(master_data)} eventos en Master")
    
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
        # Header
        f.write("ticket_event|event_time|export_time|read_time|distribute_time|worker_read_time|worker_exec_time\n")
        
        # Escribir todos los eventos del master
        for key, master_info in sorted(master_data.items()):
            worker_info = aggregated_worker_data.get(key, {})
            
            event_time = master_info.get("event_time", "")
            export_time = master_info.get("export_time", "")
            read_time = master_info.get("read_time", "")
            distribute_time = master_info.get("distribute_time", "")
            worker_read_time = worker_info.get("worker_read_time", "")
            worker_exec_time = worker_info.get("worker_exec_time", "")
            
            f.write(f"{key}|{event_time}|{export_time}|{read_time}|{distribute_time}|{worker_read_time}|{worker_exec_time}\n")
    
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
    
    generate_traceability(common_dir, output_path)


if __name__ == "__main__":
    main()

