//+------------------------------------------------------------------+
//|                                                     Worker.mq4   |
//|                Lee cola_WORKER_<account>.txt y ejecuta órdenes   |
//|                Historiza y notifica vía SendNotification         |
//+------------------------------------------------------------------+
#property strict

input bool   InpFondeo        = true;
input double InpLotMultiplier = 1.0;
input double InpFixedLots     = 0.10;
input int    InpSlippage      = 30;     // pips
input int    InpMagicNumber   = 0;
input int    InpTimerSeconds  = 1;

// Rutas relativas a Common\Files
string BASE_SUBDIR   = "V2\\Phoenix";
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
   double csOrigin;   // contract size en el origen
   string originalLine;
};

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
//| Calcula lotaje del worker                                        |
//+------------------------------------------------------------------+
double ComputeWorkerLots(string symbol, double masterLots, double csOrigin)
{
   Print("[DEBUG] ComputeWorkerLots: symbol=", symbol, " masterLots=", masterLots, " csOrigin=", csOrigin);
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
      // Si NO es cuenta de fondeo: aplicar normalización por contract size y usar FixedLots
      // 1. Calcular contract_size del destino
      double csDest = GetContractSize(symbol);
      Print("[DEBUG] ComputeWorkerLots: csDest calculado=", csDest);
      if(csDest<=0.0) 
      {
         csDest = 1.0;
         Print("[DEBUG] ComputeWorkerLots: csDest <= 0, ajustado a 1.0");
      }
      
      // 2. Calcular ratio de normalización
      double ratio = 1.0;
      if(csOrigin > 0.0)
      {
         ratio = csOrigin / csDest;
      }
      else
      {
         Print("[DEBUG] ComputeWorkerLots: csOrigin <= 0, usando ratio=1.0 (sin normalización por contract size)");
      }
      Print("[DEBUG] ComputeWorkerLots: ratio = csOrigin(", csOrigin, ") / csDest(", csDest, ") = ", ratio);
      
      // 3. Aplicar ratio a FixedLots
      finalLots = InpFixedLots * ratio;
      Print("[DEBUG] ComputeWorkerLots: InpFondeo=false, finalLots = InpFixedLots(", InpFixedLots, ") * ratio(", ratio, ") = ", finalLots);
   }
   
   // 4. Ajustar a min/max/step del símbolo
   double adjustedLots = AdjustFixedLots(symbol, finalLots);
   Print("[DEBUG] ComputeWorkerLots: adjustedLots después de AdjustFixedLots = ", adjustedLots);
   
   return(adjustedLots);
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
   
   if(bytesRead != fileSize)
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
   FileWrite(h, "timestamp_ejecucion;resultado;event_type;ticket;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit");
   FileClose(h);
}

//+------------------------------------------------------------------+
//| Añade línea al histórico                                         |
//+------------------------------------------------------------------+
void AppendHistory(const string result, const EventRec &ev, double openPrice=0.0, datetime openTime=0, double closePrice=0.0, datetime closeTime=0, double profit=0.0)
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
   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string sOpenPrice  = (openPrice!=0.0 ? DoubleToString(openPrice, symDigits) : "");
   string sOpenTime   = (openTime>0 ? TimeToString(openTime, TIME_DATE|TIME_SECONDS) : "");
   string sClosePrice = (closePrice!=0.0 ? DoubleToString(closePrice, symDigits) : "");
   string sCloseTime  = (closeTime>0 ? TimeToString(closeTime, TIME_DATE|TIME_SECONDS) : "");
   string sSl = (ev.sl>0 ? DoubleToString(ev.sl, symDigits) : "");
   string sTp = (ev.tp>0 ? DoubleToString(ev.tp, symDigits) : "");
   string sProfit = (closeTime>0 ? DoubleToString(profit, 2) : "");
   string line = ts + ";" + result + ";" + ev.eventType + ";" + ev.ticket + ";" + ev.orderType + ";" +
                 DoubleToString(ev.lots, 2) + ";" + ev.symbol + ";" +
                 sOpenPrice + ";" + sOpenTime + ";" + sSl + ";" + sTp + ";" +
                 sClosePrice + ";" + sCloseTime + ";" + sProfit;
   FileWrite(h, line);
   FileClose(h);
}

