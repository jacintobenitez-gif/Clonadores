# IDEA: Distribuidor Multi-MT4 con Script Python Intermedio

## Contexto
Necesidad de clonar eventos desde `LectorOrdenes.mq4` a múltiples MT4 (3+ instancias) de forma eficiente.

## Opción Propuesta: Distribuidor Python Intermedio

### Arquitectura

```
LectorOrdenes.mq4 → TradeEvents.csv (sin cambios)

Distribuidor.py (nuevo script):
  - Lee TradeEvents.csv cada 0.5 segundos
  - Distribuye eventos a:
    - TradeEventsMT4-1.txt
    - TradeEventsMT4-2.txt
    - TradeEventsMT4-3.txt
  - Elimina eventos procesados del CSV original

ClonadorMQ4_1.mq4 → Lee TradeEventsMT4-1.txt
ClonadorMQ4_2.mq4 → Lee TradeEventsMT4-2.txt
ClonadorMQ4_3.mq4 → Lee TradeEventsMT4-3.txt
```

### Ventajas

✅ **LectorOrdenes sin cambios**: Solo escribe 1 archivo
✅ **Separación de responsabilidades**: Distribuidor separado
✅ **Escalable**: Fácil agregar más MT4
✅ **Formato TXT**: Más legible que CSV
✅ **Sin conflictos**: Cada MT4 tiene su archivo

### Desventajas

❌ **Latencia adicional**: ~0.5 segundos de delay
❌ **Script adicional**: Más complejidad y punto de fallo
❌ **Sincronización**: Necesita gestionar qué eventos van a cada MT4

### Consideraciones Importantes

#### Problema 1: Distribución de Eventos
- ¿Todos los MT4 reciben todos los eventos?
- ¿O hay lógica de distribución (round-robin, por símbolo, etc.)?

#### Problema 2: Eliminación del CSV Original
- Si se eliminan eventos del CSV, ClonadorMQ5.py también los perderá
- Necesita mantener eventos hasta que todos los consumidores los procesen

#### Problema 3: Sincronización y Resiliencia
- Si el distribuidor falla, los MT4 no reciben eventos
- Necesita monitoreo del distribuidor
- Recuperación ante fallos

### Implementación Sugerida

#### Distribuidor.py (estructura)

```python
import os
import time
from datetime import datetime

CSV_SOURCE = "TradeEvents.csv"
MT4_FILES = [
    "TradeEventsMT4-1.txt",
    "TradeEventsMT4-2.txt",
    "TradeEventsMT4-3.txt"
]
TIMER_SECONDS = 0.5

def distribute_events():
    # Leer TradeEvents.csv
    # Distribuir eventos a cada archivo MT4
    # Gestionar índices para evitar duplicados
    # Opción: Eliminar del CSV original o mantener hasta que todos procesen
    pass
```

#### Flujo del Distribuidor

1. Leer TradeEvents.csv desde última posición procesada
2. Para cada evento nuevo:
   - Escribir en TradeEventsMT4-1.txt
   - Escribir en TradeEventsMT4-2.txt
   - Escribir en TradeEventsMT4-3.txt
3. Actualizar índice de última línea procesada
4. Opción A: Eliminar eventos procesados del CSV original
5. Opción B: Mantener eventos hasta confirmación de todos los consumidores
6. Esperar 0.5 segundos y repetir

### Alternativas Consideradas

#### Opción 4: LectorOrdenes escribe múltiples archivos
- LectorOrdenes modificado para escribir en 4 archivos simultáneamente
- Más simple pero LectorOrdenes hace más trabajo
- Sin latencia adicional

#### Opción 5: Sistema de offsets compartido
- Un solo archivo TradeEvents.csv
- Cada consumidor mantiene su offset
- Más eficiente pero más complejo

### Decisión Pendiente

- [ ] Decidir si todos los MT4 reciben todos los eventos
- [ ] Decidir si eliminar eventos del CSV original o mantenerlos
- [ ] Definir estrategia de distribución (round-robin, por símbolo, etc.)
- [ ] Implementar Distribuidor.py
- [ ] Crear ClonadorMQ4.mq4 basado en ClonadorMQ5.py
- [ ] Testing con múltiples instancias MT4

---

**Estado**: Idea guardada para desarrollo futuro
**Fecha**: 2025-12-17
**Prioridad**: Media (funcionalidad futura)



