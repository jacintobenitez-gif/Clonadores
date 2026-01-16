#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import re
from dataclasses import dataclass
from datetime import datetime, date
from pathlib import Path
from typing import Optional, Tuple, List

import pandas as pd

# --------- Helpers ---------

def _to_float(x: str) -> float:
    """
    Convierte números tipo '1,234.56' o '1.234,56' o '1234,56' a float.
    """
    if x is None:
        return 0.0
    s = str(x).strip()
    if s == "" or s.lower() in {"nan", "none"}:
        return 0.0

    # Quita espacios y símbolos raros
    s = s.replace("\u00a0", " ").strip()

    # Si hay ambos separadores, decide por el último como decimal
    # Ej: 1.234,56 -> decimal ',' ; 1,234.56 -> decimal '.'
    if "," in s and "." in s:
        if s.rfind(",") > s.rfind("."):
            # 1.234,56
            s = s.replace(".", "")
            s = s.replace(",", ".")
        else:
            # 1,234.56
            s = s.replace(",", "")
    else:
        # Solo coma -> decimal coma
        if "," in s and "." not in s:
            s = s.replace(",", ".")
        # Solo punto -> decimal punto (OK)

    # Elimina cualquier cosa no numérica salvo signo y punto
    s = re.sub(r"[^0-9\.\-\+eE]", "", s)
    try:
        return float(s)
    except ValueError:
        return 0.0


def _parse_date_from_dt(s: str) -> Optional[date]:
    """
    Intenta extraer fecha de strings tipo:
    '2026-01-16 12:34:56', '2026.01.16 12:34', '16/01/2026', etc.
    """
    if s is None:
        return None
    txt = str(s).strip()
    if not txt:
        return None

    # Normaliza separadores
    txt2 = txt.replace(".", "-").replace("/", "-")

    # Busca yyyy-mm-dd
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})", txt2)
    if m:
        y, mo, d = map(int, m.groups())
        return date(y, mo, d)

    # Busca dd-mm-yyyy
    m = re.search(r"(\d{2})-(\d{2})-(\d{4})", txt2)
    if m:
        d, mo, y = map(int, m.groups())
        return date(y, mo, d)

    return None


def _guess_delimiter_and_read_txt(path: Path) -> pd.DataFrame:
    """
    Intenta leer TXT con delimitador tab/;/, o espacios múltiples.
    """
    raw = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    raw = [ln for ln in raw if ln.strip()]

    # Encuentra header probable
    header_idx = None
    for i, ln in enumerate(raw[:50]):
        if "TYPE" in ln and ("PROFIT" in ln or "SWAP" in ln or "COMMISSION" in ln):
            header_idx = i
            break
    if header_idx is None:
        header_idx = 0

    # Prueba separadores comunes
    sample = "\n".join(raw[header_idx:header_idx + 20])
    for sep in ["\t", ";", ",", "|"]:
        try:
            # Intentar con diferentes codificaciones
            for encoding in ["utf-8", "latin-1", "cp1252"]:
                try:
                    df = pd.read_csv(path, sep=sep, engine="python", skiprows=header_idx, encoding=encoding)
                    if df.shape[1] >= 4 and any(col.upper() == "TYPE" for col in df.columns):
                        return df
                except UnicodeDecodeError:
                    continue
        except Exception:
            pass

    # Fallback: espacios múltiples
    # Convertimos a "CSV" con separador | en base a 2+ espacios
    lines = raw[header_idx:]
    split_lines = [re.split(r"\s{2,}", ln.strip()) for ln in lines]
    # Usa la primera fila como header
    header = split_lines[0]
    rows = split_lines[1:]
    # Ajusta longitudes
    max_len = max(len(r) for r in rows) if rows else len(header)
    header = header + [f"COL_{i}" for i in range(len(header), max_len)]
    norm_rows = [r + [""] * (max_len - len(r)) for r in rows]
    df = pd.DataFrame(norm_rows, columns=header)
    return df


