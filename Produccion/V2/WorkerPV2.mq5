//+------------------------------------------------------------------+
//|                                                   WorkerPV2.mq5  |
//|  Port MQL5 (desde cero) del WorkerPV2.mq4                        |
//|  ARQUITECTURA APPEND-ONLY: Elimina race condition                |
//|  - cola_WORKER_XXX.csv: Solo lectura (Distribuidor escribe)      |
//|  - estados_WORKER_XXX.csv: Solo escritura append (Worker)        |
//|  Lee cola_WORKER_<account>.csv (Common\Files\PROD\Phoenix\V2)     |
//|  Ejecuta OPEN / MODIFY / CLOSE, historiza y notifica             |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"

// -------------------- Inputs --------------------
input bool   InpFondeo        = true;
input double InpLotMultiplier = 3.0;
input double InpFixedLots     = 0.10;  // (no se usa si InpFondeo=false, se mantiene por compatibilidad)
input int    InpSlippage      = 30;    // puntos (compatibilidad con MT4)
input int    InpMagicNumber   = 0;     // (compatibilidad; en V2 el magic es ticketMaster)
input int    InpTimerSeconds  = 1;
// InpSyncSeconds ELIMINADO: El sync periódico causaba inconsistencias en g_openLogs.
// Ahora g_openLogs se mantiene sincronizado fielmente con AddOpenLog/RemoveOpenLog en cada evento.
// Solo se carga desde MT5 en OnInit() al arrancar.
input int    InpThrottleMs    = 200;   // mínimo ms entre procesamientos de cola (OnTick reactivo)

// -------------------- Paths (Common\Files) --------------------
string BASE_SUBDIR   = "PROD\\Phoenix\\V2";
string g_workerId    = "";
string g_queueFile   = "";
string g_estadosFile = "";
string g_erroresFile = "";  // Archivo de errores para trazabilidad

uint     g_lastRunMs    = 0;   // Para throttle de OnTick

// -------------------- Estados procesados (en memoria) --------------------
// Map: key = "ticketMaster_eventType" -> estado (0=pendiente, 1=en proceso, 2=completado)
string g_estadosKeys[];
int    g_estadosValues[];
int    g_estadosCount = 0;

// -------------------- Notif anti-spam --------------------
string g_notifCloseTickets[];
int    g_notifCloseCount  = 0;
string g_notifModifyTickets[];
int    g_notifModifyCount = 0;

// -------------------- Estructura unica en memoria --------------------
struct OpenLogInfo
{
   int      ticketMaster;
   string   ticketMasterSource;
   ulong    ticketWorker;
   long     magicNumber;
   string   symbol;
   long     positionType;
   double   lots;
   double   openPrice;
   datetime openTime;
   double   sl;
   double   tp;
};

OpenLogInfo g_openLogs[];
int g_openLogsCount = 0;

// -------------------- Helpers arrays --------------------
bool TicketInArray(const string ticket, string &arr[], int count)
{
   for(int i=0; i<count; i++)
      if(arr[i] == ticket) return true;
   return false;
}

void AddTicket(const string ticket, string &arr[], int &count)
{
   if(TicketInArray(ticket, arr, count)) return;
   ArrayResize(arr, count+1);
   arr[count] = ticket;
   count++;
}

void RemoveTicket(const string ticket, string &arr[], int &count)
{
   for(int i=0; i<count; i++)
   {
      if(arr[i] == ticket)
      {
         for(int j=i; j<count-1; j++)
            arr[j] = arr[j+1];
         count--;
         ArrayResize(arr, count);
         return;
      }
   }
}

// -------------------- Helpers strings --------------------
string TrimStr(string s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
}

string UpperStr(string s)
{
   StringToUpper(s);
   return s;
}

string LongToStr(const long v)
{
   return IntegerToString(v);
}

// -------------------- Errors / notifications --------------------
string ErrorText(const int code)
{
   switch(code)
   {
      case 0:   return "No error";
      case 1:   return "No error returned";
      case 2:   return "Common error";
      case 3:   return "Invalid trade parameters";
      case 4:   return "Trade server busy";
      case 5:   return "Old terminal version";
      case 6:   return "No connection with trade server";
      case 8:   return "Too frequent requests";
      case 64:  return "Account disabled";
      case 65:  return "Invalid account";
      case 128: return "Trade timeout";
      case 129: return "Invalid price";
      case 130: return "Invalid stop";
      case 131: return "Invalid trade volume";
      case 132: return "Market closed";
      case 133: return "Trade disabled";
      case 134: return "Not enough money";
      case 135: return "Price changed";
      case 136: return "Off quotes";
      case 146: return "Trade subsystem busy";
      case 148: return "Auto trading disabled";
      default:  return "Error code " + IntegerToString(code);
   }
}

string FormatLastError(const string prefix)
{
   int code = GetLastError();
   return prefix + " (" + IntegerToString(code) + ") " + ErrorText(code);
}

void Notify(const string msg)
{
   long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   string full = "W: " + LongToStr(login) + " - " + msg;
   SendNotification(full);
}

// -------------------- UTF-8 helpers (binario) --------------------
string CharFromCode(const ushort ch)
{
   string s = " ";
   StringSetCharacter(s, 0, ch);
   return s;
}

