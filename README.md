# Clonadores - Sistema de Clonación de Órdenes para MetaTrader

Sistema para clonar operaciones de trading desde una cuenta maestra a una cuenta esclava en MetaTrader 4 y MetaTrader 5.

## Archivos del Proyecto

- **ClonadorMQ5.py**: Script Python que lee eventos desde `TradeEvents.csv` y ejecuta operaciones OPEN/CLOSE/MODIFY en MetaTrader 5
- **ClonadorOrdenes.mq4**: Expert Advisor para MetaTrader 4 (equivalente MQL4)
- **LectorOrdenes.mq4**: Script para leer y generar eventos de trading

## Requisitos

- Python 3.x
- MetaTrader 5 instalado
- Librería `MetaTrader5` de Python: `pip install MetaTrader5`

## Configuración

1. Configurar las variables en `ClonadorMQ5.py`:
   - `CSV_NAME`: Nombre del archivo CSV con eventos (por defecto: "TradeEvents.csv")
   - `TIMER_SECONDS`: Intervalo de lectura del CSV (por defecto: 3 segundos)
   - `CUENTA_FONDEO`: Si es `True`, copia los lotes del maestro; si es `False`, usa lote fijo
   - `FIXED_LOTS`: Lote fijo cuando `CUENTA_FONDEO = False`
   - `SLIPPAGE_POINTS`: Desviación permitida en puntos

2. Si `CUENTA_FONDEO = True`, al iniciar el script se pedirá elegir un multiplicador de lotaje (1x, 2x o 3x)

## Uso

1. Colocar el archivo `TradeEvents.csv` en `Common\Files` de MetaTrader 5
2. Ejecutar: `python ClonadorMQ5.py`
3. El script leerá el CSV periódicamente y ejecutará las operaciones
4. Los eventos procesados se registrarán en `TradeEvents_historico.txt`

## Formato del CSV

El archivo `TradeEvents.csv` debe tener el siguiente formato (delimitado por `;`):

```
event_type;ticket;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit
OPEN;123456;BUY;0.10;EURUSD;1.1000;2025.01.01 10:00:00;1.0950;1.1050;;;
CLOSE;123456;BUY;0.10;EURUSD;1.1000;2025.01.01 10:00:00;;;1.1050;2025.01.01 12:00:00;50.00
MODIFY;123456;BUY;0.10;EURUSD;1.1000;2025.01.01 10:00:00;1.0980;1.1020;;;
```

## Características

- ✅ Prevención de duplicados (verifica en posiciones abiertas e historial)
- ✅ Soporte para operaciones OPEN, CLOSE y MODIFY
- ✅ Multiplicador de lotaje configurable
- ✅ Registro histórico de todas las ejecuciones
- ✅ Manejo robusto de errores

## Licencia

[Especificar licencia si aplica]

