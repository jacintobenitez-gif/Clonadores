//+------------------------------------------------------------------+
//|                                                      Extractor.mq4 |
//|  Spool por evento en Common\Files\V3\Phoenix\Spool                  |
//|  SOLO MARKET: BUY / SELL                                            |
//|  OPEN:   ticket + symbol + type + lots + SL + TP                    |
//|  MODIFY: ticket + SL_OLD/SL_NEW + TP_OLD/TP_NEW                     |
//|  CLOSE:  ticket                                                     |
//|  Escritura atómica: .tmp -> .txt                                    |
//|  Codificación UTF-8 igual que LectorOrdenes.mq4                    |
//+------------------------------------------------------------------+
#property strict
#property version   "1.02"

// -------------------- Inputs --------------------
input bool   InpUseCommonFiles   = true;                 // escribir en Common\Files (recomendado)
input string InpSpoolRelFolder   = "V3\\Phoenix\\Spool\\"; // carpeta relativa dentro de Common\Files
input int    InpThrottleMs       = 150;                  // mínimo ms entre evaluaciones
input bool   InpEmitOpenOnInit   = true;                 // al iniciar, emite OPEN de lo ya abierto
input int    InpTimerSeconds     = 1;                    // evaluar también sin ticks (recomendado)
input bool   InpDebug            = false;                // logs extra para diagnosticar (activar temporalmente)

// -------------------- Globals --------------------
int     g_prevTickets[];
double  g_prevSL[];
double  g_prevTP[];

uint    g_lastRunMs = 0;
int     g_seq       = 0;
int     g_dbgCycle  = 0;
int     g_lastOrdersTotal = -1;
long    g_lastTicketsHash = 0;

