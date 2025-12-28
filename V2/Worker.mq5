//+------------------------------------------------------------------+
//|                                                     Worker.mq5   |
//|                Lee cola_WORKER_<account>.txt y ejecuta órdenes   |
//|                Historiza y notifica vía SendNotification         |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

input bool   InpFondeo        = true;
input double InpLotMultiplier = 1.0;
input double InpFixedLots     = 0.10;
input int    InpSlippage      = 30;     // puntos
input ulong  InpMagicNumber   = 0;
input int    InpTimerSeconds  = 1;

// Rutas relativas a Common\Files
string BASE_SUBDIR   = "V2\\Phoenix";
string g_workerId    = "";
string g_queueFile   = "";
string g_historyFile = "";

// Instancia de CTrade para operaciones
CTrade trade;

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
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
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
//| Formatea código y descripción de error de MT5                    |
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
   string full = "W: " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + " - " + msg;
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
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
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
   
   // 1. Calcular contract_size del destino
   double csDest = GetContractSize(symbol);
   Print("[DEBUG] ComputeWorkerLots: csDest calculado=", csDest);
   if(csDest<=0.0) 
   {
      csDest = 1.0;
      Print("[DEBUG] ComputeWorkerLots: csDest <= 0, ajustado a 1.0");
   }
   
   // 2. Calcular ratio de normalización (csOrigin siempre existe)
   double ratio = csOrigin / csDest;
   Print("[DEBUG] ComputeWorkerLots: ratio = csOrigin(", csOrigin, ") / csDest(", csDest, ") = ", ratio);
   
   // 3. Normalizar lotes del master
   double normalizedLots = masterLots * ratio;
   Print("[DEBUG] ComputeWorkerLots: normalizedLots = masterLots(", masterLots, ") * ratio(", ratio, ") = ", normalizedLots);
   
   // 4. Aplicar multiplicador SOLO si es cuenta de fondeo
   double finalLots;
   if(InpFondeo)
   {
      finalLots = normalizedLots * InpLotMultiplier;
      Print("[DEBUG] ComputeWorkerLots: InpFondeo=true, finalLots = normalizedLots(", normalizedLots, ") * InpLotMultiplier(", InpLotMultiplier, ") = ", finalLots);
   }
   else
   {
      finalLots = normalizedLots;
      Print("[DEBUG] ComputeWorkerLots: InpFondeo=false, finalLots = normalizedLots(", normalizedLots, ") sin multiplicador");
   }
   
   // 5. Ajustar a min/max/step del símbolo
   double adjustedLots = AdjustFixedLots(symbol, finalLots);
   Print("[DEBUG] ComputeWorkerLots: adjustedLots después de AdjustFixedLots = ", adjustedLots);
   
   return(adjustedLots);
}