//+------------------------------------------------------------------+
//| Busca orden abierta por comment (=ticket origen)                 |
//+------------------------------------------------------------------+
int FindOpenOrder(const string ticket)
{
   int total=OrdersTotal();
   for(int i=0;i<total;i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderComment()!=ticket)
         continue;
      if(InpMagicNumber>0 && OrderMagicNumber()!=InpMagicNumber)
         continue;
      return(OrderTicket());
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
   if(n<5)
   {
      Print("[ERROR] ParseLine: Línea tiene menos de 5 campos (", n, "), descartando");
      return(false);
   }
   string tmp;

   tmp = Trim(parts[0]); ev.eventType = Upper(tmp);
   ev.ticket = Trim(parts[1]);
   tmp = Trim(parts[2]); ev.orderType = Upper(tmp);

   tmp = Trim(parts[3]); StringReplace(tmp, ",", "."); ev.lots = StrToDouble(tmp);
   tmp = Trim(parts[4]); ev.symbol = Trim(Upper(tmp));

   if(n>5)
   {
      tmp = Trim(parts[5]); StringReplace(tmp, ",", "."); ev.sl = StrToDouble(tmp);
   }
   else ev.sl = 0.0;

   if(n>6)
   {
      tmp = Trim(parts[6]); StringReplace(tmp, ",", "."); ev.tp = StrToDouble(tmp);
   }
   else ev.tp = 0.0;
   if(n>7)
   {
      tmp = Trim(parts[7]); StringReplace(tmp, ",", "."); ev.csOrigin = StrToDouble(tmp);
      Print("[DEBUG] ParseLine: csOrigin leído de parts[7]='", parts[7], "' -> tmp='", tmp, "' -> csOrigin=", ev.csOrigin);
   }
   else 
   {
      ev.csOrigin = 0.0;
      Print("[DEBUG] ParseLine: No hay campo 7, csOrigin=0.0");
   }
   ev.originalLine = line;
   
   Print("[DEBUG] ParseLine: eventType=", ev.eventType, " ticket=", ev.ticket, " symbol=", ev.symbol, " lots=", ev.lots, " csOrigin=", ev.csOrigin);
   
   if(ev.eventType=="" || ev.ticket=="" || ev.symbol=="")
   {
      Print("[ERROR] ParseLine: Campos requeridos vacíos. eventType='", ev.eventType, "' ticket='", ev.ticket, "' symbol='", ev.symbol, "'");
      return(false);
   }
   Print("[DEBUG] ParseLine: Parseo exitoso");
   return(true);
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   g_workerId    = IntegerToString(AccountNumber());
   g_queueFile   = CommonRelative("cola_WORKER_" + g_workerId + ".txt");
   g_historyFile = CommonRelative("historico_WORKER_" + g_workerId + ".txt");

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
   string lines[];
   int total = ReadQueue(g_queueFile, lines);
   if(total==0)
      return;

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
            AppendHistory(msg, ev, 0, 0, 0, 0, 0);
            continue; // OPEN no se reintenta
         }
         Print("[DEBUG] OnTimer: SymbolSelect exitoso para symbol=", ev.symbol);
         
         // Verificar si ya existe una orden abierta con este ticket (evitar duplicados)
         int existingOrder = FindOpenOrder(ev.ticket);
         if(existingOrder >= 0)
         {
            Print("[DEBUG] OnTimer: Ya existe orden abierta con ticket=", ev.ticket, " orderTicket=", existingOrder, ", saltando OPEN");
            AppendHistory("Ya existe operacion abierta", ev, 0, 0, 0, 0, 0);
            continue; // Saltar esta línea, no reintentar
         }
         
         // Calcular lotaje (solo para OPEN)
         Print("[DEBUG] OnTimer: Llamando ComputeWorkerLots con symbol=", ev.symbol, " ev.lots=", ev.lots, " ev.csOrigin=", ev.csOrigin);
         double lotsWorker = ComputeWorkerLots(ev.symbol, ev.lots, ev.csOrigin);
         Print("[DEBUG] OnTimer: lotsWorker calculado = ", lotsWorker);
         
         int type = (ev.orderType=="BUY" ? OP_BUY : OP_SELL);
         double price = (type==OP_BUY ? Ask : Bid);
         Print("[DEBUG] OnTimer: Preparando OrderSend: symbol=", ev.symbol, " type=", type, " lots=", lotsWorker, " price=", price, " sl=", ev.sl, " tp=", ev.tp, " comment=", ev.ticket);
         ResetLastError();
         int ticketNew = OrderSend(ev.symbol, type, lotsWorker, price, InpSlippage, ev.sl, ev.tp, ev.ticket, InpMagicNumber, 0, clrNONE);
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
            AppendHistory(errBase, ev, 0, 0, 0, 0, 0);
            // no reintento
         }
         else
         {
            string ok = "Ticket: " + ev.ticket + " - OPEN EXITOSO: " + ev.symbol + " " + ev.orderType + " " + DoubleToString(lotsWorker,2) + " lots";
            Notify(ok);
            AppendHistory("EXITOSO", ev, 0, 0, 0, 0, 0);
         }
      }
      else if(ev.eventType=="CLOSE")
      {
         int orderTicket = FindOpenOrder(ev.ticket);
         if(orderTicket<0)
         {
            AppendHistory("No existe operacion abierta", ev, 0, 0, 0, 0, 0);
            RemoveTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
            continue;
         }
         if(!OrderSelect(orderTicket, SELECT_BY_TICKET))
         {
            AppendHistory(FormatLastError("ERROR: CLOSE select"), ev, 0, 0, 0, 0, 0);
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
            string ok = "Ticket: " + ev.ticket + " - CLOSE EXITOSO: " + DoubleToString(volume,2) + " lots";
            Notify(ok);
            AppendHistory("CLOSE OK", ev, 0, 0, closePrice, closeTime, profitBefore);
            RemoveTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
         }
         else
         {
            string err = "Ticket: " + ev.ticket + " - " + FormatLastError("CLOSE FALLO");
            if(!TicketInArray(ev.ticket, g_notifCloseTickets, g_notifCloseCount))
            {
               Notify(err);
               AddTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
            }
            // Registrar en histórico con los campos CLOSE obtenidos
            AppendHistory(err, ev, 0, 0, closePrice, closeTime, profitBefore);
            // mantener para reintento
            ArrayResize(remaining, remainingCount+1);
            remaining[remainingCount]=ev.originalLine;
            remainingCount++;
         }
      }
      else if(ev.eventType=="MODIFY")
      {
         int orderTicket = FindOpenOrder(ev.ticket);
         if(orderTicket<0)
         {
            AppendHistory("No existe operacion abierta", ev, 0, 0, 0, 0, 0);
            RemoveTicket(ev.ticket, g_notifModifyTickets, g_notifModifyCount);
            continue;
         }
         if(!OrderSelect(orderTicket, SELECT_BY_TICKET))
         {
            AppendHistory(FormatLastError("ERROR: MODIFY select"), ev, 0, 0, 0, 0, 0);
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
            string ok = "Ticket: " + ev.ticket + " - MODIFY EXITOSO: SL=" + DoubleToString(newSL,2) + " TP=" + DoubleToString(newTP,2);
            Notify(ok);
            string resHist = "MODIFY OK SL=" + DoubleToString(newSL,2) + " TP=" + DoubleToString(newTP,2);
            AppendHistory(resHist, ev, 0, 0, 0, 0, 0);
            RemoveTicket(ev.ticket, g_notifModifyTickets, g_notifModifyCount);
         }
         else
         {
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
            AppendHistory(err, ev, 0, 0, 0, 0, 0);
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