// -------------------- Helpers --------------------
bool Throttled()
{
   uint nowMs = GetTickCount();
   // IMPORTANTE: no castear a int. GetTickCount() y restas de uint pueden desbordar
   // y el cast a int puede volverlo negativo => throttled "para siempre".
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

int FindTicket(const int &arr[], int ticket)
{
   for(int i=0; i<ArraySize(arr); i++)
      if(arr[i] == ticket) return i;
   return -1;
}

bool IsMarketBuySell(int type)
{
   return (type == OP_BUY || type == OP_SELL);
}

string TypeToStr(int type)
{
   if(type == OP_BUY)  return "BUY";
   if(type == OP_SELL) return "SELL";
   return "UNKNOWN";
}

string SpoolBaseRel()
{
   string p = InpSpoolRelFolder;
   if(StringLen(p) > 0)
   {
      string last = StringSubstr(p, StringLen(p)-1, 1);
      if(last != "\\" && last != "/") p += "\\";
   }
   return p;
}

//+------------------------------------------------------------------+
//| Convierte string Unicode (MQL4) a bytes UTF-8                     |
//| (Igual que LectorOrdenes.mq4)                                     |
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

// --- Rename seguro: lee tmp y escribe en txt, luego borra tmp
bool AtomicPromoteTmpToTxt(string tmpRel, string finalRel)
{
   int flags = FILE_BIN | FILE_READ;
   if(InpUseCommonFiles) flags |= FILE_COMMON;
   
   // Leer archivo temporal
   int hTmp = FileOpen(tmpRel, flags);
   if(hTmp == INVALID_HANDLE)
   {
      Print("ERROR: no se pudo abrir tmp para leer: ", tmpRel, " err=", GetLastError());
      return false;
   }
   
   // Leer todo el contenido
   int fileSize = (int)FileSize(hTmp);
   uchar buffer[];
   ArrayResize(buffer, fileSize);
   FileReadArray(hTmp, buffer, 0, fileSize);
   FileClose(hTmp);
   
   // Escribir en archivo final
   flags = FILE_BIN | FILE_WRITE;
   if(InpUseCommonFiles) flags |= FILE_COMMON;
   
   int hFinal = FileOpen(finalRel, flags);
   if(hFinal == INVALID_HANDLE)
   {
      Print("ERROR: no se pudo crear archivo final: ", finalRel, " err=", GetLastError());
      return false;
   }
   
   FileWriteArray(hFinal, buffer);
   FileClose(hFinal);
   
   // Borrar archivo temporal
   flags = FILE_BIN;
   if(InpUseCommonFiles) flags |= FILE_COMMON;
   FileDelete(tmpRel, flags);
   
   return true;
}

// --- Escribe un fichero por evento (spool) con codificación UTF-8 igual que LectorOrdenes
bool WriteSpoolEvent(string evtLine, int ticket, string evtType)
{
   string relFolder = SpoolBaseRel();

   datetime nowGmt = TimeGMT();
   int ms = (int)(GetTickCount() % 1000);
   
   // Calcular export_time en milisegundos desde epoch (1970.01.01 00:00:00)
   // datetime es segundos desde epoch, multiplicar por 1000 y añadir milisegundos
   long exportTimeMs = (long)(nowGmt * 1000) + ms;

   g_seq++;

   // Nombre único y ordenable:
   // YYYYMMDD_HHMMSS_mmm__SEQ__TICKET__EVENT
   // En MQL4, extraer segundos manualmente desde datetime
   datetime dayStart = nowGmt - (nowGmt % 86400);  // Inicio del día
   int secondsFromMidnight = (int)(nowGmt - dayStart);
   int sec = secondsFromMidnight % 60;
   
   string fnameBase = StringFormat("%04d%02d%02d_%02d%02d%02d_%03d__%06d__%d__%s",
                                   TimeYear(nowGmt), TimeMonth(nowGmt), TimeDay(nowGmt),
                                   TimeHour(nowGmt), TimeMinute(nowGmt), sec,
                                   ms, g_seq, ticket, evtType);

   string tmpRel   = relFolder + fnameBase + ".tmp";
   string finalRel = relFolder + fnameBase + ".txt";

   // Añadir EXPORT_TIME a la línea antes de escribir
   string finalLine = evtLine + "|EXPORT_TIME=" + IntegerToString(exportTimeMs);

   // Usar FILE_BIN igual que LectorOrdenes (no FILE_TXT)
   int flags = FILE_BIN | FILE_WRITE;
   if(InpUseCommonFiles) flags |= FILE_COMMON;

   int h = FileOpen(tmpRel, flags);
   if(h == INVALID_HANDLE)
   {
      Print("ERROR: FileOpen tmp falló: ", tmpRel, " err=", GetLastError(),
            ". Asegúrate de que existe la carpeta: Common\\Files\\", relFolder);
      return false;
   }

   // Convertir línea a UTF-8 igual que LectorOrdenes
   uchar utf8Bytes[];
   StringToUTF8Bytes(finalLine, utf8Bytes);
   
   // Escribir bytes UTF-8
   FileWriteArray(h, utf8Bytes);
   
   // Escribir salto de línea UTF-8 (\n = 0x0A) igual que LectorOrdenes (no \r\n)
   uchar newline[] = {0x0A};
   FileWriteArray(h, newline);
   
   FileClose(h);

   bool ok = AtomicPromoteTmpToTxt(tmpRel, finalRel);
   if(InpDebug)
   {
      Print("DEBUG WriteSpoolEvent: evtType=", evtType,
            " ticket=", ticket,
            " tmp=", tmpRel,
            " final=", finalRel,
            " ok=", (ok ? "true" : "false"));
   }
   return ok;
}

// -------------------- Construcción de líneas de evento --------------------
string BuildOpenLine(int ticket, string symbol, string typeStr, double lots, double sl, double tp, long eventTimeMs)
{
   // Si SL/TP son 0.0, usar string vacío (igual que LectorOrdenes)
   string sSL = (sl > 0.0 ? DoubleToString(sl, Digits) : "");
   string sTP = (tp > 0.0 ? DoubleToString(tp, Digits) : "");
   
   return StringFormat("EVT|EVENT=OPEN|TICKET=%d|SYMBOL=%s|TYPE=%s|LOTS=%.2f|SL=%s|TP=%s|EVENT_TIME=%lld",
                       ticket, symbol, typeStr, lots, sSL, sTP, eventTimeMs);
}

string BuildModifyLine(int ticket, double slOld, double slNew, double tpOld, double tpNew, long eventTimeMs)
{
   return StringFormat("EVT|EVENT=MODIFY|TICKET=%d|SL_OLD=%s|SL_NEW=%s|TP_OLD=%s|TP_NEW=%s|EVENT_TIME=%lld",
                       ticket,
                       DoubleToString(slOld, Digits), DoubleToString(slNew, Digits),
                       DoubleToString(tpOld, Digits), DoubleToString(tpNew, Digits),
                       eventTimeMs);
}

string BuildCloseLine(int ticket, long eventTimeMs)
{
   return StringFormat("EVT|EVENT=CLOSE|TICKET=%d|EVENT_TIME=%lld", ticket, eventTimeMs);
}

// -------------------- Core --------------------
void ProcessOnce(bool forceEmitAllOpen)
{
   g_dbgCycle++;
   int totalNow = OrdersTotal();

   // 1) Estado actual (tickets + SL/TP) SOLO BUY/SELL
   int    curTickets[];
   double curSL[];
   double curTP[];

   long ticketsHash = 1469598103934665603; // FNV-1a offset basis (aprox)
   int total = totalNow;
   for(int i=0; i<total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      int otype = OrderType();
      if(!IsMarketBuySell(otype))
         continue;

      int ticket = OrderTicket();
      double sl  = OrderStopLoss();
      double tp  = OrderTakeProfit();

      // hash ligero para detectar cambios de tickets sin spamear logs
      ticketsHash ^= (long)ticket;
      ticketsHash *= 1099511628211;

      int n = ArraySize(curTickets);
      ArrayResize(curTickets, n+1);
      ArrayResize(curSL,      n+1);
      ArrayResize(curTP,      n+1);

      curTickets[n] = ticket;
      curSL[n]      = sl;
      curTP[n]      = tp;
   }

   bool changed = (totalNow != g_lastOrdersTotal) || (ticketsHash != g_lastTicketsHash);
   if(InpDebug && (changed || forceEmitAllOpen))
   {
      Print("DEBUG ProcessOnce: forceEmitAllOpen=", (forceEmitAllOpen ? "true":"false"),
            " OrdersTotal=", totalNow,
            " prevTickets=", ArraySize(g_prevTickets),
            " curMarketTickets=", ArraySize(curTickets),
            " Account=", AccountNumber(),
            " SymbolChart=", Symbol());
      for(int k=0; k<ArraySize(curTickets); k++)
      {
         int t = curTickets[k];
         if(OrderSelect(t, SELECT_BY_TICKET, MODE_TRADES))
         {
            Print("DEBUG Scan: ticket=", t,
                  " sym=", OrderSymbol(),
                  " type=", TypeToStr(OrderType()),
                  " magic=", OrderMagicNumber(),
                  " openTime=", TimeToString(OrderOpenTime(), TIME_DATE|TIME_SECONDS));
         }
      }
   }
   g_lastOrdersTotal = totalNow;
   g_lastTicketsHash = ticketsHash;

   // 2) OPEN + MODIFY
   for(int c=0; c<ArraySize(curTickets); c++)
   {
      int ticket = curTickets[c];
      int pIdx   = FindTicket(g_prevTickets, ticket);

      bool inTrades = OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES);

      if(forceEmitAllOpen || pIdx < 0)
      {
         if(inTrades && IsMarketBuySell(OrderType()))
         {
            if(InpDebug)
               Print("DEBUG OPEN candidate: ticket=", ticket, " pIdx=", pIdx, " force=", (forceEmitAllOpen ? "true":"false"));

            // Para OPEN: usar OrderOpenTime() convertido a milisegundos
            datetime openTime = OrderOpenTime();
            long eventTimeMs = (long)(openTime * 1000);

            // Añadir OPEN_TIME_UTC_MS (epoch UTC ms) para que Python pueda comparar en UTC sin líos de huso horario.
            // Offset servidor vs UTC (segundos): TimeCurrent() - TimeGMT()
            int serverOffsetSec = (int)(TimeCurrent() - TimeGMT());
            long openTimeUtcMs = (long)((openTime - serverOffsetSec) * 1000);
            
            // Añadir OPEN_TIME_MT_PC_MS (epoch ms ajustado a la hora local del PC donde corre MT4)
            // Offset PC vs UTC (segundos): TimeLocal() - TimeGMT()
            int pcOffsetSec = (int)(TimeLocal() - TimeGMT());
            long openTimeMtPcMs = openTimeUtcMs + (long)pcOffsetSec * 1000;
            
            string lineO = BuildOpenLine(ticket,
                                         OrderSymbol(),
                                         TypeToStr(OrderType()),
                                         OrderLots(),
                                         OrderStopLoss(),
                                         OrderTakeProfit(),
                                         eventTimeMs);
            lineO = lineO + "|OPEN_TIME_UTC_MS=" + StringFormat("%lld", openTimeUtcMs);
            lineO = lineO + "|OPEN_TIME_MT_PC_MS=" + StringFormat("%lld", openTimeMtPcMs);
            bool okW = WriteSpoolEvent(lineO, ticket, "OPEN");
            if(InpDebug)
               Print("DEBUG OPEN write: ticket=", ticket, " ok=", (okW ? "true":"false"));
         }
      }
      else
      {
         // MODIFY (solo SL/TP)
         double slNew = curSL[c];
         double tpNew = curTP[c];
         double slOld = g_prevSL[pIdx];
         double tpOld = g_prevTP[pIdx];

         if(slNew != slOld || tpNew != tpOld)
         {
            // Para MODIFY: usar TimeCurrent() convertido a milisegundos
            datetime currentTime = TimeCurrent();
            long eventTimeMs = (long)(currentTime * 1000) + (GetTickCount() % 1000);
            
            string lineM = BuildModifyLine(ticket, slOld, slNew, tpOld, tpNew, eventTimeMs);
            WriteSpoolEvent(lineM, ticket, "MODIFY");
         }
      }
   }

   // 3) CLOSE
   if(!forceEmitAllOpen)
   {
      for(int p=0; p<ArraySize(g_prevTickets); p++)
      {
         int tPrev = g_prevTickets[p];
         int cIdx  = FindTicket(curTickets, tPrev);

         if(cIdx < 0)
         {
            // Para CLOSE: usar TimeCurrent() convertido a milisegundos
            datetime currentTime = TimeCurrent();
            long eventTimeMs = (long)(currentTime * 1000) + (GetTickCount() % 1000);
            
            string lineC = BuildCloseLine(tPrev, eventTimeMs);
            WriteSpoolEvent(lineC, tPrev, "CLOSE");
         }
      }
   }

   // 4) Update prev state
   // En MQL4 con #property strict, no se puede asignar arrays directamente
   // Necesitamos copiar elemento por elemento
   ArrayResize(g_prevTickets, ArraySize(curTickets));
   ArrayResize(g_prevSL,      ArraySize(curSL));
   ArrayResize(g_prevTP,      ArraySize(curTP));
   
   for(int i = 0; i < ArraySize(curTickets); i++)
   {
      g_prevTickets[i] = curTickets[i];
      g_prevSL[i]      = curSL[i];
      g_prevTP[i]      = curTP[i];
   }
}

