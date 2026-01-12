//+------------------------------------------------------------------+
//|                                                    WorkerV2.mq5  |
//|  Port MQL5 (desde cero) del WorkerV2.mq4                         |
//|  Lee cola_WORKER_<account>.csv (Common\Files\V3\Phoenix)          |
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

// -------------------- Paths (Common\Files) --------------------
string BASE_SUBDIR   = "V3\\Phoenix";
string g_workerId    = "";
string g_queueFile   = "";
string g_historyFile = "";

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

// -------------------- Time ms (compatible) --------------------
long NowMs()
{
   datetime t = TimeCurrent();
   return (long)(t * 1000) + (GetTickCount() % 1000);
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

int SymbolDigitsSafe(const string sym)
{
   if(sym == "")
      return (int)_Digits;
   long d = 0;
   if(SymbolInfoInteger(sym, SYMBOL_DIGITS, d))
      return (int)d;
   return (int)_Digits;
}

void AppendHistory(const string result, const string eventType, const int ticketMaster, const ulong ticketWorker, const string orderType, const double lots, const string sym, double openPrice=0.0, datetime openTime=0, double slVal=0.0, double tpVal=0.0, double closePrice=0.0, datetime closeTime=0, double profit=0.0, long workerReadTimeMs=0, long workerExecTimeMs=0)
{
   EnsureHistoryHeader();

   int h = FileOpen(g_historyFile, FILE_BIN|FILE_READ|FILE_WRITE|FILE_COMMON|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
   {
      Print("No se pudo abrir historico: ", g_historyFile, " err=", GetLastError());
      return;
   }
   FileSeek(h, 0, SEEK_END);

   int symDigits = SymbolDigitsSafe(sym);

   string sOpenPrice  = (openPrice!=0.0 ? DoubleToString(openPrice, symDigits) : "");
   string sOpenTime   = (openTime>0 ? TimeToString(openTime, TIME_DATE|TIME_SECONDS) : "");
   string sClosePrice = (closePrice!=0.0 ? DoubleToString(closePrice, symDigits) : "");
   string sCloseTime  = (closeTime>0 ? TimeToString(closeTime, TIME_DATE|TIME_SECONDS) : "");
   string sSl = (slVal>0 ? DoubleToString(slVal, symDigits) : "");
   string sTp = (tpVal>0 ? DoubleToString(tpVal, symDigits) : "");
   string sProfit = (profit!=0.0 ? DoubleToString(profit, 2) : "");

   string line = LongToStr(workerExecTimeMs) + ";" + LongToStr(workerReadTimeMs) + ";" +
                 result + ";" + eventType + ";" + IntegerToString(ticketMaster) + ";" + LongToStr((long)ticketWorker) + ";" +
                 orderType + ";" + DoubleToString(lots, 2) + ";" + sym + ";" +
                 sOpenPrice + ";" + sOpenTime + ";" + sSl + ";" + sTp + ";" + sClosePrice + ";" + sCloseTime + ";" + sProfit;

   uchar utf8[];
   StringToUTF8Bytes(line, utf8);
   FileWriteArray(h, utf8);
   uchar nl[] = {0x0A};
   FileWriteArray(h, nl);
   FileClose(h);
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
   DeleteObjectsByPrefix(0, "WorkerV2_Label_");

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

// -------------------- Lifecycle --------------------
int OnInit()
{
   g_workerId    = LongToStr((long)AccountInfoInteger(ACCOUNT_LOGIN));
   g_queueFile   = CommonRelative("cola_WORKER_" + g_workerId + ".csv");
   g_historyFile = CommonRelative("historico_WORKER_" + g_workerId + ".csv");

   if(!EnsureBaseFolder()) return INIT_FAILED;

   LoadOpenPositionsFromMT5();
   DisplayOpenLogsInChart();

   EventSetTimer(InpTimerSeconds);
   Print("WorkerV2 (MQL5) inicializado. Cola=", g_queueFile, " Historico=", g_historyFile, " Posiciones=", g_openLogsCount);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteObjectsByPrefix(0, "WorkerV2_Label_");
}

void OnTimer()
{
   long workerReadTimeMs = NowMs();

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

   string remaining[];
   int remainingCount = 0;

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
      {
         ArrayResize(remaining, remainingCount+1);
         remaining[remainingCount] = lines[i];
         remainingCount++;
         continue;
      }

      if(eventType == "OPEN")
      {
         if(!EnsureFillingMode(sym))
         {
            int errCode = GetLastError();
            string msg = "Ticket: " + IntegerToString(ticketMaster) + " - OPEN FALLO: SymbolSelect (" + IntegerToString(errCode) + ") " + ErrorText(errCode);
            Notify(msg);
            AppendHistory(msg, "OPEN", ticketMaster, 0, orderTypeStr, lots, sym, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            continue;
         }

         ulong existing = FindOpenPosition(ticketMaster);
         if(existing > 0)
         {
            AppendHistory("Ya existe operacion abierta", "OPEN", ticketMaster, existing, orderTypeStr, lots, sym, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            continue;
         }

         double lotsWorker = ComputeWorkerLots(sym, lots);
         ENUM_ORDER_TYPE type = (orderTypeStr == "BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

         MqlTick tick;
         if(!SymbolInfoTick(sym, tick))
         {
            int err = GetLastError();
            string errBase = "ERROR: OPEN (SymbolInfoTick " + IntegerToString(err) + ") " + ErrorText(err);
            Notify("Ticket: " + IntegerToString(ticketMaster) + " - " + errBase);
            AppendHistory(errBase, "OPEN", ticketMaster, 0, orderTypeStr, lots, sym, 0, 0, slVal, tpVal, 0, 0, 0, workerReadTimeMs, NowMs());
            continue;
         }

         double price = (type == ORDER_TYPE_BUY ? tick.ask : tick.bid);
         string commentStr = IntegerToString(ticketMaster);

         MqlTradeResult res;
         bool ok = SendDeal(sym, type, lotsWorker, price, slVal, tpVal, ticketMaster, commentStr, 0, res);
         long workerExecTimeMs = NowMs();

         if(!ok || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED))
         {
            int err = GetLastError();
            string errBase = "ERROR: OPEN (" + IntegerToString(err) + ") " + ErrorText(err) + " retcode=" + IntegerToString((int)res.retcode);
            Notify("Ticket: " + IntegerToString(ticketMaster) + " - " + errBase);
            AppendHistory(errBase, "OPEN", ticketMaster, 0, orderTypeStr, lots, sym, 0, 0, slVal, tpVal, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
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

            AppendHistory("EXITOSO", "OPEN", ticketMaster, posTicket, orderTypeStr, lots, sym, log.openPrice, log.openTime, log.sl, log.tp, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
         }
         else
         {
            AppendHistory("OPEN OK pero PositionSelect fallo", "OPEN", ticketMaster, 0, orderTypeStr, lots, sym, 0, 0, slVal, tpVal, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
         }
      }
      else if(eventType == "MODIFY")
      {
         int idx = FindOpenLog(ticketMaster);
         if(idx < 0)
         {
            AppendHistory("MODIFY fallido. No se encontro: " + IntegerToString(ticketMaster), "MODIFY", ticketMaster, 0, "", 0, "", 0, 0, slVal, tpVal, 0, 0, 0, workerReadTimeMs, 0);
            continue;
         }

         ulong ticketWorker = g_openLogs[idx].ticketWorker;
         string symLog = g_openLogs[idx].symbol;

         if(!PositionSelectByTicket(ticketWorker))
         {
            RemoveOpenLog(ticketMaster);
            DisplayOpenLogsInChart();
            AppendHistory("MODIFY fallido: Orden ya cerrada", "MODIFY", ticketMaster, ticketWorker, "", 0, symLog, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
            continue;
         }

         double newSL = (slVal > 0 ? slVal : 0.0);
         double newTP = (tpVal > 0 ? tpVal : 0.0);

         MqlTradeResult res;
         bool ok = SendSLTP(symLog, ticketWorker, newSL, newTP, res);
         long workerExecTimeMs = NowMs();

         if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL))
         {
            UpdateOpenLogSLTP(ticketMaster, newSL, newTP);
            DisplayOpenLogsInChart();
            string resTxt = "MODIFY OK SL=" + DoubleToString(newSL, 2) + " TP=" + DoubleToString(newTP, 2);
            AppendHistory(resTxt, "MODIFY", ticketMaster, ticketWorker, "", 0, symLog, 0, 0, newSL, newTP, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
            RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
         }
         else
         {
            ulong historyDeal = FindDealInHistory(ticketMaster);
            if(historyDeal > 0)
            {
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendHistory("MODIFY fallido: Orden ya cerrada", "MODIFY", ticketMaster, ticketWorker, "", 0, symLog, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
               RemoveTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
            }
            else
            {
               string errTxt = "MODIFY FALLO: " + FormatLastError("MODIFY") + " retcode=" + IntegerToString((int)res.retcode);
               if(!TicketInArray(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount))
               {
                  Notify("Ticket: " + IntegerToString(ticketMaster) + " - " + errTxt);
                  AddTicket(IntegerToString(ticketMaster), g_notifModifyTickets, g_notifModifyCount);
               }
               AppendHistory(errTxt, "MODIFY", ticketMaster, ticketWorker, "", 0, symLog, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, workerExecTimeMs);
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
            ulong historyDeal = FindDealInHistory(ticketMaster);
            if(historyDeal > 0)
               AppendHistory("Orden ya estaba cerrada", "CLOSE", ticketMaster, historyDeal, "", 0, "", 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            else
               AppendHistory("Close fallido. No se encontro: " + IntegerToString(ticketMaster), "CLOSE", ticketMaster, 0, "", 0, "", 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            continue;
         }

         ulong ticketWorker = g_openLogs[idx].ticketWorker;
         string symLog = g_openLogs[idx].symbol;

         if(!PositionSelectByTicket(ticketWorker))
         {
            ulong historyDeal = FindDealInHistory(ticketMaster);
            if(historyDeal > 0)
            {
               RemoveOpenLog(ticketMaster);
               DisplayOpenLogsInChart();
               AppendHistory("Orden ya estaba cerrada", "CLOSE", ticketMaster, ticketWorker, "", 0, symLog, 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
               RemoveTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            }
            else
            {
               AppendHistory("Close fallido. No se encontro: " + IntegerToString(ticketMaster), "CLOSE", ticketMaster, 0, "", 0, "", 0, 0, 0, 0, 0, 0, 0, workerReadTimeMs, 0);
            }
            continue;
         }

         long posType = PositionGetInteger(POSITION_TYPE);
         double volume = PositionGetDouble(POSITION_VOLUME);
         double profitBefore = PositionGetDouble(POSITION_PROFIT);

         MqlTick tick;
         if(!SymbolInfoTick(symLog, tick))
         {
            string errTxt = FormatLastError("CLOSE FALLO (SymbolInfoTick)");
            if(!TicketInArray(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount))
            {
               Notify("Ticket: " + IntegerToString(ticketMaster) + " - " + errTxt);
               AddTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            }
            AppendHistory(errTxt, "CLOSE", ticketMaster, ticketWorker, "", 0, symLog, 0, 0, 0, 0, 0, 0, profitBefore, workerReadTimeMs, NowMs());
            ArrayResize(remaining, remainingCount+1);
            remaining[remainingCount] = lines[i];
            remainingCount++;
            continue;
         }

         ENUM_ORDER_TYPE closeType = (posType == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
         double closePrice = (closeType == ORDER_TYPE_BUY ? tick.ask : tick.bid);

         MqlTradeResult res;
         bool ok = SendDeal(symLog, closeType, volume, closePrice, 0.0, 0.0, (int)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_COMMENT), ticketWorker, res);
         long workerExecTimeMs = NowMs();

         if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL))
         {
            AppendHistory("CLOSE OK", "CLOSE", ticketMaster, ticketWorker, "", 0, symLog, 0, 0, 0, 0, closePrice, TimeCurrent(), profitBefore, workerReadTimeMs, workerExecTimeMs);
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
               AppendHistory("CLOSE fallido: Orden ya cerrada", "CLOSE", ticketMaster, ticketWorker, "", 0, symLog, 0, 0, 0, 0, closePrice, TimeCurrent(), profitBefore, workerReadTimeMs, workerExecTimeMs);
               RemoveTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
            }
            else
            {
               string errTxt = FormatLastError("CLOSE FALLO") + " retcode=" + IntegerToString((int)res.retcode);
               if(!TicketInArray(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount))
               {
                  Notify("Ticket: " + IntegerToString(ticketMaster) + " - " + errTxt);
                  AddTicket(IntegerToString(ticketMaster), g_notifCloseTickets, g_notifCloseCount);
               }
               AppendHistory(errTxt, "CLOSE", ticketMaster, ticketWorker, "", 0, symLog, 0, 0, 0, 0, closePrice, TimeCurrent(), profitBefore, workerReadTimeMs, workerExecTimeMs);
               ArrayResize(remaining, remainingCount+1);
               remaining[remainingCount] = lines[i];
               remainingCount++;
            }
         }
      }
   }

   RewriteQueue(g_queueFile, remaining, remainingCount);
}
