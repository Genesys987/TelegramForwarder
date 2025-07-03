//+------------------------------------------------------------------+
//|                                     TelegramSignalForwarder.mq4  |
//|                Clean, Modular & Readable Code Refactoring       |
//|                           Copyright 2025, OpenAI & User Request  |
//+------------------------------------------------------------------+
#property strict

//+------------------------------------------------------------------+
//|--- Extern Parameters (EA Configuration)                         |
//+------------------------------------------------------------------+
extern bool   debugMode                = true;  // Enable detailed logging
extern int    trailingCheckIntervalSec = 5;     // Interval (sec) between trailing stop scans
extern int    triggerTolerancePips     = 5;     // Pips tolerance for trailing stop trigger
extern int    brokerTimeOffsetMinutes  = 120;   // Broker time offset from UTC in minutes (e.g., UTC+2 = 120)
extern int    signalMaxAgeMinutes      = 5;     // Maximum signal age in minutes before rejection
extern string symbolPostfix           = "";     // Broker-specific symbol postfix (e.g., ".m", ".ecn")
extern bool   useLimitOrders           = true;  // Use limit orders at middle between entry and TP1
extern double fixedLotSize              = 0.02;  // Default lot size for FX orders
extern double fixedLotSizeBitcoin       = 0.02;  // Default lot size for Bitcoin orders
extern double fixedLotSizeGold          = 0.02;  // Default lot size for Gold orders

//+------------------------------------------------------------------+
//|--- Constants & File Paths                                        |
//+------------------------------------------------------------------+
#define MAGIC_NUMBER          123456             // Unique EA identifier
#define SL_MODIFY_THRESHOLD   0.00001            // Minimum SL diff to apply
#define MAX_GROUPS            50                 // Max groups for trailing stop
#define MAX_MODIFIED_TICKETS  100                // Max tickets modified per cycle

static string gSignalFile     = "signals.txt";       // Incoming signal file
static string gTempFile       = "processing.txt";     // Temp file to avoid re-read
static string gExternalSLFile = "stoploss_update.txt";// External SL updates

//+------------------------------------------------------------------+
//|--- Global State Variables                                       |
//+------------------------------------------------------------------+
int      triggeredGroups[MAX_GROUPS];    // Array of group IDs that triggered TS
int      triggeredCount      = 0;
int      modifiedTickets[MAX_MODIFIED_TICKETS]; // Array of tickets modified by TS
int      modifiedCount       = 0;
datetime lastTrailingScan     = 0;       // Timestamp of last TS scan
string   eaName               = "TelegramSignalForwarder";
int      fh = -1;                  // File handle for reading signals
string   nextSignal = "";

//+------------------------------------------------------------------+
//|--- Function Prototypes                                          |
//+------------------------------------------------------------------+
bool    ReadSignalFile(string &signalType, string &symbol, double &entryPrice,
                       double &stopLoss,
                       double &tp1, double &tp2, double &tp3,
                       int &groupId, string &channelName);
void    UpdateExistingOrdersSL(string symbol, string signalType, double newSL, string channelName);
void    SendOrders(string signalType, string symbol,
                         double entryPrice, double stopLoss, double tp1, double tp2, double tp3,
                         int groupId, string channelName);
int     GetOrderType(string signalType);
void    HandleTrailingStops();
void    ProcessExternalSLUpdates();
bool    ParseOrderComment(string comment, int &groupId, double &signalSL);
bool    ParseOrderCommentFull(string comment, int &groupId, double &signalSL, string &channelName);
bool    HasBeenModified(int ticket);
void    MarkAsModified(int ticket);
void    AddTriggeredGroup(int groupId);
bool    CheckStopLevel(string symbol, int orderType,
                       double sl, double ask, double bid);
bool    CheckFreezeLevel(string symbol,
                         double openPrice, double ask, double bid);

