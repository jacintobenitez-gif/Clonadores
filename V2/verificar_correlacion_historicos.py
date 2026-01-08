"""
Script de verificación de correlación entre históricos
-------------------------------------------------------

Compara historico_clonacion.txt con historico_WORKER_<account>.txt
para detectar eventos distribuidos pero no procesados por los Workers.

Uso:
    python verificar_correlacion_historicos.py [--common-dir PATH] [--workers WORKER1,WORKER2]
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Set, Tuple

# Configurar salida UTF-8 para Windows
if sys.platform == "win32":
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')


@dataclass
class EventoDistribuido:
    """Evento distribuido desde historico_clonacion.txt"""
    ticket: str
    worker_id: str
    resultado: str
    timestamp: str


@dataclass
class EventoMaster:
    """Evento desde Historico_Master.txt"""
    event_type: str
    ticket: str
    order_type: str
    lots: str
    symbol: str
    sl: str
    tp: str
    timestamp: str


@dataclass
class EventoWorker:
    """Evento procesado desde historico_WORKER_<account>.txt"""
    timestamp_ejecucion: str
    resultado: str
    event_type: str
    ticket: str
    order_type: str
    lots: str
    symbol: str


def default_common_files_dir() -> Path:
    """Ruta por defecto de Common\\Files (MetaTrader)."""
    home = Path.home()
    return home / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files" / "V2" / "Phoenix"


def leer_historico_clonacion(hist_path: Path) -> List[EventoDistribuido]:
    """Lee historico_clonacion.txt y retorna lista de eventos distribuidos."""
    eventos = []
    if not hist_path.exists():
        print(f"[WARN] No existe {hist_path}")
        return eventos
    
    try:
        with open(hist_path, "r", encoding="utf-8") as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                
                parts = line.split(";")
                if len(parts) >= 4:
                    ticket = parts[0].strip()
                    worker_id = parts[1].strip()
                    resultado = parts[2].strip()
                    timestamp = parts[3].strip() if len(parts) > 3 else ""
                    
                    eventos.append(EventoDistribuido(
                        ticket=ticket,
                        worker_id=worker_id,
                        resultado=resultado,
                        timestamp=timestamp
                    ))
                else:
                    print(f"[WARN] Línea {line_num} inválida en historico_clonacion.txt: {line}")
    except Exception as e:
        print(f"[ERROR] Error leyendo historico_clonacion.txt: {e}")
    
    return eventos


def leer_historico_master(hist_path: Path) -> Dict[str, EventoMaster]:
    """Lee Historico_Master.txt y retorna dict por ticket."""
    eventos = {}
    if not hist_path.exists():
        print(f"[WARN] No existe {hist_path}")
        return eventos
    
    try:
        with open(hist_path, "r", encoding="utf-8") as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                if not line or line.startswith("#") or line.lower().startswith("event_type"):
                    continue
                
                parts = line.split(";")
                if len(parts) >= 2:
                    event_type = parts[0].strip()
                    ticket = parts[1].strip()
                    
                    order_type = parts[2].strip() if len(parts) > 2 else ""
                    lots = parts[3].strip() if len(parts) > 3 else ""
                    symbol = parts[4].strip() if len(parts) > 4 else ""
                    sl = parts[5].strip() if len(parts) > 5 else ""
                    tp = parts[6].strip() if len(parts) > 6 else ""
                    timestamp = parts[7].strip() if len(parts) > 7 else ""
                    
                    # Usar ticket como clave (puede haber múltiples eventos con mismo ticket si se distribuye varias veces)
                    # Pero normalmente cada ticket aparece una vez por event_type
                    key = f"{ticket}_{event_type}"
                    eventos[key] = EventoMaster(
                        event_type=event_type,
                        ticket=ticket,
                        order_type=order_type,
                        lots=lots,
                        symbol=symbol,
                        sl=sl,
                        tp=tp,
                        timestamp=timestamp
                    )
                else:
                    print(f"[WARN] Línea {line_num} inválida en Historico_Master.txt: {line}")
    except Exception as e:
        print(f"[ERROR] Error leyendo Historico_Master.txt: {e}")
    
    return eventos


def leer_historico_worker(hist_path: Path) -> Dict[str, EventoWorker]:
    """Lee historico_WORKER_<account>.txt y retorna dict por (ticket, event_type)."""
    eventos = {}
    if not hist_path.exists():
        print(f"[WARN] No existe {hist_path}")
        return eventos
    
    try:
        # Intentar leer como UTF-8 primero, si falla intentar con detección de codificación
        try:
            with open(hist_path, "r", encoding="utf-8") as f:
                content = f.read()
        except UnicodeDecodeError:
            # Si falla UTF-8, intentar leer como binario y detectar codificación
            with open(hist_path, "rb") as f:
                raw_bytes = f.read()
                # Saltar BOM UTF-8 si existe
                if raw_bytes.startswith(b'\xef\xbb\xbf'):
                    raw_bytes = raw_bytes[3:]
                content = raw_bytes.decode("utf-8", errors="replace")
        
        # Procesar líneas
        for line_num, line in enumerate(content.splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # Verificar si es header (case-insensitive)
            if line.lower().startswith("timestamp_ejecucion"):
                continue
            
            parts = line.split(";")
            if len(parts) >= 4:
                timestamp_ejecucion = parts[0].strip()
                resultado = parts[1].strip()
                event_type = parts[2].strip()
                ticket = parts[3].strip()
                
                order_type = parts[4].strip() if len(parts) > 4 else ""
                lots = parts[5].strip() if len(parts) > 5 else ""
                symbol = parts[6].strip() if len(parts) > 6 else ""
                
                # Clave única por ticket y event_type
                key = f"{ticket}_{event_type}"
                eventos[key] = EventoWorker(
                    timestamp_ejecucion=timestamp_ejecucion,
                    resultado=resultado,
                    event_type=event_type,
                    ticket=ticket,
                    order_type=order_type,
                    lots=lots,
                    symbol=symbol
                )
            else:
                print(f"[WARN] Línea {line_num} inválida en historico_WORKER: {line}")
    except Exception as e:
        print(f"[ERROR] Error leyendo historico_WORKER: {e}")
    
    return eventos


def verificar_correlacion(
    common_dir: Path,
    worker_ids: List[str] | None = None
) -> None:
    """Verifica correlación entre históricos."""
    
    hist_clonacion_path = common_dir / "historico_clonacion.txt"
    hist_master_path = common_dir / "Historico_Master.txt"
    
    print("=" * 80)
    print("VERIFICACIÓN DE CORRELACIÓN ENTRE HISTÓRICOS")
    print("=" * 80)
    print(f"\nDirectorio base: {common_dir}")
    print(f"historico_clonacion.txt: {hist_clonacion_path}")
    print(f"Historico_Master.txt: {hist_master_path}")
    
    # Leer eventos distribuidos (solo OK)
    print("\n[1] Leyendo historico_clonacion.txt...")
    eventos_distribuidos = leer_historico_clonacion(hist_clonacion_path)
    eventos_ok = [e for e in eventos_distribuidos if e.resultado == "OK"]
    print(f"   Total eventos distribuidos: {len(eventos_distribuidos)}")
    print(f"   Eventos con resultado OK: {len(eventos_ok)}")
    
    if not eventos_ok:
        print("\n[INFO] No hay eventos distribuidos con resultado OK para verificar.")
        return
    
    # Leer eventos del Master para obtener event_type
    print("\n[2] Leyendo Historico_Master.txt...")
    eventos_master = leer_historico_master(hist_master_path)
    print(f"   Eventos en Master: {len(eventos_master)}")
    
    # Agrupar eventos distribuidos por worker_id
    eventos_por_worker: Dict[str, List[EventoDistribuido]] = defaultdict(list)
    for ev in eventos_ok:
        eventos_por_worker[ev.worker_id].append(ev)
    
    # Si no se especifican workers, usar todos los encontrados
    if worker_ids is None:
        worker_ids = list(eventos_por_worker.keys())
    
    print(f"\n[3] Verificando workers: {', '.join(worker_ids)}")
    
    # Verificar cada worker
    total_faltantes = 0
    total_procesados = 0
    
    for worker_id in worker_ids:
        print(f"\n{'=' * 80}")
        print(f"WORKER: {worker_id}")
        print(f"{'=' * 80}")
        
        # Eventos distribuidos a este worker
        eventos_worker = eventos_por_worker.get(worker_id, [])
        if not eventos_worker:
            print(f"   [INFO] No hay eventos distribuidos para este worker.")
            continue
        
        # Leer histórico del worker
        hist_worker_path = common_dir / f"historico_WORKER_{worker_id}.txt"
        print(f"\n   Leyendo: {hist_worker_path}")
        eventos_procesados = leer_historico_worker(hist_worker_path)
        print(f"   Eventos procesados encontrados: {len(eventos_procesados)}")
        
        # Construir conjunto de eventos esperados (ticket + event_type)
        eventos_esperados: Set[Tuple[str, str]] = set()
        eventos_faltantes: List[Tuple[EventoDistribuido, str]] = []
        eventos_sin_event_type: List[EventoDistribuido] = []
        
        # Agrupar eventos distribuidos por ticket para manejar múltiples distribuciones
        tickets_distribuidos: Dict[str, List[EventoDistribuido]] = defaultdict(list)
        for ev_dist in eventos_worker:
            tickets_distribuidos[ev_dist.ticket].append(ev_dist)
        
        # Para cada ticket, buscar sus event_types en Master y verificar procesamiento
        for ticket, distribuciones in tickets_distribuidos.items():
            # Buscar todos los event_types posibles para este ticket en Master
            event_types_en_master = []
            eventos_master_ticket = {}
            for key, ev_master in eventos_master.items():
                if ev_master.ticket == ticket:
                    event_types_en_master.append(ev_master.event_type)
                    eventos_master_ticket[ev_master.event_type] = ev_master
            
            if event_types_en_master:
                # Verificar cada event_type encontrado en Master
                for event_type in event_types_en_master:
                    eventos_esperados.add((ticket, event_type))
                    key = f"{ticket}_{event_type}"
                    if key not in eventos_procesados:
                        # Este event_type falta en el worker
                        # Usar la primera distribución de este ticket como referencia
                        eventos_faltantes.append((distribuciones[0], event_type))
            else:
                # No se encontró event_type en Master para este ticket
                eventos_sin_event_type.extend(distribuciones)
        
        # Mostrar resultados
        print(f"\n   Eventos distribuidos (OK): {len(eventos_worker)}")
        print(f"   Eventos procesados encontrados: {len(eventos_procesados)}")
        print(f"   Eventos esperados (con event_type): {len(eventos_esperados)}")
        print(f"   Eventos FALTANTES: {len(eventos_faltantes)}")
        if eventos_sin_event_type:
            print(f"   Eventos sin event_type en Master: {len(eventos_sin_event_type)}")
        
        if eventos_faltantes:
            print(f"\n   [ALERTA] EVENTOS DISTRIBUIDOS PERO NO PROCESADOS:")
            print(f"   {'-' * 76}")
            for ev_dist, event_type in eventos_faltantes:
                # Buscar info adicional en Master
                key = f"{ev_dist.ticket}_{event_type}"
                ev_master = eventos_master.get(key)
                symbol_info = f" ({ev_master.symbol})" if ev_master else ""
                
                print(f"   - Ticket: {ev_dist.ticket:>10} | Tipo: {event_type:>6} | "
                      f"Distribuido: {ev_dist.timestamp}{symbol_info}")
        
        if eventos_sin_event_type:
            print(f"\n   [WARN] EVENTOS DISTRIBUIDOS SIN EVENT_TYPE EN MASTER:")
            print(f"   {'-' * 76}")
            for ev_dist in eventos_sin_event_type[:10]:  # Mostrar solo los primeros 10
                print(f"   - Ticket: {ev_dist.ticket:>10} | Distribuido: {ev_dist.timestamp}")
            if len(eventos_sin_event_type) > 10:
                print(f"   ... y {len(eventos_sin_event_type) - 10} más")
        
        if not eventos_faltantes and not eventos_sin_event_type:
            print(f"\n   [OK] Todos los eventos distribuidos fueron procesados.")
        
        # Mostrar algunos eventos procesados como referencia
        if eventos_procesados:
            print(f"\n   Ejemplos de eventos procesados (últimos 5):")
            eventos_lista = list(eventos_procesados.values())
            for ev in eventos_lista[-5:]:
                print(f"   - Ticket: {ev.ticket:>10} | Tipo: {ev.event_type:>6} | "
                      f"Resultado: {ev.resultado[:30]:<30} | Ejecutado: {ev.timestamp_ejecucion}")
        
        total_faltantes += len(eventos_faltantes)
        total_procesados += len(eventos_procesados)
    
    # Resumen final
    print(f"\n{'=' * 80}")
    print("RESUMEN FINAL")
    print(f"{'=' * 80}")
    print(f"Total eventos distribuidos (OK): {len(eventos_ok)}")
    print(f"Total eventos procesados: {total_procesados}")
    print(f"Total eventos FALTANTES: {total_faltantes}")
    
    if total_faltantes > 0:
        print(f"\n[ALERTA] Se encontraron {total_faltantes} eventos distribuidos que no aparecen en los históricos de los workers.")
        print("   Posibles causas:")
        print("   - El evento aún está en la cola esperando procesamiento")
        print("   - ParseLine falló y la línea se añadió a remaining pero nunca se procesó")
        print("   - El Worker no está leyendo la cola correctamente")
        print("   - Error crítico antes de AppendHistory")
    else:
        print(f"\n[OK] Todos los eventos distribuidos fueron procesados correctamente.")


def main():
    parser = argparse.ArgumentParser(
        description="Verifica correlación entre historico_clonacion.txt y historico_WORKER_<account>.txt"
    )
    parser.add_argument(
        "--common-dir",
        type=Path,
        default=None,
        help="Directorio Common\\Files (por defecto: detecta automáticamente)"
    )
    parser.add_argument(
        "--workers",
        type=str,
        default=None,
        help="Lista de worker IDs separados por coma (ej: 511029358,3037589). Por defecto: todos los encontrados"
    )
    
    args = parser.parse_args()
    
    # Determinar directorio
    if args.common_dir:
        common_dir = Path(args.common_dir)
    else:
        common_dir = default_common_files_dir()
    
    if not common_dir.exists():
        print(f"[ERROR] El directorio no existe: {common_dir}")
        return 1
    
    # Parsear workers
    worker_ids = None
    if args.workers:
        worker_ids = [w.strip() for w in args.workers.split(",") if w.strip()]
    
    try:
        verificar_correlacion(common_dir, worker_ids)
        return 0
    except Exception as e:
        print(f"\n[ERROR] Error durante la verificación: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    exit(main())

