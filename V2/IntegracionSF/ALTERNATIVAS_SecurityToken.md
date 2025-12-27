# Alternativas: No Encuentras Reset Security Token

## Situación Actual

- ❌ "Token" en Quick Find → Opciones incorrectas
- ❌ "My Personal Information" → No matching items found
- ⚠️ Probablemente falta de permisos o configuración

---

## Solución 1: URLs Directas (Probar Primero)

Después de iniciar sesión, copia y pega estas URLs en tu navegador:

### URL 1: Versión Classic
```
https://trailsignup-beb5322842f86c.my.salesforce.com/_ui/system/security/ResetApiTokenEdit
```

### URL 2: Versión Lightning
```
https://trailsignup-beb5322842f86c.my.salesforce.com/lightning/setup/SecurityTokens/home
```

### URL 3: Personal Information
```
https://trailsignup-beb5322842f86c.my.salesforce.com/00D?setupid=PersonalInfo
```

### URL 4: Alternative Path
```
https://trailsignup-beb5322842f86c.my.salesforce.com/_ui/system/security/ResetApiTokenEdit?setupid=PersonalInfo
```

**Si alguna de estas URLs funciona**, podrás resetear el token directamente.

---

## Solución 2: Verificar Email Antiguo

Es posible que ya tengas un Security Token en un email anterior:

1. **Busca en tu email** con estos términos:
   - De: `noreply@salesforce.com` o `salesforce.com`
   - Asunto: `security token` o `Your Salesforce.com security token`
   - Busca emails de los últimos meses

2. **El token tiene formato:**
   - 24 caracteres alfanuméricos
   - Ejemplo: `AbCdEf123456GhIjKl789012`

3. **Si encuentras un token:**
   - Puedes probarlo directamente en el archivo `.env`
   - Si no funciona (porque cambiaste contraseña), necesitas uno nuevo

---

## Solución 3: Contactar Administrador

Si no tienes acceso, el administrador puede hacerlo:

### Lo que el administrador necesita hacer:

1. **Setup** → **Users** → Buscar tu usuario
2. O ir a: `https://trailsignup-beb5322842f86c.my.salesforce.com/005`
3. Buscar tu usuario en la lista
4. En tu perfil de usuario, buscar **"Reset Security Token"**
5. El token se enviará a tu email

### Mensaje para el administrador:

```
Hola,

Necesito que me resetees el Security Token de Salesforce para poder 
configurar una integración API.

Usuario: jacinto.benitez+00dj6000001hg1i@salesforce.com

El token se enviará automáticamente a mi email después de resetearlo.

Gracias.
```

---

## Solución 4: Usar OAuth 2.0 (Sin Security Token)

Si no puedes obtener el Security Token, puedes usar **OAuth 2.0** que es más seguro:

### Ventajas:
- ✅ No requiere Security Token
- ✅ Más seguro
- ✅ Mejor para producción
- ✅ No expira con cambio de contraseña

### Requiere:
1. Crear una **Connected App** en Salesforce
2. Configurar **OAuth 2.0**
3. Usar **Client ID** y **Client Secret**

**¿Quieres que te ayude a configurar OAuth como alternativa?**

---

## Solución 5: Trusted IP Ranges (Temporal)

Si tu IP está en la lista de IPs confiables, puedes probar sin Security Token:

### Configurar Trusted IP:

1. Ve a **Setup** → **Network Access** → **Trusted IP Ranges**
2. O busca en Quick Find: **"Network Access"**
3. Haz clic en **"New"** o **"Trusted IP Ranges"**
4. Añade la IP de tu VPS:
   - Puedes usar un rango: `0.0.0.0/0` (cualquier IP) - menos seguro
   - O la IP específica de tu VPS - más seguro

### Probar sin Token:

En el archivo `.env`, comenta o deja vacío el Security Token:

```env
SALESFORCE_USERNAME=jacinto.benitez+00dj6000001hg1i@salesforce.com
SALESFORCE_PASSWORD=Jacinto1974
# SALESFORCE_SECURITY_TOKEN=  # Comentado o vacío
SALESFORCE_DOMAIN=test
```

Luego prueba:
```bash
python test_salesforce_connection.py
```

**Nota:** Esto solo funciona si tu IP está en Trusted IP Ranges.

---

## Solución 6: Verificar Tipo de Usuario

### ¿Eres Administrador o Usuario Estándar?

1. Ve a **Setup**
2. Si ves muchas opciones de configuración → Eres administrador
3. Si ves pocas opciones → Eres usuario estándar

**Si eres usuario estándar:**
- Es normal que no veas "Reset My Security Token"
- Necesitas que el administrador lo haga por ti

---

## Recomendación Inmediata

**Prueba en este orden:**

1. ✅ **URLs directas** (Solución 1) - Más rápido
2. ✅ **Buscar email antiguo** (Solución 2) - Puede que ya tengas uno
3. ✅ **Contactar administrador** (Solución 3) - Si no tienes permisos
4. ✅ **Trusted IP Ranges** (Solución 5) - Como alternativa temporal
5. ✅ **OAuth 2.0** (Solución 4) - Solución definitiva y más segura

---

## ¿Qué Prefieres Hacer?

1. **Probar las URLs directas** → Te doy las URLs exactas
2. **Buscar en email** → Te ayudo a identificar el formato del token
3. **Configurar OAuth** → Te guío paso a paso (más trabajo pero mejor solución)
4. **Contactar administrador** → Te doy el mensaje para enviarle

¿Cuál prefieres intentar primero?