// Utility functions
bool    IsSignalTooOld(long signalTimestampMs);
bool    FileExists(string filename);
string  Trim(string s);
string  ToUpperCase(string s);
bool    IsValidDouble(string s);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int init()
{
    // Initialize arrays
    ArrayInitialize(triggeredGroups, -1);
    ArrayInitialize(modifiedTickets, -1);
    triggeredCount   = 0;
    modifiedCount    = 0;
    lastTrailingScan = 0;

    // Use chart's expert name if provided
    string customName = WindowExpertName();
    if(StringLen(customName) > 0)
        eaName = customName;

    if(debugMode)
        Print(eaName, ": Initialized");

    return(0);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
int deinit()
{
    if(debugMode)
        Print(eaName, ": Deinitialized");
    return(0);
}

//+------------------------------------------------------------------+
//| Expert tick handler                                              |
//+------------------------------------------------------------------+
int start()
{
    string signalType, symbol, channelName;
    double entryPrice, stopLoss, tp1, tp2, tp3;
    int    groupId;

    if(IsTradeAllowed() && IsConnected() && !IsStopped())
    {
        // Process new signal
        if(ReadSignalFile(signalType, symbol, entryPrice,
                          stopLoss, tp1, tp2, tp3, groupId, channelName))
        {
            if(debugMode)
                Print(eaName, ": Processing signal from channel '", channelName, "' - GID=", IntegerToString(groupId));
                
            UpdateExistingOrdersSL(symbol, signalType, stopLoss, channelName);
            SendOrders(signalType, symbol,
                             entryPrice, stopLoss, tp1, tp2, tp3,
                             groupId, channelName);
        }
        // Apply trailing stop logic
        HandleTrailingStops();
    }

    // Process external SL updates
    ProcessExternalSLUpdates();
    return(0);
}

//+------------------------------------------------------------------+
//| ReadSignalFile: Parses a signal line from file                   |
//+------------------------------------------------------------------+
bool ReadSignalFile(string &signalType, string &symbol, double &entryPrice,
                    double &stopLoss,
                    double &tp1, double &tp2, double &tp3,
                    int &groupId, string &channelName)
{
  string line = "";
  if (StringLen(nextSignal) == 0)
  {
      if(fh == -1) 
      {
          if(!FileExists(gSignalFile)) return(false);
          fh = FileOpen(gSignalFile, FILE_READ | FILE_TXT | FILE_ANSI);
          Print(eaName, ": Opening signal file ", gSignalFile);
          if(fh == INVALID_HANDLE) {
              Print(eaName, ": Failed to open signal file");
              return(false);
          }
      }

      if(fh == INVALID_HANDLE)
      {
          Print(eaName, ": Failed to open temp file for reading");
          return(false);
      }
      if(IsTesting() && FileIsEnding(fh))
      {
          FileClose(fh);
          return(false);
      }
      line = FileReadString(fh);
      if(debugMode)
      {
          Print(eaName, ": Read signal line: [", line, "]");
      }
      if(!IsTesting())
      {
          FileClose(fh);
          fh = -1;
          FileDelete(gSignalFile);
      }
  } else {
    line = nextSignal;
  }

    if(StringLen(line) == 0) {
        return(false);
    }

    // Expect: 123456789|TYPE|SYMBOL|ENTRY|TP1,TP2,TP3|SL|GID:<id>|CHANNEL_NAME
    string parts[];
    if(StringSplit(line, '|', parts) < 8) {
        Print(eaName, ": Invalid signal format, expected 8 parts but got ", IntegerToString(ArraySize(parts)));
        return(false);
    }

    // 0) Extract and validate timestamp (first part, no prefix)
    string timestampStr = parts[0];
    long signalTimestamp = StrToInteger(timestampStr);
    
    if(IsSignalTooOld(signalTimestamp))
    {
      if (!IsTesting())
        {
            Print(eaName, ": Signal too old, skipping. Timestamp=", IntegerToString(signalTimestamp));
        }
        else
        {
            nextSignal = line; // Store for next call in testing mode
            return(false);
        }
    }
    
    nextSignal = "";

    // 1) Signal type
    signalType = ToUpperCase(Trim(parts[1]));
    if(signalType != "BUY" && signalType != "SELL") {
        Print(eaName, ": Invalid signal type '", signalType, "', expected BUY or SELL");
        return(false);
    }

    // 2) Symbol validation
    symbol = Trim(parts[2]) + symbolPostfix;
    if(MarketInfo(symbol, MODE_TIME) == 0) {
        Print(eaName, ": Invalid symbol '", symbol, "', skipping");
        return(false);
    }

    // 3) Entry price
    if(!IsValidDouble(parts[3])) {
        Print(eaName, ": Invalid entry price '", parts[3], "', skipping");
        return(false);
    }
    entryPrice = NormalizeDouble(StrToDouble(parts[3]), MarketInfo(symbol, MODE_DIGITS));

    // 4) TP levels
    string tpsArr[];
    if(StringSplit(parts[4], ',', tpsArr) < 3) {
        Print(eaName, ": Invalid TP levels '", parts[4], "', skipping");
        return(false);
    }
    tp1 = NormalizeDouble(StrToDouble(tpsArr[0]), MarketInfo(symbol, MODE_DIGITS));
    tp2 = NormalizeDouble(StrToDouble(tpsArr[1]), MarketInfo(symbol, MODE_DIGITS));
    tp3 = NormalizeDouble(StrToDouble(tpsArr[2]), MarketInfo(symbol, MODE_DIGITS));

    // 5) Stop loss, remove brackets
    string rawSL = parts[5];
    while(StringFind(rawSL, "[") >= 0)
    {
        int b1 = StringFind(rawSL, "[");
        int b2 = StringFind(rawSL, "]", b1);
        if(b2 < 0) break;
        rawSL = StringSubstr(rawSL, 0, b1) + StringSubstr(rawSL, b2+1);
    }
    if(!IsValidDouble(rawSL)) {
        Print(eaName, ": Invalid stop loss '", rawSL, "', skipping");
        return(false);
    }
    stopLoss = NormalizeDouble(StrToDouble(rawSL), MarketInfo(symbol, MODE_DIGITS));

    // 6) Group ID
    string gidPart = parts[6];
    if(StringFind(gidPart, "GID:") != 0) {
        Print(eaName, ": Invalid group ID format '", gidPart, "', skipping");
        return(false);
    }
    groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
    if(groupId <= 0) {
        Print(eaName, ": Invalid group ID '", IntegerToString(groupId), "', skipping");
        return(false);
    }

    // 7) Channel Name (new field)
    if(ArraySize(parts) >= 8) {
        channelName = Trim(parts[7]);
        if(StringLen(channelName) == 0) channelName = "UNKNOWN";
    } else {
        channelName = "LEGACY"; // For backward compatibility with old signals
    }

    Print(eaName, ": Parsed signal GID=", IntegerToString(groupId), " from channel '", channelName, "'");

    return(true);
}

//+------------------------------------------------------------------+
//| UpdateExistingOrdersSL: Update SL of existing orders from same channel |
//+------------------------------------------------------------------+
void UpdateExistingOrdersSL(string symbol, string signalType, double newSL, string channelName)
{
    int targetOrderType = (signalType == "BUY") ? OP_BUY : OP_SELL;
    
    for(int i=0; i<OrdersTotal(); i++)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
          if (debugMode) Print(eaName, ": Failed to select order at index ", IntegerToString(i), " - error=", IntegerToString(GetLastError()));
          continue;
        }
        if(OrderMagicNumber() != MAGIC_NUMBER) {
          if (debugMode) Print(eaName, ": Ignoring order at index ", IntegerToString(i), " - wrong magic number");
          continue;
        }
        if(OrderSymbol() != symbol || OrderType() != targetOrderType) {
          if (debugMode) Print(eaName, ": Ignoring order at index ", IntegerToString(i), " - symbol/type mismatch");
          continue;
        }

        // Parse the order's comment to get channel information
        int orderGid;
        double orderSL;
        string orderChannelName;
        if(!ParseOrderCommentFull(OrderComment(), orderGid, orderSL, orderChannelName)) {
            if (debugMode) Print(eaName, ": Failed to parse order comment for ticket ", IntegerToString(OrderTicket()), ": ", OrderComment());
            continue;
        }

        // Only update SL if the order is from the same channel
        if(orderChannelName != channelName) {
            if (debugMode) Print(eaName, ": Ignoring order ticket ", IntegerToString(OrderTicket()), 
                                " - different channel (order='", orderChannelName, "', signal='", channelName, "')");
            continue;
        }

        double currSL = OrderStopLoss();
        if(MathAbs(currSL - newSL) > SL_MODIFY_THRESHOLD)
        {
            double openP = OrderOpenPrice();
            double tp    = OrderTakeProfit();
            bool ok = OrderModify(OrderTicket(), openP, newSL, tp, 0, clrBlue);
            if(ok)
                Print(eaName, ": Updated SL for ticket=", IntegerToString(OrderTicket()), 
                      " from channel '", channelName, "' (", DoubleToString(currSL, MarketInfo(symbol, MODE_DIGITS)), 
                      " -> ", DoubleToString(newSL, MarketInfo(symbol, MODE_DIGITS)), ")");
            else
                Print(eaName, ": SL update failed ticket=", IntegerToString(OrderTicket()),
                      " err=", IntegerToString(GetLastError()));
        } else {
            if (debugMode) Print(eaName, ": SL change too small for ticket ", IntegerToString(OrderTicket()), 
                                " - current=", DoubleToString(currSL, MarketInfo(symbol, MODE_DIGITS)), 
                                " new=", DoubleToString(newSL, MarketInfo(symbol, MODE_DIGITS)));
        }
    }
}

