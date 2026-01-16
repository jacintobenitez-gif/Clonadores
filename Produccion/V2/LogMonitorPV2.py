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
        }
        self.last_summary_date = None
        
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
        }
    
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
        
        message = (
            f"📊 OmegaInversiones - Resumen Diario\n"
            f"━━━━━━━━━━━━━━━━━━━━━\n"
            f"{status_icon} Estado: {status_text}\n"
            f"⏱️ Uptime: {uptime_hours}h {uptime_mins}m\n"
            f"👷 Workers: {', '.join(workers) if workers else 'Ninguno'}\n"
            f"━━━━━━━━━━━━━━━━━━━━━\n"
            f"📈 Errores últimas 24h:\n"
            f"   • Total: {self.stats['errors_today']}\n"
            f"   • OPEN: {self.stats['open_failed']}\n"
            f"   • MODIFY: {self.stats['modify_failed']}\n"
            f"   • CLOSE: {self.stats['close_failed']}\n"
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
                # Verificar si es hora del resumen diario
                if self.should_send_summary():
                    self.send_daily_summary()
                
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