void StringToUTF8Bytes(string str, uchar &bytes[])
{
   ArrayResize(bytes, 0);
   int len = StringLen(str);
   for(int i=0; i<len; i++)
   {
      ushort ch = (ushort)StringGetCharacter(str, i);
      if(ch < 0x80)
      {
         int size = ArraySize(bytes);
         ArrayResize(bytes, size+1);
         bytes[size] = (uchar)ch;
      }
      else if(ch < 0x800)
      {
         int size = ArraySize(bytes);
         ArrayResize(bytes, size+2);
         bytes[size]     = (uchar)(0xC0 | (ch >> 6));
         bytes[size + 1] = (uchar)(0x80 | (ch & 0x3F));
      }
      else
      {
         int size = ArraySize(bytes);
         ArrayResize(bytes, size+3);
         bytes[size]     = (uchar)(0xE0 | (ch >> 12));
         bytes[size + 1] = (uchar)(0x80 | ((ch >> 6) & 0x3F));
         bytes[size + 2] = (uchar)(0x80 | (ch & 0x3F));
      }
   }
}

string UTF8BytesToString(uchar &bytes[], int startPos = 0, int length = -1)
{
   string result = "";
   int size = ArraySize(bytes);
   if(startPos >= size) return "";
   int endPos = (length < 0) ? size : MathMin(startPos + length, size);
   int pos = startPos;

   while(pos < endPos)
   {
      uchar b = bytes[pos];
      if(b == 0) break;

      if(b < 0x80)
      {
         result += CharFromCode((ushort)b);
         pos++;
      }
      else if((b & 0xE0) == 0xC0 && pos + 1 < endPos)
      {
         uchar b2 = bytes[pos+1];
         if((b2 & 0xC0) == 0x80)
         {
            ushort code = ((ushort)(b & 0x1F) << 6) | (b2 & 0x3F);
            result += CharFromCode(code);
            pos += 2;
         }
         else
         {
            result += CharFromCode((ushort)b);
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
            result += CharFromCode(code);
            pos += 3;
         }
         else
         {
            result += CharFromCode((ushort)b);
            pos++;
         }
      }
      else
      {
         result += CharFromCode((ushort)0xFFFD);
         pos++;
      }
   }

   return result;
}

string CommonRelative(const string filename)
{
   return BASE_SUBDIR + "\\" + filename;
}

bool EnsureBaseFolder()
{
   return true;
}

// -------------------- Lot sizing --------------------
double LotFromCapital(double capital, string sym)
{
   int blocks = (int)MathFloor(capital / 1000.0);
   if(blocks < 1) blocks = 1;

   double lot = blocks * 0.01;

   double minLot  = 0.0, maxLot = 0.0, stepLot = 0.0;
   SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN,  minLot);
   SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX,  maxLot);
   SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP, stepLot);

   if(minLot  <= 0.0) minLot  = 0.01;
   if(maxLot  <= 0.0) maxLot  = 100.0;
   if(stepLot <= 0.0) stepLot = 0.01;

   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   int steps = (int)MathFloor((lot - minLot) / stepLot + 1e-9);
   lot = minLot + steps * stepLot;
   lot = NormalizeDouble(lot, 2);

   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

double ComputeWorkerLots(string sym, double masterLots)
{
   if(InpFondeo)
      return masterLots * InpLotMultiplier;
   return LotFromCapital(AccountInfoDouble(ACCOUNT_BALANCE), sym);
}

// -------------------- Memory ops --------------------
int FindOpenLog(const int ticketMaster)
{
   for(int i=0; i<g_openLogsCount; i++)
      if(g_openLogs[i].ticketMaster == ticketMaster)
         return i;
   return -1;
}

void RemoveOpenLog(const int ticketMaster)
{
   int idx = FindOpenLog(ticketMaster);
   if(idx < 0) return;
   for(int j=idx; j<g_openLogsCount-1; j++)
      g_openLogs[j] = g_openLogs[j+1];
   g_openLogsCount--;
   ArrayResize(g_openLogs, g_openLogsCount);
}

void AddOpenLog(OpenLogInfo &log)
{
   ArrayResize(g_openLogs, g_openLogsCount + 1);
   g_openLogs[g_openLogsCount] = log;
   g_openLogsCount++;
}

void UpdateOpenLogSLTP(const int ticketMaster, double slVal, double tpVal)
{
   int idx = FindOpenLog(ticketMaster);
   if(idx < 0) return;
   g_openLogs[idx].sl = slVal;
   g_openLogs[idx].tp = tpVal;
}

// -------------------- Trade helpers (declaradas antes de usarse) --------------------
bool SelectPositionByIndex(const int index)
{
   // PositionGetTicket() ya selecciona automáticamente la posición del índice
   ulong ticket = PositionGetTicket(index);
   return (ticket != 0);
}

bool SendDeal(const string sym, const ENUM_ORDER_TYPE type, const double volume, const double price, const double slVal, const double tpVal, const int magic, const string comment, const ulong positionTicket, MqlTradeResult &res)
{
   MqlTradeRequest req;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action      = TRADE_ACTION_DEAL;
   req.symbol      = sym;
   req.type        = type;
   req.volume      = volume;
   req.price       = price;
   req.deviation   = (uint)InpSlippage;
   req.magic       = magic;
   req.comment     = comment;
   req.type_filling = ORDER_FILLING_IOC;
   req.type_time    = ORDER_TIME_GTC;

   if(slVal > 0.0) req.sl = slVal;
   if(tpVal > 0.0) req.tp = tpVal;
   if(positionTicket > 0) req.position = positionTicket;

   ResetLastError();
   bool ok = OrderSend(req, res);
   return ok;
}

