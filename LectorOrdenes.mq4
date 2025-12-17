//+------------------------------------------------------------------+
//|                                                LectorOrdenes.mq4 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//|   Lee aperturas y cierres y los escribe en Common\Files          |
//|   Fichero: TradeEvents.csv (compartido por todos los MT4/MT5)    |
//|   v1.1: añade columnas SL y TP                                   |
//|   v1.2: detecta cambios en SL/TP y escribe eventos MODIFY        |
//|   v1.3: elimina campos magic y comment, usa FILE_TXT              |
//+------------------------------------------------------------------+
#property strict

// Nombre del fichero CSV (en carpeta COMMON\Files)
input string InpCSVFileName = "TradeEvents.csv";

// Tamaño máximo de órdenes que vamos a manejar
#define MAX_ORDERS 500

// Estructura para almacenar estado previo de cada orden (SL/TP)
struct OrderState
{
   int    ticket;
   double sl;
   double tp;
};

int  g_prevTickets[MAX_ORDERS];  // Tickets abiertos en el tick anterior
OrderState g_prevOrders[MAX_ORDERS]; // Estado previo completo (SL/TP)
int  g_prevCount      = 0;       // Cuántos había
bool g_initialized    = false;   // Para no disparar eventos en el primer tick

//+------------------------------------------------------------------+
//| Devuelve true si el ticket está en el array (size elementos)     |
//+------------------------------------------------------------------+
bool TicketInArray(int ticket, int &arr[], int size)
{
   for(int i = 0; i < size; i++)
   {
      if(arr[i] == ticket)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Busca el índice de un ticket en el array de estados previos      |
//| Retorna -1 si no se encuentra                                     |
//+------------------------------------------------------------------+
int FindOrderStateIndex(int ticket, OrderState &states[], int size)
{
   for(int i = 0; i < size; i++)
   {
      if(states[i].ticket == ticket)
         return(i);
   }
   return(-1);
}

//+------------------------------------------------------------------+
//| Compara dos valores double con tolerancia para evitar falsos     |
//| positivos por redondeo                                            |
//+------------------------------------------------------------------+
bool DoubleChanged(double val1, double val2)
{
   // Tolerancia: 1 punto (0.00001 para pares de 5 decimales)
   double tolerance = 0.00001;
   return(MathAbs(val1 - val2) > tolerance);
}

//+------------------------------------------------------------------+
//| Escribe una línea en el CSV (apertura, cierre o modificación)    |
//| v1.3: elimina magic y comment, usa FILE_TXT                      |
//+------------------------------------------------------------------+
void AppendEventToCSV(string eventType,
                      int    ticket,
                      string orderTypeStr,
                      double lots,
                      string symbol,
                      double openPrice,
                      datetime openTime,
                      double sl,
                      double tp,
                      double closePrice,
                      datetime closeTime,
                      double profit)
{
   // *** IMPORTANTE: Usar FILE_TXT en lugar de FILE_CSV para evitar problemas de codificación ***
   // READ + WRITE para NO truncar el fichero
   int handle = FileOpen(InpCSVFileName,
                         FILE_TXT | FILE_READ | FILE_WRITE | FILE_COMMON |
                         FILE_SHARE_READ | FILE_SHARE_WRITE);

   if(handle == INVALID_HANDLE)
   {
      Print("Observador_Common: ERROR al abrir CSV '", InpCSVFileName,
            "' err=", GetLastError());
      return;
   }

   // Ir al final para añadir
   FileSeek(handle, 0, SEEK_END);

   string sLots       = DoubleToString(lots, 2);
   string sOpenPrice  = (openPrice  > 0.0 ? DoubleToString(openPrice,  Digits) : "");
   string sClosePrice = (closePrice > 0.0 ? DoubleToString(closePrice, Digits) : "");
   string sSL         = (sl > 0.0 ? DoubleToString(sl, Digits) : "");
   string sTP         = (tp > 0.0 ? DoubleToString(tp, Digits) : "");

   string sOpenTime   = (openTime  > 0 ? TimeToStr(openTime,  TIME_DATE|TIME_SECONDS)  : "");
   string sCloseTime  = (closeTime > 0 ? TimeToStr(closeTime, TIME_DATE|TIME_SECONDS)  : "");

   string sProfit     = DoubleToString(profit, 2);

   // Construir línea manualmente con delimitador ;
   string line = eventType + ";" +
                 IntegerToString(ticket) + ";" +
                 orderTypeStr + ";" +
                 sLots + ";" +
                 symbol + ";" +
                 sOpenPrice + ";" +
                 sOpenTime + ";" +
                 sSL + ";" +
                 sTP + ";" +
                 sClosePrice + ";" +
                 sCloseTime + ";" +
                 sProfit;

   // Escribir línea completa (FileWrite con FILE_TXT añade salto de línea automáticamente)
   FileWrite(handle, line);

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Inicializa el CSV (cabecera) en COMMON\Files si no existe        |
//| v1.3: cabecera sin magic y comment                               |
//+------------------------------------------------------------------+
void InitCSVIfNeeded()
{
   // Intentar abrir en lectura en carpeta COMMON
   int hRead = FileOpen(InpCSVFileName,
                        FILE_TXT | FILE_READ |
                        FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(hRead != INVALID_HANDLE)
   {
      FileClose(hRead);
      return; // ya existe
   }

   // No existe: crear y escribir cabecera nueva
   int handle = FileOpen(InpCSVFileName,
                         FILE_TXT | FILE_WRITE |
                         FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
   {
      Print("Observador_Common: ERROR al crear CSV '", InpCSVFileName,
            "' err=", GetLastError());
      return;
   }

   // Escribir cabecera manualmente con delimitador ;
   string header = "event_type;ticket;order_type;lots;symbol;open_price;open_time;sl;tp;close_price;close_time;profit";
   FileWrite(handle, header);

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("Observador_Common v1.3 inicializado. CSV(COMMON) = ", InpCSVFileName);

   g_prevCount   = 0;
   g_initialized = false;
   ArrayInitialize(g_prevTickets, 0);
   
   // Inicializar array de estados previos
   for(int i = 0; i < MAX_ORDERS; i++)
   {
      g_prevOrders[i].ticket = 0;
      g_prevOrders[i].sl = 0.0;
      g_prevOrders[i].tp = 0.0;
   }

   InitCSVIfNeeded();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Observador_Common finalizado. reason = ", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   int  curTickets[MAX_ORDERS];
   int  curCount = 0;
   ArrayInitialize(curTickets, 0);

   //================= 1) Construir lista de tickets actuales ============
   int total = OrdersTotal();
   for(int i = 0; i < total && curCount < MAX_ORDERS; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      int ticket = OrderTicket();
      curTickets[curCount] = ticket;
      curCount++;
   }

   //================= 1.5) Primera vez: registrar las órdenes ya abiertas
   if(!g_initialized)
   {
      Print("Observador_Common: inicialización. Órdenes abiertas actuales = ", curCount);

      for(int k = 0; k < curCount; k++)
      {
         int t = curTickets[k];
         if(OrderSelect(t, SELECT_BY_TICKET, MODE_TRADES))
         {
            string tipo;
            switch(OrderType())
            {
               case OP_BUY:       tipo = "BUY";       break;
               case OP_SELL:      tipo = "SELL";      break;
               case OP_BUYLIMIT:  tipo = "BUYLIMIT";  break;
               case OP_SELLLIMIT: tipo = "SELLLIMIT"; break;
               case OP_BUYSTOP:   tipo = "BUYSTOP";   break;
               case OP_SELLSTOP:  tipo = "SELLSTOP"; break;
               default:           tipo = "OTRO";      break;
            }

            AppendEventToCSV("OPEN",
                             t,
                             tipo,
                             OrderLots(),
                             OrderSymbol(),
                             OrderOpenPrice(),
                             OrderOpenTime(),
                             OrderStopLoss(),
                             OrderTakeProfit(),
                             0.0,
                             0,
                             0.0);

            // Guardar estado inicial (SL/TP)
            g_prevTickets[k] = t;
            g_prevOrders[k].ticket = t;
            g_prevOrders[k].sl = OrderStopLoss();
            g_prevOrders[k].tp = OrderTakeProfit();
         }
         else
         {
            g_prevTickets[k] = 0;
            g_prevOrders[k].ticket = 0;
            g_prevOrders[k].sl = 0.0;
            g_prevOrders[k].tp = 0.0;
         }
      }

      g_prevCount   = curCount;
      g_initialized = true;
      return;
   }

   //================= 2) Detectar nuevas APERTURAS ======================
   for(int j = 0; j < curCount; j++)
   {
      int t = curTickets[j];
      if(!TicketInArray(t, g_prevTickets, g_prevCount))
      {
         if(OrderSelect(t, SELECT_BY_TICKET, MODE_TRADES))
         {
            string tipo;
            switch(OrderType())
            {
               case OP_BUY:       tipo = "BUY";       break;
               case OP_SELL:      tipo = "SELL";      break;
               case OP_BUYLIMIT:  tipo = "BUYLIMIT";  break;
               case OP_SELLLIMIT: tipo = "SELLLIMIT"; break;
               case OP_BUYSTOP:   tipo = "BUYSTOP";   break;
               case OP_SELLSTOP:  tipo = "SELLSTOP"; break;
               default:           tipo = "OTRO";      break;
            }

            AppendEventToCSV("OPEN",
                             t,
                             tipo,
                             OrderLots(),
                             OrderSymbol(),
                             OrderOpenPrice(),
                             OrderOpenTime(),
                             OrderStopLoss(),
                             OrderTakeProfit(),
                             0.0,
                             0,
                             0.0);
            
            // Nota: El estado previo se guardará en la sección 4 al final
         }
      }
   }

   //================= 2.5) Detectar MODIFICACIONES de SL/TP ============
   for(int mod = 0; mod < curCount; mod++)
   {
      int t = curTickets[mod];
      
      // Solo revisar órdenes que ya existían antes (no nuevas)
      if(TicketInArray(t, g_prevTickets, g_prevCount))
      {
         if(OrderSelect(t, SELECT_BY_TICKET, MODE_TRADES))
         {
            // Buscar estado previo
            int prevIdx = FindOrderStateIndex(t, g_prevOrders, g_prevCount);
            if(prevIdx >= 0)
            {
               double currentSL = OrderStopLoss();
               double currentTP = OrderTakeProfit();
               double prevSL = g_prevOrders[prevIdx].sl;
               double prevTP = g_prevOrders[prevIdx].tp;
               
               // Detectar cambios (con tolerancia para evitar falsos positivos)
               bool slChanged = DoubleChanged(currentSL, prevSL);
               bool tpChanged = DoubleChanged(currentTP, prevTP);
               
               if(slChanged || tpChanged)
               {
                  string tipo;
                  switch(OrderType())
                  {
                     case OP_BUY:       tipo = "BUY";       break;
                     case OP_SELL:      tipo = "SELL";      break;
                     case OP_BUYLIMIT:  tipo = "BUYLIMIT";  break;
                     case OP_SELLLIMIT: tipo = "SELLLIMIT"; break;
                     case OP_BUYSTOP:   tipo = "BUYSTOP";   break;
                     case OP_SELLSTOP:  tipo = "SELLSTOP"; break;
                     default:           tipo = "OTRO";      break;
                  }
                  
                  AppendEventToCSV("MODIFY",
                                   t,
                                   tipo,
                                   OrderLots(),
                                   OrderSymbol(),
                                   OrderOpenPrice(),
                                   OrderOpenTime(),
                                   currentSL,  // Nuevo SL
                                   currentTP,  // Nuevo TP
                                   0.0,
                                   0,
                                   0.0);
                  
                  // Actualizar estado previo inmediatamente
                  g_prevOrders[prevIdx].sl = currentSL;
                  g_prevOrders[prevIdx].tp = currentTP;
               }
            }
         }
      }
   }

   //================= 3) Detectar CIERRES (tickets que ya no están) =====
   for(int p = 0; p < g_prevCount; p++)
   {
      int oldTicket = g_prevTickets[p];

      if(!TicketInArray(oldTicket, curTickets, curCount))
      {
         if(OrderSelect(oldTicket, SELECT_BY_TICKET, MODE_HISTORY))
         {
            string tipo;
            switch(OrderType())
            {
               case OP_BUY:       tipo = "BUY";       break;
               case OP_SELL:      tipo = "SELL";      break;
               case OP_BUYLIMIT:  tipo = "BUYLIMIT";  break;
               case OP_SELLLIMIT: tipo = "SELLLIMIT"; break;
               case OP_BUYSTOP:   tipo = "BUYSTOP";   break;
               case OP_SELLSTOP:  tipo = "SELLSTOP"; break;
               default:           tipo = "OTRO";      break;
            }

            AppendEventToCSV("CLOSE",
                             oldTicket,
                             tipo,
                             OrderLots(),
                             OrderSymbol(),
                             OrderOpenPrice(),
                             OrderOpenTime(),
                             OrderStopLoss(),
                             OrderTakeProfit(),
                             OrderClosePrice(),
                             OrderCloseTime(),
                             OrderProfit());
         }
      }
   }

   //================= 4) Actualizar lista previa ========================
   g_prevCount = curCount;
   for(int m = 0; m < curCount; m++)
   {
      g_prevTickets[m] = curTickets[m];
      
      // Actualizar estado previo (SL/TP) para la próxima comparación
      if(OrderSelect(curTickets[m], SELECT_BY_TICKET, MODE_TRADES))
      {
         g_prevOrders[m].ticket = curTickets[m];
         g_prevOrders[m].sl = OrderStopLoss();
         g_prevOrders[m].tp = OrderTakeProfit();
      }
      else
      {
         g_prevOrders[m].ticket = 0;
         g_prevOrders[m].sl = 0.0;
         g_prevOrders[m].tp = 0.0;
      }
   }
}

