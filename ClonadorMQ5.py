#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Clonador de Órdenes para MetaTrader 5
Lee TradeEvents.csv desde Common\Files y clona operaciones OPEN/CLOSE/MODIFY
Equivalente funcional a ClonadorOrdenes.mq5 pero ejecutándose como script Python
"""

import os
import time
import csv
from dataclasses import dataclass
from typing import Optional
from io import StringIO
from datetime import datetime, timedelta

import MetaTrader5 as mt5

# ========= CONFIG (equivalentes a Inputs) =========
CSV_NAME = "TradeEvents.csv"     # en Common\Files
CSV_HISTORICO = "TradeEvents_historico.txt"  # Archivo TXT histórico de ejecuciones exitosas
TIMER_SECONDS = 1
SLIPPAGE_POINTS = 30

CUENTA_FONDEO = True              # True = copia lots del maestro (por defecto)
FIXED_LOTS = 0.10                 # lote fijo si NO es fondeo
MAGIC = 0
# Multiplicador de lotaje (se establece al inicio si CUENTA_FONDEO = True)
LOT_MULTIPLIER = 1.0              # Por defecto 1x, se configura al inicio
# ================================================

@dataclass
class Ev:
    event_type: str
    master_ticket: str
    order_type: str   # BUY/SELL
    master_lots: float
    symbol: str
    sl: float
    tp: float

def upper(s: str) -> str:
    return (s or "").strip().upper()

def f(s: str) -> float:
    s = (s or "").strip().replace(",", ".")
    return float(s) if s else 0.0

def compute_slave_lots(symbol: str, master_lots: float) -> float:
    if CUENTA_FONDEO:
        return float(master_lots) * LOT_MULTIPLIER

    info = mt5.symbol_info(symbol)
    if info is None:
        raise RuntimeError(f"Símbolo no válido: {symbol}")

    min_lot  = float(info.volume_min)
    max_lot  = float(info.volume_max)
    step    = float(info.volume_step) if info.volume_step > 0 else float(info.volume_min)

    lots = float(FIXED_LOTS)
    lots = (lots // step) * step  # floor al step
    if lots < min_lot: lots = min_lot
    if lots > max_lot: lots = max_lot

    # normalizar decimales según step (2–4 típicamente)
    lot_digits = 2
    tmp = step
    d = 0
    while tmp < 1.0 and d < 4:
        tmp *= 10.0
        d += 1
    lot_digits = max(2, d)
    return round(lots, lot_digits)

def ensure_symbol(symbol: str):
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"No puedo seleccionar {symbol}: {mt5.last_error()}")

def clone_comment(master_ticket: str) -> str:
    """Retorna solo el ticket maestro como comentario (evita truncamiento)"""
    return master_ticket

def find_open_clone(symbol: str, comment: str, master_ticket: str = None):
    """Busca una posición abierta por símbolo y comentario (ticket maestro)"""
    poss = mt5.positions_get(symbol=symbol)
    if not poss:
        return None
    
    # El comentario ahora es solo el ticket maestro
    search_ticket = (master_ticket or comment).strip()
    
    for p in poss:
        pos_comment = (p.comment or "").strip()
        
        # Comparación exacta (el comentario es el ticket maestro)
        if pos_comment == search_ticket:
            return p
    
    return None

def find_ticket_in_history(symbol: str, master_ticket: str):
    """Busca el ticket origen en el historial (deals y órdenes) por campo comment"""
    master_ticket = master_ticket.strip()
    
    # Buscar en las últimas 90 días
    from_date = datetime.now() - timedelta(days=90)
    to_date = datetime.now()
    
    # Buscar en TODOS los deals del historial
    deals = mt5.history_deals_get(from_date, to_date)
    if deals:
        for deal in deals:
            deal_symbol = deal.symbol or ""
            deal_comment = (deal.comment or "").strip()
            
            # Buscar el ticket maestro en el comentario
            if deal_symbol == symbol and master_ticket in deal_comment:
                return True
    
    # Buscar en TODAS las órdenes del historial
    orders = mt5.history_orders_get(from_date, to_date)
    if orders:
        for order in orders:
            order_symbol = order.symbol or ""
            order_comment = (order.comment or "").strip()
            
            # Buscar el ticket maestro en el comentario
            if order_symbol == symbol and master_ticket in order_comment:
                return True
    
    return False

def ticket_exists_anywhere(symbol: str, master_ticket: str):
    """Verifica si el ticket origen existe en abiertas O en historial"""
    # Buscar en posiciones abiertas
    comment = master_ticket  # El comment es el ticket maestro
    if find_open_clone(symbol, comment, master_ticket) is not None:
        return True
    
    # Buscar en historial
    if find_ticket_in_history(symbol, master_ticket):
        return True
    
    return False

# Función eliminada - ahora usamos ticket_exists_anywhere() directamente

def open_clone(ev: Ev) -> tuple[bool, str]:
    """
    Ejecuta OPEN (BUY/SELL) con reintentos inmediatos.
    Retorna (True, "EXITOSO") si se ejecutó exitosamente
    Retorna (False, motivo_error) si falla después de 3 intentos (motivo del broker)
    """
    ensure_symbol(ev.symbol)
    comment = clone_comment(ev.master_ticket)
    lots = compute_slave_lots(ev.symbol, ev.master_lots)
    
    # Reintentos inmediatos (3 intentos)
    for intento in range(1, 4):
        try:
            tick = mt5.symbol_info_tick(ev.symbol)
            if tick is None:
                raise RuntimeError(f"No tick para {ev.symbol}")

            if ev.order_type == "BUY":
                otype = mt5.ORDER_TYPE_BUY
                price = tick.ask
            elif ev.order_type == "SELL":
                otype = mt5.ORDER_TYPE_SELL
                price = tick.bid
            else:
                raise ValueError(f"order_type no soportado: {ev.order_type}")

            req = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": ev.symbol,
                "volume": lots,
                "type": otype,
                "price": price,
                "sl": ev.sl if ev.sl > 0 else 0.0,
                "tp": ev.tp if ev.tp > 0 else 0.0,
                "deviation": SLIPPAGE_POINTS,
                "magic": MAGIC,
                "comment": comment,
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": mt5.ORDER_FILLING_FOK,
            }
            res = mt5.order_send(req)
            
            if res is not None and res.retcode in (mt5.TRADE_RETCODE_DONE, mt5.TRADE_RETCODE_PLACED):
                return (True, "EXITOSO")
            
            # Si falla, preparar mensaje de error del broker
            error_msg = f"retcode={getattr(res,'retcode',None)} comment={getattr(res,'comment','')}"
            
            # Si es el último intento, retornar error
            if intento == 3:
                return (False, f"ERROR BROKER: {error_msg}")
            
            # Continuar con siguiente intento
            continue
            
        except Exception as e:
            error_msg = str(e)
            if intento == 3:
                return (False, f"ERROR: {error_msg}")
            continue
    
    return (False, "ERROR: Fallo después de 3 intentos")

def close_clone(ev: Ev) -> tuple[bool, str]:
    """
    Ejecuta CLOSE con reintentos inmediatos.
    Retorna (True, "EXITOSO") si se ejecutó exitosamente
    Retorna (True, "ya estaba cerrada") si la posición ya estaba cerrada (éxito)
    Retorna (False, motivo_error) si falla después de 3 intentos (motivo del broker)
    """
    comment = clone_comment(ev.master_ticket)
    ensure_symbol(ev.symbol)
    
    # Buscar posición abierta para cerrar
    p = find_open_clone(ev.symbol, comment, ev.master_ticket)
    if p is None:
        # Posición no encontrada = ya estaba cerrada (éxito)
        return (True, "ya estaba cerrada")
    
    # Reintentos inmediatos (3 intentos)
    for intento in range(1, 4):
        try:
            tick = mt5.symbol_info_tick(ev.symbol)
            if tick is None:
                raise RuntimeError(f"No tick para {ev.symbol}")

            # Verificar que la posición sigue existiendo (puede haberse cerrado entre intentos)
            p = find_open_clone(ev.symbol, comment, ev.master_ticket)
            if p is None:
                return (True, "ya estaba cerrada")

            # Cerrar: operación contraria con position=ticket
            if p.type == mt5.POSITION_TYPE_BUY:
                otype = mt5.ORDER_TYPE_SELL
                price = tick.bid
            else:
                otype = mt5.ORDER_TYPE_BUY
                price = tick.ask

            req = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": ev.symbol,
                "position": int(p.ticket),
                "volume": float(p.volume),
                "type": otype,
                "price": price,
                "deviation": SLIPPAGE_POINTS,
                "magic": int(p.magic),
                "comment": comment,
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": mt5.ORDER_FILLING_FOK,
            }
            res = mt5.order_send(req)
            
            if res is not None and res.retcode == mt5.TRADE_RETCODE_DONE:
                return (True, "EXITOSO")
            
            # Si falla, preparar mensaje de error del broker
            error_msg = f"retcode={getattr(res,'retcode',None)} comment={getattr(res,'comment','')}"
            
            # Si es el último intento, retornar error
            if intento == 3:
                return (False, f"ERROR BROKER: {error_msg}")
            
            # Continuar con siguiente intento
            continue
            
        except Exception as e:
            error_msg = str(e)
            if intento == 3:
                return (False, f"ERROR: {error_msg}")
            continue
    
    return (False, "ERROR: Fallo después de 3 intentos")

def modify_clone(ev: Ev) -> tuple[bool, str]:
    """
    Ejecuta MODIFY con reintentos inmediatos.
    Retorna (True, "EXITOSO") si se ejecutó exitosamente
    Retorna (False, motivo_error) si falla después de 3 intentos (motivo del broker)
    """
    comment = clone_comment(ev.master_ticket)
    
    # Buscar posición abierta para modificar
    p = find_open_clone(ev.symbol, comment, ev.master_ticket)
    if p is None:
        # Posición no existe = no se puede modificar, tratar como éxito (ya procesado)
        return (True, "EXITOSO")
    
    # Reintentos inmediatos (3 intentos)
    for intento in range(1, 4):
        try:
            # Verificar que la posición sigue existiendo (puede haberse cerrado entre intentos)
            p = find_open_clone(ev.symbol, comment, ev.master_ticket)
            if p is None:
                return (True, "EXITOSO")  # Ya no existe, tratar como éxito
            
            req = {
                "action": mt5.TRADE_ACTION_SLTP,
                "position": int(p.ticket),
                "symbol": ev.symbol,
                "sl": ev.sl if ev.sl > 0 else 0.0,
                "tp": ev.tp if ev.tp > 0 else 0.0,
                "comment": comment,
            }
            res = mt5.order_send(req)
            
            # NO_CHANGES es normal si repites la misma modificación
            if res is not None and res.retcode in (mt5.TRADE_RETCODE_DONE, mt5.TRADE_RETCODE_NO_CHANGES):
                return (True, "EXITOSO")
            
            # Si falla, preparar mensaje de error del broker
            error_msg = f"retcode={getattr(res,'retcode',None)} comment={getattr(res,'comment','')}"
            
            # Si es el último intento, retornar error
            if intento == 3:
                return (False, f"ERROR BROKER: {error_msg}")
            
            # Continuar con siguiente intento
            continue
            
        except Exception as e:
            error_msg = str(e)
            if intento == 3:
                return (False, f"ERROR: {error_msg}")
            continue
    
    return (False, "ERROR: Fallo después de 3 intentos")

def read_events_from_csv(path: str) -> tuple[list[Ev], list[str], str]:
    """
    Lee el CSV y retorna:
    - Lista de eventos parseados
    - Lista de líneas originales (sin header)
    - Header del CSV
    """
    events: list[Ev] = []
    lines: list[str] = []
    
    # Intentar diferentes codificaciones
    encodings = ["utf-8", "utf-8-sig", "windows-1252", "latin-1", "cp1252"]
    file_content = None
    used_encoding = None
    
    for enc in encodings:
        try:
            with open(path, "rb") as file_handle:
                raw_content = file_handle.read()
            file_content = raw_content.decode(enc)
            used_encoding = enc
            break
        except (UnicodeDecodeError, UnicodeError):
            continue
    
    if file_content is None:
        raise RuntimeError(f"No se pudo decodificar el archivo {path} con ninguna codificación conocida")
    
    # Dividir en líneas
    all_lines = file_content.splitlines()
    
    if not all_lines:
        return events, lines, ""
    
    header = all_lines[0]
    
    # Parsear cada línea (empezando desde la línea 1, saltando header)
    for line in all_lines[1:]:
        line = line.strip()
        if not line:
            continue
        
        # Parsear línea con delimiter ";"
        row = line.split(";")
        if len(row) < 5:
            continue

        # indices según tu formato:
        # 0 event_type; 1 ticket; 2 order_type; 3 lots; 4 symbol; ... 7 sl; 8 tp
        et = upper(row[0])
        master_ticket = (row[1] or "").strip()
        ot = upper(row[2])
        lots = f(row[3])
        sym = upper(row[4])
        sl = f(row[7]) if len(row) > 7 else 0.0
        tp = f(row[8]) if len(row) > 8 else 0.0

        if not sym or not master_ticket:
            continue

        # Guardar línea original y evento parseado
        lines.append(line)
        events.append(Ev(et, master_ticket, ot, lots, sym, sl, tp))
    
    return events, lines, header

def common_files_csv_path(csv_name: str) -> str:
    ti = mt5.terminal_info()
    if ti is None:
        raise RuntimeError("No hay terminal_info() (¿MT5 abierto?)")
    # normalmente: <commondata_path>\\Files\\TradeEvents.csv
    return os.path.join(ti.commondata_path, "Files", csv_name)

def append_to_history_csv(csv_line: str, resultado: str = "EXITOSO"):
    """Añade una línea al archivo TXT histórico con timestamp y resultado"""
    hist_path = common_files_csv_path(CSV_HISTORICO)
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    # Crear línea histórica: timestamp_ejecucion;resultado;línea_original_completa
    hist_line = f"{timestamp};{resultado};{csv_line}\n"
    
    try:
        # Si el archivo no existe, crear con header
        if not os.path.exists(hist_path):
            with open(hist_path, "w", encoding="utf-8", newline="") as f:
                # Header: timestamp_ejecucion;resultado;event_type;ticket;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit
                f.write("timestamp_ejecucion;resultado;event_type;ticket;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit\n")
        
        # Añadir línea al histórico
        with open(hist_path, "a", encoding="utf-8", newline="") as f:
            f.write(hist_line)
    except Exception as e:
        print(f"[ERROR] No se pudo escribir al histórico: {e}")

def write_csv(path: str, header: str, lines: list[str]):
    """Reescribe el CSV con header y líneas especificadas"""
    try:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(header + "\n")
            for line in lines:
                f.write(line + "\n")
    except Exception as e:
        raise RuntimeError(f"Error al escribir CSV: {e}")

def main_loop():
    global LOT_MULTIPLIER
    
    if not mt5.initialize():
        raise SystemExit(f"MT5 init failed: {mt5.last_error()}")

    try:
        # Si es cuenta de fondeo, pedir al usuario el multiplicador de lotaje
        if CUENTA_FONDEO:
            print("=" * 60)
            print("CONFIGURACIÓN DE MULTIPLICADOR DE LOTAJE")
            print("=" * 60)
            print("Seleccione el multiplicador para el lotaje origen:")
            print("  1. Multiplicar por 1 (lotaje original)")
            print("  2. Multiplicar por 2 (doble del lotaje)")
            print("  3. Multiplicar por 3 (triple del lotaje)")
            print("-" * 60)
            
            while True:
                try:
                    opcion = input("Ingrese su opción (1, 2 o 3): ").strip()
                    if opcion == "1":
                        LOT_MULTIPLIER = 1.0
                        print(f"✓ Multiplicador configurado: {LOT_MULTIPLIER}x (lotaje original)")
                        break
                    elif opcion == "2":
                        LOT_MULTIPLIER = 2.0
                        print(f"✓ Multiplicador configurado: {LOT_MULTIPLIER}x (doble del lotaje)")
                        break
                    elif opcion == "3":
                        LOT_MULTIPLIER = 3.0
                        print(f"✓ Multiplicador configurado: {LOT_MULTIPLIER}x (triple del lotaje)")
                        break
                    else:
                        print("❌ Opción inválida. Por favor ingrese 1, 2 o 3.")
                except (EOFError, KeyboardInterrupt):
                    print("\nOperación cancelada.")
                    raise SystemExit("Configuración cancelada por el usuario")
            print("-" * 60)
        
        path = common_files_csv_path(CSV_NAME)
        print(f"ClonadorOrdenes.py iniciado")
        print(f"Leyendo CSV: {path}")
        print(f"Timer: {TIMER_SECONDS} segundos")
        print(f"Cuenta Fondeo: {CUENTA_FONDEO}")
        if CUENTA_FONDEO:
            print(f"Multiplicador de lotaje: {LOT_MULTIPLIER}x")
        print(f"Modo: Ejecución directa con reintentos (3 intentos inmediatos)")
        print(f"Presiona Ctrl+C para detener")
        print("-" * 60)

        while True:
            try:
                if os.path.exists(path) and os.path.getsize(path) > 0:
                    # Leer eventos y líneas originales
                    events, lines, header = read_events_from_csv(path)
                    
                    # Procesar cada evento (todas las líneas se procesan y pasan al histórico)
                    eventos_procesados = 0
                    for idx, ev in enumerate(events):
                        if idx >= len(lines):
                            continue  # Protección contra desincronización
                        
                        original_line = lines[idx]
                        
                        try:
                            # Procesar el evento (ejecución directa con reintentos)
                            if ev.event_type == "OPEN":
                                executed_successfully, motivo = open_clone(ev)
                                if executed_successfully:
                                    print(f"[OPEN] {ev.symbol} {ev.order_type} {ev.master_lots} lots (maestro: {ev.master_ticket})")
                                    append_to_history_csv(original_line, motivo)
                                else:
                                    # Fallo después de 3 intentos, eliminar del CSV y pasar al histórico
                                    print(f"[OPEN FALLIDO] {ev.symbol} (maestro: {ev.master_ticket}): {motivo}")
                                    append_to_history_csv(original_line, motivo)
                                eventos_procesados += 1
                                    
                            elif ev.event_type == "CLOSE":
                                executed_successfully, motivo = close_clone(ev)
                                if executed_successfully:
                                    if motivo == "ya estaba cerrada":
                                        print(f"[CLOSE] {ev.symbol} (maestro: {ev.master_ticket}) - Ya estaba cerrada")
                                    else:
                                        print(f"[CLOSE] {ev.symbol} (maestro: {ev.master_ticket})")
                                    append_to_history_csv(original_line, motivo)
                                else:
                                    # Fallo después de 3 intentos, eliminar del CSV y pasar al histórico
                                    print(f"[CLOSE FALLIDO] {ev.symbol} (maestro: {ev.master_ticket}): {motivo}")
                                    append_to_history_csv(original_line, motivo)
                                eventos_procesados += 1
                                    
                            elif ev.event_type == "MODIFY":
                                executed_successfully, motivo = modify_clone(ev)
                                if executed_successfully:
                                    print(f"[MODIFY] {ev.symbol} SL={ev.sl} TP={ev.tp} (maestro: {ev.master_ticket})")
                                    append_to_history_csv(original_line, motivo)
                                else:
                                    # Fallo después de 3 intentos, eliminar del CSV y pasar al histórico
                                    print(f"[MODIFY FALLIDO] {ev.symbol} (maestro: {ev.master_ticket}): {motivo}")
                                    append_to_history_csv(original_line, motivo)
                                eventos_procesados += 1
                            # otros event_type: ignorar (no se procesan ni eliminan)
                                
                        except Exception as e:
                            # Error crítico inesperado, eliminar del CSV y pasar al histórico
                            print(f"[ERROR CRÍTICO] {ev.event_type} {ev.symbol} (maestro: {ev.master_ticket}): {e}")
                            append_to_history_csv(original_line, f"ERROR CRÍTICO: {str(e)}")
                            eventos_procesados += 1
                    
                    # Eliminar todas las líneas procesadas del CSV (siempre se procesan todas)
                    if eventos_procesados > 0:
                        write_csv(path, header, [])
                        print(f"[CSV] Actualizado: {eventos_procesados} eventos procesados, CSV vaciado")
            except Exception as e:
                print(f"ERROR: {e}")

            time.sleep(TIMER_SECONDS)
    except KeyboardInterrupt:
        print("\nDeteniendo ClonadorOrdenes...")
    finally:
        mt5.shutdown()
        print("MT5 desconectado")

if __name__ == "__main__":
    main_loop()