//+------------------------------------------------------------------+
//| SendOrders: Place three market or limit orders with SL & TP        |
//+------------------------------------------------------------------+
void SendOrders(string signalType, string symbol,
                      double entryPrice, double stopLoss, double tp1, double tp2, double tp3,
                      int groupId, string channelName)
{
    int digits    = MarketInfo(symbol, MODE_DIGITS);
    double point  = MarketInfo(symbol, MODE_POINT);
    int stopLevel = MarketInfo(symbol, MODE_STOPLEVEL);

    RefreshRates();
    double ask = MarketInfo(symbol, MODE_ASK);
    double bid = MarketInfo(symbol, MODE_BID);
    double price;
    bool shouldBuy = signalType == "BUY";
    double midPrice = (entryPrice + tp1) / 2.0; // Midpoint for limit order logic
    // mid price is halfway between entry and TP1
    // between entry and mid price, market orders are used
    // between mid price and TP1, limit orders are used for the mid price
    bool shouldUseLimitOrders = useLimitOrders && (shouldBuy ? ask > midPrice : bid < midPrice);

    int orderType;
    if(shouldUseLimitOrders) {
        price = midPrice;
        orderType = (shouldBuy) ? OP_BUYLIMIT : OP_SELLLIMIT;
    } else {
        price = shouldBuy ? ask : bid;
        orderType = (shouldBuy) ? OP_BUY : OP_SELL;
    }
    price = NormalizeDouble(price, digits);

    // Check if we've missed TP1 already
    bool missedTP1 = (shouldBuy) ? bid >= tp1 : ask <= tp1;

    // Determine which SL to use
    double rawSL, fallbackSL;
    if(missedTP1) {
        // Use entry price as SL if we've missed TP1
        rawSL = NormalizeDouble(entryPrice, digits);
        fallbackSL = rawSL; // No fallback needed since we're using entry
    } else {
        // Normal SL logic
        rawSL = NormalizeDouble(stopLoss, digits);
        fallbackSL = (shouldBuy)
                        ? price - MathAbs(entryPrice - stopLoss)
                        : price + MathAbs(stopLoss - entryPrice);
        fallbackSL = NormalizeDouble(fallbackSL, digits);
    }

    // Apply minimum distance for SL if needed
    double minDist = MathMax(stopLevel * point, point);
    if(shouldBuy && price - fallbackSL < minDist) fallbackSL = price - minDist;
    if(!shouldBuy && fallbackSL - price < minDist) fallbackSL = price + minDist;
    fallbackSL = NormalizeDouble(fallbackSL, digits);

    double tps[3];
    tps[0] = tp1;
    tps[1] = tp2;
    tps[2] = tp3;

    for(int j=0; j<3; j++)
    {
        tps[j] = NormalizeDouble(tps[j], digits);
        double dist = MathAbs(tps[j] - entryPrice);
        if(dist < minDist)
            tps[j] = (shouldBuy) ? price + minDist : price - minDist;
        tps[j] = NormalizeDouble(tps[j], digits);
    }

    Print(eaName, ": Sending orders for GID=", IntegerToString(groupId),
          " from channel '", channelName, "'",
          " Missed TP1=", missedTP1 ? "Yes" : "No",
          " Using SL=", DoubleToString(rawSL, digits));

    int slippage = 5;
    color cols[3] = { clrBlue, clrGreen, clrRed };
    double lotSize = (symbol == "BTCUSD") ? fixedLotSizeBitcoin :
                        (symbol == "XAUUSD") ? fixedLotSizeGold : fixedLotSize;

    for(int k=0; k<3; k++)
    {
        RefreshRates();
        string comment = "GID:" + IntegerToString(groupId) + "|" + channelName + "|SL:" + DoubleToString(rawSL, digits);
    
        Print(eaName, ": Order[", IntegerToString(k), "] parameters: ",
        "Symbol=", symbol,
        " Type=", IntegerToString(orderType),
        " Lots=", DoubleToString(lotSize, 2),
        " Price=", DoubleToString(price, digits),
        " SL=", DoubleToString(rawSL, digits),
        " TP=", DoubleToString(tps[k], digits),
        " Comment=", comment);

        int ticket = OrderSend(symbol, orderType, lotSize, price, slippage,
                               rawSL, tps[k], comment, MAGIC_NUMBER, 0, cols[k]);
                               
        if(ticket < 0) {
            Print(eaName, ": Error creating order[", IntegerToString(k), "] ticket=", IntegerToString(ticket), " error=", IntegerToString(GetLastError()));
        }
        
        if(ticket < 0 && GetLastError() == ERR_INVALID_STOPS)
        {
            RefreshRates();
            // retry with fallback SL
            Print(eaName, ": Retrying with fallback SL=", DoubleToString(fallbackSL, digits));
            ticket = OrderSend(symbol, orderType, fixedLotSize, price, slippage,
                               fallbackSL, tps[k], comment, MAGIC_NUMBER, 0, cols[k]);
        }
        
        Print(eaName, ": Order[", IntegerToString(k), "] ticket=", IntegerToString(ticket));
    }
}

