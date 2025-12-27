"""
Script de prueba para verificar conexión con Salesforce
Ejecuta este script después de configurar .env para verificar que todo funciona
"""

import os
from pathlib import Path
from dotenv import load_dotenv

def test_connection():
    """Prueba la conexión con Salesforce"""
    
    # Cargar variables de entorno
    # Buscar .env en el directorio actual o en el directorio padre (V2)
    env_file = Path(".env")
    if not env_file.exists():
        # Intentar en el directorio padre (V2)
        env_file = Path("..") / ".env"
    if not env_file.exists():
        print("ERROR: Archivo .env no encontrado")
        print("   El archivo .env debe estar en la carpeta V2")
        print("   Ejecuta: python IntegracionSF/setup_salesforce_env.py")
        return False
    
    load_dotenv()
    
    # Verificar que las variables esenciales estén configuradas
    username = os.getenv('SALESFORCE_USERNAME')
    password = os.getenv('SALESFORCE_PASSWORD')
    security_token = os.getenv('SALESFORCE_SECURITY_TOKEN', '')  # Opcional si IP está autorizada
    domain = os.getenv('SALESFORCE_DOMAIN', 'login')
    
    if not all([username, password]):
        print("ERROR: Faltan credenciales en .env")
        print("   Verifica que username y password esten configurados")
        return False
    
    # Security Token es opcional si IP está en Trusted IP Ranges
    if not security_token or not security_token.strip():
        print("ADVERTENCIA: Security Token vacio")
        print("   Requiere que tu IP este en Trusted IP Ranges de Salesforce")
        print()
    
    print("=" * 60)
    print("Probando conexión con Salesforce...")
    print("=" * 60)
    print()
    print(f"Usuario: {username}")
    print(f"Domain: {domain}")
    print()
    
    try:
        from simple_salesforce import Salesforce
        
        print("Conectando...")
        # Construir parámetros de conexión
        sf_params = {
            'username': username,
            'password': password,
            'domain': domain
        }
        
        # Solo añadir security_token si no está vacío
        if security_token and security_token.strip():
            sf_params['security_token'] = security_token
        
        sf = Salesforce(**sf_params)
        
        # Probar una consulta simple
        print("Realizando consulta de prueba...")
        result = sf.query("SELECT Id, Name FROM User LIMIT 1")
        
        if result['records']:
            user = result['records'][0]
            print()
            print("=" * 60)
            print("OK: Conexion exitosa!")
            print("=" * 60)
            print()
            print(f"Usuario conectado: {user.get('Name', 'N/A')}")
            print(f"User ID: {user.get('Id', 'N/A')}")
            print()
            print("Todo esta configurado correctamente!")
            print("   Puedes proceder a implementar el servicio de sincronización")
            return True
        else:
            print("ADVERTENCIA: Conexion OK pero no se obtuvieron resultados")
            return True
            
    except ImportError:
        print("ERROR: Libreria simple-salesforce no instalada")
        print("   Instala con: pip install simple-salesforce python-dotenv")
        return False
        
    except Exception as e:
        print()
        print("=" * 60)
        print("ERROR: Error de conexion")
        print("=" * 60)
        print()
        print(f"Error: {str(e)}")
        print()
        print("Posibles causas:")
        print("  1. Credenciales incorrectas")
        print("  2. Security Token incorrecto o expirado")
        print("  3. Domain incorrecto (test vs login)")
        print("  4. Problemas de conectividad de red")
        print("  5. IP bloqueada en Salesforce (verificar Trusted IPs)")
        print()
        print("Solución:")
        print("  1. Verifica las credenciales en .env")
        print("  2. Obtén un nuevo Security Token desde Salesforce")
        print("     Setup > My Personal Information > Reset My Security Token")
        print("  3. Verifica que el domain sea correcto:")
        print("     - 'test' para sandbox")
        print("     - 'login' para producción")
        return False

if __name__ == "__main__":
    success = test_connection()
    exit(0 if success else 1)

