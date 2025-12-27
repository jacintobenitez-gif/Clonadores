"""
Script wrapper para probar conexión con Salesforce
Ejecuta el script desde V2/ para que encuentre el archivo .env
"""

import sys
from pathlib import Path

# Añadir IntegracionSF al path
sys.path.insert(0, str(Path(__file__).parent / "IntegracionSF"))

# Importar y ejecutar el script de prueba
from test_salesforce_connection import test_connection

if __name__ == "__main__":
    success = test_connection()
    exit(0 if success else 1)