// -------------------- MT4 lifecycle --------------------
int OnInit()
{
   ArrayResize(g_prevTickets, 0);
   ArrayResize(g_prevSL,      0);
   ArrayResize(g_prevTP,      0);

   g_lastRunMs = 0;
   g_seq       = 0;

   if(InpEmitOpenOnInit)
      ProcessOnce(true); // emite OPEN de todas las abiertas actuales

   Print("Extractor v1.02 (BUY/SELL) listo. FolderRel=", SpoolBaseRel(),
         " common=", (InpUseCommonFiles ? "true":"false"));
   Print("Codificación UTF-8 igual que LectorOrdenes.mq4");
   Print("Asegúrate de que existe la carpeta: Common\\Files\\", SpoolBaseRel());
   Print("Timer: ", InpTimerSeconds, "s (para detectar OPEN aunque no haya ticks)");

   EventSetTimer(InpTimerSeconds);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTick()
{
   if(Throttled()) return;
   ProcessOnce(false);
}

void OnTimer()
{
   if(Throttled()) return;
   if(InpDebug)
   {
      // Heartbeat de diagnóstico: confirma que OnTimer corre y qué ve MT4 como OrdersTotal()
      Print("DEBUG OnTimer: Account=", AccountNumber(),
            " Server=", AccountServer(),
            " OrdersTotal=", OrdersTotal(),
            " TimeCurrent=", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
            " TimeLocal=", TimeToString(TimeLocal(), TIME_DATE|TIME_SECONDS));
   }
   ProcessOnce(false);
}
//+------------------------------------------------------------------+