def _read_pdf_as_text_table(path: Path) -> pd.DataFrame:
    """
    Extrae texto de PDF y reconstruye una tabla por heurística.
    Requiere pdfplumber.
    """
    try:
        import pdfplumber
    except ImportError as e:
        raise RuntimeError("Falta dependencia: pip install pdfplumber") from e

    all_lines: List[str] = []
    with pdfplumber.open(str(path)) as pdf:
        for page in pdf.pages:
            txt = page.extract_text() or ""
            for ln in txt.splitlines():
                ln = ln.strip()
                if ln:
                    all_lines.append(ln)

    # Busca header
    header_idx = None
    for i, ln in enumerate(all_lines[:200]):
        if "TYPE" in ln and ("PROFIT" in ln or "SWAP" in ln or "COMMISSION" in ln):
            header_idx = i
            break
    if header_idx is None:
        # Si no hay header claro, intenta con la primera línea
        header_idx = 0

    lines = all_lines[header_idx:]
    split_lines = [re.split(r"\s{2,}", ln.strip()) for ln in lines]

    header = split_lines[0]
    rows = split_lines[1:]
    if not rows:
        return pd.DataFrame()

    max_len = max(len(r) for r in rows)
    header = header + [f"COL_{i}" for i in range(len(header), max_len)]
    norm_rows = [r + [""] * (max_len - len(r)) for r in rows]
    df = pd.DataFrame(norm_rows, columns=header)
    return df


def load_any(path: Path) -> pd.DataFrame:
    if path.suffix.lower() == ".pdf":
        return _read_pdf_as_text_table(path)
    else:
        return _guess_delimiter_and_read_txt(path)


def normalize_columns(df: pd.DataFrame) -> pd.DataFrame:
    """
    Intenta mapear nombres a estándar: CLOSE_TIME, TYPE, PROFIT, COMMISSION, SWAP, AMOUNT.
    En muchos extractos, los depósitos vienen como PROFIT o AMOUNT.
    """
    if df.empty:
        return df

    cols = {c: str(c).strip() for c in df.columns}
    df = df.rename(columns=cols)

    # Normaliza a mayúsculas para matching
    upper_map = {c: c.upper() for c in df.columns}
    inv_upper = {}
    for k, v in upper_map.items():
        inv_upper.setdefault(v, []).append(k)

    def pick(*names: str) -> Optional[str]:
        for n in names:
            if n in inv_upper:
                return inv_upper[n][0]
        return None

    col_type = pick("TYPE")
    col_profit = pick("PROFIT", "P/L", "PL")
    col_comm = pick("COMMISSION", "COMM")
    col_swap = pick("SWAP")
    col_close = pick("CLOSE_TIME", "CLOSE", "CLOSE TIME", "TIME", "DATE", "CLOSEDATE")

    # Algunos extractos tienen "AMOUNT" en vez de PROFIT para depósitos
    col_amount = pick("AMOUNT", "VALUE")

    # Si no hay close, intenta con cualquier col que parezca fecha
    if col_close is None:
        for c in df.columns:
            if re.search(r"(CLOSE|DATE|TIME)", c.upper()):
                col_close = c
                break

    # Crea columnas estándar
    out = pd.DataFrame()
    out["TYPE"] = df[col_type] if col_type else ""
    out["CLOSE_TIME_RAW"] = df[col_close] if col_close else ""

    # Profit / comm / swap
    if col_profit:
        out["PROFIT"] = df[col_profit].apply(_to_float)
    else:
        out["PROFIT"] = 0.0

    if col_comm:
        out["COMMISSION"] = df[col_comm].apply(_to_float)
    else:
        out["COMMISSION"] = 0.0

    if col_swap:
        out["SWAP"] = df[col_swap].apply(_to_float)
    else:
        out["SWAP"] = 0.0

    # Amount (para depósitos), si existe
    if col_amount:
        out["AMOUNT"] = df[col_amount].apply(_to_float)
    else:
        # muchos extractos meten el importe del depósito en PROFIT
        out["AMOUNT"] = out["PROFIT"]

    # Fecha (solo día)
    out["DATE"] = out["CLOSE_TIME_RAW"].apply(_parse_date_from_dt)
    out = out.dropna(subset=["DATE"])

    return out


