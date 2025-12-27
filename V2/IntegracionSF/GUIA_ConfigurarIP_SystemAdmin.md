# Guía: Configurar Login IP Ranges como System Administrator

## Estás en: Users → Tu Usuario (System Administrator)

Ahora necesitas encontrar dónde configurar las IPs permitidas.

---

## Opción 1: Buscar en la Página de Tu Usuario

En la página de tu usuario, busca estas secciones o pestañas:

1. **"Login IP Ranges"** (pestaña o sección)
2. **"Network Access"** (pestaña o sección)
3. **"Security"** (pestaña o sección)
4. **"Personal Information"** (pestaña o sección)

**¿Ves alguna de estas opciones en la página de tu usuario?**

---

## Opción 2: Buscar en Quick Find desde Setup

1. Ve a **Setup** (icono de engranaje)
2. En **Quick Find**, busca: **"Login IP Ranges"**
3. O busca: **"IP Ranges"**
4. Debería aparecer una opción para configurar IPs

---

## Opción 3: Desde Profiles

1. Ve a **Setup** → **Users** → **Profiles**
2. O busca en Quick Find: **"Profiles"**
3. Selecciona **"System Administrator"** (tu perfil)
4. Busca sección: **"Login IP Ranges"**
5. Haz clic en **"Edit"**
6. Busca **"Login IP Ranges"** en la lista de opciones
7. Añade la IP de tu VPS o usa `0.0.0.0/0` temporalmente (cualquier IP)

---

## Opción 4: URL Directa para Login IP Ranges

Prueba esta URL después de iniciar sesión:

```
https://trailsignup-beb5322842f86c.my.salesforce.com/00PS0000000LbqY?setupid=NetworkAccess
```

O:

```
https://trailsignup-beb5322842f86c.my.salesforce.com/lightning/setup/NetworkAccess/home
```

---

## Qué Hacer Cuando Encuentres Login IP Ranges

1. Haz clic en **"New"** o **"Add"** o **"Edit"**
2. Añade un nuevo rango de IP:
   - **Start IP Address**: `0.0.0.0`
   - **End IP Address**: `255.255.255.255`
   - O la IP específica de tu VPS si la conoces
3. **Description**: "API Access" o "VPS Access"
4. Haz clic en **"Save"**

**Nota:** `0.0.0.0` a `255.255.255.255` permite cualquier IP (menos seguro pero funciona para pruebas).

---

## Si NO Encuentras Login IP Ranges

Puede ser que:
- Tu org no tenga esa funcionalidad habilitada
- Esté en otra ubicación
- Necesites usar OAuth 2.0 en su lugar

---

## Pregunta

**¿Qué ves en la página de tu usuario?** 
- ¿Hay pestañas arriba?
- ¿Hay secciones en el menú izquierdo?
- ¿Qué opciones aparecen?

Dime qué ves y te guío al lugar correcto.

