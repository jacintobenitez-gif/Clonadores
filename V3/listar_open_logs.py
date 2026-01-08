#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from pathlib import Path
import os

common = Path(os.path.expanduser('~')) / 'AppData' / 'Roaming' / 'MetaQuotes' / 'Terminal' / 'Common' / 'Files' / 'V3' / 'Phoenix'

if not common.exists():
    print(f'Directorio no existe: {common}')
    exit(1)

open_logs_files = list(common.glob('open_logs_*.csv'))
print(f'Archivos open_logs encontrados: {len(open_logs_files)}\n')

for f in open_logs_files:
    account = f.stem.replace('open_logs_', '')
    print(f'Archivo: {f.name}')
    print(f'  Cuenta: {account}')
    if f.exists():
        lines = f.read_text(encoding='utf-8').splitlines()
        tickets = [l.split(';')[0] for l in lines if l.strip()]
        print(f'  Tickets: {len(tickets)}')
        print(f'  Lista: {", ".join(tickets[:10])}{"..." if len(tickets) > 10 else ""}')
        
        # Buscar tickets problemáticos
        if '17490030' in tickets:
            print(f'  ✓ 17490030 ENCONTRADO')
        if '17665163' in tickets:
            print(f'  ✓ 17665163 ENCONTRADO')
    print()