//+------------------------------------------------------------------+
//| HandleTrailingStops: Refined trailing stop logic                |
//+------------------------------------------------------------------+
void HandleTrailingStops()
{
    datetime now = TimeCurrent();
    if(now - lastTrailingScan < trailingCheckIntervalSec) return;
    
    lastTrailingScan = now;

    int historyTotal = OrdersHistoryTotal();
    if(debugMode) Print(eaName, ": TS checking ", IntegerToString(historyTotal), " history orders");

    for(int i=historyTotal-1; i>=0; i--)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) 
        {
            Print(eaName, ": TS history order select failed at index ", IntegerToString(i));
            continue;
        }
        if(OrderMagicNumber() != MAGIC_NUMBER) 
        {
            if(debugMode) Print(eaName, ": TS skipping history order - wrong magic number: ", IntegerToString(OrderMagicNumber()));
            continue;
        }
        double closeP = OrderClosePrice();
        double tp       = OrderTakeProfit();
        double tol      = triggerTolerancePips * MarketInfo(OrderSymbol(), MODE_POINT);
        bool  triggered = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT)
                          ? (closeP >= tp - tol)
                          : (closeP <= tp + tol);
        if(!triggered) 
        {
            if(debugMode) Print(eaName, ": TS order not triggered ticket ", IntegerToString(OrderTicket()), " - closeP=", DoubleToString(closeP, 5), 
                     " tp=", DoubleToString(tp, 5), " tol=", DoubleToString(tol, 5));
            continue;
        }
        int gid; double sl;
        if(ParseOrderComment(OrderComment(), gid, sl))
        {
            if(debugMode) Print(eaName, ": TS adding triggered group: ", IntegerToString(gid));
            AddTriggeredGroup(gid);
        }
        else if(debugMode) 
            Print(eaName, ": TS failed to parse comment: ", OrderComment());
    }

    if(triggeredCount == 0)
    {
        if(debugMode) Print(eaName, ": no TS triggers found");
        return;
    }

    if(debugMode) Print(eaName, ": TS found ", IntegerToString(triggeredCount), " triggered groups");

    int openTotal = OrdersTotal();
    if(debugMode) Print(eaName, ": TS checking ", IntegerToString(openTotal), " open orders");
    
    for(int m=0; m<openTotal; m++)
    {
        if(!OrderSelect(m, SELECT_BY_POS, MODE_TRADES)) 
        {
            Print(eaName, ": TS open order select failed at index ", IntegerToString(m));
            continue;
        }
        if(OrderMagicNumber() != MAGIC_NUMBER) 
        {
            if(debugMode) Print(eaName, ": TS skipping open order - wrong magic number: ", IntegerToString(OrderMagicNumber()));
            continue;
        }
        int ticket = OrderTicket();
        if(HasBeenModified(ticket)) 
        {
            if(debugMode) Print(eaName, ": TS skipping ticket ", IntegerToString(ticket), " - already modified");
            continue;
        }

        int gid; double sl;
        if(!ParseOrderComment(OrderComment(), gid, sl)) 
        {
            if(debugMode) Print(eaName, ": TS failed to parse comment for ticket ", IntegerToString(ticket), ": ", OrderComment());
            continue;
        }

        bool belongs = false;
        for(int n=0; n<triggeredCount; n++)
            if(triggeredGroups[n] == gid) { belongs = true; break; }
        if(!belongs) 
        {
            if(debugMode) Print(eaName, ": TS ticket ", IntegerToString(ticket), " GID ", IntegerToString(gid), " not in triggered groups");
            continue;
        }

        double openP = OrderOpenPrice();
        int d       = MarketInfo(OrderSymbol(), MODE_DIGITS);
        double newSL = NormalizeDouble(openP, d);
        double ask   = MarketInfo(OrderSymbol(), MODE_ASK);
        double bid   = MarketInfo(OrderSymbol(), MODE_BID);
        if(!CheckFreezeLevel(OrderSymbol(), openP, ask, bid) ||
           !CheckStopLevel (OrderSymbol(), OrderType(), newSL, ask, bid))
        {
            Print(eaName, ": TS ticket ", IntegerToString(ticket), " failed freeze/stop level checks");
            continue;
        }

        if(OrderModify(ticket, openP, newSL, OrderTakeProfit(), 0, clrMagenta))
        {
            Print(eaName, ": TS successfully modified ticket ", IntegerToString(ticket), " to SL=", DoubleToString(newSL, d));
            MarkAsModified(ticket);
        }
        else Print(eaName, ": TS modify fail ticket=", IntegerToString(ticket),
                  " err=", IntegerToString(GetLastError()));
    }
    
    if(debugMode) Print(eaName, ": TS scan complete");
}

