# Guía: Configurar OAuth 2.0 en Salesforce

## Situación Actual

- ✅ Eres System Administrator
- ✅ Ves la pestaña "OAuth Apps"
- ❌ No encuentras Login IP Ranges
- ✅ OAuth es la mejor solución

---

## Paso 1: Crear Connected App

1. **Ve a Setup** (icono de engranaje)
2. En **Quick Find**, busca: **"App Manager"** o **"Connected Apps"**
3. O ve directamente a: **Setup** → **App Manager** → **New Connected App**

**Si no encuentras App Manager:**
- Busca en Quick Find: **"Connected Apps"**
- O busca: **"Apps"**

---

## Paso 2: Configurar Connected App

Cuando estés en "New Connected App", completa estos campos:

### Información Básica:
- **Connected App Name**: `API Integration` (o el nombre que prefieras)
- **API Name**: Se genera automáticamente (puedes dejarlo)
- **Contact Email**: Tu email

### Configuración de API (Enable OAuth Settings):
- ✅ **Enable OAuth Settings** (marca esta casilla)

### OAuth Settings:
- **Callback URL**: `http://localhost:8080/callback` (o `https://localhost:8080/callback`)
- **Selected OAuth Scopes**: Selecciona:
  - ✅ **Full access (full)**
  - ✅ **Perform requests on your behalf at any time (refresh_token, offline_access)**

### Opciones Adicionales:
- ✅ **Require Secret for Web Server Flow**: Dejar marcado
- ✅ **Require Secret for Refresh Token Flow**: Dejar marcado

### Guardar:
- Haz clic en **"Save"**
- **IMPORTANTE**: Salesforce mostrará un mensaje diciendo que los cambios pueden tardar unos minutos

---

## Paso 3: Obtener Credenciales

Después de guardar:

1. **Espera 2-5 minutos** (los cambios pueden tardar)
2. Ve a **Setup** → **App Manager**
3. Busca tu Connected App (`API Integration`)
4. Haz clic en la **flecha hacia abajo** (▼) junto al nombre
5. Selecciona **"View"** o **"Manage"**
6. Busca la sección **"API (Enable OAuth Settings)"**
7. Verás:
   - **Consumer Key** (Client ID)
   - **Consumer Secret** (Client Secret) - Haz clic en "Click to reveal" para verlo

**Copia ambos valores** - los necesitarás para el archivo `.env`

---

## Paso 4: Actualizar Archivo .env

Una vez tengas el Consumer Key y Consumer Secret, actualiza el archivo `.env`:

```env
SALESFORCE_USERNAME=jacinto.benitez+00dj6000001hg1i@salesforce.com
SALESFORCE_PASSWORD=Jacinto1974
SALESFORCE_CONSUMER_KEY=tu_consumer_key_aqui
SALESFORCE_CONSUMER_SECRET=tu_consumer_secret_aqui
SALESFORCE_DOMAIN=login
# Ya no necesitas Security Token con OAuth
# SALESFORCE_SECURITY_TOKEN=
```

---

## Paso 5: Actualizar Código Python para Usar OAuth

Necesitarás modificar el código para usar OAuth en lugar de username/password.

---

## Ventajas de OAuth 2.0

- ✅ No requiere Security Token
- ✅ No requiere configurar IPs
- ✅ Más seguro
- ✅ Mejor para producción
- ✅ Tokens se renuevan automáticamente

---

## ¿Necesitas Ayuda?

Dime:
1. ¿Encuentras "App Manager" o "Connected Apps" en Setup?
2. ¿Qué ves cuando buscas "Connected" en Quick Find?

Te guío paso a paso desde donde estés.

