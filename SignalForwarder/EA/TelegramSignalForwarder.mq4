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
extern double limitOrderExpirationSec = -1;   // Limit order expiration time in seconds (-1 to disable)

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
//|--- Trailing Stop Structure                                      |
//+------------------------------------------------------------------+
struct TriggeredGroup {
    int groupId;
    int triggeredTPLevel;  // Which TP was hit (1=TP1, 2=TP2, etc.)
    datetime triggerTime;
};

//+------------------------------------------------------------------+
//|--- Global State Variables                                       |
//+------------------------------------------------------------------+
TriggeredGroup triggeredGroups[MAX_GROUPS];    // Array of groups that triggered TS
int      triggeredCount      = 0;
int      modifiedTickets[MAX_MODIFIED_TICKETS]; // Array of tickets modified by TS
int      modifiedCount       = 0;
datetime lastTrailingScan     = 0;       // Timestamp of last TS scan
string   eaName               = "TelegramSignalForwarder";
int      fh = -1;                  // File handle for reading signals
string   nextSignal = "";
int      lastProcessedGroupId = -1; // Track last processed signal to avoid duplicates
datetime lastProcessedTime = 0;     // Track last processed time for additional safety

//+------------------------------------------------------------------+
//|--- Function Prototypes                                          |
//+------------------------------------------------------------------+
bool    ReadSignalFile(string &signalType, string &symbol, double &entryPrice,
                       double &stopLoss,
                       double &tp1, double &tp2, double &tp3,
                       int &groupId, string &channelName, double &tpLevels[], int &tpCount);
void    UpdateExistingOrdersSL(string symbol, string signalType, double newSL, string channelName);
void    SendOrders(string signalType, string symbol,
                         double entryPrice, double stopLoss, double tp1, double tp2, double tp3,
                         int groupId, string channelName, double &tpLevels[], int tpCount);
