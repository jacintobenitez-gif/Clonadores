//+------------------------------------------------------------------+
//|                                                   WorkerPV2.mq4  |
//|  Clon MQL4 del WorkerPV2.mq5                                     |
//|  ARQUITECTURA APPEND-ONLY: Elimina race condition                |
//|  - cola_WORKER_XXX.csv: Solo lectura (Distribuidor escribe)      |
//|  - estados_WORKER_XXX.csv: Solo escritura append (Worker)        |
//|  Lee cola_WORKER_<account>.csv (Common\Files\PROD\Phoenix\V2)    |
//|  Ejecuta OPEN / MODIFY / CLOSE, historiza y notifica             |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"

// -------------------- Inputs --------------------
input bool   InpFondeo        = true;
input double InpLotMultiplier = 1.0;
input double InpFixedLots     = 0.10;
input int    InpSlippage      = 30;
input int    InpMagicNumber   = 0;     // (compatibilidad; en V2 el magic es ticketMaster)
input int    InpTimerSeconds  = 1;
input int    InpThrottleMs    = 200;

// -------------------- Paths (Common\Files) --------------------
string BASE_SUBDIR   = "PROD\\Phoenix\\V2";
string g_workerId    = "";
string g_queueFile   = "";
string g_estadosFile = "";
string g_erroresFile = "";

uint   g_lastRunMs   = 0;

// -------------------- Estados procesados (en memoria) --------------------
string g_estadosKeys[];
int    g_estadosValues[];
int    g_estadosCount = 0;

// -------------------- Notif anti-spam --------------------
string g_notifCloseTickets[];
int    g_notifCloseCount  = 0;
string g_notifModifyTickets[];
int    g_notifModifyCount = 0;

// -------------------- Estructura en memoria (arrays paralelos) --------------------
int      g_logTicketMaster[];
string   g_logTicketMasterSource[];
int      g_logTicketWorker[];
int      g_logMagicNumber[];
string   g_logSymbol[];
int      g_logOrderType[];
double   g_logLots[];
double   g_logOpenPrice[];
datetime g_logOpenTime[];
double   g_logSL[];
double   g_logTP[];
int      g_openLogsCount = 0;

// -------------------- Helpers arrays --------------------
bool TicketInArray(string ticket, string &arr[], int count)
{
   for(int i=0; i<count; i++)
      if(arr[i] == ticket) return true;
   return false;
}

void AddTicket(string ticket, string &arr[], int &count)
{
   if(TicketInArray(ticket, arr, count)) return;
   ArrayResize(arr, count+1);
   arr[count] = ticket;
   count++;
}

void RemoveTicket(string ticket, string &arr[], int &count)
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

// -------------------- Errors / notifications --------------------
string ErrorText(int code)
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

void Notify(string msg)
{
   string full = "W: " + IntegerToString(AccountNumber()) + " - " + msg;
   SendNotification(full);
}

// -------------------- UTF-8 helpers --------------------
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
         result += CharToString((uchar)b);
         pos++;
      }
      else if((b & 0xE0) == 0xC0 && pos + 1 < endPos)
      {
         uchar b2 = bytes[pos+1];
         if((b2 & 0xC0) == 0x80)
         {
            ushort code = ((ushort)(b & 0x1F) << 6) | (b2 & 0x3F);
            result += CharToString((uchar)code);
            pos += 2;
         }
         else
         {
            result += CharToString((uchar)b);
            pos++;
         }
      }
      else if((b & 0xF0) == 0xE0 && pos + 2 < endPos)
      {
         pos += 3;
      }
      else
      {
         pos++;
      }
   }
   return result;
}

string CommonRelative(string filename)
{
   return BASE_SUBDIR + "\\" + filename;
}

