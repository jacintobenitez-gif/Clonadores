//+------------------------------------------------------------------+
//|                                                     Worker.mq4   |
//|                Lee cola_WORKER_<account>.txt y ejecuta órdenes   |
//|                Historiza y notifica vía SendNotification         |
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

// Estructura de evento
struct EventRec
{
   string eventType;
   string ticket;
   string orderType;
   double lots;
   string symbol;
   double sl;
   double tp;
   string originalLine;
};

//+------------------------------------------------------------------+
//| Estructura para guardar información de OPEN en memoria           |
//+------------------------------------------------------------------+
struct OpenLogInfo
{
   string ticketMaestro;
   int ticketWorker;
   string timestampOpen;
   string symbol;
   int magicSent;
   int ordersTotalBefore;
   int ordersTotalAfter;
   string timestampVerify;
   bool verifyOrderSelectOK;
   int verifyMagicRead;
   bool verifyMagicMatch;
   int verifyDelayMs;
};

OpenLogInfo g_openLogs[100];  // Array para guardar logs de OPEN
int g_openLogsCount = 0;      // Contador de logs guardados

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
//| Obtiene contract size usando tickvalue/ticksize (compatibilidad) |
//+------------------------------------------------------------------+
double GetContractSize(string symbol)
{
   double tickValue = MarketInfo(symbol, MODE_TICKVALUE);
   double tickSize  = MarketInfo(symbol, MODE_TICKSIZE);
   Print("[DEBUG] GetContractSize: symbol=", symbol, " tickValue=", tickValue, " tickSize=", tickSize);
   
   if(tickValue <= 0.0 || tickSize <= 0.0)
   {
      Print("[DEBUG] GetContractSize: tickValue o tickSize <= 0, retornando 1.0");
      return(1.0);
   }
   
   double contractSize = tickValue / tickSize;
   Print("[DEBUG] GetContractSize: contractSize = tickValue(", tickValue, ") / tickSize(", tickSize, ") = ", contractSize);
   return(contractSize);
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
//| Helper: Convertir string a bytes para logging                   |
//+------------------------------------------------------------------+
string StringToBytes(string s)
{
   string result = "[";
   int len = StringLen(s);
   for(int i = 0; i < len; i++)
   {
      if(i > 0) result += ",";
      result += IntegerToString((int)StringGetCharacter(s, i));
   }
   result += "]";
   return(result);
}

//+------------------------------------------------------------------+
//| Añade información de OPEN exitoso a memoria                     |
//+------------------------------------------------------------------+
void AddOpenLog(EventRec &ev, int ticketWorker, int ordersTotalBefore, bool verifyOK, int verifyMagicRead, bool verifyMagicMatch, int verifyDelayMs)
{
   if(g_openLogsCount >= 100) return;  // Límite de seguridad
   
   string tsOpen = GetTimestampWithMillis();
   int ordersTotalAfter = OrdersTotal();
   int magicSent = (int)StrToInteger(ev.ticket);
   
   // Guardar información básica
   g_openLogs[g_openLogsCount].ticketMaestro = ev.ticket;
   g_openLogs[g_openLogsCount].ticketWorker = ticketWorker;
   g_openLogs[g_openLogsCount].timestampOpen = tsOpen;
   g_openLogs[g_openLogsCount].symbol = ev.symbol;
   g_openLogs[g_openLogsCount].magicSent = magicSent;
   g_openLogs[g_openLogsCount].ordersTotalBefore = ordersTotalBefore;
   g_openLogs[g_openLogsCount].ordersTotalAfter = ordersTotalAfter;
   
   // Guardar resultados de verificación (ya realizada externamente)
   string tsVerify = GetTimestampWithMillis();
   g_openLogs[g_openLogsCount].timestampVerify = tsVerify;
   g_openLogs[g_openLogsCount].verifyOrderSelectOK = verifyOK;
   g_openLogs[g_openLogsCount].verifyMagicRead = verifyMagicRead;
   g_openLogs[g_openLogsCount].verifyMagicMatch = verifyMagicMatch;
   g_openLogs[g_openLogsCount].verifyDelayMs = verifyDelayMs;
   
   g_openLogsCount++;
   
   // Escribir también al archivo de persistencia
   WriteOpenLogToFile(ev.ticket, ticketWorker, ev.symbol, magicSent);
}

//+------------------------------------------------------------------+
//| Elimina información de OPEN de memoria                           |
//+------------------------------------------------------------------+
void RemoveOpenLog(string ticketMaestro)
{
   for(int i = 0; i < g_openLogsCount; i++)
   {
      if(g_openLogs[i].ticketMaestro == ticketMaestro)
      {
         // Mover los siguientes hacia atrás
         for(int j = i; j < g_openLogsCount - 1; j++)
         {
            g_openLogs[j] = g_openLogs[j + 1];
         }
         g_openLogsCount--;
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Obtiene información de OPEN de memoria                           |
//+------------------------------------------------------------------+
OpenLogInfo GetOpenLog(string ticketMaestro)
{
   OpenLogInfo empty;
   empty.ticketMaestro = "";
   
   for(int i = 0; i < g_openLogsCount; i++)
   {
      if(g_openLogs[i].ticketMaestro == ticketMaestro)
      {
         return g_openLogs[i];
      }
   }
   return empty;
}

//+------------------------------------------------------------------+
//| Genera string de log cuando busca en historial y no encuentra  |
//+------------------------------------------------------------------+
string GetCloseHistoryNotFoundLog(EventRec &ev)
{
   string ts = GetTimestampWithMillis();
   int ordersTotal = OrdersTotal();
   int historyTotal = OrdersHistoryTotal();
   int ticketLength = StringLen(ev.ticket);
   
   // Obtener información de última orden en historial
   string lastHistoryInfo = "N/A";
   if(historyTotal > 0 && OrderSelect(historyTotal - 1, SELECT_BY_POS, MODE_HISTORY))
   {
      int lastTicket = OrderTicket();
      int lastMagic = OrderMagicNumber();
      lastHistoryInfo = StringFormat("ticket=%d magic=%d", lastTicket, lastMagic);
   }
   
   return StringFormat("[CLOSE_HISTORY_SEARCH] timestamp=%s | ticket_buscado=%s | ticket_length=%d | OrdersTotal=%d | HistoryTotal=%d | encontrado_en_historial=NO | rango_busqueda=todo_historial | ultima_orden_historial_%s",
                      ts, ev.ticket, ticketLength, ordersTotal, historyTotal, lastHistoryInfo);
}

//+------------------------------------------------------------------+
//| Escribe error de CLOSE en archivo ERROR_CLOSE_WORKER_{ID}.txt  |
//+------------------------------------------------------------------+
void WriteCloseErrorToFile(EventRec &ev)
{
   string errorFile = CommonRelative("ERROR_CLOSE_WORKER_" + g_workerId + ".txt");
   int handle = FileOpen(errorFile, FILE_BIN | FILE_READ | FILE_WRITE | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   
   if(handle == INVALID_HANDLE)
   {
      // Intentar crear archivo nuevo
      handle = FileOpen(errorFile, FILE_BIN | FILE_WRITE | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   }
   
   if(handle == INVALID_HANDLE)
      return;  // No se pudo abrir/crear archivo
   
   FileSeek(handle, 0, SEEK_END);
   
   string ts = GetTimestampWithMillis();
   int ordersTotal = OrdersTotal();
   int historyTotal = OrdersHistoryTotal();
   int ticketLength = StringLen(ev.ticket);
   
   // Separador
   string separator = "================================================================================\r\n";
   uchar sepBytes[];
   StringToUTF8Bytes(separator, sepBytes);
   FileWriteArray(handle, sepBytes);
   
   // Log básico
   string log1 = StringFormat("[CLOSE_NOT_FOUND] timestamp=%s | ticket_maestro=%s | ticket_buscado=%s | ticket_length=%d | OrdersTotal=%d | HistoryTotal=%d\r\n",
                              ts, ev.ticket, ev.ticket, ticketLength, ordersTotal, historyTotal);
   uchar log1Bytes[];
   StringToUTF8Bytes(log1, log1Bytes);
   FileWriteArray(handle, log1Bytes);
   
   // Log del evento CLOSE
   string log2 = StringFormat("[CLOSE_EVENT_INFO] timestamp=%s | linea_original=%s | ticket_parseado=%s | ticket_length=%d | symbol=%s | orderType=%s | lots=%.2f\r\n",
                              ts, ev.originalLine, ev.ticket, ticketLength, ev.symbol, ev.orderType, ev.lots);
   uchar log2Bytes[];
   StringToUTF8Bytes(log2, log2Bytes);
   FileWriteArray(handle, log2Bytes);
   
   // Log de búsqueda en historial
   string historyLog = GetCloseHistoryNotFoundLog(ev) + "\r\n";
   uchar historyBytes[];
   StringToUTF8Bytes(historyLog, historyBytes);
   FileWriteArray(handle, historyBytes);
   
   // Log de todas las órdenes abiertas
   int magicBuscado = (int)StrToInteger(ev.ticket);
   string ordersDump = "[CLOSE_ORDERS_DUMP] timestamp=" + ts + " | ticket_buscado=" + ev.ticket + " | magic_buscado=" + IntegerToString(magicBuscado) + " | total_abiertas=" + IntegerToString(ordersTotal) + " | ordenes=[";
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0 && count < 20; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      
      if(count > 0) ordersDump += ", ";
      int orderTicket = OrderTicket();
      int orderMagic = OrderMagicNumber();
      string orderSymbol = OrderSymbol();
      int orderType = OrderType();
      string typeStr = (orderType == OP_BUY ? "BUY" : (orderType == OP_SELL ? "SELL" : "OTHER"));
      
      ordersDump += StringFormat("ticket=%d magic=%d symbol=%s type=%s", orderTicket, orderMagic, orderSymbol, typeStr);
      count++;
   }
   ordersDump += "]\r\n";
   uchar ordersBytes[];
   StringToUTF8Bytes(ordersDump, ordersBytes);
   FileWriteArray(handle, ordersBytes);
   
   // Log de comparación MagicNumber
   string compareLog = "[CLOSE_MAGIC_COMPARE] ticket_buscado=" + ev.ticket + " | magic_buscado=" + IntegerToString(magicBuscado) + " | ordenes_magic=[";
   count = 0;
   for(int i = OrdersTotal() - 1; i >= 0 && count < 10; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      
      if(count > 0) compareLog += ", ";
      int orderTicket = OrderTicket();
      int orderMagic = OrderMagicNumber();
      bool match = (orderMagic == magicBuscado);
      
      compareLog += StringFormat("ticket=%d magic=%d match=%s", orderTicket, orderMagic, (match ? "YES" : "NO"));
      count++;
   }
   compareLog += "]\r\n";
   uchar compareBytes[];
   StringToUTF8Bytes(compareLog, compareBytes);
   FileWriteArray(handle, compareBytes);
   
   // Buscar información del OPEN en memoria
   OpenLogInfo openInfo = GetOpenLog(ev.ticket);
   if(StringLen(openInfo.ticketMaestro) > 0)
   {
      // Información del OPEN encontrada
      string openLog = "--- INFORMACION DEL OPEN CORRESPONDIENTE ---\r\n";
      uchar openLogBytes[];
      StringToUTF8Bytes(openLog, openLogBytes);
      FileWriteArray(handle, openLogBytes);
      
      string openSuccess = StringFormat("[OPEN_SUCCESS] timestamp=%s | ticket_maestro=%s | ticket_worker=%d | symbol=%s | magic_sent=%d | OrderSend_retcode=OK | OrdersTotal_antes=%d | OrdersTotal_despues=%d\r\n",
                                       openInfo.timestampOpen, openInfo.ticketMaestro, openInfo.ticketWorker, openInfo.symbol, openInfo.magicSent, openInfo.ordersTotalBefore, openInfo.ordersTotalAfter);
      uchar openSuccessBytes[];
      StringToUTF8Bytes(openSuccess, openSuccessBytes);
      FileWriteArray(handle, openSuccessBytes);
      
      string verifyResult = openInfo.verifyOrderSelectOK ? "OK" : "FAIL";
      string verifyMatch = openInfo.verifyMagicMatch ? "YES" : "NO";
      string openVerify = StringFormat("[OPEN_VERIFY] timestamp=%s | ticket_worker=%d | OrderSelect_result=%s | OrderMagic_read=%d | magic_match=%s | delay_ms=%d\r\n",
                                      openInfo.timestampVerify, openInfo.ticketWorker, verifyResult, openInfo.verifyMagicRead, verifyMatch, openInfo.verifyDelayMs);
      uchar openVerifyBytes[];
      StringToUTF8Bytes(openVerify, openVerifyBytes);
      FileWriteArray(handle, openVerifyBytes);
      
      // Timing entre OPEN y CLOSE
      string timingLog = StringFormat("[CLOSE_TIMING] ticket=%s | OPEN_timestamp=%s | CLOSE_timestamp=%s\r\n",
                                     ev.ticket, openInfo.timestampOpen, ts);
      uchar timingBytes[];
      StringToUTF8Bytes(timingLog, timingBytes);
      FileWriteArray(handle, timingBytes);
   }
   else
   {
      // No se encontró información del OPEN
      string noOpenLog = "--- INFORMACION DEL OPEN NO DISPONIBLE EN MEMORIA ---\r\n";
      uchar noOpenBytes[];
      StringToUTF8Bytes(noOpenLog, noOpenBytes);
      FileWriteArray(handle, noOpenBytes);
   }
   
   // Separador final
   FileWriteArray(handle, sepBytes);
   
   FileClose(handle);
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
//| Obtiene el nombre del archivo de persistencia de OPEN logs       |
//+------------------------------------------------------------------+
string GetOpenLogsFileName()
{
   return("open_logs_" + g_workerId + ".csv");
}

//+------------------------------------------------------------------+
//| Escribe información de OPEN al archivo de persistencia          |
//+------------------------------------------------------------------+
void WriteOpenLogToFile(string ticketMaestro, int ticketWorker, string symbol, int magic)
{
   string filename = GetOpenLogsFileName();
   string relPath = CommonRelative(filename);
   
   Print("[DEBUG] WriteOpenLogToFile: Intentando escribir. ticketMaestro=", ticketMaestro, " ticketWorker=", ticketWorker, " symbol=", symbol, " magic=", magic);
   Print("[DEBUG] WriteOpenLogToFile: Ruta archivo=", relPath);
   
   // Construir línea: ticket_maestro;ticket_worker;timestamp;symbol;magic
   string timestamp = GetTimestampWithMillis();
   string line = ticketMaestro + ";" + IntegerToString(ticketWorker) + ";" + timestamp + ";" + symbol + ";" + IntegerToString(magic);
   Print("[DEBUG] WriteOpenLogToFile: Línea a escribir=", line);
   
   // Intentar abrir archivo en modo append
   int handle = FileOpen(relPath, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
   {
      Print("[DEBUG] WriteOpenLogToFile: Archivo no existe, intentando crear. err=", GetLastError());
      // Intentar crear archivo nuevo
      handle = FileOpen(relPath, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_WRITE);
      if(handle == INVALID_HANDLE)
      {
         int errCode = GetLastError();
         Print("ERROR: WriteOpenLogToFile: No se pudo crear archivo OPEN log: ", relPath, " err=", errCode, " desc=", ErrorText(errCode));
         return;
      }
      Print("[DEBUG] WriteOpenLogToFile: Archivo creado exitosamente");
      FileClose(handle);
      
      // Reabrir para append
      handle = FileOpen(relPath, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_WRITE);
      if(handle == INVALID_HANDLE)
      {
         int errCode = GetLastError();
         Print("ERROR: WriteOpenLogToFile: No se pudo abrir archivo para escribir OPEN log: ", relPath, " err=", errCode, " desc=", ErrorText(errCode));
         return;
      }
      Print("[DEBUG] WriteOpenLogToFile: Archivo reabierto para append");
   }
   else
   {
      Print("[DEBUG] WriteOpenLogToFile: Archivo abierto exitosamente para append");
   }
   
   // Ir al final del archivo
   FileSeek(handle, 0, SEEK_END);
   
   // Escribir línea (igual que AppendHistory)
   FileWrite(handle, line);
   Print("[DEBUG] WriteOpenLogToFile: Línea escrita exitosamente");
   
   FileClose(handle);
   Print("[DEBUG] WriteOpenLogToFile: Archivo cerrado. OPEN log escrito exitosamente.");
}

//+------------------------------------------------------------------+
//| Lee ticket_worker del archivo de persistencia                    |
//| Retorna ticket_worker si encuentra, -1 si no encuentra          |
//+------------------------------------------------------------------+
int ReadOpenLogFromFile(string ticketMaestro)
{
   string filename = GetOpenLogsFileName();
   string relPath = CommonRelative(filename);
   
   // Leer archivo como texto (igual que otros archivos de texto)
   int handle = FileOpen(relPath, FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
   {
      // Archivo no existe, no hay problema
      return(-1);
   }
   
   // Leer línea por línea
   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      if(StringLen(line) == 0) continue;
      
      // Parsear línea: ticket_maestro;ticket_worker;timestamp;symbol;magic
      string parts[];
      int count = StringSplit(line, ';', parts);
      if(count >= 2)
      {
         if(parts[0] == ticketMaestro)
         {
            // Encontrado: retornar ticket_worker
            FileClose(handle);
            return((int)StrToInteger(parts[1]));
         }
      }
   }
   
   FileClose(handle);
   return(-1); // No encontrado
}

//+------------------------------------------------------------------+
//| Elimina línea del archivo de persistencia                        |
//| Retorna true si eliminó, false si no encontró                    |
//+------------------------------------------------------------------+
bool RemoveOpenLogFromFile(string ticketMaestro)
{
   string filename = GetOpenLogsFileName();
   string relPath = CommonRelative(filename);
   
   // Leer archivo como texto
   int handle = FileOpen(relPath, FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
   {
      // Archivo no existe, no hay problema
      return(false);
   }
   
   // Leer todas las líneas y guardar las que NO coincidan con ticketMaestro
   string lines[];
   int linesCount = 0;
   bool found = false;
   
   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      if(StringLen(line) == 0) continue;
      
      // Parsear línea: ticket_maestro;ticket_worker;timestamp;symbol;magic
      string parts[];
      int count = StringSplit(line, ';', parts);
      if(count >= 2)
      {
         if(parts[0] == ticketMaestro)
         {
            // Esta línea coincide: NO guardarla (eliminarla)
            found = true;
         }
         else
         {
            // Esta línea NO coincide: guardarla
            ArrayResize(lines, linesCount + 1);
            lines[linesCount] = line;
            linesCount++;
         }
      }
      else
      {
         // Línea inválida: guardarla de todas formas
         ArrayResize(lines, linesCount + 1);
         lines[linesCount] = line;
         linesCount++;
      }
   }
   
   FileClose(handle);
   
   if(!found)
   {
      // No se encontró la línea, no hay nada que hacer
      return(false);
   }
   
   // Reescribir archivo sin la línea eliminada (igual que RewriteQueue)
   handle = FileOpen(relPath, FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(handle == INVALID_HANDLE)
   {
      Print("ERROR: No se pudo reescribir archivo OPEN log: ", relPath, " err=", GetLastError());
      return(false);
   }
   
   // Escribir todas las líneas restantes
   for(int i = 0; i < linesCount; i++)
   {
      FileWrite(handle, lines[i]);
   }
   
   FileClose(handle);
   return(true);
}

//+------------------------------------------------------------------+
//| Ajusta lote fijo a min/max/step del símbolo destino             |
//| SIEMPRE se aplica para proteger las cuentas                     |
//+------------------------------------------------------------------+
double AdjustFixedLots(string symbol, double lot)
{
   double minLot  = MarketInfo(symbol, MODE_MINLOT);
   double maxLot  = MarketInfo(symbol, MODE_MAXLOT);
   double step    = MarketInfo(symbol, MODE_LOTSTEP);
   if(step<=0) step = minLot;
   
   Print("[DEBUG] AdjustFixedLots: symbol=", symbol, " lot entrada=", lot, " MINLOT=", minLot, " MAXLOT=", maxLot, " LOTSTEP=", step);
   
   double lots = lot;
   // Ajustar al step (floor)
   double lotsBeforeStep = lots;
   lots = MathFloor(lots/step)*step;
   if(lots != lotsBeforeStep)
      Print("[DEBUG] AdjustFixedLots: Ajustado al step: ", lotsBeforeStep, " -> ", lots);
   
   // Limitar a mínimo
   if(lots<minLot)
   {
      Print("[WARN] AdjustFixedLots: Lote ", lots, " < MINLOT ", minLot, ", ajustando a MINLOT");
      lots=minLot;
   }
   
   // Limitar a máximo
   if(lots>maxLot)
   {
      Print("[WARN] AdjustFixedLots: Lote ", lots, " > MAXLOT ", maxLot, ", ajustando a MAXLOT");
      lots=maxLot;
   }
   
   // Normalizar decimales según step
   int digits=2;
   double tmp=step;
   int d=0;
   while(tmp<1.0 && d<4)
   {
      tmp*=10.0; d++;
   }
   digits = MathMax(2,d);
   double finalLots = NormalizeDouble(lots,digits);
   
   Print("[DEBUG] AdjustFixedLots: Lote final ajustado = ", finalLots);
   return(finalLots);
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
   FileWrite(h, "worker_exec_time;worker_read_time;resultado;event_type;ticket;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit");
   FileClose(h);
}

//+------------------------------------------------------------------+
//| Añade línea al histórico                                         |
//+------------------------------------------------------------------+
void AppendHistory(const string result, const EventRec &ev, double openPrice=0.0, datetime openTime=0, double closePrice=0.0, datetime closeTime=0, double profit=0.0, long workerReadTimeMs=0, long workerExecTimeMs=0)
{
   EnsureHistoryHeader(g_historyFile);
   int h = FileOpen(g_historyFile, FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
   {
      Print("No se pudo abrir historico: err=", GetLastError());
      return;
   }
   FileSeek(h, 0, SEEK_END);
   int symDigits = (int)MarketInfo(ev.symbol, MODE_DIGITS);
   if(symDigits<=0) symDigits = Digits;
   string sOpenPrice  = (openPrice!=0.0 ? DoubleToString(openPrice, symDigits) : "");
   string sOpenTime   = (openTime>0 ? TimeToString(openTime, TIME_DATE|TIME_SECONDS) : "");
   string sClosePrice = (closePrice!=0.0 ? DoubleToString(closePrice, symDigits) : "");
   string sCloseTime  = (closeTime>0 ? TimeToString(closeTime, TIME_DATE|TIME_SECONDS) : "");
   string sSl = (ev.sl>0 ? DoubleToString(ev.sl, symDigits) : "");
   string sTp = (ev.tp>0 ? DoubleToString(ev.tp, symDigits) : "");
   string sProfit = (closeTime>0 ? DoubleToString(profit, 2) : "");
   string sWorkerReadTime = (workerReadTimeMs>0 ? IntegerToString(workerReadTimeMs) : "");
   string sWorkerExecTime = (workerExecTimeMs>0 ? IntegerToString(workerExecTimeMs) : "");
   string line = sWorkerExecTime + ";" + sWorkerReadTime + ";" + result + ";" + ev.eventType + ";" + ev.ticket + ";" + ev.orderType + ";" +
                 DoubleToString(ev.lots, 2) + ";" + ev.symbol + ";" +
                 sOpenPrice + ";" + sOpenTime + ";" + sSl + ";" + sTp + ";" +
                 sClosePrice + ";" + sCloseTime + ";" + sProfit;
   FileWrite(h, line);
   FileClose(h);
}

//+------------------------------------------------------------------+
//| Busca orden abierta por MagicNumber o Comment (modo híbrido)     |
//+------------------------------------------------------------------+
int FindOpenOrder(const string ticket)
{
   int ticketOrigen = (int)StrToInteger(ticket);
   
   // Modo híbrido: buscar primero por MagicNumber (V3), luego por Comment (V2)
   
   // Paso 1: Buscar por MagicNumber (órdenes nuevas de V3)
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() == ticketOrigen)
         return OrderTicket();
   }
   
   // Paso 2: Si no se encuentra por MagicNumber, buscar por Comment (órdenes antiguas de V2)
   string ticketNormalized = Trim(ticket);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      string orderComment = OrderComment();
      orderComment = Trim(orderComment);
      if(orderComment == ticketNormalized)
         return OrderTicket();
   }
   
   return(-1);
}

//+------------------------------------------------------------------+
//| Busca orden en historial por MagicNumber o Comment (modo híbrido) |
//+------------------------------------------------------------------+
int FindOrderInHistory(const string ticket)
{
   int ticketOrigen = (int)StrToInteger(ticket);
   
   // Modo híbrido: buscar primero por MagicNumber (V3), luego por Comment (V2)
   
   // Paso 1: Buscar por MagicNumber (órdenes nuevas de V3)
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(OrderMagicNumber() == ticketOrigen)
         return OrderTicket();
   }
   
   // Paso 2: Si no se encuentra por MagicNumber, buscar por Comment (órdenes antiguas de V2)
   string ticketNormalized = Trim(ticket);
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      string orderComment = OrderComment();
      orderComment = Trim(orderComment);
      if(orderComment == ticketNormalized)
         return OrderTicket();
   }
   
   return(-1);
}

//+------------------------------------------------------------------+
//| Parseo de línea a EventRec                                       |
//+------------------------------------------------------------------+
bool ParseLine(const string line, EventRec &ev)
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
   string tmp;

   // Campos comunes a todos los eventos
   tmp = Trim(parts[0]); ev.eventType = Upper(tmp);
   ev.ticket = Trim(parts[1]);
   
   // Validación básica: eventType y ticket son siempre requeridos
   if(ev.eventType=="" || ev.ticket=="")
   {
      Print("[ERROR] ParseLine: Campos básicos vacíos. eventType='", ev.eventType, "' ticket='", ev.ticket, "'");
      return(false);
   }
   
   // Inicializar campos opcionales
   ev.orderType = "";
   ev.lots = 0.0;
   ev.symbol = "";
   ev.sl = 0.0;
   ev.tp = 0.0;
   
   // Parsear según el tipo de evento
   if(ev.eventType == "OPEN")
   {
      // OPEN: event_type;ticket;order_type;lots;symbol;sl;tp
      if(n < 5)
      {
         Print("[ERROR] ParseLine: OPEN requiere al menos 5 campos (", n, ")");
         return(false);
      }
      tmp = Trim(parts[2]); ev.orderType = Upper(tmp);
      tmp = Trim(parts[3]); StringReplace(tmp, ",", "."); ev.lots = StrToDouble(tmp);
      tmp = Trim(parts[4]); ev.symbol = Trim(Upper(tmp));
      
      if(n > 5)
      {
         tmp = Trim(parts[5]); 
         if(tmp != "") { StringReplace(tmp, ",", "."); ev.sl = StrToDouble(tmp); }
      }
      
      if(n > 6)
      {
         tmp = Trim(parts[6]); 
         if(tmp != "") { StringReplace(tmp, ",", "."); ev.tp = StrToDouble(tmp); }
      }
      
      // Validar campos requeridos para OPEN
      if(ev.symbol == "" || ev.orderType == "")
      {
         Print("[ERROR] ParseLine: OPEN requiere symbol y orderType. symbol='", ev.symbol, "' orderType='", ev.orderType, "'");
         return(false);
      }
   }
   else if(ev.eventType == "MODIFY")
   {
      // MODIFY: event_type;ticket;;;;;sl_new;tp_new
      if(n > 5)
      {
         tmp = Trim(parts[5]); 
         if(tmp != "") { StringReplace(tmp, ",", "."); ev.sl = StrToDouble(tmp); }
      }
      
      if(n > 6)
      {
         tmp = Trim(parts[6]); 
         if(tmp != "") { StringReplace(tmp, ",", "."); ev.tp = StrToDouble(tmp); }
      }
   }
   else if(ev.eventType == "CLOSE")
   {
      // CLOSE: event_type;ticket;;;;;;
      // No requiere campos adicionales, solo ticket
   }
   else
   {
      Print("[ERROR] ParseLine: Tipo de evento desconocido: '", ev.eventType, "'");
      return(false);
   }
   
   ev.originalLine = line;
   
   Print("[DEBUG] ParseLine: eventType=", ev.eventType, " ticket=", ev.ticket, " symbol=", ev.symbol, " lots=", ev.lots, " sl=", ev.sl, " tp=", ev.tp);
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

   EventSetTimer(InpTimerSeconds);
   Print("Worker inicializado. Cola=", g_queueFile, " Historico=", g_historyFile);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
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
      EventRec ev;
      if(!ParseLine(lines[i], ev))
      {
         // línea inválida: añadir a remaining para reintento
         ArrayResize(remaining, remainingCount+1);
         remaining[remainingCount]=lines[i];
         remainingCount++;
         continue;
      }

      if(ev.eventType=="OPEN")
      {
         Print("[DEBUG] OnTimer: Procesando evento OPEN para ticket=", ev.ticket, " symbol=", ev.symbol, " orderType=", ev.orderType);
         
         // Asegurar símbolo (solo necesario para OPEN)
         Print("[DEBUG] OnTimer: Intentando SymbolSelect para symbol=", ev.symbol);
         if(!SymbolSelect(ev.symbol, true))
         {
            int errCodeSym = GetLastError();
            string errDescSym = ErrorText(errCodeSym);
            string msg = "Ticket: " + ev.ticket + " - OPEN FALLO: SymbolSelect (" + IntegerToString(errCodeSym) + ") " + errDescSym;
            Print("[ERROR] OnTimer: ", msg);
            Notify(msg);
            AppendHistory(msg, ev, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            continue; // OPEN no se reintenta
         }
         Print("[DEBUG] OnTimer: SymbolSelect exitoso para symbol=", ev.symbol);
         
         // Verificar si ya existe una orden abierta con este ticket (evitar duplicados)
         int existingOrder = FindOpenOrder(ev.ticket);
         Print("[DEBUG] OnTimer: FindOpenOrder retornó existingOrder=", existingOrder, " para ticket=", ev.ticket);
         if(existingOrder >= 0)
         {
            Print("[DEBUG] OnTimer: Ya existe orden abierta con ticket=", ev.ticket, " orderTicket=", existingOrder, ", saltando OPEN");
            AppendHistory("Ya existe operacion abierta", ev, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            continue; // Saltar esta línea, no reintentar
         }
         
         // Calcular lotaje (solo para OPEN)
         Print("[DEBUG] OnTimer: Llamando ComputeWorkerLots con symbol=", ev.symbol, " ev.lots=", ev.lots);
         double lotsWorker = ComputeWorkerLots(ev.symbol, ev.lots);
         Print("[DEBUG] OnTimer: lotsWorker calculado = ", lotsWorker);
         
         int type = (ev.orderType=="BUY" ? OP_BUY : OP_SELL);
         double price = (type==OP_BUY ? Ask : Bid);
         int magicOrigen = (int)StrToInteger(ev.ticket);
         Print("[DEBUG] OnTimer: Preparando OrderSend: symbol=", ev.symbol, " type=", type, " lots=", lotsWorker, " price=", price, " sl=", ev.sl, " tp=", ev.tp, " magic=", magicOrigen);
         ResetLastError();
         int ordersTotalBefore = OrdersTotal();
         int ticketNew = OrderSend(ev.symbol, type, lotsWorker, price, InpSlippage, ev.sl, ev.tp, ev.ticket, magicOrigen, 0, clrNONE);
         
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
            string err = "Ticket: " + ev.ticket + " - " + errBase;
            Notify(err);
            // En el histórico dejamos el texto de error base (código + descripción)
            AppendHistory(errBase, ev, 0, 0, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
            // no reintento
         }
         else
         {
            // Verificación inmediata antes de enviar notificación
            string tsVerify = GetTimestampWithMillis();
            bool verifyOK = false;
            int verifyMagicRead = 0;
            bool verifyMagicMatch = false;
            int verifyDelayMs = (int)(GetTickCount() % 1000);
            // magicOrigen ya está declarado arriba, reutilizar
            
            if(OrderSelect(ticketNew, SELECT_BY_TICKET))
            {
               verifyMagicRead = OrderMagicNumber();
               verifyMagicMatch = (verifyMagicRead == magicOrigen);
               verifyOK = true;
               verifyDelayMs = (int)(GetTickCount() % 1000);
            }
            else
            {
               verifyOK = false;
               verifyDelayMs = (int)(GetTickCount() % 1000);
            }
            
            // Construir mensaje con resultado de verificación
            string ok = "Ticket: " + ev.ticket + " - OPEN EXITOSO: " + ev.symbol + " " + ev.orderType + " " + DoubleToString(lotsWorker,2) + " lots";
            if(verifyOK && verifyMagicMatch)
               ok += " VERIFICADO";
            else
               ok += " NO VERIFICADO";
            
            Notify(ok);
            AppendHistory("EXITOSO", ev, 0, 0, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
            
            // Guardar información de OPEN en memoria (con resultados de verificación)
            AddOpenLog(ev, ticketNew, ordersTotalBefore, verifyOK, verifyMagicRead, verifyMagicMatch, verifyDelayMs);
         }
      }
      else if(ev.eventType=="CLOSE")
      {
         int ticketWorker = -1;
         bool foundInMemory = false;
         bool foundInFile = false;
         
         // Paso 1: Buscar en memoria (g_openLogs) - más rápido
         OpenLogInfo openInfo = GetOpenLog(ev.ticket);
         if(openInfo.ticketMaestro != "")
         {
            ticketWorker = openInfo.ticketWorker;
            foundInMemory = true;
         }
         else
         {
            // Paso 2: Buscar en archivo de persistencia
            ticketWorker = ReadOpenLogFromFile(ev.ticket);
            if(ticketWorker >= 0)
            {
               foundInFile = true;
            }
         }
         
         // Si encontramos ticketWorker (memoria o archivo), intentar cerrar directamente
         if(ticketWorker >= 0)
         {
            if(OrderSelect(ticketWorker, SELECT_BY_TICKET))
            {
               // Orden encontrada y seleccionada: cerrar
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
                  
                  string source = (foundInMemory ? "memoria" : "archivo");
                  string ok = "Ticket: " + ev.ticket + " - CLOSE EXITOSO (por ticketWorker desde " + source + "): " + DoubleToString(volume,2) + " lots";
                  Notify(ok);
                  AppendHistory("CLOSE OK", ev, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
                  RemoveTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
                  // Eliminar información de OPEN de memoria y archivo
                  RemoveOpenLog(ev.ticket);
                  RemoveOpenLogFromFile(ev.ticket);
               }
               else
               {
                  // Capturar worker_exec_time después de OrderClose (aunque haya fallado)
                  datetime execTime = TimeCurrent();
                  long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
                  
                  string source = (foundInMemory ? "memoria" : "archivo");
                  string err = "Ticket: " + ev.ticket + " - " + FormatLastError("CLOSE FALLO (por ticketWorker desde " + source + ")");
                  if(!TicketInArray(ev.ticket, g_notifCloseTickets, g_notifCloseCount))
                  {
                     Notify(err);
                     AddTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
                  }
                  AppendHistory(err, ev, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
                  // mantener para reintento (NO eliminar de memoria ni archivo)
                  ArrayResize(remaining, remainingCount+1);
                  remaining[remainingCount]=ev.originalLine;
                  remainingCount++;
               }
            }
            else
            {
               // ticketWorker no existe: verificar si está en historial antes de eliminar
               int historyTicket = FindOrderInHistory(ev.ticket);
               if(historyTicket >= 0)
               {
                  // Encontrada en historial: confirmada cerrada, eliminar
                  AppendHistory("Operacion ya cerrada (en historial)", ev, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
                  RemoveTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
                  RemoveOpenLog(ev.ticket);
                  RemoveOpenLogFromFile(ev.ticket);
               }
               else
               {
                  // No está en historial: podría seguir abierta con otro ticket o el ticketWorker es incorrecto
                  // Buscar por MagicNumber/Comment antes de eliminar
                  int orderTicket = FindOpenOrder(ev.ticket);
                  if(orderTicket >= 0)
                  {
                     // Encontrada por MagicNumber/Comment: el ticketWorker del archivo es incorrecto
                     // Actualizar archivo con el ticket correcto y cerrar
                     if(OrderSelect(orderTicket, SELECT_BY_TICKET))
                     {
                        int type = OrderType();
                        double volume = OrderLots();
                        double closePrice = (type==OP_BUY ? Bid : Ask);
                        double profitBefore = OrderProfit();
                        datetime closeTime = TimeCurrent();
                        
                        if(OrderClose(orderTicket, volume, closePrice, InpSlippage, clrNONE))
                        {
                           datetime execTime = TimeCurrent();
                           long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
                           
                           string ok = "Ticket: " + ev.ticket + " - CLOSE EXITOSO (ticketWorker corregido): " + DoubleToString(volume,2) + " lots";
                           Notify(ok);
                           AppendHistory("CLOSE OK (ticketWorker corregido)", ev, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
                           RemoveTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
                           RemoveOpenLog(ev.ticket);
                           RemoveOpenLogFromFile(ev.ticket);
                        }
                        else
                        {
                           datetime execTime = TimeCurrent();
                           long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
                           
                           string err = "Ticket: " + ev.ticket + " - " + FormatLastError("CLOSE FALLO (ticketWorker corregido)");
                           if(!TicketInArray(ev.ticket, g_notifCloseTickets, g_notifCloseCount))
                           {
                              Notify(err);
                              AddTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
                           }
                           AppendHistory(err, ev, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
                           // mantener para reintento (NO eliminar de memoria ni archivo)
                           ArrayResize(remaining, remainingCount+1);
                           remaining[remainingCount]=ev.originalLine;
                           remainingCount++;
                        }
                     }
                  }
                  else
                  {
                     // No encontrada en ningún lugar: podría ser un error o la orden nunca existió
                     // NO eliminar del archivo todavía, solo alertar
                     string alerta = "ALERTA: Ticket " + ev.ticket + " no encontrado (ticketWorker=" + IntegerToString(ticketWorker) + " invalido)";
                     Notify(alerta);
                     AppendHistory(alerta, ev, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
                     WriteCloseErrorToFile(ev);
                     // NO eliminar del archivo: mantener para investigación
                  }
               }
            }
         }
         else
         {
            // Paso 3: No encontrado en memoria ni archivo, buscar por MagicNumber/Comment (fallback)
            int orderTicket = FindOpenOrder(ev.ticket);
            if(orderTicket >= 0)
            {
               // Encontrada en abiertas: seleccionar y cerrar
               if(!OrderSelect(orderTicket, SELECT_BY_TICKET))
               {
                  AppendHistory(FormatLastError("ERROR: CLOSE select"), ev, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
                  // mantener para reintento
                  ArrayResize(remaining, remainingCount+1);
                  remaining[remainingCount]=ev.originalLine;
                  remainingCount++;
                  continue;
               }
               int type = OrderType();
               double volume = OrderLots();
               double closePrice = (type==OP_BUY ? Bid : Ask);
               double profitBefore = OrderProfit();
               datetime closeTime = TimeCurrent();
               if(OrderClose(orderTicket, volume, closePrice, InpSlippage, clrNONE))
               {
                  // Capturar worker_exec_time después de OrderClose
                  datetime execTime = TimeCurrent();
                  long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
                  
                  string ok = "Ticket: " + ev.ticket + " - CLOSE EXITOSO (por MagicNumber/Comment): " + DoubleToString(volume,2) + " lots";
                  Notify(ok);
                  AppendHistory("CLOSE OK", ev, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
                  RemoveTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
                  // Eliminar información de OPEN de memoria y archivo
                  RemoveOpenLog(ev.ticket);
                  RemoveOpenLogFromFile(ev.ticket);
               }
               else
               {
                  // Capturar worker_exec_time después de OrderClose (aunque haya fallado)
                  datetime execTime = TimeCurrent();
                  long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
                  
                  string err = "Ticket: " + ev.ticket + " - " + FormatLastError("CLOSE FALLO");
                  if(!TicketInArray(ev.ticket, g_notifCloseTickets, g_notifCloseCount))
                  {
                     Notify(err);
                     AddTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
                  }
                  AppendHistory(err, ev, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
                  // mantener para reintento
                  ArrayResize(remaining, remainingCount+1);
                  remaining[remainingCount]=ev.originalLine;
                  remainingCount++;
               }
            }
            else
            {
               // Paso 4: No encontrada en abiertas, buscar en historial (MODE_HISTORY)
               int historyTicket = FindOrderInHistory(ev.ticket);
               if(historyTicket >= 0)
               {
                  // Encontrada en historial: ya está cerrada
                  AppendHistory("Operacion ya esta cerrada", ev, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
                  RemoveTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
                  // Eliminar información de OPEN de memoria y archivo
                  RemoveOpenLog(ev.ticket);
                  RemoveOpenLogFromFile(ev.ticket);
               }
               else
               {
                  // Paso 5: No encontrado en ningún lugar, alerta final
                  string alerta = "ALERTA: Ticket " + ev.ticket + " no encontrado para cerrar";
                  Notify(alerta);
                  AppendHistory(alerta, ev, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
                  
                  // Escribir error detallado en archivo
                  WriteCloseErrorToFile(ev);
                  
                  // Limpiar archivo por si acaso
                  RemoveOpenLogFromFile(ev.ticket);
               }
            }
         }
      }
      else if(ev.eventType=="MODIFY")
      {
         int orderTicket = FindOpenOrder(ev.ticket);
         if(orderTicket<0)
         {
            AppendHistory("No existe operacion abierta", ev, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            RemoveTicket(ev.ticket, g_notifModifyTickets, g_notifModifyCount);
            continue;
         }
         if(!OrderSelect(orderTicket, SELECT_BY_TICKET))
         {
            AppendHistory(FormatLastError("ERROR: MODIFY select"), ev, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            // mantener
            ArrayResize(remaining, remainingCount+1);
            remaining[remainingCount]=ev.originalLine;
            remainingCount++;
            continue;
         }
         double newSL = (ev.sl>0 ? ev.sl : 0.0);
         double newTP = (ev.tp>0 ? ev.tp : 0.0);
         if(OrderModify(orderTicket, OrderOpenPrice(), newSL, newTP, OrderExpiration(), clrNONE))
         {
            // Capturar worker_exec_time después de OrderModify
            datetime execTime = TimeCurrent();
            long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
            
            string ok = "Ticket: " + ev.ticket + " - MODIFY EXITOSO: SL=" + DoubleToString(newSL,2) + " TP=" + DoubleToString(newTP,2);
            Notify(ok);
            string resHist = "MODIFY OK SL=" + DoubleToString(newSL,2) + " TP=" + DoubleToString(newTP,2);
            AppendHistory(resHist, ev, 0, 0, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
            RemoveTicket(ev.ticket, g_notifModifyTickets, g_notifModifyCount);
         }
         else
         {
            // Capturar worker_exec_time después de OrderModify (aunque haya fallado)
            datetime execTime = TimeCurrent();
            long workerExecTimeMs = (long)(execTime * 1000) + (GetTickCount() % 1000);
            
            // Capturar error antes de otras llamadas para no perder el código
            int errCode = GetLastError();
            string errDesc = ErrorText(errCode);
            string errBase = "MODIFY FALLO (" + IntegerToString(errCode) + ") " + errDesc;
            string err = "Ticket: " + ev.ticket + " - " + errBase;
            if(!TicketInArray(ev.ticket, g_notifModifyTickets, g_notifModifyCount))
            {
               Notify(err);
               AddTicket(ev.ticket, g_notifModifyTickets, g_notifModifyCount);
            }
            // mantener para reintento
            AppendHistory(err, ev, 0, 0, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
            ArrayResize(remaining, remainingCount+1);
            remaining[remainingCount]=ev.originalLine;
            remainingCount++;
         }
      }
      // Otros event_type: ignorar
   }

   // Reescribir cola con pendientes
   RewriteQueue(g_queueFile, remaining, remainingCount);
}

//+------------------------------------------------------------------+***