@dataclass
class Summary:
    capital_contributed: float
    net_total: float
    trade_days: int
    avg_net_per_trade_day: float
    best_day: Tuple[date, float]
    worst_day: Tuple[date, float]
    avg_capital_start_trade_days: float
    roi_daily_est: float
    capital_needed_for_target: float
    injection_needed_vs_contributed: float


def compute_summary(df_std: pd.DataFrame, exclude_types: str, target_daily: float, initial_capital: float = 0.0) -> Summary:
    # Deposits / aportaciones (puede ser una lista separada por comas: "DEPOSIT,CREDIT")
    exclude_list = [t.strip().upper() for t in exclude_types.split(",")]
    is_deposit = df_std["TYPE"].astype(str).str.upper().isin(exclude_list)
    deposits = df_std[is_deposit].copy()
    # Un deposito suele ser positivo; si hubiera negativos (retiradas), tambien los contariamos.
    deposits_by_day = deposits.groupby("DATE")["AMOUNT"].sum().sort_index() if len(deposits) > 0 else pd.Series(dtype=float)
    capital_contributed = float(deposits["AMOUNT"].sum()) if len(deposits) > 0 else initial_capital

    # Trades (excluyendo UNKNOWN)
    trades = df_std[~is_deposit].copy()
    trades["NET"] = trades["PROFIT"] + trades["COMMISSION"] + trades["SWAP"]
    pnl_by_day = trades.groupby("DATE")["NET"].sum().sort_index()

    # Días con trading (al menos 1 trade)
    trade_days = int((trades.groupby("DATE").size() > 0).sum())
    net_total = float(pnl_by_day.sum())
    avg_net = net_total / trade_days if trade_days > 0 else 0.0

    # Mejor/peor día
    if len(pnl_by_day) > 0:
        best_day = (pnl_by_day.idxmax(), float(pnl_by_day.max()))
        worst_day = (pnl_by_day.idxmin(), float(pnl_by_day.min()))
    else:
        best_day = (date.today(), 0.0)
        worst_day = (date.today(), 0.0)

    # Reconstruccion de balance diario (balance inicial = capital_contributed o initial_capital)
    all_days = sorted(set(deposits_by_day.index).union(set(pnl_by_day.index)))
    bal = initial_capital if len(deposits) == 0 else 0.0
    balance_start = {}
    for d in all_days:
        dep = float(deposits_by_day.get(d, 0.0)) if len(deposits_by_day) > 0 else 0.0
        pnl = float(pnl_by_day.get(d, 0.0))
        bal_start = bal + dep
        balance_start[d] = bal_start
        bal = bal_start + pnl

    # Capital medio al inicio de días con trading (días donde hay pnl_by_day)
    if len(pnl_by_day) > 0:
        starts = [balance_start[d] for d in pnl_by_day.index if d in balance_start]
        avg_capital_start = float(sum(starts) / len(starts)) if starts else 0.0
    else:
        avg_capital_start = 0.0

    # ROI diario estimado (solo días con trading)
    roi_daily = (avg_net / avg_capital_start) if avg_capital_start > 0 else 0.0

    # Capital necesario para target (escalado lineal)
    capital_needed = (target_daily / roi_daily) if roi_daily > 0 else float("inf")
    injection_needed = capital_needed - capital_contributed if capital_needed != float("inf") else float("inf")

    return Summary(
        capital_contributed=capital_contributed,
        net_total=net_total,
        trade_days=trade_days,
        avg_net_per_trade_day=avg_net,
        best_day=best_day,
        worst_day=worst_day,
        avg_capital_start_trade_days=avg_capital_start,
        roi_daily_est=roi_daily,
        capital_needed_for_target=capital_needed,
        injection_needed_vs_contributed=injection_needed,
    )


def fmt_eur(x: float) -> str:
    if x == float("inf"):
        return "INF"
    return f"{x:,.2f} EUR".replace(",", "X").replace(".", ",").replace("X", ".")


