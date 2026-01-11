//+------------------------------------------------------------------+
//|                                                   WorkerV3.mq4   |
//|                Lee cola_WORKER_<account>.csv y ejecuta órdenes   |
//|                Historiza y notifica vía SendNotification         |
//|                Versión V3: Arquitectura unificada en memoria     |
//+------------------------------------------------------------------+
#property strict

input bool   InpFondeo        = false;
input double InpLotMultiplier = 1.0;
input double InpFixedLots     = 0.10;
input int    InpSlippage      = 30;     // pips
input int    InpMagicNumber   = 0;
input int    InpTimerSeconds  = 1;

// Rutas relativas a Common\Files
string BASE_SUBDIR   = "V3\\Phoenix";
string g_workerId    = "";
string g_queueFile   = "";
string g_historyFile = "";

// Conjuntos de tickets notificados (fallos) para CLOSE y MODIFY
string g_notifCloseTickets[];
int    g_notifCloseCount = 0;
string g_notifModifyTickets[];
int    g_notifModifyCount = 0;

//+------------------------------------------------------------------+
//| Estructura única para almacenar información de operaciones       |
//+------------------------------------------------------------------+
struct OpenLogInfo
{
   int ticketMaster;         // MagicNumber (int) - identificador del maestro
   int ticketWorker;         // Ticket de la orden en MT4
   int magicNumber;          // MagicNumber (para verificación/visualización)
   
   // Campos de la orden abierta
   string symbol;
   int orderType;            // OP_BUY o OP_SELL
   double lots;
   double openPrice;
   datetime openTime;
   double sl;                // Stop Loss actual
   double tp;                // Take Profit actual
};

// Array dinámico para guardar operaciones abiertas (sin límite)
OpenLogInfo g_openLogs[];
int g_openLogsCount = 0;

//+------------------------------------------------------------------+
//| Utilidades de arrays simples                                     |
//+------------------------------------------------------------------+
bool TicketInArray(const string ticket, string &arr[], int count)
{
   for(int i=0;i<count;i++)
      if(arr[i]==ticket)
         return(true);
   return(false);
}
void AddTicket(string ticket, string &arr[], int &count)
{
   if(TicketInArray(ticket, arr, count))
      return;
   ArrayResize(arr, count+1);
   arr[count]=ticket;
   count++;
}
void RemoveTicket(string ticket, string &arr[], int &count)
{
   for(int i=0;i<count;i++)
   {
      if(arr[i]==ticket)
      {
         for(int j=i;j<count-1;j++)
            arr[j]=arr[j+1];
         count--;
         ArrayResize(arr, count);
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Helpers de strings                                               |
//+------------------------------------------------------------------+
string Trim(string s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   return(s);
}

string Upper(string s)
{
   StringToUpper(s);
   return(s);
}

//+------------------------------------------------------------------+
//| Descripción de error (fallback si build no trae ErrorDescription)|
//+------------------------------------------------------------------+
string ErrorText(const int code)
{
   switch(code)
   {
      case 0:   return("No error");
      case 1:   return("No error returned");
      case 2:   return("Common error");
      case 3:   return("Invalid trade parameters");
      case 4:   return("Trade server busy");
      case 5:   return("Old terminal version");
      case 6:   return("No connection with trade server");
      case 8:   return("Too frequent requests");
      case 64:  return("Account disabled");
      case 65:  return("Invalid account");
      case 128: return("Trade timeout");
      case 129: return("Invalid price");
      case 130: return("Invalid stop");
      case 131: return("Invalid trade volume");
      case 132: return("Market closed");
      case 133: return("Trade disabled");
      case 134: return("Not enough money");
      case 135: return("Price changed");
      case 136: return("Off quotes");
      case 146: return("Trade subsystem busy");
      case 148: return("Auto trading disabled");
      default:  return("Error code " + IntegerToString(code));
   }
}

//+------------------------------------------------------------------+
//| Formatea código y descripción de error de MT4                    |
//+------------------------------------------------------------------+
string FormatLastError(const string prefix)
{
   int code = GetLastError();
   string desc = ErrorText(code);
   return(prefix + " (" + IntegerToString(code) + ") " + desc);
}

//+------------------------------------------------------------------+
//| Prefijo de notificación                                          |
//+------------------------------------------------------------------+
void Notify(string msg)
{
   string full = "W: " + IntegerToString(AccountNumber()) + " - " + msg;
   SendNotification(full);
}

//+------------------------------------------------------------------+
//| Helper: Obtener timestamp con milisegundos                      |
//+------------------------------------------------------------------+
string GetTimestampWithMillis()
{
   datetime t = TimeCurrent();
   int ms = (int)(GetTickCount() % 1000);
   return(StringFormat("%s.%03d", TimeToString(t, TIME_DATE|TIME_SECONDS), ms));
}

//+------------------------------------------------------------------+
//| Convierte string Unicode (MQL4) a bytes UTF-8                     |
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
//| Convierte bytes UTF-8 a string (MQL4)                             |
//+------------------------------------------------------------------+
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
      if(b == 0) break; // Null terminator
      
      // ASCII (0x00-0x7F): 1 byte
      if(b < 0x80)
      {
         result += ShortToString((ushort)b);
         pos++;
      }
      // UTF-8 multi-byte: 2 bytes (110xxxxx 10xxxxxx)
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
            // Byte inválido, usar byte directo
            result += ShortToString((ushort)b);
            pos++;
         }
      }
      // UTF-8 multi-byte: 3 bytes (1110xxxx 10xxxxxx 10xxxxxx)
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
            // Byte inválido, usar byte directo
            result += ShortToString((ushort)b);
            pos++;
         }
      }
      // UTF-8 multi-byte: 4 bytes (11110xxx ...) - raro, pero posible
      else if((b & 0xF8) == 0xF0 && pos + 3 < endPos)
      {
         // MQL4 usa UTF-16, así que solo podemos representar hasta 0xFFFF
         // Para caracteres > 0xFFFF, usar carácter de reemplazo
         result += ShortToString((ushort)0xFFFD); // Replacement character
         pos += 4;
      }
      else
      {
         // Byte inválido, saltar
         result += ShortToString((ushort)b);
         pos++;
      }
   }
   return(result);
}

