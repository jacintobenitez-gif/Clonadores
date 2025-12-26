//+------------------------------------------------------------------+
//|                                                LectorOrdenes.mq4 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//|   Lee aperturas y cierres y los escribe en Common\Files          |
//|   Fichero: Master.txt (compartido por todos los MT4/MT5)    |
//|   v1.1: añade columnas SL y TP                                   |
//|   v1.2: detecta cambios en SL/TP y escribe eventos MODIFY        |
//|   v1.3: elimina campos magic y comment, usa FILE_TXT              |
//|   v1.4: escribe en UTF-8 usando FILE_BIN                          |
//|   v1.5: cambia OnTick() por OnTimer() para mayor eficiencia       |
//|   v1.6: simplifica campos a: event_type;ticket;order_type;lots;symbol;sl;tp |
//|   v1.7: añade sistema de reintento para cierres pendientes                  |
//+------------------------------------------------------------------+
#property strict

// Nombre del fichero TXT (subcarpeta COMMON\Files\V2\Phoenix)
input string InpCSVFileName = "V2\\Phoenix\\Master.txt";
// Timer en segundos para revisar cambios
input int    InpTimerSeconds = 1;  // Revisar cada 1 segundo (alineado con clonadores)

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

// Sistema de reintento para cierres pendientes
int  g_pendingCloseTickets[MAX_ORDERS];  // Tickets pendientes de escribir CLOSE
int  g_pendingCloseCount = 0;            // Cuántos tickets pendientes hay

//+------------------------------------------------------------------+
//| Asegura que existan las carpetas V2 y V2\Phoenix en COMMON\Files |
//+------------------------------------------------------------------+
void EnsureCommonFolders()
{
   // Crea la carpeta base V2 (si no existe) y la subcarpeta Phoenix
   FolderCreate("V2", FILE_COMMON);
   FolderCreate("V2\\Phoenix", FILE_COMMON);
}

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
//| Escribe una línea en el TXT (apertura, cierre o modificación)    |
//| v1.6: solo campos: event_type;ticket;order_type;lots;symbol;sl;tp |
//| v1.4: escribe en UTF-8 usando FILE_BIN                           |
//+------------------------------------------------------------------+
void AppendEventToCSV(string eventType,
                      int    ticket,
                      string orderTypeStr,
                      double lots,
                      string symbol,
                      double sl,
                      double tp)
{
   // Abrir archivo en modo binario para escribir UTF-8
   int handle = FileOpen(InpCSVFileName,
                         FILE_BIN | FILE_READ | FILE_WRITE | FILE_COMMON |
                         FILE_SHARE_READ | FILE_SHARE_WRITE);

   if(handle == INVALID_HANDLE)
   {
      Print("Observador_Common: ERROR al abrir TXT '", InpCSVFileName,
            "' err=", GetLastError());
      return;
   }

   // Ir al final para añadir
   FileSeek(handle, 0, SEEK_END);

   string sLots = DoubleToString(lots, 2);
   string sSL   = (sl > 0.0 ? DoubleToString(sl, Digits) : "");
   string sTP   = (tp > 0.0 ? DoubleToString(tp, Digits) : "");

   // Construir línea manualmente con delimitador ; (solo campos requeridos)
   string line = eventType + ";" +
                 IntegerToString(ticket) + ";" +
                 orderTypeStr + ";" +
                 sLots + ";" +
                 symbol + ";" +
                 sSL + ";" +
                 sTP;

   // Convertir línea a UTF-8 y escribir
   uchar utf8Bytes[];
   StringToUTF8Bytes(line, utf8Bytes);

   // Escribir bytes UTF-8
   FileWriteArray(handle, utf8Bytes);
   
   // Escribir salto de línea UTF-8 (\n = 0x0A)
   uchar newline[] = {0x0A};
   FileWriteArray(handle, newline);

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Intenta escribir un evento CLOSE para un ticket                  |
//| Retorna true si se escribió exitosamente, false si falló         |
//| v1.7: función helper para sistema de reintento                    |
//+------------------------------------------------------------------+
bool TryWriteCloseEvent(int ticket)
{
   if(OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY))
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
                       ticket,
                       tipo,
                       OrderLots(),
                       OrderSymbol(),
                       OrderStopLoss(),
                       OrderTakeProfit());
      return(true);  // Éxito
   }
   return(false);  // Falló: ticket no encontrado en historial
}

