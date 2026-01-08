#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para generar open_logs_{AccountNumber}.csv desde los históricos
Identifica operaciones OPEN que no tienen CLOSE correspondiente
"""

from pathlib import Path
import os
import time

def get_common_files_dir():
    """Obtiene la ruta del directorio Common\Files\V3\Phoenix"""
    return Path(os.path.expanduser('~')) / 'AppData' / 'Roaming' / 'MetaQuotes' / 'Terminal' / 'Common' / 'Files' / 'V3' / 'Phoenix'

def parse_worker_history(hist_path: Path) -> dict:
    """
    Parsea el histórico del worker y retorna:
    - open_operations: dict[ticket_maestro] = {event_type, ticket, order_type, lots, symbol, sl, tp, ...}
    - closed_tickets: set de tickets que tienen CLOSE
    """
    if not hist_path.exists():
        print(f"[WARN] Archivo no existe: {hist_path}")
        return {}, set()
    
    lines = hist_path.read_text(encoding='utf-8', errors='replace').splitlines()
    if not lines:
        return {}, set()
    
    # Detectar header
    header = lines[0]
    start_idx = 1 if 'worker_exec_time' in header.lower() or 'event_type' in header.lower() else 0
    
    open_operations = {}
    closed_tickets = set()
    
    for line in lines[start_idx:]:
        if not line.strip():
            continue
        
        parts = line.split(';')
        if len(parts) < 4:
            continue
        
        # Formato actualizado: worker_exec_time;worker_read_time;resultado;event_type;ticket;order_type;lots;symbol;...
        # Formato antiguo: timestamp_ejecucion;resultado;event_type;ticket;order_type;lots;symbol;...
        
        # Detectar formato
        if len(parts) >= 15:
            # Formato nuevo con worker_read_time
            worker_exec_time = parts[0]
            worker_read_time = parts[1]
            resultado = parts[2]
            event_type = parts[3]
            ticket = parts[4]
            order_type = parts[5] if len(parts) > 5 else ""
            lots = parts[6] if len(parts) > 6 else ""
            symbol = parts[7] if len(parts) > 7 else ""
            sl = parts[10] if len(parts) > 10 else ""
            tp = parts[11] if len(parts) > 11 else ""
        elif len(parts) >= 13:
            # Formato antiguo
            worker_exec_time = parts[0]
            resultado = parts[1]
            event_type = parts[2]
            ticket = parts[3]
            order_type = parts[4] if len(parts) > 4 else ""
            lots = parts[5] if len(parts) > 5 else ""
            symbol = parts[6] if len(parts) > 6 else ""
            sl = parts[9] if len(parts) > 9 else ""
            tp = parts[10] if len(parts) > 10 else ""
        else:
            continue
        
        event_type = event_type.strip().upper()
        ticket = ticket.strip()
        
        if event_type == "OPEN":
            # Guardar operación OPEN
            open_operations[ticket] = {
                'ticket': ticket,
                'order_type': order_type.strip(),
                'lots': lots.strip(),
                'symbol': symbol.strip(),
                'sl': sl.strip(),
                'tp': tp.strip(),
                'resultado': resultado.strip() if len(parts) > 2 else ""
            }
        elif event_type == "CLOSE":
            # Marcar como cerrada
            closed_tickets.add(ticket)
    
    return open_operations, closed_tickets

def main():
    common_dir = get_common_files_dir()
    
    if not common_dir.exists():
        print(f"[ERROR] Directorio no existe: {common_dir}")
        return
    
    # Buscar todos los históricos de workers
    hist_files = list(common_dir.glob('historico_WORKER_*.csv'))
    
    if not hist_files:
        print("[ERROR] No se encontraron archivos históricos")
        return
    
    print(f"[INFO] Encontrados {len(hist_files)} archivos históricos")
    
    all_open_ops = {}  # ticket_maestro -> {info, worker_id}
    
    for hist_path in hist_files:
        # Extraer worker_id del nombre del archivo
        worker_id = hist_path.stem.replace('historico_WORKER_', '')
        print(f"\n[INFO] Procesando histórico: {hist_path.name} (Worker: {worker_id})")
        
        open_ops, closed_tickets = parse_worker_history(hist_path)
        
        print(f"  - Operaciones OPEN encontradas: {len(open_ops)}")
        print(f"  - Operaciones CLOSE encontradas: {len(closed_tickets)}")
        
        # Filtrar: solo las que NO tienen CLOSE
        for ticket, info in open_ops.items():
            if ticket not in closed_tickets:
                # Verificar que no sea un "Ya existe operacion abierta" (esas ya están abiertas)
                if info['resultado'] == "Ya existe operacion abierta" or info['resultado'] == "EXITOSO":
                    all_open_ops[ticket] = {
                        **info,
                        'worker_id': worker_id
                    }
                    print(f"  [OPEN] Ticket {ticket}: {info['symbol']} {info['order_type']} {info['lots']} lots")
    
    print(f"\n[INFO] Total operaciones abiertas identificadas: {len(all_open_ops)}")
    
    if not all_open_ops:
        print("[WARN] No se encontraron operaciones abiertas")
        return
    
    # Agrupar por worker_id
    by_worker = {}
    for ticket, info in all_open_ops.items():
        worker_id = info['worker_id']
        if worker_id not in by_worker:
            by_worker[worker_id] = []
        by_worker[worker_id].append((ticket, info))
    
    # Generar archivos open_logs para cada worker
    print("\n[INFO] Generando archivos open_logs...")
    
    for worker_id, ops in by_worker.items():
        open_logs_file = common_dir / f"open_logs_{worker_id}.csv"
        
        print(f"\n[INFO] Generando: {open_logs_file.name}")
        print(f"  - Operaciones a escribir: {len(ops)}")
        
        # Leer archivo existente si existe (para no duplicar)
        existing_tickets = set()
        existing_lines = []
        if open_logs_file.exists():
            existing_lines = open_logs_file.read_text(encoding='utf-8', errors='replace').splitlines()
            for line in existing_lines:
                if line.strip():
                    parts = line.split(';')
                    if len(parts) >= 2:
                        existing_tickets.add(parts[0].strip())
            print(f"  - Entradas existentes en archivo: {len(existing_tickets)}")
        
        # Escribir archivo
        with open(open_logs_file, 'w', encoding='utf-8', newline='') as f:
            # Escribir líneas existentes (si no están en las nuevas)
            for line in existing_lines:
                if line.strip():
                    parts = line.split(';')
                    if len(parts) >= 2 and parts[0].strip() not in [t for t, _ in ops]:
                        f.write(line + '\n')
            
            # Escribir nuevas operaciones
            timestamp_ms = str(int(time.time() * 1000))
            for ticket, info in ops:
                if ticket not in existing_tickets:
                    # Formato: ticket_maestro;ticket_worker;timestamp;symbol;magic
                    # ticket_worker lo obtendremos desde MetaTrader (por ahora ponemos 0, se actualizará)
                    # magic = ticket_maestro (convertido a int)
                    magic = ticket
                    line = f"{ticket};0;{timestamp_ms};{info['symbol']};{magic}\n"
                    f.write(line)
                    print(f"    + {ticket} ({info['symbol']} {info['order_type']})")
        
        print(f"  [OK] Archivo generado: {open_logs_file.name}")
    
    print("\n[INFO] IMPORTANTE:")
    print("  Los archivos open_logs se generaron con ticket_worker=0")
    print("  Necesitas ejecutar un script MQL4/MQL5 para:")
    print("  1. Buscar las órdenes abiertas por MagicNumber/Comment")
    print("  2. Actualizar ticket_worker en los archivos open_logs")
    print("\n  O simplemente reiniciar el Worker y las nuevas operaciones se escribirán correctamente.")
    print("  Las operaciones existentes usarán el fallback (MagicNumber/Comment) hasta que se cierren.")

if __name__ == "__main__":
    main()

