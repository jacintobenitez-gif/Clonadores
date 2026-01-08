//+------------------------------------------------------------------+
//|                                          Migrador_V2_a_V3.mq4   |
//|                IMPORTANTE: En MQL4 NO se puede cambiar MagicNumber |
//|                de órdenes abiertas. Este script solo informa.   |
//|                Las órdenes deben cerrarse y reabrirse con V3.    |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

input bool InpEjecutarMigracion = false;  // Marcar true para ver información detallada

//+------------------------------------------------------------------+
//| Helper: Trim de espacios                                        |
//+------------------------------------------------------------------+
string Trim(string s)
{
   int len = StringLen(s);
   if(len == 0) 
      return("");
   
   int start = 0;
   while(start < len && StringGetCharacter(s, start) == ' ')
      start++;
   
   if(start >= len) 
      return("");
   
   int end = len - 1;
   while(end >= start && StringGetCharacter(s, end) == ' ')
      end--;
   
   if(end < start)
      return("");
   
   return(StringSubstr(s, start, end - start + 1));
}

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
{
   Alert("========================================");
   Alert("Migrador V2 -> V3");
   Alert("========================================");
   Alert("LIMITACION CRITICA DE MQL4:");
   Alert("NO se puede cambiar MagicNumber de órdenes abiertas");
   Alert("");
   Alert("V2 usa: Comment = ticket origen");
   Alert("V3 usa: MagicNumber = ticket origen");
   Alert("");
   Alert("SOLUCION:");
   Alert("Las órdenes deben cerrarse y reabrirse con V3");
   Alert("Este script solo muestra qué órdenes necesitan migración");
   Alert("");
   
   int totalOrders = OrdersTotal();
   Alert("Total de operaciones abiertas: " + IntegerToString(totalOrders));
   Alert("");
   
   SimularMigracion();
   Alert("");
   Alert("NOTA: En MQL4, OrderModify() NO permite cambiar MagicNumber");
   Alert("El MagicNumber solo se establece al crear la orden");
   Alert("Debes esperar a que se cierren o cerrarlas manualmente");
   Alert("Las nuevas órdenes abiertas con V3 tendrán el MagicNumber correcto");
}

//+------------------------------------------------------------------+
//| Simula la migración sin modificar nada                          |
//+------------------------------------------------------------------+
void SimularMigracion()
{
   int total = OrdersTotal();
   Alert("SimularMigracion: Total = " + IntegerToString(total));
   
   if(total == 0)
   {
      Alert("No hay operaciones abiertas.");
      return;
   }
   
   Alert("ANALISIS DE OPERACIONES:");
   Alert("Total de operaciones abiertas: " + IntegerToString(total));
   Alert("");
   
   int migradas = 0;
   int yaMigradas = 0;
   int errores = 0;
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      
      int ticket = OrderTicket();
      string comment = OrderComment();
      comment = Trim(comment);
      int magicActual = OrderMagicNumber();
      string symbol = OrderSymbol();
      double lots = OrderLots();
      
      string msg = "Operación #" + IntegerToString(i + 1) + ":";
      msg += "\n  Ticket: " + IntegerToString(ticket);
      msg += "\n  Symbol: " + symbol;
      msg += "\n  Lots: " + DoubleToString(lots, 2);
      msg += "\n  Comment: '" + comment + "'";
      msg += "\n  MagicNumber actual: " + IntegerToString(magicActual);
      
      if(!InpEjecutarMigracion)
      {
         // Modo rápido: solo mostrar resumen
      }
      else
      {
         Alert(msg);
      }
      
      if(StringLen(comment) == 0)
      {
         if(InpEjecutarMigracion)
            Alert("  Estado: SIN COMMENT - No se puede migrar");
         errores++;
         continue;
      }
      
      int ticketOrigen = (int)StrToInteger(comment);
      if(ticketOrigen == 0 && comment != "0")
      {
         if(InpEjecutarMigracion)
            Alert("  Estado: COMMENT NO ES NUMERO VALIDO - No se puede migrar");
         errores++;
         continue;
      }
      
      if(magicActual == ticketOrigen)
      {
         if(InpEjecutarMigracion)
            Alert("  Estado: YA MIGRADA (MagicNumber coincide con Comment)");
         yaMigradas++;
      }
      else
      {
         if(InpEjecutarMigracion)
         {
            Alert("  Estado: REQUIERE MIGRACION");
            Alert("    MagicNumber actual: " + IntegerToString(magicActual));
            Alert("    MagicNumber necesario: " + IntegerToString(ticketOrigen));
            Alert("    ACCION: Cerrar esta orden y reabrirla con V3");
         }
         migradas++;
      }
   }
   
   Alert("RESUMEN:");
   Alert("  Total operaciones: " + IntegerToString(total));
   Alert("  Requieren migración: " + IntegerToString(migradas));
   Alert("  Ya migradas: " + IntegerToString(yaMigradas));
   Alert("  Con errores: " + IntegerToString(errores));
   Alert("");
   Alert("IMPORTANTE:");
   Alert("En MQL4 NO se puede cambiar MagicNumber de órdenes abiertas");
   Alert("OrderModify() solo permite cambiar SL/TP, no MagicNumber");
   Alert("");
   Alert("OPCIONES:");
   Alert("1. Cerrar manualmente las órdenes que requieren migración");
   Alert("2. Esperar a que se cierren naturalmente");
   Alert("3. Las nuevas órdenes abiertas con V3 tendrán MagicNumber correcto");
   Alert("4. V3 buscará por MagicNumber, así que las antiguas no se encontrarán");
   Alert("   hasta que se cierren y se reabran con V3");
}
