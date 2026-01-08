#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para actualizar manualmente open_logs con los ticket_worker
basándose en las órdenes activas proporcionadas por el usuario
"""

from pathlib import Path
import os
import time

def main():
    common = Path(os.path.expanduser('~')) / 'AppData' / 'Roaming' / 'MetaQuotes' / 'Terminal' / 'Common' / 'Files' / 'V3' / 'Phoenix'
    open_logs = common / 'open_logs_3037589.csv'
    
    if not open_logs.exists():
        print(f"Archivo no existe: {open_logs}")
        return
    
    # Leer archivo actual
    lines = open_logs.read_text(encoding='utf-8').splitlines()
    
    # Ordenes activas proporcionadas por el usuario (estos son los ticket_maestro)
    ordenes_activas = {
        '17677089', '17666928', '17666835', '17666785', '17666038', 
        '17665162', '17664986', '17489827', '17489824', '17415794', '17415765'
    }
    
    print(f"Ordenes activas proporcionadas: {len(ordenes_activas)}")
    print(f"Líneas en archivo: {len(lines)}")
    
    # Actualizar líneas
    updated_lines = []
    updated_count = 0
    
    for line in lines:
        if not line.strip():
            continue
        
        parts = line.split(';')
        if len(parts) < 2:
            updated_lines.append(line)
            continue
        
        ticket_maestro = parts[0].strip()
        ticket_worker_str = parts[1].strip()
        
        # Si ticket_worker es 0 y el ticket_maestro está en las órdenes activas
        # Necesitamos obtener el ticket_worker real desde MetaTrader
        # Por ahora, dejamos 0 y el Worker buscará por MagicNumber/Comment
        if ticket_worker_str == '0':
            if ticket_maestro in ordenes_activas:
                # Mantener 0 por ahora - el Worker buscará por MagicNumber/Comment
                print(f"  Ticket {ticket_maestro}: Mantiene ticket_worker=0 (Worker buscará por MagicNumber/Comment)")
            else:
                # Esta orden ya no está activa, eliminarla
                print(f"  Ticket {ticket_maestro}: ELIMINADO (no está en órdenes activas)")
                continue
        
        updated_lines.append(line)
    
    # Escribir archivo actualizado
    open_logs.write_text('\n'.join(updated_lines) + '\n', encoding='utf-8')
    
    print(f"\n[OK] Archivo actualizado: {len(updated_lines)} líneas")
    print("\nNOTA: Los ticket_worker siguen en 0.")
    print("El Worker buscará las órdenes por MagicNumber/Comment cuando llegue un CLOSE.")
    print("Esto funcionará correctamente gracias al fallback implementado.")

if __name__ == "__main__":
    main()

