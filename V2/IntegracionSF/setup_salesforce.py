"""
Script wrapper para configurar credenciales de Salesforce
Ejecuta el script desde V2/ para que cree el archivo .env en el lugar correcto
Ejemplo: python IntegracionSF/setup_salesforce.py
"""

import sys
from pathlib import Path

# El script está ahora en IntegracionSF, importar directamente
# setup_salesforce_env.py ya crea .env en el directorio padre (V2)
from setup_salesforce_env import setup_env_file

if __name__ == "__main__":
    setup_env_file()

