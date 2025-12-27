# Verificar Restricciones de IP en Salesforce

## Problema Actual

- ✅ Credenciales correctas (puedes iniciar sesión)
- ✅ Security Token obtenido (nuevo token)
- ❌ Error de API: "Invalid username, password, security token"
- ⚠️ Probable causa: **IP no autorizada**

---

## Cómo Verificar Restricciones de IP

### Método 1: Desde Tu Perfil de Usuario

1. **Inicia sesión en Salesforce**
2. Haz clic en tu **nombre/avatar** (esquina superior derecha)
3. Selecciona **"My Settings"** o **"Mi configuración"**
4. Busca en el menú izquierdo:
   - **"Personal Information"**
   - **"Login History"**
   - **"Security"**
5. Busca opciones relacionadas con:
   - **"Login IP Ranges"**
   - **"IP Restrictions"**
   - **"Network Access"**

---

### Método 2: Desde Setup → Users

1. Ve a **Setup**
2. Busca en Quick Find: **"Users"**
3. Haz clic en **"Users"**
4. Busca tu usuario en la lista
5. Haz clic en tu nombre de usuario
6. Busca sección: **"Login IP Ranges"** o **"Network Access"**

---

### Método 3: Desde Profile (Perfil)

1. Ve a **Setup** → **Users** → **Profiles**
2. O busca en Quick Find: **"Profiles"**
3. Selecciona tu perfil (ej: "System Administrator", "Standard User")
4. Busca sección: **"Login IP Ranges"**
5. Si está vacío o restringido, ahí está el problema

---

### Método 4: URL Directa

Prueba estas URLs después de iniciar sesión:

**Para ver tu perfil:**
```
https://trailsignup-beb5322842f86c.my.salesforce.com/005
```

**Para ver perfiles:**
```
https://trailsignup-beb5322842f86c.my.salesforce.com/00e
```

---

## Qué Buscar

### Si encuentras "Login IP Ranges":

1. **Si está vacío**: Añade la IP de tu VPS
2. **Si tiene IPs**: Verifica que tu IP esté en la lista
3. **Si dice "No restrictions"**: No es el problema

### Si NO encuentras la opción:

Puede ser que:
- Tu perfil no tenga permisos para ver/modificar IPs
- Necesitas permisos de administrador
- La opción está en otro lugar

---

## Solución Temporal: Obtener IP de tu VPS

Para saber qué IP añadir, ejecuta desde tu VPS:

```bash
# En PowerShell
Invoke-RestMethod -Uri "https://api.ipify.org?format=json"

# O visita en navegador:
# https://api.ipify.org
```

---

## Solución Definitiva: OAuth 2.0

Si no puedes configurar IPs, **OAuth 2.0** es la mejor solución:

- ✅ No requiere Security Token
- ✅ No requiere configurar IPs
- ✅ Más seguro
- ✅ Mejor para producción

**¿Quieres que te ayude a configurar OAuth 2.0?**

---

## Próximos Pasos

1. **Verifica restricciones de IP** usando los métodos arriba
2. **Si encuentras Login IP Ranges**, añade la IP de tu VPS
3. **Si no encuentras nada**, considera OAuth 2.0

