#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Eliminar operaciones cerradas del archivo open_logs"""

from pathlib import Path
import os

def main():
    common = Path(os.path.expanduser('~')) / 'AppData' / 'Roaming' / 'MetaQuotes' / 'Terminal' / 'Common' / 'Files' / 'V3' / 'Phoenix'
    open_logs = common / 'open_logs_3037589.csv'
    
    if not open_logs.exists():
        print(f"Archivo no existe: {open_logs}")
        return
    
    lines = open_logs.read_text(encoding='utf-8').splitlines()
    
    # Operaciones cerradas según usuario
    cerradas = ['17669368', '17671052', '17672880']
    
    # Filtrar líneas
    filtradas = []
    eliminadas = []
    
    for line in lines:
        if not line.strip():
            continue
        ticket = line.split(';')[0] if ';' in line else line
        if ticket in cerradas:
            eliminadas.append(ticket)
        else:
            filtradas.append(line)
    
    # Escribir archivo actualizado
    open_logs.write_text('\n'.join(filtradas) + '\n', encoding='utf-8')
    
    print(f"Archivo actualizado: {len(filtradas)} líneas (eliminadas {len(eliminadas)} cerradas)")
    print(f"\nOperaciones eliminadas: {', '.join(eliminadas)}")
    print(f"\nOperaciones restantes ({len(filtradas)}):")
    for line in filtradas:
        if line.strip():
            ticket = line.split(';')[0]
            print(f"  {ticket}")

if __name__ == "__main__":
    main()

