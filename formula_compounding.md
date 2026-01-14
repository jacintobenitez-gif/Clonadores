# FÓRMULA DEL SISTEMA DE COMPOUNDING POR BLOQUES

## Fórmula Exacta (Iterativa)

El sistema funciona de forma iterativa día a día:

```
Para cada día t:
  1. blocks(t) = floor(capital(t) / 1000)
     Si blocks(t) < 1 → blocks(t) = 1
  
  2. lote(t) = blocks(t) * 0.01
  
  3. ganancia_dia(t) = blocks(t) * 80
  
  4. capital(t+1) = capital(t) + ganancia_dia(t)
```

**Condiciones iniciales:**
- capital(0) = capital_inicial
- t = 0, 1, 2, ..., T (días)

---

## Fórmula Aproximada (Exponencial Continua)

Si aproximamos `floor(capital/1000)` como `capital/1000` (sin el redondeo hacia abajo):

```
blocks(t) ≈ capital(t) / 1000
ganancia_dia(t) ≈ (capital(t) / 1000) * 80 = capital(t) * 0.08

Por lo tanto:
capital(t+1) ≈ capital(t) * (1 + 0.08) = capital(t) * 1.08
```

**Solución exponencial:**
```
capital(t) ≈ capital(0) * (1.08)^t
```

Donde:
- `capital(0)` = capital inicial
- `t` = número de días
- `1.08` = factor de crecimiento diario (8% por día)

---

## Ejemplo de Cálculo

### Con capital inicial = 2,000€

**Fórmula exacta (iterativa):**
```
Día 0: capital(0) = 2,000
       blocks(0) = floor(2000/1000) = 2
       ganancia_dia(0) = 2 * 80 = 160
       
Día 1: capital(1) = 2,000 + 160 = 2,160
       blocks(1) = floor(2160/1000) = 2
       ganancia_dia(1) = 2 * 80 = 160
       
Día 2: capital(2) = 2,160 + 160 = 2,320
       ...
```

**Fórmula aproximada (exponencial):**
```
capital(84) ≈ 2,000 * (1.08)^84
            ≈ 2,000 * 499.12
            ≈ 998,240€
```

---

## Tasa de Crecimiento

La tasa de crecimiento diaria es aproximadamente **8%** cuando el capital es múltiplo de 1000€.

Sin embargo, como los bloques se calculan con `floor()`, la tasa efectiva varía ligeramente:
- Cuando capital está justo en un múltiplo de 1000€: tasa ≈ 8%
- Cuando capital está cerca pero no alcanza el siguiente múltiplo: tasa < 8%
- Cuando capital cruza un nuevo múltiplo de 1000€: tasa aumenta

---

## Fórmula Generalizada

Si quieres generalizar para diferentes parámetros:

```
Parámetros:
- capital_inicial = C₀
- ganancia_por_bloque = G (en €/día)
- tamaño_bloque = B (en €, típicamente 1000)

Fórmula iterativa:
  blocks(t) = floor(capital(t) / B)
  ganancia_dia(t) = blocks(t) * G
  capital(t+1) = capital(t) + ganancia_dia(t)

Fórmula aproximada exponencial:
  tasa_diaria ≈ (G / B)
  capital(t) ≈ C₀ * (1 + G/B)^t
```

**Para tu caso específico:**
- C₀ = 2,000€
- G = 80€/día
- B = 1,000€
- tasa_diaria ≈ 80/1000 = 0.08 = 8%
- capital(84) ≈ 2,000 * (1.08)^84 ≈ 998,240€

---

## Nota Importante

La fórmula exacta usa `floor()` que introduce una pequeña diferencia con la aproximación exponencial continua. La fórmula iterativa es la que usa el código y da resultados exactos.
























