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
//|--- Anti-Whipsaw Protection Structure                           |
//+------------------------------------------------------------------+
struct PendingTrailingStop {
    int ticket;             // Order ticket
    int groupId;           // Group ID
    int triggeredTPLevel;   // Which TP was triggered
    double calculatedSL;    // Calculated new SL
    datetime triggerTime;   // When trigger was detected
    datetime executeTime;   // When to execute (triggerTime + delay)
    double triggerPrice;    // Price when trigger was detected
    bool isPending;         // If this is waiting
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
int      signalFileHandle = -1;        // File handle for reading signals
int      externalSLHandle = -1;        // File handle for external SL updates
string   nextSignal = "";
int      lastProcessedGroupId = -1; // Track last processed signal to avoid duplicates
datetime lastProcessedTime = 0;     // Track last processed time for additional safety

// Anti-Whipsaw Protection Variables
PendingTrailingStop pendingStops[100];
int pendingStopCount = 0;
int antiWhipsawDelaySeconds = 300;        // 5 perc várakozás
double minSLDistancePips_BTC = 100.0;     // BTC minimum távolság (pips)
double minSLDistancePips_GOLD = 50.0;     // XAU minimum távolság (pips) 
double minSLDistancePips_FOREX = 20.0;    // Forex minimum távolság (pips)
double minSLDistancePips_CRYPTO = 80.0;   // Egyéb crypto minimum távolság (pips)


//+------------------------------------------------------------------+
//|--- Function Prototypes                                          |
//+------------------------------------------------------------------+
void    PrintLog(string message);
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

// Anti-Whipsaw Protection Functions
double  GetMinimumSLDistance(string symbol);
bool    CheckIfSLTooClose(string symbol, double newSL, double currentPrice, bool isBuyOrder);
void    AddPendingTrailingStop(int ticket, int groupId, int triggeredTPLevel, double calculatedSL, double currentPrice);
void    ProcessPendingTrailingStops();
int     CountActivePendingStops();
void    ShowPendingStopsStatus();

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

    // Initialize pending trailing stops array
    for(int i = 0; i < 100; i++) {
        pendingStops[i].ticket = -1;
        pendingStops[i].groupId = -1;
        pendingStops[i].triggeredTPLevel = 0;
        pendingStops[i].calculatedSL = 0.0;
        pendingStops[i].triggerTime = 0;
        pendingStops[i].executeTime = 0;
        pendingStops[i].triggerPrice = 0.0;
        pendingStops[i].isPending = false;
    }
    pendingStopCount = 0;

    // Use chart's expert name if provided
    string customName = WindowExpertName();
    if(StringLen(customName) > 0)
        eaName = customName;

    if(debugMode)
        PrintLog(eaName + ": Initialized");

