"""
Distribuidor.py
---------------

Servicio 24/7 que:
- Lee eventos completos desde `Master.txt` (Common\\Files)
- Valida que cada línea tenga exactamente 7 campos
- Ignora cabecera (si existe) y líneas incompletas (sin '\n')
- Distribuye cada evento válido a todas las colas `cola_WORKER_XX.txt` (UTF-8)
- Recorta `Master.txt` eliminando los eventos ya distribuidos
- Registra actividad sin bloquearse ante errores

El código sigue la especificación funcional descrita en
`ANALISIS_Distribuidor.md`.
"""

from __future__ import annotations

import os
import time
from datetime import datetime
from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple, Optional

# Configuración por defecto
DEFAULT_MASTER_FILENAME = "Master.txt"
DEFAULT_WORKER_IDS = ["01"]
DEFAULT_POLL_SECONDS = 1.0
CONFIG_FILENAME = "distribuidor_config.txt"  # Fichero de configuración externa (hot-reload)
DEFAULT_RELOAD_MINUTES = 15.0  # Intervalo de recarga de config


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
      master_filename=Master.txt
      worker_ids=01,02,03
      poll_seconds=1.0
    Líneas vacías o que empiezan por # se ignoran.
    """
    cfg: dict = {}
    workers: List[str] = []
    if not cfg_path.exists():
        cfg["worker_ids_list"] = workers
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
                workers.append(value)
            else:
                cfg[key] = value
    except Exception as exc:
        print(f"[WARN] No se pudo leer {cfg_path}: {exc}")
    cfg["worker_ids_list"] = workers
    return cfg


@dataclass
class Config:
    common_dir: Path
    master_filename: str
    worker_ids: List[str]
    poll_seconds: float
    reload_minutes: float


def load_config() -> Config:
    """
    Carga configuración en este orden de prioridad (hot-reload):
    1) Variables de entorno
    2) Fichero distribuidor_config.txt (en la misma carpeta que este script)
    3) Valores por defecto
    """
    cfg_path = Path(__file__).resolve().parent / CONFIG_FILENAME
    file_cfg = load_file_config(cfg_path)

    env_common = os.getenv("COMMON_FILES_DIR")
    file_common = file_cfg.get("common_files_dir")
    common_dir = (
        Path(env_common)
        if env_common
        else Path(file_common)
        if file_common
        else default_common_files_dir()
    )

    master_filename = (
        os.getenv("MASTER_FILENAME")
        or file_cfg.get("master_filename")
        or DEFAULT_MASTER_FILENAME
    )

    worker_ids: Optional[List[str]] = env_list("WORKER_IDS")
    if worker_ids is None:
        cfg_workers = file_cfg.get("worker_ids_list", [])
        if cfg_workers:
            worker_ids = cfg_workers
        else:
            comma_workers = file_cfg.get("worker_ids", "")
            worker_ids = [w.strip() for w in comma_workers.split(",") if w.strip()]
    if not worker_ids:
        worker_ids = DEFAULT_WORKER_IDS

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
        master_filename=master_filename,
        worker_ids=worker_ids,
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


def detect_header(lines: List[str]) -> Tuple[int, str | None]:
    """
    Detecta cabecera si la primera línea es completa y empieza por event_type;...
    Retorna (start_idx, header_line)
    """
    if not lines:
        return 0, None
    first = lines[0]
    if first.endswith("\n") and first.strip().lower().startswith("event_type;"):
        return 1, first
    return 0, None


def load_master(master_path: Path) -> Tuple[str | None, List[str], List[str], List[str]]:
    """
    Lee el Master y separa:
    - header_line: cabecera si existe
    - complete_lines: líneas completas candidatas (sin cabecera)
    - invalid_complete_lines: se llena después de validar
    - incomplete_lines: líneas sin salto de línea (no procesables)
    """
    content = master_path.read_text(encoding="utf-8", errors="replace")
    all_lines = content.splitlines(True)  # conserva saltos de línea

    start_idx, header_line = detect_header(all_lines)

    complete_lines: List[str] = []
    incomplete_lines: List[str] = []
    for line in all_lines[start_idx:]:
        if line.endswith("\n"):
            complete_lines.append(line)
        else:
            incomplete_lines.append(line)

    # invalid_complete_lines se determina en el ciclo principal
    return header_line, complete_lines, [], incomplete_lines


def validate_lines(complete_lines: List[str]) -> Tuple[List[str], List[str]]:
    """
    Valida que cada línea tenga 7 u 8 campos (separados por ';').
    Retorna (valid_lines, invalid_lines)
    """
    valid: List[str] = []
    invalid: List[str] = []
    for line in complete_lines:
        fields = line.rstrip("\n").split(";")
        if 7 <= len(fields) <= 10:
            valid.append(line)
        else:
            invalid.append(line)
    return valid, invalid



def append_to_queues(valid_lines: List[str], queues_dir: Path, worker_ids: List[str]) -> dict:
    """
    Escribe cada lÃ­nea vÃ¡lida en todas las colas de workers y devuelve status por worker.
    """
    queues_dir.mkdir(parents=True, exist_ok=True)
    lines_to_write = [ln if ln.endswith("\n") else ln + "\n" for ln in valid_lines]
    tickets = []
    for ln in lines_to_write:
        parts = ln.strip().split(";")
        if len(parts) > 1:
            tickets.append(parts[1])
    tickets_str = ",".join(tickets) if tickets else "desconocido"

    status = {}
    for worker_id in worker_ids:
        queue_path = queues_dir / f"cola_WORKER_{worker_id}.txt"
        ok = True
        try:
            with open(queue_path, "a", encoding="utf-8", newline="") as fh:
                fh.writelines(lines_to_write)
        except Exception as exc:
            ok = False
            pending_path = queues_dir / f"pendientes_worker_{worker_id}.txt"
            try:
                with open(pending_path, "a", encoding="utf-8", newline="") as ph:
                    ph.writelines(lines_to_write)
            except Exception as pend_exc:
                print(f"[ALERTA] worker={worker_id} ticket={tickets_str} fallo al guardar pendientes: {pend_exc}")
            else:
                print(f"[ALERTA] worker={worker_id} ticket={tickets_str} fallo al escribir cola: {exc}. Guardado en {pending_path}")
        status[worker_id] = ok
    return status


def append_hist_master(valid_lines: List[str], worker_ids: List[str], status: dict, hist_path: Path) -> None:
    """
    Log de distribuciÃ³n:
    - lÃ­nea original del Master con clonacion_time aÃ±adido
    - una lÃ­nea de resultado por worker: ticket;worker;OK|NOK;clonacion_time
    """
    hist_path.parent.mkdir(parents=True, exist_ok=True)
    clonacion_time = datetime.now().strftime("%Y.%m.%d %H:%M:%S.%f")[:-3]
    lines_out: List[str] = []
    for ln in valid_lines:
        base = ln.rstrip("\n")
        lines_out.append(base + ";" + clonacion_time + "\n")
        parts = base.split(";")
        ticket = parts[1] if len(parts) > 1 else ""
        for wid in worker_ids:
            ok = status.get(wid, True)
            result = "OK" if ok else "NOK"
            lines_out.append(f"{ticket};{wid};{result};{clonacion_time}\n")
    with open(hist_path, "a", encoding="utf-8", newline="") as fh:
        fh.writelines(lines_out)


def rewrite_master(
    master_path: Path,
    header_line: str | None,
    invalid_lines: List[str],
    incomplete_lines: List[str],
) -> int:
    """
    Reescribe Master.txt conservando:
    - cabecera (si existÃ­a)
    - lÃ­neas invÃ¡lidas
    - lÃ­neas incompletas (sin 
)
    Retorna los bytes recortados (aproximado).
    """
    remaining: List[str] = []
    if header_line:
        remaining.append(header_line if header_line.endswith("
") else header_line + "
")
    remaining.extend(invalid_lines)
    remaining.extend(incomplete_lines)

    new_content = "".join(remaining)
    new_bytes = new_content.encode("utf-8")

    original_size = master_path.stat().st_size if master_path.exists() else 0
    master_path.write_text(new_content, encoding="utf-8")
    return max(original_size - len(new_bytes), 0)


def run_service() -> None:
    cfg = get_config()
    print(f"[INIT] Distribuidor arrancado.")
    print(f"[INIT] Master: {cfg.common_dir / cfg.master_filename}")
    print(f"[INIT] Workers: {cfg.worker_ids}")
    print(f"[INIT] Intervalo de sondeo: {cfg.poll_seconds}s")
    print(f"[INIT] Recarga config cada: {cfg.reload_minutes} minutos")

    while True:
        try:
            cycle_start = time.time()
            cfg = get_config()
            master_path = cfg.common_dir / cfg.master_filename
            queues_dir = cfg.common_dir
            hist_path = cfg.common_dir / "Historico_Master.txt"
            worker_ids = cfg.worker_ids
            poll_seconds = cfg.poll_seconds

            if not master_path.exists():
                print(f"[WARN] Master no encontrado: {master_path}")
                time.sleep(poll_seconds)
                continue

            original_size = master_path.stat().st_size
            header_line, complete_lines, _, incomplete_lines = load_master(master_path)

            valid_lines, invalid_lines = validate_lines(complete_lines)

            total_complete = len(complete_lines)
            total_valid = len(valid_lines)
            total_invalid = len(invalid_lines)
            total_incomplete = len(incomplete_lines)

            if total_complete or total_incomplete:
                print(
                    f"[CICLO] completas={total_complete} validas={total_valid} "
                    f"invalidas={total_invalid} incompletas={total_incomplete}"
                )

            if not valid_lines:
                time.sleep(poll_seconds)
                continue

            try:
                status = append_to_queues(valid_lines, queues_dir, worker_ids)
                append_hist_master(valid_lines, worker_ids, status, hist_path)
                print(f"[OK] Distribuidas {total_valid} lÃ­neas a {len(worker_ids)} colas")
            except Exception as exc:
                print(f"[ERROR] FallÃ³ la distribuciÃ³n: {exc}")
                time.sleep(poll_seconds)
                continue

            recorte = rewrite_master(master_path, header_line, invalid_lines, incomplete_lines)
            if recorte > 0:
                print(f"[RECORTE] Se recortaron ~{recorte} bytes del Master (tam orig {original_size})")

            elapsed_ms = int((time.time() - cycle_start) * 1000)
            print(f"[CICLO] Tiempo distribuciÃ³n+recorte: {elapsed_ms} ms")

        except Exception as exc:
            print(f"[ERROR] Ciclo fallÃ³: {exc}")

        time.sleep(poll_seconds)


if __name__ == "__main__":
    run_service()
