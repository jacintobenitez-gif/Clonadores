//+------------------------------------------------------------------+
//|                                                    WorkerV2.mq4  |
//|  Implementación MQL4 según V3/ANALISIS_Worker_V2.md              |
//|  Lee cola_WORKER_<account>.csv (Common\\Files\\V3\\Phoenix)      |
//|  Ejecuta OPEN / MODIFY / CLOSE, historiza y notifica             |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"

// -------------------- Inputs --------------------
input bool   InpFondeo        = false;
input double InpLotMultiplier = 1.0;
input double InpFixedLots     = 0.10;  // (no se usa si InpFondeo=false, se mantiene por compatibilidad)
input int    InpSlippage      = 30;     // pips
input int    InpMagicNumber   = 0;      // (compatibilidad; en V2 el magic es ticketMaster)
input int    InpTimerSeconds  = 1;
input int    InpSyncSeconds   = 10;     // cada N segundos recalcula memoria desde MT4

// -------------------- Paths (Common\\Files) --------------------
string BASE_SUBDIR   = "V3\\Phoenix";
string g_workerId    = "";
string g_queueFile   = "";
string g_historyFile = "";

datetime g_lastSyncTime = 0;

// -------------------- Notif anti-spam --------------------
string g_notifCloseTickets[];
int    g_notifCloseCount  = 0;
string g_notifModifyTickets[];
int    g_notifModifyCount = 0;

