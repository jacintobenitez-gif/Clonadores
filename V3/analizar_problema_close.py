"""
analizar_problema_close.py
--------------------------
Análisis detallado del problema de CLOSE para un ticket específico.
Busca patrones, errores y posibles causas.
"""

from pathlib import Path
import os
import sys
from datetime import datetime

DEFAULT_COMMON_FILES_DIR = Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"
V3_PHOENIX_DIR = Path("V3") / "Phoenix"


def get_common_files_dir() -> Path:
    env_dir = os.getenv("COMMON_FILES_DIR")
    if env_dir:
        return Path(env_dir)
    return DEFAULT_COMMON_FILES_DIR


def parse_worker_line(line: str):
    """Parsea una línea del histórico del Worker."""
    parts = line.strip().split(";")
    if len(parts) < 5:
        return None
    
    # Detectar formato
    first_field = parts[0]
    is_old_format = "." in first_field or " " in first_field or len(first_field) > 15
    
    if is_old_format:
        # Formato antiguo: timestamp;resultado;event_type;ticket;...
        return {
            "timestamp": parts[0],
            "resultado": parts[1] if len(parts) > 1 else "",
            "event_type": parts[2] if len(parts) > 2 else "",
            "ticket": parts[3] if len(parts) > 3 else "",
            "order_type": parts[4] if len(parts) > 4 else "",
            "lots": parts[5] if len(parts) > 5 else "",
            "symbol": parts[6] if len(parts) > 6 else "",
        }
    else:
        # Formato nuevo: worker_exec_time;worker_read_time;resultado;event_type;ticket;...
        return {
            "worker_exec_time": parts[0],
            "worker_read_time": parts[1] if len(parts) > 1 else "",
            "resultado": parts[2] if len(parts) > 2 else "",
            "event_type": parts[3] if len(parts) > 3 else "",
            "ticket": parts[4] if len(parts) > 4 else "",
            "order_type": parts[5] if len(parts) > 5 else "",
            "lots": parts[6] if len(parts) > 6 else "",
            "symbol": parts[7] if len(parts) > 7 else "",
        }


def analyze_worker_history(hist_path: Path, ticket: str):
    """Analiza el histórico completo del Worker para entender el contexto."""
    if not hist_path.exists():
        return None
    
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
            return None
        
        # Buscar todas las líneas relacionadas con el ticket
        ticket_lines = []
        for line_num, line in enumerate(content, 1):
            if ticket in line:
                parsed = parse_worker_line(line)
                if parsed:
                    parsed["line_num"] = line_num
                    parsed["raw_line"] = line.strip()
                    ticket_lines.append(parsed)
        
        # Buscar líneas cercanas (antes y después) para contexto
        context_lines = []
        if ticket_lines:
            first_line_num = ticket_lines[0]["line_num"]
            # Buscar 5 líneas antes y después
            start = max(0, first_line_num - 6)
            end = min(len(content), first_line_num + 5)
            
            for line_num in range(start, end):
                if line_num + 1 != first_line_num:  # No incluir la línea del ticket
                    line = content[line_num].strip()
                    if line and not line.startswith("worker_exec_time") and not line.startswith("timestamp"):
                        parsed = parse_worker_line(line)
                        if parsed:
                            parsed["line_num"] = line_num + 1
                            parsed["raw_line"] = line
                            context_lines.append(parsed)
        
        return {
            "ticket_lines": ticket_lines,
            "context_lines": context_lines
        }
    except Exception as exc:
        print(f"[ERROR] Error analizando {hist_path}: {exc}")
        return None


def analyze_master_history(hist_path: Path, ticket: str):
    """Analiza el histórico master para ver el flujo completo."""
    if not hist_path.exists():
        return None
    
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
            return None
        
        ticket_events = []
        for line_num, line in enumerate(content, 1):
            if ticket in line:
                parts = line.strip().split(";")
                if len(parts) >= 2:
                    event_type = parts[0]
                    ticket_found = parts[1]
                    if ticket_found == ticket:
                        ticket_events.append({
                            "line_num": line_num,
                            "event_type": event_type,
                            "full_line": line.strip(),
                            "timestamps": {
                                "event_time": parts[7] if len(parts) > 7 else "",
                                "export_time": parts[8] if len(parts) > 8 else "",
                                "read_time": parts[9] if len(parts) > 9 else "",
                                "distribute_time": parts[10] if len(parts) > 10 else "",
                            }
                        })
        
        return ticket_events
    except Exception as exc:
        print(f"[ERROR] Error analizando master: {exc}")
        return None


