"""
Script de ayuda para configurar el archivo .env de Salesforce
Ejecuta este script para crear el archivo .env de forma interactiva
"""

import os
from pathlib import Path

def setup_env_file():
    """Crea archivo .env de forma interactiva"""
    # Crear .env en el directorio padre (V2) donde debe estar
    env_file = Path("..") / ".env"
    example_file = Path("env_template.txt")
    
    if env_file.exists():
        respuesta = input("El archivo .env ya existe. ¿Sobrescribirlo? (s/N): ")
        if respuesta.lower() != 's':
            print("Operación cancelada.")
            return
    
    print("=" * 60)
    print("Configuración de Credenciales de Salesforce")
    print("=" * 60)
    print()
    print("Necesitarás:")
    print("1. Usuario de Salesforce (email)")
    print("2. Contraseña de Salesforce")
    print("3. Security Token (obtener desde Setup > Reset My Security Token)")
    print()
    
    # Solicitar credenciales
    username = input("Usuario de Salesforce (email): ").strip()
    password = input("Contraseña de Salesforce: ").strip()
    security_token = input("Security Token (24 caracteres, del email): ").strip()
    
    print()
    print("Domain:")
    print("  - 'test' para sandbox")
    print("  - 'login' para producción")
    print("  - Dejar vacío para auto-detección")
    domain = input("Domain (test/login/vacío): ").strip() or "test"
    
    # Crear contenido del archivo .env
    env_content = f"""# Configuración de Salesforce
# Generado automáticamente - NO subir a Git

SALESFORCE_USERNAME={username}
SALESFORCE_PASSWORD={password}
SALESFORCE_SECURITY_TOKEN={security_token}
SALESFORCE_DOMAIN={domain}
"""
    
    # Escribir archivo
    try:
        with open(env_file, 'w', encoding='utf-8') as f:
            f.write(env_content)
        
        # Establecer permisos restrictivos (solo en Linux/Mac)
        if os.name != 'nt':  # No Windows
            os.chmod(env_file, 0o600)  # Solo lectura/escritura para el propietario
        
        print()
        print("=" * 60)
        print("✅ Archivo .env creado exitosamente!")
        print("=" * 60)
        print()
        print(f"Ubicacion: {env_file.absolute()}")
        print(f"NOTA: El archivo .env esta en V2/ (directorio padre)")
        print()
        print("⚠️  IMPORTANTE:")
        print("   - El archivo .env está en .gitignore")
        print("   - NO se subirá a Git")
        print("   - Mantén este archivo seguro y privado")
        print()
        print("Próximo paso:")
        print("   1. Verifica que el Security Token sea correcto")
        print("   2. Prueba la conexión con: python test_salesforce_connection.py")
        
    except Exception as e:
        print(f"❌ Error al crear archivo .env: {e}")

if __name__ == "__main__":
    setup_env_file()

