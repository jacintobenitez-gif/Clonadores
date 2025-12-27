# Guía: Cómo Obtener el Security Token de Salesforce

## Método 1: Desde Setup (Ruta Completa)

### Paso a Paso:

1. **Inicia sesión en Salesforce**
   - URL: https://trailsignup-beb5322842f86c.my.salesforce.com
   - Usa tu usuario y contraseña

2. **Abre Setup**
   - Haz clic en el **icono de engranaje** (⚙️) en la esquina superior derecha
   - O ve directamente a: https://trailsignup-beb5322842f86c.my.salesforce.com/lightning/setup/SetupHome/home

3. **Navega a la sección de Personal Information**
   - En el menú izquierdo, busca: **My Personal Information**
   - Si no lo ves, usa el buscador de Setup (Quick Find box) arriba a la izquierda
   - Escribe: "My Personal Information"

4. **Busca Reset Security Token**
   - Dentro de "My Personal Information", busca: **Reset My Security Token**
   - O escribe directamente en Quick Find: "Reset My Security Token"

---

## Método 2: Búsqueda Directa en Setup

1. **Ve a Setup**
   - Icono de engranaje (⚙️) → Setup

2. **Usa Quick Find (buscador)**
   - En la parte superior izquierda hay un cuadro de búsqueda que dice "Quick Find"
   - ⚠️ **NO busques solo "Token"** (aparecen opciones incorrectas como "Token Exchange Handlers")
   - Busca específicamente: **"Reset My Security Token"** (texto completo)
   - O busca: **"My Personal Information"** y luego busca dentro de esa sección

---

## Método 3: URL Directa

Si tienes acceso, puedes intentar ir directamente a:

```
https://trailsignup-beb5322842f86c.my.salesforce.com/_ui/system/security/ResetApiTokenEdit
```

O la versión Lightning:

```
https://trailsignup-beb5322842f86c.my.salesforce.com/lightning/setup/SecurityTokens/home
```

---

## Método 4: Desde Perfil de Usuario

1. **Ve a tu perfil**
   - Haz clic en tu nombre/avatar en la esquina superior derecha
   - Selecciona **"Settings"** o **"Configuración"**

2. **Busca Security Token**
   - En el menú de configuración personal
   - Busca opciones relacionadas con seguridad o tokens

---

## Método 5: Si No Aparece la Opción

### Posibles Razones:

1. **Permisos insuficientes**
   - Tu perfil de usuario puede no tener permisos para resetear tokens
   - Contacta al administrador de Salesforce

2. **Interfaz diferente (Lightning vs Classic)**
   - Si estás en Lightning, prueba cambiar a Classic:
     - Setup → Switch to Salesforce Classic (abajo a la izquierda)
   - En Classic, la ruta es más directa

3. **Sandbox vs Producción**
   - En algunos sandboxes, la opción puede estar en otra ubicación
   - Verifica que estés en el entorno correcto

---

## Método 6: Alternativa - Usar OAuth en lugar de Security Token

Si no puedes obtener el Security Token, puedes usar **OAuth 2.0** con Connected App:

### Ventajas:
- ✅ Más seguro que Security Token
- ✅ No requiere resetear tokens manualmente
- ✅ Mejor para producción

### Desventajas:
- ⚠️ Requiere configuración adicional en Salesforce
- ⚠️ Más complejo de implementar inicialmente

---

## Método 7: Verificar si ya tienes un Token

Si ya recibiste un email con el Security Token anteriormente:

1. **Busca en tu email**
   - Busca emails de "salesforce.com" con asunto "Your Salesforce.com security token"
   - El token puede estar en emails antiguos

2. **El token tiene formato:**
   - 24 caracteres alfanuméricos
   - Ejemplo: `AbCdEfGhIjKlMnOpQrStUvWx`

---

## Método 8: Contactar Administrador

Si ninguna de las opciones anteriores funciona:

1. **Contacta al administrador de Salesforce**
   - Pide que te resetee el Security Token
   - O que te dé permisos para hacerlo tú mismo

2. **El administrador puede:**
   - Resetear tu token desde su panel
   - Enviarte el token por email
   - Configurar OAuth como alternativa

---

## Instrucciones Visuales (Lightning)

1. **Engranaje (⚙️)** → **Setup**
2. En el buscador **Quick Find** (arriba izquierda), escribe: **"token"**
3. Debería aparecer: **"Reset My Security Token"**
4. Haz clic y luego **"Reset Security Token"**
5. Revisa tu email

---

## Instrucciones Visuales (Classic)

1. **Setup** (menú superior)
2. **My Personal Information** (menú izquierdo)
3. **Reset My Security Token**
4. Haz clic en **"Reset Security Token"**
5. Revisa tu email

---

## ¿Qué hacer después de obtener el Token?

1. **Copia el token del email** (24 caracteres)
2. **Añádelo al archivo `.env`**:
   ```
   SALESFORCE_SECURITY_TOKEN=pega_aqui_el_token
   ```
3. **Prueba la conexión**:
   ```bash
   python test_salesforce_connection.py
   ```

---

## Nota Importante

- El Security Token se envía **solo por email**
- No aparece en la interfaz de Salesforce
- Si cambias tu contraseña, el token se invalida y necesitas uno nuevo
- El token es sensible: mantenlo seguro y no lo compartas

---

## Si Nada Funciona

**Alternativa temporal:** Puedes intentar conectarte sin Security Token si tu IP está en la lista de "Trusted IP Ranges" de Salesforce:

1. Ve a Setup → Network Access → Trusted IP Ranges
2. Añade la IP de tu VPS
3. Intenta conectar sin Security Token (dejar vacío en .env)

**Nota:** Esto es menos seguro y no recomendado para producción.

