//+------------------------------------------------------------------+
//|                                                ClonadorMQ5.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//|   Clonador de órdenes para MetaTrader 5                          |
//|   Lee TradeEvents.csv y clona operaciones OPEN/CLOSE/MODIFY      |
//|   Versión 3: Con soporte múltiple codificaciones                 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "3.00"
#property strict

//--- Inputs
input string InpCSVFileName = "TradeEvents.txt";  // Nombre del TXT en Common\Files
input string InpHistFileName = "TradeEvents_historico.txt";  // Archivo histórico
input int    InpTimerSeconds = 1;                 // Timer en segundos
input int    InpSlippagePoints = 30;              // Slippage en puntos
input bool   InpCuentaFondeo = true;              // Cuenta de fondeo (copia lots)
input double InpFixedLots = 0.10;                 // Lote fijo si NO es fondeo
input double InpLotMultiplier = 1.0;              // Multiplicador de lotaje (1x, 2x, 3x)
input int    InpMagic = 0;                        // Magic number

//+------------------------------------------------------------------+
//| Detectar codificación del archivo                                |
//+------------------------------------------------------------------+
enum ENCODING_TYPE
{
   ENCODING_UTF8,
   ENCODING_UTF8_SIG,
   ENCODING_UTF16_LE,
   ENCODING_UTF16_BE,
   ENCODING_WINDOWS_1252,
   ENCODING_LATIN1,
   ENCODING_CP1252,
   ENCODING_UNKNOWN
};

