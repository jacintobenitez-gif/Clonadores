"""
Distribuidor.py (V3 Spool)
---------------------------

Servicio 24/7 que:
- Escanea eventos del spool generados por Extractor.mq4 (V3\Phoenix\Spool\)
- Parsea formato pipe-separated: EVT|EVENT=OPEN|TICKET=123|...
- Convierte a CSV mínimo para workers
- Distribuye cada evento a todas las colas `cola_WORKER_XX.csv`
- Borra archivos de evento después de procesar exitosamente
- Genera históricos: Historico_Master.csv e historico_clonacion.csv
"""

from __future__ import annotations

import os
import time
from datetime import datetime, timedelta
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Dict

# Configuración por defecto
DEFAULT_SPOOL_FOLDER = "V3\\Phoenix\\Spool"
DEFAULT_WORKER_IDS = ["01"]
DEFAULT_POLL_SECONDS = 1.0
CONFIG_FILENAME = "distribuidor_config.txt"
DEFAULT_RELOAD_MINUTES = 15.0


def default_common_files_dir() -> Path:
    """Ruta por defecto de Common\\Files (MetaTrader)."""
    home = Path.home()
    return home / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"


def env_list(name: str) -> List[str] | None:
    value = os.getenv(name)
    if not value:
        return None
    return [w.strip() for w in value.split(",") if w.strip()]


def env_float(name: str) -> float | None:
    value = os.getenv(name)
    if value is None:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def load_file_config(cfg_path: Path) -> dict:
    """
    Lee un fichero plano key=value (una clave por línea).
    Formato esperado:
      common_files_dir=C:\\Users\\...\\Common\\Files
      spool_folder=V3\\Phoenix\\Spool
      worker_ids=01,02,03
      worker_id=71617942|xaudusd-std=XAUUSD|eurusd-std=EURUSD
      poll_seconds=1.0
    Líneas vacías o que empiezan por # se ignoran.
    """
    cfg: dict = {}
    workers: List[str] = []
    symbol_mappings: dict[str, dict[str, str]] = {}
    if not cfg_path.exists():
        cfg["worker_ids_list"] = workers
        cfg["symbol_mappings"] = symbol_mappings
        return cfg
    try:
        for raw in cfg_path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if not key:
                continue
            if key == "worker_id":
                # Formato: worker_id=<id>|<symbol_origen>=<symbol_destino>|...
                if "|" in value:
                    parts = value.split("|", 1)
                    worker_id = parts[0].strip()
                    workers.append(worker_id)
                    
                    if len(parts) > 1 and parts[1].strip():
                        mappings_str = parts[1].strip()
                        worker_mappings: dict[str, str] = {}
                        for mapping_pair in mappings_str.split("|"):
                            mapping_pair = mapping_pair.strip()
                            if "=" in mapping_pair:
                                symbol_orig, symbol_dest = mapping_pair.split("=", 1)
                                symbol_orig = symbol_orig.strip().upper()
                                symbol_dest = symbol_dest.strip().upper()
                                if symbol_orig and symbol_dest:
                                    worker_mappings[symbol_orig] = symbol_dest
                        if worker_mappings:
                            symbol_mappings[worker_id] = worker_mappings
                else:
                    workers.append(value)
            else:
                cfg[key] = value
    except Exception as exc:
        print(f"[WARN] No se pudo leer {cfg_path}: {exc}")
    cfg["worker_ids_list"] = workers
    cfg["symbol_mappings"] = symbol_mappings
    
    # Debug: mostrar qué se encontró
    if workers:
        print(f"[DEBUG] load_file_config: Encontrados {len(workers)} workers: {workers}")
    else:
        print(f"[DEBUG] load_file_config: No se encontraron workers en config")
    
    return cfg


@dataclass
class Config:
    common_dir: Path
    spool_folder: str
    worker_ids: List[str]
    symbol_mappings: dict[str, dict[str, str]]
    poll_seconds: float
    reload_minutes: float