//+------------------------------------------------------------------+
//| ProcessExternalSLUpdates: Apply external SL update commands     |
//+------------------------------------------------------------------+
void ProcessExternalSLUpdates()
{
    if(!FileExists(gExternalSLFile)) return;
    if(fh == -1)
    {
      fh = FileOpen(gExternalSLFile, FILE_READ|FILE_TXT|FILE_ANSI);
    }
    if(fh == INVALID_HANDLE) return;
    string cmd = FileReadString(fh);
    if(!IsTesting()) {
      FileClose(fh);
      fh = -1;
      FileDelete(gExternalSLFile);
    }

    int sep = StringFind(cmd, "|NEW_SL:");
    if(StringFind(cmd, "GID:") != 0 || sep < 0) {
      Print(eaName, "Not a SL modify command: ", cmd);
      return;
    }
    int gid      = (int)StrToInteger(StringSubstr(cmd, 4, sep-4));
    double newSL = StrToDouble(StringSubstr(cmd, sep+8));

    int total = OrdersTotal();
    for(int i=0; i<total; i++)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            Print(eaName, ": ext SL order select failed at index ", IntegerToString(i));
            continue;
        }
        if(OrderMagicNumber() != MAGIC_NUMBER) {
            if(debugMode) Print(eaName, ": Ignoring order at index ", IntegerToString(i), " - wrong magic number");
            continue;
        }
        if(StringFind(OrderComment(), "GID:" + IntegerToString(gid)) < 0) {
            if(debugMode) Print(eaName, ": Ignoring order at index ", IntegerToString(i), " - GID mismatch");
            continue;
        }
        double op = OrderOpenPrice();
        double tp = OrderTakeProfit();
        if(!OrderModify(OrderTicket(), op, newSL, tp, 0, clrGold))
            Print(eaName, ": ext SL update fail GID=", IntegerToString(gid),
                  " err=", IntegerToString(GetLastError()));
    }
}

