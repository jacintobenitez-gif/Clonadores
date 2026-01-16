//+------------------------------------------------------------------+
//|                                                     historial.mq4 |
//|  Lee todo el historial de operaciones de la cuenta y lo exporta   |
//|  a un archivo .txt con retorno de carro Windows (\r\n)            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Exporta historial completo de operaciones a fichero TXT"

// -------------------- Inputs --------------------
input bool   InpUseCommonFiles = true;                // Escribir en Common\Files (recomendado para acceso externo)
input string InpFileName       = "historial.txt";     // Nombre del archivo de salida
input bool   InpIncludeHeader  = true;                // Incluir cabecera con nombres de columnas
input string InpSeparator      = "|";                 // Separador de campos

// -------------------- Helpers --------------------
string OrderTypeToString(int type)
{
   switch(type)
   {
      case OP_BUY:       return "BUY";
      case OP_SELL:      return "SELL";
      case OP_BUYLIMIT:  return "BUY_LIMIT";
      case OP_SELLLIMIT: return "SELL_LIMIT";
      case OP_BUYSTOP:   return "BUY_STOP";
      case OP_SELLSTOP:  return "SELL_STOP";
      default:           return "UNKNOWN";
   }
}

string DateTimeToStr(datetime dt)
{
   if(dt <= 0) return "";
   return TimeToString(dt, TIME_DATE|TIME_SECONDS);
}

//+------------------------------------------------------------------+
//| Escribe una línea al archivo con retorno de carro Windows        |
//+------------------------------------------------------------------+
void WriteLineToFile(int handle, string line)
{
   // Convertir string a array de caracteres
   uchar bytes[];
   StringToCharArray(line, bytes, 0, StringLen(line));
   
   // Escribir la línea
   FileWriteArray(handle, bytes, 0, ArraySize(bytes));
   
   // Escribir retorno de carro Windows: \r\n (0x0D 0x0A)
   uchar crlf[] = {0x0D, 0x0A};
   FileWriteArray(handle, crlf);
}

//+------------------------------------------------------------------+
//| Genera la cabecera del archivo                                   |
//+------------------------------------------------------------------+
string BuildHeader()
{
   string sep = InpSeparator;
   return "TICKET" + sep +
          "SYMBOL" + sep +
          "TYPE" + sep +
          "LOTS" + sep +
          "OPEN_PRICE" + sep +
          "CLOSE_PRICE" + sep +
          "STOP_LOSS" + sep +
          "TAKE_PROFIT" + sep +
          "OPEN_TIME" + sep +
          "CLOSE_TIME" + sep +
          "MAGIC_NUMBER" + sep +
          "COMMISSION" + sep +
          "SWAP" + sep +
          "PROFIT" + sep +
          "COMMENT";
}

//+------------------------------------------------------------------+
//| Construye una línea con los datos de una orden                   |
//+------------------------------------------------------------------+
string BuildOrderLine()
{
   string sep = InpSeparator;
   
   int ticket        = OrderTicket();
   string symbol     = OrderSymbol();
   int type          = OrderType();
   double lots       = OrderLots();
   double openPrice  = OrderOpenPrice();
   double closePrice = OrderClosePrice();
   double sl         = OrderStopLoss();
   double tp         = OrderTakeProfit();
   datetime openTime = OrderOpenTime();
   datetime closeTime= OrderCloseTime();
   int magic         = OrderMagicNumber();
   double commission = OrderCommission();
   double swap       = OrderSwap();
   double profit     = OrderProfit();
   string comment    = OrderComment();
   
   // Obtener dígitos del símbolo para formatear precios
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);
   if(digits <= 0) digits = 5; // valor por defecto
   
   string line = IntegerToString(ticket) + sep +
                 symbol + sep +
                 OrderTypeToString(type) + sep +
                 DoubleToString(lots, 2) + sep +
                 DoubleToString(openPrice, digits) + sep +
                 DoubleToString(closePrice, digits) + sep +
                 DoubleToString(sl, digits) + sep +
                 DoubleToString(tp, digits) + sep +
                 DateTimeToStr(openTime) + sep +
                 DateTimeToStr(closeTime) + sep +
                 IntegerToString(magic) + sep +
                 DoubleToString(commission, 2) + sep +
                 DoubleToString(swap, 2) + sep +
                 DoubleToString(profit, 2) + sep +
                 comment;
   
   return line;
}

//+------------------------------------------------------------------+
//| Exporta el historial completo                                    |
//+------------------------------------------------------------------+
void ExportHistory()
{
   // Abrir archivo para escritura en modo binario
   int flags = FILE_BIN | FILE_WRITE;
   if(InpUseCommonFiles) flags |= FILE_COMMON;
   
   int handle = FileOpen(InpFileName, flags);
   
   if(handle == INVALID_HANDLE)
   {
      int err = GetLastError();
      Print("ERROR: No se pudo crear el archivo: ", InpFileName, " Error: ", err);
      Alert("Error al crear archivo: ", InpFileName);
      return;
   }
   
   // Escribir cabecera si está habilitada
   if(InpIncludeHeader)
   {
      WriteLineToFile(handle, BuildHeader());
   }
   
   // Obtener total de órdenes en el historial
   int totalHistory = OrdersHistoryTotal();
   int ordersExported = 0;
   
   Print("Iniciando exportación del historial...");
   Print("Total de órdenes en historial: ", totalHistory);
   
   // Recorrer todas las órdenes del historial
   for(int i = 0; i < totalHistory; i++)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
      {
         // Solo exportar órdenes que tienen close time (operaciones cerradas)
         // Las órdenes canceladas también tienen close time
         string line = BuildOrderLine();
         WriteLineToFile(handle, line);
         ordersExported++;
      }
      else
      {
         Print("ADVERTENCIA: No se pudo seleccionar orden en posición ", i);
      }
   }
   
   FileClose(handle);
   
   // Mostrar resumen
   string folder = InpUseCommonFiles ? "Common\\Files\\" : "MQL4\\Files\\";
   Print("========================================");
   Print("EXPORTACIÓN COMPLETADA");
   Print("Órdenes exportadas: ", ordersExported, " de ", totalHistory);
   Print("Archivo guardado en: ", folder, InpFileName);
   Print("========================================");
   
   Alert("Historial exportado: ", ordersExported, " órdenes a ", InpFileName);
}

//+------------------------------------------------------------------+
//| Información de la cuenta                                         |
//+------------------------------------------------------------------+
void PrintAccountInfo()
{
   Print("========================================");
   Print("INFORMACIÓN DE LA CUENTA");
   Print("Número de cuenta: ", AccountNumber());
   Print("Nombre: ", AccountName());
   Print("Servidor: ", AccountServer());
   Print("Divisa: ", AccountCurrency());
   Print("Balance: ", DoubleToString(AccountBalance(), 2));
   Print("Equity: ", DoubleToString(AccountEquity(), 2));
   Print("========================================");
}

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Mostrar información de la cuenta
   PrintAccountInfo();
   
   // Exportar historial al inicializar
   ExportHistory();
   
   // El EA puede removerse después de exportar ya que es una operación única
   Print("Exportación finalizada. Puede remover el EA del gráfico.");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EA Historial removido del gráfico.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // No se requiere acción en cada tick
   // La exportación se realiza una sola vez al inicializar
}
//+------------------------------------------------------------------+