def load_config() -> Config:
    """
    Carga configuración en este orden de prioridad (hot-reload):
    1) Variables de entorno
    2) Fichero distribuidor_config.txt
    3) Valores por defecto
    """
    cfg_path = Path(__file__).resolve().parent / CONFIG_FILENAME
    print(f"[DEBUG] load_config: Buscando config en: {cfg_path}")
    print(f"[DEBUG] load_config: ¿Existe? {cfg_path.exists()}")
    file_cfg = load_file_config(cfg_path)
    print(f"[DEBUG] load_config: file_cfg keys = {list(file_cfg.keys())}")

    env_common = os.getenv("COMMON_FILES_DIR")
    file_common = file_cfg.get("common_files_dir")
    common_dir = (
        Path(env_common)
        if env_common
        else Path(file_common)
        if file_common
        else default_common_files_dir()
    )

    spool_folder = (
        os.getenv("SPOOL_FOLDER")
        or file_cfg.get("spool_folder")
        or DEFAULT_SPOOL_FOLDER
    )

    worker_ids: Optional[List[str]] = env_list("WORKER_IDS")
    if worker_ids is None:
        cfg_workers = file_cfg.get("worker_ids_list", [])
        print(f"[DEBUG] load_config: cfg_workers de file_cfg = {cfg_workers}")
        if cfg_workers:
            worker_ids = cfg_workers
        else:
            comma_workers = file_cfg.get("worker_ids", "")
            print(f"[DEBUG] load_config: comma_workers = '{comma_workers}'")
            worker_ids = [w.strip() for w in comma_workers.split(",") if w.strip()]
    if not worker_ids:
        worker_ids = DEFAULT_WORKER_IDS
        print(f"[WARN] No se encontraron worker_ids en config, usando por defecto: {worker_ids}")
    else:
        print(f"[DEBUG] load_config: worker_ids finales = {worker_ids}")

    symbol_mappings = file_cfg.get("symbol_mappings", {})

    poll_seconds = env_float("POLL_SECONDS")
    if poll_seconds is None:
        file_poll = file_cfg.get("poll_seconds")
        if file_poll:
            try:
                poll_seconds = float(file_poll)
            except ValueError:
                poll_seconds = None
    if poll_seconds is None:
        poll_seconds = DEFAULT_POLL_SECONDS

    reload_minutes = env_float("CONFIG_RELOAD_MINUTES")
    if reload_minutes is None:
        file_reload = file_cfg.get("reload_minutes")
        if file_reload:
            try:
                reload_minutes = float(file_reload)
            except ValueError:
                reload_minutes = None
    if reload_minutes is None:
        reload_minutes = DEFAULT_RELOAD_MINUTES

    return Config(
        common_dir=common_dir,
        spool_folder=spool_folder,
        worker_ids=worker_ids,
        symbol_mappings=symbol_mappings,
        poll_seconds=float(poll_seconds),
        reload_minutes=float(reload_minutes),
    )


_CACHED_CONFIG: Optional[Config] = None
_LAST_CONFIG_LOAD: float = 0.0


def get_config() -> Config:
    """Recarga configuración cada reload_minutes (por defecto 15)."""
    global _CACHED_CONFIG, _LAST_CONFIG_LOAD
    now = time.time()
    if _CACHED_CONFIG is None:
        _CACHED_CONFIG = load_config()
        _LAST_CONFIG_LOAD = now
        return _CACHED_CONFIG
    interval = _CACHED_CONFIG.reload_minutes * 60.0
    if now - _LAST_CONFIG_LOAD >= interval:
        _CACHED_CONFIG = load_config()
        _LAST_CONFIG_LOAD = now
    return _CACHED_CONFIG


def scan_spool_directory(spool_dir: Path) -> List[Path]:
    """
    Escanea carpeta spool y retorna archivos .txt ordenados por nombre (cronológico).
    Ignora archivos .tmp (temporales).
    """
    if not spool_dir.exists():
        return []
    
    event_files = []
    for file_path in spool_dir.iterdir():
        if file_path.is_file() and file_path.suffix == ".txt":
            # Ignorar archivos .tmp
            if file_path.stem.endswith(".tmp"):
                continue
            event_files.append(file_path)
    
    # Ordenar por nombre (ya incluye timestamp)
    event_files.sort(key=lambda p: p.name)
    return event_files


