//+------------------------------------------------------------------+
//| MigrarOpenLogs.mq4                                               |
//| Script para actualizar ticket_worker en open_logs_{AccountNumber}.csv |
//| Busca órdenes abiertas por MagicNumber/Comment y actualiza el archivo |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

input bool InpUseCommonFiles = true;

//+------------------------------------------------------------------+
//| Construye ruta relativa para FILE_COMMON                         |
//+------------------------------------------------------------------+
string CommonRelative(const string filename)
{
   return("V3\\Phoenix\\" + filename);
}

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
{
   string workerId = IntegerToString(AccountNumber());
   string filename = "open_logs_" + workerId + ".csv";
   string relPath = CommonRelative(filename);
   
   Print("=== Migración de open_logs ===");
   Print("Worker ID: ", workerId);
   Print("Archivo relPath: ", relPath);
   Print("AccountNumber: ", AccountNumber());
   
   // Intentar abrir en modo WRITE primero (igual que WriteOpenLogToFile)
   ResetLastError();
   int handle = FileOpen(relPath, FILE_WRITE | FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
   {
      int err = GetLastError();
      Print("ERROR: No se pudo abrir archivo");
      Print("  Ruta intentada: ", relPath);
      Print("  Error code: ", err);
      Print("  Verifica que el archivo existe en: Common\\Files\\", relPath);
      Print("  Verifica que la cuenta es correcta: ", AccountNumber());
      Print("  Ruta completa esperada: Common\\Files\\V3\\Phoenix\\open_logs_", workerId, ".csv");
      return;
   }
   
   // Si el archivo está vacío, cerrar y retornar
   int fileSize = (int)FileSize(handle);
   if(fileSize == 0)
   {
      FileClose(handle);
      Print("Archivo vacío");
      return;
   }
   
   // Leer archivo completo como texto
   string fileContent = "";
   while(!FileIsEnding(handle))
   {
      fileContent += FileReadString(handle) + "\n";
   }
   FileClose(handle);
   
   // Ahora parsear el contenido
   string lines[];
   int linesCount = 0;
   bool updated = false;
   
   int startPos = 0;
   while(startPos < StringLen(fileContent))
   {
      int lineEnd = StringFind(fileContent, "\n", startPos);
      if(lineEnd < 0) lineEnd = StringFind(fileContent, "\r", startPos);
      if(lineEnd < 0) lineEnd = StringLen(fileContent);
      
      string line = StringSubstr(fileContent, startPos, lineEnd - startPos);
      line = Trim(line);
      
      if(StringLen(line) > 0)
      {
         // Parsear: ticket_maestro;ticket_worker;timestamp;symbol;magic
         string parts[];
         int count = StringSplit(line, ';', parts);
         
         if(count >= 2)
         {
            string ticketMaestro = parts[0];
            string ticketWorkerStr = parts[1];
            int ticketWorker = (int)StrToInteger(ticketWorkerStr);
            
            // Si ticket_worker es 0, buscar orden abierta
            if(ticketWorker == 0)
            {
               Print("\n--- Procesando ticket maestro: ", ticketMaestro, " ---");
               int foundTicket = FindOpenOrderByMagicOrComment(ticketMaestro);
               if(foundTicket >= 0)
               {
                  // Actualizar línea
                  string timestamp = (count >= 3 ? parts[2] : "");
                  string symbol = (count >= 4 ? parts[3] : "");
                  string magic = (count >= 5 ? parts[4] : ticketMaestro);
                  
                  line = ticketMaestro + ";" + IntegerToString(foundTicket) + ";" + timestamp + ";" + symbol + ";" + magic;
                  Print("  [ACTUALIZADO] Ticket maestro ", ticketMaestro, " -> Worker ticket ", foundTicket);
                  updated = true;
               }
               else
               {
                  Print("  [NO ENCONTRADO] Ticket maestro ", ticketMaestro, " - orden no encontrada (puede estar cerrada)");
               }
            }
            else
            {
               Print("  [YA ACTUALIZADO] Ticket maestro ", ticketMaestro, " ya tiene ticket_worker=", ticketWorker);
            }
            
            ArrayResize(lines, linesCount + 1);
            lines[linesCount] = line;
            linesCount++;
         }
         else
         {
            // Línea inválida, mantenerla
            ArrayResize(lines, linesCount + 1);
            lines[linesCount] = line;
            linesCount++;
         }
      }
      
      startPos = lineEnd + 1;
      if(startPos >= StringLen(fileContent)) break;
   }
   
   // Reescribir archivo si hubo actualizaciones
   if(updated)
   {
      handle = FileOpen(relPath, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_WRITE);
      if(handle == INVALID_HANDLE)
      {
         Print("ERROR: No se pudo reescribir archivo");
         return;
      }
      
      for(int i = 0; i < linesCount; i++)
      {
         FileWrite(handle, lines[i]);
      }
      
      FileClose(handle);
      Print("[OK] Archivo actualizado: ", relPath);
   }
   else
   {
      Print("[INFO] No se encontraron entradas para actualizar");
   }
   
   Print("=== Migración completada ===");
}

//+------------------------------------------------------------------+
//| Busca orden abierta por MagicNumber o Comment                    |
//+------------------------------------------------------------------+
int FindOpenOrderByMagicOrComment(string ticketMaestro)
{
   int ticketOrigen = (int)StrToInteger(ticketMaestro);
   int totalOrders = OrdersTotal();
   
   Print("  Buscando orden para ticket maestro: ", ticketMaestro, " (magic=", ticketOrigen, ")");
   Print("  Total órdenes abiertas: ", totalOrders);
   
   // Paso 1: Buscar por MagicNumber
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      
      int orderMagic = OrderMagicNumber();
      int orderTicket = OrderTicket();
      string orderComment = OrderComment();
      
      Print("    Orden ", i, ": ticket=", orderTicket, " magic=", orderMagic, " comment='", orderComment, "'");
      
      if(orderMagic == ticketOrigen)
      {
         Print("    [ENCONTRADO] Por MagicNumber: ticket=", orderTicket);
         return orderTicket;
      }
   }
   
   // Paso 2: Buscar por Comment
   string ticketNormalized = Trim(ticketMaestro);
   Print("  Buscando por Comment: '", ticketNormalized, "'");
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      
      string orderComment = OrderComment();
      orderComment = Trim(orderComment);
      
      if(orderComment == ticketNormalized)
      {
         Print("    [ENCONTRADO] Por Comment: ticket=", OrderTicket());
         return OrderTicket();
      }
   }
   
   Print("  [NO ENCONTRADO] Orden no encontrada");
   return(-1);
}

