# Esperando que Aparezca la App en App Manager

## Situación Normal

Después de crear una External Client App, Salesforce puede tardar **2-10 minutos** en procesarla y mostrarla en App Manager.

---

## Qué Hacer Mientras Esperas

### Opción 1: Esperar y Refrescar

1. **Espera 5-10 minutos**
2. **Refresca la página** de App Manager (F5 o Ctrl+R)
3. Busca tu app por nombre (`API Integration`)

---

### Opción 2: Buscar de Otra Forma

1. Ve a **Setup**
2. En **Quick Find**, busca: **"Connected Apps"**
3. O busca: **"External Client Apps"**
4. Puede aparecer en una lista diferente

---

### Opción 3: Verificar si se Creó Correctamente

1. Ve a **Setup**
2. Busca en Quick Find: **"App Manager"**
3. En la parte superior, verifica los filtros:
   - ¿Está en "All Apps"?
   - Prueba cambiar el filtro a "Connected Apps" o "External Client Apps"
   - O busca por nombre: `API Integration`

---

### Opción 4: Verificar desde Otro Lugar

1. Ve a **Setup** → **Apps** → **App Manager**
2. O busca directamente: **"Connected Apps"** en Quick Find
3. Puede aparecer en una sección diferente

---

## Si Después de 10 Minutos No Aparece

### Verificar que se Guardó Correctamente

1. Intenta crear otra vez la app
2. Verifica que no haya errores al guardar
3. Asegúrate de haber marcado "Enable OAuth Settings"

---

## Alternativa: Usar Username/Password Flow con IP Autorizada

Si OAuth tarda mucho o no funciona, podemos intentar otra cosa:

1. **Contactar al administrador** para que configure Trusted IP Ranges
2. O usar **OAuth Username-Password Flow** que es más simple

---

## Pregunta

¿Cuánto tiempo ha pasado desde que guardaste la External Client App?

- Si han pasado menos de 5 minutos: **Espera un poco más y refresca**
- Si han pasado más de 10 minutos: **Puede haber un problema, verifica que se guardó correctamente**

---

## Mientras Tanto

Puedes:
1. **Esperar 5-10 minutos más**
2. **Refrescar App Manager** (F5)
3. **Buscar "Connected Apps"** en Quick Find como alternativa
4. **Verificar los filtros** en App Manager (puede estar oculta por un filtro)

¿Quieres que esperemos un poco más o prefieres que busquemos otra solución?

