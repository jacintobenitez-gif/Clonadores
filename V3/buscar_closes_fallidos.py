"""
buscar_closes_fallidos.py
--------------------------
Busca eventos CLOSE que puedan haber fallado en los históricos de Workers.
"""

from pathlib import Path
import os
import sys

DEFAULT_COMMON_FILES_DIR = Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"
V3_PHOENIX_DIR = Path("V3") / "Phoenix"


def get_common_files_dir() -> Path:
    env_dir = os.getenv("COMMON_FILES_DIR")
    if env_dir:
        return Path(env_dir)
    return DEFAULT_COMMON_FILES_DIR


def search_close_events(hist_path: Path, ticket: str):
    """Busca eventos CLOSE relacionados con un ticket."""
    if not hist_path.exists():
        return []
    
    results = []
    try:
        encodings = ["utf-8", "utf-8-sig", "latin-1", "cp1252"]
        content = None
        for encoding in encodings:
            try:
                with open(hist_path, "r", encoding=encoding) as f:
                    content = f.readlines()
                    break
            except (UnicodeDecodeError, UnicodeError):
                continue
        
        if content is None:
            return []
        
        for line_num, line in enumerate(content, 1):
            # Buscar líneas que contengan el ticket Y que sean eventos CLOSE
            if ticket in line:
                parts = line.strip().split(";")
                # Formato: worker_exec_time;worker_read_time;resultado;event_type;ticket;...
                # O formato antiguo: timestamp;resultado;event_type;ticket;...
                if len(parts) >= 4:
                    # Detectar formato
                    first_field = parts[0]
                    is_old_format = "." in first_field or " " in first_field or len(first_field) > 15
                    
                    if is_old_format:
                        # Formato antiguo: timestamp;resultado;event_type;ticket;...
                        event_type = parts[2] if len(parts) > 2 else ""
                        ticket_found = parts[3] if len(parts) > 3 else ""
                        resultado = parts[1] if len(parts) > 1 else ""
                    else:
                        # Formato nuevo: worker_exec_time;worker_read_time;resultado;event_type;ticket;...
                        event_type = parts[3] if len(parts) > 3 else ""
                        ticket_found = parts[4] if len(parts) > 4 else ""
                        resultado = parts[2] if len(parts) > 2 else ""
                    
                    if event_type.upper() == "CLOSE" and ticket_found == ticket:
                        results.append({
                            "line_num": line_num,
                            "line": line.strip(),
                            "resultado": resultado,
                            "event_type": event_type
                        })
    except Exception as exc:
        print(f"[ERROR] Error leyendo {hist_path}: {exc}")
    
    return results


def main():
    if len(sys.argv) < 2:
        print("Uso: python buscar_closes_fallidos.py <ticket>")
        print("Ejemplo: python buscar_closes_fallidos.py 17671052")
        sys.exit(1)
    
    ticket = sys.argv[1]
    common_dir = get_common_files_dir()
    v3_phoenix = common_dir / V3_PHOENIX_DIR
    
    print("=" * 80)
    print(f"BUSCANDO EVENTOS CLOSE PARA TICKET: {ticket}")
    print("=" * 80)
    print()
    
    if not v3_phoenix.exists():
        print(f"[NO] El directorio {v3_phoenix} no existe")
        return
    
    worker_files = list(v3_phoenix.glob("historico_WORKER_*.csv"))
    
    if not worker_files:
        print(f"[NO] No se encontraron archivos historico_WORKER_*.csv")
        return
    
    found_any = False
    for worker_file in sorted(worker_files):
        worker_id = worker_file.stem.replace("historico_WORKER_", "")
        close_events = search_close_events(worker_file, ticket)
        
        if close_events:
            found_any = True
            print(f"\nWorker ID: {worker_id}")
            print("-" * 80)
            for event in close_events:
                print(f"Linea {event['line_num']}: {event['line']}")
                print(f"   -> Resultado: {event['resultado']}")
                print(f"   -> Evento: {event['event_type']}")
    
    if not found_any:
        print(f"\n[NO] No se encontraron eventos CLOSE para el ticket {ticket} en ningun Worker")
        print("\n[CONCLUSION] El evento CLOSE nunca se proceso en los Workers.")
        print("   Posibles causas:")
        print("   1. El evento CLOSE no llego a las colas de los Workers")
        print("   2. El Worker leyo el evento pero fallo al procesarlo")
        print("   3. El Worker encontro la orden ya cerrada pero no lo registro")


if __name__ == "__main__":
    main()