//+------------------------------------------------------------------+
//| Añade un ticket al array de pendientes (si no está ya)          |
//| v1.7: sistema de reintento                                       |
//+------------------------------------------------------------------+
void AddPendingClose(int ticket)
{
   // Verificar si ya está en el array
   for(int i = 0; i < g_pendingCloseCount; i++)
   {
      if(g_pendingCloseTickets[i] == ticket)
         return;  // Ya está pendiente
   }
   
   // Añadir si hay espacio
   if(g_pendingCloseCount < MAX_ORDERS)
   {
      g_pendingCloseTickets[g_pendingCloseCount] = ticket;
      g_pendingCloseCount++;
   }
}

//+------------------------------------------------------------------+
//| Elimina un ticket del array de pendientes                        |
//| v1.7: sistema de reintento                                       |
//+------------------------------------------------------------------+
void RemovePendingClose(int ticket)
{
   for(int i = 0; i < g_pendingCloseCount; i++)
   {
      if(g_pendingCloseTickets[i] == ticket)
      {
         // Mover los siguientes hacia atrás
         for(int j = i; j < g_pendingCloseCount - 1; j++)
         {
            g_pendingCloseTickets[j] = g_pendingCloseTickets[j + 1];
         }
         g_pendingCloseTickets[g_pendingCloseCount - 1] = 0;
         g_pendingCloseCount--;
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Inicializa el TXT (cabecera) en COMMON\Files si no existe        |
//| v1.4: escribe cabecera en UTF-8                                  |
//+------------------------------------------------------------------+
void InitCSVIfNeeded()
{
   // Asegurar que existen las carpetas destino en Common\Files
   EnsureCommonFolders();

   // Intentar abrir en lectura en carpeta COMMON
   int hRead = FileOpen(InpCSVFileName,
                        FILE_BIN | FILE_READ |
                        FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(hRead != INVALID_HANDLE)
   {
      FileClose(hRead);
      return; // ya existe
   }

   // No existe: crear y escribir cabecera nueva en UTF-8
   int handle = FileOpen(InpCSVFileName,
                         FILE_BIN | FILE_WRITE |
                         FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
   {
      Print("Observador_Common: ERROR al crear TXT '", InpCSVFileName,
            "' err=", GetLastError());
      return;
   }

   // Escribir cabecera en UTF-8
   string header = "event_type;ticket;order_type;lots;symbol;sl;tp";
   uchar utf8Bytes[];
   StringToUTF8Bytes(header, utf8Bytes);
   FileWriteArray(handle, utf8Bytes);
   
   // Escribir salto de línea UTF-8
   uchar newline[] = {0x0A};
   FileWriteArray(handle, newline);

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("Observador_Common v1.7 inicializado. TXT(COMMON) = ", InpCSVFileName);
   Print("COMMON path = ", TerminalInfoString(TERMINAL_COMMONDATA_PATH), "\\Files\\", InpCSVFileName);
   Print("Timer: ", InpTimerSeconds, " segundos");

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
   
   // Inicializar sistema de reintento
   g_pendingCloseCount = 0;
   ArrayInitialize(g_pendingCloseTickets, 0);

   InitCSVIfNeeded();
   
   // Configurar timer
   EventSetTimer(InpTimerSeconds);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("Observador_Common finalizado. reason = ", reason);
}

//+------------------------------------------------------------------+
//| OnTimer                                                          |
//+------------------------------------------------------------------+
void OnTimer()
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
                             OrderStopLoss(),
                             OrderTakeProfit());

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
                             OrderStopLoss(),
                             OrderTakeProfit());
            
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
                                   currentSL,  // Nuevo SL
                                   currentTP);  // Nuevo TP
                  
                  // Actualizar estado previo inmediatamente
                  g_prevOrders[prevIdx].sl = currentSL;
                  g_prevOrders[prevIdx].tp = currentTP;
               }
            }
         }
      }
   }

   //================= 3) Procesar CIERRES (con sistema de reintento) =====
   
   // 3.1) Primero: Intentar procesar tickets pendientes de ciclos anteriores
   int i = 0;
   while(i < g_pendingCloseCount)
   {
      int pendingTicket = g_pendingCloseTickets[i];
      
      // Intentar escribir el CLOSE
      if(TryWriteCloseEvent(pendingTicket))
      {
         // Éxito: eliminar de pendientes
         RemovePendingClose(pendingTicket);
         // No incrementar i porque RemovePendingClose ya reorganizó el array
      }
      else
      {
         // Aún falla: mantener en pendientes y continuar
         i++;
      }
   }
   
   // 3.2) Segundo: Detectar nuevos CIERRES (tickets que ya no están abiertos)
   for(int p = 0; p < g_prevCount; p++)
   {
      int oldTicket = g_prevTickets[p];

      // Si el ticket ya no está en las posiciones abiertas actuales
      if(!TicketInArray(oldTicket, curTickets, curCount))
      {
         // Verificar si ya está en pendientes (para evitar duplicados)
         bool alreadyPending = TicketInArray(oldTicket, g_pendingCloseTickets, g_pendingCloseCount);
         
         if(!alreadyPending)
         {
            // Intentar escribir el CLOSE
            if(!TryWriteCloseEvent(oldTicket))
            {
               // Falló: añadir a pendientes para reintentar en el siguiente ciclo
               AddPendingClose(oldTicket);
            }
         }
         // Si ya está pendiente, no hacer nada (se procesará en 3.1 del siguiente ciclo)
      }
   }

   //================= 4) Actualizar lista previa (manteniendo pendientes) =====
   // Guardar valor anterior de g_prevCount antes de modificarlo
   int oldPrevCount = g_prevCount;
   
   // Construir nueva lista combinando tickets abiertos actuales + pendientes
   int newPrevCount = 0;
   
   // Primero: añadir tickets abiertos actuales
   for(int m = 0; m < curCount && newPrevCount < MAX_ORDERS; m++)
   {
      g_prevTickets[newPrevCount] = curTickets[m];
      
      // Actualizar estado previo (SL/TP) para la próxima comparación
      if(OrderSelect(curTickets[m], SELECT_BY_TICKET, MODE_TRADES))
      {
         g_prevOrders[newPrevCount].ticket = curTickets[m];
         g_prevOrders[newPrevCount].sl = OrderStopLoss();
         g_prevOrders[newPrevCount].tp = OrderTakeProfit();
      }
      else
      {
         g_prevOrders[newPrevCount].ticket = 0;
         g_prevOrders[newPrevCount].sl = 0.0;
         g_prevOrders[newPrevCount].tp = 0.0;
      }
      newPrevCount++;
   }
   
   // Segundo: añadir tickets pendientes que no estén ya en la lista
   for(int pend = 0; pend < g_pendingCloseCount && newPrevCount < MAX_ORDERS; pend++)
   {
      int pendTicket = g_pendingCloseTickets[pend];
      
      // Solo añadir si no está ya en la lista (no debería estar, pero por seguridad)
      if(!TicketInArray(pendTicket, g_prevTickets, newPrevCount))
      {
         g_prevTickets[newPrevCount] = pendTicket;
         
         // Intentar obtener estado del historial (si está disponible)
         if(OrderSelect(pendTicket, SELECT_BY_TICKET, MODE_HISTORY))
         {
            g_prevOrders[newPrevCount].ticket = pendTicket;
            g_prevOrders[newPrevCount].sl = OrderStopLoss();
            g_prevOrders[newPrevCount].tp = OrderTakeProfit();
         }
         else
         {
            // Si no está en historial aún, mantener estado anterior si existe
            // Usar oldPrevCount para buscar en el array anterior
            int prevIdx = FindOrderStateIndex(pendTicket, g_prevOrders, oldPrevCount);
            if(prevIdx >= 0)
            {
               g_prevOrders[newPrevCount] = g_prevOrders[prevIdx];
            }
            else
            {
               g_prevOrders[newPrevCount].ticket = pendTicket;
               g_prevOrders[newPrevCount].sl = 0.0;
               g_prevOrders[newPrevCount].tp = 0.0;
            }
         }
         newPrevCount++;
      }
   }
   
   // Limpiar el resto del array
   for(int clean = newPrevCount; clean < MAX_ORDERS; clean++)
   {
      g_prevTickets[clean] = 0;
      g_prevOrders[clean].ticket = 0;
      g_prevOrders[clean].sl = 0.0;
      g_prevOrders[clean].tp = 0.0;
   }
   
   g_prevCount = newPrevCount;
}