bool SendSLTP(const string sym, const ulong positionTicket, const double slVal, const double tpVal, MqlTradeResult &res)
{
   MqlTradeRequest req;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = sym;
   req.position = positionTicket;
   req.sl = slVal;
   req.tp = tpVal;

   ResetLastError();
   bool ok = OrderSend(req, res);
   return ok;
}

bool EnsureFillingMode(const string sym)
{
   return SymbolSelect(sym, true);
}

// -------------------- Find open position / history by ticketMaster --------------------
ulong FindOpenPosition(const int ticketMaster)
{
   string tm = IntegerToString(ticketMaster);
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(!SelectPositionByIndex(i)) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      string cmt = PositionGetString(POSITION_COMMENT);
      if(magic == ticketMaster || cmt == tm)
         return (ulong)PositionGetInteger(POSITION_TICKET);
   }
   return 0;
}

ulong FindDealInHistory(const int ticketMaster)
{
   string tm = IntegerToString(ticketMaster);
   if(!HistorySelect(0, TimeCurrent()))
      return 0;

   int total = HistoryDealsTotal();
   for(int i=total-1; i>=0; i--)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      long magic = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
      string cmt = HistoryDealGetString(deal, DEAL_COMMENT);
      if(magic == ticketMaster || cmt == tm)
         return deal;
   }
   return 0;
}

// -------------------- Estados procesados --------------------
// Busca estado por key (ticketMaster_eventType)
int FindEstado(const string key)
{
   for(int i=0; i<g_estadosCount; i++)
      if(g_estadosKeys[i] == key)
         return g_estadosValues[i];
   return -1; // No encontrado
}

// Actualiza o añade estado en memoria
void SetEstado(const string key, int estado)
{
   for(int i=0; i<g_estadosCount; i++)
   {
      if(g_estadosKeys[i] == key)
      {
         g_estadosValues[i] = estado;
         return;
      }
   }
   // No existe, añadir
   ArrayResize(g_estadosKeys, g_estadosCount+1);
   ArrayResize(g_estadosValues, g_estadosCount+1);
   g_estadosKeys[g_estadosCount] = key;
   g_estadosValues[g_estadosCount] = estado;
   g_estadosCount++;
}

