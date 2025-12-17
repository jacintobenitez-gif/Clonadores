//+------------------------------------------------------------------+
//|                                              ClonadorOrdenes.mq4 |
//|   Lee TradeEvents.csv (Common\Files) y clona operaciones         |
//|   OPEN/CLOSE del maestro en esta cuenta (MT4)                    |
//+------------------------------------------------------------------+
#property strict

//--- Inputs
input string InpCsvFileName     = "TradeEvents.csv"; // nombre del CSV en Common\Files
input int    InpTimerSeconds    = 3;                 // cada cuántos segundos revisar
input int    InpSlippagePoints  = 30;                // slippage en puntos para abrir/cerrar
input bool   InpCuentaFondeo    = false;             // true = cuenta de fondeo (copiar lotes)
input double InpFixedLots       = 0.10;              // lote fijo cuando NO es cuenta de fondeo

//--- copia interna del timer
int g_TimerSeconds = 5;

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+

// Convierte "BUY"/"SELL" a tipo de orden MQL4
int TextToOrderType(string text)
{
   string t = text;
   StringToUpper(t);

   if(t == "BUY")   return OP_BUY;
   if(t == "SELL")  return OP_SELL;

   return -1;
}

// Bid / Ask para un símbolo cualquiera
double GetBid(string symbol)
{
   if(symbol == Symbol()) return Bid;
   return MarketInfo(symbol, MODE_BID);
}

double GetAsk(string symbol)
{
   if(symbol == Symbol()) return Ask;
   return MarketInfo(symbol, MODE_ASK);
}

// Calcula lotaje esclavo
// - Cuenta de fondeo: copia el lote del maestro
// - No fondeo: usa lote fijo InpFixedLots (normalizado a min/max/step)
double ComputeSlaveLots(string symbol, double masterLots)
{
   if(InpCuentaFondeo)
      return masterLots;

   double rawLots = InpFixedLots;

   double minLot   = MarketInfo(symbol, MODE_MINLOT);
   double maxLot   = MarketInfo(symbol, MODE_MAXLOT);
   double lotStep  = MarketInfo(symbol, MODE_LOTSTEP);
   if(lotStep <= 0.0) lotStep = minLot;

   double lots = rawLots;

   // Redondear al paso de lote hacia abajo
   lots = MathFloor(lots / lotStep) * lotStep;

   // Respetar mínimos y máximos del símbolo
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   int lotDigits = 2;
   if(lotStep > 0.0)
   {
      double tmp = lotStep;
      lotDigits = 0;
      while(tmp < 1.0 && lotDigits < 4)
      {
         tmp *= 10.0;
         lotDigits++;
      }
   }

   return NormalizeDouble(lots, lotDigits);
}

// Comprueba si YA existe un clon (abierto o en histórico)
// Basado en: símbolo + comentario "CLONE Tkt <ticket>"
bool CloneAlreadyExists(string symbol, string cloneComment)
{
   // 1) ÓRDENES ABIERTAS
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol()  == symbol &&
         OrderComment() == cloneComment)
         return(true);
   }

   // 2) HISTÓRICO
   for(int j = OrdersHistoryTotal() - 1; j >= 0; j--)
   {
      if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY))
         continue;

      if(OrderSymbol()  == symbol &&
         OrderComment() == cloneComment)
         return(true);
   }

   return(false);
}

// Cierra el clon si está abierto (mismo símbolo + comentario)
bool CloseCloneIfOpen(string symbol, string cloneComment)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol()  != symbol)        continue;
      if(OrderComment() != cloneComment)  continue;

      int    type = OrderType();
      double lots = OrderLots();

      double price = (type == OP_BUY ? GetBid(symbol) : GetAsk(symbol));

      bool ok = OrderClose(OrderTicket(), lots, price, InpSlippagePoints, clrRed);
      if(!ok)
      {
         int err = GetLastError();
         PrintFormat("OIExecutor(MT4): error al cerrar clon %s (%s). Error=%d",
                     symbol, cloneComment, err);
         return(false);
      }
      else
      {
         PrintFormat("OIExecutor(MT4): clon CERRADO %s (%s)", symbol, cloneComment);
         return(true);
      }
   }
   // No encontrado -> ya está cerrado o nunca existió
   return(false);
}

