//+------------------------------------------------------------------+
//|                                        BvnlOps_FileBridge.mq5   |
//|                                       BVNL Solution v1.0        |
//|                                                                  |
//| Writes JSON snapshots to the MT5 Common Files folder so the     |
//| BvnlOps.Mcp C# server can read account/position/price data      |
//| and pass trade commands back.                                    |
//|                                                                  |
//| Setup:                                                           |
//|   1. Copy to MT5 → Experts → BVNL folder                        |
//|   2. Attach to ANY chart (one instance per account is enough)   |
//|   3. Enable "Algo trading" button in MT5 toolbar                 |
//|   4. Under Tools → Options → Expert Advisors:                   |
//|        ☑ Allow algorithmic trading                              |
//|        ☑ Allow DLL imports (not needed for this EA)             |
//|   5. Files are written to:                                       |
//|      %APPDATA%\MetaQuotes\Terminal\Common\Files\                 |
//+------------------------------------------------------------------+
#property copyright "BVNL Solution"
#property version   "1.00"
#property strict

input int    UpdateIntervalMs = 1000;
input string WatchList        = "XAUUSD,EURUSD,GBPUSD,USDJPY,BTCUSD";
input string MagicTag         = "BVNL-MCP";

string g_watchSymbols[];

int OnInit()
  {
   StringSplit(WatchList, ',', g_watchSymbols);
   EventSetMillisecondTimer(UpdateIntervalMs);
   PrintFormat("BvnlOps FileBridge v1.0 | interval=%dms | watching %d symbols",
               UpdateIntervalMs, ArraySize(g_watchSymbols));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTimer()
  {
   WriteAccount();
   WritePositions();
   WriteQuotes();
   CheckCommand();
  }

void OnTick()
  {
   WriteQuote(_Symbol);
  }

void WriteAccount()
  {
   string login    = (string)AccountInfoInteger(ACCOUNT_LOGIN);
   string server   = AccountInfoString(ACCOUNT_SERVER);
   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin   = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMgn  = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double profit   = AccountInfoDouble(ACCOUNT_PROFIT);
   int    leverage = (int)AccountInfoInteger(ACCOUNT_LEVERAGE);

   string json = StringFormat(
      "{\n"
      "  \"Login\":     \"%s\",\n"
      "  \"Server\":    \"%s\",\n"
      "  \"Currency\":  \"%s\",\n"
      "  \"Balance\":   %.2f,\n"
      "  \"Equity\":    %.2f,\n"
      "  \"Margin\":    %.2f,\n"
      "  \"FreeMargin\":%.2f,\n"
      "  \"Profit\":    %.2f,\n"
      "  \"Leverage\":  %d,\n"
      "  \"UpdatedAt\": \"%s\"\n"
      "}",
      login, server, currency,
      balance, equity, margin, freeMgn, profit, leverage,
      TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS));

   WriteCommonFile("bvnl_account.json", json);
  }

void WritePositions()
  {
   string items = "";
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;

      string posType = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      string item = StringFormat(
         "    {\n"
         "      \"Ticket\":       %I64d,\n"
         "      \"Symbol\":       \"%s\",\n"
         "      \"Type\":         \"%s\",\n"
         "      \"Volume\":       %.2f,\n"
         "      \"OpenPrice\":    %.5f,\n"
         "      \"CurrentPrice\": %.5f,\n"
         "      \"StopLoss\":     %.5f,\n"
         "      \"TakeProfit\":   %.5f,\n"
         "      \"Profit\":       %.2f,\n"
         "      \"Swap\":         %.2f,\n"
         "      \"Comment\":      \"%s\",\n"
         "      \"OpenTime\":     \"%s\"\n"
         "    }",
         (long)ticket,
         PositionGetString(POSITION_SYMBOL),
         posType,
         PositionGetDouble(POSITION_VOLUME),
         PositionGetDouble(POSITION_PRICE_OPEN),
         PositionGetDouble(POSITION_PRICE_CURRENT),
         PositionGetDouble(POSITION_SL),
         PositionGetDouble(POSITION_TP),
         PositionGetDouble(POSITION_PROFIT),
         PositionGetDouble(POSITION_SWAP),
         PositionGetString(POSITION_COMMENT),
         TimeToString((datetime)PositionGetInteger(POSITION_TIME), TIME_DATE|TIME_SECONDS));

      if(StringLen(items) > 0) items += ",\n";
      items += item;
     }

   string json = "{\n  \"Positions\": [\n" + items + "\n  ]\n}";
   WriteCommonFile("bvnl_positions.json", json);
  }

void WriteQuotes()
  {
   WriteQuote(_Symbol);
   for(int i = 0; i < ArraySize(g_watchSymbols); i++)
     {
      string sym = g_watchSymbols[i];
      StringTrimLeft(sym); StringTrimRight(sym);
      if(StringLen(sym) > 0 && sym != _Symbol)
         WriteQuote(sym);
     }
  }

void WriteQuote(string symbol)
  {
   double bid    = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double spread = (ask - bid) / _Point;

   if(bid <= 0.0 || ask <= 0.0) return;

   string json = StringFormat(
      "{\n"
      "  \"Bid\":    %.5f,\n"
      "  \"Ask\":    %.5f,\n"
      "  \"Spread\": %.1f,\n"
      "  \"Time\":   \"%s\"\n"
      "}",
      bid, ask, spread,
      TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS));

   WriteCommonFile("bvnl_price_" + symbol + ".json", json);
  }

