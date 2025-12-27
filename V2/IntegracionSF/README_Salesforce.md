# Configuración de Integración con Salesforce

## Pasos para Configurar

### 1. Instalar Dependencias

```bash
pip install simple-salesforce python-dotenv
```

### 2. Configurar Credenciales

**Opción A: Usar script interactivo (Recomendado)**

```bash
python setup_salesforce_env.py
```

El script te pedirá:
- Usuario de Salesforce
- Contraseña
- Security Token
- Domain (test/login)

**Opción B: Crear archivo .env manualmente**

1. Copia el contenido de `env_template.txt`
2. Crea un archivo llamado `.env` en la carpeta `V2`
3. Completa con tus credenciales reales

Ejemplo de `.env`:
```
SALESFORCE_USERNAME=jacinto.benitez+00dj6000001hg1i@salesforce.com
SALESFORCE_PASSWORD=Jacinto1974
SALESFORCE_SECURITY_TOKEN=tu_token_aqui
SALESFORCE_DOMAIN=test
```

### 3. Obtener Security Token

1. Inicia sesión en Salesforce: https://trailsignup-beb5322842f86c.my.salesforce.com
2. Ve a: **Setup** → **My Personal Information** → **Reset My Security Token**
3. Haz clic en **Reset Security Token**
4. Revisa tu email (el token se envía por correo)
5. Copia el token (típicamente 24 caracteres)
6. Añádelo al archivo `.env`

### 4. Probar Conexión

```bash
python test_salesforce_connection.py
```

Si todo está correcto, verás:
```
✅ ¡Conexión exitosa!
Usuario conectado: [Tu nombre]
```

Si hay errores, el script te indicará qué revisar.

### 5. Verificar que .env está protegido

El archivo `.env` está en `.gitignore` y NO se subirá a Git. Verifica:

```bash
git status
```

No debería aparecer `.env` en la lista de archivos nuevos.

---

## Estructura de Archivos

```
V2/
├── .env                    ← Tus credenciales (NO se sube a Git)
├── env_template.txt        ← Plantilla de ejemplo
├── setup_salesforce_env.py ← Script para crear .env
├── test_salesforce_connection.py ← Script de prueba
└── .gitignore              ← Protege archivos sensibles
```

---

## Seguridad

⚠️ **IMPORTANTE:**
- ✅ El archivo `.env` está en `.gitignore`
- ✅ NO hardcodees credenciales en el código
- ✅ NO compartas el archivo `.env`
- ✅ Mantén el Security Token seguro
- ✅ Si comprometes credenciales, resetea el Security Token inmediatamente

---

## Troubleshooting

### Error: "Invalid login"
- Verifica usuario y contraseña en `.env`
- Verifica que el Security Token sea correcto
- Obtén un nuevo Security Token si es necesario

### Error: "Domain incorrecto"
- Para sandbox: usa `SALESFORCE_DOMAIN=test`
- Para producción: usa `SALESFORCE_DOMAIN=login`
- Para custom domains: prueba con `test` primero

### Error: "IP no autorizada"
- Ve a Setup → Network Access → Trusted IP Ranges
- Añade la IP de tu VPS a la lista de IPs confiables
- O desactiva la restricción de IP (menos seguro)

---

## Próximos Pasos

Una vez que la conexión funcione:
1. Crear objetos en Salesforce (`Evento_Master__c`, `Clonacion_Worker__c`)
2. Implementar el servicio de sincronización
3. Probar con datos reales