def parse_event_file(event_path: Path) -> Dict[str, str]:
    """
    Lee y parsea archivo de evento pipe-separated.
    Retorna diccionario con los campos parseados.
    """
    try:
        content = event_path.read_text(encoding="utf-8", errors="replace").strip()
        if not content:
            return {}
        
        # Parsear formato: EVT|EVENT=OPEN|TICKET=123|SYMBOL=EURUSD|...
        event_dict: Dict[str, str] = {}
        parts = content.split("|")
        
        for part in parts:
            part = part.strip()
            if "=" in part:
                key, value = part.split("=", 1)
                event_dict[key.strip()] = value.strip()
        
        return event_dict
    except Exception as exc:
        print(f"[ERROR] No se pudo parsear {event_path.name}: {exc}")
        return {}


def convert_pipe_to_csv(event_dict: Dict[str, str]) -> Optional[str]:
    """
    Convierte evento pipe a formato CSV mínimo para workers.
    Retorna línea CSV o None si el evento es inválido.
    """
    event_type = event_dict.get("EVENT", "").upper()
    ticket = event_dict.get("TICKET", "")
    
    if not event_type or not ticket:
        return None
    
    if event_type == "OPEN":
        # OPEN: todos los campos
        symbol = event_dict.get("SYMBOL", "")
        order_type = event_dict.get("TYPE", "")
        lots = event_dict.get("LOTS", "0")
        sl_raw = event_dict.get("SL", "")
        tp_raw = event_dict.get("TP", "")
        
        # Convertir "0.00" o "0" a vacío (igual que LectorOrdenes)
        sl = "" if (sl_raw == "0.00" or sl_raw == "0" or not sl_raw) else sl_raw
        tp = "" if (tp_raw == "0.00" or tp_raw == "0" or not tp_raw) else tp_raw
        
        if not symbol or not order_type:
            return None
        
        return f"{event_type};{ticket};{order_type};{lots};{symbol};{sl};{tp}"
    
    elif event_type == "OPEN_INVALIDATE_BYTIME30SEG":
        # OPEN_INVALIDATE_BYTIME30SEG: mismo formato que OPEN pero con campos adicionales
        symbol = event_dict.get("SYMBOL", "")
        order_type = event_dict.get("TYPE", "")
        lots = event_dict.get("LOTS", "0")
        sl_raw = event_dict.get("SL", "")
        tp_raw = event_dict.get("TP", "")
        invalidation_reason = event_dict.get("INVALIDATION_REASON", "")
        seconds_elapsed = event_dict.get("SECONDS_ELAPSED", "")
        
        # Convertir "0.00" o "0" a vacío (igual que LectorOrdenes)
        sl = "" if (sl_raw == "0.00" or sl_raw == "0" or not sl_raw) else sl_raw
        tp = "" if (tp_raw == "0.00" or tp_raw == "0" or not tp_raw) else tp_raw
        
        if not symbol or not order_type:
            return None
        
        # Formato: event_type;ticket;order_type;lots;symbol;sl;tp;invalidation_reason;seconds_elapsed
        return f"{event_type};{ticket};{order_type};{lots};{symbol};{sl};{tp};{invalidation_reason};{seconds_elapsed}"
    
    elif event_type == "MODIFY":
        # MODIFY: escribir en formato CORTO para WorkerV2:
        #   MODIFY;ticket;sl;tp
        # Importante: si SL_NEW viene vacío pero TP_NEW no, el WorkerV2 preferirá el formato largo
        # (y ahí es fácil desalinear columnas). Por eso ponemos "0" como placeholder.
        sl_new = (event_dict.get("SL_NEW", "") or "").strip()
        tp_new = (event_dict.get("TP_NEW", "") or "").strip()

        if sl_new == "":
            sl_new = "0"
        if tp_new == "":
            tp_new = "0"

        return f"{event_type};{ticket};{sl_new};{tp_new}"
    
    elif event_type == "CLOSE":
        # CLOSE: solo ticket (campos vacíos para el resto)
        return f"{event_type};{ticket};;;;;;"
    
    return None