int     GetOrderType(string signalType);
void    HandleTrailingStopsDynamic();
void    ProcessExternalSLUpdates();
bool    ParseOrderComment(string comment, int &groupId, double &signalSL);
bool    ParseOrderCommentFull(string comment, int &groupId, double &signalSL, string &channelName);
bool    ParseOrderCommentDynamic(string comment, int &groupId, double &signalSL, string &channelName, double &tpLevels[], int &tpCount);
bool    ReconstructTPLevelsFromOrders(int groupId, double &tpLevels[], int &tpCount);
int     GetHighestTriggeredTP(int groupId, double &tpLevels[], int tpCount);
bool    HasBeenModified(int ticket);
void    MarkAsModified(int ticket);
void    AddTriggeredGroup(int groupId, int tpLevel);
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
string  CleanChannelName(string channelName);
string  FormatMT4Comment(int groupId, string channelName, double stopLoss, int digits);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int init()
{
    // Initialize arrays
    ArrayInitialize(modifiedTickets, -1);
    triggeredCount   = 0;
    modifiedCount    = 0;
    lastTrailingScan = 0;
    lastProcessedGroupId = -1; // Initialize to -1 to allow first signal
    lastProcessedTime = 0;     // Initialize to 0 to allow first signal
    
    // Initialize triggered groups array
    for(int i = 0; i < MAX_GROUPS; i++) {
        triggeredGroups[i].groupId = -1;
        triggeredGroups[i].triggeredTPLevel = 0;
        triggeredGroups[i].triggerTime = 0;
    }

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
    int    groupId, tpCount;
    double tpLevels[20]; // Support up to 20 TP levels

    if(IsTradeAllowed() && IsConnected() && !IsStopped())
    {
        // Process new signal
        if(ReadSignalFile(signalType, symbol, entryPrice,
                          stopLoss, tp1, tp2, tp3, groupId, channelName, tpLevels, tpCount))
        {
            if(debugMode)
                Print(eaName, ": Processing NEW signal from channel '", channelName, "' - GID=", IntegerToString(groupId), " with ", IntegerToString(tpCount), " TP levels");
                
            // Check if orders with this GID already exist
            bool hasExistingOrders = false;
            for(int i=0; i<OrdersTotal(); i++)
            {
                if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
                {
                    if(OrderMagicNumber() == MAGIC_NUMBER)
                    {
                        int orderGid;
                        double orderSL;
                        string orderChannel;
                        if(ParseOrderCommentFull(OrderComment(), orderGid, orderSL, orderChannel))
                        {
                            if(orderGid == groupId && orderChannel == channelName)
                            {
                                hasExistingOrders = true;
                                break;
                            }
                        }
                    }
                }
            }
            
            if(hasExistingOrders)
            {
                if(debugMode)
                    Print(eaName, ": Orders with GID=", IntegerToString(groupId), " already exist, only updating SL");
                UpdateExistingOrdersSL(symbol, signalType, stopLoss, channelName);
            }
            else
            {
                if(debugMode)
                    Print(eaName, ": No existing orders found, creating new orders");
                UpdateExistingOrdersSL(symbol, signalType, stopLoss, channelName);
                SendOrders(signalType, symbol,
                                 entryPrice, stopLoss, tp1, tp2, tp3,
                                 groupId, channelName, tpLevels, tpCount);
            }
        }
        // Apply trailing stop logic
        HandleTrailingStopsDynamic();
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
                    int &groupId, string &channelName, double &tpLevels[], int &tpCount)
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

    // 4) TP levels - dynamic parsing with bounds checking
    string tpsArr[];
    tpCount = StringSplit(parts[4], ',', tpsArr);
    if(tpCount < 1) {
        Print(eaName, ": Invalid TP levels '", parts[4], "', skipping");
        return(false);
    }
    
    // Enforce maximum TP count limit (array size is 20)
    if(tpCount > 20) {
        Print(eaName, ": Warning: TP count ", IntegerToString(tpCount), " exceeds maximum 20, truncating");
        tpCount = 20;
    }
    
    // Resize array to hold all TPs (up to maximum)
    ArrayResize(tpLevels, tpCount);
    
    // Parse all TP levels
    for(int i=0; i<tpCount; i++) {
        if(!IsValidDouble(tpsArr[i])) {
            Print(eaName, ": Invalid TP level[", IntegerToString(i), "] '", tpsArr[i], "', skipping");
            return(false);
        }
        tpLevels[i] = NormalizeDouble(StrToDouble(tpsArr[i]), MarketInfo(symbol, MODE_DIGITS));
    }
    
    // Set backward compatibility values for first 3 TPs
    tp1 = tpLevels[0];
    tp2 = tpCount > 1 ? tpLevels[1] : tpLevels[0];
    tp3 = tpCount > 2 ? tpLevels[2] : tpLevels[0];
    
    // Validate TP order and remove duplicates
    bool shouldBuy = signalType == "BUY";
    for(int i=0; i<tpCount; i++) {
        // Check TP order (ascending for BUY, descending for SELL)
        if(i > 0) {
            if(shouldBuy && tpLevels[i] <= tpLevels[i-1]) {
                Print(eaName, ": Warning: TP[", IntegerToString(i), "] ", DoubleToString(tpLevels[i], MarketInfo(symbol, MODE_DIGITS)), 
                      " should be higher than TP[", IntegerToString(i-1), "] ", DoubleToString(tpLevels[i-1], MarketInfo(symbol, MODE_DIGITS)), " for BUY");
            } else if(!shouldBuy && tpLevels[i] >= tpLevels[i-1]) {
                Print(eaName, ": Warning: TP[", IntegerToString(i), "] ", DoubleToString(tpLevels[i], MarketInfo(symbol, MODE_DIGITS)), 
                      " should be lower than TP[", IntegerToString(i-1), "] ", DoubleToString(tpLevels[i-1], MarketInfo(symbol, MODE_DIGITS)), " for SELL");
            }
        }
        
        // Check TP direction relative to entry
        if(shouldBuy && tpLevels[i] <= entryPrice) {
            Print(eaName, ": Warning: TP[", IntegerToString(i), "] ", DoubleToString(tpLevels[i], MarketInfo(symbol, MODE_DIGITS)), 
                  " should be higher than entry ", DoubleToString(entryPrice, MarketInfo(symbol, MODE_DIGITS)), " for BUY");
        } else if(!shouldBuy && tpLevels[i] >= entryPrice) {
            Print(eaName, ": Warning: TP[", IntegerToString(i), "] ", DoubleToString(tpLevels[i], MarketInfo(symbol, MODE_DIGITS)), 
                  " should be lower than entry ", DoubleToString(entryPrice, MarketInfo(symbol, MODE_DIGITS)), " for SELL");
        }
    }

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
    
    // Validate SL position relative to entry price
    if(shouldBuy && stopLoss >= entryPrice) {
        Print(eaName, ": Warning: SL ", DoubleToString(stopLoss, MarketInfo(symbol, MODE_DIGITS)), 
              " should be below entry ", DoubleToString(entryPrice, MarketInfo(symbol, MODE_DIGITS)), " for BUY");
    } else if(!shouldBuy && stopLoss <= entryPrice) {
        Print(eaName, ": Warning: SL ", DoubleToString(stopLoss, MarketInfo(symbol, MODE_DIGITS)), 
              " should be above entry ", DoubleToString(entryPrice, MarketInfo(symbol, MODE_DIGITS)), " for SELL");
    }

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

    // Check if this signal was already processed to avoid duplicates
    datetime currentTime = TimeCurrent();
    if(groupId == lastProcessedGroupId && currentTime - lastProcessedTime < 60) {
        if(debugMode)
            Print(eaName, ": Signal GID=", IntegerToString(groupId), " already processed recently, skipping");
        return(false);
    }

    // 7) Channel Name (new field) - clean and truncate to 4 letters
    if(ArraySize(parts) >= 8) {
        string rawChannelName = Trim(parts[7]);
        if(StringLen(rawChannelName) == 0) rawChannelName = "UNKNOWN";
        channelName = CleanChannelName(rawChannelName);
    } else {
        channelName = "LEGC"; // For backward compatibility with old signals (4 letters)
    }

    Print(eaName, ": Parsed signal GID=", IntegerToString(groupId), " from channel '", channelName, "'");

    // Mark this signal as processed to avoid duplicates
    lastProcessedGroupId = groupId;
    lastProcessedTime = TimeCurrent();

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
                      int groupId, string channelName, double &tpLevels[], int tpCount)
{
    // NEW: Simple check for immediate entry (entry price = 0)
    if(MathAbs(entryPrice) < 0.001) {
        RefreshRates();
        double currentAsk = MarketInfo(symbol, MODE_ASK);
        double currentBid = MarketInfo(symbol, MODE_BID);
        
        // Replace 0 with current market price
        entryPrice = (signalType == "BUY") ? currentAsk : currentBid;
        
        if(debugMode) {
            Print(eaName, ": IMMEDIATE ENTRY detected - Using market price: ", 
                  DoubleToString(entryPrice, MarketInfo(symbol, MODE_DIGITS)), 
                  " for GID=", IntegerToString(groupId));
        }
    }
    
    // UNCHANGED: All existing logic continues with real entryPrice now
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

    // Always use the original stop loss from signal
    double rawSL = NormalizeDouble(stopLoss, digits);
    double fallbackSL = (shouldBuy)
                        ? price - MathAbs(entryPrice - stopLoss)
                        : price + MathAbs(stopLoss - entryPrice);
    fallbackSL = NormalizeDouble(fallbackSL, digits);

    // Apply minimum distance for SL if needed
    double minDist = MathMax(stopLevel * point, point);
    if(shouldBuy && price - fallbackSL < minDist) fallbackSL = price - minDist;
    if(!shouldBuy && fallbackSL - price < minDist) fallbackSL = price + minDist;
    fallbackSL = NormalizeDouble(fallbackSL, digits);

    // Normalize all TP levels and ensure minimum distance
    for(int j=0; j<tpCount; j++)
    {
        tpLevels[j] = NormalizeDouble(tpLevels[j], digits);
        double dist = MathAbs(tpLevels[j] - entryPrice);
        if(dist < minDist)
            tpLevels[j] = (shouldBuy) ? price + minDist : price - minDist;
        tpLevels[j] = NormalizeDouble(tpLevels[j], digits);
    }

    Print(eaName, ": Sending orders for GID=", IntegerToString(groupId),
          " from channel '", channelName, "'",
          " Using SL=", DoubleToString(rawSL, digits),
          " TP Count=", IntegerToString(tpCount));

    int slippage = 5;
    color cols[6] = { clrBlue, clrGreen, clrRed, clrYellow, clrMagenta, clrCyan };
    double lotSize = (symbol == "BTCUSD") ? fixedLotSizeBitcoin :
                        (symbol == "XAUUSD") ? fixedLotSizeGold : fixedLotSize;

    // Create orders for each TP level
    for(int k=0; k<tpCount; k++)
    {
        RefreshRates();
        string comment = FormatMT4Comment(groupId, channelName, rawSL, digits);
    
        Print(eaName, ": Order[", IntegerToString(k), "] parameters: ",
        "Symbol=", symbol,
        " Type=", IntegerToString(orderType),
        " Lots=", DoubleToString(lotSize, 2),
        " Price=", DoubleToString(price, digits),
        " SL=", DoubleToString(rawSL, digits),
        " TP=", DoubleToString(tpLevels[k], digits),
        " Comment=", comment);

        int colorIndex = k % 6; // Cycle through available colors
        datetime expiration = 0;
        if((orderType == OP_BUYLIMIT || orderType == OP_SELLLIMIT) && limitOrderExpirationSec > 0) {
            expiration = TimeCurrent() + limitOrderExpirationSec;
        }
        int ticket = OrderSend(symbol, orderType, lotSize, price, slippage,
                               rawSL, tpLevels[k], comment, MAGIC_NUMBER, expiration, cols[colorIndex]);
                                
        if(ticket < 0) {
            Print(eaName, ": Error creating order[", IntegerToString(k), "] ticket=", IntegerToString(ticket), " error=", IntegerToString(GetLastError()));
        }
        
        if(ticket < 0 && GetLastError() == ERR_INVALID_STOPS)
        {
            RefreshRates();
            // retry with fallback SL
            Print(eaName, ": Retrying with fallback SL=", DoubleToString(fallbackSL, digits));
            ticket = OrderSend(symbol, orderType, lotSize, price, slippage,
                               fallbackSL, tpLevels[k], comment, MAGIC_NUMBER, expiration, cols[colorIndex]);
        }
        
        Print(eaName, ": Order[", IntegerToString(k), "] ticket=", IntegerToString(ticket));
    }
}