def get_mt4_common_files_path() -> Path:
    """
    Retorna la ruta a Common/Files de MetaTrader 4.
    En Windows: C:/Users/<Usuario>/AppData/Roaming/MetaQuotes/Terminal/Common/Files
    """
    import os
    appdata = os.environ.get("APPDATA", "")
    if appdata:
        common_path = Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files"
        if common_path.exists():
            return common_path
    # Fallback: intentar ruta tipica
    return Path("C:/Users") / os.environ.get("USERNAME", "Administrator") / "AppData/Roaming/MetaQuotes/Terminal/Common/Files"


def main():
    # Ruta por defecto: historial.txt en Common\Files de MT4
    mt4_common = get_mt4_common_files_path()
    default_file = mt4_common / "historial.txt"
    
    # Alternativa: carpeta local del script
    script_dir = Path(__file__).parent
    local_file = script_dir / "historial.txt"

    ap = argparse.ArgumentParser(description="Analiza historial (txt/pdf) y calcula PnL diario excluyendo aportaciones UNKNOWN.")
    ap.add_argument("file", type=str, nargs="?", default=None, 
                    help="Ruta a historial.txt o historial.pdf (default: busca en Common/Files de MT4 o carpeta local)")
    ap.add_argument("--exclude-type", type=str, default="DEPOSIT,CREDIT", help="Valores de TYPE que se consideran aportacion, separados por coma (default: DEPOSIT,CREDIT)")
    ap.add_argument("--target", type=float, default=320.0, help="Objetivo de media diaria (EUR/dia) para calcular capital necesario (default: 320)")
    ap.add_argument("--capital", type=float, default=0.0, help="Capital inicial de la cuenta (si no hay depositos en historial)")
    args = ap.parse_args()

    # Determinar qué archivo usar
    if args.file:
        path = Path(args.file)
    elif default_file.exists():
        path = default_file
        print(f"(Usando archivo de MT4 Common/Files: {path})")
    elif local_file.exists():
        path = local_file
        print(f"(Usando archivo local: {path})")
    else:
        raise SystemExit(f"No se encontró historial.txt en:\n  - {default_file}\n  - {local_file}\n\nEjecuta primero el EA historial.mq4 en MT4 o especifica la ruta del archivo.")
    
    if not path.exists():
        raise SystemExit(f"No existe el fichero: {path}")

    df_raw = load_any(path)
    df = normalize_columns(df_raw)

    if df.empty:
        raise SystemExit("No pude extraer filas válidas (DATE) del fichero. Revisa formato o pásame otro export.")

    summ = compute_summary(df, exclude_types=args.exclude_type, target_daily=args.target, initial_capital=args.capital)

    print("\n=== RESUMEN ===")
    print(f"Fichero: {path.name}")
    print(f"Aportaciones (TYPE in [{args.exclude_type}]): {fmt_eur(summ.capital_contributed)}")
    print(f"PnL neto total (sin aportaciones): {fmt_eur(summ.net_total)}")
    print(f"Días con trading: {summ.trade_days}")
    print(f"Media diaria (solo días con trading): {fmt_eur(summ.avg_net_per_trade_day)}")
    print(f"Mejor día: {summ.best_day[0].isoformat()} -> {fmt_eur(summ.best_day[1])}")
    print(f"Peor día:  {summ.worst_day[0].isoformat()} -> {fmt_eur(summ.worst_day[1])}")

    print("\n=== CAPITAL MEDIO / ESCALADO ===")
    print(f"Capital medio (inicio de día en días con trading): {fmt_eur(summ.avg_capital_start_trade_days)}")
    print(f"ROI diario estimado (media/ capital medio): {summ.roi_daily_est*100:.3f}%")
    print(f"\nObjetivo: {fmt_eur(args.target)} / día")
    print(f"Capital requerido (aprox): {fmt_eur(summ.capital_needed_for_target)}")
    print(f"Inyección necesaria vs capital aportado: {fmt_eur(summ.injection_needed_vs_contributed)}")

    print("\n(Notas) NET = PROFIT + COMMISSION + SWAP. Aportaciones excluidas por TYPE.")
    print("Si tu PDF/TXT no trae COMMISSION o SWAP, se asumen 0.\n")


if __name__ == "__main__":
    main()

