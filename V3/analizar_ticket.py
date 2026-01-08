"""
analizar_ticket.py
------------------
Script para analizar un ticket específico en los históricos.
Busca en Historico_Master.csv y en los históricos de Workers.
"""

from pathlib import Path
import os
import sys

# Configuración por defecto
DEFAULT_COMMON_FILES_DIR = Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"
V3_PHOENIX_DIR = Path("V3") / "Phoenix"
HIST_MASTER_FILE = "Historico_Master.csv"


def get_common_files_dir() -> Path:
    """Obtiene el directorio Common\\Files desde variable de entorno o por defecto."""
    env_dir = os.getenv("COMMON_FILES_DIR")
    if env_dir:
        return Path(env_dir)
    return DEFAULT_COMMON_FILES_DIR


def search_in_file(file_path: Path, ticket: str, file_type: str = "master"):
    """Busca un ticket en un archivo histórico."""
    if not file_path.exists():
        print(f"[INFO] Archivo no existe: {file_path}")
        return []
    
    results = []
    try:
        # Intentar UTF-8 primero, luego otros encodings
        encodings = ["utf-8", "utf-8-sig", "latin-1", "cp1252"]
        content = None
        for encoding in encodings:
            try:
                with open(file_path, "r", encoding=encoding) as f:
                    content = f.readlines()
                    break
            except (UnicodeDecodeError, UnicodeError):
                continue
        
        if content is None:
            print(f"[ERROR] No se pudo leer {file_path} con ningun encoding")
            return []
        
        for line_num, line in enumerate(content, 1):
            if ticket in line:
                results.append({
                    "file": file_path.name,
                    "line_num": line_num,
                    "line": line.strip()
                })
    except Exception as exc:
        print(f"[ERROR] Error leyendo {file_path}: {exc}")
    
    return results


def parse_worker_hist_line(line: str):
    """
    Parsea una línea del histórico de un Worker.
    Formato esperado: worker_exec_time;worker_read_time;resultado;event_type;ticket;order_type;lots;symbol;...
    O formato antiguo: timestamp_ejecucion;resultado;event_type;ticket;order_type;lots;symbol;...
    """
    parts = line.strip().split(";")
    if len(parts) < 5:
        return None
    
    # Detectar formato: nuevo (con worker_exec_time y worker_read_time) vs antiguo
    # Si el primer campo parece ser una fecha (contiene puntos o espacios), es formato antiguo
    first_field = parts[0]
    is_old_format = "." in first_field or " " in first_field or len(first_field) > 15
    
    if is_old_format:
        # Formato antiguo: timestamp_ejecucion;resultado;event_type;ticket;...
        return {
            "worker_exec_time": parts[0],
            "worker_read_time": "",
            "resultado": parts[1] if len(parts) > 1 else "",
            "event_type": parts[2] if len(parts) > 2 else "",
            "ticket": parts[3] if len(parts) > 3 else "",
        }
    else:
        # Formato nuevo: worker_exec_time;worker_read_time;resultado;event_type;ticket;...
        return {
            "worker_exec_time": parts[0],
            "worker_read_time": parts[1] if len(parts) > 1 else "",
            "resultado": parts[2] if len(parts) > 2 else "",
            "event_type": parts[3] if len(parts) > 3 else "",
            "ticket": parts[4] if len(parts) > 4 else "",
        }