def map_symbol_for_worker(worker_id: str, symbol: str, mappings: dict[str, dict[str, str]]) -> str:
    """
    Aplica mapeo de símbolo para un worker específico.
    Retorna el símbolo mapeado si existe, o el símbolo original si no hay mapeo.
    """
    symbol_upper = symbol.upper()
    if worker_id in mappings:
        if symbol_upper in mappings[worker_id]:
            mapped = mappings[worker_id][symbol_upper]
            print(f"[MAPEO] Worker {worker_id}: {symbol} -> {mapped}")
            return mapped
    return symbol


def append_to_queues(valid_lines: List[str], queues_dir: Path, worker_ids: List[str], symbol_mappings: dict[str, dict[str, str]]) -> dict:
    """
    Escribe cada línea válida en todas las colas de workers aplicando mapeo de símbolos por worker.
    Devuelve status por worker.
    Funcionalidad idéntica a V2/Distribuidor.py
    """
    queues_dir.mkdir(parents=True, exist_ok=True)
    tickets = []
    for ln in valid_lines:
        parts = ln.rstrip("\n").split(";")
        if len(parts) > 1:
            tickets.append(parts[1])
    tickets_str = ",".join(tickets) if tickets else "desconocido"

    status = {}
    for worker_id in worker_ids:
        # Aplicar mapeo de símbolos para este worker
        mapped_lines: List[str] = []
        for line in valid_lines:
            # Parsear línea: event_type;ticket;order_type;lots;symbol;sl;tp[;contract_size]
            parts = line.rstrip("\n").split(";")
            if len(parts) >= 5:
                original_symbol = parts[4]
                mapped_symbol = map_symbol_for_worker(worker_id, original_symbol, symbol_mappings)
                # Reemplazar símbolo en la línea
                parts[4] = mapped_symbol
                mapped_line = ";".join(parts)
                if not mapped_line.endswith("\n"):
                    mapped_line += "\n"
                mapped_lines.append(mapped_line)
                if original_symbol != mapped_symbol:
                    print(f"[MAPEO] Línea procesada para worker {worker_id}: símbolo {original_symbol} -> {mapped_symbol}")
            else:
                # Línea inválida, mantener original
                mapped_lines.append(line if line.endswith("\n") else line + "\n")
        
        queue_path = queues_dir / f"cola_WORKER_{worker_id}.csv"
        ok = True
        try:
            with open(queue_path, "a", encoding="utf-8", newline="") as fh:
                fh.writelines(mapped_lines)
        except Exception as exc:
            ok = False
            pending_path = queues_dir / f"pendientes_worker_{worker_id}.csv"
            try:
                with open(pending_path, "a", encoding="utf-8", newline="") as ph:
                    ph.writelines(mapped_lines)
            except Exception as pend_exc:
                print(f"[ALERTA] worker={worker_id} ticket={tickets_str} fallo al guardar pendientes: {pend_exc}")
            else:
                print(f"[ALERTA] worker={worker_id} ticket={tickets_str} fallo al escribir cola: {exc}. Guardado en {pending_path}")
        status[worker_id] = ok
    return status


def append_hist_master(valid_lines: List[str], hist_path: Path, event_time_ms: str, export_time_ms: str, read_time_ms: str, distribute_time_ms: str) -> None:
    """
    Log de eventos distribuidos con trazabilidad completa:
    - Formato: event_type;ticket;order_type;lots;symbol;sl;tp;event_time;export_time;read_time;distribute_time
    """
    hist_path.parent.mkdir(parents=True, exist_ok=True)
    lines_out: List[str] = []
    for ln in valid_lines:
        base = ln.rstrip("\n")
        lines_out.append(base + ";" + event_time_ms + ";" + export_time_ms + ";" + read_time_ms + ";" + distribute_time_ms + "\n")
    with open(hist_path, "a", encoding="utf-8", newline="") as fh:
        fh.writelines(lines_out)