    return(0);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
int deinit()
{
    // CRITICAL FIX: Close any open file handles to prevent memory leaks
    if(signalFileHandle != -1) {
        FileClose(signalFileHandle);
        signalFileHandle = -1;
    }
    
    if(externalSLHandle != -1) {
        FileClose(externalSLHandle);
        externalSLHandle = -1;
    }
    
    if(debugMode)
        PrintLog(eaName + ": Deinitialized - file handles closed");
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
        // ANTI-WHIPSAW: Process pending trailing stops first
        ProcessPendingTrailingStops();
        
        // Process new signal
        if(ReadSignalFile(signalType, symbol, entryPrice,
                          stopLoss, tp1, tp2, tp3, groupId, channelName, tpLevels, tpCount))
        {
            if(debugMode)
                PrintLog(eaName + ": Processing NEW signal from channel '" + channelName + "' - GID=" + IntegerToString(groupId) + " with " + IntegerToString(tpCount) + " TP levels");
                
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
                    PrintLog(eaName + ": Orders with GID=" + IntegerToString(groupId) + " already exist, only updating SL");
                UpdateExistingOrdersSL(symbol, signalType, stopLoss, channelName);
            }
            else
            {
                if(debugMode)
                    PrintLog(eaName + ": No existing orders found, creating new orders");
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
      if(signalFileHandle == -1) 
      {
          if(!FileExists(gSignalFile)) return(false);
          signalFileHandle = FileOpen(gSignalFile, FILE_READ|FILE_SHARE_READ | FILE_TXT | FILE_ANSI);
          PrintLog(eaName + ": Opening signal file " + gSignalFile);
          if(signalFileHandle == INVALID_HANDLE) {
              PrintLog(eaName + ": Failed to open signal file");
              return(false);
          }
      }

      if(signalFileHandle == INVALID_HANDLE)
      {
          PrintLog(eaName + ": Failed to open signal file for reading");
          return(false);
      }
      if(IsTesting() && FileIsEnding(signalFileHandle))
      {
          FileClose(signalFileHandle);
          signalFileHandle = -1;
          return(false);
      }
      line = FileReadString(signalFileHandle);
      if(debugMode)
      {
          PrintLog(eaName + ": Read signal line: [" + line + "]");
      }
      if(!IsTesting())
      {
          FileClose(signalFileHandle);
          signalFileHandle = -1;
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
        PrintLog(eaName + ": Invalid signal format, expected 8 parts but got " + IntegerToString(ArraySize(parts)));
        return(false);
    }

    // 0) Extract and validate timestamp (first part, no prefix)
    string timestampStr = parts[0];
    long signalTimestamp = StrToInteger(timestampStr);
    
    if(IsSignalTooOld(signalTimestamp))
    {
      if (!IsTesting())
        {
            PrintLog(eaName + ": Signal too old, skipping. Timestamp=" + IntegerToString(signalTimestamp));
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
        PrintLog(eaName + ": Invalid signal type '" + signalType + "', expected BUY or SELL");
        return(false);
    }

    // 2) Symbol validation
    symbol = Trim(parts[2]) + symbolPostfix;
    if(MarketInfo(symbol, MODE_TIME) == 0) {
        PrintLog(eaName + ": Invalid symbol '" + symbol + "', skipping");
        return(false);
    }

    // 3) Entry price
    if(!IsValidDouble(parts[3])) {
        PrintLog(eaName + ": Invalid entry price '" + parts[3] + "', skipping");
        return(false);
    }
    entryPrice = NormalizeDouble(StrToDouble(parts[3]), MarketInfo(symbol, MODE_DIGITS));

    // 4) TP levels - dynamic parsing with bounds checking
    string tpsArr[];
    tpCount = StringSplit(parts[4], ',', tpsArr);
    if(tpCount < 1) {
        PrintLog(eaName + ": Invalid TP levels '" + parts[4] + "', skipping");
        return(false);
    }
    
    // Enforce maximum TP count limit (array size is 20)
    if(tpCount > 20) {
        PrintLog(eaName + ": Warning: TP count " + IntegerToString(tpCount) + " exceeds maximum 20, truncating");
        tpCount = 20;
    }
    
    // Resize array to hold all TPs (up to maximum)
    ArrayResize(tpLevels, tpCount);
    
    // Parse all TP levels
    for(int i=0; i<tpCount; i++) {
        if(!IsValidDouble(tpsArr[i])) {
            PrintLog(eaName + ": Invalid TP level[" + IntegerToString(i) + "] '" + tpsArr[i] + "', skipping");
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
                PrintLog(eaName + ": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(tpLevels[i], MarketInfo(symbol, MODE_DIGITS)) + 
                      " should be higher than TP[" + IntegerToString(i-1) + "] " + DoubleToString(tpLevels[i-1], MarketInfo(symbol, MODE_DIGITS)) + " for BUY");
            } else if(!shouldBuy && tpLevels[i] >= tpLevels[i-1]) {
                PrintLog(eaName + ": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(tpLevels[i], MarketInfo(symbol, MODE_DIGITS)) + 
                      " should be lower than TP[" + IntegerToString(i-1) + "] " + DoubleToString(tpLevels[i-1], MarketInfo(symbol, MODE_DIGITS)) + " for SELL");
            }
        }
        
        // Check TP direction relative to entry
        if(shouldBuy && tpLevels[i] <= entryPrice) {
            PrintLog(eaName + ": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(tpLevels[i], MarketInfo(symbol, MODE_DIGITS)) + 
                  " should be higher than entry " + DoubleToString(entryPrice, MarketInfo(symbol, MODE_DIGITS)) + " for BUY");
        } else if(!shouldBuy && tpLevels[i] >= entryPrice) {
            PrintLog(eaName + ": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(tpLevels[i], MarketInfo(symbol, MODE_DIGITS)) + 
                  " should be lower than entry " + DoubleToString(entryPrice, MarketInfo(symbol, MODE_DIGITS)) + " for SELL");
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
        PrintLog(eaName + ": Invalid stop loss '" + rawSL + "', skipping");
        return(false);
    }
    stopLoss = NormalizeDouble(StrToDouble(rawSL), MarketInfo(symbol, MODE_DIGITS));
    
    // Validate SL position relative to entry price
    if(shouldBuy && stopLoss >= entryPrice) {
        PrintLog(eaName + ": Warning: SL " + DoubleToString(stopLoss, MarketInfo(symbol, MODE_DIGITS)) + 
              " should be below entry " + DoubleToString(entryPrice, MarketInfo(symbol, MODE_DIGITS)) + " for BUY");
    } else if(!shouldBuy && stopLoss <= entryPrice) {
        PrintLog(eaName + ": Warning: SL " + DoubleToString(stopLoss, MarketInfo(symbol, MODE_DIGITS)) + 
              " should be above entry " + DoubleToString(entryPrice, MarketInfo(symbol, MODE_DIGITS)) + " for SELL");
    }

    // 6) Group ID
    string gidPart = parts[6];
    if(StringFind(gidPart, "GID:") != 0) {
        PrintLog(eaName + ": Invalid group ID format '" + gidPart + "', skipping");
        return(false);
    }
    groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
    if(groupId <= 0) {
        PrintLog(eaName + ": Invalid group ID '" + IntegerToString(groupId) + "', skipping");
        return(false);
    }

    // Check if this signal was already processed to avoid duplicates
    datetime currentTime = TimeCurrent();
    if(groupId == lastProcessedGroupId && currentTime - lastProcessedTime < 60) {
        if(debugMode)
            PrintLog(eaName + ": Signal GID=" + IntegerToString(groupId) + " already processed recently, skipping");
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

    PrintLog(eaName + ": Parsed signal GID=" + IntegerToString(groupId) + " from channel '" + channelName + "'");

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
    // Skip XAUUSD (Gold) trades to avoid interfering with independent trades from same group
    if(StringFind(ToUpperCase(symbol), "XAUUSD") >= 0 || StringFind(ToUpperCase(symbol), "GOLD") >= 0)
    {
        if(debugMode) PrintLog(eaName + ": Skipping UpdateExistingOrdersSL for Gold symbol: " + symbol + 
                              " - avoiding interference with independent trades");
        return;
    }
    
    int targetOrderType = (signalType == "BUY") ? OP_BUY : OP_SELL;
    
    for(int i=0; i<OrdersTotal(); i++)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
          if (debugMode) PrintLog(eaName + ": Failed to select order at index " + IntegerToString(i) + " - error=" + IntegerToString(GetLastError()));
          continue;
        }
        if(OrderMagicNumber() != MAGIC_NUMBER) {
          if (debugMode) PrintLog(eaName + ": Ignoring order at index " + IntegerToString(i) + " - wrong magic number");
          continue;
        }
        if(OrderSymbol() != symbol || OrderType() != targetOrderType) {
          if (debugMode) PrintLog(eaName + ": Ignoring order at index " + IntegerToString(i) + " - symbol/type mismatch");
          continue;
        }

        // Parse the order's comment to get channel information
        int orderGid;
        double orderSL;
        string orderChannelName;
        if(!ParseOrderCommentFull(OrderComment(), orderGid, orderSL, orderChannelName)) {
            if (debugMode) PrintLog(eaName + ": Failed to parse order comment for ticket " + IntegerToString(OrderTicket()) + ": " + OrderComment());
            continue;
        }

        // Only update SL if the order is from the same channel
        if(orderChannelName != channelName) {
            if (debugMode) PrintLog(eaName + ": Ignoring order ticket " + IntegerToString(OrderTicket()) + 
                                " - different channel (order='" + orderChannelName + "', signal='" + channelName + "')");
            continue;
        }

        double currSL = OrderStopLoss();
        if(MathAbs(currSL - newSL) > SL_MODIFY_THRESHOLD)
        {
            double openP = OrderOpenPrice();
            double tp    = OrderTakeProfit();
            bool ok = OrderModify(OrderTicket(), openP, newSL, tp, 0, clrBlue);
            if(ok)
                PrintLog(eaName + ": Updated SL for ticket=" + IntegerToString(OrderTicket()) + 
                      " from channel '" + channelName + "' (" + DoubleToString(currSL, MarketInfo(symbol, MODE_DIGITS)) + 
                      " -> " + DoubleToString(newSL, MarketInfo(symbol, MODE_DIGITS)) + ")");
            else
                PrintLog(eaName + ": SL update failed ticket=" + IntegerToString(OrderTicket()) +
                      " err=" + IntegerToString(GetLastError()));
        } else {
            if (debugMode) PrintLog(eaName + ": SL change too small for ticket " + IntegerToString(OrderTicket()) + 
                                " - current=" + DoubleToString(currSL, MarketInfo(symbol, MODE_DIGITS)) + 
                                " new=" + DoubleToString(newSL, MarketInfo(symbol, MODE_DIGITS)));
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
    // Simple check for immediate entry (entry price = 0)
    if(entryPrice == 0.0) {
        RefreshRates();
        double currentAsk = MarketInfo(symbol, MODE_ASK);
        double currentBid = MarketInfo(symbol, MODE_BID);
        
        // Replace 0 with current market price
        entryPrice = (signalType == "BUY") ? currentAsk : currentBid;
        
        if(debugMode) {
            PrintLog(eaName + ": IMMEDIATE ENTRY detected - Using market price: " + 
                  DoubleToString(entryPrice, MarketInfo(symbol, MODE_DIGITS)) + 
                  " for GID=" + IntegerToString(groupId));
        }
    }
    
    int digits    = MarketInfo(symbol, MODE_DIGITS);
    double point  = MarketInfo(symbol, MODE_POINT);
    int stopLevel = MarketInfo(symbol, MODE_STOPLEVEL);

    RefreshRates();
    double ask = MarketInfo(symbol, MODE_ASK);
    double bid = MarketInfo(symbol, MODE_BID);
    double price;
    bool shouldBuy = signalType == "BUY";
    double midPrice = (entryPrice + tp1) / 2.0; // Midpoint for limit order logic
    
    // CRITICAL FIX: Correct limit order logic
    // Use limit orders only when current price is beyond entry point (favorable for us)
    // For BUY: Use BUYLIMIT when current ask > entryPrice (we can buy cheaper)
    // For SELL: Use SELLLIMIT when current bid < entryPrice (we can sell higher)
    bool shouldUseLimitOrders = useLimitOrders && 
                               (shouldBuy ? ask > entryPrice : bid < entryPrice);

    int orderType;
    if(shouldUseLimitOrders) {
        price = entryPrice; // Use exact entry price for limit orders
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
        if(dist < minDist) {
            // CRITICAL FIX: Use entryPrice as reference, not price
            tpLevels[j] = (shouldBuy) ? entryPrice + minDist : entryPrice - minDist;
        }
        tpLevels[j] = NormalizeDouble(tpLevels[j], digits);
    }

    PrintLog(eaName + ": Sending orders for GID=" + IntegerToString(groupId) +
          " from channel '" + channelName + "'" +
          " Using SL=" + DoubleToString(rawSL, digits) +
          " TP Count=" + IntegerToString(tpCount));

    int slippage = 20;
    color cols[6] = { clrBlue, clrGreen, clrRed, clrYellow, clrMagenta, clrCyan };
    double lotSize = (symbol == "BTCUSD") ? fixedLotSizeBitcoin :
                        (symbol == "XAUUSD") ? fixedLotSizeGold : fixedLotSize;

    // Create orders for each TP level
    for(int k=0; k<tpCount; k++)
    {
        // CRITICAL FIX: For market orders, refresh rates; for limit orders, keep original price
        double finalPrice = price; // Use the price determined earlier (limit or market)
        
        if(orderType == OP_BUY || orderType == OP_SELL) {
            // Market orders: refresh rates for accurate execution
            RefreshRates();
            ask = MarketInfo(symbol, MODE_ASK);
            bid = MarketInfo(symbol, MODE_BID);
            finalPrice = (shouldBuy) ? ask : bid;
        }
        // For limit orders (OP_BUYLIMIT/OP_SELLLIMIT): keep the original calculated price
        
        finalPrice = NormalizeDouble(finalPrice, digits);
        string comment = FormatMT4Comment(groupId, channelName, rawSL, digits);
    
        PrintLog(eaName + ": Order[" + IntegerToString(k) + "] parameters: " +
        "Symbol=" + symbol +
        " Type=" + IntegerToString(orderType) +
        " Lots=" + DoubleToString(lotSize, 2) +
        " Price=" + DoubleToString(finalPrice, digits) +
        " SL=" + DoubleToString(rawSL, digits) +
        " TP=" + DoubleToString(tpLevels[k], digits) +
        " Comment=" + comment);

        int colorIndex = k % 6; // Cycle through available colors
        datetime expiration = 0;
        if((orderType == OP_BUYLIMIT || orderType == OP_SELLLIMIT) && limitOrderExpirationSec > 0) {
            expiration = TimeCurrent() + limitOrderExpirationSec;
        }
        int ticket = OrderSend(symbol, orderType, lotSize, finalPrice, slippage,
                               rawSL, tpLevels[k], comment, MAGIC_NUMBER, expiration, cols[colorIndex]);
                                
        if(ticket < 0) {
            PrintLog(eaName + ": Error creating order[" + IntegerToString(k) + "] ticket=" + IntegerToString(ticket) + " error=" + IntegerToString(GetLastError()));
        }
        
        if(ticket < 0 && GetLastError() == ERR_INVALID_STOPS)
        {
            RefreshRates();
            PrintLog(eaName + ": Retrying with fallback SL=" + DoubleToString(fallbackSL, digits));
            ticket = OrderSend(symbol, orderType, lotSize, finalPrice, slippage,
                               fallbackSL, tpLevels[k], comment, MAGIC_NUMBER, expiration, cols[colorIndex]);
        }
        
        PrintLog(eaName + ": Order[" + IntegerToString(k) + "] ticket=" + IntegerToString(ticket));
    }
}

//+------------------------------------------------------------------+
//| HandleTrailingStopsDynamic: Robust trailing stop logic         |
//+------------------------------------------------------------------+
void HandleTrailingStopsDynamic()
{
    datetime now = TimeCurrent();
    if(now - lastTrailingScan < trailingCheckIntervalSec) return;
    
    lastTrailingScan = now;

    if(debugMode) PrintLog(eaName + ": TS scan starting...");

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
    
    // PERFORMANCE FIX: Pre-calculate TP levels for all unique groups ONCE
    int uniqueGroups[MAX_GROUPS];
    double allTPLevels[MAX_GROUPS][20]; // [group_index][tp_index]
    int allTPCounts[MAX_GROUPS];
    bool allIsBuyOrder[MAX_GROUPS];
    int uniqueGroupCount = 0;
    
    // PHASE 1: Collect all unique group IDs and their TP levels
    int openTotal = OrdersTotal();
    if(debugMode) PrintLog(eaName + ": TS checking " + IntegerToString(openTotal) + " open orders for triggers");
    
    for(int m = 0; m < openTotal; m++)
    {
        if(!OrderSelect(m, SELECT_BY_POS, MODE_TRADES)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        if(OrderCloseTime() != 0) continue; // Skip closed orders
        
        int gid;
        double signalSL;
        string channelName;
        if(!ParseOrderCommentFull(OrderComment(), gid, signalSL, channelName)) continue;
        
        // Check if this group is already processed
        bool groupFound = false;
        int groupIndex = -1;
        for(int g = 0; g < uniqueGroupCount; g++) {
            if(uniqueGroups[g] == gid) {
                groupFound = true;
                groupIndex = g;
                break;
            }
        }
        
        // If new group, add it and calculate TP levels
        if(!groupFound && uniqueGroupCount < MAX_GROUPS) {
            groupIndex = uniqueGroupCount;
            uniqueGroups[groupIndex] = gid;
            
            // Calculate TP levels for this group ONCE
            double tempTPLevels[20];
            int tempTPCount;
            if(ReconstructTPLevelsFromOrders(gid, tempTPLevels, tempTPCount) && tempTPCount > 0) {
                allTPCounts[groupIndex] = tempTPCount;
                allIsBuyOrder[groupIndex] = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT);
                
                // Copy TP levels
                for(int tp = 0; tp < tempTPCount; tp++) {
                    allTPLevels[groupIndex][tp] = tempTPLevels[tp];
                }
                uniqueGroupCount++;
                
                if(debugMode) PrintLog(eaName + ": Pre-calculated " + IntegerToString(tempTPCount) + " TP levels for GID " + IntegerToString(gid));
            }
        }
    }
    
    // PHASE 2: Check TP triggers using pre-calculated data
    for(int m = 0; m < openTotal; m++)
    {
        if(!OrderSelect(m, SELECT_BY_POS, MODE_TRADES)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        if(OrderCloseTime() != 0) continue;
        
        string symbol = OrderSymbol();
        int ticket = OrderTicket();
        
        RefreshRates();
        double currentPrice = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT) ? 
                             MarketInfo(symbol, MODE_BID) : MarketInfo(symbol, MODE_ASK);
        
        double orderTP = OrderTakeProfit();
        if(orderTP <= 0) continue;
        
        int gid;
        double signalSL;
        string channelName;
        bool isBuyOrder = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT);
        
        if(!ParseOrderCommentFull(OrderComment(), gid, signalSL, channelName)) continue;
        
        // Find pre-calculated TP levels for this group
        int groupIndex = -1;
        for(int g = 0; g < uniqueGroupCount; g++) {
            if(uniqueGroups[g] == gid) {
                groupIndex = g;
                break;
            }
        }
        
        if(groupIndex == -1) {
            if(debugMode) PrintLog(eaName + ": TS warning - GID " + IntegerToString(gid) + " not found in pre-calculated groups");
            continue;
        }
        
        // ENHANCED: Point calculation with symbol-specific fallbacks
        double point = MarketInfo(symbol, MODE_POINT);
        if(point <= 0) {
            if(StringFind(symbol, "JPY") >= 0) {
                point = 0.01;  // 4-digit JPY pairs
            } else if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0) {
                point = 0.01;  // Gold typically 2-3 digits
            } else if(StringFind(symbol, "BTC") >= 0) {
                point = 0.01;  // Bitcoin typically 2 digits
            } else {
                point = 0.00001; // 5-digit major pairs
            }
        }
        double tolerance = triggerTolerancePips * point;
        
        // STABILITY FIX: More conservative trigger tolerance
        double triggerTolerance = tolerance * 0.3; // Use 30% of tolerance for triggering
        
        // Check ALL TP levels for this group using pre-calculated data
        int highestTriggeredTP = 0;
        int tpCount = allTPCounts[groupIndex];
        bool groupIsBuyOrder = allIsBuyOrder[groupIndex];
        
        for(int j = 0; j < tpCount; j++)
        {
            double tpLevel = allTPLevels[groupIndex][j];
            bool thisTPReached = false;
            
            if(groupIsBuyOrder) {
                thisTPReached = (currentPrice >= tpLevel - triggerTolerance);
            } else {
                thisTPReached = (currentPrice <= tpLevel + triggerTolerance);
            }
            
            if(thisTPReached && (j + 1) > highestTriggeredTP) {
                highestTriggeredTP = j + 1; // 1-indexed
            }
            
            // Enhanced debug logging for near misses
            if(debugMode && !thisTPReached) {
                double distance = groupIsBuyOrder ? (tpLevel - currentPrice) : (currentPrice - tpLevel);
                if(distance <= tolerance && distance > triggerTolerance) {
                    PrintLog(eaName + ": TS " + (groupIsBuyOrder ? "BUY" : "SELL") + " TP" + IntegerToString(j+1) + 
                          " near but not triggered - Distance: " + DoubleToString(distance/point, 1) + " pips" +
                          " (needs " + DoubleToString(triggerTolerance/point, 1) + " pips)");
                }
            }
        }
        
        // Add triggered group if any TP level was reached
        if(highestTriggeredTP > 0) {
            AddTriggeredGroup(gid, highestTriggeredTP);
            if(debugMode) PrintLog(eaName + ": TS detected HIGHEST TP" + IntegerToString(highestTriggeredTP) + 
                              " for GID " + IntegerToString(gid) + " Ticket: " + IntegerToString(ticket) +
                              " (Price: " + DoubleToString(currentPrice, MarketInfo(symbol, MODE_DIGITS)) +
                              ", TP: " + DoubleToString(allTPLevels[groupIndex][highestTriggeredTP-1], MarketInfo(symbol, MODE_DIGITS)) + ")");
        }
    }
    
    // PHASE 2: Check recently closed orders for additional triggers (using pre-calculated groups)
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
                // Find pre-calculated TP levels for this group
                int groupIndex = -1;
                for(int g = 0; g < uniqueGroupCount; g++) {
                    if(uniqueGroups[g] == gid) {
                        groupIndex = g;
                        break;
                    }
                }
                
                if(groupIndex != -1) {
                    int tpCount = allTPCounts[groupIndex];
                    for(int j = 0; j < tpCount; j++)
                    {
                        if(MathAbs(orderTP - allTPLevels[groupIndex][j]) <= tolerance)
                        {
                            int tpLevel = j + 1;
                            AddTriggeredGroup(gid, tpLevel);
                            if(debugMode) PrintLog(eaName + ": TS detected closed TP" + IntegerToString(tpLevel) + " for GID " + IntegerToString(gid));
                            break;
                        }
                    }
                }
            }
        }
    }

    if(debugMode) PrintLog(eaName + ": TS found " + IntegerToString(triggeredCount) + " triggered groups");

    // PHASE 3: Update SL for remaining open orders based on triggered TPs (using pre-calculated data)
    int totalModifications = 0;
    for(int m = 0; m < openTotal; m++)
    {
        if(!OrderSelect(m, SELECT_BY_POS, MODE_TRADES)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        if(OrderCloseTime() != 0) continue;
        
        int ticket = OrderTicket();
        if(HasBeenModified(ticket)) {
            if(debugMode) PrintLog(eaName + ": TS skipping ticket " + IntegerToString(ticket) + " - already modified this scan");
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
            if(debugMode) PrintLog(eaName + ": TS no trigger for GID " + IntegerToString(gid) + " ticket " + IntegerToString(ticket));
            continue; // No TP triggered for this group
        }

        // Find pre-calculated TP levels for this group
        int groupIndex = -1;
        for(int g = 0; g < uniqueGroupCount; g++) {
            if(uniqueGroups[g] == gid) {
                groupIndex = g;
                break;
            }
        }
        
        if(groupIndex == -1) {
            if(debugMode) PrintLog(eaName + ": TS warning - cannot find TP levels for GID " + IntegerToString(gid));
            continue;
        }

        // Calculate new SL based on triggered TP level using pre-calculated data
        double newSL;
        double openPrice = OrderOpenPrice();
        int digits = MarketInfo(OrderSymbol(), MODE_DIGITS);
        int tpCount = allTPCounts[groupIndex];
        
        if(triggeredTPLevel == 1)
        {
            // TP1 hit: Move SL to breakeven (order open price)
            newSL = NormalizeDouble(openPrice, digits);
            if(debugMode) PrintLog(eaName + ": TS TP1 triggered for ticket " + IntegerToString(ticket) + " - moving SL to breakeven: " + DoubleToString(newSL, digits));
        }
        else if(triggeredTPLevel > 1 && triggeredTPLevel <= tpCount)
        {
            // TP2+ hit: Move SL to previous TP level using pre-calculated data
            newSL = NormalizeDouble(allTPLevels[groupIndex][triggeredTPLevel - 2], digits); // Previous TP
            if(debugMode) PrintLog(eaName + ": TS TP" + IntegerToString(triggeredTPLevel) + " triggered for ticket " + IntegerToString(ticket) + 
                              " - moving SL to TP" + IntegerToString(triggeredTPLevel-1) + ": " + DoubleToString(newSL, digits));
        }
        else
        {
            if(debugMode) PrintLog(eaName + ": TS invalid TP level " + IntegerToString(triggeredTPLevel) + " for ticket " + IntegerToString(ticket));
            continue; // Invalid TP level
        }
        
        // STABILITY FIX: Enhanced validation with multiple checks
        double currentSL = OrderStopLoss();
        if(MathAbs(newSL - currentSL) < SL_MODIFY_THRESHOLD) {
            if(debugMode) PrintLog(eaName + ": TS SL change too small for ticket " + IntegerToString(ticket) + 
                              " current: " + DoubleToString(currentSL, digits) + " new: " + DoubleToString(newSL, digits));
            continue;
        }
        
        // STABILITY FIX: More robust SL direction validation
        bool isBuyOrder = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT);
        bool validDirection = false;
        
        if(isBuyOrder) {
            // For BUY orders: new SL must be higher than current SL (or current SL is 0/unset)
            // ALSO: new SL should not be higher than current market price (avoid immediate trigger)
            RefreshRates();
            double currentBid = MarketInfo(OrderSymbol(), MODE_BID);
            validDirection = (currentSL <= 0.000001 || newSL > currentSL) && (newSL < currentBid * 0.999); // 0.1% safety margin
        } else {
            // For SELL orders: new SL must be lower than current SL (or current SL is 0/unset)
            // ALSO: new SL should not be lower than current market price
            RefreshRates();
            double currentAsk = MarketInfo(OrderSymbol(), MODE_ASK);
            validDirection = (currentSL <= 0.000001 || newSL < currentSL) && (newSL > currentAsk * 1.001); // 0.1% safety margin
        }
        
        if(!validDirection) {
            if(debugMode) PrintLog(eaName + ": TS invalid SL direction/level for " + (isBuyOrder ? "BUY" : "SELL") + " ticket " + IntegerToString(ticket) + 
                              " Current SL: " + DoubleToString(currentSL, digits) + " Proposed: " + DoubleToString(newSL, digits));
            continue;
        }
        
        // Apply broker constraints
        RefreshRates();
        double ask = MarketInfo(OrderSymbol(), MODE_ASK);
        double bid = MarketInfo(OrderSymbol(), MODE_BID);
        
        if(!CheckStopLevel(OrderSymbol(), OrderType(), newSL, ask, bid)) {
            if(debugMode) PrintLog(eaName + ": TS SL failed broker constraints for ticket " + IntegerToString(ticket));
            continue;
        }

        // ANTI-WHIPSAW PROTECTION CHECK
        string symbol = OrderSymbol();
        double currentPrice = isBuyOrder ? bid : ask;
        bool slTooClose = CheckIfSLTooClose(symbol, newSL, currentPrice, isBuyOrder);
        
        if(slTooClose) {
            // SL túl közel van -> pending listára
            PrintLog("🔄 Anti-Whipsaw DELAY: Ticket " + IntegerToString(ticket) + 
                     " SL too close to current price, delaying " + IntegerToString(antiWhipsawDelaySeconds) + " seconds");
            AddPendingTrailingStop(ticket, gid, triggeredTPLevel, newSL, currentPrice);
            continue;
        }

        // STABILITY FIX: Enhanced order modification with better error handling
        bool modifySuccess = false;
        int attempts = 0;
        int maxAttempts = 3;
        
        while(!modifySuccess && attempts < maxAttempts) {
            attempts++;
            
            // Critical: Refresh rates and re-select order before each attempt
            RefreshRates();
            if(!OrderSelect(ticket, SELECT_BY_TICKET)) {
                PrintLog(eaName + ": TS order disappeared during modify - ticket " + IntegerToString(ticket));
                break;
            }
            
            // Double-check order is still open
            if(OrderCloseTime() != 0) {
                if(debugMode) PrintLog(eaName + ": TS order closed during modify - ticket " + IntegerToString(ticket));
                break;
            }
            
            // Final safety check - verify SL is still valid with fresh market data
            ask = MarketInfo(OrderSymbol(), MODE_ASK);
            bid = MarketInfo(OrderSymbol(), MODE_BID);
            if(!CheckStopLevel(OrderSymbol(), OrderType(), newSL, ask, bid)) {
                PrintLog(eaName + ": TS SL became invalid due to market change - ticket " + IntegerToString(ticket));
                break;
            }
            
            if(OrderModify(ticket, OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrMagenta))
            {
                modifySuccess = true;
                PrintLog(eaName + ": ✅ IMMEDIATE TS success for ticket " + IntegerToString(ticket) + 
                      " from " + DoubleToString(currentSL, digits) + " to " + DoubleToString(newSL, digits) +
                      " (TP" + IntegerToString(triggeredTPLevel) + " triggered for GID " + IntegerToString(gid) + ") [attempt " + IntegerToString(attempts) + "]");
                MarkAsModified(ticket);
                totalModifications++;
            }
            else
            {
                int error = GetLastError();
                PrintLog(eaName + ": TS modify attempt " + IntegerToString(attempts) + "/" + IntegerToString(maxAttempts) + 
                      " failed for ticket " + IntegerToString(ticket) + " error: " + IntegerToString(error));
                
                // STABILITY FIX: Better error handling
                if(error == ERR_BROKER_BUSY || error == ERR_TRADE_CONTEXT_BUSY || error == ERR_PRICE_CHANGED) {
                    if(attempts < maxAttempts) {
                        Sleep(200 + (attempts * 100)); // Progressive delay: 200ms, 300ms, 400ms
                        continue; // Retry
                    }
                } else if(error == ERR_INVALID_STOPS) {
                    PrintLog(eaName + ": TS invalid stops error - market conditions changed");
                    break; // Don't retry for constraint violations
                } else if(error == ERR_TRADE_MODIFY_DENIED || error == ERR_TRADE_DISABLED) {
                    PrintLog(eaName + ": TS trading not allowed - check trading permissions");
                    break; // Don't retry for permission issues
                } else {
                    PrintLog(eaName + ": TS unhandled error " + IntegerToString(error) + " - stopping retries");
                    break; // Non-retriable error
                }
            }
        }
        
        if(!modifySuccess) {
            PrintLog(eaName + ": ❌ TS modify failed permanently for ticket " + IntegerToString(ticket) + 
                  " GID: " + IntegerToString(gid) + " after " + IntegerToString(attempts) + " attempts");
        }
    }
    
    if(debugMode) {
        int pendingCount = CountActivePendingStops();
        PrintLog(eaName + ": TS scan complete - Groups processed: " + IntegerToString(uniqueGroupCount) + 
                 ", Immediate modifications: " + IntegerToString(totalModifications) + 
                 ", Pending Anti-Whipsaw delays: " + IntegerToString(pendingCount));
    }
}