// Escribe estado a archivo (append-only)
// NOTA: timestamp en milisegundos epoch UTC para trazabilidad precisa
void AppendEstado(int ticketMaster, string eventType, int estado, string resultado, string extra)
{
   string key = IntegerToString(ticketMaster) + "_" + eventType;
   SetEstado(key, estado);
   
   int h = FileOpen(g_estadosFile, FILE_BIN|FILE_READ|FILE_WRITE|FILE_COMMON|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
   {
      // Crear archivo si no existe
      h = FileOpen(g_estadosFile, FILE_BIN|FILE_WRITE|FILE_COMMON);
   }
   else
   {
      FileSeek(h, 0, SEEK_END);
   }
   
   if(h == INVALID_HANDLE)
   {
      Print("ERROR: No se pudo abrir estados: ", g_estadosFile);
      return;
   }
   
   // Timestamp en milisegundos epoch UTC (compatible con Distribuidor Python)
   // TimeGMT() retorna segundos UTC, multiplicamos por 1000 para milisegundos
   long timestampMs = (long)TimeGMT() * 1000;
   string timestamp = LongToStr(timestampMs);
   
   string line = IntegerToString(ticketMaster) + ";" +
                 eventType + ";" +
                 IntegerToString(estado) + ";" +
                 timestamp + ";" +
                 resultado + ";" +
                 extra;
   
   uchar utf8[];
   StringToUTF8Bytes(line, utf8);
   FileWriteArray(h, utf8);
   uchar nl[] = {0x0A};
   FileWriteArray(h, nl);
   FileClose(h);
}

// Escribe error a archivo de errores (append-only) para trazabilidad completa
// Formato: timestamp;ticket_master;magic_number;event_type;error_code;mt5_error;ticketWorker;symbol;detalle
void AppendError(int ticketMaster, int magicNumber, string eventType, string errorCode, int mt5Error, ulong ticketWorker, string symbol, string detalle)
{
   int h = FileOpen(g_erroresFile, FILE_BIN|FILE_READ|FILE_WRITE|FILE_COMMON|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
   {
      // Crear archivo si no existe
      h = FileOpen(g_erroresFile, FILE_BIN|FILE_WRITE|FILE_COMMON);
   }
   else
   {
      FileSeek(h, 0, SEEK_END);
   }
   
   if(h == INVALID_HANDLE)
   {
      Print("ERROR: No se pudo abrir archivo de errores: ", g_erroresFile);
      return;
   }
   
   // Timestamp legible (formato: YYYY.MM.DD HH:MM:SS)
   string timestamp = TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS);
   
   string line = timestamp + ";" +
                 IntegerToString(ticketMaster) + ";" +
                 IntegerToString(magicNumber) + ";" +
                 eventType + ";" +
                 errorCode + ";" +
                 IntegerToString(mt5Error) + ";" +
                 IntegerToString((long)ticketWorker) + ";" +
                 symbol + ";" +
                 detalle;
   
   uchar utf8[];
   StringToUTF8Bytes(line, utf8);
   FileWriteArray(h, utf8);
   uchar nl[] = {0x0A};
   FileWriteArray(h, nl);
   FileClose(h);
   
   // También imprimir en log de MT5 para visibilidad inmediata
   Print("[ERROR] ", eventType, " ticketMaster=", ticketMaster, " magic=", magicNumber, 
         " err=", errorCode, " mt5=", mt5Error, " tw=", ticketWorker, " sym=", symbol, " | ", detalle);
}

// Carga estados desde archivo a memoria
void CargarEstadosProcesados()
{
   // Limpiar memoria
   ArrayResize(g_estadosKeys, 0);
   ArrayResize(g_estadosValues, 0);
   g_estadosCount = 0;
   
   int handle = FileOpen(g_estadosFile, FILE_BIN|FILE_READ|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE) return; // No existe aún
   
   int fileSize = (int)FileSize(handle);
   if(fileSize <= 0)
   {
      FileClose(handle);
      return;
   }
   
   uchar bytes[];
   ArrayResize(bytes, fileSize);
   uint bytesRead = (uint)FileReadArray(handle, bytes, 0, fileSize);
   FileClose(handle);
   if((int)bytesRead != fileSize) return;
   
   // Saltar BOM UTF-8 si existe
   int bomSkip = 0;
   if(fileSize >= 3 && bytes[0]==0xEF && bytes[1]==0xBB && bytes[2]==0xBF)
      bomSkip = 3;
   
   int lineStart = bomSkip;
   while(lineStart < fileSize)
   {
      int lineEnd = lineStart;
      for(int i=lineStart; i<fileSize; i++)
      {
         if(bytes[i]==0x0A || bytes[i]==0x0D || bytes[i]==0)
         {
            lineEnd = i;
            break;
         }
      }
      if(lineEnd > lineStart)
      {
         uchar lineBytes[];
         ArrayResize(lineBytes, lineEnd - lineStart);
         ArrayCopy(lineBytes, bytes, 0, lineStart, lineEnd - lineStart);
         string ln = UTF8BytesToString(lineBytes);
         
         // Parsear línea: ticketMaster;eventType;estado;timestamp;resultado;extra
         if(StringLen(ln) > 0)
         {
            string parts[];
            int n = StringSplit(ln, ';', parts);
            if(n >= 3)
            {
               string ticketStr = TrimStr(parts[0]);
               string evtType = TrimStr(parts[1]);
               int estado = (int)StringToInteger(TrimStr(parts[2]));
               
               string key = ticketStr + "_" + evtType;
               SetEstado(key, estado); // Último estado prevalece
            }
         }
      }
      lineStart = lineEnd;
      if(lineStart < fileSize)
      {
         if(bytes[lineStart]==0x0D && lineStart+1<fileSize && bytes[lineStart+1]==0x0A)
            lineStart += 2;
         else if(bytes[lineStart]==0x0A || bytes[lineStart]==0x0D)
            lineStart++;
      }
   }
}

// Reconstruye arrays de reintentos desde estados (estado=1)
void ReconstruirReintentosDesdeEstados()
{
   // Limpiar arrays de reintentos
   ArrayResize(g_notifCloseTickets, 0);
   g_notifCloseCount = 0;
   ArrayResize(g_notifModifyTickets, 0);
   g_notifModifyCount = 0;
   
   for(int i=0; i<g_estadosCount; i++)
   {
      if(g_estadosValues[i] == 1) // En proceso = necesita reintento
      {
         string key = g_estadosKeys[i];
         // Extraer ticketMaster y eventType del key "ticketMaster_eventType"
         int sep = StringFind(key, "_");
         if(sep > 0)
         {
            string ticketStr = StringSubstr(key, 0, sep);
            string evtType = StringSubstr(key, sep + 1);
            
            if(evtType == "CLOSE")
               AddTicket(ticketStr, g_notifCloseTickets, g_notifCloseCount);
            else if(evtType == "MODIFY")
               AddTicket(ticketStr, g_notifModifyTickets, g_notifModifyCount);
         }
      }
   }
   
   if(g_notifCloseCount > 0 || g_notifModifyCount > 0)
   {
      Print("WorkerPV2: Reconstruidos reintentos - CLOSE:", g_notifCloseCount, " MODIFY:", g_notifModifyCount);
   }
}

// -------------------- Queue I/O (solo lectura) --------------------
int ReadQueue(const string relPath, string &lines[])
{
   int handle = FileOpen(relPath, FILE_BIN|FILE_READ|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE) return 0;

   int fileSize = (int)FileSize(handle);
   if(fileSize <= 0)
   {
      FileClose(handle);
      return 0;
   }

   uchar bytes[];
   ArrayResize(bytes, fileSize);
   uint bytesRead = (uint)FileReadArray(handle, bytes, 0, fileSize);
   FileClose(handle);
   if((int)bytesRead != fileSize) return 0;

   int bomSkip = 0;
   if(fileSize >= 3 && bytes[0]==0xEF && bytes[1]==0xBB && bytes[2]==0xBF)
      bomSkip = 3;

   int count = 0;
   int lineStart = bomSkip;
   while(lineStart < fileSize)
   {
      int lineEnd = lineStart;
      for(int i=lineStart; i<fileSize; i++)
      {
         if(bytes[i]==0x0A || bytes[i]==0x0D || bytes[i]==0)
         {
            lineEnd = i;
            break;
         }
      }
      if(lineEnd > lineStart)
      {
         uchar lineBytes[];
         ArrayResize(lineBytes, lineEnd - lineStart);
         ArrayCopy(lineBytes, bytes, 0, lineStart, lineEnd - lineStart);
         string ln = UTF8BytesToString(lineBytes);
         if(StringLen(ln) > 0)
         {
            ArrayResize(lines, count+1);
            lines[count] = ln;
            count++;
         }
      }
      lineStart = lineEnd;
      if(lineStart < fileSize)
      {
         if(bytes[lineStart]==0x0D && lineStart+1<fileSize && bytes[lineStart+1]==0x0A)
            lineStart += 2;
         else if(bytes[lineStart]==0x0A || bytes[lineStart]==0x0D)
            lineStart++;
      }
   }
   return count;
}

// -------------------- Chart display --------------------
void DeleteObjectsByPrefix(const long chartId, const string prefix)
{
   int total = ObjectsTotal(chartId, 0, -1);
   for(int i=total-1; i>=0; i--)
   {
      string name = ObjectName(chartId, i, 0, -1);
      if(StringLen(name) == 0) continue;
      if(StringFind(name, prefix) == 0)
         ObjectDelete(chartId, name);
   }
}

void DisplayOpenLogsInChart()
{
   DeleteObjectsByPrefix(0, "WorkerPV2_Label_");

   int y = 20;
   int lineH = 14;

   string title = "WorkerPV2 - POSICIONES EN MEMORIA";
   string titleName = "WorkerPV2_Label_Title";
   ObjectCreate(0, titleName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, titleName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, titleName, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, titleName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, titleName, OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, titleName, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, titleName, OBJPROP_TEXT, title);
   y += lineH;

   for(int i=0; i<g_openLogsCount; i++)
   {
      string labelName = "WorkerPV2_Label_" + IntegerToString(i);
      string text = "TM: " + IntegerToString(g_openLogs[i].ticketMaster) +
                    " (source=" + g_openLogs[i].ticketMasterSource + ")" +
                    " || TW: " + LongToStr((long)g_openLogs[i].ticketWorker) +
                    " || MN: " + LongToStr(g_openLogs[i].magicNumber) +
                    " || SYMBOL: " + g_openLogs[i].symbol;
      ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, labelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, labelName, OBJPROP_TEXT, text);
      y += lineH;
   }

   string summaryName = "WorkerPV2_Label_Summary";
   string summaryText = "Total: " + IntegerToString(g_openLogsCount) + " posiciones";
   ObjectCreate(0, summaryName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, summaryName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, summaryName, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, summaryName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, summaryName, OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, summaryName, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, summaryName, OBJPROP_TEXT, summaryText);
}