// -------------------- Lot sizing --------------------
double LotFromCapital(double capital, string sym)
{
   int blocks = (int)MathFloor(capital / 1000.0);
   if(blocks < 1) blocks = 1;

   double lot = blocks * 0.01;
   double minLot  = MarketInfo(sym, MODE_MINLOT);
   double maxLot  = MarketInfo(sym, MODE_MAXLOT);
   double stepLot = MarketInfo(sym, MODE_LOTSTEP);

   if(minLot  <= 0.0) minLot  = 0.01;
   if(maxLot  <= 0.0) maxLot  = 100.0;
   if(stepLot <= 0.0) stepLot = 0.01;

   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   int steps = (int)MathFloor((lot - minLot) / stepLot + 1e-9);
   lot = minLot + steps * stepLot;
   lot = NormalizeDouble(lot, 2);

   return lot;
}

double ComputeWorkerLots(string sym, double masterLots)
{
   if(InpFondeo)
      return masterLots * InpLotMultiplier;
   return LotFromCapital(AccountBalance(), sym);
}

// -------------------- Memory ops (arrays paralelos) --------------------
int FindOpenLog(int ticketMaster)
{
   for(int i=0; i<g_openLogsCount; i++)
      if(g_logTicketMaster[i] == ticketMaster)
         return i;
   return -1;
}

void RemoveOpenLog(int ticketMaster)
{
   int idx = FindOpenLog(ticketMaster);
   if(idx < 0) return;
   
   for(int j=idx; j<g_openLogsCount-1; j++)
   {
      g_logTicketMaster[j]       = g_logTicketMaster[j+1];
      g_logTicketMasterSource[j] = g_logTicketMasterSource[j+1];
      g_logTicketWorker[j]       = g_logTicketWorker[j+1];
      g_logMagicNumber[j]        = g_logMagicNumber[j+1];
      g_logSymbol[j]             = g_logSymbol[j+1];
      g_logOrderType[j]          = g_logOrderType[j+1];
      g_logLots[j]               = g_logLots[j+1];
      g_logOpenPrice[j]          = g_logOpenPrice[j+1];
      g_logOpenTime[j]           = g_logOpenTime[j+1];
      g_logSL[j]                 = g_logSL[j+1];
      g_logTP[j]                 = g_logTP[j+1];
   }
   g_openLogsCount--;
   
   ArrayResize(g_logTicketMaster, g_openLogsCount);
   ArrayResize(g_logTicketMasterSource, g_openLogsCount);
   ArrayResize(g_logTicketWorker, g_openLogsCount);
   ArrayResize(g_logMagicNumber, g_openLogsCount);
   ArrayResize(g_logSymbol, g_openLogsCount);
   ArrayResize(g_logOrderType, g_openLogsCount);
   ArrayResize(g_logLots, g_openLogsCount);
   ArrayResize(g_logOpenPrice, g_openLogsCount);
   ArrayResize(g_logOpenTime, g_openLogsCount);
   ArrayResize(g_logSL, g_openLogsCount);
   ArrayResize(g_logTP, g_openLogsCount);
}

void AddOpenLog(int ticketMaster, string source, int ticketWorker, int magic, string sym, int orderType, double lots, double price, datetime openTime, double sl, double tp)
{
   int idx = g_openLogsCount;
   g_openLogsCount++;
   
   ArrayResize(g_logTicketMaster, g_openLogsCount);
   ArrayResize(g_logTicketMasterSource, g_openLogsCount);
   ArrayResize(g_logTicketWorker, g_openLogsCount);
   ArrayResize(g_logMagicNumber, g_openLogsCount);
   ArrayResize(g_logSymbol, g_openLogsCount);
   ArrayResize(g_logOrderType, g_openLogsCount);
   ArrayResize(g_logLots, g_openLogsCount);
   ArrayResize(g_logOpenPrice, g_openLogsCount);
   ArrayResize(g_logOpenTime, g_openLogsCount);
   ArrayResize(g_logSL, g_openLogsCount);
   ArrayResize(g_logTP, g_openLogsCount);
   
   g_logTicketMaster[idx]       = ticketMaster;
   g_logTicketMasterSource[idx] = source;
   g_logTicketWorker[idx]       = ticketWorker;
   g_logMagicNumber[idx]        = magic;
   g_logSymbol[idx]             = sym;
   g_logOrderType[idx]          = orderType;
   g_logLots[idx]               = lots;
   g_logOpenPrice[idx]          = price;
   g_logOpenTime[idx]           = openTime;
   g_logSL[idx]                 = sl;
   g_logTP[idx]                 = tp;
}