//+------------------------------------------------------------------+
//| ProcessExternalSLUpdates: Apply external SL update commands     |
//+------------------------------------------------------------------+
void ProcessExternalSLUpdates()
{
    if(!FileExists(gExternalSLFile)) return;
    
    if(externalSLHandle == -1)
    {
        externalSLHandle = FileOpen(gExternalSLFile, FILE_READ|FILE_SHARE_READ|FILE_TXT|FILE_ANSI);
    }
    if(externalSLHandle == INVALID_HANDLE) return;
    
    string cmd = FileReadString(externalSLHandle);
    if(!IsTesting()) {
        FileClose(externalSLHandle);
        externalSLHandle = -1;
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
            PrintLog(eaName + "Not a valid SL modify command: " + cmd);
            return;
        }
    }
    
    if(gid <= 0) {
        PrintLog(eaName + "Invalid GID in SL modify command: " + cmd);
        return;
    }
    
    double newSL = StrToDouble(StringSubstr(cmd, sep+8));

    int total = OrdersTotal();
    for(int i=0; i<total; i++)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            PrintLog(eaName + ": ext SL order select failed at index " + IntegerToString(i));
            continue;
        }
        if(OrderMagicNumber() != MAGIC_NUMBER) {
            if(debugMode) PrintLog(eaName + ": Ignoring order at index " + IntegerToString(i) + " - wrong magic number");
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
            if(debugMode) PrintLog(eaName + ": Ignoring order at index " + IntegerToString(i) + " - GID mismatch");
            continue;
        }
        
        // STABILITY FIX: Enhanced external SL update with validation
        double op = OrderOpenPrice();
        double tp = OrderTakeProfit();
        double currentSL = OrderStopLoss();
        
        // Check if change is significant enough
        if(MathAbs(currentSL - newSL) < SL_MODIFY_THRESHOLD) {
            if(debugMode) PrintLog(eaName + ": External SL change too small for ticket " + IntegerToString(OrderTicket()));
            continue;
        }
        
        // Validate SL direction for order type
        bool isBuyOrder = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT);
        bool validDirection = true;
        
        if(isBuyOrder && currentSL > 0 && newSL <= currentSL) {
            PrintLog(eaName + ": External SL invalid direction for BUY order - current: " + 
                  DoubleToString(currentSL, MarketInfo(OrderSymbol(), MODE_DIGITS)) + 
                  " new: " + DoubleToString(newSL, MarketInfo(OrderSymbol(), MODE_DIGITS)));
            validDirection = false;
        } else if(!isBuyOrder && currentSL > 0 && newSL >= currentSL) {
            PrintLog(eaName + ": External SL invalid direction for SELL order - current: " + 
                  DoubleToString(currentSL, MarketInfo(OrderSymbol(), MODE_DIGITS)) + 
                  " new: " + DoubleToString(newSL, MarketInfo(OrderSymbol(), MODE_DIGITS)));
            validDirection = false;
        }
        
        if(!validDirection) continue;
        
        // Apply broker constraints
        RefreshRates();
        double ask = MarketInfo(OrderSymbol(), MODE_ASK);
        double bid = MarketInfo(OrderSymbol(), MODE_BID);
        
        if(!CheckStopLevel(OrderSymbol(), OrderType(), newSL, ask, bid)) {
            PrintLog(eaName + ": External SL failed broker constraints for ticket " + IntegerToString(OrderTicket()));
            continue;
        }
        
        if(!OrderModify(OrderTicket(), op, newSL, tp, 0, clrGold)) {
            PrintLog(eaName + ": External SL update failed for GID=" + IntegerToString(gid) +
                  " ticket=" + IntegerToString(OrderTicket()) + 
                  " error=" + IntegerToString(GetLastError()));
        } else {
            PrintLog(eaName + ": ✅ External SL updated for GID=" + IntegerToString(gid) +
                  " ticket=" + IntegerToString(OrderTicket()) + 
                  " from " + DoubleToString(currentSL, MarketInfo(OrderSymbol(), MODE_DIGITS)) +
                  " to " + DoubleToString(newSL, MarketInfo(OrderSymbol(), MODE_DIGITS)));
        }
    }
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
            if(debugMode) PrintLog(eaName + ": Invalid old comment format, no GID found: " + comment);
            return(false);
        }
        
        // Find first pipe after GID
        int firstPipe = StringFind(comment, "|", 4);
        if(firstPipe < 0) {
            if(debugMode) PrintLog(eaName + ": Invalid old comment format, no pipe separator found: " + comment);
            return(false);
        }
        
        // Extract GID
        groupId = StrToInteger(StringSubstr(comment, 4, firstPipe-4));
        if(groupId <= 0) {
            if(debugMode) PrintLog(eaName + ": Invalid GID in old comment: " + comment);
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
                if(debugMode) PrintLog(eaName + ": No SL found in old comment: " + comment);
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
            PrintLog(eaName + ": Parsed old comment - GID:" + IntegerToString(groupId) + " Channel:" + channelName + " SL:" + DoubleToString(signalSL, 5));
        }
        
        return(true);
    }
    
    // New format: 1234|ABCD|1.2345
    int firstPipe = StringFind(comment, "|");
    if(firstPipe < 0) {
        if(debugMode) PrintLog(eaName + ": Invalid new comment format, no first pipe found: " + comment);
        return(false);
    }
    
    int secondPipe = StringFind(comment, "|", firstPipe + 1);
    if(secondPipe < 0) {
        if(debugMode) PrintLog(eaName + ": Invalid new comment format, no second pipe found: " + comment);
        return(false);
    }
    
    // Extract GID (first part)
    groupId = StrToInteger(StringSubstr(comment, 0, firstPipe));
    if(groupId <= 0) {
        if(debugMode) PrintLog(eaName + ": Invalid GID in new comment: " + comment);
        return(false);
    }
    
    // Extract channel name (second part, should be 4 letters)
    channelName = StringSubstr(comment, firstPipe + 1, secondPipe - firstPipe - 1);
    if(StringLen(channelName) != 4) {
        if(debugMode) PrintLog(eaName + ": Invalid channel name length in new comment: " + comment);
        channelName = "UNKN"; // Fallback
    }
    
    // Extract SL value (third part)
    signalSL = StrToDouble(StringSubstr(comment, secondPipe + 1));
    
    if(debugMode) {
        PrintLog(eaName + ": Parsed new comment - GID:" + IntegerToString(groupId) + " Channel:" + channelName + " SL:" + DoubleToString(signalSL, 5));
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
    
    if(debugMode) PrintLog(eaName + ": Reconstructing TP levels for GID " + IntegerToString(groupId));
    
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
        if(debugMode) PrintLog(eaName + ": No TP levels found for GID " + IntegerToString(groupId));
        return false;
    }
    
    // CRITICAL FIX: Sort TP levels correctly
    // For BUY orders: TP1 < TP2 < TP3 (ascending - closest to entry first)
    // For SELL orders: TP1 > TP2 > TP3 (descending - closest to entry first)
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
    
    // FIXED: Correct sorting logic - TP1 should always be closest to entry
    // Simple bubble sort
    for(int i = 0; i < tempCount - 1; i++)
    {
        for(int j = 0; j < tempCount - i - 1; j++)
        {
            // For BUY: Sort ascending (TP1=lowest, TP2=higher, TP3=highest)
            // For SELL: Sort descending (TP1=highest, TP2=lower, TP3=lowest)
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
        PrintLog(eaName + ": Reconstructed " + IntegerToString(tpCount) + " TP levels for GID " + IntegerToString(groupId) + ": " + tpStr);
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
        if(debugMode) PrintLog(eaName + ": Invalid groupId or tpLevel: " + IntegerToString(groupId) + "/" + IntegerToString(tpLevel));
        return;
    }
    
    // STABILITY FIX: Thread-safe group management with bounds checking
    datetime currentTime = TimeCurrent();
    
    // Check if group already exists and update with higher TP level
    for(int i = 0; i < triggeredCount; i++)
    {
        if(triggeredGroups[i].groupId == groupId)
        {
            // STABILITY FIX: Only update if significantly higher TP level
            if(tpLevel > triggeredGroups[i].triggeredTPLevel)
            {
                int oldLevel = triggeredGroups[i].triggeredTPLevel;
                triggeredGroups[i].triggeredTPLevel = tpLevel;
                triggeredGroups[i].triggerTime = currentTime;
                if(debugMode) PrintLog(eaName + ": Updated triggered group " + IntegerToString(groupId) + 
                                  " from TP" + IntegerToString(oldLevel) + " to TP" + IntegerToString(tpLevel));
            }
            else if(tpLevel == triggeredGroups[i].triggeredTPLevel) {
                // Refresh timestamp for same level (maintain validity)
                triggeredGroups[i].triggerTime = currentTime;
                if(debugMode) PrintLog(eaName + ": Refreshed trigger time for group " + IntegerToString(groupId) + " TP" + IntegerToString(tpLevel));
            }
            else if(debugMode) {
                PrintLog(eaName + ": Group " + IntegerToString(groupId) + " already has higher TP" + 
                      IntegerToString(triggeredGroups[i].triggeredTPLevel) + " (ignoring TP" + IntegerToString(tpLevel) + ")");
            }
            return;
        }
    }
    
    // STABILITY FIX: Add new triggered group with bounds checking
    if(triggeredCount < MAX_GROUPS)
    {
        triggeredGroups[triggeredCount].groupId = groupId;
        triggeredGroups[triggeredCount].triggeredTPLevel = tpLevel;
        triggeredGroups[triggeredCount].triggerTime = currentTime;
        triggeredCount++;
        if(debugMode) PrintLog(eaName + ": Added new triggered group " + IntegerToString(groupId) + " with TP" + IntegerToString(tpLevel) + 
                              " (total groups: " + IntegerToString(triggeredCount) + ")");
    }
    else
    {
        // STABILITY FIX: Try to replace the oldest entry if array is full
        int oldestIndex = 0;
        datetime oldestTime = triggeredGroups[0].triggerTime;
        
        for(int i = 1; i < MAX_GROUPS; i++) {
            if(triggeredGroups[i].triggerTime < oldestTime) {
                oldestTime = triggeredGroups[i].triggerTime;
                oldestIndex = i;
            }
        }
        
        // Replace oldest entry if it's older than 5 minutes
        if(currentTime - oldestTime > 300) {
            PrintLog(eaName + ": WARNING: Replacing oldest triggered group " + IntegerToString(triggeredGroups[oldestIndex].groupId) + 
                  " with new group " + IntegerToString(groupId) + " TP" + IntegerToString(tpLevel));
            triggeredGroups[oldestIndex].groupId = groupId;
            triggeredGroups[oldestIndex].triggeredTPLevel = tpLevel;
            triggeredGroups[oldestIndex].triggerTime = currentTime;
        } else {
            PrintLog(eaName + ": ERROR: Cannot add triggered group " + IntegerToString(groupId) + " - array full with recent entries!");
        }
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
        PrintLog(eaName + ": invalid SL " + DoubleToString(sl, digits));
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
        PrintLog(eaName + ": price freeze err");
        return(false);
    }
    if(MathAbs(openPrice-ask) < freezeDist || MathAbs(openPrice-bid) < freezeDist)
    {
        PrintLog(eaName + ": freeze violation");
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
        PrintLog(eaName + ": Signal age check - UTC now: " + TimeToString(utcTime) +
              ", Signal time: " + TimeToString(signalTime) +
              ", Age: " + IntegerToString(ageMinutes) + " minutes");
    
    return(ageMinutes > signalMaxAgeMinutes);
}

//+------------------------------------------------------------------+
//| FileExists: check if a file exists                              |
//+------------------------------------------------------------------+
bool FileExists(string filename)
{
    int tfh = FileOpen(filename, FILE_READ|FILE_SHARE_READ | FILE_TXT | FILE_ANSI);
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

//+------------------------------------------------------------------+
//| PrintLog: Write log to daily file and Experts log               |
//+------------------------------------------------------------------+
void PrintLog(string msg)
{
    datetime currentTime = TimeCurrent() - (brokerTimeOffsetMinutes * 60);
    string dateStr = TimeToString(currentTime, TIME_DATE);
    string y = StringSubstr(dateStr, 0, 4);
    string m = StringSubstr(dateStr, 5, 2);
    string d = StringSubstr(dateStr, 8, 2);
    string logFile = y + m + d + ".log";
    int handle = FileOpen(logFile, FILE_WRITE|FILE_SHARE_READ|FILE_READ|FILE_TXT|FILE_ANSI);
    if(handle != INVALID_HANDLE)
    {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(currentTime, TIME_DATE|TIME_SECONDS), " ", msg);
        FileFlush(handle);
        FileClose(handle);
    }
    // Also print to Experts log for convenience
    Print(msg);
}

//+------------------------------------------------------------------+
//| ANTI-WHIPSAW PROTECTION FUNCTIONS                              |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| GetMinimumSLDistance: Symbol-specific minimum SL distance       |
//+------------------------------------------------------------------+
double GetMinimumSLDistance(string symbol)
{
    // Bitcoin párok
    if(StringFind(symbol, "BTC") >= 0 || 
       StringFind(symbol, "BITCOIN") >= 0) {
        return minSLDistancePips_BTC;
    }
    
    // Arany (XAU)
    if(StringFind(symbol, "XAU") >= 0 || 
       StringFind(symbol, "GOLD") >= 0) {
        return minSLDistancePips_GOLD;
    }
    
    // Major Forex párok
    if(StringFind(symbol, "USD") >= 0 || 
       StringFind(symbol, "EUR") >= 0 || 
       StringFind(symbol, "GBP") >= 0 || 
       StringFind(symbol, "JPY") >= 0 ||
       StringFind(symbol, "CHF") >= 0 ||
       StringFind(symbol, "CAD") >= 0 ||
       StringFind(symbol, "AUD") >= 0 ||
       StringFind(symbol, "NZD") >= 0) {
        return minSLDistancePips_FOREX;
    }
    
    // Crypto párok (ETH, LTC, stb.)
    if(StringFind(symbol, "ETH") >= 0 || 
       StringFind(symbol, "LTC") >= 0 || 
       StringFind(symbol, "BCH") >= 0 ||
       StringFind(symbol, "XRP") >= 0 ||
       StringFind(symbol, "ADA") >= 0) {
        return minSLDistancePips_CRYPTO;
    }
    
    // Default: forex távolság
    return minSLDistancePips_FOREX;
}

//+------------------------------------------------------------------+
//| CheckIfSLTooClose: Ellenőrzi hogy túl közel van-e az új SL     |
//+------------------------------------------------------------------+
bool CheckIfSLTooClose(string symbol, double newSL, double currentPrice, bool isBuyOrder)
{
    double point = MarketInfo(symbol, MODE_POINT);
    if(point <= 0) {
        // Fallback point értékek
        if(StringFind(symbol, "JPY") >= 0) {
            point = 0.01;
        } else {
            point = 0.00001;
        }
    }
    
    double minDistancePips = GetMinimumSLDistance(symbol);
    double minDistancePrice = minDistancePips * point;
    
    double slDistance;
    if(isBuyOrder) {
        // BUY order esetén: current price - new SL = távolság
        slDistance = currentPrice - newSL;
    } else {
        // SELL order esetén: new SL - current price = távolság
        slDistance = newSL - currentPrice;
    }
    
    bool tooClose = (slDistance < minDistancePrice);
    
    if(debugMode) {
        PrintLog("Anti-Whipsaw Check for " + symbol + ":");
        PrintLog("  Current Price: " + DoubleToString(currentPrice, MarketInfo(symbol, MODE_DIGITS)));
        PrintLog("  Proposed SL: " + DoubleToString(newSL, MarketInfo(symbol, MODE_DIGITS)));
        PrintLog("  Distance: " + DoubleToString(slDistance / point, 1) + " pips");
        PrintLog("  Minimum Required: " + DoubleToString(minDistancePips, 1) + " pips");
        PrintLog("  Too Close: " + (tooClose ? "YES (DELAY)" : "NO (EXECUTE)"));
    }
    
    return tooClose;
}

//+------------------------------------------------------------------+
//| AddPendingTrailingStop: Függőben lévő trailing stop hozzáadása |
//+------------------------------------------------------------------+
void AddPendingTrailingStop(int ticket, int groupId, int triggeredTPLevel, double calculatedSL, double currentPrice)
{
    if(pendingStopCount >= 100) {
        PrintLog("WARNING: Pending stops array full, cannot add more!");
        return;
    }
    
    // Ellenőrizzük hogy már benne van-e
    for(int i = 0; i < pendingStopCount; i++) {
        if(pendingStops[i].ticket == ticket && pendingStops[i].isPending) {
            PrintLog("Ticket " + IntegerToString(ticket) + " already has pending trailing stop");
            return;
        }
    }
    
    // Új pending stop hozzáadása
    pendingStops[pendingStopCount].ticket = ticket;
    pendingStops[pendingStopCount].groupId = groupId;
    pendingStops[pendingStopCount].triggeredTPLevel = triggeredTPLevel;
    pendingStops[pendingStopCount].calculatedSL = calculatedSL;
    pendingStops[pendingStopCount].triggerTime = TimeCurrent();
    pendingStops[pendingStopCount].executeTime = TimeCurrent() + antiWhipsawDelaySeconds;
    pendingStops[pendingStopCount].triggerPrice = currentPrice;
    pendingStops[pendingStopCount].isPending = true;
    
    pendingStopCount++;
    
    PrintLog("Anti-Whipsaw: Added pending trailing stop for ticket " + IntegerToString(ticket) + 
             " (Execute at " + TimeToString(pendingStops[pendingStopCount-1].executeTime) + ")");
}

//+------------------------------------------------------------------+
//| ProcessPendingTrailingStops: Feldolgozza a függő trailing stops|
//+------------------------------------------------------------------+
void ProcessPendingTrailingStops()
{
    datetime now = TimeCurrent();
    
    for(int i = 0; i < pendingStopCount; i++) {
        if(!pendingStops[i].isPending) continue;
        
        // Ellenőrizzük hogy lejárt-e a várakozási idő
        if(now < pendingStops[i].executeTime) continue;
        
        int ticket = pendingStops[i].ticket;
        
        // Ellenőrizzük hogy az order még nyitva van-e
        if(!OrderSelect(ticket, SELECT_BY_TICKET)) {
            PrintLog("Anti-Whipsaw: Ticket " + IntegerToString(ticket) + " not found (closed?)");
            pendingStops[i].isPending = false;
            continue;
        }
        
        if(OrderCloseTime() != 0) {
            PrintLog("Anti-Whipsaw: Ticket " + IntegerToString(ticket) + " already closed");
            pendingStops[i].isPending = false;
            continue;
        }
        
        string symbol = OrderSymbol();
        RefreshRates();
        double currentPrice = (OrderType() == OP_BUY) ? 
                             MarketInfo(symbol, MODE_BID) : MarketInfo(symbol, MODE_ASK);
        
        // RE-VALIDATION: Ellenőrizzük hogy most sem túl közel-e
        bool isBuyOrder = (OrderType() == OP_BUY);
        double proposedSL = pendingStops[i].calculatedSL;
        
        bool stillTooClose = CheckIfSLTooClose(symbol, proposedSL, currentPrice, isBuyOrder);
        
        if(stillTooClose) {
            // Ha még mindig túl közel van, adjunk még 2 percet
            pendingStops[i].executeTime = now + 120; // +2 perc
            PrintLog("Anti-Whipsaw: Ticket " + IntegerToString(ticket) + " still too close, delaying +2min");
            continue;
        }
        
        // VÉGREHAJTÁS: SL módosítás most már biztonságos
        double currentSL = OrderStopLoss();
        
        // Végső irány ellenőrzés
        bool validDirection = true;
        if(isBuyOrder) {
            // BUY order: új SL magasabb legyen mint a jelenlegi (vagy 0)
            validDirection = (currentSL <= 0.000001 || proposedSL > currentSL);
        } else {
            // SELL order: új SL alacsonyabb legyen mint a jelenlegi (vagy 0)
            validDirection = (currentSL <= 0.000001 || proposedSL < currentSL);
        }
        
        if(!validDirection) {
            PrintLog("Anti-Whipsaw: Invalid SL direction for ticket " + IntegerToString(ticket) + 
                     " Current: " + DoubleToString(currentSL, MarketInfo(symbol, MODE_DIGITS)) +
                     " Proposed: " + DoubleToString(proposedSL, MarketInfo(symbol, MODE_DIGITS)));
            pendingStops[i].isPending = false;
            continue;
        }
        
        // SL módosítás végrehajtása
        bool success = OrderModify(ticket, OrderOpenPrice(), proposedSL, 
                                   OrderTakeProfit(), OrderExpiration());
        
        if(success) {
            PrintLog("✅ Anti-Whipsaw SUCCESS: Modified ticket " + IntegerToString(ticket) + 
                     " SL: " + DoubleToString(currentSL, MarketInfo(symbol, MODE_DIGITS)) + 
                     " -> " + DoubleToString(proposedSL, MarketInfo(symbol, MODE_DIGITS)));
                     
            // Statisztika frissítése
            if(modifiedCount < MAX_MODIFIED_TICKETS) {
                modifiedTickets[modifiedCount] = ticket;
                modifiedCount++;
            }
        } else {
            int error = GetLastError();
            PrintLog("❌ Anti-Whipsaw FAILED: Ticket " + IntegerToString(ticket) + 
                     " Error: " + IntegerToString(error));
        }
        
        // Pending stop eltávolítása (sikeres vagy sikertelen)
        pendingStops[i].isPending = false;
    }
    
    // Tisztítás: inaktív bejegyzések eltávolítása
    int activeCount = 0;
    for(int i = 0; i < pendingStopCount; i++) {
        if(pendingStops[i].isPending) {
            if(activeCount != i) {
                pendingStops[activeCount] = pendingStops[i];
            }
            activeCount++;
        }
    }
    pendingStopCount = activeCount;
}

//+------------------------------------------------------------------+
//| CountActivePendingStops: Aktív pending stops száma             |
//+------------------------------------------------------------------+
int CountActivePendingStops()
{
    int count = 0;
    for(int i = 0; i < pendingStopCount; i++) {
        if(pendingStops[i].isPending) count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| ShowPendingStopsStatus: Pending stops státusz kiírása         |
//+------------------------------------------------------------------+
void ShowPendingStopsStatus()
{
    int activeCount = CountActivePendingStops();
    if(activeCount == 0) {
        PrintLog("Anti-Whipsaw: No pending trailing stops");
        return;
    }
    
    PrintLog("Anti-Whipsaw Status: " + IntegerToString(activeCount) + " pending stops");
    
    for(int i = 0; i < pendingStopCount; i++) {
        if(!pendingStops[i].isPending) continue;
        
        int remainingSeconds = (int)(pendingStops[i].executeTime - TimeCurrent());
        PrintLog("  Ticket " + IntegerToString(pendingStops[i].ticket) + 
                 " -> Execute in " + IntegerToString(remainingSeconds) + "s" +
                 " (TP" + IntegerToString(pendingStops[i].triggeredTPLevel) + ")");
    }
}