// -------------------- Parse --------------------
bool ParseLine(const string line, string &eventType, int &ticketMaster, string &orderTypeStr, double &lots, string &sym, double &slVal, double &tpVal)
{
   string parts[];
   int n = StringSplit(line, ';', parts);
   if(n < 2) return false;

   string p0 = parts[0];
   string p1 = parts[1];
   eventType = UpperStr(TrimStr(p0));
   ticketMaster = (int)StringToInteger(TrimStr(p1));
   orderTypeStr = "";
   lots = 0.0;
   sym = "";
   slVal = 0.0;
   tpVal = 0.0;

   if(eventType == "" || ticketMaster <= 0) return false;

   if(eventType == "OPEN")
   {
      if(n < 5) return false;
      string p2 = parts[2];
      string p3 = parts[3];
      string p4 = parts[4];
      orderTypeStr = UpperStr(TrimStr(p2));
      string lotsStr = TrimStr(p3);
      StringReplace(lotsStr, ",", ".");
      lots = StringToDouble(lotsStr);
      sym = UpperStr(TrimStr(p4));
      if(n > 5)
      {
         string p5 = parts[5];
         string s5 = TrimStr(p5);
         StringReplace(s5, ",", ".");
         if(s5 != "") slVal = StringToDouble(s5);
      }
      if(n > 6)
      {
         string p6 = parts[6];
         string s6 = TrimStr(p6);
         StringReplace(s6, ",", ".");
         if(s6 != "") tpVal = StringToDouble(s6);
      }
      if(sym == "" || (orderTypeStr != "BUY" && orderTypeStr != "SELL")) return false;
      return true;
   }
   if(eventType == "MODIFY")
   {
      if(n < 4) return false;
      string p2 = parts[2];
      string p3 = parts[3];
      string s2 = TrimStr(p2);
      string s3 = TrimStr(p3);
      StringReplace(s2, ",", ".");
      StringReplace(s3, ",", ".");
      if(s2 == "" && s3 == "") return false;
      if(s2 != "") slVal = StringToDouble(s2);
      if(s3 != "") tpVal = StringToDouble(s3);
      return true;
   }
   if(eventType == "CLOSE")
   {
      return true;
   }

   return false;
}

