#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from pathlib import Path
import os

common = Path(os.path.expanduser('~')) / 'AppData' / 'Roaming' / 'MetaQuotes' / 'Terminal' / 'Common' / 'Files' / 'V3' / 'Phoenix'
open_logs = common / 'open_logs_3037589.csv'

if open_logs.exists():
    lines = open_logs.read_text(encoding='utf-8').splitlines()
    tickets = [l.split(';')[0] for l in lines if l.strip()]
    print('Tickets en open_logs_3037589.csv:')
    for t in tickets:
        print(f'  {t}')
    print(f'\nTotal: {len(tickets)}')
    print('\nBuscando tickets problemáticos:')
    print(f'  17490030: {"ENCONTRADO" if "17490030" in tickets else "NO ENCONTRADO"}')
    print(f'  17665163: {"ENCONTRADO" if "17665163" in tickets else "NO ENCONTRADO"}')
else:
    print('Archivo no existe')