//+------------------------------------------------------------------+
//| Detecta automáticamente el tipo de llenado para un símbolo      |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingType(string symbol)
{
   // Intentar obtener el tipo de llenado del símbolo
   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   
   // Si el símbolo soporta FOK, usarlo
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   
   // Si soporta IOC, usarlo
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   
   // Por defecto, usar RETURN
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Lee todas las líneas del archivo de cola                         |
//+------------------------------------------------------------------+
int ReadQueue(string relPath, string &lines[])
{
   int handle = FileOpen(relPath, FILE_READ|FILE_TXT|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(handle==INVALID_HANDLE)
      return(0);
   int count=0;
   while(!FileIsEnding(handle))
   {
      string ln = FileReadString(handle);
      // FileReadString se detiene en \n; conservar tal cual
      if(StringLen(ln)==0) { continue; }
      ArrayResize(lines, count+1);
      lines[count]=ln;
      count++;
   }
   FileClose(handle);
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
   int symDigits = (int)SymbolInfoInteger(ev.symbol, SYMBOL_DIGITS);
   if(symDigits<=0) symDigits = (int)_Digits;
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
//| Busca posición abierta por symbol + comment (=ticket)           |
//+------------------------------------------------------------------+
ulong FindOpenPosition(const string symbol, const string ticket)
{
   int total = PositionsTotal();
   for(int i=0;i<total;i++)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket==0) continue;
      
      // PositionGetTicket selecciona automáticamente la posición
      // pero verificamos que la selección sea exitosa por seguridad
      if(!PositionSelectByTicket(posTicket)) continue;
      
      string posSymbol = PositionGetString(POSITION_SYMBOL);
      if(posSymbol!=symbol) continue;
      
      string posComment = PositionGetString(POSITION_COMMENT);
      if(posComment!=ticket) continue;
      
      if(InpMagicNumber>0)
      {
         ulong posMagic = PositionGetInteger(POSITION_MAGIC);
         if(posMagic!=InpMagicNumber) continue;
      }
      return(posTicket);
   }
   return(0);
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

   tmp = Trim(parts[3]); StringReplace(tmp, ",", "."); ev.lots = StringToDouble(tmp);
   tmp = Trim(parts[4]); ev.symbol = Trim(Upper(tmp));

   if(n>5)
   {
      tmp = Trim(parts[5]); StringReplace(tmp, ",", "."); ev.sl = StringToDouble(tmp);
   }
   else ev.sl = 0.0;

   if(n>6)
   {
      tmp = Trim(parts[6]); StringReplace(tmp, ",", "."); ev.tp = StringToDouble(tmp);
   }
   else ev.tp = 0.0;
   if(n>7)
   {
      tmp = Trim(parts[7]); StringReplace(tmp, ",", "."); ev.csOrigin = StringToDouble(tmp);
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
   g_workerId    = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   g_queueFile   = CommonRelative("cola_WORKER_" + g_workerId + ".txt");
   g_historyFile = CommonRelative("historico_WORKER_" + g_workerId + ".txt");

   if(!EnsureBaseFolder())
      return(INIT_FAILED);

   // Configurar CTrade
   trade.SetExpertMagicNumber((int)InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetAsyncMode(false);

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
         // línea inválida: descartar
         continue;
      }

      // Asegurar símbolo
      if(!SymbolSelect(ev.symbol, true))
      {
         int errCodeSym = GetLastError();
         string errDescSym = ErrorText(errCodeSym);
         string msg = "Ticket: " + ev.ticket + " - " + ev.eventType + " FALLO: SymbolSelect (" + IntegerToString(errCodeSym) + ") " + errDescSym;
         Notify(msg);
         if(ev.eventType!="OPEN")
         {
            // mantener para reintento en CLOSE/MODIFY
            ArrayResize(remaining, remainingCount+1);
            remaining[remainingCount]=ev.originalLine;
            remainingCount++;
         }
         // OPEN no se reintenta
         continue;
      }

      // Calcular lotaje (tras asegurar símbolo)
      Print("[DEBUG] OnTimer: Llamando ComputeWorkerLots con symbol=", ev.symbol, " ev.lots=", ev.lots, " ev.csOrigin=", ev.csOrigin);
      double lotsWorker = ComputeWorkerLots(ev.symbol, ev.lots, ev.csOrigin);
      Print("[DEBUG] OnTimer: lotsWorker calculado = ", lotsWorker);

      if(ev.eventType=="OPEN")
      {
         // Obtener tick actual para precios
         MqlTick tick;
         if(!SymbolInfoTick(ev.symbol, tick))
         {
            int errCode = GetLastError();
            string errDesc = ErrorText(errCode);
            string errBase = "ERROR: OPEN (" + IntegerToString(errCode) + ") " + errDesc;
            string err = "Ticket: " + ev.ticket + " - " + errBase;
            Notify(err);
            AppendHistory(errBase, ev, 0, 0, 0, 0, 0);
            continue;
         }
         
         // Configurar tipo de llenado según el símbolo
         ENUM_ORDER_TYPE_FILLING fillingType = GetFillingType(ev.symbol);
         trade.SetTypeFilling(fillingType);
         
         bool result = false;
         // Usar precio explícito del tick (más seguro y explícito)
         double price = (ev.orderType=="BUY" ? tick.ask : tick.bid);
         if(ev.orderType=="BUY")
            result = trade.Buy(lotsWorker, ev.symbol, price, ev.sl, ev.tp, ev.ticket);
         else
            result = trade.Sell(lotsWorker, ev.symbol, price, ev.sl, ev.tp, ev.ticket);
         
         if(!result)
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
         ulong posTicket = FindOpenPosition(ev.symbol, ev.ticket);
         if(posTicket==0)
         {
            AppendHistory("No existe operacion abierta", ev, 0, 0, 0, 0, 0);
            RemoveTicket(ev.ticket, g_notifCloseTickets, g_notifCloseCount);
            continue;
         }
         if(!PositionSelectByTicket(posTicket))
         {
            AppendHistory(FormatLastError("ERROR: CLOSE select"), ev, 0, 0, 0, 0, 0);
            // mantener para reintento
            ArrayResize(remaining, remainingCount+1);
            remaining[remainingCount]=ev.originalLine;
            remainingCount++;
            continue;
         }
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double volume = PositionGetDouble(POSITION_VOLUME);
         
         // Obtener tick actual para precio de cierre
         MqlTick tick;
         if(!SymbolInfoTick(ev.symbol, tick))
         {
            AppendHistory(FormatLastError("ERROR: CLOSE - No tick disponible"), ev, 0, 0, 0, 0, 0);
            ArrayResize(remaining, remainingCount+1);
            remaining[remainingCount]=ev.originalLine;
            remainingCount++;
            continue;
         }
         
         double price = 0.0;
         if(posType == POSITION_TYPE_BUY)
            price = tick.bid;
         else
            price = tick.ask;
         double profitBefore = PositionGetDouble(POSITION_PROFIT);
         
         // Configurar tipo de llenado según el símbolo
         ENUM_ORDER_TYPE_FILLING fillingType = GetFillingType(ev.symbol);
         trade.SetTypeFilling(fillingType);
         
         if(trade.PositionClose(posTicket))
         {
            string ok = "Ticket: " + ev.ticket + " - CLOSE EXITOSO: " + ev.symbol + " " + ev.orderType + " " + DoubleToString(volume,2) + " lots";
            Notify(ok);
            AppendHistory("CLOSE OK", ev, 0, 0, price, TimeCurrent(), profitBefore);
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
            // mantener para reintento
            ArrayResize(remaining, remainingCount+1);
            remaining[remainingCount]=ev.originalLine;
            remainingCount++;
         }
      }
      else if(ev.eventType=="MODIFY")
      {
         ulong posTicket = FindOpenPosition(ev.symbol, ev.ticket);
         if(posTicket==0)
         {
            AppendHistory("No existe operacion abierta", ev, 0, 0, 0, 0, 0);
            RemoveTicket(ev.ticket, g_notifModifyTickets, g_notifModifyCount);
            continue;
         }
         if(!PositionSelectByTicket(posTicket))
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
         if(trade.PositionModify(posTicket, newSL, newTP))
         {
            int symDigits = (int)SymbolInfoInteger(ev.symbol, SYMBOL_DIGITS);
            if(symDigits<=0) symDigits = (int)_Digits;
            string ok = "Ticket: " + ev.ticket + " - MODIFY EXITOSO: " + ev.symbol + " " + ev.orderType + " " + DoubleToString(PositionGetDouble(POSITION_VOLUME),2) + " lots SL=" + DoubleToString(newSL,symDigits) + " TP=" + DoubleToString(newTP,symDigits);
            Notify(ok);
            string resHist = "MODIFY OK SL=" + DoubleToString(newSL,symDigits) + " TP=" + DoubleToString(newTP,symDigits);
            AppendHistory(resHist, ev, 0, 0, 0, 0, 0);
            RemoveTicket(ev.ticket, g_notifModifyTickets, g_notifModifyCount);
         }
         else
         {
            // Capturar error antes de otras llamadas para no perder el código
            int errCode = GetLastError();
            string errDesc = ErrorText(errCode);
            string errBase = "MODIFY FALLO (" + IntegerToString(errCode) + ") " + errDesc;

            int symDigits2 = (int)SymbolInfoInteger(ev.symbol, SYMBOL_DIGITS);
            if(symDigits2<=0) symDigits2 = (int)_Digits;
            string errDetail = "ERROR: MODIFY SL=" + DoubleToString(newSL,symDigits2) + " TP=" + DoubleToString(newTP,symDigits2);
            string err = "Ticket: " + ev.ticket + " - " + errBase + " " + errDetail;
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

//+------------------------------------------------------------------+