// -------------------- Estructura única en memoria --------------------
struct OpenLogInfo
{
   int ticketMaster;     // MagicNumber = identificador maestro
   string ticketMasterSource; // "MAGIC" | "COMMENT" | "ORDER_TICKET"
   int ticketWorker;     // Ticket MT4
   int magicNumber;      // Para verificación/visualización
   string symbol;
   int orderType;        // OP_BUY / OP_SELL
   double lots;
   double openPrice;
   datetime openTime;
   double sl;
   double tp;
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

bool LineInArray(const string line, string &arr[], int count)
{
   for(int i=0; i<count; i++)
      if(arr[i] == line) return true;
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
string Trim(string s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
}

string Upper(string s)
{
   StringToUpper(s);
   return s;
}

// MQL4 no tiene LongToString() en algunas builds; usar StringFormat para int64
string LongToStr(const long v)
{
   return StringFormat("%I64d", v);
}

// -------------------- Errors / notifications --------------------
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

string FormatLastError(const string prefix)
{
   int code = GetLastError();
   return prefix + " (" + IntegerToString(code) + ") " + ErrorText(code);
}

void Notify(const string msg)
{
   string full = "W: " + IntegerToString(AccountNumber()) + " - " + msg;
   SendNotification(full);
}

// -------------------- UTF-8 helpers (binario) --------------------
void StringToUTF8Bytes(string str, uchar &bytes[])
{
   ArrayResize(bytes, 0);
   int len = StringLen(str);
   for(int i=0; i<len; i++)
   {
      ushort ch = StringGetCharacter(str, i);
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
         result += ShortToString((ushort)0xFFFD);
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
   // Las carpetas se crean externamente; no intentamos crearlas desde MQL4.
   return true;
}

// -------------------- Lot sizing --------------------
double LotFromCapital(double capital, string symbol)
{
   int blocks = (int)MathFloor(capital / 1000.0);
   if(blocks < 1) blocks = 1;

   double lot = blocks * 0.01;

   double minLot  = MarketInfo(symbol, MODE_MINLOT);
   double maxLot  = MarketInfo(symbol, MODE_MAXLOT);
   double stepLot = MarketInfo(symbol, MODE_LOTSTEP);

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

double ComputeWorkerLots(string symbol, double masterLots)
{
   if(InpFondeo)
      return masterLots * InpLotMultiplier;
   return LotFromCapital(AccountBalance(), symbol);
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

void UpdateOpenLogSLTP(const int ticketMaster, double sl, double tp)
{
   int idx = FindOpenLog(ticketMaster);
   if(idx < 0) return;
   g_openLogs[idx].sl = sl;
   g_openLogs[idx].tp = tp;
}

// -------------------- Find open order / history by ticketMaster --------------------
int FindOpenOrder(const int ticketMaster)
{
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() == ticketMaster) return OrderTicket();
      if(OrderComment() == IntegerToString(ticketMaster)) return OrderTicket();
   }
   return -1;
}

int FindOrderInHistory(const int ticketMaster)
{
   for(int i=HistoryTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber() == ticketMaster) return OrderTicket();
      if(OrderComment() == IntegerToString(ticketMaster)) return OrderTicket();
   }
   return -1;
}

// -------------------- Queue I/O --------------------
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
   uint bytesRead = FileReadArray(handle, bytes, 0, fileSize);
   FileClose(handle);
   if((int)bytesRead != fileSize) return 0;

   // Saltar BOM UTF-8 si existe
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

void RewriteQueue(const string relPath, string &lines[], int count)
{
   int handle = FileOpen(relPath, FILE_BIN|FILE_WRITE|FILE_COMMON);
   if(handle == INVALID_HANDLE)
   {
      Print("No se pudo reescribir cola: ", relPath, " err=", GetLastError());
      return;
   }

   for(int i=0; i<count; i++)
   {
      uchar utf8[];
      StringToUTF8Bytes(lines[i], utf8);
      FileWriteArray(handle, utf8);
      uchar nl[] = {0x0A};
      FileWriteArray(handle, nl);
   }
   FileClose(handle);
}

// -------------------- History --------------------
void EnsureHistoryHeader()
{
   if(FileIsExist(g_historyFile, FILE_COMMON)) return;

   int h = FileOpen(g_historyFile, FILE_BIN|FILE_WRITE|FILE_COMMON);
   if(h == INVALID_HANDLE)
   {
      Print("No se pudo crear historico: ", g_historyFile, " err=", GetLastError());
      return;
   }
   string header = "worker_exec_time;worker_read_time;resultado;event_type;ticketMaster;ticketWorker;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit";
   uchar b[];
   StringToUTF8Bytes(header, b);
   FileWriteArray(h, b);
   uchar nl[] = {0x0A};
   FileWriteArray(h, nl);
   FileClose(h);
}

void AppendHistory(const string result,
                   const string eventType,
                   const int ticketMaster,
                   const int ticketWorker,
                   const string orderType,
                   const double lots,
                   const string symbol,
                   double openPrice=0.0,
                   datetime openTime=0,
                   double sl=0.0,
                   double tp=0.0,
                   double closePrice=0.0,
                   datetime closeTime=0,
                   double profit=0.0,
                   long workerReadTimeMs=0,
                   long workerExecTimeMs=0)
{
   EnsureHistoryHeader();

   int h = FileOpen(g_historyFile, FILE_BIN|FILE_READ|FILE_WRITE|FILE_COMMON|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
   {
      Print("No se pudo abrir historico: ", g_historyFile, " err=", GetLastError());
      return;
   }
   FileSeek(h, 0, SEEK_END);

   int symDigits = (int)MarketInfo(symbol, MODE_DIGITS);
   if(symDigits <= 0) symDigits = Digits;

   string sOpenPrice  = (openPrice!=0.0 ? DoubleToString(openPrice, symDigits) : "");
   string sOpenTime   = (openTime>0 ? TimeToString(openTime, TIME_DATE|TIME_SECONDS) : "");
   string sClosePrice = (closePrice!=0.0 ? DoubleToString(closePrice, symDigits) : "");
   string sCloseTime  = (closeTime>0 ? TimeToString(closeTime, TIME_DATE|TIME_SECONDS) : "");
   string sSl = (sl>0 ? DoubleToString(sl, symDigits) : "");
   string sTp = (tp>0 ? DoubleToString(tp, symDigits) : "");
   string sProfit = (profit!=0.0 ? DoubleToString(profit, 2) : "");

   string line = LongToStr(workerExecTimeMs) + ";" + LongToStr(workerReadTimeMs) + ";" +
                 result + ";" + eventType + ";" + IntegerToString(ticketMaster) + ";" + IntegerToString(ticketWorker) + ";" +
                 orderType + ";" + DoubleToString(lots, 2) + ";" + symbol + ";" +
                 sOpenPrice + ";" + sOpenTime + ";" + sSl + ";" + sTp + ";" + sClosePrice + ";" + sCloseTime + ";" + sProfit;

   uchar utf8[];
   StringToUTF8Bytes(line, utf8);
   FileWriteArray(h, utf8);
   uchar nl[] = {0x0A};
   FileWriteArray(h, nl);
   FileClose(h);
}

// -------------------- Chart display --------------------
void DisplayOpenLogsInChart()
{
   // Limpieza previa
   ObjectsDeleteAll(0, "WorkerV2_Label_");

   int y = 20;
   int lineH = 14;

   string title = "WorkerV2 - POSICIONES EN MEMORIA";
   string titleName = "WorkerV2_Label_Title";
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
      string labelName = "WorkerV2_Label_" + IntegerToString(i);
      string text = "TM: " + IntegerToString(g_openLogs[i].ticketMaster) +
                    " (source=" + g_openLogs[i].ticketMasterSource + ")" +
                    " || TW: " + IntegerToString(g_openLogs[i].ticketWorker) +
                    " || MN: " + IntegerToString(g_openLogs[i].magicNumber) +
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

   string summaryName = "WorkerV2_Label_Summary";
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
// Acepta:
// - OPEN;ticket;BUY/SELL;lots;symbol;sl;tp
// - MODIFY;ticket;sl;tp   (o MODIFY;ticket;;;;;sl;tp)
// - CLOSE;ticket
bool ParseLine(const string line,
               string &eventType,
               int &ticketMaster,
               string &orderTypeStr,
               double &lots,
               string &symbol,
               double &sl,
               double &tp)
{
   string parts[];
   int n = StringSplit(line, ';', parts);
   if(n < 2) return false;

   eventType = Upper(Trim(parts[0]));
   ticketMaster = (int)StrToInteger(Trim(parts[1]));
   orderTypeStr = "";
   lots = 0.0;
   symbol = "";
   sl = 0.0;
   tp = 0.0;

   if(eventType == "" || ticketMaster <= 0) return false;

   if(eventType == "OPEN")
   {
      if(n < 5) return false;
      orderTypeStr = Upper(Trim(parts[2]));
      string lotsStr = Trim(parts[3]); StringReplace(lotsStr, ",", ".");
      lots = StrToDouble(lotsStr);
      symbol = Upper(Trim(parts[4]));
      if(n > 5)
      {
         string s = Trim(parts[5]); StringReplace(s, ",", ".");
         if(s != "") sl = StrToDouble(s);
      }
      if(n > 6)
      {
         string s = Trim(parts[6]); StringReplace(s, ",", ".");
         if(s != "") tp = StrToDouble(s);
      }
      if(symbol == "" || (orderTypeStr != "BUY" && orderTypeStr != "SELL")) return false;
      return true;
   }
   if(eventType == "MODIFY")
   {
      // Contrato ÚNICO: MODIFY;ticket;sl;tp
      if(n < 4) return false;

      string s = Trim(parts[2]); StringReplace(s, ",", ".");
      string t = Trim(parts[3]); StringReplace(t, ",", ".");

      // No permitir ambos vacíos (evento inválido)
      if(s == "" && t == "") return false;

      if(s != "") sl = StrToDouble(s);
      if(t != "") tp = StrToDouble(t);
      return true;
   }
   if(eventType == "CLOSE")
   {
      return true;
   }

   return false;
}

// -------------------- Load open positions --------------------
void LoadOpenPositionsFromMT4()
{
   ArrayResize(g_openLogs, 0);
   g_openLogsCount = 0;

   int total = OrdersTotal();
   for(int i=0; i<total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int magic = OrderMagicNumber();
      
      // En producción pueden existir órdenes antiguas/manuales con magic=0.
      // Para que la memoria refleje la realidad, las cargamos igualmente usando un ticketMaster "sustituto".
      // Prioridad:
      // - magicNumber si > 0
      // - si el comment es numérico (ticketMaster), usarlo
      // - si no, usar OrderTicket() como identificador interno (solo para visualización/sync)
      int ticketMaster = 0;
      string source = "";
      if(magic > 0)
      {
         ticketMaster = magic;
         source = "MAGIC";
      }
      else
      {
         string cmt = Trim(OrderComment());
         int cmtId = (int)StrToInteger(cmt);
         if(cmtId > 0)
         {
            ticketMaster = cmtId;
            source = "COMMENT";
         }
         else
         {
            ticketMaster = OrderTicket();
            source = "ORDER_TICKET";
         }
      }

      OpenLogInfo log;
      log.ticketMaster = ticketMaster;
      log.ticketMasterSource = source;
      log.ticketWorker = OrderTicket();
      log.magicNumber  = magic;
      log.symbol       = OrderSymbol();
      log.orderType    = OrderType();
      log.lots         = OrderLots();
      log.openPrice    = OrderOpenPrice();
      log.openTime     = OrderOpenTime();
      log.sl           = OrderStopLoss();
      log.tp           = OrderTakeProfit();

      AddOpenLog(log);
   }
}

// -------------------- Lifecycle --------------------
int OnInit()
{
   g_workerId    = IntegerToString(AccountNumber());
   g_queueFile   = CommonRelative("cola_WORKER_" + g_workerId + ".csv");
   g_historyFile = CommonRelative("historico_WORKER_" + g_workerId + ".csv");

   if(!EnsureBaseFolder()) return INIT_FAILED;

   LoadOpenPositionsFromMT4();
   DisplayOpenLogsInChart();

   EventSetTimer(InpTimerSeconds);
   Print("WorkerV2 inicializado. Cola=", g_queueFile, " Historico=", g_historyFile, " Posiciones=", g_openLogsCount);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, "WorkerV2_Label_");
}

void OnTimer()
{
   // Sync defensivo: evita "posiciones en memoria" fantasma (cierres manuales/SL/TP o eventos perdidos)
   datetime now = TimeCurrent();
   if(g_lastSyncTime == 0 || (InpSyncSeconds > 0 && (now - g_lastSyncTime) >= InpSyncSeconds))
   {
      LoadOpenPositionsFromMT4();
      DisplayOpenLogsInChart();
      g_lastSyncTime = now;
   }

   // worker_read_time cuando se lee la cola (ms epoch)
   datetime tRead = TimeCurrent();
   long workerReadTimeMs = (long)(tRead * 1000) + (GetTickCount() % 1000);

   string lines[];
   int total = ReadQueue(g_queueFile, lines);
   if(total <= 0) return;

   // Cabecera opcional
   int startIdx = 0;
   if(total > 0)
   {
      string firstLower = lines[0];
      StringToLower(firstLower);
      if(StringFind(firstLower, "event_type") >= 0) startIdx = 1;
   }

   string remaining[];
   int remainingCount = 0;

   for(int i=startIdx; i<total; i++)
   {
      string eventType;
      int ticketMaster;
      string orderTypeStr;
      double lots;
      string symbol;
      double sl;
      double tp;

      if(!ParseLine(lines[i], eventType, ticketMaster, orderTypeStr, lots, symbol, sl, tp))
      {
         ArrayResize(remaining, remainingCount+1);
         remaining[remainingCount] = lines[i];
         remainingCount++;
         continue;
      }

      if(eventType == "OPEN")
      {
         RefreshRates();
         // Validación: símbolo
         if(!SymbolSelect(symbol, true))
         {
            int errCode = GetLastError();
            string msg = "Ticket: " + IntegerToString(ticketMaster) + " - OPEN FALLO: SymbolSelect (" + IntegerToString(errCode) + ") " + ErrorText(errCode);
            Notify(msg);
            AppendHistory(msg, "OPEN", ticketMaster, 0, orderTypeStr, lots, symbol, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            continue; // OPEN no se reintenta
         }

         // Deduplicación
         int existing = FindOpenOrder(ticketMaster);
         if(existing >= 0)
         {
            AppendHistory("Ya existe operacion abierta", "OPEN", ticketMaster, existing, orderTypeStr, lots, symbol, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            continue;
         }

         double lotsWorker = ComputeWorkerLots(symbol, lots);
         int type = (orderTypeStr == "BUY" ? OP_BUY : OP_SELL);
         double price = (type == OP_BUY ? Ask : Bid);
         string commentStr = IntegerToString(ticketMaster);

         ResetLastError();
         int ordersTotalBefore = OrdersTotal();
         int ticketNew = OrderSend(symbol, type, lotsWorker, price, InpSlippage, sl, tp, commentStr, ticketMaster, 0, clrNONE);

         datetime tExec = TimeCurrent();
         long workerExecTimeMs = (long)(tExec * 1000) + (GetTickCount() % 1000);

         if(ticketNew < 0)
         {
            int err = GetLastError();
            string errBase = "ERROR: OPEN (" + IntegerToString(err) + ") " + ErrorText(err);
            Notify("Ticket: " + IntegerToString(ticketMaster) + " - " + errBase);
            AppendHistory(errBase, "OPEN", ticketMaster, 0, orderTypeStr, lots, symbol, 0, 0, sl, tp, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
            continue;
         }

         // OPEN OK
         if(OrderSelect(ticketNew, SELECT_BY_TICKET))
         {
            OpenLogInfo log;
            log.ticketMaster = ticketMaster;
            log.ticketMasterSource = "MAGIC";
            log.ticketWorker = ticketNew;
            log.magicNumber  = ticketMaster;
            log.symbol       = OrderSymbol();
            log.orderType    = OrderType();
            log.lots         = OrderLots();
            log.openPrice    = OrderOpenPrice();
            log.openTime     = OrderOpenTime();
            log.sl           = OrderStopLoss();
            log.tp           = OrderTakeProfit();

            AddOpenLog(log);
            DisplayOpenLogsInChart();

            AppendHistory("EXITOSO", "OPEN", ticketMaster, ticketNew, orderTypeStr, lots, symbol, log.openPrice, log.openTime, log.sl, log.tp, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
         }
         else
         {
            AppendHistory("OPEN OK pero OrderSelect falló", "OPEN", ticketMaster, ticketNew, orderTypeStr, lots, symbol, 0, 0, sl, tp, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
         }
      }
      else if(eventType == "MODIFY")
      {
         int idx = FindOpenLog(ticketMaster);
         if(idx < 0)
         {
            AppendHistory("MODIFY fallido. No se encontro: " + IntegerToString(ticketMaster), "MODIFY", ticketMaster, 0, "", 0, "", 0, 0, sl, tp, 0, 0, 0, workerReadTimeMs, 0);
            continue;
         }

         int ticketWorker = g_openLogs[idx].ticketWorker;
         if(!OrderSelect(ticketWorker, SELECT_BY_TICKET))
         {
            string sym = g_openLogs[idx].symbol;
            RemoveOpenLog(ticketMaster);
            DisplayOpenLogsInChart();
            AppendHistory("MODIFY fallido: Orden ya cerrada", "MODIFY", ticketMaster, ticketWorker, "", 0, sym, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
            continue;
         }

         double newSL = (sl > 0 ? sl : 0.0);
         double newTP = (tp > 0 ? tp : 0.0);

         ResetLastError();
         bool ok = OrderModify(ticketWorker, OrderOpenPrice(), newSL, newTP, OrderExpiration(), clrNONE);

         datetime tExec = TimeCurrent();
         long workerExecTimeMs = (long)(tExec * 1000) + (GetTickCount() % 1000);

         if(ok)
         {
            UpdateOpenLogSLTP(ticketMaster, newSL, newTP);
            DisplayOpenLogsInChart();
            string res = "MODIFY OK SL=" + DoubleToString(newSL, 2) + " TP=" + DoubleToString(newTP, 2);
            AppendHistory(res, "MODIFY", ticketMaster, ticketWorker, "", 0, g_openLogs[idx].symbol, 0, 0, newSL, newTP, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
            RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
         }
         else
         {
            int historyTicket = FindOrderInHistory(ticketMaster);
            if(historyTicket >= 0)
            {
               string sym = g_openLogs[idx].symbol;
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendHistory("MODIFY fallido: Orden ya cerrada", "MODIFY", ticketMaster, ticketWorker, "", 0, sym, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
               RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
            }
            else
            {
               string err = "MODIFY FALLO: " + FormatLastError("MODIFY");
               if(!TicketInArray(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount))
               {
                  Notify("Ticket: " + IntegerToString(ticketMaster) + " - " + err);
                  AddTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
               }
               AppendHistory(err, "MODIFY", ticketMaster, ticketWorker, "", 0, g_openLogs[idx].symbol, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
               ArrayResize(remaining, remainingCount+1);
               remaining[remainingCount] = lines[i];
               remainingCount++;
            }
         }
      }
      else if(eventType == "CLOSE")
      {
         int idx = FindOpenLog(ticketMaster);
         if(idx < 0)
         {
            int historyTicket = FindOrderInHistory(ticketMaster);
            if(historyTicket >= 0)
               AppendHistory("Orden ya estaba cerrada", "CLOSE", ticketMaster, historyTicket, "", 0, "", 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            else
               AppendHistory("Close fallido. No se encontro: " + IntegerToString(ticketMaster), "CLOSE", ticketMaster, 0, "", 0, "", 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            continue;
         }

         int ticketWorker = g_openLogs[idx].ticketWorker;
         if(!OrderSelect(ticketWorker, SELECT_BY_TICKET))
         {
            int historyTicket = FindOrderInHistory(ticketMaster);
            if(historyTicket >= 0)
            {
               string sym = g_openLogs[idx].symbol;
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendHistory("Orden ya estaba cerrada", "CLOSE", ticketMaster, ticketWorker, "", 0, sym, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
               RemoveTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            }
            else
            {
               AppendHistory("Close fallido. No se encontro: " + IntegerToString(ticketMaster), "CLOSE", ticketMaster, 0, "", 0, "", 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            }
            continue;
         }

         RefreshRates();
         int type = OrderType();
         double volume = OrderLots();
         double closePrice = (type==OP_BUY ? Bid : Ask);
         double profitBefore = OrderProfit();
         datetime closeTime = TimeCurrent();

         ResetLastError();
         bool ok = OrderClose(ticketWorker, volume, closePrice, InpSlippage, clrNONE);

         datetime tExec = TimeCurrent();
         long workerExecTimeMs = (long)(tExec * 1000) + (GetTickCount() % 1000);

         if(ok)
         {
            AppendHistory("CLOSE OK", "CLOSE", ticketMaster, ticketWorker, "", 0, g_openLogs[idx].symbol, 0, 0, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
            RemoveTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            RemoveOpenLog(ticketMaster);
            DisplayOpenLogsInChart();
         }
         else
         {
            int historyTicket = FindOrderInHistory(ticketMaster);
            if(historyTicket >= 0)
            {
               string sym = g_openLogs[idx].symbol;
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendHistory("CLOSE fallido: Orden ya cerrada", "CLOSE", ticketMaster, ticketWorker, "", 0, sym, 0, 0, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
               RemoveTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            }
            else
            {
               string err = FormatLastError("CLOSE FALLO");
               if(!TicketInArray(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount))
               {
                  Notify("Ticket: " + IntegerToString(ticketMaster) + " - " + err);
                  AddTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
               }
               AppendHistory(err, "CLOSE", ticketMaster, ticketWorker, "", 0, g_openLogs[idx].symbol, 0, 0, 0, 0, closePrice, closeTime, profitBefore, workerReadTimeMs, workerExecTimeMs);
               ArrayResize(remaining, remainingCount+1);
               remaining[remainingCount] = lines[i];
               remainingCount++;
            }
         }
      }
   }

   // REWRITE defensivo: evita perder eventos si Phoenix escribió mientras procesábamos (race condition)
   string merged[];
   int mergedCount = 0;

   // 1) Mantener lo que quedó pendiente
   for(int r=0; r<remainingCount; r++)
   {
      ArrayResize(merged, mergedCount+1);
      merged[mergedCount] = remaining[r];
      mergedCount++;
   }

   // 2) Releer el archivo actual y conservar líneas nuevas que no estaban en el snapshot inicial
   string linesNow[];
   int totalNow = ReadQueue(g_queueFile, linesNow);
   if(totalNow > 0)
   {
      int startNow = 0;
      string firstLowerNow = linesNow[0];
      StringToLower(firstLowerNow);
      if(StringFind(firstLowerNow, "event_type") >= 0) startNow = 1;

      for(int n=startNow; n<totalNow; n++)
      {
         // Si esta línea NO existía cuando leímos al inicio, la preservamos (para no perderla)
         if(!LineInArray(linesNow[n], lines, total) && !LineInArray(linesNow[n], merged, mergedCount))
         {
            ArrayResize(merged, mergedCount+1);
            merged[mergedCount] = linesNow[n];
            mergedCount++;
         }
      }
   }

   RewriteQueue(g_queueFile, merged, mergedCount);
}


