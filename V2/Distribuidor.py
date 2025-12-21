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
from pathlib import Path
from typing import List, Tuple

# Configuración
MASTER_FILENAME = "Master.txt"
# Lista de workers, configurable vía env WORKER_IDS="01,02,03"
DEFAULT_WORKER_IDS = ["01"]
POLL_SECONDS = float(os.getenv("POLL_SECONDS", "1.0"))


def get_common_files_dir() -> Path:
    """
    Devuelve la ruta base de Common\Files.
    Se puede sobreescribir con la variable de entorno COMMON_FILES_DIR.
    """
    env_path = os.getenv("COMMON_FILES_DIR")
    if env_path:
        return Path(env_path)

    # Valor por defecto (habitual en MetaTrader)
    home = Path.home()
    default_path = home / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"
    return default_path


def parse_worker_ids() -> List[str]:
    env_value = os.getenv("WORKER_IDS")
    if env_value:
        return [w.strip() for w in env_value.split(",") if w.strip()]
    return DEFAULT_WORKER_IDS


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
    common_dir = get_common_files_dir()
    master_path = common_dir / MASTER_FILENAME
    queues_dir = common_dir  # mismas Common\Files para las colas
    worker_ids = parse_worker_ids()

    print(f"[INIT] Distribuidor arrancado. Master: {master_path}")
    print(f"[INIT] Workers: {worker_ids}")
    print(f"[INIT] Intervalo de sondeo: {POLL_SECONDS}s")

    while True:
        try:
            if not master_path.exists():
                print(f"[WARN] Master no encontrado: {master_path}")
                time.sleep(POLL_SECONDS)
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
                time.sleep(POLL_SECONDS)
                continue

            try:
                append_to_queues(valid_lines, queues_dir, worker_ids)
                print(f"[OK] Distribuidas {total_valid} líneas a {len(worker_ids)} colas")
            except Exception as exc:
                print(f"[ERROR] Falló la distribución: {exc}")
                time.sleep(POLL_SECONDS)
                continue  # No recortar para no perder eventos

            recorte = rewrite_master(master_path, header_line, invalid_lines, incomplete_lines)
            if recorte > 0:
                print(f"[RECORTE] Se recortaron ~{recorte} bytes del Master (tam orig {original_size})")

        except Exception as exc:
            # Cualquier error no debe detener el servicio
            print(f"[ERROR] Ciclo falló: {exc}")

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    run_service()

