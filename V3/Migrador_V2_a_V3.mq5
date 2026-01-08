//+------------------------------------------------------------------+
//|                                          Migrador_V2_a_V3.mq5   |
//|                Migra posiciones de V2 (Comment) a V3 (MagicNumber) |
//|                Mantiene Comment intacto por seguridad            |
//+------------------------------------------------------------------+
#property script_show_inputs

input bool InpEjecutarMigracion = false;  // Marcar true para ejecutar la migración

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
{
   Print("========================================");
   Print("Migrador V2 -> V3");
   Print("========================================");
   Print("Este script migra posiciones abiertas de V2 a V3");
   Print("V2 usa: Comment = ticket origen");
   Print("V3 usa: MagicNumber = ticket origen");
   Print("");
   
   if(!InpEjecutarMigracion)
   {
      Print("ATENCION: InpEjecutarMigracion = false");
      Print("Revisa las posiciones que se migrarían y luego marca true para ejecutar");
      Print("");
      SimularMigracion();
      return;
   }
   
   Print("EJECUTANDO MIGRACION...");
   Print("");
   EjecutarMigracion();
   Print("");
   Print("Migración completada.");
}

//+------------------------------------------------------------------+
//| Simula la migración sin modificar nada                          |
//+------------------------------------------------------------------+
void SimularMigracion()
{
   int total = PositionsTotal();
   if(total == 0)
   {
      Print("No hay posiciones abiertas.");
      return;
   }
   
   Print("SIMULACION (no se modifica nada):");
   Print("Total de posiciones abiertas: ", total);
   Print("");
   
   int migradas = 0;
   int yaMigradas = 0;
   int errores = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0) continue;
      if(!PositionSelectByTicket(posTicket)) continue;
      
      string comment = PositionGetString(POSITION_COMMENT);
      comment = Trim(comment);
      ulong magicActual = PositionGetInteger(POSITION_MAGIC);
      string symbol = PositionGetString(POSITION_SYMBOL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      
      Print("Posición #", i + 1, ":");
      Print("  Ticket: ", posTicket);
      Print("  Symbol: ", symbol);
      Print("  Volume: ", volume);
      Print("  Comment actual: '", comment, "'");
      Print("  MagicNumber actual: ", magicActual);
      
      if(StringLen(comment) == 0)
      {
         Print("  Estado: SIN COMMENT - No se puede migrar");
         errores++;
         Print("");
         continue;
      }
      
      ulong ticketOrigen = StringToInteger(comment);
      if(ticketOrigen == 0 && comment != "0")
      {
         Print("  Estado: COMMENT NO ES NUMERO VALIDO - No se puede migrar");
         errores++;
         Print("");
         continue;
      }
      
      if(magicActual == ticketOrigen)
      {
         Print("  Estado: YA MIGRADA (MagicNumber coincide con Comment)");
         yaMigradas++;
      }
      else
      {
         Print("  Estado: SE MIGRARIA");
         Print("    MagicNumber nuevo: ", ticketOrigen);
         migradas++;
      }
      Print("");
   }
   
   Print("RESUMEN:");
   Print("  Total posiciones: ", total);
   Print("  Se migrarían: ", migradas);
   Print("  Ya migradas: ", yaMigradas);
   Print("  Con errores: ", errores);
}

//+------------------------------------------------------------------+
//| Ejecuta la migración real                                        |
//+------------------------------------------------------------------+
void EjecutarMigracion()
{
   int total = PositionsTotal();
   if(total == 0)
   {
      Print("No hay posiciones abiertas.");
      return;
   }
   
   Print("Total de posiciones abiertas: ", total);
   Print("");
   
   int migradas = 0;
   int yaMigradas = 0;
   int errores = 0;
   
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0) continue;
      if(!PositionSelectByTicket(posTicket)) continue;
      
      string comment = PositionGetString(POSITION_COMMENT);
      comment = Trim(comment);
      ulong magicActual = PositionGetInteger(POSITION_MAGIC);
      string symbol = PositionGetString(POSITION_SYMBOL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      
      Print("Procesando posición #", i + 1, ":");
      Print("  Ticket: ", posTicket, " | Symbol: ", symbol, " | Volume: ", volume);
      Print("  Comment: '", comment, "' | MagicNumber actual: ", magicActual);
      
      if(StringLen(comment) == 0)
      {
         Print("  ERROR: Sin Comment - No se puede migrar");
         errores++;
         Print("");
         continue;
      }
      
      ulong ticketOrigen = StringToInteger(comment);
      if(ticketOrigen == 0 && comment != "0")
      {
         Print("  ERROR: Comment no es número válido - No se puede migrar");
         errores++;
         Print("");
         continue;
      }
      
      if(magicActual == ticketOrigen)
      {
         Print("  OK: Ya migrada (MagicNumber = ", magicActual, ")");
         yaMigradas++;
      }
      else
      {
         Print("  REQUIERE MIGRACION: MagicNumber ", magicActual, " -> ", ticketOrigen);
         Print("  ADVERTENCIA: En MQL5 NO se puede modificar MagicNumber de posición abierta");
         Print("  SOLUCION: Cerrar esta posición y reabrirla con V3 (MagicNumber correcto)");
         Print("  O esperar a que se cierre naturalmente y las nuevas se abrirán con V3");
         migradas++;  // Contamos como "requiere migración"
      }
      Print("");
   }
   
   Print("========================================");
   Print("RESUMEN FINAL:");
   Print("  Total posiciones: ", total);
   Print("  Requieren migración (cerrar y reabrir): ", migradas);
   Print("  Ya estaban migradas: ", yaMigradas);
   Print("  Con errores: ", errores);
   Print("");
   Print("NOTA IMPORTANTE:");
   Print("  En MQL5, el MagicNumber de una posición abierta NO se puede modificar.");
   Print("  El MagicNumber solo se establece al abrir la posición.");
   Print("");
   Print("  OPCIONES:");
   Print("  1. Cerrar manualmente las posiciones que requieren migración");
   Print("  2. Esperar a que se cierren naturalmente");
   Print("  3. Las nuevas posiciones abiertas con V3 tendrán el MagicNumber correcto");
   Print("  4. V3 buscará por MagicNumber, así que las posiciones antiguas no se encontrarán");
   Print("     hasta que se cierren y se reabran con V3");
   Print("========================================");
}

//+------------------------------------------------------------------+
//| Helper: Trim de espacios                                        |
//+------------------------------------------------------------------+
string Trim(string s)
{
   int len = StringLen(s);
   if(len == 0) return("");
   
   int start = 0;
   while(start < len && StringGetCharacter(s, start) == ' ')
      start++;
   
   if(start >= len) return("");
   
   int end = len - 1;
   while(end >= start && StringGetCharacter(s, end) == ' ')
      end--;
   
   return(StringSubstr(s, start, end - start + 1));
}

