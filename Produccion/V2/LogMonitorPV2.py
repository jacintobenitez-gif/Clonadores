# -*- coding: utf-8 -*-
"""
LogMonitorPV2.py - Monitor de logs en tiempo real para OmegaInversiones V2
Detecta anomalías y envía alertas a Telegram

Uso:
    python LogMonitorPV2.py                 # Modo normal
    python LogMonitorPV2.py --test          # Enviar mensaje de prueba
    python LogMonitorPV2.py --daemon        # Correr como daemon (sin ventana)
"""

import os
import sys
import time
import csv
import requests
import warnings
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict

# Suprimir warnings de SSL
warnings.filterwarnings('ignore', message='Unverified HTTPS request')

# =============================================================================
# CONFIGURACIÓN
# =============================================================================

TELEGRAM_BOT_TOKEN = "7950672242:AAG9IV-kKDnP2UXjFSDqj7xpNgBp6yw3bsE"
TELEGRAM_CHAT_ID = "7949423647"

# Ruta base de los logs
LOGS_BASE_PATH = Path(os.environ.get('APPDATA', '')) / "MetaQuotes" / "Terminal" / "Common" / "Files" / "PROD" / "Phoenix" / "V2"

# Intervalo de monitoreo (segundos)
MONITOR_INTERVAL = 30

# Hora del resumen diario (formato 24h)
DAILY_SUMMARY_HOUR = 8  # 08:00

# Horas para reportes horarios (de 8:00 a 20:00)
HOURLY_REPORT_START = 8
HOURLY_REPORT_END = 20

# Archivo para guardar estado del monitor
STATE_FILE = Path(__file__).parent / "monitor_state.json"

# =============================================================================
# TELEGRAM
# =============================================================================

def send_telegram(message: str, parse_mode: str = None) -> bool:
    """Envía mensaje a Telegram"""
    try:
        url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
        data = {
            "chat_id": TELEGRAM_CHAT_ID,
            "text": message,
        }
        if parse_mode:
            data["parse_mode"] = parse_mode
        
        response = requests.post(url, data=data, verify=False, timeout=10)
        return response.json().get("ok", False)
    except Exception as e:
        print(f"[ERROR] Telegram: {e}")
        return False

# =============================================================================
# LECTURA DE LOGS
# =============================================================================

def read_csv_file(filepath: Path) -> list:
    """Lee un archivo CSV y retorna lista de filas"""
    if not filepath.exists():
        return []
    
    rows = []
    try:
        with open(filepath, 'r', encoding='utf-8-sig') as f:
            content = f.read()
        
        for line in content.strip().split('\n'):
            if line.strip():
                rows.append(line.split(';'))
    except Exception as e:
        print(f"[ERROR] Leyendo {filepath}: {e}")
    
    return rows

def get_file_mod_time(filepath: Path) -> float:
    """Obtiene el tiempo de modificación de un archivo"""
    try:
        return filepath.stat().st_mtime if filepath.exists() else 0
    except:
        return 0

# =============================================================================
# DETECCIÓN DE ANOMALÍAS
# =============================================================================