def append_hist_clonacion(valid_lines: List[str], worker_ids: List[str], status: dict, hist_path: Path) -> None:
    """
    Log de resultados de clonación por worker:
    - Una línea por worker por evento: ticket;worker_id;resultado;timestamp
    - Relación 1 a N con Historico_Master.txt (1 evento → N workers)
    Funcionalidad idéntica a V2/Distribuidor.py
    """
    hist_path.parent.mkdir(parents=True, exist_ok=True)
    clonacion_time = datetime.now().strftime("%Y.%m.%d %H:%M:%S.%f")[:-3]
    lines_out: List[str] = []
    for ln in valid_lines:
        base = ln.rstrip("\n")
        parts = base.split(";")
        ticket = parts[1] if len(parts) > 1 else ""
        for wid in worker_ids:
            ok = status.get(wid, True)
            result = "OK" if ok else "NOK"
            lines_out.append(f"{ticket};{wid};{result};{clonacion_time}\n")
    with open(hist_path, "a", encoding="utf-8", newline="") as fh:
        fh.writelines(lines_out)


def process_spool_event(event_path: Path, config: Config) -> bool:
    """
    Procesa un evento completo: leer, parsear, distribuir, historizar, borrar.
    Retorna True si se procesó exitosamente, False en caso contrario.
    """
    try:
        # 1. Capturar read_time (milisegundos desde epoch) cuando se lee del spool
        read_time_ms = str(int(time.time() * 1000))
        
        # 2. Parsear evento
        event_dict = parse_event_file(event_path)
        if not event_dict:
            print(f"[WARN] Evento vacío o inválido: {event_path.name}")
            return False
        
        # Extraer tipo/ticket y timestamps del evento
        event_type = event_dict.get("EVENT", "").upper()
        ticket = event_dict.get("TICKET", "")
        event_time_ms = event_dict.get("EVENT_TIME", "")
        export_time_ms = event_dict.get("EXPORT_TIME", "")

        # Regla 30s SOLO para eventos OPEN (antes de distribuir)
        # Usa OPEN_TIME_UTC_MS (ms epoch UTC) vs "ahora" (ms epoch UTC) del servidor del distribuidor
        if event_type == "OPEN":
            now_ms_int = int(time.time() * 1000)
            try:
                open_ms_int = int(event_dict.get("OPEN_TIME_UTC_MS", "") or "")
                diff_seconds = int(max(0, (now_ms_int - open_ms_int) / 1000))
                open_dt_str = datetime.fromtimestamp(open_ms_int / 1000).strftime("%Y.%m.%d %H:%M:%S")
            except Exception:
                # Si no podemos calcular, NO distribuimos por seguridad y lo dejamos registrado
                diff_seconds = -1
                open_dt_str = ""

            now_dt_str = datetime.fromtimestamp(now_ms_int / 1000).strftime("%Y.%m.%d %H:%M:%S")

            # Mostrar open_time según el PC de MT4 (si viene informado por Extractor)
            open_mt_pc_dt_str = ""
            try:
                open_mt_pc_ms_int = int(event_dict.get("OPEN_TIME_MT_PC_MS", "") or "")
                open_mt_pc_dt_str = datetime.fromtimestamp(open_mt_pc_ms_int / 1000).strftime("%Y.%m.%d %H:%M:%S")
            except Exception:
                open_mt_pc_dt_str = ""
            # También mostrar open_time "real" (server time) si EVENT_TIME es parseable
            open_real_dt_str = ""
            try:
                event_ms_int = int(event_time_ms)
                # EVENT_TIME viene como openTime(server)*1000, OPEN_TIME_UTC_MS es openTime(utc)*1000
                offset_sec = int(round((event_ms_int - open_ms_int) / 1000))
                open_real_dt_str = (datetime.fromtimestamp(open_ms_int / 1000) + timedelta(seconds=offset_sec)).strftime(
                    "%Y.%m.%d %H:%M:%S"
                )
            except Exception:
                open_real_dt_str = ""

            if diff_seconds == -1 or diff_seconds > 30:
                motivo = "OPEN_TIME_UTC_MS inválido" if diff_seconds == -1 else "Tiempo excedido"
                nota = f"Ticket {ticket} invalido por regla 30 segundos"

                # Construir línea CSV de invalidación con columnas extra:
                # event_type;ticket;order_type;lots;symbol;sl;tp;invalidation_reason;seconds_elapsed;nota;open_time;open_time_MT_PC;hora_actual;diferencia_seg
                symbol = event_dict.get("SYMBOL", "")
                order_type = event_dict.get("TYPE", "")
                lots = event_dict.get("LOTS", "0")
                sl_raw = event_dict.get("SL", "")
                tp_raw = event_dict.get("TP", "")
                sl = "" if (sl_raw == "0.00" or sl_raw == "0" or not sl_raw) else sl_raw
                tp = "" if (tp_raw == "0.00" or tp_raw == "0" or not tp_raw) else tp_raw

                seconds_elapsed_str = "" if diff_seconds == -1 else str(diff_seconds)
                invalid_csv = (
                    f"OPEN_INVALIDATE_BYTIME30SEG;{ticket};{order_type};{lots};{symbol};{sl};{tp};"
                    f"{motivo};{seconds_elapsed_str};{nota};{open_dt_str};{open_mt_pc_dt_str};{now_dt_str};{seconds_elapsed_str}"
                )
                valid_lines = [invalid_csv + "\n"]

                hist_master_path = config.common_dir / "V3" / "Phoenix" / "Historico_Master.csv"
                distribute_time_ms = str(now_ms_int)
                # Para el histórico master, usar como event_time la hora real de apertura (UTC) si es válida,
                # para evitar inconsistencias con EVENT_TIME (server time) del archivo.
                hist_event_time_ms = str(open_ms_int) if diff_seconds != -1 else event_time_ms
                append_hist_master(valid_lines, hist_master_path, hist_event_time_ms, export_time_ms, read_time_ms, distribute_time_ms)

                print(
                    f"[OPEN][INVALIDADO_30S] ticket={ticket} open_time (real)={open_real_dt_str} "
                    f"open_time (convertido)={open_dt_str} "
                    f"open_time_MT_PC={open_mt_pc_dt_str} "
                    f"hora_actual={now_dt_str} diferencia_seg={seconds_elapsed_str} | {motivo}"
                )

                # Borrar archivo de evento (lo tratamos como procesado)
                try:
                    event_path.unlink()
                    print(f"[OK] Procesado y borrado: {event_path.name} (EVENT=OPEN_INVALIDATE_BYTIME30SEG TICKET={ticket})")
                except Exception as exc:
                    print(f"[ERROR] No se pudo borrar {event_path.name}: {exc}")
                return True
            else:
                print(
                    f"[OPEN][OK_30S] ticket={ticket} open_time={open_dt_str} "
                    f"hora_actual={now_dt_str} diferencia_seg={diff_seconds}"
                )

        # 3. Convertir a CSV (para el flujo normal)
        csv_line = convert_pipe_to_csv(event_dict)
        if not csv_line:
            print(f"[WARN] No se pudo convertir evento a CSV: {event_path.name}")
            return False

        # Convertir csv_line a lista para mantener compatibilidad con V2
        valid_lines = [csv_line + "\n"] if not csv_line.endswith("\n") else [csv_line]
        
        # 4. Si es OPEN_INVALIDATE_BYTIME30SEG, escribir directamente al histórico master sin distribuir
        if event_type == "OPEN_INVALIDATE_BYTIME30SEG":
            hist_master_path = config.common_dir / "V3" / "Phoenix" / "Historico_Master.csv"
            distribute_time_ms = str(int(time.time() * 1000))
            append_hist_master(valid_lines, hist_master_path, event_time_ms, export_time_ms, read_time_ms, distribute_time_ms)
            print(f"[OK] Orden invalidada por tiempo registrada en histórico: {event_path.name} (EVENT={event_type} TICKET={ticket})")
        else:
            # 5. Distribuir a workers (en V3/Phoenix) para eventos normales
            queues_dir = config.common_dir / "V3" / "Phoenix"
            
            # Capturar distribute_time justo antes de distribuir
            distribute_time_ms = str(int(time.time() * 1000))
            
            status = append_to_queues(valid_lines, queues_dir, config.worker_ids, config.symbol_mappings)
            
            # 6. Verificar que la distribución fue exitosa ANTES de escribir históricos
            all_ok = all(status.values())
            if not all_ok:
                print(f"[WARN] No se procesó {event_path.name} por errores en distribución (EVENT={event_type} TICKET={ticket})")
                return False
            
            # 7. Escribir históricos SOLO si la distribución fue exitosa
            hist_master_path = config.common_dir / "V3" / "Phoenix" / "Historico_Master.csv"
            hist_clonacion_path = config.common_dir / "V3" / "Phoenix" / "historico_clonacion.csv"
            
            append_hist_master(valid_lines, hist_master_path, event_time_ms, export_time_ms, read_time_ms, distribute_time_ms)
            append_hist_clonacion(valid_lines, config.worker_ids, status, hist_clonacion_path)
        
        # 7. Borrar archivo de evento (solo si todo fue exitoso)
        try:
            event_path.unlink()
            print(f"[OK] Procesado y borrado: {event_path.name} (EVENT={event_type} TICKET={ticket})")
        except Exception as exc:
            print(f"[ERROR] No se pudo borrar {event_path.name}: {exc}")
            # Aunque falle el borrado, el evento ya fue procesado y registrado en históricos
            # No retornar False para evitar reprocesamiento
        
        return True
        
    except Exception as exc:
        print(f"[ERROR] Error procesando {event_path.name}: {exc}")
        return False