//+------------------------------------------------------------------+
//| ParseOrderComment: extracts GID and SL from trade comment       |
//+------------------------------------------------------------------+
bool ParseOrderComment(string comment, int &groupId, double &signalSL)
{
    string channelName = "";
    return ParseOrderCommentFull(comment, groupId, signalSL, channelName);
}

//+------------------------------------------------------------------+
//| ParseOrderCommentFull: extracts GID, SL and channel from comment|
//+------------------------------------------------------------------+
bool ParseOrderCommentFull(string comment, int &groupId, double &signalSL, string &channelName)
{
    // New format: GID:1234|CHANNELNAME|SL:1.2345
    // Old format: GID:1234|SL:1.2345 (for backward compatibility)
    
    int p1 = StringFind(comment, "GID:");
    if(p1 != 0) {
        if(debugMode) Print(eaName, ": Invalid comment format, no GID found: ", comment);
        return(false);
    }
    
    // Find first pipe after GID
    int firstPipe = StringFind(comment, "|", 4);
    if(firstPipe < 0) {
        if(debugMode) Print(eaName, ": Invalid comment format, no pipe separator found: ", comment);
        return(false);
    }
    
    // Extract GID
    groupId = StrToInteger(StringSubstr(comment, 4, firstPipe-4));
    if(groupId <= 0) {
        if(debugMode) Print(eaName, ": Invalid GID in comment: ", comment);
        return(false);
    }
    
    // Look for SL: either immediately after first pipe (old format) or after second pipe (new format)
    int slPos = StringFind(comment, "|SL:", firstPipe);
    if(slPos < 0) {
        // Try old format where SL comes right after first pipe
        if(StringSubstr(comment, firstPipe, 3) == "|SL") {
            slPos = firstPipe;
            channelName = "LEGACY"; // Old format
        } else {
            if(debugMode) Print(eaName, ": No SL found in comment: ", comment);
            return(false);
        }
    } else {
        // New format - extract channel name
        if(slPos > firstPipe + 1) {
            channelName = StringSubstr(comment, firstPipe+1, slPos-firstPipe-1);
        } else {
            channelName = "UNKNOWN";
        }
    }
    
    // Extract SL value
    signalSL = StrToDouble(StringSubstr(comment, slPos+4));
    
    if(debugMode) {
        if(StringLen(channelName) > 0 && channelName != "LEGACY") {
            Print(eaName, ": Parsed comment - GID:", IntegerToString(groupId), " Channel:", channelName, " SL:", DoubleToString(signalSL, 5));
        } else {
            Print(eaName, ": Parsed comment (legacy) - GID:", IntegerToString(groupId), " SL:", DoubleToString(signalSL, 5));
        }
    }
    
    return(true);
}