def analyze_ticket(ticket: str, common_dir: Path):
    """Analiza un ticket en todos los históricos disponibles."""
    v3_phoenix = common_dir / V3_PHOENIX_DIR
    
    print(f"=" * 80)
    print(f"ANÁLISIS DEL TICKET: {ticket}")
    print(f"=" * 80)
    print(f"Directorio base: {common_dir}")
    print(f"Directorio V3/Phoenix: {v3_phoenix}")
    print()
    
    # 1. Buscar en Historico_Master.csv
    print("1. BUSCANDO EN Historico_Master.csv:")
    print("-" * 80)
    hist_master_path = v3_phoenix / HIST_MASTER_FILE
    master_results = search_in_file(hist_master_path, ticket, "master")
    
    if master_results:
        print(f"   [OK] Encontradas {len(master_results)} ocurrencias:")
        for result in master_results:
            print(f"   Linea {result['line_num']}: {result['line']}")
            
            # Parsear línea para mostrar información relevante
            parts = result['line'].split(";")
            if len(parts) >= 2:
                event_type = parts[0]
                ticket_found = parts[1]
                print(f"      -> Evento: {event_type}, Ticket: {ticket_found}")
                if len(parts) >= 8:
                    event_time = parts[7] if len(parts) > 7 else ""
                    export_time = parts[8] if len(parts) > 8 else ""
                    read_time = parts[9] if len(parts) > 9 else ""
                    distribute_time = parts[10] if len(parts) > 10 else ""
                    print(f"      -> Timestamps: event={event_time}, export={export_time}, read={read_time}, distribute={distribute_time}")
    else:
        print(f"   [NO] No se encontro el ticket {ticket} en Historico_Master.csv")
    print()
    
    # 2. Buscar en históricos de Workers
    print("2. BUSCANDO EN HISTÓRICOS DE WORKERS:")
    print("-" * 80)
    
    if not v3_phoenix.exists():
        print(f"   [NO] El directorio {v3_phoenix} no existe")
        return
    
    worker_files = list(v3_phoenix.glob("historico_WORKER_*.csv"))
    if not worker_files:
        print(f"   [NO] No se encontraron archivos historico_WORKER_*.csv en {v3_phoenix}")
    else:
        print(f"   Encontrados {len(worker_files)} archivos de workers:")
        for worker_file in sorted(worker_files):
            worker_id = worker_file.stem.replace("historico_WORKER_", "")
            print(f"\n   Worker ID: {worker_id}")
            worker_results = search_in_file(worker_file, ticket, "worker")
            
            if worker_results:
                print(f"   [OK] Encontradas {len(worker_results)} ocurrencias:")
                for result in worker_results:
                    print(f"   Linea {result['line_num']}: {result['line']}")
                    
                    # Parsear línea para mostrar información relevante
                    parsed = parse_worker_hist_line(result['line'])
                    if parsed:
                        print(f"      -> Resultado: {parsed.get('resultado', '')}, Evento: {parsed.get('event_type', '')}, Ticket: {parsed.get('ticket', '')}")
                        print(f"      -> Timestamps: exec={parsed.get('worker_exec_time', '')}, read={parsed.get('worker_read_time', '')}")
            else:
                print(f"   [NO] No se encontro el ticket {ticket} en este worker")
    
    print()
    print("=" * 80)
    
    # 3. Análisis y conclusiones
    print("\n3. ANÁLISIS:")
    print("-" * 80)
    
    # Buscar eventos OPEN y CLOSE
    open_events = []
    close_events = []
    
    for result in master_results:
        parts = result['line'].split(";")
        if len(parts) >= 1:
            event_type = parts[0].upper()
            if event_type == "OPEN":
                open_events.append(result)
            elif event_type == "CLOSE":
                close_events.append(result)
    
    print(f"   Eventos OPEN encontrados: {len(open_events)}")
    print(f"   Eventos CLOSE encontrados: {len(close_events)}")
    
    if open_events and not close_events:
        print(f"\n   [PROBLEMA] DETECTADO:")
        print(f"      - El ticket {ticket} tiene evento OPEN pero NO tiene evento CLOSE")
        print(f"      - Esto significa que el Extractor.mq4 no detecto el cierre de la orden")
        print(f"      - O el evento CLOSE no se proceso correctamente")
    elif not open_events:
        print(f"\n   [PROBLEMA] DETECTADO:")
        print(f"      - El ticket {ticket} NO aparece en Historico_Master.csv")
        print(f"      - Esto significa que nunca se proceso un evento para este ticket")
    elif open_events and close_events:
        print(f"\n   [OK] El ticket {ticket} tiene tanto OPEN como CLOSE")
        print(f"      - Revisar los historicos de Workers para ver si se ejecuto el CLOSE")
    
    print()


def main():
    """Función principal."""
    if len(sys.argv) < 2:
        print("Uso: python analizar_ticket.py <ticket>")
        print("Ejemplo: python analizar_ticket.py 17671052")
        sys.exit(1)
    
    ticket = sys.argv[1]
    common_dir = get_common_files_dir()
    
    analyze_ticket(ticket, common_dir)


if __name__ == "__main__":
    main()