//+------------------------------------------------------------------+
//| Funciones auxiliares (copiadas de Worker.mq4)                   |
//+------------------------------------------------------------------+
string Trim(string str)
{
   int len = StringLen(str);
   int start = 0;
   int end = len - 1;
   
   while(start < len && (str[start] == ' ' || str[start] == '\t' || str[start] == '\r' || str[start] == '\n'))
      start++;
   
   while(end >= start && (str[end] == ' ' || str[end] == '\t' || str[end] == '\r' || str[end] == '\n'))
      end--;
   
   if(start > end)
      return("");
   
   return(StringSubstr(str, start, end - start + 1));
}

string UTF8BytesToString(uchar &bytes[], int startPos = 0, int length = -1)
{
   string result = "";
   int size = ArraySize(bytes);
   if(startPos >= size) return("");
   
   int endPos = (length < 0) ? size : MathMin(startPos + length, size);
   int pos = startPos;
   
   while(pos < endPos)
   {
      uchar b = bytes[pos];
      if(b == 0) break;
      
      if(b < 0x80)
      {
         result += ShortToString((ushort)b);
         pos++;
      }
      else if((b & 0xE0) == 0xC0 && pos + 1 < endPos)
      {
         uchar b2 = bytes[pos+1];
         if((b2 & 0xC0) == 0x80)
         {
            ushort code = ((ushort)(b & 0x1F) << 6) | (b2 & 0x3F);
            result += ShortToString(code);
            pos += 2;
         }
         else
         {
            result += ShortToString((ushort)b);
            pos++;
         }
      }
      else if((b & 0xF0) == 0xE0 && pos + 2 < endPos)
      {
         uchar b2 = bytes[pos+1];
         uchar b3 = bytes[pos+2];
         if((b2 & 0xC0) == 0x80 && (b3 & 0xC0) == 0x80)
         {
            ushort code = ((ushort)(b & 0x0F) << 12) | ((ushort)(b2 & 0x3F) << 6) | (b3 & 0x3F);
            result += ShortToString(code);
            pos += 3;
         }
         else
         {
            result += ShortToString((ushort)b);
            pos++;
         }
      }
      else
      {
         result += ShortToString((ushort)b);
         pos++;
      }
   }
   
   return(result);
}

void StringToUTF8Bytes(string str, uchar &bytes[])
{
   ArrayResize(bytes, 0);
   int len = StringLen(str);
   
   for(int i = 0; i < len; i++)
   {
      ushort code = StringGetCharacter(str, i);
      
      if(code < 0x80)
      {
         int size = ArraySize(bytes);
         ArrayResize(bytes, size + 1);
         bytes[size] = (uchar)code;
      }
      else if(code < 0x800)
      {
         int size = ArraySize(bytes);
         ArrayResize(bytes, size + 2);
         bytes[size] = (uchar)(0xC0 | (code >> 6));
         bytes[size + 1] = (uchar)(0x80 | (code & 0x3F));
      }
      else
      {
         int size = ArraySize(bytes);
         ArrayResize(bytes, size + 3);
         bytes[size] = (uchar)(0xE0 | (code >> 12));
         bytes[size + 1] = (uchar)(0x80 | ((code >> 6) & 0x3F));
         bytes[size + 2] = (uchar)(0x80 | (code & 0x3F));
      }
   }
}
//+------------------------------------------------------------------+

