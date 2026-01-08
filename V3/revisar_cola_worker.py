"""
revisar_cola_worker.py
----------------------
Script para revisar la cola de un Worker y buscar eventos específicos.
"""

from pathlib import Path
import os
import sys

# Configuración por defecto
DEFAULT_COMMON_FILES_DIR = Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"
V3_PHOENIX_DIR = Path("V3") / "Phoenix"


def get_common_files_dir() -> Path:
    """Obtiene el directorio Common\\Files desde variable de entorno o por defecto."""
    env_dir = os.getenv("COMMON_FILES_DIR")
    if env_dir:
        return Path(env_dir)
    return DEFAULT_COMMON_FILES_DIR


def read_queue_file(queue_path: Path, ticket: str):
    """Lee y analiza la cola de un Worker."""
    if not queue_path.exists():
        print(f"[NO] La cola no existe: {queue_path}")
        return
    
    print(f"[INFO] Leyendo cola: {queue_path}")
    print("-" * 80)
    
    try:
        encodings = ["utf-8", "utf-8-sig", "latin-1", "cp1252"]
        content = None
        for encoding in encodings:
            try:
                with open(queue_path, "r", encoding=encoding) as f:
                    content = f.readlines()
                    break
            except (UnicodeDecodeError, UnicodeError):
                continue
        
        if content is None:
            print(f"[ERROR] No se pudo leer {queue_path}")
            return
        
        print(f"Total de lineas en la cola: {len(content)}")
        print()
        
        # Buscar el ticket específico
        ticket_found = False
        for line_num, line in enumerate(content, 1):
            if ticket in line:
                ticket_found = True
                print(f"Linea {line_num}: {line.strip()}")
                
                # Parsear línea
                parts = line.strip().split(";")
                if len(parts) >= 2:
                    event_type = parts[0]
                    ticket_found_val = parts[1]
                    print(f"   -> Evento: {event_type}, Ticket: {ticket_found_val}")
                    if event_type.upper() == "CLOSE":
                        print(f"   -> [IMPORTANTE] Evento CLOSE encontrado en la cola!")
        
        if not ticket_found:
            print(f"[NO] El ticket {ticket} NO esta en la cola")
            print()
            print("Ultimas 10 lineas de la cola:")
            for line_num, line in enumerate(content[-10:], len(content)-9):
                print(f"Linea {line_num}: {line.strip()}")
        
    except Exception as exc:
        print(f"[ERROR] Error leyendo {queue_path}: {exc}")


def main():
    """Función principal."""
    if len(sys.argv) < 3:
        print("Uso: python revisar_cola_worker.py <worker_id> <ticket>")
        print("Ejemplo: python revisar_cola_worker.py 3037589 17671052")
        sys.exit(1)
    
    worker_id = sys.argv[1]
    ticket = sys.argv[2]
    common_dir = get_common_files_dir()
    
    v3_phoenix = common_dir / V3_PHOENIX_DIR
    queue_path = v3_phoenix / f"cola_WORKER_{worker_id}.csv"
    
    print("=" * 80)
    print(f"REVISION DE COLA DEL WORKER: {worker_id}")
    print(f"TICKET BUSCADO: {ticket}")
    print("=" * 80)
    print()
    
    read_queue_file(queue_path, ticket)


if __name__ == "__main__":
    main()