def run_service() -> None:
    cfg = get_config()
    print(f"[INIT] Distribuidor V3 Spool arrancado.")
    print(f"[INIT] Spool: {cfg.common_dir / cfg.spool_folder}")
    print(f"[INIT] Workers: {cfg.worker_ids} (total: {len(cfg.worker_ids)})")
    print(f"[INIT] Common dir: {cfg.common_dir}")
    print(f"[INIT] Intervalo de sondeo: {cfg.poll_seconds}s")
    print(f"[INIT] Recarga config cada: {cfg.reload_minutes} minutos")
    
    if not cfg.worker_ids:
        print(f"[ERROR] No hay workers configurados! El distribuidor no funcionará.")

    while True:
        try:
            cycle_start = time.time()
            cfg = get_config()
            spool_dir = cfg.common_dir / cfg.spool_folder.replace("\\", os.sep)
            poll_seconds = cfg.poll_seconds

            # Escanear spool
            event_files = scan_spool_directory(spool_dir)
            
            if event_files:
                print(f"[CICLO] Encontrados {len(event_files)} eventos en spool")
            
            processed = 0
            errors = 0
            
            for event_file in event_files:
                success = process_spool_event(event_file, cfg)
                if success:
                    processed += 1
                else:
                    errors += 1
            
            if processed > 0 or errors > 0:
                print(f"[CICLO] Procesados: {processed} | Errores: {errors}")

            elapsed_ms = int((time.time() - cycle_start) * 1000)
            if processed > 0:
                print(f"[CICLO] Tiempo procesamiento: {elapsed_ms} ms")

        except Exception as exc:
            print(f"[ERROR] Ciclo falló: {exc}")
            import traceback
            traceback.print_exc()

        time.sleep(poll_seconds)


if __name__ == "__main__":
    run_service()