//+------------------------------------------------------------------+
//| HasBeenModified: checks if ticket was already modified          |
//+------------------------------------------------------------------+
bool HasBeenModified(int ticket)
{
    for(int i=0; i<modifiedCount; i++)
        if(modifiedTickets[i] == ticket) return(true);
    return(false);
}

//+------------------------------------------------------------------+
//| MarkAsModified: record ticket as modified                       |
//+------------------------------------------------------------------+
void MarkAsModified(int ticket)
{
    if(modifiedCount < MAX_MODIFIED_TICKETS)
        modifiedTickets[modifiedCount++] = ticket;
}

//+------------------------------------------------------------------+
//| AddTriggeredGroup: add groupId if not present                   |
//+------------------------------------------------------------------+
void AddTriggeredGroup(int groupId)
{
    for(int i=0; i<triggeredCount; i++)
        if(triggeredGroups[i] == groupId) return;
    if(triggeredCount < MAX_GROUPS)
        triggeredGroups[triggeredCount++] = groupId;
}

//+------------------------------------------------------------------+
//| CheckStopLevel: validate new SL against market constraints      |
//+------------------------------------------------------------------+
bool CheckStopLevel(string symbol, int orderType,
                    double sl, double ask, double bid)
{
    if(sl <= 0) return(true);
    int digits = MarketInfo(symbol, MODE_DIGITS);
    double point= MarketInfo(symbol, MODE_POINT);
    double minStopLevelDist = MarketInfo(symbol, MODE_STOPLEVEL) * point + point;
    bool valid;
    if(orderType == OP_BUY || orderType == OP_BUYLIMIT)
         // For buy orders, SL must be below the bid price
         valid = (sl < bid && bid - sl >= minStopLevelDist);
    else if(orderType == OP_SELL || orderType == OP_SELLLIMIT)
         // For sell orders, SL must be above the ask price
         valid = (sl > ask && sl - ask >= minStopLevelDist);
    else valid = false;
    if(!valid)
        Print(eaName, ": invalid SL ", DoubleToString(sl, digits));
    return(valid);
}