void UpdateOpenLogSLTP(int ticketMaster, double slVal, double tpVal)
{
   int idx = FindOpenLog(ticketMaster);
   if(idx < 0) return;
   g_logSL[idx] = slVal;
   g_logTP[idx] = tpVal;
}

// -------------------- Find in history (MQL4) --------------------
int FindOrderInHistory(int ticketMaster)
{
   string tm = IntegerToString(ticketMaster);
   int total = OrdersHistoryTotal();
   for(int i=total-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber() == ticketMaster || OrderComment() == tm)
         return OrderTicket();
   }
   return 0;
}

// -------------------- Estados procesados --------------------
int FindEstado(string key)
{
   for(int i=0; i<g_estadosCount; i++)
      if(g_estadosKeys[i] == key)
         return g_estadosValues[i];
   return -1;
}

void SetEstado(string key, int estado)
{
   for(int i=0; i<g_estadosCount; i++)
   {
      if(g_estadosKeys[i] == key)
      {
         g_estadosValues[i] = estado;
         return;
      }
   }
   ArrayResize(g_estadosKeys, g_estadosCount+1);
   ArrayResize(g_estadosValues, g_estadosCount+1);
   g_estadosKeys[g_estadosCount] = key;
   g_estadosValues[g_estadosCount] = estado;
   g_estadosCount++;
}