//+------------------------------------------------------------------+
//| HandleTrailingStopsDynamic: Robust trailing stop logic         |
//+------------------------------------------------------------------+
//| HandleTrailingStopsDynamic: FIXED robust trailing stop logic   |
//+------------------------------------------------------------------+
void HandleTrailingStopsDynamic()
{
    datetime now = TimeCurrent();
    if(now - lastTrailingScan < trailingCheckIntervalSec) return;
    
    lastTrailingScan = now;

    if(debugMode) Print(eaName, ": TS scan starting...");

    modifiedCount = 0;
    ArrayInitialize(modifiedTickets, -1);

    // Store current triggered groups before reset to preserve existing triggers
    TriggeredGroup previousTriggered[MAX_GROUPS];
    int previousCount = triggeredCount;
    for(int i = 0; i < previousCount; i++) {
        previousTriggered[i] = triggeredGroups[i];
    }

    // Reset triggered groups array for this scan
    triggeredCount = 0;
    for(int i = 0; i < MAX_GROUPS; i++) {
        triggeredGroups[i].groupId = -1;
        triggeredGroups[i].triggeredTPLevel = 0;
        triggeredGroups[i].triggerTime = 0;
    }
    
    // Restore previous triggers that are still valid (within last 10 minutes)
    for(int i = 0; i < previousCount; i++) {
        if(now - previousTriggered[i].triggerTime <= 600) { // 10 minutes
            AddTriggeredGroup(previousTriggered[i].groupId, previousTriggered[i].triggeredTPLevel);
        }
    }
    
    // PHASE 1: Check for TP triggers by examining current market prices vs order TP levels
    int openTotal = OrdersTotal();
    if(debugMode) Print(eaName, ": TS checking ", IntegerToString(openTotal), " open orders for triggers");
    
    for(int m = 0; m < openTotal; m++)
    {
        if(!OrderSelect(m, SELECT_BY_POS, MODE_TRADES)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        
        string symbol = OrderSymbol();
        int ticket = OrderTicket();
        
        // CRITICAL FIX: Skip orders that are already closed or pending deletion
        if(OrderCloseTime() != 0) continue;
        
        RefreshRates();
        double currentPrice = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT) ? 
                             MarketInfo(symbol, MODE_BID) : MarketInfo(symbol, MODE_ASK);
        
        double orderTP = OrderTakeProfit();
        if(orderTP <= 0) continue; // Skip orders without TP
        
        // Check if TP level has been reached - CRITICAL FIX: Improved tolerance logic
        bool tpReached = false;
        bool isBuyOrder = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT);
        double tolerance = triggerTolerancePips * MarketInfo(symbol, MODE_POINT);
        
        if(isBuyOrder) {
            // For BUY orders: TP reached when current price >= TP level (no negative tolerance)
            tpReached = (currentPrice >= orderTP);
            if(debugMode && currentPrice >= orderTP - tolerance && currentPrice < orderTP) {
                Print(eaName, ": BUY order near TP but not triggered - Price: ", DoubleToString(currentPrice, MarketInfo(symbol, MODE_DIGITS)),
                      " TP: ", DoubleToString(orderTP, MarketInfo(symbol, MODE_DIGITS)), " (needs to reach or exceed TP)");
            }
        } else {
            // For SELL orders: TP reached when current price <= TP level (no positive tolerance)
            tpReached = (currentPrice <= orderTP);
            if(debugMode && currentPrice <= orderTP + tolerance && currentPrice > orderTP) {
                Print(eaName, ": SELL order near TP but not triggered - Price: ", DoubleToString(currentPrice, MarketInfo(symbol, MODE_DIGITS)),
                      " TP: ", DoubleToString(orderTP, MarketInfo(symbol, MODE_DIGITS)), " (needs to reach or go below TP)");
            }
        }
        
        if(tpReached)
        {
            int gid;
            double signalSL;
            string channelName;
            
            if(ParseOrderCommentFull(OrderComment(), gid, signalSL, channelName))
            {
                // Determine which TP level this is by reconstructing all TPs for this group
                double tpLevels[20];
                int tpCount;
                
                if(ReconstructTPLevelsFromOrders(gid, tpLevels, tpCount))
                {
                    // Find which TP level matches this order's TP
                    for(int j = 0; j < tpCount; j++)
                    {
                        if(MathAbs(orderTP - tpLevels[j]) <= tolerance)
                        {
                            int tpLevel = j + 1; // 1-indexed
                            AddTriggeredGroup(gid, tpLevel);
                            if(debugMode) Print(eaName, ": TS detected TP", IntegerToString(tpLevel), " reached for GID ", IntegerToString(gid),
                                              " Ticket: ", IntegerToString(ticket),
                                              " (Price: ", DoubleToString(currentPrice, MarketInfo(symbol, MODE_DIGITS)),
                                              ", TP: ", DoubleToString(orderTP, MarketInfo(symbol, MODE_DIGITS)), ")");
                            break;
                        }
                    }
                }
            }
        }
    }
    
    // PHASE 2: Check recently closed orders for additional triggers
    int historyTotal = OrdersHistoryTotal();
    for(int i = historyTotal - 1; i >= 0; i--)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        
        // Only check orders closed in last 10 minutes
        if(now - OrderCloseTime() > 600) continue;
        
        double orderTP = OrderTakeProfit();
        if(orderTP <= 0) continue;
        
        double closePrice = OrderClosePrice();
        double tolerance = triggerTolerancePips * MarketInfo(OrderSymbol(), MODE_POINT);
        
        // Check if order was closed at TP
        if(MathAbs(closePrice - orderTP) <= tolerance)
        {
            int gid;
            double signalSL;
            string channelName;
            
            if(ParseOrderCommentFull(OrderComment(), gid, signalSL, channelName))
            {
                double tpLevels[20];
                int tpCount;
                
                if(ReconstructTPLevelsFromOrders(gid, tpLevels, tpCount))
                {
                    for(int j = 0; j < tpCount; j++)
                    {
                        if(MathAbs(orderTP - tpLevels[j]) <= tolerance)
                        {
                            int tpLevel = j + 1;
                            AddTriggeredGroup(gid, tpLevel);
                            if(debugMode) Print(eaName, ": TS detected closed TP", IntegerToString(tpLevel), " for GID ", IntegerToString(gid));
                            break;
                        }
                    }
                }
            }
        }
    }

    if(debugMode) Print(eaName, ": TS found ", IntegerToString(triggeredCount), " triggered groups");

    // PHASE 3: Update SL for remaining open orders based on triggered TPs
    
    int totalModifications = 0;
    for(int m = 0; m < openTotal; m++)
    {
        if(!OrderSelect(m, SELECT_BY_POS, MODE_TRADES)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        
        // CRITICAL FIX: Skip orders that are already closed
        if(OrderCloseTime() != 0) continue;
        
        int ticket = OrderTicket();
        if(HasBeenModified(ticket)) {
            if(debugMode) Print(eaName, ": TS skipping ticket ", IntegerToString(ticket), " - already modified this scan");
            continue;
        }

        int gid;
        double signalSL;
        string channelName;
        
        if(!ParseOrderCommentFull(OrderComment(), gid, signalSL, channelName)) continue;

        // Check if this order belongs to any triggered group
        int triggeredTPLevel = 0;
        for(int n = 0; n < triggeredCount; n++)
        {
            if(triggeredGroups[n].groupId == gid)
            {
                triggeredTPLevel = triggeredGroups[n].triggeredTPLevel;
                break;
            }
        }
        
        if(triggeredTPLevel == 0) {
            if(debugMode) Print(eaName, ": TS no trigger for GID ", IntegerToString(gid), " ticket ", IntegerToString(ticket));
            continue; // No TP triggered for this group
        }

        // Calculate new SL based on triggered TP level
        double newSL;
        double openPrice = OrderOpenPrice();
        int digits = MarketInfo(OrderSymbol(), MODE_DIGITS);
        
        if(triggeredTPLevel == 1)
        {
            // TP1 hit: Move SL to breakeven (order open price)
            newSL = NormalizeDouble(openPrice, digits);
            if(debugMode) Print(eaName, ": TS TP1 triggered for ticket ", IntegerToString(ticket), " - moving SL to breakeven: ", DoubleToString(newSL, digits));
        }
        else if(triggeredTPLevel > 1)
        {
            // TP2+ hit: Move SL to previous TP level
            double tpLevels[20];
            int tpCount;
            
            if(ReconstructTPLevelsFromOrders(gid, tpLevels, tpCount) && triggeredTPLevel <= tpCount)
            {
                newSL = NormalizeDouble(tpLevels[triggeredTPLevel - 2], digits); // Previous TP
                if(debugMode) Print(eaName, ": TS TP", IntegerToString(triggeredTPLevel), " triggered for ticket ", IntegerToString(ticket), 
                                  " - moving SL to TP", IntegerToString(triggeredTPLevel-1), ": ", DoubleToString(newSL, digits));
            }
            else
            {
                continue; // Cannot determine correct SL
            }
        }
        else
        {
            continue; // Invalid TP level
        }
        
        // Validate SL change
        double currentSL = OrderStopLoss();
        if(MathAbs(newSL - currentSL) < SL_MODIFY_THRESHOLD) {
            if(debugMode) Print(eaName, ": TS SL change too small for ticket ", IntegerToString(ticket), 
                              " current: ", DoubleToString(currentSL, digits), " new: ", DoubleToString(newSL, digits));
            continue;
        }
        
        // Check SL direction
        bool isBuyOrder = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT);
        if(isBuyOrder) {
            // For BUY orders: new SL must be higher than current SL (or current SL is 0)
            if(currentSL > 0 && newSL <= currentSL) {
                if(debugMode) Print(eaName, ": TS invalid SL direction for BUY ticket ", IntegerToString(ticket), 
                                  " current: ", DoubleToString(currentSL, digits), " new: ", DoubleToString(newSL, digits));
                continue;
            }
        } else {
            // For SELL orders: new SL must be lower than current SL (or current SL is 0)  
            if(currentSL > 0 && newSL >= currentSL) {
                if(debugMode) Print(eaName, ": TS invalid SL direction for SELL ticket ", IntegerToString(ticket),
                                  " current: ", DoubleToString(currentSL, digits), " new: ", DoubleToString(newSL, digits));
                continue;
            }
        }
        
        // Apply broker constraints
        RefreshRates();
        double ask = MarketInfo(OrderSymbol(), MODE_ASK);
        double bid = MarketInfo(OrderSymbol(), MODE_BID);
        
        if(!CheckStopLevel(OrderSymbol(), OrderType(), newSL, ask, bid)) {
            if(debugMode) Print(eaName, ": TS SL failed broker constraints for ticket ", IntegerToString(ticket));
            continue;
        }

        // Modify the order
        if(OrderModify(ticket, openPrice, newSL, OrderTakeProfit(), 0, clrMagenta))
        {
            Print(eaName, ": ✅ TS successfully moved SL for ticket ", IntegerToString(ticket), 
                  " from ", DoubleToString(currentSL, digits), " to ", DoubleToString(newSL, digits),
                  " (TP", IntegerToString(triggeredTPLevel), " triggered for GID ", IntegerToString(gid), ")");
            MarkAsModified(ticket);
            totalModifications++;
        }
        else
        {
            Print(eaName, ": ❌ TS modify failed for ticket ", IntegerToString(ticket),
                  " error: ", IntegerToString(GetLastError()), " GID: ", IntegerToString(gid));
        }
    }
    
    if(debugMode) Print(eaName, ": TS scan complete - ", IntegerToString(totalModifications), " orders modified");
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

    // Check for old format (GID:xxxx|NEW_SL:value) and new format (xxxx|NEW_SL:value)
    int sep = StringFind(cmd, "|NEW_SL:");
    int gid;
    
    if(StringFind(cmd, "GID:") == 0 && sep > 0) {
        // Old format: GID:xxxx|NEW_SL:value
        gid = (int)StrToInteger(StringSubstr(cmd, 4, sep-4));
    } else {
        // New format: xxxx|NEW_SL:value
        if(sep > 0) {
            gid = (int)StrToInteger(StringSubstr(cmd, 0, sep));
        } else {
            Print(eaName, "Not a valid SL modify command: ", cmd);
            return;
        }
    }
    
    if(gid <= 0) {
        Print(eaName, "Invalid GID in SL modify command: ", cmd);
        return;
    }
    
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
        // Check if order belongs to the GID (handle both old and new formats)
        string orderComment = OrderComment();
        bool gidMatch = false;
        
        // Check old format: GID:xxxx|...
        if(StringFind(orderComment, "GID:" + IntegerToString(gid)) >= 0) {
            gidMatch = true;
        }
        // Check new format: xxxx|...
        else if(StringFind(orderComment, IntegerToString(gid) + "|") == 0) {
            gidMatch = true;
        }
        
        if(!gidMatch) {
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
    // New format: 1234|ABCD|1.2345 (ABCD is 4-letter channel code, no GID: and SL: prefixes)
    // Old format: GID:1234|SL:1.2345 (for backward compatibility)
    
    // Check if it's the old format with GID: prefix
    if(StringFind(comment, "GID:") == 0) {
        // Old format handling
        int p1 = StringFind(comment, "GID:");
        if(p1 != 0) {
            if(debugMode) Print(eaName, ": Invalid old comment format, no GID found: ", comment);
            return(false);
        }
        
        // Find first pipe after GID
        int firstPipe = StringFind(comment, "|", 4);
        if(firstPipe < 0) {
            if(debugMode) Print(eaName, ": Invalid old comment format, no pipe separator found: ", comment);
            return(false);
        }
        
        // Extract GID
        groupId = StrToInteger(StringSubstr(comment, 4, firstPipe-4));
        if(groupId <= 0) {
            if(debugMode) Print(eaName, ": Invalid GID in old comment: ", comment);
            return(false);
        }
        
        // Look for SL: either immediately after first pipe (old format) or after second pipe (old new format)
        if(StringSubstr(comment, firstPipe, 4) == "|SL:") {
            // Direct old format: GID:xxxx|SL:yyyy (SL immediately after first pipe)
            channelName = "LEGC"; // Old format default
            // Extract SL value directly from first pipe + 4
            signalSL = StrToDouble(StringSubstr(comment, firstPipe + 4));
        } else {
            // Look for |SL: after first pipe (old new format: GID:xxxx|CHAN|SL:yyyy)
            int slPos = StringFind(comment, "|SL:", firstPipe + 1);
            if(slPos < 0) {
                if(debugMode) Print(eaName, ": No SL found in old comment: ", comment);
                return(false);
            }
            
            // Extract channel name (between first pipe and |SL:)
            if(slPos > firstPipe + 1) {
                channelName = StringSubstr(comment, firstPipe+1, slPos-firstPipe-1);
            } else {
                channelName = "UNKN";
            }
            
            // Extract SL value
            signalSL = StrToDouble(StringSubstr(comment, slPos + 4));
        }
        
        if(debugMode) {
            Print(eaName, ": Parsed old comment - GID:", IntegerToString(groupId), " Channel:", channelName, " SL:", DoubleToString(signalSL, 5));
        }
        
        return(true);
    }
    
    // New format: 1234|ABCD|1.2345
    int firstPipe = StringFind(comment, "|");
    if(firstPipe < 0) {
        if(debugMode) Print(eaName, ": Invalid new comment format, no first pipe found: ", comment);
        return(false);
    }
    
    int secondPipe = StringFind(comment, "|", firstPipe + 1);
    if(secondPipe < 0) {
        if(debugMode) Print(eaName, ": Invalid new comment format, no second pipe found: ", comment);
        return(false);
    }
    
    // Extract GID (first part)
    groupId = StrToInteger(StringSubstr(comment, 0, firstPipe));
    if(groupId <= 0) {
        if(debugMode) Print(eaName, ": Invalid GID in new comment: ", comment);
        return(false);
    }
    
    // Extract channel name (second part, should be 4 letters)
    channelName = StringSubstr(comment, firstPipe + 1, secondPipe - firstPipe - 1);
    if(StringLen(channelName) != 4) {
        if(debugMode) Print(eaName, ": Invalid channel name length in new comment: ", comment);
        channelName = "UNKN"; // Fallback
    }
    
    // Extract SL value (third part)
    signalSL = StrToDouble(StringSubstr(comment, secondPipe + 1));
    
    if(debugMode) {
        Print(eaName, ": Parsed new comment - GID:", IntegerToString(groupId), " Channel:", channelName, " SL:", DoubleToString(signalSL, 5));
    }
    
    return(true);
}