//+------------------------------------------------------------------+
//| CheckFreezeLevel: ensure open price respects freeze level      |
//+------------------------------------------------------------------+
bool CheckFreezeLevel(string symbol,
                      double openPrice, double ask, double bid)
{
    double freezePts = MarketInfo(symbol, MODE_FREEZELEVEL);
    if(freezePts <= 0) return(true);
    double freezeDist= freezePts * MarketInfo(symbol, MODE_POINT);
    if(ask <= bid || ask <= 0 || bid <= 0)
    {
        Print(eaName, ": price freeze err");
        return(false);
    }
    if(MathAbs(openPrice-ask) < freezeDist || MathAbs(openPrice-bid) < freezeDist)
    {
        Print(eaName, ": freeze violation");
        return(false);
    }
    return(true);
}

//+------------------------------------------------------------------+
//| IsSignalTooOld: validate if signal timestamp is too old         |
//+------------------------------------------------------------------+
bool IsSignalTooOld(long signalTimestamp)
{
    if(signalTimestamp <= 0) return(true);
    
    datetime signalTime = (datetime)(signalTimestamp);
    
    // Get current broker time and convert to UTC
    datetime brokerTime = TimeCurrent();
    datetime utcTime = brokerTime - (brokerTimeOffsetMinutes * 60);
    
    // Calculate age in minutes
    int ageSeconds = (int)(utcTime - signalTime);
    int ageMinutes = ageSeconds / 60;
    
    if(IsTesting() && ageMinutes < 0)
    {
        // In testing mode, allow negative age (future signals)
        return(true);
    }
    
    if(debugMode)
        Print(eaName, ": Signal age check - UTC now: ", TimeToString(utcTime), 
              ", Signal time: ", TimeToString(signalTime), 
              ", Age: ", IntegerToString(ageMinutes), " minutes");
    
    return(ageMinutes > signalMaxAgeMinutes);
}

//+------------------------------------------------------------------+
//| FileExists: check if a file exists                              |
//+------------------------------------------------------------------+
bool FileExists(string filename)
{
    int tfh = FileOpen(filename, FILE_READ | FILE_TXT | FILE_ANSI);
    if(tfh != INVALID_HANDLE)
    {
        FileClose(tfh);
        return(true);
    }
    return(false);
}

//+------------------------------------------------------------------+
//| Trim: remove whitespace from string ends                        |
//+------------------------------------------------------------------+
string Trim(string s)
{
    int len = StringLen(s);
    int start = 0, end = len - 1;
    while(start < len && StringGetCharacter(s, start) <= 32) start++;
    while(end > start && StringGetCharacter(s, end) <= 32) end--;
    return StringSubstr(s, start, end - start + 1);
}

//+------------------------------------------------------------------+
//| ToUpperCase: convert string to uppercase                        |
//+------------------------------------------------------------------+
string ToUpperCase(string s)
{
    string result = "";
    int length = StringLen(s);
    for(int i = 0; i < length; i++)
    {
        int code = StringGetCharacter(s, i);
        if(code >= 'a' && code <= 'z') code -= 32;
        result += CharToStr(code);
    }
    return result;
}

//+------------------------------------------------------------------+
//| IsValidDouble: validate if string is numeric                    |
//+------------------------------------------------------------------+
bool IsValidDouble(string s)
{
    int len = StringLen(s);
    if(len == 0) return(false);
    bool dotFound = false;
    int start = (StringGetCharacter(s, 0) == '+' || StringGetCharacter(s, 0) == '-') ? 1 : 0;
    for(int i = start; i < len; i++)
    {
        int c = StringGetCharacter(s, i);
        if(c == '.')
        {
            if(dotFound) return(false);
            dotFound = true;
        }
        else if(c < '0' || c > '9') return(false);
    }
    return(true);
}

//+------------------------------------------------------------------+
