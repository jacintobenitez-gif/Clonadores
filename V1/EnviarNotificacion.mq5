//+------------------------------------------------------------------+
//|                                          EnviarNotificacion.mq5 |
//|                        EA para enviar notificaciones push        |
//|                        desde Python escribiendo en archivo       |
//+------------------------------------------------------------------+
#property copyright "ClonadorMQ5"
#property version   "1.00"
#property description "EA para enviar notificaciones push desde Python"
#property description "Lee NotificationQueue.txt y envía notificaciones usando SendNotification()"

input string InpNotificationFile = "NotificationQueue.txt";  // Archivo de cola de notificaciones
input int    InpTimerSeconds = 1;                            // Intervalo de verificación (segundos)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Configurar timer para verificar el archivo periódicamente
   if(EventSetTimer(InpTimerSeconds))
   {
      Print("EnviarNotificacion: EA iniciado. Timer configurado para verificar cada ", InpTimerSeconds, " segundos");
      Print("EnviarNotificacion: Buscando archivo: Common\\Files\\", InpNotificationFile);
   }
   else
   {
      Print("EnviarNotificacion: ERROR - No se pudo configurar el timer. Error: ", GetLastError());
      return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("EnviarNotificacion: EA detenido");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // No se usa OnTick, usamos OnTimer
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   static int cycleCount = 0;
   cycleCount++;
   
   // Log cada 10 ciclos para confirmar que el timer funciona (cada 10 segundos si timer=1)
   if(cycleCount % 10 == 0)
   {
      Print("EnviarNotificacion: Timer activo - Ciclo #", cycleCount, " - Verificando archivo...");
   }
   
   // Usar solo el nombre del archivo con FILE_COMMON (equivalente a Common\Files\)
   string filePath = InpNotificationFile;
   
   // Leer el archivo en modo binario (Python lo escribe en modo binario)
   ResetLastError();
   int handle = FileOpen(filePath, FILE_READ | FILE_BIN | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   
   if(handle == INVALID_HANDLE)
   {
      int error = GetLastError();
      // Mostrar el error cada 10 ciclos para debug
      if(cycleCount % 10 == 0)
      {
         string commonPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH);
         Print("EnviarNotificacion: No se pudo abrir archivo: ", filePath);
         Print("  Ruta esperada: ", commonPath, "\\MQL5\\Files\\", InpNotificationFile);
         Print("  Error: ", error, " (5004 = FILE_NOT_FOUND)");
      }
      return;
   }
   
   Print("EnviarNotificacion: Archivo encontrado y abierto correctamente");
   
   // Leer el tamaño del archivo
   ulong fileSize = FileSize(handle);
   Print("EnviarNotificacion: Tamaño del archivo: ", fileSize, " bytes");
   
   if(fileSize == 0)
   {
      FileClose(handle);
      Print("EnviarNotificacion: Archivo vacío");
      return;
   }
   
   // Leer todo el contenido del archivo como UTF-8
   uchar buffer[];
   ArrayResize(buffer, (int)fileSize);
   uint bytesRead = FileReadArray(handle, buffer, 0, (int)fileSize);
   FileClose(handle);
   
   Print("EnviarNotificacion: Bytes leídos: ", bytesRead);
   
   // Convertir bytes UTF-8 a string
   string message = "";
   for(int i = 0; i < (int)bytesRead; i++)
   {
      message += CharToString((char)buffer[i]);
   }
   
   // Limpiar caracteres de control al final
   StringTrimRight(message);
   
   Print("EnviarNotificacion: Archivo leído. Longitud del mensaje: ", StringLen(message));
   
   if(StringLen(message) == 0)
   {
      // Archivo vacío, no hay nada que enviar
      Print("EnviarNotificacion: Archivo vacío o sin contenido válido");
      return;
   }
   
   Print("EnviarNotificacion: Mensaje encontrado: ", message);
   
   // Verificar que las notificaciones estén habilitadas
   if(!TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
   {
      Print("EnviarNotificacion: Las notificaciones no están habilitadas en el terminal");
      // Limpiar el archivo aunque falle
      handle = FileOpen(filePath, FILE_WRITE | FILE_BIN | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(handle != INVALID_HANDLE)
      {
         FileWriteString(handle, "");
         FileClose(handle);
      }
      return;
   }
   
   // Enviar la notificación
   ResetLastError();
   bool result = SendNotification(message);
   
   if(result)
   {
      Print("EnviarNotificacion: Notificación enviada exitosamente: ", message);
      
      // Limpiar el archivo después de enviar
      handle = FileOpen(filePath, FILE_WRITE | FILE_BIN | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(handle != INVALID_HANDLE)
      {
         FileWriteString(handle, "");  // Escribir cadena vacía para limpiar
         FileClose(handle);
      }
   }
   else
   {
      int error = GetLastError();
      Print("EnviarNotificacion: Error al enviar notificación. Error: ", error);
      // No limpiar el archivo si falló, para reintentar en el siguiente ciclo
   }
}

//+------------------------------------------------------------------+