class LogMonitor:
    def __init__(self):
        self.last_check_time = time.time()
        self.known_errors = set()  # Errores ya notificados
        self.last_activity = {}    # Última actividad por worker
        self.last_file_sizes = {}  # Tamaños de archivo conocidos
        self.startup_time = time.time()
        
        # Estadísticas para resumen diario
        self.stats = {
            'errors_today': 0,
            'open_failed': 0,
            'modify_failed': 0,
            'close_failed': 0,
            'open_ok': 0,
            'modify_ok': 0,
            'close_ok': 0,
        }
        self.last_summary_date = None
        self.last_hourly_report = None  # Última hora en que se envió reporte horario
        self.known_success = set()  # Éxitos ya contabilizados
        
    def check_errors_file(self, worker_id: str) -> list:
        """Revisa el archivo de errores de un worker"""
        alerts = []
        filepath = LOGS_BASE_PATH / f"errores_WORKER_{worker_id}.csv"
        
        if not filepath.exists():
            return alerts
        
        rows = read_csv_file(filepath)
        
        for row in rows:
            if len(row) < 5:
                continue
            
            # Crear clave única para este error
            error_key = f"{worker_id}_{';'.join(row[:5])}"
            
            if error_key not in self.known_errors:
                self.known_errors.add(error_key)
                
                # Solo alertar si no estamos en startup (primeros 60 seg)
                if time.time() - self.startup_time > 60:
                    ticket = row[0] if len(row) > 0 else "?"
                    event_type = row[2] if len(row) > 2 else "?"
                    error_code = row[3] if len(row) > 3 else "?"
                    detail = row[7] if len(row) > 7 else ""
                    
                    alerts.append({
                        'severity': '🔴',
                        'type': 'ERROR',
                        'worker': worker_id,
                        'message': f"Ticket {ticket} - {event_type}: {error_code}\n{detail[:100]}"
                    })
        
        return alerts
    
    def check_estados_file(self, worker_id: str) -> list:
        """Revisa el archivo de estados buscando errores críticos"""
        alerts = []
        filepath = LOGS_BASE_PATH / f"estados_WORKER_{worker_id}.csv"
        
        if not filepath.exists():
            return alerts
        
        # Actualizar última actividad
        mod_time = get_file_mod_time(filepath)
        if mod_time > 0:
            self.last_activity[worker_id] = mod_time
        
        rows = read_csv_file(filepath)
        
        # Buscar errores críticos recientes
        for row in rows:
            if len(row) < 5:
                continue
            
            ticket = row[0]
            event_type = row[1]
            estado = row[2]
            resultado = row[4] if len(row) > 4 else ""
            extra = row[5] if len(row) > 5 else ""
            
            # Extraer tipo base del evento (MODIFY_0.00_4640.00 -> MODIFY)
            event_base = event_type.split("_")[0] if "_" in event_type else event_type
            
            # Detectar errores según tipo de evento
            if resultado.startswith("ERR_"):
                error_key = f"estado_{worker_id}_{ticket}_{event_type}_{resultado}"
                
                if error_key not in self.known_errors:
                    self.known_errors.add(error_key)
                    
                    if time.time() - self.startup_time > 60:
                        # Determinar severidad y tipo
                        if event_base == "OPEN":
                            severity = "🔴"
                            alert_type = "OPEN_FAILED"
                            message = f"Ticket {ticket} - OPEN fallido: {resultado}"
                        elif event_base == "MODIFY":
                            # Extraer SL/TP del event_type si está disponible
                            sl_tp_info = ""
                            if "_" in event_type:
                                parts = event_type.split("_")
                                if len(parts) >= 3:
                                    sl_tp_info = f"\nSL={parts[1]} TP={parts[2]}"
                            
                            # ERR_NO_ENCONTRADA es menos grave (posición ya cerrada)
                            severity = "🟡" if resultado == "ERR_NO_ENCONTRADA" or resultado == "ERR_YA_CERRADA" else "🔴"
                            alert_type = "MODIFY_FAILED"
                            message = f"Ticket {ticket} - MODIFY: {resultado}{sl_tp_info}"
                        elif event_base == "CLOSE":
                            severity = "🔴"
                            alert_type = "CLOSE_FAILED"
                            message = f"Ticket {ticket} - CLOSE: {resultado}"
                        else:
                            severity = "🔴"
                            alert_type = "ERROR"
                            message = f"Ticket {ticket} - {event_type}: {resultado}"
                        
                        alerts.append({
                            'severity': severity,
                            'type': alert_type,
                            'worker': worker_id,
                            'message': message
                        })
            
            # Contar operaciones exitosas (OK)
            elif resultado == "OK" or resultado.startswith("OK_"):
                success_key = f"ok_{worker_id}_{ticket}_{event_type}"
                
                if success_key not in self.known_success:
                    self.known_success.add(success_key)
                    
                    if event_base == "OPEN":
                        self.stats['open_ok'] += 1
                    elif event_base == "MODIFY":
                        self.stats['modify_ok'] += 1
                    elif event_base == "CLOSE":
                        self.stats['close_ok'] += 1
        
        return alerts
    
    
    def check_pending_tickets(self) -> list:
        """Verifica tickets del Master pendientes de procesar"""
        alerts = []
        
        master_file = LOGS_BASE_PATH / "Historico_Master.csv"
        if not master_file.exists():
            return alerts
        
        # Por ahora solo verificar que el archivo existe y se actualiza
        mod_time = get_file_mod_time(master_file)
        if mod_time > 0:
            self.last_activity['MASTER'] = mod_time
        
        return alerts
    
    def discover_workers(self) -> list:
        """Descubre los workers configurados mirando archivos existentes"""
        workers = set()
        
        if not LOGS_BASE_PATH.exists():
            return list(workers)
        
        for f in LOGS_BASE_PATH.glob("estados_WORKER_*.csv"):
            worker_id = f.stem.replace("estados_WORKER_", "")
            workers.add(worker_id)
        
        for f in LOGS_BASE_PATH.glob("cola_WORKER_*.csv"):
            worker_id = f.stem.replace("cola_WORKER_", "")
            workers.add(worker_id)
        
        return list(workers)
    
    def run_check(self) -> list:
        """Ejecuta una verificación completa"""
        all_alerts = []
        
        workers = self.discover_workers()
        
        for worker_id in workers:
            all_alerts.extend(self.check_errors_file(worker_id))
            all_alerts.extend(self.check_estados_file(worker_id))
        
        all_alerts.extend(self.check_pending_tickets())
        
        return all_alerts
    
    def format_alert(self, alert: dict) -> str:
        """Formatea una alerta para Telegram"""
        return (
            f"{alert['severity']} {alert['type']}\n"
            f"Worker: {alert['worker']}\n"
            f"{alert['message']}"
        )
    
    def update_stats(self, alert: dict):
        """Actualiza las estadísticas con una nueva alerta"""
        self.stats['errors_today'] += 1
        
        alert_type = alert.get('type', '')
        if 'OPEN' in alert_type:
            self.stats['open_failed'] += 1
        elif 'MODIFY' in alert_type:
            self.stats['modify_failed'] += 1
        elif 'CLOSE' in alert_type:
            self.stats['close_failed'] += 1
    
    def reset_stats(self):
        """Reinicia las estadísticas diarias"""
        self.stats = {
            'errors_today': 0,
            'open_failed': 0,
            'modify_failed': 0,
            'close_failed': 0,
            'open_ok': 0,
            'modify_ok': 0,
            'close_ok': 0,
        }
        self.known_success.clear()
    
    def should_send_summary(self) -> bool:
        """Verifica si es hora de enviar el resumen diario"""
        now = datetime.now()
        today = now.date()
        
        # Si ya enviamos resumen hoy, no enviar
        if self.last_summary_date == today:
            return False
        
        # Enviar si es la hora configurada (o después, si acabamos de arrancar)
        if now.hour >= DAILY_SUMMARY_HOUR:
            return True
        
        return False
    
    def get_worker_stats_from_historico(self, worker_id: str) -> dict:
        """Lee el histórico del worker y calcula estadísticas del día"""
        stats = {
            'open_ok': 0,
            'modify_ok': 0,
            'close_ok': 0,
            'open_err': 0,
            'modify_err': 0,
            'close_err': 0,
            'profit_gained': 0.0,
            'profit_lost': 0.0,
            'trades_won': 0,
            'trades_lost': 0,
        }
        
        filepath = LOGS_BASE_PATH / f"historico_WORKER_{worker_id}.csv"
        if not filepath.exists():
            return stats
        
        today = datetime.now().date()
        rows = read_csv_file(filepath)
        
        for row in rows:
            if len(row) < 5:
                continue
            
            # Formato: fecha;ticket;tipo;intentos;timestamp;resultado;profit
            try:
                fecha_str = row[0].split()[0]  # "2026.01.17" -> solo fecha
                fecha = datetime.strptime(fecha_str, "%Y.%m.%d").date()
            except:
                continue
            
            # Solo contar operaciones de hoy
            if fecha != today:
                continue
            
            event_type = row[2] if len(row) > 2 else ""
            resultado = row[5] if len(row) > 5 else ""
            profit_str = row[6] if len(row) > 6 else ""
            
            # Contar operaciones
            if resultado == "OK" or resultado.startswith("OK_"):
                if event_type == "OPEN":
                    stats['open_ok'] += 1
                elif event_type == "MODIFY":
                    stats['modify_ok'] += 1
                elif event_type == "CLOSE":
                    stats['close_ok'] += 1
                    # Extraer profit si está disponible
                    if profit_str:
                        try:
                            profit = float(profit_str)
                            if profit >= 0:
                                stats['profit_gained'] += profit
                                stats['trades_won'] += 1
                            else:
                                stats['profit_lost'] += abs(profit)
                                stats['trades_lost'] += 1
                        except ValueError:
                            pass
            elif resultado.startswith("ERR_"):
                if event_type == "OPEN":
                    stats['open_err'] += 1
                elif event_type == "MODIFY":
                    stats['modify_err'] += 1
                elif event_type == "CLOSE":
                    stats['close_err'] += 1
        
        return stats
    
    def get_worker_stats_from_estados(self, worker_id: str) -> dict:
        """Obtiene estadísticas del día desde el archivo de estados"""
        stats = {
            'open_ok': 0,
            'modify_ok': 0,
            'close_ok': 0,
            'open_err': 0,
            'modify_err': 0,
            'close_err': 0,
        }
        
        filepath = LOGS_BASE_PATH / f"estados_WORKER_{worker_id}.csv"
        if not filepath.exists():
            return stats
        
        today = datetime.now().strftime("%Y.%m.%d")
        rows = read_csv_file(filepath)
        
        for row in rows:
            if len(row) < 5:
                continue
            
            # Solo contar si tiene fecha de hoy (algunos formatos pueden variar)
            event_type = row[1] if len(row) > 1 else ""
            resultado = row[4] if len(row) > 4 else ""
            
            event_base = event_type.split("_")[0] if "_" in event_type else event_type
            
            if resultado == "OK" or resultado.startswith("OK_"):
                if event_base == "OPEN":
                    stats['open_ok'] += 1
                elif event_base == "MODIFY":
                    stats['modify_ok'] += 1
                elif event_base == "CLOSE":
                    stats['close_ok'] += 1
            elif resultado.startswith("ERR_"):
                if event_base == "OPEN":
                    stats['open_err'] += 1
                elif event_base == "MODIFY":
                    stats['modify_err'] += 1
                elif event_base == "CLOSE":
                    stats['close_err'] += 1
        
        return stats
    
    def should_send_hourly_report(self) -> bool:
        """Verifica si es hora de enviar reporte horario"""
        now = datetime.now()
        current_hour = now.hour
        
        # Solo entre las horas configuradas
        if current_hour < HOURLY_REPORT_START or current_hour > HOURLY_REPORT_END:
            return False
        
        # No enviar si ya enviamos esta hora
        current_hour_key = f"{now.date()}_{current_hour}"
        if self.last_hourly_report == current_hour_key:
            return False
        
        # Enviar solo en los primeros minutos de la hora (0-5)
        if now.minute > 5:
            return False
        
        return True
    
    def send_hourly_report(self):
        """Envía el reporte horario con desglose por worker"""
        workers = self.discover_workers()
        now = datetime.now()
        
        # Construir mensaje
        lines = [
            f"📊 OmegaInversiones - Reporte Horario",
            f"━━━━━━━━━━━━━━━━━━━━━",
            f"🕐 {now.strftime('%d/%m/%Y %H:%M')}",
            ""
        ]
        
        total_gained = 0.0
        total_lost = 0.0
        
        for worker_id in sorted(workers):
            # Intentar obtener stats del histórico (tiene profit)
            stats = self.get_worker_stats_from_historico(worker_id)
            
            # Si no hay historico, usar estados
            if stats['open_ok'] == 0 and stats['close_ok'] == 0:
                stats = self.get_worker_stats_from_estados(worker_id)
            
            total_ok = stats['open_ok'] + stats['modify_ok'] + stats['close_ok']
            total_err = stats.get('open_err', 0) + stats.get('modify_err', 0) + stats.get('close_err', 0)
            
            lines.append(f"👷 Worker {worker_id}")
            lines.append(f"   ✅ OPEN: {stats['open_ok']} | MODIFY: {stats['modify_ok']} | CLOSE: {stats['close_ok']}")
            lines.append(f"   ❌ Errores: {total_err}")
            
            # Datos económicos (solo si hay historico con profit)
            gained = stats.get('profit_gained', 0)
            lost = stats.get('profit_lost', 0)
            balance = gained - lost
            trades_won = stats.get('trades_won', 0)
            trades_lost = stats.get('trades_lost', 0)
            
            if gained > 0 or lost > 0:
                balance_sign = "+" if balance >= 0 else ""
                lines.append(f"   💰 Balance: ${gained:.2f} - ${lost:.2f} = {balance_sign}${balance:.2f}")
                lines.append(f"   📈 Ganadas: {trades_won} | 📉 Perdidas: {trades_lost}")
            else:
                lines.append(f"   💰 Balance: Sin datos económicos")
            
            lines.append("")
            
            total_gained += gained
            total_lost += lost
        
        # Total general
        total_balance = total_gained - total_lost
        total_sign = "+" if total_balance >= 0 else ""
        
        lines.append(f"━━━━━━━━━━━━━━━━━━━━━")
        lines.append(f"💵 Total día: ${total_gained:.2f} - ${total_lost:.2f} = {total_sign}${total_balance:.2f}")
        
        message = "\n".join(lines)
        send_telegram(message)
        
        # Marcar como enviado
        self.last_hourly_report = f"{now.date()}_{now.hour}"
        print(f"[{now.strftime('%H:%M:%S')}] Reporte horario enviado")
    
    def send_daily_summary(self):
        """Envía el resumen diario"""
        workers = self.discover_workers()
        
        # Determinar estado general
        if self.stats['errors_today'] == 0:
            status_icon = "✅"
            status_text = "Sin errores"
        elif self.stats['errors_today'] < 5:
            status_icon = "⚠️"
            status_text = "Algunos errores"
        else:
            status_icon = "🔴"
            status_text = "Muchos errores"
        
        # Calcular tiempo activo
        uptime_seconds = time.time() - self.startup_time
        uptime_hours = int(uptime_seconds / 3600)
        uptime_mins = int((uptime_seconds % 3600) / 60)
        
        # Calcular totales
        total_ops = self.stats['open_ok'] + self.stats['modify_ok'] + self.stats['close_ok']
        
        message = (
            f"📊 OmegaInversiones - Resumen Diario\n"
            f"━━━━━━━━━━━━━━━━━━━━━\n"
            f"{status_icon} Estado: {status_text}\n"
            f"⏱️ Uptime: {uptime_hours}h {uptime_mins}m\n"
            f"👷 Workers: {', '.join(workers) if workers else 'Ninguno'}\n"
            f"━━━━━━━━━━━━━━━━━━━━━\n"
            f"✅ Operaciones exitosas:\n"
            f"   • OPEN: {self.stats['open_ok']}\n"
            f"   • MODIFY: {self.stats['modify_ok']}\n"
            f"   • CLOSE: {self.stats['close_ok']}\n"
            f"   • Total: {total_ops}\n"
            f"━━━━━━━━━━━━━━━━━━━━━\n"
            f"❌ Errores:\n"
            f"   • OPEN: {self.stats['open_failed']}\n"
            f"   • MODIFY: {self.stats['modify_failed']}\n"
            f"   • CLOSE: {self.stats['close_failed']}\n"
            f"   • Total: {self.stats['errors_today']}\n"
            f"━━━━━━━━━━━━━━━━━━━━━\n"
            f"🕐 {datetime.now().strftime('%d/%m/%Y %H:%M')}"
        )
        
        send_telegram(message)
        
        # Marcar como enviado y resetear stats
        self.last_summary_date = datetime.now().date()
        self.reset_stats()
        
        print(f"[{datetime.now().strftime('%H:%M:%S')}] Resumen diario enviado")
    
    def run(self):
        """Loop principal del monitor"""
        print(f"[{datetime.now()}] OmegaInversiones LogMonitor iniciado")
        print(f"[INFO] Monitoreando: {LOGS_BASE_PATH}")
        print(f"[INFO] Intervalo: {MONITOR_INTERVAL}s")
        print(f"[INFO] Telegram: {TELEGRAM_CHAT_ID}")
        print("-" * 50)
        
        # Notificar inicio
        workers = self.discover_workers()
        send_telegram(
            f"🟢 **OmegaInversiones Monitor iniciado**\n"
            f"Workers detectados: {len(workers)}\n"
            f"IDs: {', '.join(workers) if workers else 'Ninguno'}\n"
            f"Intervalo: {MONITOR_INTERVAL}s"
        )
        
        while True:
            try:
                # Verificar si es hora del resumen diario (8:00)
                if self.should_send_summary():
                    self.send_daily_summary()
                
                # Verificar si es hora del reporte horario (8:00-20:00)
                if self.should_send_hourly_report():
                    self.send_hourly_report()
                
                # Verificar errores
                alerts = self.run_check()
                
                for alert in alerts:
                    msg = self.format_alert(alert)
                    print(f"[ALERT] {msg}")
                    send_telegram(msg)
                    self.update_stats(alert)
                
                if not alerts:
                    print(f"[{datetime.now().strftime('%H:%M:%S')}] OK - Sin alertas")
                
                time.sleep(MONITOR_INTERVAL)
                
            except KeyboardInterrupt:
                print("\n[INFO] Monitor detenido por usuario")
                send_telegram("🔴 OmegaInversiones Monitor detenido")
                break
            except Exception as e:
                print(f"[ERROR] {e}")
                time.sleep(MONITOR_INTERVAL)

# =============================================================================
# MAIN
# =============================================================================

def main():
    if "--test" in sys.argv:
        print("Enviando mensaje de prueba...")
        success = send_telegram("🧪 Test de OmegaInversiones Monitor\n\nSi ves este mensaje, el sistema funciona correctamente.")
        print("OK" if success else "FALLO")
        return
    
    if "--summary" in sys.argv:
        print("Enviando resumen de prueba...")
        monitor = LogMonitor()
        monitor.send_daily_summary()
        print("OK")
        return
    
    if "--hourly" in sys.argv:
        print("Enviando reporte horario de prueba...")
        monitor = LogMonitor()
        monitor.send_hourly_report()
        print("OK")
        return
    
    if "--status" in sys.argv:
        print(f"Ruta de logs: {LOGS_BASE_PATH}")
        print(f"Existe: {LOGS_BASE_PATH.exists()}")
        if LOGS_BASE_PATH.exists():
            files = list(LOGS_BASE_PATH.glob("*.csv"))
            print(f"Archivos CSV: {len(files)}")
            for f in files[:10]:
                print(f"  - {f.name}")
        return
    
    monitor = LogMonitor()
    monitor.run()

if __name__ == "__main__":
    main()