//+------------------------------------------------------------------+
//| Procesa el CSV completo                                          |
//|  - OPEN  -> crear clon (si no existe ni abierto ni en histórico) |
//|  - CLOSE -> cerrar clon si está abierto                          |
//+------------------------------------------------------------------+
void ProcessCsv()
{
   ResetLastError();

   // Abrimos como texto normal, SIN FILE_CSV, para leer línea completa
   int handle = FileOpen(InpCsvFileName,
                         FILE_READ | FILE_TXT | FILE_COMMON |
                         FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
   {
      int err = GetLastError();
      if(err != 4103) // 4103 = archivo no existe
         PrintFormat("OIExecutor(MT4): no se pudo abrir '%s'. Error=%d",
                     InpCsvFileName, err);
      return;
   }

   // Saltar cabecera (primera línea completa)
   if(!FileIsEnding(handle))
      FileReadString(handle);

   // Recorrer resto de líneas (cada vuelta = una línea CSV)
   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      if(line == "" || StringLen(line) < 3)
         continue;

      string fields[];
      int cnt = StringSplit(line, ';', fields);
      if(cnt < 5)
         continue;

      string event_type      = fields[0];
      string masterTicketStr = fields[1];
      string orderTypeText   = fields[2];
      string lotsText        = fields[3];
      string symbol          = fields[4];

      // Comentario estándar del clon
      string cloneComment = "CLONE Tkt " + masterTicketStr;

      //========================
      // 1) OPEN  -> crear clon
      //========================
      if(event_type == "OPEN")
      {
         double masterLots = StrToDouble(lotsText);
         double lots       = ComputeSlaveLots(symbol, masterLots);

         // sl y tp en campos 7 y 8 (si existen)
         double sl = 0.0;
         double tp = 0.0;
         if(cnt > 7 && fields[7] != "")
            sl = StrToDouble(fields[7]);
         if(cnt > 8 && fields[8] != "")
            tp = StrToDouble(fields[8]);

         // Evitar duplicados (abiertos o ya cerrados en el pasado)
         if(CloneAlreadyExists(symbol, cloneComment))
            continue;

         int orderType = TextToOrderType(orderTypeText);
         if(orderType != OP_BUY && orderType != OP_SELL)
         {
            PrintFormat("OIExecutor(MT4): tipo de orden no soportado '%s' en línea '%s'",
                        orderTypeText, line);
            continue;
         }

         double price = (orderType == OP_BUY ? GetAsk(symbol) : GetBid(symbol));
         color  arrow = (orderType == OP_BUY ? clrBlue : clrRed);

         int ticket = OrderSend(symbol, orderType, lots, price,
                                InpSlippagePoints, sl, tp, cloneComment, 0, 0, arrow);

         if(ticket < 0)
         {
            int err = GetLastError();
            PrintFormat("OrderSend fallo. Maestro %s, símbolo %s, lots=%.2f. Error %d: %s",
               masterTicketStr,
               symbol,
               lots,
               err,
               MyErrorDescription(err));        
         }
         else
         {
            PrintFormat("OIExecutor(MT4): CLONE creado %s %s lots=%.2f SL=%.5f TP=%.5f (maestro %s)",
                        symbol, orderTypeText, lots, sl, tp, masterTicketStr);
         }
      }
      //========================
      // 2) CLOSE -> cerrar clon
      //========================
      else if(event_type == "CLOSE")
      {
         CloseCloneIfOpen(symbol, cloneComment);
      }
      // Otros tipos se ignoran
   }

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Eventos                                                          |
//+------------------------------------------------------------------+
int OnInit()
{
   g_TimerSeconds = InpTimerSeconds;
   if(g_TimerSeconds < 1)
      g_TimerSeconds = 1;

   EventSetTimer(g_TimerSeconds);
   PrintFormat("OIExecutor(MT4): iniciado. Leyendo '%s' cada %d s",
               InpCsvFileName, g_TimerSeconds);
   return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}
//+------------------------------------------------------------------+
void OnTick()
{
   // Todo el trabajo va por OnTimer.
}
//+------------------------------------------------------------------+
void OnTimer()
{
   ProcessCsv();
}
//+------------------------------------------------------------------+

string MyErrorDescription(int code)
{
   switch(code)
   {
      // ---- Genéricos / conexión / cuenta ----
      case 0:   return "0: Sin error";
      case 1:   return "1: Sin error, pero resultado desconocido";
      case 2:   return "2: Error común (Common error)";
      case 3:   return "3: Parámetros de trade no válidos (invalid trade parameters)";
      case 4:   return "4: Servidor ocupado (trade server busy)";
      case 5:   return "5: Versión antigua del terminal (old terminal version)";
      case 6:   return "6: Sin conexión con el servidor (no connection)";
      case 7:   return "7: Permisos insuficientes (not enough rights)";
      case 8:   return "8: Peticiones demasiado frecuentes (too frequent requests)";
      case 9:   return "9: Operación de trade malfuncionando (malfunctional trade operation)";
      case 64:  return "64: Cuenta deshabilitada (account disabled)";
      case 65:  return "65: Cuenta no válida (invalid account)";

      // ---- Errores de trade del servidor ----
      case 128: return "128: Trade timeout (tiempo de espera agotado)";
      case 129: return "129: Invalid price (precio inválido o ya no disponible)";
      case 130: return "130: Invalid stops (SL/TP mal puestos o demasiado cerca)";
      case 131: return "131: Invalid trade volume (lote inválido)";
      case 132: return "132: Market closed (mercado cerrado)";
      case 133: return "133: Trade disabled (trading deshabilitado para el símbolo/cuenta)";
      case 134: return "134: Not enough money (margen insuficiente)";
      case 135: return "135: Price changed (el precio cambió antes de ejecutar)";
      case 136: return "136: Off quotes (sin cotización válida del broker)";
      case 137: return "137: Broker busy (servidor ocupado/broker busy)";
      case 138: return "138: Requote (nuevo precio enviado, requote)";
      case 139: return "139: Order locked (orden bloqueada)";
      case 140: return "140: Only long positions allowed (solo largos permitidos)";
      case 141: return "141: Too many requests (demasiadas peticiones de trade)";
      case 145: return "145: Modification denied (modificación de orden denegada)";
      case 146: return "146: Trade context busy (contexto de trade ocupado)";
      case 147: return "147: Expiración demasiado cercana o incorrecta";
      case 148: return "148: Too many orders (demasiadas órdenes abiertas/pendientes)";
      case 149: return "149: Hedging prohibido (hedging no permitido en la cuenta)";
      case 150: return "150: Proximidad de stops (SL/TP demasiado cerca del precio actual)";

      // ---- Algunos errores típicos del terminal / cliente ----
      case 4000: return "4000: Error interno del terminal (no error detail)";
      case 4001: return "4001: Puntero de función incorrecto";
      case 4002: return "4002: Índice de array fuera de rango";
      case 4003: return "4003: Sin memoria para la pila de llamadas (call stack)";
      case 4004: return "4004: Desbordamiento de recursión (recursion stack overflow)";
      case 4005: return "4005: Pila de ejecución insuficiente (not enough stack for parameter)";
      case 4006: return "4006: Sin memoria para cadena (string)";
      case 4007: return "4007: Sin memoria para array";
      case 4008: return "4008: Sin memoria para historial";
      case 4009: return "4009: Sin memoria para indicador personalizado";

      // ---- Errores muy típicos al programar EAs ----
      case 4106: return "4106: Símbolo desconocido o no válido";
      case 4107: return "4107: Parámetro de precio no válido";
      case 4108: return "4108: Ticket de orden no válido";
      case 4109: return "4109: Trade not allowed (AutoTrading desactivado o EA sin permisos)";
      case 4110: return "4110: Solo posiciones largas permitidas para este símbolo";

      default:
         return "Error " + IntegerToString(code) + ": descripción no definida en MyErrorDescription()";
   }
}