//+------------------------------------------------------------------+
//| Asegura carpeta base en Common\Files                             |
//+------------------------------------------------------------------+
bool EnsureBaseFolder()
{
   // Las carpetas deben existir previamente. No intentamos crearlas.
   return(true);
}

//+------------------------------------------------------------------+
//| Construye ruta relativa para FILE_COMMON                         |
//+------------------------------------------------------------------+
string CommonRelative(const string filename)
{
   return(BASE_SUBDIR + "\\" + filename);
}

//+------------------------------------------------------------------+
//| Devuelve el lotaje según "compounding por bloques":             |
//| +0.01 por cada 1000€ de capital, y ajustado a MIN/MAX/STEP     |
//+------------------------------------------------------------------+
double LotFromCapital(double capital, string symbol)
{
   // 1) Bloques -> lote base
   int blocks = (int)MathFloor(capital / 1000.0); // miles completos
   if(blocks < 1) blocks = 1;                     // mínimo 0.01 (1 bloque)

   double lot = blocks * 0.01;

   // 2) Leer restricciones del broker
   double minLot  = MarketInfo(symbol, MODE_MINLOT);
   double maxLot  = MarketInfo(symbol, MODE_MAXLOT);
   double stepLot = MarketInfo(symbol, MODE_LOTSTEP);

   // Fallbacks por si el broker devuelve 0
   if(minLot  <= 0.0) minLot  = 0.01;
   if(maxLot  <= 0.0) maxLot  = 100.0;
   if(stepLot <= 0.0) stepLot = 0.01;

   // 3) Clamp a min/max
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   // 4) Ajuste al step (redondeo hacia abajo para no pasarse)
   int steps = (int)MathFloor((lot - minLot) / stepLot + 1e-9);
   lot = minLot + steps * stepLot;

   // 5) Redondeo por seguridad a 2 decimales (típico 0.01)
   // (si tu step fuera 0.001, cambia a 3 decimales)
   lot = NormalizeDouble(lot, 2);

   // Re-clamp final por si el redondeo tocó bordes
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

//+------------------------------------------------------------------+
//| Calcula lotaje del worker                                        |
//+------------------------------------------------------------------+
double ComputeWorkerLots(string symbol, double masterLots)
{
   Print("[DEBUG] ComputeWorkerLots: symbol=", symbol, " masterLots=", masterLots);
   Print("[DEBUG] ComputeWorkerLots: InpFondeo=", InpFondeo, " InpLotMultiplier=", InpLotMultiplier);
   
   double finalLots;
   
   // Si es cuenta de fondeo: multiplicar directamente sin normalización por contract size
   if(InpFondeo)
   {
      finalLots = masterLots * InpLotMultiplier;
      Print("[DEBUG] ComputeWorkerLots: InpFondeo=true, finalLots = masterLots(", masterLots, ") * InpLotMultiplier(", InpLotMultiplier, ") = ", finalLots);
   }
   else
   {
      // Si NO es cuenta de fondeo: usar LotFromCapital basado en AccountBalance()
      double capital = AccountBalance();
      Print("[DEBUG] ComputeWorkerLots: InpFondeo=false, capital=", capital);
      finalLots = LotFromCapital(capital, symbol);
      Print("[DEBUG] ComputeWorkerLots: InpFondeo=false, finalLots calculado con LotFromCapital = ", finalLots);
   }
   
   return(finalLots);
}

//+------------------------------------------------------------------+
//| Lee todas las líneas del archivo de cola (UTF-8)                 |
//+------------------------------------------------------------------+
int ReadQueue(string relPath, string &lines[])
{
   // Leer archivo como binario para manejar UTF-8 correctamente
   int handle = FileOpen(relPath, FILE_BIN|FILE_READ|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
      return(0);
   
   // Leer todos los bytes
   int fileSize = (int)FileSize(handle);
   if(fileSize <= 0)
   {
      FileClose(handle);
      return(0);
   }
   
   uchar bytes[];
   ArrayResize(bytes, fileSize);
   uint bytesRead = FileReadArray(handle, bytes, 0, fileSize);
   FileClose(handle);
   
   if((int)bytesRead != fileSize)
      return(0);
   
   // Verificar y saltar BOM UTF-8 si existe
   int bomSkip = 0;
   if(fileSize >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
      bomSkip = 3;
   
   // Convertir bytes UTF-8 a líneas
   int count = 0;
   int lineStart = bomSkip;
   
   while(lineStart < fileSize)
   {
      // Encontrar fin de línea
      int lineEnd = lineStart;
      bool foundEOL = false;
      
      for(int i = lineStart; i < fileSize; i++)
      {
         if(bytes[i] == 0x0A) // LF
         {
            lineEnd = i;
            foundEOL = true;
            break;
         }
         if(bytes[i] == 0x0D) // CR
         {
            lineEnd = i;
            foundEOL = true;
            break;
         }
         if(bytes[i] == 0) // Null terminator
         {
            lineEnd = i;
            break;
         }
      }
      
      if(!foundEOL && lineEnd == lineStart)
         lineEnd = fileSize; // Última línea sin salto
      
      // Convertir línea UTF-8 a string
      if(lineEnd > lineStart)
      {
         uchar lineBytes[];
         ArrayResize(lineBytes, lineEnd - lineStart);
         ArrayCopy(lineBytes, bytes, 0, lineStart, lineEnd - lineStart);
         string ln = UTF8BytesToString(lineBytes);
         
         if(StringLen(ln) > 0)
         {
            ArrayResize(lines, count + 1);
            lines[count] = ln;
            count++;
         }
      }
      
      // Avanzar al siguiente carácter después del salto de línea
      lineStart = lineEnd;
      if(lineStart < fileSize)
      {
         // Saltar CRLF o LF
         if(bytes[lineStart] == 0x0D && lineStart + 1 < fileSize && bytes[lineStart + 1] == 0x0A)
            lineStart += 2;
         else if(bytes[lineStart] == 0x0A || bytes[lineStart] == 0x0D)
            lineStart++;
      }
      
      if(lineStart >= fileSize) break;
   }
   
   return(count);
}

//+------------------------------------------------------------------+
//| Reescribe archivo de cola con líneas restantes                   |
//+------------------------------------------------------------------+
void RewriteQueue(string relPath, string &lines[], int count)
{
   int handle = FileOpen(relPath, FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(handle==INVALID_HANDLE)
   {
      Print("No se pudo reescribir cola: ", relPath, " err=", GetLastError());
      return;
   }
   for(int i=0;i<count;i++)
   {
      FileWrite(handle, lines[i]);
   }
   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Aplica header histórico si no existe                             |
//+------------------------------------------------------------------+
void EnsureHistoryHeader(string relPath)
{
   if(FileIsExist(relPath, FILE_COMMON))
      return;
   int h = FileOpen(relPath, FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h==INVALID_HANDLE)
   {
      Print("No se pudo crear historico: ", relPath, " err=", GetLastError());
      return;
   }
   FileWrite(h, "worker_exec_time;worker_read_time;resultado;event_type;ticketMaster;ticketWorker;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit");
   FileClose(h);
}

//+------------------------------------------------------------------+
//| Añade línea al histórico (formato actualizado con ticketWorker) |
//+------------------------------------------------------------------+
void AppendHistory(const string result, const string eventType, const int ticketMaster, const int ticketWorker, 
                   const string orderType, const double lots, const string symbol, 
                   double openPrice=0.0, datetime openTime=0, double sl=0.0, double tp=0.0, 
                   double closePrice=0.0, datetime closeTime=0, double profit=0.0, 
                   long workerReadTimeMs=0, long workerExecTimeMs=0)
{
   EnsureHistoryHeader(g_historyFile);
   int h = FileOpen(g_historyFile, FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
   {
      Print("No se pudo abrir historico: err=", GetLastError());
      return;
   }
   FileSeek(h, 0, SEEK_END);
   int symDigits = (int)MarketInfo(symbol, MODE_DIGITS);
   if(symDigits<=0) symDigits = Digits;
   string sOpenPrice  = (openPrice!=0.0 ? DoubleToString(openPrice, symDigits) : "");
   string sOpenTime   = (openTime>0 ? TimeToString(openTime, TIME_DATE|TIME_SECONDS) : "");
   string sClosePrice = (closePrice!=0.0 ? DoubleToString(closePrice, symDigits) : "");
   string sCloseTime  = (closeTime>0 ? TimeToString(closeTime, TIME_DATE|TIME_SECONDS) : "");
   string sSl = (sl>0 ? DoubleToString(sl, symDigits) : "");
   string sTp = (tp>0 ? DoubleToString(tp, symDigits) : "");
   string sProfit = (closeTime>0 ? DoubleToString(profit, 2) : "");
   string sWorkerReadTime = (workerReadTimeMs>0 ? IntegerToString(workerReadTimeMs) : "");
   string sWorkerExecTime = (workerExecTimeMs>0 ? IntegerToString(workerExecTimeMs) : "");
   string sTicketMaster = (ticketMaster>0 ? IntegerToString(ticketMaster) : "");
   string sTicketWorker = (ticketWorker>0 ? IntegerToString(ticketWorker) : "");
   string sLots = (lots>0 ? DoubleToString(lots, 2) : "");
   string line = sWorkerExecTime + ";" + sWorkerReadTime + ";" + result + ";" + eventType + ";" + 
                 sTicketMaster + ";" + sTicketWorker + ";" + orderType + ";" + sLots + ";" + symbol + ";" +
                 sOpenPrice + ";" + sOpenTime + ";" + sSl + ";" + sTp + ";" +
                 sClosePrice + ";" + sCloseTime + ";" + sProfit;
   FileWrite(h, line);
   FileClose(h);
}

//+------------------------------------------------------------------+
//| Busca orden abierta por MagicNumber                              |
//+------------------------------------------------------------------+
int FindOpenOrder(int ticketMaster)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() == ticketMaster)
         return OrderTicket();
   }
   return(-1);
}

//+------------------------------------------------------------------+
//| Busca orden en historial por MagicNumber                         |
//+------------------------------------------------------------------+
int FindOrderInHistory(int ticketMaster)
{
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(OrderMagicNumber() == ticketMaster)
         return OrderTicket();
   }
   return(-1);
}

//+------------------------------------------------------------------+
//| Busca entrada en g_openLogs[] por ticketMaster                   |
//+------------------------------------------------------------------+
int FindOpenLog(int ticketMaster)
{
   for(int i = 0; i < g_openLogsCount; i++)
   {
      if(g_openLogs[i].ticketMaster == ticketMaster)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Añade nueva entrada a g_openLogs[]                                |
//+------------------------------------------------------------------+
void AddOpenLog(OpenLogInfo &log)
{
   ArrayResize(g_openLogs, g_openLogsCount + 1);
   g_openLogs[g_openLogsCount] = log;
   g_openLogsCount++;
   DisplayOpenLogsInChart();
}

//+------------------------------------------------------------------+
//| Actualiza sl y tp en g_openLogs[]                                |
//+------------------------------------------------------------------+
void UpdateOpenLog(int ticketMaster, double sl, double tp)
{
   int index = FindOpenLog(ticketMaster);
   if(index >= 0)
   {
      g_openLogs[index].sl = sl;
      g_openLogs[index].tp = tp;
      DisplayOpenLogsInChart();
   }
}

//+------------------------------------------------------------------+
//| Elimina entrada de g_openLogs[]                                  |
//+------------------------------------------------------------------+
void RemoveOpenLog(int ticketMaster)
{
   int index = FindOpenLog(ticketMaster);
   if(index < 0) return;
   
   // Mover los siguientes hacia atrás
   for(int j = index; j < g_openLogsCount - 1; j++)
   {
      g_openLogs[j] = g_openLogs[j + 1];
   }
   g_openLogsCount--;
   ArrayResize(g_openLogs, g_openLogsCount);
   DisplayOpenLogsInChart();
}

//+------------------------------------------------------------------+
//| Carga todas las posiciones abiertas desde MT4                    |
//+------------------------------------------------------------------+
void LoadOpenPositionsFromMT4()
{
   g_openLogsCount = 0;
   ArrayResize(g_openLogs, 0);
   
   int total = OrdersTotal();
   Print("[INIT] Cargando posiciones abiertas desde MT4. Total: ", total);
   
   for(int i = 0; i < total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      
      OpenLogInfo log;
      log.ticketWorker = OrderTicket();
      log.magicNumber = OrderMagicNumber();
      log.ticketMaster = log.magicNumber;  // ticketMaster = magicNumber
      log.symbol = OrderSymbol();
      log.orderType = OrderType();
      log.lots = OrderLots();
      log.openPrice = OrderOpenPrice();
      log.openTime = OrderOpenTime();
      log.sl = OrderStopLoss();
      log.tp = OrderTakeProfit();
      
      AddOpenLog(log);
      Print("[INIT] Cargada posición: TM=", log.ticketMaster, " TW=", log.ticketWorker, " MN=", log.magicNumber, " Symbol=", log.symbol);
   }
   
   Print("[INIT] Carga completada. Total en memoria: ", g_openLogsCount);
}

//+------------------------------------------------------------------+
//| Muestra en pantalla todas las posiciones en memoria (color rojo) |
//+------------------------------------------------------------------+
void DisplayOpenLogsInChart()
{
   // Eliminar objetos gráficos anteriores
   ObjectsDeleteAll(0, "WorkerV3_Label_");
   
   int yOffset = 20;
   int lineHeight = 15;
   
   // Título
   string titleName = "WorkerV3_Label_Title";
   ObjectCreate(0, titleName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, titleName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, titleName, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, titleName, OBJPROP_YDISTANCE, yOffset);
   ObjectSetInteger(0, titleName, OBJPROP_COLOR, clrRed);
   ObjectSetString(0, titleName, OBJPROP_TEXT, "=== POSICIONES EN MEMORIA ===");
   ObjectSetInteger(0, titleName, OBJPROP_FONTSIZE, 9);
   yOffset += lineHeight + 5;
   
   // Mostrar cada posición
   for(int i = 0; i < g_openLogsCount; i++)
   {
      string labelName = "WorkerV3_Label_" + IntegerToString(i);
      string text = "TM: " + IntegerToString(g_openLogs[i].ticketMaster) + 
                    " || TW: " + IntegerToString(g_openLogs[i].ticketWorker) + 
                    " || MN: " + IntegerToString(g_openLogs[i].magicNumber);
      
      ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, labelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, yOffset);
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrRed);
      ObjectSetString(0, labelName, OBJPROP_TEXT, text);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
      yOffset += lineHeight;
   }
   
   // Resumen
   string summaryName = "WorkerV3_Label_Summary";
   string summaryText = "Total: " + IntegerToString(g_openLogsCount) + " posiciones";
   ObjectCreate(0, summaryName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, summaryName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, summaryName, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, summaryName, OBJPROP_YDISTANCE, yOffset);
   ObjectSetInteger(0, summaryName, OBJPROP_COLOR, clrRed);
   ObjectSetString(0, summaryName, OBJPROP_TEXT, summaryText);
   ObjectSetInteger(0, summaryName, OBJPROP_FONTSIZE, 9);
}

//+------------------------------------------------------------------+
//| Parseo de línea a OpenLogInfo                                    |
//+------------------------------------------------------------------+
bool ParseLine(const string line, OpenLogInfo &log, string &eventType)
{
   Print("[DEBUG] ParseLine: Parseando línea: ", line);
   string parts[];
   int n = StringSplit(line, ';', parts);
   Print("[DEBUG] ParseLine: StringSplit retornó ", n, " partes");
   if(n<2)
   {
      Print("[ERROR] ParseLine: Línea tiene menos de 2 campos (", n, "), descartando");
      return(false);
   }
   
   // Inicializar estructura
   log.ticketMaster = 0;
   log.ticketWorker = 0;
   log.magicNumber = 0;
   log.symbol = "";
   log.orderType = 0;
   log.lots = 0.0;
   log.openPrice = 0.0;
   log.openTime = 0;
   log.sl = 0.0;
   log.tp = 0.0;
   
   // Campos comunes a todos los eventos
   string tmp = Trim(parts[0]);
   eventType = Upper(tmp);
   tmp = Trim(parts[1]);
   log.ticketMaster = (int)StrToInteger(tmp);
   
   // Validación básica: eventType y ticketMaster son siempre requeridos
   if(eventType=="" || log.ticketMaster<=0)
   {
      Print("[ERROR] ParseLine: Campos básicos inválidos. eventType='", eventType, "' ticketMaster=", log.ticketMaster);
      return(false);
   }
   
   // Parsear según el tipo de evento
   if(eventType == "OPEN")
   {
      // OPEN: event_type;ticketMaster;order_type;lots;symbol;sl;tp
      if(n < 5)
      {
         Print("[ERROR] ParseLine: OPEN requiere al menos 5 campos (", n, ")");
         return(false);
      }
      tmp = Trim(parts[2]);
      string orderTypeStr = Upper(tmp);
      log.orderType = (orderTypeStr=="BUY" ? OP_BUY : OP_SELL);
      
      tmp = Trim(parts[3]);
      StringReplace(tmp, ",", ".");
      log.lots = StrToDouble(tmp);
      
      tmp = Trim(parts[4]);
      log.symbol = Trim(Upper(tmp));
      
      if(n > 5)
      {
         tmp = Trim(parts[5]);
         if(tmp != "") { StringReplace(tmp, ",", "."); log.sl = StrToDouble(tmp); }
      }
      
      if(n > 6)
      {
         tmp = Trim(parts[6]);
         if(tmp != "") { StringReplace(tmp, ",", "."); log.tp = StrToDouble(tmp); }
      }
      
      // Validar campos requeridos para OPEN
      if(log.symbol == "" || log.orderType == 0)
      {
         Print("[ERROR] ParseLine: OPEN requiere symbol y orderType. symbol='", log.symbol, "' orderType=", log.orderType);
         return(false);
      }
      
      log.magicNumber = log.ticketMaster;  // magicNumber = ticketMaster
   }
   else if(eventType == "MODIFY")
   {
      // MODIFY: event_type;ticketMaster;;;;;sl_new;tp_new
      if(n > 5)
      {
         tmp = Trim(parts[5]);
         if(tmp != "") { StringReplace(tmp, ",", "."); log.sl = StrToDouble(tmp); }
      }
      
      if(n > 6)
      {
         tmp = Trim(parts[6]);
         if(tmp != "") { StringReplace(tmp, ",", "."); log.tp = StrToDouble(tmp); }
      }
   }
   else if(eventType == "CLOSE")
   {
      // CLOSE: event_type;ticketMaster;;;;;;
      // No requiere campos adicionales, solo ticketMaster
   }
   else
   {
      Print("[ERROR] ParseLine: Tipo de evento desconocido: '", eventType, "'");
      return(false);
   }
   
   Print("[DEBUG] ParseLine: eventType=", eventType, " ticketMaster=", log.ticketMaster, " symbol=", log.symbol, " lots=", log.lots, " sl=", log.sl, " tp=", log.tp);
   Print("[DEBUG] ParseLine: Parseo exitoso");
   return(true);
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   g_workerId    = IntegerToString(AccountNumber());
   g_queueFile   = CommonRelative("cola_WORKER_" + g_workerId + ".csv");
   g_historyFile = CommonRelative("historico_WORKER_" + g_workerId + ".csv");

   if(!EnsureBaseFolder())
      return(INIT_FAILED);

   // Cargar todas las posiciones abiertas desde MT4
   LoadOpenPositionsFromMT4();
   
   // Mostrar en pantalla
   DisplayOpenLogsInChart();

   EventSetTimer(InpTimerSeconds);
   Print("WorkerV3 inicializado. Cola=", g_queueFile, " Historico=", g_historyFile);
   Print("Posiciones cargadas en memoria: ", g_openLogsCount);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   // Limpiar objetos gráficos
   ObjectsDeleteAll(0, "WorkerV3_Label_");
}

//+------------------------------------------------------------------+
//| OnTimer                                                          |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Capturar worker_read_time cuando se lee la cola (milisegundos desde epoch)
   datetime currentTime = TimeCurrent();
   long workerReadTimeMs = (long)(currentTime * 1000) + (GetTickCount() % 1000);
   
   string lines[];
   int total = ReadQueue(g_queueFile, lines);
   if(total==0)
   {
      Print("[DEBUG] OnTimer: Cola vacía, no hay eventos para procesar");
      return;
   }
   Print("[DEBUG] OnTimer: Leyendo cola, total líneas=", total);

   // Detectar cabecera opcional
   int startIdx=0;
   if(total>0)
   {
      string firstLower = lines[0];
      StringToLower(firstLower);
      if(StringFind(firstLower, "event_type")>=0)
         startIdx=1;
   }

   string remaining[];
   int remainingCount=0;

   for(int i=startIdx;i<total;i++)
   {
      OpenLogInfo log;
      string eventType;
      if(!ParseLine(lines[i], log, eventType))
      {
         // línea inválida: añadir a remaining para reintento
         ArrayResize(remaining, remainingCount+1);
         remaining[remainingCount]=lines[i];
         remainingCount++;
         continue;
      }

      if(eventType=="OPEN")
      {
         Print("[DEBUG] OnTimer: Procesando evento OPEN para ticketMaster=", log.ticketMaster, " symbol=", log.symbol, " orderType=", log.orderType);
         
         // Asegurar símbolo (solo necesario para OPEN)
         Print("[DEBUG] OnTimer: Intentando SymbolSelect para symbol=", log.symbol);
         if(!SymbolSelect(log.symbol, true))
         {
            int errCodeSym = GetLastError();
            string errDescSym = ErrorText(errCodeSym);
            string msg = "Ticket: " + IntegerToString(log.ticketMaster) + " - OPEN FALLO: SymbolSelect (" + IntegerToString(errCodeSym) + ") " + errDescSym;
            Print("[ERROR] OnTimer: ", msg);
            Notify(msg);
            AppendHistory(msg, "OPEN", log.ticketMaster, 0, (log.orderType==OP_BUY ? "BUY" : "SELL"), log.lots, log.symbol, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            continue; // OPEN no se reintenta
         }
         Print("[DEBUG] OnTimer: SymbolSelect exitoso para symbol=", log.symbol);
         
         // Verificar si ya existe una orden abierta con este ticketMaster (evitar duplicados)
         int existingOrder = FindOpenOrder(log.ticketMaster);
         Print("[DEBUG] OnTimer: FindOpenOrder retornó existingOrder=", existingOrder, " para ticketMaster=", log.ticketMaster);
         if(existingOrder >= 0)
         {
            Print("[DEBUG] OnTimer: Ya existe orden abierta con ticketMaster=", log.ticketMaster, " orderTicket=", existingOrder, ", saltando OPEN");
            AppendHistory("Ya existe operacion abierta", "OPEN", log.ticketMaster, existingOrder, (log.orderType==OP_BUY ? "BUY" : "SELL"), log.lots, log.symbol, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            continue; // Saltar esta línea, no reintentar
         }
         
         // Calcular lotaje (solo para OPEN)
         Print("[DEBUG] OnTimer: Llamando ComputeWorkerLots con symbol=", log.symbol, " log.lots=", log.lots);
         double lotsWorker = ComputeWorkerLots(log.symbol, log.lots);
         Print("[DEBUG] OnTimer: lotsWorker calculado = ", lotsWorker);
         
         int type = log.orderType;
         double price = (type==OP_BUY ? Ask : Bid);
         string commentStr = IntegerToString(log.ticketMaster);
         Print("[DEBUG] OnTimer: Preparando OrderSend: symbol=", log.symbol, " type=", type, " lots=", lotsWorker, " price=", price, " sl=", log.sl, " tp=", log.tp, " magic=", log.ticketMaster);
         ResetLastError();
         int ticketNew = OrderSend(log.symbol, type, lotsWorker, price, InpSlippage, log.sl, log.tp, commentStr, log.ticketMaster, 0, clrNONE);
         
         // Capturar worker_exec_time después de OrderSend (milisegundos desde epoch)
         datetime execTime = TimeCurrent();
         long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
         
         Print("[DEBUG] OnTimer: OrderSend retornó ticketNew=", ticketNew);
         if(ticketNew<0)
         {
            // Capturar el error inmediatamente y registrar código + descripción
            int errCode = GetLastError();
            string errDesc = ErrorText(errCode);
            string errBase = "ERROR: OPEN (" + IntegerToString(errCode) + ") " + errDesc;
            string err = "Ticket: " + IntegerToString(log.ticketMaster) + " - " + errBase;
            Notify(err);
            // En el histórico dejamos el texto de error base (código + descripción)
            AppendHistory(errBase, "OPEN", log.ticketMaster, 0, (log.orderType==OP_BUY ? "BUY" : "SELL"), log.lots, log.symbol, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
            // no reintento
         }
         else
         {
            // OPEN exitoso: crear entrada en memoria
            if(OrderSelect(ticketNew, SELECT_BY_TICKET))
            {
               log.ticketWorker = ticketNew;
               log.magicNumber = log.ticketMaster;
               log.openPrice = OrderOpenPrice();
               log.openTime = OrderOpenTime();
               log.sl = OrderStopLoss();
               log.tp = OrderTakeProfit();
               
               AddOpenLog(log);
               
               string ok = "Ticket: " + IntegerToString(log.ticketMaster) + " - OPEN EXITOSO: " + log.symbol + " " + (log.orderType==OP_BUY ? "BUY" : "SELL") + " " + DoubleToString(lotsWorker,2) + " lots";
               Notify(ok);
               AppendHistory("EXITOSO", "OPEN", log.ticketMaster, ticketNew, (log.orderType==OP_BUY ? "BUY" : "SELL"), log.lots, log.symbol, log.openPrice, log.openTime, log.sl, log.tp, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
            }
         }
      }
      else if(eventType=="CLOSE")
      {
         Print("[DEBUG] OnTimer: Procesando evento CLOSE para ticketMaster=", log.ticketMaster);
         
         // Buscar en memoria
         int index = FindOpenLog(log.ticketMaster);
         if(index >= 0)
         {
            // Encontrado en memoria: obtener ticketWorker
            int ticketWorker = g_openLogs[index].ticketWorker;
            
            // Verificar si ticketWorker sigue en operaciones abiertas
            if(OrderSelect(ticketWorker, SELECT_BY_TICKET))
            {
               // Orden sigue abierta: cerrar
               int type = OrderType();
               double volume = OrderLots();
               double closePrice = (type==OP_BUY ? Bid : Ask);
               double profitBefore = OrderProfit();
               datetime closeTime = TimeCurrent();
               
               if(OrderClose(ticketWorker, volume, closePrice, InpSlippage, clrNONE))
               {
                  // Capturar worker_exec_time después de OrderClose
                  datetime execTime = TimeCurrent();
                  long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
                  
                  string ok = "Ticket: " + IntegerToString(log.ticketMaster) + " - CLOSE EXITOSO: " + DoubleToString(volume,2) + " lots";
                  Notify(ok);
                  AppendHistory("CLOSE OK", "CLOSE", log.ticketMaster, ticketWorker, "", 0, g_openLogs[index].symbol, 0, 0, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
                  RemoveTicket(IntegerToString(log.ticketMaster), g_notifCloseTickets, g_notifCloseCount);
                  
                  // Eliminar entrada de memoria inmediatamente
                  RemoveOpenLog(log.ticketMaster);
               }
               else
               {
                  // Capturar worker_exec_time después de OrderClose (aunque haya fallado)
                  datetime execTime = TimeCurrent();
                  long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
                  
                  // Verificar si la orden pasó al historial (se cerró manualmente)
                  int historyTicket = FindOrderInHistory(log.ticketMaster);
                  if(historyTicket >= 0)
                  {
                     // Encontrada en historial: orden cerrada, eliminar de memoria
                     RemoveOpenLog(log.ticketMaster);
                     AppendHistory("CLOSE fallido: Orden ya cerrada", "CLOSE", log.ticketMaster, ticketWorker, "", 0, g_openLogs[index].symbol, 0, 0, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
                     RemoveTicket(IntegerToString(log.ticketMaster), g_notifCloseTickets, g_notifCloseCount);
                  }
                  else
                  {
                     // Error de MT4: mantener en memoria para reintento
                     string err = "Ticket: " + IntegerToString(log.ticketMaster) + " - " + FormatLastError("CLOSE FALLO");
                     if(!TicketInArray(IntegerToString(log.ticketMaster), g_notifCloseTickets, g_notifCloseCount))
                     {
                        Notify(err);
                        AddTicket(IntegerToString(log.ticketMaster), g_notifCloseTickets, g_notifCloseCount);
                     }
                     AppendHistory(err, "CLOSE", log.ticketMaster, ticketWorker, "", 0, g_openLogs[index].symbol, 0, 0, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
                     ArrayResize(remaining, remainingCount+1);
                     remaining[remainingCount]=lines[i];
                     remainingCount++;
                  }
               }
            }
            else
            {
               // ticketWorker no se puede seleccionar: verificar historial
               int historyTicket = FindOrderInHistory(log.ticketMaster);
               if(historyTicket >= 0)
               {
                  // Encontrada en historial: orden ya cerrada
                  RemoveOpenLog(log.ticketMaster);
                  AppendHistory("Orden ya estaba cerrada", "CLOSE", log.ticketMaster, ticketWorker, "", 0, g_openLogs[index].symbol, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
                  RemoveTicket(IntegerToString(log.ticketMaster), g_notifCloseTickets, g_notifCloseCount);
               }
               else
               {
                  // No encontrada: error
                  AppendHistory("Close fallido. No se encontro: " + IntegerToString(log.ticketMaster), "CLOSE", log.ticketMaster, 0, "", 0, "", 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
               }
            }
         }
         else
         {
            // No encontrado en memoria: verificar historial
            int historyTicket = FindOrderInHistory(log.ticketMaster);
            if(historyTicket >= 0)
            {
               // Encontrada en historial: orden ya cerrada
               AppendHistory("Orden ya estaba cerrada", "CLOSE", log.ticketMaster, historyTicket, "", 0, "", 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            }
            else
            {
               // No encontrada: error
               AppendHistory("Close fallido. No se encontro: " + IntegerToString(log.ticketMaster), "CLOSE", log.ticketMaster, 0, "", 0, "", 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            }
         }
      }
      else if(eventType=="MODIFY")
      {
         Print("[DEBUG] OnTimer: Procesando evento MODIFY para ticketMaster=", log.ticketMaster);
         
         // Buscar en memoria
         int index = FindOpenLog(log.ticketMaster);
         if(index >= 0)
         {
            // Encontrado en memoria: obtener ticketWorker
            int ticketWorker = g_openLogs[index].ticketWorker;
            
            // Verificar si ticketWorker sigue en operaciones abiertas
            if(OrderSelect(ticketWorker, SELECT_BY_TICKET))
            {
               // Orden sigue abierta: modificar
               double newSL = (log.sl>0 ? log.sl : 0.0);
               double newTP = (log.tp>0 ? log.tp : 0.0);
               
               if(OrderModify(ticketWorker, OrderOpenPrice(), newSL, newTP, OrderExpiration(), clrNONE))
               {
                  // Capturar worker_exec_time después de OrderModify
                  datetime execTime = TimeCurrent();
                  long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
                  
                  // Actualizar memoria
                  UpdateOpenLog(log.ticketMaster, newSL, newTP);
                  
                  string ok = "Ticket: " + IntegerToString(log.ticketMaster) + " - MODIFY EXITOSO: SL=" + DoubleToString(newSL,2) + " TP=" + DoubleToString(newTP,2);
                  Notify(ok);
                  string resHist = "MODIFY OK SL=" + DoubleToString(newSL,2) + " TP=" + DoubleToString(newTP,2);
                  AppendHistory(resHist, "MODIFY", log.ticketMaster, ticketWorker, "", 0, g_openLogs[index].symbol, 0, 0, newSL, newTP, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
                  RemoveTicket(IntegerToString(log.ticketMaster), g_notifModifyTickets, g_notifModifyCount);
               }
               else
               {
                  // Capturar worker_exec_time después de OrderModify (aunque haya fallado)
                  datetime execTime = TimeCurrent();
                  long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
                  
                  // Verificar si la orden pasó al historial (se cerró manualmente)
                  int historyTicket = FindOrderInHistory(log.ticketMaster);
                  if(historyTicket >= 0)
                  {
                     // Encontrada en historial: orden cerrada, eliminar de memoria
                     RemoveOpenLog(log.ticketMaster);
                     AppendHistory("MODIFY fallido: Orden ya cerrada", "MODIFY", log.ticketMaster, ticketWorker, "", 0, g_openLogs[index].symbol, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
                     RemoveTicket(IntegerToString(log.ticketMaster), g_notifModifyTickets, g_notifModifyCount);
                  }
                  else
                  {
                     // Error de MT4: mantener en memoria para reintento
                     int errCode = GetLastError();
                     string errDesc = ErrorText(errCode);
                     string errBase = "MODIFY FALLO (" + IntegerToString(errCode) + ") " + errDesc;
                     string err = "Ticket: " + IntegerToString(log.ticketMaster) + " - " + errBase;
                     if(!TicketInArray(IntegerToString(log.ticketMaster), g_notifModifyTickets, g_notifModifyCount))
                     {
                        Notify(err);
                        AddTicket(IntegerToString(log.ticketMaster), g_notifModifyTickets, g_notifModifyCount);
                     }
                     AppendHistory(err, "MODIFY", log.ticketMaster, ticketWorker, "", 0, g_openLogs[index].symbol, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
                     ArrayResize(remaining, remainingCount+1);
                     remaining[remainingCount]=lines[i];
                     remainingCount++;
                  }
               }
            }
            else
            {
               // ticketWorker no se puede seleccionar: orden cerrada
               RemoveOpenLog(log.ticketMaster);
               AppendHistory("MODIFY fallido: Orden ya cerrada", "MODIFY", log.ticketMaster, ticketWorker, "", 0, g_openLogs[index].symbol, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
               RemoveTicket(IntegerToString(log.ticketMaster), g_notifModifyTickets, g_notifModifyCount);
            }
         }
         else
         {
            // No encontrado en memoria
            AppendHistory("MODIFY fallido. No se encontro: " + IntegerToString(log.ticketMaster), "MODIFY", log.ticketMaster, 0, "", 0, "", 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
         }
      }
      // Otros event_type: ignorar
   }

   // Reescribir cola con pendientes
   RewriteQueue(g_queueFile, remaining, remainingCount);
}

//+------------------------------------------------------------------+

