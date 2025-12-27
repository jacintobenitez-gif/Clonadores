# Solución: No Encuentras Network Access

## Situación
- ✅ Puedes iniciar sesión en Salesforce (credenciales OK)
- ❌ No encuentras "Network Access" en Setup
- ⚠️ Error de autenticación con API

---

## Alternativas para Configurar Trusted IP Ranges

### Opción 1: Buscar "IP" en Quick Find

1. En **Setup**, usa **Quick Find**
2. Busca: **"IP"** o **"IP Ranges"** o **"Trusted IP"**
3. Debería aparecer algo como:
   - "Network Access"
   - "Trusted IP Ranges"
   - "Login IP Ranges"

---

### Opción 2: Buscar "Login" o "Security"

1. En **Quick Find**, busca: **"Login"**
2. O busca: **"Security"**
3. Busca opciones relacionadas con:
   - Login IP Ranges
   - Network Access
   - Security Settings

---

### Opción 3: Desde Profile (Perfil de Usuario)

1. Ve a **Setup** → **Users** → **Profiles**
2. O busca en Quick Find: **"Profiles"**
3. Selecciona tu perfil de usuario
4. Busca sección: **"Login IP Ranges"** o **"Network Access"**
5. Puedes configurar IPs permitidas desde ahí

---

### Opción 4: URL Directa para Network Access

Prueba estas URLs después de iniciar sesión:

```
https://trailsignup-beb5322842f86c.my.salesforce.com/0PS?setupid=NetworkAccess
```

O:

```
https://trailsignup-beb5322842f86c.my.salesforce.com/lightning/setup/NetworkAccess/home
```

---

## Alternativa: Verificar Security Token

Si no puedes configurar IPs, el problema puede ser el Security Token.

### Verificar si el Token es Correcto

El Security Token que tienes: `bYUGqGk6Y5hL7tbnZUEXCRpgo`

**Características de un Security Token válido:**
- 24 caracteres alfanuméricos
- Sin espacios
- Mezcla de letras y números

Tu token parece tener el formato correcto.

### Posibles Problemas:

1. **Token expirado**: Si cambiaste la contraseña, el token anterior se invalida
2. **Token incorrecto**: Puede que no sea el token correcto para tu usuario
3. **Token de otro entorno**: Puede ser de sandbox cuando necesitas producción o viceversa

---

## Solución: Probar Sin Security Token (Si IP está Autorizada)

Si tu IP ya está autorizada, puedes probar sin Security Token:

### Actualizar .env para probar sin token:

```env
SALESFORCE_USERNAME=jacinto.benitez+00dj6000001hg1i@salesforce.com
SALESFORCE_PASSWORD=Jacinto1974
SALESFORCE_SECURITY_TOKEN=
SALESFORCE_DOMAIN=login
```

O comenta la línea:
```env
# SALESFORCE_SECURITY_TOKEN=
```

---

## Solución Definitiva: OAuth 2.0

Si no puedes configurar IPs ni obtener un Security Token válido, la mejor solución es **OAuth 2.0**:

### Ventajas:
- ✅ No requiere Security Token
- ✅ No requiere configurar IPs (usa OAuth flow)
- ✅ Más seguro
- ✅ Mejor para producción

### Requiere:
1. Crear una **Connected App** en Salesforce
2. Configurar **OAuth 2.0**
3. Usar **Client ID** y **Client Secret**

**¿Quieres que te ayude a configurar OAuth 2.0?**

---

## Próximos Pasos Recomendados

1. **Buscar "IP" o "Login" en Quick Find** → Ver si aparece Network Access
2. **Probar sin Security Token** → Si tu IP ya está autorizada
3. **Obtener nuevo Security Token** → Usando las URLs directas
4. **Configurar OAuth 2.0** → Solución más robusta

---

## Pregunta Importante

¿Qué tipo de entorno de Salesforce es?
- **Sandbox** (test/trial)
- **Producción** (org real)

Esto puede afectar dónde encontrar las opciones de configuración.

