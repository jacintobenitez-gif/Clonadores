"""
Distribuidor.py
---------------

Servicio 24/7 que:
- Lee eventos completos desde `Master.txt` (Common\Files)
- Valida que cada línea tenga exactamente 7 campos
- Ignora cabecera (si existe) y líneas incompletas (sin '\n')
- Distribuye cada evento válido a todas las colas `cola_WORKER_XX.csv`
- Recorta `Master.txt` eliminando los eventos ya distribuidos
- Registra actividad sin bloquearse ante errores

El código sigue la especificación funcional descrita en
`ANALISIS_Distribuidor.md`.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple

# Configuración por defecto
DEFAULT_MASTER_FILENAME = "Master.txt"
DEFAULT_WORKER_IDS = ["01"]
DEFAULT_POLL_SECONDS = 1.0
CONFIG_FILENAME = "distribuidor_config.txt"  # Fichero de configuración externa (hot-reload)


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
    if not cfg_path.exists():
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
            cfg[key] = value
    except Exception as exc:
        print(f"[WARN] No se pudo leer {cfg_path}: {exc}")
    return cfg


@dataclass
class Config:
    common_dir: Path
    master_filename: str
    worker_ids: List[str]
    poll_seconds: float


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

    worker_ids = (
        env_list("WORKER_IDS")
        or ([w.strip() for w in file_cfg.get("worker_ids", "").split(",") if w.strip()])
        or DEFAULT_WORKER_IDS
    )

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

    return Config(
        common_dir=common_dir,
        master_filename=master_filename,
        worker_ids=worker_ids,
        poll_seconds=float(poll_seconds),
    )


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
    Valida que cada línea tenga exactamente 7 campos (separados por ';').
    Retorna (valid_lines, invalid_lines)
    """
    valid: List[str] = []
    invalid: List[str] = []
    for line in complete_lines:
        fields = line.rstrip("\n").split(";")
        if len(fields) == 7:
            valid.append(line)
        else:
            invalid.append(line)
    return valid, invalid


def append_to_queues(valid_lines: List[str], queues_dir: Path, worker_ids: List[str]) -> None:
    """
    Escribe cada línea válida en todas las colas de workers.
    """
    queues_dir.mkdir(parents=True, exist_ok=True)
    for worker_id in worker_ids:
        queue_path = queues_dir / f"cola_WORKER_{worker_id}.csv"
        with open(queue_path, "a", encoding="utf-8", newline="") as fh:
            fh.writelines(valid_lines)


def rewrite_master(
    master_path: Path,
    header_line: str | None,
    invalid_lines: List[str],
    incomplete_lines: List[str],
) -> int:
    """
    Reescribe Master.txt conservando:
    - cabecera (si existía)
    - líneas inválidas
    - líneas incompletas (sin \n)
    Retorna los bytes recortados (aproximado).
    """
    remaining: List[str] = []
    if header_line:
        # Garantiza que la cabecera termina en salto de línea
        remaining.append(header_line if header_line.endswith("\n") else header_line + "\n")
    remaining.extend(invalid_lines)
    remaining.extend(incomplete_lines)

    new_content = "".join(remaining)
    new_bytes = new_content.encode("utf-8")

    original_size = master_path.stat().st_size if master_path.exists() else 0
    master_path.write_text(new_content, encoding="utf-8")
    return max(original_size - len(new_bytes), 0)


def run_service() -> None:
    cfg = load_config()
    print(f"[INIT] Distribuidor arrancado.")
    print(f"[INIT] Master: {cfg.common_dir / cfg.master_filename}")
    print(f"[INIT] Workers: {cfg.worker_ids}")
    print(f"[INIT] Intervalo de sondeo: {cfg.poll_seconds}s")

    while True:
        try:
            # Hot-reload de configuración en cada ciclo
            cfg = load_config()
            master_path = cfg.common_dir / cfg.master_filename
            queues_dir = cfg.common_dir  # mismas Common\Files para las colas
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
                # Nada que distribuir; respetar cabecera e incompletas
                time.sleep(poll_seconds)
                continue

            try:
                append_to_queues(valid_lines, queues_dir, worker_ids)
                print(f"[OK] Distribuidas {total_valid} líneas a {len(worker_ids)} colas")
            except Exception as exc:
                print(f"[ERROR] Falló la distribución: {exc}")
                time.sleep(poll_seconds)
                continue  # No recortar para no perder eventos

            recorte = rewrite_master(master_path, header_line, invalid_lines, incomplete_lines)
            if recorte > 0:
                print(f"[RECORTE] Se recortaron ~{recorte} bytes del Master (tam orig {original_size})")

        except Exception as exc:
            # Cualquier error no debe detener el servicio
            print(f"[ERROR] Ciclo falló: {exc}")

        time.sleep(poll_seconds)


if __name__ == "__main__":
    run_service()

