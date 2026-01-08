"""
revisar_spool_y_pendientes.py
------------------------------
Revisa el spool y archivos pendientes para encontrar eventos CLOSE no procesados.
"""

from pathlib import Path
import os
import sys

DEFAULT_COMMON_FILES_DIR = Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"
V3_PHOENIX_DIR = Path("V3") / "Phoenix"
SPOOL_DIR = Path("V3") / "Phoenix" / "Spool"


def get_common_files_dir() -> Path:
    env_dir = os.getenv("COMMON_FILES_DIR")
    if env_dir:
        return Path(env_dir)
    return DEFAULT_COMMON_FILES_DIR


def search_in_spool(spool_path: Path, ticket: str):
    """Busca eventos en el spool."""
    if not spool_path.exists():
        print(f"[NO] El directorio spool no existe: {spool_path}")
        return []
    
    results = []
    # Buscar archivos .txt en el spool
    for event_file in spool_path.glob("*.txt"):
        try:
            encodings = ["utf-8", "utf-8-sig", "latin-1", "cp1252"]
            content = None
            for encoding in encodings:
                try:
                    with open(event_file, "r", encoding=encoding) as f:
                        content = f.read()
                        break
                except (UnicodeDecodeError, UnicodeError):
                    continue
            
            if content and ticket in content:
                # Parsear contenido
                parts = content.split("|")
                event_type = ""
                ticket_found = ""
                for part in parts:
                    if "=" in part:
                        key, value = part.split("=", 1)
                        if key.strip() == "EVENT":
                            event_type = value.strip()
                        elif key.strip() == "TICKET":
                            ticket_found = value.strip()
                
                if ticket_found == ticket:
                    results.append({
                        "file": event_file.name,
                        "event_type": event_type,
                        "content": content.strip()
                    })
        except Exception as exc:
            print(f"[ERROR] Error leyendo {event_file}: {exc}")
    
    return results


def search_pending_files(v3_phoenix: Path, ticket: str):
    """Busca en archivos pendientes."""
    pending_files = list(v3_phoenix.glob("pendientes_worker_*.csv"))
    
    results = []
    for pending_file in pending_files:
        try:
            encodings = ["utf-8", "utf-8-sig", "latin-1", "cp1252"]
            content = None
            for encoding in encodings:
                try:
                    with open(pending_file, "r", encoding=encoding) as f:
                        content = f.readlines()
                        break
                except (UnicodeDecodeError, UnicodeError):
                    continue
            
            if content:
                for line_num, line in enumerate(content, 1):
                    if ticket in line:
                        results.append({
                            "file": pending_file.name,
                            "line_num": line_num,
                            "line": line.strip()
                        })
        except Exception as exc:
            print(f"[ERROR] Error leyendo {pending_file}: {exc}")
    
    return results


def main():
    if len(sys.argv) < 2:
        print("Uso: python revisar_spool_y_pendientes.py <ticket>")
        print("Ejemplo: python revisar_spool_y_pendientes.py 17671052")
        sys.exit(1)
    
    ticket = sys.argv[1]
    common_dir = get_common_files_dir()
    v3_phoenix = common_dir / V3_PHOENIX_DIR
    spool_path = common_dir / SPOOL_DIR
    
    print("=" * 80)
    print(f"REVISION DE SPOOL Y ARCHIVOS PENDIENTES PARA TICKET: {ticket}")
    print("=" * 80)
    print()
    
    # 1. Buscar en spool
    print("1. BUSCANDO EN SPOOL:")
    print("-" * 80)
    spool_results = search_in_spool(spool_path, ticket)
    
    if spool_results:
        print(f"[ENCONTRADO] {len(spool_results)} eventos en el spool:")
        for result in spool_results:
            print(f"   Archivo: {result['file']}")
            print(f"   Evento: {result['event_type']}")
            print(f"   Contenido: {result['content']}")
            print()
    else:
        print(f"[NO] No se encontro el ticket {ticket} en el spool")
        print("   (Esto es normal si el evento ya fue procesado)")
    print()
    
    # 2. Buscar en archivos pendientes
    print("2. BUSCANDO EN ARCHIVOS PENDIENTES:")
    print("-" * 80)
    pending_results = search_pending_files(v3_phoenix, ticket)
    
    if pending_results:
        print(f"[ENCONTRADO] {len(pending_results)} eventos en archivos pendientes:")
        for result in pending_results:
            print(f"   Archivo: {result['file']}")
            print(f"   Linea {result['line_num']}: {result['line']}")
            print()
    else:
        print(f"[NO] No se encontro el ticket {ticket} en archivos pendientes")
    print()
    
    # 3. Resumen
    print("=" * 80)
    print("RESUMEN:")
    print("-" * 80)
    if spool_results:
        print(f"[PROBLEMA] El evento CLOSE aun esta en el spool (no fue procesado)")
    elif pending_results:
        print(f"[PROBLEMA] El evento CLOSE esta en archivos pendientes (fallo al escribir)")
    else:
        print(f"[OK] El evento CLOSE no esta en spool ni pendientes")
        print(f"   -> Fue procesado por el Distribuidor pero no llego a los Workers")
        print(f"   -> O los Workers lo procesaron pero no lo registraron correctamente")


if __name__ == "__main__":
    main()