def main():
    if len(sys.argv) < 2:
        print("Uso: python analizar_problema_close.py <ticket>")
        print("Ejemplo: python analizar_problema_close.py 17671052")
        sys.exit(1)
    
    ticket = sys.argv[1]
    common_dir = get_common_files_dir()
    v3_phoenix = common_dir / V3_PHOENIX_DIR
    hist_master_path = v3_phoenix / "Historico_Master.csv"
    
    print("=" * 80)
    print(f"ANALISIS DETALLADO DEL PROBLEMA DE CLOSE PARA TICKET: {ticket}")
    print("=" * 80)
    print()
    
    # 1. Analizar Historico_Master.csv
    print("1. ANALISIS DE Historico_Master.csv:")
    print("-" * 80)
    master_events = analyze_master_history(hist_master_path, ticket)
    
    if master_events:
        print(f"   Encontrados {len(master_events)} eventos:")
        for event in master_events:
            print(f"   Linea {event['line_num']}: {event['event_type']}")
            print(f"      Timestamps: event={event['timestamps']['event_time']}, "
                  f"export={event['timestamps']['export_time']}, "
                  f"read={event['timestamps']['read_time']}, "
                  f"distribute={event['timestamps']['distribute_time']}")
            print()
        
        # Analizar timing
        open_event = next((e for e in master_events if e['event_type'] == 'OPEN'), None)
        close_event = next((e for e in master_events if e['event_type'] == 'CLOSE'), None)
        
        if open_event and close_event:
            print("   [TIMING] Analisis de tiempos:")
            open_time = open_event['timestamps']['distribute_time'] or open_event['timestamps']['read_time']
            close_time = close_event['timestamps']['distribute_time'] or close_event['timestamps']['read_time']
            print(f"      OPEN distribuido: {open_time}")
            print(f"      CLOSE distribuido: {close_time}")
            if open_time and close_time:
                try:
                    # Intentar parsear timestamps
                    open_dt = datetime.strptime(open_time.split('.')[0], "%Y.%m.%d %H:%M:%S")
                    close_dt = datetime.strptime(close_time.split('.')[0], "%Y.%m.%d %H:%M:%S")
                    diff = close_dt - open_dt
                    print(f"      Diferencia: {diff.total_seconds()} segundos ({diff.total_seconds()/60:.1f} minutos)")
                except:
                    pass
    else:
        print(f"   [NO] No se encontraron eventos para el ticket {ticket}")
    print()
    
    # 2. Analizar históricos de Workers
    print("2. ANALISIS DE HISTORICOS DE WORKERS:")
    print("-" * 80)
    
    worker_files = list(v3_phoenix.glob("historico_WORKER_*.csv"))
    if not worker_files:
        print("   [NO] No se encontraron archivos historico_WORKER_*.csv")
    else:
        for worker_file in sorted(worker_files):
            worker_id = worker_file.stem.replace("historico_WORKER_", "")
            print(f"\n   Worker ID: {worker_id}")
            print("-" * 80)
            
            analysis = analyze_worker_history(worker_file, ticket)
            if analysis and analysis["ticket_lines"]:
                print(f"   [ENCONTRADO] {len(analysis['ticket_lines'])} lineas relacionadas:")
                for line_info in analysis["ticket_lines"]:
                    print(f"      Linea {line_info['line_num']}:")
                    print(f"         Evento: {line_info.get('event_type', 'N/A')}")
                    print(f"         Resultado: {line_info.get('resultado', 'N/A')}")
                    print(f"         Ticket: {line_info.get('ticket', 'N/A')}")
                    if 'timestamp' in line_info:
                        print(f"         Timestamp: {line_info['timestamp']}")
                    print(f"         Linea completa: {line_info['raw_line'][:100]}...")
                    print()
                
                # Analizar contexto
                if analysis["context_lines"]:
                    print(f"   [CONTEXTO] {len(analysis['context_lines'])} lineas cercanas:")
                    for ctx in analysis["context_lines"][:10]:  # Mostrar máximo 10
                        print(f"      Linea {ctx['line_num']}: {ctx.get('event_type', 'N/A')} - "
                              f"{ctx.get('ticket', 'N/A')} - {ctx.get('resultado', 'N/A')}")
            else:
                print(f"   [NO] No se encontro el ticket {ticket} en este Worker")
                print(f"   [PROBLEMA] El Worker nunca proceso el evento CLOSE")
    
    print()
    print("=" * 80)
    print("CONCLUSIONES:")
    print("-" * 80)
    
    # Determinar conclusiones
    has_open_in_master = any(e['event_type'] == 'OPEN' for e in master_events) if master_events else False
    has_close_in_master = any(e['event_type'] == 'CLOSE' for e in master_events) if master_events else False
    has_open_in_worker = False
    has_close_in_worker = False
    
    for worker_file in worker_files:
        analysis = analyze_worker_history(worker_file, ticket)
        if analysis and analysis["ticket_lines"]:
            for line_info in analysis["ticket_lines"]:
                if line_info.get('event_type') == 'OPEN':
                    has_open_in_worker = True
                if line_info.get('event_type') == 'CLOSE':
                    has_close_in_worker = True
    
    print(f"1. OPEN en Master: {'SI' if has_open_in_master else 'NO'}")
    print(f"2. CLOSE en Master: {'SI' if has_close_in_master else 'NO'}")
    print(f"3. OPEN en Worker: {'SI' if has_open_in_worker else 'NO'}")
    print(f"4. CLOSE en Worker: {'SI' if has_close_in_worker else 'NO'}")
    print()
    
    if has_open_in_master and has_close_in_master and has_open_in_worker and not has_close_in_worker:
        print("[PROBLEMA CONFIRMADO]")
        print("   - El evento CLOSE fue generado y distribuido correctamente")
        print("   - El Worker proceso el OPEN correctamente")
        print("   - PERO el Worker NO proceso el CLOSE")
        print()
        print("   Posibles causas:")
        print("   1. El Worker leyo el evento CLOSE pero fallo al procesarlo")
        print("   2. El Worker encontro la orden ya cerrada pero no la registro")
        print("   3. El Worker no encontro la orden (ni en MODE_TRADES ni en MODE_HISTORY)")
        print("   4. Bug en el codigo: el Worker procesa pero no registra en el historico")
        print()
        print("   RECOMENDACIONES:")
        print("   - Revisar logs de MetaTrader del Worker para ver errores")
        print("   - Verificar si el MagicNumber coincide entre OPEN y CLOSE")
        print("   - Verificar si el Comment coincide")
        print("   - Verificar si FindOrderInHistory() funciona correctamente")


if __name__ == "__main__":
    main()