ENCODING_TYPE DetectEncoding(uchar &bytes[])
{
   int size = ArraySize(bytes);
   if(size < 2) return ENCODING_WINDOWS_1252; // Por defecto
   
   // Detectar UTF-16 BOM (FF FE = LE, FE FF = BE)
   if(size >= 2)
   {
      if(bytes[0] == 0xFF && bytes[1] == 0xFE)
      {
         return ENCODING_UTF16_LE;
      }
      if(bytes[0] == 0xFE && bytes[1] == 0xFF)
      {
         return ENCODING_UTF16_BE;
      }
   }
   
   // Detectar UTF-8 BOM (EF BB BF)
   if(size >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
   {
      return ENCODING_UTF8_SIG;
   }
   
   // Intentar detectar UTF-8 válido (sin BOM)
   bool isValidUTF8 = true;
   for(int i = 0; i < size && i < 1000; i++) // Revisar primeros 1000 bytes
   {
      uchar b = bytes[i];
      if(b < 0x80) continue; // ASCII válido
      
      // Patrón UTF-8: 110xxxxx 10xxxxxx
      if((b & 0xE0) == 0xC0)
      {
         if(i + 1 >= size || (bytes[i+1] & 0xC0) != 0x80)
         {
            isValidUTF8 = false;
            break;
         }
         i++;
      }
      // Patrón UTF-8: 1110xxxx 10xxxxxx 10xxxxxx
      else if((b & 0xF0) == 0xE0)
      {
         if(i + 2 >= size || (bytes[i+1] & 0xC0) != 0x80 || (bytes[i+2] & 0xC0) != 0x80)
         {
            isValidUTF8 = false;
            break;
         }
         i += 2;
      }
      // Patrón UTF-8: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
      else if((b & 0xF8) == 0xF0)
      {
         if(i + 3 >= size || (bytes[i+1] & 0xC0) != 0x80 || 
            (bytes[i+2] & 0xC0) != 0x80 || (bytes[i+3] & 0xC0) != 0x80)
         {
            isValidUTF8 = false;
            break;
         }
         i += 3;
      }
      else if((b & 0xC0) == 0x80)
      {
         // Byte de continuación sin inicio válido
         isValidUTF8 = false;
         break;
      }
      else if(b >= 0x80 && b < 0xA0)
      {
         // Rango no válido en UTF-8 (Windows-1252 típicamente)
         isValidUTF8 = false;
         break;
      }
   }
   
   if(isValidUTF8) return ENCODING_UTF8;
   
   // Por defecto, asumir Windows-1252 (compatible con Latin-1 para ASCII)
   return ENCODING_WINDOWS_1252;
}

//+------------------------------------------------------------------+
//| Convertir UTF-8 a string (UTF-16)                                |
//+------------------------------------------------------------------+
string UTF8ToString(uchar &bytes[], int startPos = 0, int skipBOM = 0)
{
   if(skipBOM > 0 && startPos + skipBOM < ArraySize(bytes))
      startPos += skipBOM;
   
   string result = "";
   int size = ArraySize(bytes);
   
   for(int i = startPos; i < size; i++)
   {
      uchar b = bytes[i];
      
      // ASCII (0x00-0x7F)
      if(b < 0x80)
      {
         if(b == 0) break; // Fin de string
         if(b == 0x0A || b == 0x0D) // Salto de línea
         {
            if(b == 0x0D && i + 1 < size && bytes[i+1] == 0x0A)
               i++; // Saltar \r\n
            break; // Fin de línea
         }
         result += ShortToString(b);
      }
      // UTF-8: 110xxxxx 10xxxxxx (2 bytes)
      else if((b & 0xE0) == 0xC0 && i + 1 < size)
      {
         uchar b2 = bytes[i+1];
         if((b2 & 0xC0) == 0x80)
         {
            int codePoint = ((b & 0x1F) << 6) | (b2 & 0x3F);
            if(codePoint < 0x80) // ASCII válido
            {
               result += ShortToString((ushort)codePoint);
            }
            else
            {
               // Convertir a UTF-16 (simplificado: solo BMP)
               if(codePoint < 0x10000)
               {
                  result += ShortToString((ushort)codePoint);
               }
            }
            i++;
         }
         else
         {
            result += ShortToString((ushort)b); // Carácter inválido, usar byte directo
         }
      }
      // UTF-8: 1110xxxx 10xxxxxx 10xxxxxx (3 bytes)
      else if((b & 0xF0) == 0xE0 && i + 2 < size)
      {
         uchar b2 = bytes[i+1];
         uchar b3 = bytes[i+2];
         if((b2 & 0xC0) == 0x80 && (b3 & 0xC0) == 0x80)
         {
            int codePoint = ((b & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
            if(codePoint < 0x10000)
            {
               result += ShortToString((ushort)codePoint);
            }
            i += 2;
         }
         else
         {
            result += ShortToString((ushort)b);
         }
      }
      else
      {
         // Byte inválido o fuera de rango, usar byte directo
         result += ShortToString(b);
      }
   }
   
   return result;
}

//+------------------------------------------------------------------+
//| Convertir UTF-16 LE a string (MQL5 usa UTF-16 internamente)      |
//+------------------------------------------------------------------+
string UTF16LEToString(uchar &bytes[], int startPos = 0, int skipBOM = 0)
{
   string result = "";
   int size = ArraySize(bytes);
   int pos = startPos + skipBOM;
   
   // UTF-16 LE: cada carácter son 2 bytes (little-endian)
   while(pos + 1 < size)
   {
      // Leer 2 bytes como ushort (little-endian)
      ushort ch = (ushort)(bytes[pos] | (bytes[pos + 1] << 8));
      
      if(ch == 0) break; // Fin de string
      if(ch == 0x0A || ch == 0x0D) break; // Salto de línea
      
      result += ShortToString(ch);
      pos += 2;
   }
   
   return result;
}

//+------------------------------------------------------------------+
//| Convertir UTF-16 BE a string (MQL5 usa UTF-16 internamente)      |
//+------------------------------------------------------------------+
string UTF16BEToString(uchar &bytes[], int startPos = 0, int skipBOM = 0)
{
   string result = "";
   int size = ArraySize(bytes);
   int pos = startPos + skipBOM;
   
   // UTF-16 BE: cada carácter son 2 bytes (big-endian)
   while(pos + 1 < size)
   {
      // Leer 2 bytes como ushort (big-endian)
      ushort ch = (ushort)((bytes[pos] << 8) | bytes[pos + 1]);
      
      if(ch == 0) break; // Fin de string
      if(ch == 0x0A || ch == 0x0D) break; // Salto de línea
      
      result += ShortToString(ch);
      pos += 2;
   }
   
   return result;
}

//+------------------------------------------------------------------+
//| Convierte string Unicode (MQL5) a bytes UTF-8                     |
//+------------------------------------------------------------------+
void StringToUTF8Bytes(string str, uchar &bytes[])
{
   ArrayResize(bytes, 0);
   int len = StringLen(str);
   
   for(int i = 0; i < len; i++)
   {
      ushort ch = StringGetCharacter(str, i);
      
      // ASCII (0x00-0x7F): 1 byte
      if(ch < 0x80)
      {
         int size = ArraySize(bytes);
         ArrayResize(bytes, size + 1);
         bytes[size] = (uchar)ch;
      }
      // 2 bytes UTF-8: 110xxxxx 10xxxxxx (0x80-0x7FF)
      else if(ch < 0x800)
      {
         int size = ArraySize(bytes);
         ArrayResize(bytes, size + 2);
         bytes[size] = (uchar)(0xC0 | (ch >> 6));
         bytes[size + 1] = (uchar)(0x80 | (ch & 0x3F));
      }
      // 3 bytes UTF-8: 1110xxxx 10xxxxxx 10xxxxxx (0x800-0xFFFF)
      else
      {
         int size = ArraySize(bytes);
         ArrayResize(bytes, size + 3);
         bytes[size] = (uchar)(0xE0 | (ch >> 12));
         bytes[size + 1] = (uchar)(0x80 | ((ch >> 6) & 0x3F));
         bytes[size + 2] = (uchar)(0x80 | (ch & 0x3F));
      }
   }
}

//+------------------------------------------------------------------+
//| Convertir Windows-1252/Latin-1 a string                          |
//+------------------------------------------------------------------+
string Windows1252ToString(uchar &bytes[], int startPos = 0)
{
   string result = "";
   int size = ArraySize(bytes);
   
   for(int i = startPos; i < size; i++)
   {
      uchar b = bytes[i];
      
      if(b == 0) break; // Fin de string
      if(b == 0x0A || b == 0x0D) // Salto de línea
      {
         if(b == 0x0D && i + 1 < size && bytes[i+1] == 0x0A)
            i++; // Saltar \r\n
         break; // Fin de línea
      }
      
      // Windows-1252 y Latin-1 son compatibles para 0x00-0xFF
      // MQL5 usa UTF-16, así que mapeamos directamente
      result += ShortToString((ushort)b);
   }
   
   return result;
}

//+------------------------------------------------------------------+
//| Leer archivo con detección automática de codificación            |
//+------------------------------------------------------------------+
bool ReadFileWithEncoding(string filename, string &lines[])
{
   ArrayResize(lines, 0);
   
   // Leer archivo como binario
   int handle = FileOpen(filename, FILE_BIN | FILE_READ | FILE_COMMON | 
                         FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
   {
      int err = GetLastError();
      if(err == 4103) // 4103 = archivo no existe
      {
         PrintFormat("[ERROR LECTURA] El archivo no existe: '%s' (Error=%d)", filename, err);
      }
      else
      {
         PrintFormat("[ERROR LECTURA] No se pudo abrir '%s'. Error=%d", filename, err);
      }
      return false;
   }
   
   // Leer todos los bytes
   uchar bytes[];
   int fileSize = (int)FileSize(handle);
   if(fileSize <= 0)
   {
      FileClose(handle);
      PrintFormat("[ERROR LECTURA] El archivo está vacío: '%s' (tamaño=%d)", filename, fileSize);
      return false;
   }
   
   ArrayResize(bytes, fileSize);
   uint bytesRead = FileReadArray(handle, bytes, 0, fileSize);
   FileClose(handle);
   
   if(bytesRead != fileSize)
   {
      PrintFormat("[ERROR LECTURA] Error al leer archivo '%s': leídos %d de %d bytes", filename, bytesRead, fileSize);
      return false;
   }
   
   // Leer solo UTF-8 (estándar)
   // Verificar BOM UTF-8 si existe
   int bomSkip = 0;
   if(fileSize >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
   {
      bomSkip = 3; // Saltar BOM UTF-8
   }
   
   // Convertir bytes UTF-8 a líneas
   int lineStart = bomSkip;
   while(lineStart < fileSize)
   {
      string line = "";
      
      // Encontrar posición del siguiente salto de línea
      int lineEnd = lineStart;
      bool foundLF = false;
      
      for(int i = lineStart; i < fileSize; i++)
      {
         if(bytes[i] == 0x0A) // LF
         {
            lineEnd = i + 1;
            foundLF = true;
            break;
         }
         if(bytes[i] == 0x0D) // CR
         {
            if(i + 1 < fileSize && bytes[i+1] == 0x0A) // CRLF
               lineEnd = i + 2;
            else
               lineEnd = i + 1;
            foundLF = true;
            break;
         }
         if(bytes[i] == 0) // Null terminator
         {
            lineEnd = i;
            break;
         }
      }
      
      if(!foundLF && lineEnd == lineStart)
         lineEnd = fileSize; // Última línea sin salto
      
      // Convertir línea completa UTF-8
      uchar lineBytes[];
      ArrayResize(lineBytes, lineEnd - lineStart);
      ArrayCopy(lineBytes, bytes, 0, lineStart, lineEnd - lineStart);
      string line = UTF8ToString(lineBytes, 0, 0);
      
      // Limpiar línea (eliminar CR/LF y espacios)
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) > 0)
      {
         int count = ArraySize(lines);
         ArrayResize(lines, count + 1);
         lines[count] = line;
      }
      
      lineStart = lineEnd;
      if(lineStart >= fileSize) break;
   }
   
   int totalLines = ArraySize(lines);
   if(totalLines == 0)
   {
      PrintFormat("[WARNING LECTURA] Archivo '%s' no contiene líneas válidas después del procesamiento", filename);
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Calcular lotes del esclavo                                       |
//+------------------------------------------------------------------+
double ComputeSlaveLots(string symbol, double masterLots)
{
   if(InpCuentaFondeo)
   {
      return masterLots * InpLotMultiplier;
   }
   
   // Usar lote fijo con validación
   double lots = InpFixedLots;
   
   if(!SymbolSelect(symbol, true))
      return lots;
   
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   if(step <= 0) step = minLot;
   
   // Ajustar al step
   lots = MathFloor(lots / step) * step;
   
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   
   // Normalizar decimales
   int lotDigits = 2;
   double tmp = step;
   int d = 0;
   while(tmp < 1.0 && d < 4)
   {
      tmp *= 10.0;
      d++;
   }
   lotDigits = MathMax(2, d);
   
   return NormalizeDouble(lots, lotDigits);
}

//+------------------------------------------------------------------+
//| Buscar posición abierta por comentario (ticket maestro)         |
//+------------------------------------------------------------------+
ulong FindOpenPosition(string symbol, string masterTicket)
{
   if(!PositionSelect(symbol))
      return 0;
   
   string comment = PositionGetString(POSITION_COMMENT);
   StringTrimLeft(comment);
   StringTrimRight(comment);
   if(comment == masterTicket)
   {
      return PositionGetInteger(POSITION_TICKET);
   }
   
   // Buscar en todas las posiciones del símbolo
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) == symbol)
      {
         comment = PositionGetString(POSITION_COMMENT);
         StringTrimLeft(comment);
         StringTrimRight(comment);
         if(comment == masterTicket)
         {
            return ticket;
         }
      }
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Buscar ticket en historial                                       |
//+------------------------------------------------------------------+
bool FindTicketInHistory(string symbol, string masterTicket)
{
   datetime fromDate = TimeCurrent() - 90 * 24 * 3600; // 90 días
   datetime toDate = TimeCurrent();
   
   // Buscar en deals
   if(HistorySelect(fromDate, toDate))
   {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == symbol)
         {
            string comment = HistoryDealGetString(ticket, DEAL_COMMENT);
            if(StringFind(comment, masterTicket) >= 0)
               return true;
         }
      }
   }
   
   // Buscar en órdenes
   if(HistorySelect(fromDate, toDate))
   {
      int total = HistoryOrdersTotal();
      for(int i = 0; i < total; i++)
      {
         ulong ticket = HistoryOrderGetTicket(i);
         if(ticket == 0) continue;
         
         if(HistoryOrderGetString(ticket, ORDER_SYMBOL) == symbol)
         {
            string comment = HistoryOrderGetString(ticket, ORDER_COMMENT);
            if(StringFind(comment, masterTicket) >= 0)
               return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Verificar si ticket existe en abiertas o historial               |
//+------------------------------------------------------------------+
bool TicketExistsAnywhere(string symbol, string masterTicket)
{
   // Buscar en posiciones abiertas
   if(FindOpenPosition(symbol, masterTicket) > 0)
      return true;
   
   // Buscar en historial
   if(FindTicketInHistory(symbol, masterTicket))
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Ejecutar OPEN                                                     |
//| Ejecuta directamente sin verificaciones previas (el ticket del origen es único)
//| Retorna: 1=EXITOSO, -2=ERROR (con mensaje descriptivo del MT5 en errorMsg)
//+------------------------------------------------------------------+
int ExecuteOpen(string symbol, string orderType, double masterLots, 
                 double sl, double tp, string masterTicket, string &errorMsg)
{
   // Ejecuta OPEN directamente sin verificaciones previas (el ticket del origen es único)
   // Retorna: 1=EXITOSO, -2=ERROR (con mensaje descriptivo del MT5 en errorMsg)
   errorMsg = "";
   
   // Asegurar símbolo
   if(!SymbolSelect(symbol, true))
   {
      errorMsg = "ERROR: No se puede seleccionar " + symbol;
      PrintFormat("[ERROR OPEN] %s (maestro: %s): %s", symbol, masterTicket, errorMsg);
      return -2; // ERROR
   }
   
   double lots = ComputeSlaveLots(symbol, masterLots);
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
   {
      errorMsg = "ERROR: No hay tick para " + symbol;
      PrintFormat("[ERROR OPEN] %s (maestro: %s): %s", symbol, masterTicket, errorMsg);
      return -2; // ERROR
   }
   
   ENUM_ORDER_TYPE otype;
   double price;
   
   if(orderType == "BUY")
   {
      otype = ORDER_TYPE_BUY;
      price = tick.ask;
   }
   else if(orderType == "SELL")
   {
      otype = ORDER_TYPE_SELL;
      price = tick.bid;
   }
   else
   {
      errorMsg = "ERROR: order_type no soportado: " + orderType;
      PrintFormat("[ERROR OPEN] %s (maestro: %s): %s", symbol, masterTicket, errorMsg);
      return -2; // ERROR
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = symbol;
   request.volume = lots;
   request.type = otype;
   request.price = price;
   request.sl = (sl > 0 ? sl : 0);
   request.tp = (tp > 0 ? tp : 0);
   request.deviation = InpSlippagePoints;
   request.magic = InpMagic;
   request.comment = masterTicket;
   request.type_time = ORDER_TIME_GTC;
   request.type_filling = ORDER_FILLING_FOK;
   
   // Enviar orden
   bool sent = OrderSend(request, result);
   
   // Verificar resultado
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      return 1; // EXITOSO
   }
   
   // Error al ejecutar
   errorMsg = "ERROR: retcode=" + IntegerToString(result.retcode) + " comment=" + result.comment;
   PrintFormat("[ERROR OPEN] %s (maestro: %s): %s", symbol, masterTicket, errorMsg);
   return -2; // ERROR
}

//+------------------------------------------------------------------+
//| Ejecutar CLOSE                                                    |
//| Solo busca en posiciones abiertas (no en historial)               |
//| Retorna: 1=CLOSE OK, 0=NO_EXISTE, 2=FALLO                       |
//+------------------------------------------------------------------+
int ExecuteClose(string symbol, string masterTicket)
{
   // CONTROL: Solo buscar en posiciones abiertas (no en historial)
   // Solo se puede cerrar una posición que está abierta
   ulong ticket = FindOpenPosition(symbol, masterTicket);
   if(ticket == 0)
   {
      PrintFormat("[SKIP CLOSE] %s (maestro: %s) - No existe operacion abierta", symbol, masterTicket);
      return 0; // NO_EXISTE
   }
   
   if(!SymbolSelect(symbol, true))
   {
      PrintFormat("[ERROR] No se puede seleccionar %s", symbol);
      return 0;
   }
   
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
   {
      PrintFormat("[ERROR] No hay tick para %s", symbol);
      return 0;
   }
   
   // Obtener información de la posición
   if(!PositionSelectByTicket(ticket))
   {
      PrintFormat("[ERROR] No se puede seleccionar posición %llu", ticket);
      return 0;
   }
   
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);
   
   ENUM_ORDER_TYPE otype;
   double price;
   
   if(posType == POSITION_TYPE_BUY)
   {
      otype = ORDER_TYPE_SELL;
      price = tick.bid;
   }
   else
   {
      otype = ORDER_TYPE_BUY;
      price = tick.ask;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = symbol;
   request.position = ticket;
   request.volume = volume;
   request.type = otype;
   request.price = price;
   request.deviation = InpSlippagePoints;
   request.magic = PositionGetInteger(POSITION_MAGIC);
   request.comment = masterTicket;
   request.type_time = ORDER_TIME_GTC;
   request.type_filling = ORDER_FILLING_FOK;
   
   // Enviar orden
   bool sent = OrderSend(request, result);
   
   // Verificar resultado
   if(result.retcode == TRADE_RETCODE_DONE)
   {
      return 1; // CLOSE OK
   }
   
   // Cualquier error (incluyendo 10031): mantener en CSV para reintento hasta que se cierre la operación
   if(result.retcode == 10031)
   {
      PrintFormat("[CLOSE ERROR RED] %s (maestro: %s): retcode=10031 comment=%s - Manteniendo en CSV para reintento", 
                  symbol, masterTicket, result.comment);
   }
   else
   {
      PrintFormat("[ERROR CLOSE] %s (maestro: %s): retcode=%d comment=%s - Manteniendo en CSV para reintento", 
                  symbol, masterTicket, result.retcode, result.comment);
   }
   return 2; // FALLO
}

//+------------------------------------------------------------------+
//| Ejecutar MODIFY                                                   |
//| Solo busca en posiciones abiertas (no en historial)              |
//| Retorna: 1=MODIFY OK, 0=NO_EXISTE, 2=FALLO                       |
//+------------------------------------------------------------------+
int ExecuteModify(string symbol, double sl, double tp, string masterTicket)
{
   // CONTROL: Solo buscar en posiciones abiertas (no en historial)
   // Solo se puede modificar una posición que está abierta
   ulong ticket = FindOpenPosition(symbol, masterTicket);
   if(ticket == 0)
   {
      PrintFormat("[SKIP MODIFY] %s (maestro: %s) - No existe operacion abierta", symbol, masterTicket);
      return 0; // NO_EXISTE
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = symbol;
   request.sl = (sl > 0 ? sl : 0);
   request.tp = (tp > 0 ? tp : 0);
   request.comment = masterTicket;
   
   // Enviar orden
   bool sent = OrderSend(request, result);
   
   // Verificar resultado - IMPORTANTE: verificar retcode incluso si OrderSend retorna false
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_NO_CHANGES)
   {
      return 1; // MODIFY OK
   }
   
   // Cualquier error (incluyendo 10031): mantener en CSV para reintento hasta que se cierre la operación
   if(result.retcode == 10031)
   {
      PrintFormat("[MODIFY ERROR RED] %s (maestro: %s): retcode=10031 comment=%s - Manteniendo en CSV para reintento", 
                  symbol, masterTicket, result.comment);
   }
   else
   {
      PrintFormat("[ERROR MODIFY] %s (maestro: %s): retcode=%d comment=%s - Manteniendo en CSV para reintento", 
                  symbol, masterTicket, result.retcode, result.comment);
   }
   return 2; // FALLO
}

//+------------------------------------------------------------------+
//| Escribir al histórico en UTF-8                                   |
//+------------------------------------------------------------------+
void AppendToHistory(string csvLine, string resultado)
{
   string histPath = InpHistFileName;
   datetime now = TimeCurrent();
   string timestamp = TimeToString(now, TIME_DATE|TIME_SECONDS);
   
   // Reemplazar espacios y : por formato compatible
   StringReplace(timestamp, ".", "-");
   StringReplace(timestamp, ":", "-");
   
   string histLine = timestamp + ";" + resultado + ";" + csvLine + "\n";
   
   int handle = FileOpen(histPath, FILE_BIN | FILE_READ | FILE_WRITE | FILE_COMMON |
                        FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
   {
      // Intentar crear archivo nuevo
      handle = FileOpen(histPath, FILE_BIN | FILE_WRITE | FILE_COMMON |
                       FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(handle != INVALID_HANDLE)
      {
         // Escribir header en UTF-8
         string header = "timestamp_ejecucion;resultado;event_type;ticket;order_type;lots;symbol;sl;tp";
         uchar headerBytes[];
         StringToUTF8Bytes(header, headerBytes);
         FileWriteArray(handle, headerBytes);
         
         // Escribir salto de línea UTF-8
         uchar newline[] = {0x0A};
         FileWriteArray(handle, newline);
         FileClose(handle);
         
         // Reabrir para append
         handle = FileOpen(histPath, FILE_BIN | FILE_READ | FILE_WRITE | FILE_COMMON |
                          FILE_SHARE_READ | FILE_SHARE_WRITE);
      }
   }
   
   if(handle != INVALID_HANDLE)
   {
      FileSeek(handle, 0, SEEK_END);
      
      // Escribir línea en UTF-8
      uchar lineBytes[];
      StringToUTF8Bytes(histLine, lineBytes);
      FileWriteArray(handle, lineBytes);
      
      FileClose(handle);
   }
}

//+------------------------------------------------------------------+
//| Reescribir CSV en UTF-8                                          |
//+------------------------------------------------------------------+
void WriteCSV(string filename, string header, string &lines[])
{
   int handle = FileOpen(filename, FILE_BIN | FILE_WRITE | FILE_COMMON |
                        FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
   {
      PrintFormat("[ERROR] No se pudo escribir CSV: %s", filename);
      return;
   }
   
   // Escribir header en UTF-8
   uchar headerBytes[];
   StringToUTF8Bytes(header, headerBytes);
   FileWriteArray(handle, headerBytes);
   
   // Escribir salto de línea UTF-8 (\n = 0x0A)
   uchar newline[] = {0x0A};
   FileWriteArray(handle, newline);
   
   // Escribir cada línea en UTF-8
   for(int i = 0; i < ArraySize(lines); i++)
   {
      uchar lineBytes[];
      StringToUTF8Bytes(lines[i], lineBytes);
      FileWriteArray(handle, lineBytes);
      FileWriteArray(handle, newline);
   }
   
   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Procesar CSV                                                      |
//+------------------------------------------------------------------+
void ProcessCSV()
{
   string lines[];
   if(!ReadFileWithEncoding(InpCSVFileName, lines))
      return;
   
   if(ArraySize(lines) == 0) return;
   
   // Detectar si la primera línea es header o es un evento
   string header = "";
   int startIdx = 0;
   
   if(ArraySize(lines) > 0)
   {
      string firstLine = lines[0];
      StringTrimLeft(firstLine);
      StringTrimRight(firstLine);
      StringToUpper(firstLine);
      
      // Si la primera línea parece ser un header (contiene "event_type" o "ticket")
      if(StringFind(firstLine, "EVENT_TYPE") >= 0 || StringFind(firstLine, "TICKET") >= 0)
      {
         header = lines[0];
         startIdx = 1;
      }
      else
      {
         // No hay header, usar header por defecto (nuevo formato simplificado)
         header = "event_type;ticket;order_type;lots;symbol;sl;tp";
         startIdx = 0;
      }
   }
   else
   {
      // Archivo vacío, usar header por defecto (nuevo formato simplificado)
      header = "event_type;ticket;order_type;lots;symbol;sl;tp";
   }
   
   string remainingLines[];
   int remainingCount = 0;
   
   // Procesar cada línea (empezando desde startIdx)
   for(int i = startIdx; i < ArraySize(lines); i++)
   {
      string line = lines[i];
      if(StringLen(line) < 5) continue;
      
      string fields[];
      int cnt = StringSplit(line, ';', fields);
      if(cnt < 5) continue;
      
      string eventType = fields[0];
      StringTrimLeft(eventType);
      StringTrimRight(eventType);
      StringToUpper(eventType);
      
      string masterTicket = fields[1];
      StringTrimLeft(masterTicket);
      StringTrimRight(masterTicket);
      
      string orderType = fields[2];
      StringTrimLeft(orderType);
      StringTrimRight(orderType);
      StringToUpper(orderType);
      
      double lots = StringToDouble(fields[3]);
      
      string symbol = fields[4];
      StringTrimLeft(symbol);
      StringTrimRight(symbol);
      StringToUpper(symbol);
      
      // Nuevo formato simplificado: event_type;ticket;order_type;lots;symbol;sl;tp
      // indices: 0=event_type, 1=ticket, 2=order_type, 3=lots, 4=symbol, 5=sl, 6=tp
      double sl = 0.0;
      double tp = 0.0;
      if(cnt > 5 && fields[5] != "") sl = StringToDouble(fields[5]);
      if(cnt > 6 && fields[6] != "") tp = StringToDouble(fields[6]);
      
      if(StringLen(symbol) == 0 || StringLen(masterTicket) == 0)
         continue;
      
      bool executedSuccessfully = false;
      int result = 0;
      
      if(eventType == "OPEN")
      {
         string errorMsg = "";
         int result = ExecuteOpen(symbol, orderType, lots, sl, tp, masterTicket, errorMsg);
         if(result == 1) // EXITOSO
         {
            PrintFormat("[OPEN] %s %s %.2f lots (maestro: %s)", 
                       symbol, orderType, lots, masterTicket);
            AppendToHistory(line, "EXITOSO");
         }
         else
         {
            // Siempre escribir al histórico (éxito o fallo) y eliminar del CSV
            AppendToHistory(line, errorMsg);
         }
      }
      else if(eventType == "CLOSE")
      {
         result = ExecuteClose(symbol, masterTicket);
         if(result == 1) // CLOSE OK
         {
            PrintFormat("[CLOSE] %s (maestro: %s)", symbol, masterTicket);
            AppendToHistory(line, "CLOSE OK");
         }
         else if(result == 0) // NO_EXISTE
         {
            AppendToHistory(line, "No existe operacion abierta");
         }
         else if(result == 2) // FALLO
         {
            ArrayResize(remainingLines, remainingCount + 1);
            remainingLines[remainingCount] = line;
            remainingCount++;
            AppendToHistory(line, "ERROR: Fallo al cerrar (reintento)");
         }
      }
      else if(eventType == "MODIFY")
      {
         result = ExecuteModify(symbol, sl, tp, masterTicket);
         if(result == 1) // MODIFY OK
         {
            PrintFormat("[MODIFY] %s SL=%.5f TP=%.5f (maestro: %s)", 
                       symbol, sl, tp, masterTicket);
            AppendToHistory(line, "MODIFY OK");
         }
         else if(result == 0) // NO_EXISTE
         {
            AppendToHistory(line, "No existe operacion abierta");
         }
         else if(result == 2) // FALLO
         {
            ArrayResize(remainingLines, remainingCount + 1);
            remainingLines[remainingCount] = line;
            remainingCount++;
            AppendToHistory(line, "ERROR: Fallo al modificar (reintento)");
         }
      }
   }
   
   // Reescribir CSV solo con líneas pendientes
   int totalProcessed = ArraySize(lines) - startIdx;
   if(remainingCount != totalProcessed)
   {
      WriteCSV(InpCSVFileName, header, remainingLines);
      PrintFormat("[CSV] Actualizado: %d líneas pendientes (de %d totales procesadas)", 
                 remainingCount, totalProcessed);
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   PrintFormat("ClonadorMQ5.mq5 iniciado");
   PrintFormat("Leyendo CSV: %s", InpCSVFileName);
   PrintFormat("Timer: %d segundos", InpTimerSeconds);
   PrintFormat("Cuenta Fondeo: %s", InpCuentaFondeo ? "true" : "false");
   if(InpCuentaFondeo)
      PrintFormat("Multiplicador de lotaje: %.1fx", InpLotMultiplier);
   PrintFormat("Verificación: Solo MT5 (historial + abiertas)");
   PrintFormat("Codificación: UTF-8 exclusivamente");
   Print("Presiona Ctrl+C para detener");
   Print("------------------------------------------------------------");
   
   EventSetTimer(InpTimerSeconds);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("ClonadorMQ5.mq5 finalizado");
}

//+------------------------------------------------------------------+
//| OnTimer                                                           |
//+------------------------------------------------------------------+
void OnTimer()
{
   ProcessCSV();
}

//+------------------------------------------------------------------+