void AppendEstado(int ticketMaster, string eventType, int estado, string resultado, string extra)
{
   string key = IntegerToString(ticketMaster) + "_" + eventType;
   SetEstado(key, estado);
   
   int h = FileOpen(g_estadosFile, FILE_BIN|FILE_READ|FILE_WRITE|FILE_COMMON|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
   {
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
   
   long timestampMs = (long)TimeGMT() * 1000;
   string timestamp = IntegerToString(timestampMs);
   
   string line = IntegerToString(ticketMaster) + ";" +
                 eventType + ";" +
                 IntegerToString(estado) + ";" +
                 timestamp + ";" +
                 resultado + ";" +
                 extra;
   
   uchar utf8[];
   StringToUTF8Bytes(line, utf8);
   FileWriteArray(h, utf8);
   uchar nl[] = {0x0D, 0x0A};
   FileWriteArray(h, nl);
   FileClose(h);
}

void AppendError(int ticketMaster, int magicNumber, string eventType, string errorCode, int mt4Error, int ticketWorker, string symbol, string detalle)
{
   int h = FileOpen(g_erroresFile, FILE_BIN|FILE_READ|FILE_WRITE|FILE_COMMON|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
   {
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
   
   string timestamp = TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS);
   
   string line = timestamp + ";" +
                 IntegerToString(ticketMaster) + ";" +
                 IntegerToString(magicNumber) + ";" +
                 eventType + ";" +
                 errorCode + ";" +
                 IntegerToString(mt4Error) + ";" +
                 IntegerToString(ticketWorker) + ";" +
                 symbol + ";" +
                 detalle;
   
   uchar utf8[];
   StringToUTF8Bytes(line, utf8);
   FileWriteArray(h, utf8);
   uchar nl[] = {0x0D, 0x0A};
   FileWriteArray(h, nl);
   FileClose(h);
   
   Print("[ERROR] ", eventType, " ticketMaster=", ticketMaster, " magic=", magicNumber, 
         " err=", errorCode, " mt4=", mt4Error, " tw=", ticketWorker, " sym=", symbol, " | ", detalle);
}

void CargarEstadosProcesados()
{
   ArrayResize(g_estadosKeys, 0);
   ArrayResize(g_estadosValues, 0);
   g_estadosCount = 0;
   
   int handle = FileOpen(g_estadosFile, FILE_BIN|FILE_READ|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE) return;
   
   int fileSize = (int)FileSize(handle);
   if(fileSize <= 0)
   {
      FileClose(handle);
      return;
   }
   
   uchar bytes[];
   ArrayResize(bytes, fileSize);
   uint bytesRead = FileReadArray(handle, bytes, 0, fileSize);
   FileClose(handle);
   if((int)bytesRead != fileSize) return;
   
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
               SetEstado(key, estado);
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

void ReconstruirReintentosDesdeEstados()
{
   ArrayResize(g_notifCloseTickets, 0);
   g_notifCloseCount = 0;
   ArrayResize(g_notifModifyTickets, 0);
   g_notifModifyCount = 0;
   
   for(int i=0; i<g_estadosCount; i++)
   {
      if(g_estadosValues[i] == 1)
      {
         string key = g_estadosKeys[i];
         int sep = StringFind(key, "_");
         if(sep > 0)
         {
            string ticketStr = StringSubstr(key, 0, sep);
            string evtType = StringSubstr(key, sep + 1);
            
            if(evtType == "CLOSE")
               AddTicket(ticketStr, g_notifCloseTickets, g_notifCloseCount);
            else if(StringFind(evtType, "MODIFY") == 0)  // Empieza con "MODIFY" (incluye MODIFY_sl_tp)
               AddTicket(ticketStr, g_notifModifyTickets, g_notifModifyCount);
         }
      }
   }
   
   if(g_notifCloseCount > 0 || g_notifModifyCount > 0)
   {
      Print("WorkerPV2: Reconstruidos reintentos - CLOSE:", g_notifCloseCount, " MODIFY:", g_notifModifyCount);
   }
}

// -------------------- Queue I/O --------------------
int ReadQueue(string relPath, string &lines[])
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
   uint bytesRead = FileReadArray(handle, bytes, 0, fileSize);
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
void DisplayOpenLogsInChart()
{
   string prefix = "WorkerPV2_Label_";
   for(int i=ObjectsTotal()-1; i>=0; i--)
   {
      string name = ObjectName(i);
      if(StringFind(name, prefix) == 0)
         ObjectDelete(name);
   }

   int y = 20;
   int lineH = 14;

   string title = "WorkerPV2 (MQL4) - POSICIONES EN MEMORIA";
   string titleName = prefix + "Title";
   ObjectCreate(titleName, OBJ_LABEL, 0, 0, 0);
   ObjectSet(titleName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSet(titleName, OBJPROP_XDISTANCE, 10);
   ObjectSet(titleName, OBJPROP_YDISTANCE, y);
   ObjectSetText(titleName, title, 10, "Arial", clrRed);
   y += lineH;

   for(int i=0; i<g_openLogsCount; i++)
   {
      string labelName = prefix + IntegerToString(i);
      string text = "TM: " + IntegerToString(g_logTicketMaster[i]) +
                    " (source=" + g_logTicketMasterSource[i] + ")" +
                    " || TW: " + IntegerToString(g_logTicketWorker[i]) +
                    " || MN: " + IntegerToString(g_logMagicNumber[i]) +
                    " || SYMBOL: " + g_logSymbol[i];
      ObjectCreate(labelName, OBJ_LABEL, 0, 0, 0);
      ObjectSet(labelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSet(labelName, OBJPROP_XDISTANCE, 10);
      ObjectSet(labelName, OBJPROP_YDISTANCE, y);
      ObjectSetText(labelName, text, 8, "Arial", clrRed);
      y += lineH;
   }

   string summaryName = prefix + "Summary";
   string summaryText = "Total: " + IntegerToString(g_openLogsCount) + " posiciones";
   ObjectCreate(summaryName, OBJ_LABEL, 0, 0, 0);
   ObjectSet(summaryName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSet(summaryName, OBJPROP_XDISTANCE, 10);
   ObjectSet(summaryName, OBJPROP_YDISTANCE, y);
   ObjectSetText(summaryName, summaryText, 9, "Arial", clrRed);
}

// -------------------- Parse --------------------
bool ParseLine(string line, string &eventType, int &ticketMaster, string &orderTypeStr, double &lots, string &sym, double &slVal, double &tpVal)
{
   string parts[];
   int n = StringSplit(line, ';', parts);
   if(n < 2) return false;

   eventType = UpperStr(TrimStr(parts[0]));
   ticketMaster = (int)StringToInteger(TrimStr(parts[1]));
   orderTypeStr = "";
   lots = 0.0;
   sym = "";
   slVal = 0.0;
   tpVal = 0.0;

   if(eventType == "" || ticketMaster <= 0) return false;

   if(eventType == "OPEN")
   {
      if(n < 5) return false;
      orderTypeStr = UpperStr(TrimStr(parts[2]));
      string lotsStr = TrimStr(parts[3]);
      StringReplace(lotsStr, ",", ".");
      lots = StringToDouble(lotsStr);
      sym = UpperStr(TrimStr(parts[4]));
      if(n > 5)
      {
         string s5 = TrimStr(parts[5]);
         StringReplace(s5, ",", ".");
         if(s5 != "") slVal = StringToDouble(s5);
      }
      if(n > 6)
      {
         string s6 = TrimStr(parts[6]);
         StringReplace(s6, ",", ".");
         if(s6 != "") tpVal = StringToDouble(s6);
      }
      if(sym == "" || (orderTypeStr != "BUY" && orderTypeStr != "SELL")) return false;
      return true;
   }
   if(eventType == "MODIFY")
   {
      if(n < 4) return false;
      string s2 = TrimStr(parts[2]);
      string s3 = TrimStr(parts[3]);
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

// -------------------- Load open orders from MT4 --------------------
void LoadOpenOrdersFromMT4()
{
   g_openLogsCount = 0;
   ArrayResize(g_logTicketMaster, 0);
   ArrayResize(g_logTicketMasterSource, 0);
   ArrayResize(g_logTicketWorker, 0);
   ArrayResize(g_logMagicNumber, 0);
   ArrayResize(g_logSymbol, 0);
   ArrayResize(g_logOrderType, 0);
   ArrayResize(g_logLots, 0);
   ArrayResize(g_logOpenPrice, 0);
   ArrayResize(g_logOpenTime, 0);
   ArrayResize(g_logSL, 0);
   ArrayResize(g_logTP, 0);

   int total = OrdersTotal();
   for(int i=0; i<total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      
      // Solo órdenes de mercado (BUY/SELL)
      int orderType = OrderType();
      if(orderType != OP_BUY && orderType != OP_SELL) continue;

      int magic = OrderMagicNumber();
      string cmt = TrimStr(OrderComment());

      int tm = 0;
      string source = "";
      if(magic > 0)
      {
         tm = magic;
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
            tm = OrderTicket();
            source = "ORDER_TICKET";
         }
      }

      AddOpenLog(tm, source, OrderTicket(), magic, OrderSymbol(), orderType, 
                 OrderLots(), OrderOpenPrice(), OrderOpenTime(), OrderStopLoss(), OrderTakeProfit());
   }
}

// -------------------- Throttle --------------------
bool Throttled()
{
   uint nowMs = GetTickCount();
   if(InpThrottleMs <= 0)
   {
      g_lastRunMs = nowMs;
      return false;
   }
   uint elapsed = nowMs - g_lastRunMs;
   if(elapsed < (uint)InpThrottleMs) return true;
   g_lastRunMs = nowMs;
   return false;
}

// -------------------- Lifecycle --------------------
int OnInit()
{
   g_workerId    = IntegerToString(AccountNumber());
   g_queueFile   = CommonRelative("cola_WORKER_" + g_workerId + ".csv");
   g_estadosFile = CommonRelative("estados_WORKER_" + g_workerId + ".csv");
   g_erroresFile = CommonRelative("errores_WORKER_" + g_workerId + ".csv");

   LoadOpenOrdersFromMT4();
   CargarEstadosProcesados();
   ReconstruirReintentosDesdeEstados();
   
   DisplayOpenLogsInChart();

   EventSetTimer(InpTimerSeconds);
   Print("WorkerPV2 (MQL4) inicializado. Cola=", g_queueFile, " Estados=", g_estadosFile, " Posiciones=", g_openLogsCount);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   string prefix = "WorkerPV2_Label_";
   for(int i=ObjectsTotal()-1; i>=0; i--)
   {
      string name = ObjectName(i);
      if(StringFind(name, prefix) == 0)
         ObjectDelete(name);
   }
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

      // Construir clave según tipo de evento
      // Para MODIFY: incluir valores SL/TP para distinguir MODIFYs múltiples del mismo ticket
      string key;
      if(eventType == "MODIFY")
         key = IntegerToString(ticketMaster) + "_MODIFY_" + DoubleToString(slVal, 2) + "_" + DoubleToString(tpVal, 2);
      else
         key = IntegerToString(ticketMaster) + "_" + eventType;
      
      int estadoActual = FindEstado(key);

      if(estadoActual == 2)
         continue;

      if(eventType == "OPEN")
      {
         // Verificar si ya existe
         int idx = FindOpenLog(ticketMaster);
         if(idx >= 0)
         {
            AppendEstado(ticketMaster, "OPEN", 2, "OK_YA_EXISTE", IntegerToString(g_logTicketWorker[idx]));
            continue;
         }

         double lotsWorker = ComputeWorkerLots(sym, lots);
         int cmd = (orderTypeStr == "BUY" ? OP_BUY : OP_SELL);
         double price = (cmd == OP_BUY ? MarketInfo(sym, MODE_ASK) : MarketInfo(sym, MODE_BID));
         string commentStr = IntegerToString(ticketMaster);

         int ticket = OrderSend(sym, cmd, lotsWorker, price, InpSlippage, slVal, tpVal, commentStr, ticketMaster, 0, clrNONE);

         if(ticket < 0)
         {
            int err = GetLastError();
            string errBase = "OrderSend failed: " + ErrorText(err);
            Notify("Ticket: " + IntegerToString(ticketMaster) + " - OPEN FALLO: " + errBase);
            AppendEstado(ticketMaster, "OPEN", 2, "ERR_" + IntegerToString(err), errBase);
            AppendError(ticketMaster, ticketMaster, "OPEN", "ERR_SEND", err, 0, sym, errBase);
            continue;
         }

         // OrderSend OK - guardar en memoria
         AddOpenLog(ticketMaster, "MAGIC", ticket, ticketMaster, sym, cmd, lotsWorker, price, TimeCurrent(), slVal, tpVal);
         DisplayOpenLogsInChart();
         AppendEstado(ticketMaster, "OPEN", 2, "OK", IntegerToString(ticket));
      }
      else if(eventType == "MODIFY")
      {
         // EventType extendido para distinguir MODIFYs múltiples del mismo ticket
         string modifyEventType = "MODIFY_" + DoubleToString(slVal, 2) + "_" + DoubleToString(tpVal, 2);
         
         int idx = FindOpenLog(ticketMaster);
         if(idx < 0)
         {
            int histTicket = FindOrderInHistory(ticketMaster);
            if(histTicket > 0)
            {
               AppendEstado(ticketMaster, modifyEventType, 2, "ERR_YA_CERRADA", "");
            }
            else
            {
               AppendEstado(ticketMaster, modifyEventType, 2, "ERR_NO_ENCONTRADA", "");
               AppendError(ticketMaster, ticketMaster, "MODIFY", "ERR_NO_ENCONTRADA", 0, 0, "", "Posicion no encontrada en g_openLogs");
            }
            continue;
         }

         int ticketWorker = g_logTicketWorker[idx];
         string symLog = g_logSymbol[idx];
         int magicLog = g_logMagicNumber[idx];

         if(!OrderSelect(ticketWorker, SELECT_BY_TICKET, MODE_TRADES))
         {
            int histTicket = FindOrderInHistory(ticketMaster);
            if(histTicket > 0)
            {
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendEstado(ticketMaster, modifyEventType, 2, "ERR_YA_CERRADA", "");
            }
            else
            {
               AppendEstado(ticketMaster, modifyEventType, 2, "ERR_NO_ENCONTRADA", "");
               AppendError(ticketMaster, magicLog, "MODIFY", "ERR_NO_ENCONTRADA", 0, ticketWorker, symLog, "OrderSelect failed");
            }
            RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
            continue;
         }

         double newSL = (slVal > 0 ? slVal : 0.0);
         double newTP = (tpVal > 0 ? tpVal : 0.0);
         double currentPrice = OrderOpenPrice();

         bool ok = OrderModify(ticketWorker, currentPrice, newSL, newTP, 0, clrNONE);

         if(ok)
         {
            UpdateOpenLogSLTP(ticketMaster, newSL, newTP);
            DisplayOpenLogsInChart();
            AppendEstado(ticketMaster, modifyEventType, 2, "OK", "");
            RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
         }
         else
         {
            int histTicket = FindOrderInHistory(ticketMaster);
            if(histTicket > 0)
            {
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendEstado(ticketMaster, modifyEventType, 2, "ERR_YA_CERRADA", "");
               RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
            }
            else
            {
               int err = GetLastError();
               string errTxt = "OrderModify failed: " + ErrorText(err);
               AppendError(ticketMaster, magicLog, "MODIFY", "RETRY", err, ticketWorker, symLog, errTxt);
               
               if(estadoActual != 1)
               {
                  AppendEstado(ticketMaster, modifyEventType, 1, "RETRY", "ERR_" + IntegerToString(err));
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
            int histTicket = FindOrderInHistory(ticketMaster);
            if(histTicket > 0)
            {
               AppendEstado(ticketMaster, "CLOSE", 2, "OK_YA_CERRADA", "");
            }
            else
            {
               AppendEstado(ticketMaster, "CLOSE", 2, "ERR_NO_ENCONTRADA", "");
               AppendError(ticketMaster, ticketMaster, "CLOSE", "ERR_NO_ENCONTRADA", 0, 0, "", "Posicion no encontrada en g_openLogs");
            }
            continue;
         }

         int ticketWorker = g_logTicketWorker[idx];
         string symLog = g_logSymbol[idx];
         int magicLog = g_logMagicNumber[idx];

         if(!OrderSelect(ticketWorker, SELECT_BY_TICKET, MODE_TRADES))
         {
            int histTicket = FindOrderInHistory(ticketMaster);
            if(histTicket > 0)
            {
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendEstado(ticketMaster, "CLOSE", 2, "OK_YA_CERRADA", "");
               RemoveTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            }
            else
            {
               AppendEstado(ticketMaster, "CLOSE", 2, "ERR_NO_ENCONTRADA", "");
               AppendError(ticketMaster, magicLog, "CLOSE", "ERR_NO_ENCONTRADA", 0, ticketWorker, symLog, "OrderSelect failed");
            }
            continue;
         }

         double volume = OrderLots();
         double profitBefore = OrderProfit();
         int orderType = OrderType();
         double closePrice = (orderType == OP_BUY ? MarketInfo(symLog, MODE_BID) : MarketInfo(symLog, MODE_ASK));

         bool ok = OrderClose(ticketWorker, volume, closePrice, InpSlippage, clrNONE);

         if(ok)
         {
            AppendEstado(ticketMaster, "CLOSE", 2, "OK", DoubleToString(profitBefore, 2));
            RemoveTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            RemoveOpenLog(ticketMaster);
            DisplayOpenLogsInChart();
         }
         else
         {
            int histTicket = FindOrderInHistory(ticketMaster);
            if(histTicket > 0)
            {
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendEstado(ticketMaster, "CLOSE", 2, "OK_YA_CERRADA", "");
               RemoveTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            }
            else
            {
               int err = GetLastError();
               string errTxt = "OrderClose failed: " + ErrorText(err);
               AppendError(ticketMaster, magicLog, "CLOSE", "RETRY_SEND", err, ticketWorker, symLog, errTxt);
               
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
}
