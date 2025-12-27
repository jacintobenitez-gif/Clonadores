# Integración con Salesforce

Esta carpeta contiene todos los archivos relacionados con la integración de los históricos (`Historico_Master.txt` e `historico_clonacion.txt`) con Salesforce.

---

## Archivos Principales

### Scripts Python

- **`setup_salesforce_env.py`**: Script interactivo para crear el archivo `.env` con credenciales
- **`test_salesforce_connection.py`**: Script para probar la conexión con Salesforce

### Documentación Principal

- **`ANALISIS_IntegracionSalesforce.md`**: Análisis completo de la arquitectura y opciones de integración
- **`README_Salesforce.md`**: Guía paso a paso para configurar credenciales

### Guías de Configuración

- **`GUIA_ResetSecurityToken.md`**: Cómo obtener el Security Token de Salesforce
- **`GUIA_ConfigurarOAuth.md`**: Guía para configurar OAuth 2.0 (recomendado)
- **`PASOS_ExternalClientApp.md`**: Pasos detallados para crear External Client App
- **`ESPERAR_AppManager.md`**: Qué hacer mientras aparece la app en App Manager

### Soluciones a Problemas

- **`SOLUCION_SecurityToken.md`**: Soluciones si no encuentras Reset Security Token
- **`ALTERNATIVAS_SecurityToken.md`**: Alternativas si no puedes obtener Security Token
- **`SOLUCION_NetworkAccess.md`**: Cómo encontrar y configurar Network Access
- **`VERIFICAR_IP_Restrictions.md`**: Cómo verificar restricciones de IP
- **`GUIA_ConfigurarIP_SystemAdmin.md`**: Configurar IPs como System Administrator
- **`RESUMEN_ProblemaConexion.md`**: Resumen de problemas comunes y soluciones

### Plantillas

- **`env_template.txt`**: Plantilla para crear el archivo `.env`
- **`CREAR_ENV.txt`**: Instrucciones para crear el archivo `.env`

---

## Archivo .env (NO está en esta carpeta)

⚠️ **IMPORTANTE**: El archivo `.env` con las credenciales debe estar en la carpeta `V2` (no en `IntegracionSF`) para que los scripts funcionen correctamente.

Ubicación: `V2/.env`

---

## Estructura Recomendada

```
V2/
├── .env                          ← Credenciales (NO mover)
├── IntegracionSF/                ← Esta carpeta
│   ├── README.md                 ← Este archivo
│   ├── setup_salesforce_env.py
│   ├── test_salesforce_connection.py
│   ├── ANALISIS_IntegracionSalesforce.md
│   └── ... (otros archivos de documentación)
├── Distribuidor.py
├── Worker.mq4
├── Worker.mq5
└── ...
```

---

## Próximos Pasos

1. ✅ Configurar OAuth 2.0 en Salesforce (crear External Client App)
2. ✅ Obtener Consumer Key y Consumer Secret
3. ✅ Actualizar archivo `.env` con las credenciales OAuth
4. ✅ Implementar servicio de sincronización Python
5. ✅ Probar con datos reales

---

## Nota

Los scripts Python están en `IntegracionSF/` pero deben ejecutarse desde la carpeta `V2` usando los scripts wrapper:

- **Desde V2**: `python test_salesforce.py` (usa `IntegracionSF/test_salesforce_connection.py`)
- **Desde V2**: `python setup_salesforce.py` (usa `IntegracionSF/setup_salesforce_env.py`)

O directamente:
- **Desde V2**: `python IntegracionSF/test_salesforce_connection.py`
- **Desde V2**: `python IntegracionSF/setup_salesforce_env.py`

El archivo `.env` debe estar en `V2/` (no en `IntegracionSF/`) para que los scripts lo encuentren.