//+------------------------------------------------------------------+
//| ParseOrderCommentDynamic: Enhanced parser with TP level support|
//+------------------------------------------------------------------+
bool ParseOrderCommentDynamic(string comment, int &groupId, double &signalSL, 
                             string &channelName, double &tpLevels[], int &tpCount)
{
    // This function attempts to parse both old and new formats
    // Since current comment format only has GID|CHANNEL|SL, we cannot parse TP levels directly
    // Return false to force fallback to ReconstructTPLevelsFromOrders
    
    // We could implement extended comment format in future:
    // GID|CHANNEL|SL|TP1,TP2,TP3 - but this would exceed 31 character limit
    
    tpCount = 0;
    return false; // Force fallback to ReconstructTPLevelsFromOrders
}

//+------------------------------------------------------------------+
//| ReconstructTPLevelsFromOrders: Rebuild TP array from orders    |
//+------------------------------------------------------------------+
bool ReconstructTPLevelsFromOrders(int groupId, double &tpLevels[], int &tpCount)
{
    tpCount = 0;
    double tempTPs[20];
    int tempCount = 0;
    
    if(debugMode) Print(eaName, ": Reconstructing TP levels for GID ", IntegerToString(groupId));
    
    // Scan all orders (both open and closed) for this group
    int totalOrders = OrdersTotal();
    for(int i = 0; i < totalOrders; i++)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        
        int orderGid;
        double orderSL;
        string orderChannel;
        if(!ParseOrderCommentFull(OrderComment(), orderGid, orderSL, orderChannel)) continue;
        if(orderGid != groupId) continue;
        
        double tp = OrderTakeProfit();
        if(tp > 0)
        {
            // Check if this TP is already in our array
            bool found = false;
            for(int j = 0; j < tempCount; j++)
            {
                if(MathAbs(tempTPs[j] - tp) < 0.00001)
                {
                    found = true;
                    break;
                }
            }
            
            if(!found && tempCount < 20)
            {
                tempTPs[tempCount++] = tp;
            }
        }
    }
    
    // Also check closed orders
    int historyTotal = OrdersHistoryTotal();
    for(int i = 0; i < historyTotal; i++)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        
        int orderGid;
        double orderSL;
        string orderChannel;
        if(!ParseOrderCommentFull(OrderComment(), orderGid, orderSL, orderChannel)) continue;
        if(orderGid != groupId) continue;
        
        double tp = OrderTakeProfit();
        if(tp > 0)
        {
            // Check if this TP is already in our array
            bool found = false;
            for(int j = 0; j < tempCount; j++)
            {
                if(MathAbs(tempTPs[j] - tp) < 0.00001)
                {
                    found = true;
                    break;
                }
            }
            
            if(!found && tempCount < 20)
            {
                tempTPs[tempCount++] = tp;
            }
        }
    }
    
    if(tempCount == 0)
    {
        if(debugMode) Print(eaName, ": No TP levels found for GID ", IntegerToString(groupId));
        return false;
    }
    
    // Sort TP levels (ascending for BUY, descending for SELL)
    // We need to determine order type first
    bool isBuyOrder = true;
    for(int i = 0; i < OrdersTotal(); i++)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        
        int orderGid;
        double orderSL;
        string orderChannel;
        if(!ParseOrderCommentFull(OrderComment(), orderGid, orderSL, orderChannel)) continue;
        if(orderGid != groupId) continue;
        
        isBuyOrder = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT);
        break;
    }
    
    // Simple bubble sort
    for(int i = 0; i < tempCount - 1; i++)
    {
        for(int j = 0; j < tempCount - i - 1; j++)
        {
            bool shouldSwap = isBuyOrder ? (tempTPs[j] > tempTPs[j + 1]) : (tempTPs[j] < tempTPs[j + 1]);
            if(shouldSwap)
            {
                double temp = tempTPs[j];
                tempTPs[j] = tempTPs[j + 1];
                tempTPs[j + 1] = temp;
            }
        }
    }
    
    // Copy sorted TPs to output array
    ArrayResize(tpLevels, tempCount);
    for(int i = 0; i < tempCount; i++)
    {
        tpLevels[i] = tempTPs[i];
    }
    tpCount = tempCount;
    
    if(debugMode)
    {
        string tpStr = "";
        for(int i = 0; i < tpCount; i++)
        {
            tpStr += DoubleToString(tpLevels[i], 5);
            if(i < tpCount - 1) tpStr += ", ";
        }
        Print(eaName, ": Reconstructed ", IntegerToString(tpCount), " TP levels for GID ", IntegerToString(groupId), ": ", tpStr);
    }
    
    return tpCount > 0;
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
//| AddTriggeredGroup: add groupId and TP level if not present      |
//+------------------------------------------------------------------+
void AddTriggeredGroup(int groupId, int tpLevel)
{
    if(groupId <= 0 || tpLevel <= 0) {
        if(debugMode) Print(eaName, ": Invalid groupId or tpLevel: ", IntegerToString(groupId), "/", IntegerToString(tpLevel));
        return;
    }
    
    // Check if group already exists and update with higher TP level
    for(int i = 0; i < triggeredCount; i++)
    {
        if(triggeredGroups[i].groupId == groupId)
        {
            // Update to higher TP level if applicable
            if(tpLevel > triggeredGroups[i].triggeredTPLevel)
            {
                triggeredGroups[i].triggeredTPLevel = tpLevel;
                triggeredGroups[i].triggerTime = TimeCurrent();
                if(debugMode) Print(eaName, ": Updated triggered group ", IntegerToString(groupId), " from TP", 
                                  IntegerToString(triggeredGroups[i].triggeredTPLevel), " to TP", IntegerToString(tpLevel));
            }
            else if(debugMode) {
                Print(eaName, ": Group ", IntegerToString(groupId), " already has TP", 
                      IntegerToString(triggeredGroups[i].triggeredTPLevel), " (ignoring TP", IntegerToString(tpLevel), ")");
            }
            return;
        }
    }
    
    // Add new triggered group
    if(triggeredCount < MAX_GROUPS)
    {
        triggeredGroups[triggeredCount].groupId = groupId;
        triggeredGroups[triggeredCount].triggeredTPLevel = tpLevel;
        triggeredGroups[triggeredCount].triggerTime = TimeCurrent();
        triggeredCount++;
        if(debugMode) Print(eaName, ": Added new triggered group ", IntegerToString(groupId), " with TP", IntegerToString(tpLevel));
    }
    else
    {
        Print(eaName, ": WARNING: Cannot add triggered group ", IntegerToString(groupId), " - array full!");
    }
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
//| CleanChannelName: Clean and truncate channel name to match Python|
//+------------------------------------------------------------------+
string CleanChannelName(string channelName)
{
    // This function matches the simplified Python clean_channel_name logic
    // for perfect compatibility between Python-generated and MT4-parsed comments
    
    string result = "";
    int length = StringLen(channelName);
    
    // Handle empty input
    if(length == 0) return "UNKN";
    
    // Convert to uppercase and extract only alphabetic characters
    string alphaOnly = "";
    for(int i = 0; i < length; i++)
    {
        int c = StringGetCharacter(channelName, i);
        if(c >= 'A' && c <= 'Z') alphaOnly += CharToStr(c);
        else if(c >= 'a' && c <= 'z') alphaOnly += CharToStr(c - 32); // Convert to uppercase
    }
    
    // Simple truncation/padding logic to match Python exactly
    if(StringLen(alphaOnly) > 0) {
        if(StringLen(alphaOnly) <= 4) {
            result = alphaOnly;
            // Pad with 'X' if needed
            while(StringLen(result) < 4) {
                result += "X";
            }
        } else {
            // Simple truncation for long names - take first 4 characters
            result = StringSubstr(alphaOnly, 0, 4);
        }
    } else {
        result = "UNKN";
    }
    
    return StringSubstr(result, 0, 4);
}

//+------------------------------------------------------------------+
//| FormatMT4Comment: Format comment string within 31 char limit    |
//| New format: 1234|ABCD|1.2345 (saves 7 chars vs old GID:xxx|SL:)|
//+------------------------------------------------------------------+
string FormatMT4Comment(int groupId, string channelName, double stopLoss, int digits)
{
    // Format: 1234|ABCD|1.2345 (saves 7 chars vs old GID:xxx|SL: format)
    string cleanChannel = CleanChannelName(channelName);
    
    // Format SL with reduced precision to save space
    string slStr = DoubleToString(stopLoss, MathMin(digits, 4));
    
    // Remove trailing zeros from SL string to save space
    while(StringLen(slStr) > 1 && StringGetCharacter(slStr, StringLen(slStr)-1) == '0')
    {
        slStr = StringSubstr(slStr, 0, StringLen(slStr)-1);
    }
    if(StringGetCharacter(slStr, StringLen(slStr)-1) == '.')
    {
        slStr = StringSubstr(slStr, 0, StringLen(slStr)-1);
    }
    
    // Build the comment: GID|CHANNEL|SL
    string comment = IntegerToString(groupId) + "|" + cleanChannel + "|" + slStr;
    
    // Ensure comment fits within MT4's 31-character limit
    if(StringLen(comment) > 31)
    {
        // If too long, truncate SL precision
        int maxSLLen = 31 - StringLen(IntegerToString(groupId)) - StringLen(cleanChannel) - 2; // -2 for pipes
        if(maxSLLen > 0)
        {
            slStr = StringSubstr(slStr, 0, maxSLLen);
            comment = IntegerToString(groupId) + "|" + cleanChannel + "|" + slStr;
        }
    }
    
    return comment;
}

//+------------------------------------------------------------------+
//| GetHighestTriggeredTP: Find highest triggered TP for a group   |
//+------------------------------------------------------------------+
int GetHighestTriggeredTP(int groupId, double &tpLevels[], int tpCount)
{
    int highestTP = 0;
    
    // Check triggered groups array first
    for(int i = 0; i < triggeredCount; i++)
    {
        if(triggeredGroups[i].groupId == groupId)
        {
            highestTP = MathMax(highestTP, triggeredGroups[i].triggeredTPLevel);
        }
    }
    
    // If no triggered TP found in current scan, check recent history
    if(highestTP == 0)
    {
        datetime now = TimeCurrent();
        for(int i = 0; i < OrdersHistoryTotal(); i++)
        {
            if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
            
            if(OrderMagicNumber() != MAGIC_NUMBER) continue;
            if(OrderCloseTime() == 0) continue; // Skip if not closed
            if(now - OrderCloseTime() > 3600) continue; // Only check last hour
            
            int orderGroupId;
            double signalSL;
            string channelName;
            
            if(!ParseOrderCommentFull(OrderComment(), orderGroupId, signalSL, channelName))
                continue;
                
            if(orderGroupId != groupId) continue;
            
            // Check if this order was closed at TP
            double orderTP = OrderTakeProfit();
            double closePrice = OrderClosePrice();
            double tolerance = triggerTolerancePips * MarketInfo(OrderSymbol(), MODE_POINT);
            
            if(orderTP > 0 && MathAbs(closePrice - orderTP) <= tolerance)
            {
                // Find which TP level this corresponds to
                for(int j = 0; j < tpCount; j++)
                {
                    if(MathAbs(orderTP - tpLevels[j]) <= tolerance)
                    {
                        int triggeredTP = j + 1; // TP levels are 1-indexed
                        highestTP = MathMax(highestTP, triggeredTP);
                        
                        // Add to triggered groups for current scan
                        AddTriggeredGroup(groupId, triggeredTP);
                        break;
                    }
                }
            }
        }
    }
    
    return highestTP;
}