// -------------------- Load open positions --------------------
void LoadOpenPositionsFromMT5()
{
   ArrayResize(g_openLogs, 0);
   g_openLogsCount = 0;

   int total = PositionsTotal();
   for(int i=0; i<total; i++)
   {
      if(!SelectPositionByIndex(i)) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      string cmt = TrimStr(PositionGetString(POSITION_COMMENT));

      int tm = 0;
      string source = "";
      if(magic > 0)
      {
         tm = (int)magic;
         source = "MAGIC";
      }
      else
      {
         int cmtId = (int)StringToInteger(cmt);
         if(cmtId > 0)
         {
            tm = cmtId;
            source = "COMMENT";
         }
         else
         {
            tm = (int)PositionGetInteger(POSITION_TICKET);
            source = "POSITION_TICKET";
         }
      }

      OpenLogInfo log;
      log.ticketMaster       = tm;
      log.ticketMasterSource = source;
      log.ticketWorker       = (ulong)PositionGetInteger(POSITION_TICKET);
      log.magicNumber        = magic;
      log.symbol             = PositionGetString(POSITION_SYMBOL);
      log.positionType       = PositionGetInteger(POSITION_TYPE);
      log.lots               = PositionGetDouble(POSITION_VOLUME);
      log.openPrice          = PositionGetDouble(POSITION_PRICE_OPEN);
      log.openTime           = (datetime)PositionGetInteger(POSITION_TIME);
      log.sl                 = PositionGetDouble(POSITION_SL);
      log.tp                 = PositionGetDouble(POSITION_TP);

      AddOpenLog(log);
   }
}

// -------------------- Throttle (para OnTick reactivo) --------------------
bool Throttled()
{
   uint nowMs = GetTickCount();
   if(InpThrottleMs <= 0)
   {
      g_lastRunMs = nowMs;
      return false;
   }
   uint elapsed = nowMs - g_lastRunMs; // wrap-safe en unsigned
   if(elapsed < (uint)InpThrottleMs) return true;
   g_lastRunMs = nowMs;
   return false;
}

// -------------------- Lifecycle --------------------
int OnInit()
{
   g_workerId    = LongToStr((long)AccountInfoInteger(ACCOUNT_LOGIN));
   g_queueFile   = CommonRelative("cola_WORKER_" + g_workerId + ".csv");
   g_estadosFile = CommonRelative("estados_WORKER_" + g_workerId + ".csv");
   g_erroresFile = CommonRelative("errores_WORKER_" + g_workerId + ".csv");

   if(!EnsureBaseFolder()) return INIT_FAILED;

   // 1. Cargar posiciones abiertas de MT5
   LoadOpenPositionsFromMT5();
   
   // 2. Cargar estados procesados y reconstruir reintentos
   CargarEstadosProcesados();
   ReconstruirReintentosDesdeEstados();
   
   DisplayOpenLogsInChart();

   EventSetTimer(InpTimerSeconds);
   Print("WorkerPV2 (MQL5) inicializado. Cola=", g_queueFile, " Estados=", g_estadosFile, " Posiciones=", g_openLogsCount);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteObjectsByPrefix(0, "WorkerPV2_Label_");
}

void OnTick()
{
   if(Throttled()) return;
   ProcessQueue();
}

void OnTimer()
{
   if(Throttled()) return;
   ProcessQueue();
}

