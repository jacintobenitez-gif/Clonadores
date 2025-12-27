# Pasos: Crear External Client App (Connected App)

## Opción Correcta: "New External Client App"

Haz clic en **"New External Client App"** (NO en "New Lightning App")

---

## Paso 1: Información Básica

Completa estos campos:

### Basic Information:
- **App Name**: `API Integration` (o el nombre que prefieras)
- **API Name**: Se genera automáticamente (puedes dejarlo)
- **Contact Email**: Tu email

---

## Paso 2: Configurar OAuth

Busca la sección **"OAuth Settings"** o **"API (Enable OAuth Settings)"**:

1. ✅ **Marca la casilla**: **"Enable OAuth Settings"** o **"OAuth Enabled"**

2. **Callback URL**: 
   ```
   http://localhost:8080/callback
   ```
   O también puedes usar:
   ```
   https://localhost:8080/callback
   ```

3. **Selected OAuth Scopes**: 
   - Busca la lista de "Available OAuth Scopes" o "Selected OAuth Scopes"
   - Mueve estos scopes a "Selected" (usando las flechas o botones):
     - ✅ **"Full access (full)"**
     - ✅ **"Perform requests on your behalf at any time (refresh_token, offline_access)"**
   
   O busca específicamente:
   - `full`
   - `refresh_token`
   - `offline_access`

4. **Opciones Adicionales** (si aparecen):
   - ✅ **"Require Secret for Web Server Flow"**: Dejar marcado
   - ✅ **"Require Secret for Refresh Token Flow"**: Dejar marcado

---

## Paso 3: Guardar

1. Haz clic en **"Save"**
2. **IMPORTANTE**: Salesforce mostrará un mensaje diciendo que los cambios pueden tardar 2-10 minutos
3. **Espera unos minutos** antes de continuar

---

## Paso 4: Obtener Consumer Key y Consumer Secret

Después de guardar y esperar:

1. Ve a **Setup** → **App Manager**
2. Busca tu app (`API Integration`)
3. Haz clic en la **flecha hacia abajo** (▼) o en los **tres puntos** (...) junto al nombre
4. Selecciona **"View"** o **"Manage"**
5. Busca la sección **"API (Enable OAuth Settings)"** o **"OAuth Settings"**
6. Verás:
   - **Consumer Key** (este es el Client ID)
   - **Consumer Secret** (haz clic en "Click to reveal" o "Show" para verlo)

**Copia ambos valores** - los necesitarás para el archivo `.env`

---

## Paso 5: Actualizar Archivo .env

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

## Notas Importantes

- ⏱️ **Espera 2-10 minutos** después de guardar antes de buscar las credenciales
- 🔒 El **Consumer Secret** solo se muestra una vez - cópialo inmediatamente
- ✅ Con OAuth NO necesitas Security Token
- ✅ Con OAuth NO necesitas configurar IPs

---

## Próximo Paso

Una vez tengas el Consumer Key y Consumer Secret, actualiza el archivo `.env` y te ayudo a modificar el código Python para usar OAuth.

