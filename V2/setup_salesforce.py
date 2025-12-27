"""
Script wrapper para configurar credenciales de Salesforce
Ejecuta el script desde V2/ para que cree el archivo .env en el lugar correcto
"""

import sys
from pathlib import Path

# Añadir IntegracionSF al path
sys.path.insert(0, str(Path(__file__).parent / "IntegracionSF"))

# Importar y ejecutar el script de setup
from setup_salesforce_env import setup_env_file

if __name__ == "__main__":
    setup_env_file()