void CheckCommand()
  {
   string path = "bvnl_command.json";
   if(!FileIsExist(path, FILE_COMMON)) return;

   int fh = FileOpen(path, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh == INVALID_HANDLE) return;
   string content = "";
   while(!FileIsEnding(fh)) content += FileReadString(fh);
   FileClose(fh);
   FileDelete(path, FILE_COMMON);

   string action = ParseField(content, "Action");
   string symbol = ParseField(content, "Symbol");
   string side   = ParseField(content, "Side");
   double volume = StringToDouble(ParseField(content, "Volume"));
   double sl     = StringToDouble(ParseField(content, "StopLoss"));
   double tp     = StringToDouble(ParseField(content, "TakeProfit"));
   long   ticket = StringToInteger(ParseField(content, "Ticket"));
   string comment= ParseField(content, "Comment");
   if(StringLen(comment) == 0) comment = MagicTag;

   string resultJson = "";

   if(action == "OPEN")
      resultJson = ExecuteOpen(symbol, side, volume, sl, tp, comment);
   else if(action == "CLOSE")
      resultJson = ExecuteClose(ticket);
   else if(action == "MODIFY")
      resultJson = ExecuteModify(ticket, sl, tp);
   else
      resultJson = MakeResult(false, "Unknown action: " + action, 0, 0);

   WriteCommonFile("bvnl_command_result.json", resultJson);
  }

string ExecuteOpen(string symbol, string side, double volume, double sl, double tp, string comment)
  {
   MqlTradeRequest req  = {};
   MqlTradeResult  res  = {};
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = symbol;
   req.volume    = volume;
   req.type      = (side == "SELL") ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price     = (side == "SELL") ? SymbolInfoDouble(symbol, SYMBOL_BID)
                                    : SymbolInfoDouble(symbol, SYMBOL_ASK);
   req.sl        = sl;
   req.tp        = tp;
   req.comment   = comment;
   req.magic     = 20260802;
   req.deviation = 30;
   req.type_filling = ORDER_FILLING_FOK;

   if(!OrderSend(req, res))
      return MakeResult(false, "OrderSend failed: rc=" + (string)res.retcode, 0, 0);

   return MakeResult(true, "Executed", (long)res.deal, res.price);
  }

string ExecuteClose(long ticket)
  {
   if(!PositionSelectByTicket((ulong)ticket))
      return MakeResult(false, "Position not found: #" + (string)ticket, 0, 0);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action   = TRADE_ACTION_DEAL;
   req.position = (ulong)ticket;
   req.symbol   = PositionGetString(POSITION_SYMBOL);
   req.volume   = PositionGetDouble(POSITION_VOLUME);
   req.type     = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                  ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price    = (req.type == ORDER_TYPE_SELL)
                  ? SymbolInfoDouble(req.symbol, SYMBOL_BID)
                  : SymbolInfoDouble(req.symbol, SYMBOL_ASK);
   req.deviation= 30;
   req.type_filling = ORDER_FILLING_FOK;

   if(!OrderSend(req, res))
      return MakeResult(false, "Close failed: rc=" + (string)res.retcode, 0, 0);

   return MakeResult(true, "Closed", (long)ticket, res.price);
  }

string ExecuteModify(long ticket, double sl, double tp)
  {
   if(!PositionSelectByTicket((ulong)ticket))
      return MakeResult(false, "Position not found: #" + (string)ticket, 0, 0);

   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   double newSL = (sl > 0) ? sl : curSL;
   double newTP = (tp > 0) ? tp : curTP;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action   = TRADE_ACTION_SLTP;
   req.position = (ulong)ticket;
   req.symbol   = PositionGetString(POSITION_SYMBOL);
   req.sl       = newSL;
   req.tp       = newTP;

   if(!OrderSend(req, res))
      return MakeResult(false, "Modify failed: rc=" + (string)res.retcode, 0, 0);

   return MakeResult(true, "Modified", ticket, PositionGetDouble(POSITION_PRICE_CURRENT));
  }

string MakeResult(bool success, string message, long ticket, double price)
  {
   return StringFormat(
      "{\n"
      "  \"Success\": %s,\n"
      "  \"Message\": \"%s\",\n"
      "  \"Ticket\":  %I64d,\n"
      "  \"Price\":   %.5f,\n"
      "  \"Time\":    \"%s\"\n"
      "}",
      success ? "true" : "false",
      message, ticket, price,
      TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS));
  }

void WriteCommonFile(string filename, string content)
  {
   string tmp = filename + ".tmp";
   int fh = FileOpen(tmp, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh == INVALID_HANDLE)
     {
      PrintFormat("FileBridge: cannot open %s for write, err=%d", tmp, GetLastError());
      return;
     }
   FileWriteString(fh, content);
   FileClose(fh);
   if(FileIsExist(filename, FILE_COMMON)) FileDelete(filename, FILE_COMMON);
   FileCopy(tmp, FILE_COMMON, filename, FILE_COMMON|FILE_REWRITE);
   FileDelete(tmp, FILE_COMMON);
  }

string ParseField(const string json, const string field)
  {
   string search = "\"" + field + "\"";
   int pos = StringFind(json, search);
   if(pos < 0) return "";
   pos += StringLen(search);
   while(pos < StringLen(json) && (StringGetCharacter(json, pos) == ' ' ||
         StringGetCharacter(json, pos) == ':')) pos++;
   if(StringGetCharacter(json, pos) == '"')
     {
      pos++;
      int end = StringFind(json, "\"", pos);
      if(end < 0) return "";
      return StringSubstr(json, pos, end - pos);
     }
   int end = pos;
   while(end < StringLen(json) &&
         StringGetCharacter(json, end) != ',' &&
         StringGetCharacter(json, end) != '}' &&
         StringGetCharacter(json, end) != '\n') end++;
   string val = StringSubstr(json, pos, end - pos);
   StringTrimLeft(val); StringTrimRight(val);
   return val;
  }
