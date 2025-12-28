"""
Script wrapper para probar conexión con Salesforce
Ejecuta el script desde V2/ para que encuentre el archivo .env
Ejemplo: python IntegracionSF/test_salesforce.py
"""

import sys
from pathlib import Path

# El script está ahora en IntegracionSF, importar directamente
# test_salesforce_connection.py ya busca .env en el directorio padre (V2)
from test_salesforce_connection import test_connection

if __name__ == "__main__":
    success = test_connection()
    exit(0 if success else 1)