void ProcessQueue()
{
   // 1. Si existe .lck, es purga nocturna → salir
   string lockFile = g_queueFile + ".lck";
   if(FileIsExist(lockFile, FILE_COMMON))
   {
      Print("WorkerPV2: Purga nocturna en curso (.lck detectado), esperando...");
      return;
   }

   // NOTA: El sync periódico fue ELIMINADO. g_openLogs se mantiene sincronizado
   // fielmente mediante AddOpenLog/RemoveOpenLog en cada OPEN/CLOSE procesado.
   // Solo se carga desde MT5 en OnInit() al arrancar.

   // 2. Cargar estados procesados en memoria
   CargarEstadosProcesados();

   string lines[];
   int total = ReadQueue(g_queueFile, lines);
   if(total <= 0) return;

   int startIdx = 0;
   if(total > 0)
   {
      string firstLower = lines[0];
      StringToLower(firstLower);
      if(StringFind(firstLower, "event_type") >= 0) startIdx = 1;
   }

   for(int i=startIdx; i<total; i++)
   {
      string eventType;
      int ticketMaster;
      string orderTypeStr;
      double lots;
      string sym;
      double slVal;
      double tpVal;

      if(!ParseLine(lines[i], eventType, ticketMaster, orderTypeStr, lots, sym, slVal, tpVal))
         continue;

      // Construir key para buscar estado
      string key = IntegerToString(ticketMaster) + "_" + eventType;
      int estadoActual = FindEstado(key);

      // Si ya completado (estado=2), saltar
      if(estadoActual == 2)
         continue;

      if(eventType == "OPEN")
      {
         if(!EnsureFillingMode(sym))
         {
            int errCode = GetLastError();
            string msg = "SymbolSelect failed: " + ErrorText(errCode);
            Notify("Ticket: " + IntegerToString(ticketMaster) + " - OPEN FALLO: " + msg);
            AppendEstado(ticketMaster, "OPEN", 2, "ERR_SYMBOL", msg);
            AppendError(ticketMaster, ticketMaster, "OPEN", "ERR_SYMBOL", errCode, 0, sym, msg);
            continue;
         }

         ulong existing = FindOpenPosition(ticketMaster);
         if(existing > 0)
         {
            AppendEstado(ticketMaster, "OPEN", 2, "OK_YA_EXISTE", LongToStr((long)existing));
            continue;
         }

         double lotsWorker = ComputeWorkerLots(sym, lots);
         ENUM_ORDER_TYPE type = (orderTypeStr == "BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

         MqlTick tick;
         if(!SymbolInfoTick(sym, tick))
         {
            int err = GetLastError();
            string errBase = "SymbolInfoTick failed: " + ErrorText(err);
            Notify("Ticket: " + IntegerToString(ticketMaster) + " - OPEN FALLO: " + errBase);
            AppendEstado(ticketMaster, "OPEN", 2, "ERR_TICK", errBase);
            AppendError(ticketMaster, ticketMaster, "OPEN", "ERR_TICK", err, 0, sym, errBase);
            continue;
         }

         double price = (type == ORDER_TYPE_BUY ? tick.ask : tick.bid);
         string commentStr = IntegerToString(ticketMaster);

         MqlTradeResult res;
         bool ok = SendDeal(sym, type, lotsWorker, price, slVal, tpVal, ticketMaster, commentStr, 0, res);

         if(!ok || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED))
         {
            int err = GetLastError();
            string errBase = "SendDeal failed: " + ErrorText(err) + " retcode=" + IntegerToString((int)res.retcode);
            Notify("Ticket: " + IntegerToString(ticketMaster) + " - OPEN FALLO: " + errBase);
            AppendEstado(ticketMaster, "OPEN", 2, "ERR_" + IntegerToString(err), errBase);
            AppendError(ticketMaster, ticketMaster, "OPEN", "ERR_SEND", err, 0, sym, errBase);
            continue;
         }

         ulong posTicket = FindOpenPosition(ticketMaster);
         if(posTicket > 0 && PositionSelectByTicket(posTicket))
         {
            OpenLogInfo log;
            log.ticketMaster       = ticketMaster;
            log.ticketMasterSource = "MAGIC";
            log.ticketWorker       = posTicket;
            log.magicNumber        = (long)ticketMaster;
            log.symbol             = PositionGetString(POSITION_SYMBOL);
            log.positionType       = PositionGetInteger(POSITION_TYPE);
            log.lots               = PositionGetDouble(POSITION_VOLUME);
            log.openPrice          = PositionGetDouble(POSITION_PRICE_OPEN);
            log.openTime           = (datetime)PositionGetInteger(POSITION_TIME);
            log.sl                 = PositionGetDouble(POSITION_SL);
            log.tp                 = PositionGetDouble(POSITION_TP);

            AddOpenLog(log);
            DisplayOpenLogsInChart();

            AppendEstado(ticketMaster, "OPEN", 2, "OK", LongToStr((long)posTicket));
         }
         else
         {
            AppendEstado(ticketMaster, "OPEN", 2, "OK", "");
         }
      }
      else if(eventType == "MODIFY")
      {
         int idx = FindOpenLog(ticketMaster);
         if(idx < 0)
         {
            AppendEstado(ticketMaster, "MODIFY", 2, "ERR_NO_ENCONTRADA", "");
            AppendError(ticketMaster, ticketMaster, "MODIFY", "ERR_NO_ENCONTRADA", 0, 0, "", "Posicion no encontrada en g_openLogs");
            continue;
         }

         ulong ticketWorker = g_openLogs[idx].ticketWorker;
         string symLog = g_openLogs[idx].symbol;
         long magicLog = g_openLogs[idx].magicNumber;

         if(!PositionSelectByTicket(ticketWorker))
         {
            RemoveOpenLog(ticketMaster);
            DisplayOpenLogsInChart();
            AppendEstado(ticketMaster, "MODIFY", 2, "ERR_YA_CERRADA", "");
            AppendError(ticketMaster, (int)magicLog, "MODIFY", "ERR_YA_CERRADA", 0, ticketWorker, symLog, "PositionSelectByTicket failed - posicion no existe");
            RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
            continue;
         }

         double newSL = (slVal > 0 ? slVal : 0.0);
         double newTP = (tpVal > 0 ? tpVal : 0.0);

         MqlTradeResult res;
         bool ok = SendSLTP(symLog, ticketWorker, newSL, newTP, res);

         if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL))
         {
            UpdateOpenLogSLTP(ticketMaster, newSL, newTP);
            DisplayOpenLogsInChart();
            string resTxt = "MODIFY OK SL=" + DoubleToString(newSL, 2) + " TP=" + DoubleToString(newTP, 2);
            AppendEstado(ticketMaster, "MODIFY", 2, "OK", "");
            RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
         }
         else
         {
            ulong historyDeal = FindDealInHistory(ticketMaster);
            if(historyDeal > 0)
            {
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendEstado(ticketMaster, "MODIFY", 2, "ERR_YA_CERRADA", "");
               AppendError(ticketMaster, (int)magicLog, "MODIFY", "ERR_YA_CERRADA", 0, ticketWorker, symLog, "SendSLTP failed pero posicion en historial");
               RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
            }
            else
            {
               int err = GetLastError();
               string errTxt = "SendSLTP failed: " + ErrorText(err) + " retcode=" + IntegerToString((int)res.retcode);
               AppendError(ticketMaster, (int)magicLog, "MODIFY", "RETRY", err, ticketWorker, symLog, errTxt);
               
               // Si es primer intento (estado != 1), marcar como en proceso
               if(estadoActual != 1)
               {
                  AppendEstado(ticketMaster, "MODIFY", 1, "RETRY", "ERR_" + IntegerToString(err));
                  if(!TicketInArray(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount))
                  {
                     Notify("Ticket: " + IntegerToString(ticketMaster) + " - " + errTxt);
                     AddTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
                  }
               }
            }
         }
      }
      else if(eventType == "CLOSE")
      {
         int idx = FindOpenLog(ticketMaster);
         if(idx < 0)
         {
            ulong historyDeal = FindDealInHistory(ticketMaster);
            if(historyDeal > 0)
            {
               AppendEstado(ticketMaster, "CLOSE", 2, "OK_YA_CERRADA", "");
            }
            else
            {
               AppendEstado(ticketMaster, "CLOSE", 2, "ERR_NO_ENCONTRADA", "");
               AppendError(ticketMaster, ticketMaster, "CLOSE", "ERR_NO_ENCONTRADA", 0, 0, "", "Posicion no encontrada en g_openLogs ni historial");
            }
            continue;
         }

         ulong ticketWorker = g_openLogs[idx].ticketWorker;
         string symLog = g_openLogs[idx].symbol;
         long magicLog = g_openLogs[idx].magicNumber;

         if(!PositionSelectByTicket(ticketWorker))
         {
            ulong historyDeal = FindDealInHistory(ticketMaster);
            if(historyDeal > 0)
            {
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendEstado(ticketMaster, "CLOSE", 2, "OK_YA_CERRADA", "");
               RemoveTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            }
            else
            {
               AppendEstado(ticketMaster, "CLOSE", 2, "ERR_NO_ENCONTRADA", "");
               AppendError(ticketMaster, (int)magicLog, "CLOSE", "ERR_NO_ENCONTRADA", 0, ticketWorker, symLog, "PositionSelectByTicket failed y no en historial");
            }
            continue;
         }

         long posType = PositionGetInteger(POSITION_TYPE);
         double volume = PositionGetDouble(POSITION_VOLUME);
         double profitBefore = PositionGetDouble(POSITION_PROFIT);

         MqlTick tick;
         if(!SymbolInfoTick(symLog, tick))
         {
            int err = GetLastError();
            string errTxt = "SymbolInfoTick failed: " + ErrorText(err);
            AppendError(ticketMaster, (int)magicLog, "CLOSE", "RETRY_TICK", err, ticketWorker, symLog, errTxt);
            
            // Si es primer intento (estado != 1), marcar como en proceso
            if(estadoActual != 1)
            {
               AppendEstado(ticketMaster, "CLOSE", 1, "RETRY", "ERR_" + IntegerToString(err));
               if(!TicketInArray(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount))
               {
                  Notify("Ticket: " + IntegerToString(ticketMaster) + " - " + errTxt);
                  AddTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
               }
            }
            continue;
         }

         ENUM_ORDER_TYPE closeType = (posType == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
         double closePrice = (closeType == ORDER_TYPE_BUY ? tick.ask : tick.bid);

         MqlTradeResult res;
         bool ok = SendDeal(symLog, closeType, volume, closePrice, 0.0, 0.0, (int)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_COMMENT), ticketWorker, res);

         if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL))
         {
            AppendEstado(ticketMaster, "CLOSE", 2, "OK", DoubleToString(profitBefore, 2));
            RemoveTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            RemoveOpenLog(ticketMaster);
            DisplayOpenLogsInChart();
         }
         else
         {
            ulong historyDeal = FindDealInHistory(ticketMaster);
            if(historyDeal > 0)
            {
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendEstado(ticketMaster, "CLOSE", 2, "OK_YA_CERRADA", "");
               RemoveTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            }
            else
            {
               int err = GetLastError();
               string errTxt = "SendDeal(CLOSE) failed: " + ErrorText(err) + " retcode=" + IntegerToString((int)res.retcode);
               AppendError(ticketMaster, (int)magicLog, "CLOSE", "RETRY_SEND", err, ticketWorker, symLog, errTxt);
               
               // Si es primer intento (estado != 1), marcar como en proceso
               if(estadoActual != 1)
               {
                  AppendEstado(ticketMaster, "CLOSE", 1, "RETRY", "ERR_" + IntegerToString(err));
                  if(!TicketInArray(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount))
                  {
                     Notify("Ticket: " + IntegerToString(ticketMaster) + " - " + errTxt);
                     AddTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
                  }
               }
            }
         }
      }
   }
   
   // NOTA: Ya NO hay RewriteQueue ni merge defensivo.
   // La cola es append-only (Distribuidor) y los estados son append-only (Worker).
   // La purga nocturna del Distribuidor limpiará ambos archivos.
}


