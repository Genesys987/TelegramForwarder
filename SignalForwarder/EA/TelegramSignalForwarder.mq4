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
extern int    brokerTimeOffsetMinutes  = 120;   // Broker time offset from UTC in minutes (e.g., UTC+2 = 120)
extern int    signalMaxAgeMinutes      = 5;     // Maximum signal age in minutes before rejection
extern string symbolPostfix           = "";     // Broker-specific symbol postfix (e.g., ".m", ".ecn")
extern double fixedLotSize              = 0.02;  // Default lot size for FX orders
extern double fixedLotSizeBitcoin       = 0.02;  // Default lot size for Bitcoin orders
extern double fixedLotSizeGold          = 0.02;  // Default lot size for Gold orders

//+------------------------------------------------------------------+
//|--- Constants & File Paths                                        |
//+------------------------------------------------------------------+
#define MAGIC_NUMBER          123456             // Unique EA identifier
#define SL_MODIFY_THRESHOLD   0.00001            // Minimum SL diff to apply

static string gSignalFile     = "signals.txt";       // Incoming signal file
static string gTempFile       = "processing.txt";     // Temp file to avoid re-read
static string gExternalSLFile = "stoploss_update.txt";// External SL updates

//+------------------------------------------------------------------+
//|--- Global State Variables                                       |
//+------------------------------------------------------------------+
string   eaName               = "TelegramSignalForwarder";
int      fh = -1;                  // File handle for reading signals
string   nextSignal = "";
int      lastProcessedGroupId = -1; // Track last processed signal to avoid duplicates
datetime lastProcessedTime = 0;     // Track last processed time for additional safety

// Trailing Stop State Tracking
struct TrailingStopState {
    int gid;
    string channel;
    string symbol;
    bool isBuy;
    double originalEntry;
    double originalSL;
    int tpHitLevel;        // 0=no hits, 1=TP1 hit, 2=TP2 hit, etc.
    double tpLevels[20];   // All TP levels for this GID
    int tpCount;           // Number of TP levels
    datetime lastUpdate;   // Last time this GID was updated
};

TrailingStopState gTrailingStops[100]; // Support up to 100 concurrent GIDs
int gTrailingStopsCount = 0;


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
                         double entryPrice, double stopLoss,
                         int groupId, string channelName, double &tpLevels[], int tpCount);
void    ProcessExternalSLUpdates();
void    ProcessDynamicTrailingStop();
void    CleanupInactiveTrailingStops();
void    InitializeTrailingStop(int gid, string channel, string symbol, bool isBuy, 
                              double entry, double sl, double &tpLevels[], int tpCount);
void    UpdateTrailingStopState(int gid, string channel);
double  CalculateNewSL(int tpHitLevel, double originalEntry, double originalSL, 
                      double &tpLevels[], int tpCount, string symbol, bool isBuy);
int     GetTrailingStopIndex(int gid, string channel);
bool    ParseOrderCommentFull(string comment, int &groupId, string &channelName);
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
string  FormatMT4Comment(int groupId, string channelName, double tp1, double tp2, string symbol);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int init()
{
    lastProcessedGroupId = -1; // Initialize to -1 to allow first signal
    lastProcessedTime = 0;     // Initialize to 0 to allow first signal
    
    // Initialize trailing stop array
    gTrailingStopsCount = 0;

    // Use chart's expert name if provided
    string customName = WindowExpertName();
    if(StringLen(customName) > 0)
        eaName = customName;

    if(debugMode)
        PrintLog(eaName + ": Initialized with trailing stop support");

    return(0);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
int deinit()
{
    if(debugMode)
        PrintLog(eaName + ": Deinitialized");
    return(0);
}

//+------------------------------------------------------------------+
//| Expert tick handler                                              |
//+------------------------------------------------------------------+
int start()
{
    string signalType, symbol, channelName;
    double entryPrice, stopLoss;
    int    groupId, tpCount;
    double tpLevels[20]; // Support up to 20 TP levels

    if(IsTradeAllowed() && IsConnected() && !IsStopped())
    {
        // Process dynamic trailing stop for existing positions
        ProcessDynamicTrailingStop();
        
        // Process new signal
        if(ReadSignalFile(signalType, symbol, entryPrice,
                          stopLoss, groupId, channelName, tpLevels, tpCount))
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
                        string orderChannel;
                        if(ParseOrderCommentFull(OrderComment(), orderGid, orderChannel))
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
                UpdateExistingOrdersSL(symbol, signalType, stopLoss, channelName);
                SendOrders(signalType, symbol,
                                 entryPrice, stopLoss,
                                 groupId, channelName, tpLevels, tpCount);
                
                // Initialize trailing stop state for this new GID
                InitializeTrailingStop(groupId, channelName, symbol, signalType == "BUY", 
                                     entryPrice, stopLoss, tpLevels, tpCount);
            }
        }
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
                    int &groupId, string &channelName, double &tpLevels[], int &tpCount)
{
  string line = "";
  if (StringLen(nextSignal) == 0)
  {
      if(fh == -1) 
      {
          if(!FileExists(gSignalFile)) return(false);
          fh = FileOpen(gSignalFile, FILE_READ|FILE_SHARE_READ | FILE_TXT | FILE_ANSI);
          PrintLog(eaName + ": Opening signal file " + gSignalFile);
          if(fh == INVALID_HANDLE) {
              PrintLog(eaName + ": Failed to open signal file");
              return(false);
          }
      }

      if(fh == INVALID_HANDLE)
      {
          PrintLog(eaName + ": Failed to open temp file for reading");
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
          PrintLog(eaName + ": Read signal line: [" + line + "]");
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

    // Expect: 123456789|TYPE|SYMBOL|ENTRY|TP1,TP2,TP3,...|SL|GID:<id>|CHANNEL_NAME
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
        string orderChannelName;
        if(!ParseOrderCommentFull(OrderComment(), orderGid, orderChannelName)) {
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
//| SendOrders: Place three market orders with SL & TP        |
//+------------------------------------------------------------------+
void SendOrders(string signalType, string symbol,
                      double entryPrice, double stopLoss,
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
    double tp1 = tpLevels[0];

    double price = shouldBuy ? ask : bid;
    int orderType = (shouldBuy) ? OP_BUY : OP_SELL;
    price = NormalizeDouble(price, digits);
    
    if(shouldBuy && price > tp1 || !shouldBuy && price < tp1) {
      PrintLog(eaName + ": Entry price " + DoubleToString(price, digits) +
            " is beyond TP1 " + DoubleToString(tp1, digits) + 
            " for GID=" + IntegerToString(groupId) + 
            ", skipping order creation");
      return;
    }

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
         // for market orders we want to get the correct current price
         // to avoid off-quotes errors
         RefreshRates();
         ask = MarketInfo(symbol, MODE_ASK);
         bid = MarketInfo(symbol, MODE_BID);
         price = (shouldBuy) ? ask : bid;
        string comment = FormatMT4Comment(groupId, channelName, tp1, tpLevels[k], symbol);
    
        PrintLog(eaName + ": Order[" + IntegerToString(k) + "] parameters: " +
        "Symbol=" + symbol +
        " Type=" + IntegerToString(orderType) +
        " Lots=" + DoubleToString(lotSize, 2) +
        " Price=" + DoubleToString(price, digits) +
        " SL=" + DoubleToString(rawSL, digits) +
        " TP=" + DoubleToString(tpLevels[k], digits) +
        " Comment=" + comment);

        int colorIndex = k % 6; // Cycle through available colors
        int ticket = OrderSend(symbol, orderType, lotSize, price, slippage,
                               rawSL, tpLevels[k], comment, MAGIC_NUMBER, 0 /* expiration */, cols[colorIndex]);
                                
        if(ticket < 0) {
            PrintLog(eaName + ": Error creating order[" + IntegerToString(k) + "] ticket=" + IntegerToString(ticket) + " error=" + IntegerToString(GetLastError()));
            Sleep(1000);
            RefreshRates();
            PrintLog(eaName + ": Retrying with fallback SL=" + DoubleToString(fallbackSL, digits));
            ticket = OrderSend(symbol, orderType, lotSize, price, slippage,
                               fallbackSL, tpLevels[k], comment, MAGIC_NUMBER, 0 /* expiration */, cols[colorIndex]);
        }
        
        PrintLog(eaName + ": Order[" + IntegerToString(k) + "] ticket=" + IntegerToString(ticket));
    }
}

//+------------------------------------------------------------------+
//| ProcessExternalSLUpdates: Apply external SL update commands     |
//+------------------------------------------------------------------+
void ProcessExternalSLUpdates()
{
    if(!FileExists(gExternalSLFile)) return;
    if(fh == -1)
    {
      fh = FileOpen(gExternalSLFile, FILE_READ|FILE_SHARE_READ|FILE_TXT|FILE_ANSI);
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
        double op = OrderOpenPrice();
        double tp = OrderTakeProfit();
        if(!OrderModify(OrderTicket(), op, newSL, tp, 0, clrGold))
            PrintLog(eaName + ": ext SL update fail GID=" + IntegerToString(gid) +
                  " err=" + IntegerToString(GetLastError()));
    }
}

//+------------------------------------------------------------------+
//| ParseOrderCommentFull: extracts GID and channel from comment    |
//+------------------------------------------------------------------+
bool ParseOrderCommentFull(string comment, int &groupId, string &channelName)
{
    // New format: 1234|ABCD|1.2550|1.2600 (GID|CHANNEL|TP1|ORDER_TP)
    // Old format compatibility: GID:1234|SL:1.2345 or 1234|ABCD|1.2345
    // We only care about GID and CHANNEL for identification purposes
    
    // Check if it's the old format with GID: prefix
    if(StringFind(comment, "GID:") == 0) {
        // Old format handling: GID:xxxx|...
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
        
        // For old format, use legacy channel name
        channelName = "LEGC"; // Old format default
        
        if(debugMode) {
            PrintLog(eaName + ": Parsed old comment (legacy) - GID:" + IntegerToString(groupId) + " Channel:" + channelName);
        }
        
        return(true);
    }
    
    // New format: 1234|ABCD|... (we only need the first two parts)
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
    
    if(debugMode) {
        PrintLog(eaName + ": Parsed comment - GID:" + IntegerToString(groupId) + " Channel:" + channelName);
    }
    
    return(true);
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
    if(orderType == OP_BUY)
         // For buy orders, SL must be below the bid price
         valid = (sl < bid && bid - sl >= minStopLevelDist);
    else if(orderType == OP_SELL)
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
//| New format: 1234|ABCD|1.2550|1.2600 (GID|CHANNEL|TP1|ORDER_TP)|
//+------------------------------------------------------------------+
string FormatMT4Comment(int groupId, string channelName, double tp1, double tp2, string symbol)
{
    string cleanChannel = CleanChannelName(channelName);
    
    // Determine decimal precision based on symbol type
    int precision = 4; // Default for Forex
    string upperSymbol = ToUpperCase(symbol);
    
    if(StringFind(upperSymbol, "XAUUSD") >= 0 || StringFind(upperSymbol, "GOLD") >= 0) {
        precision = 1; // Gold: 3366.9 (1 decimal, total 6 chars)
    } else if(StringFind(upperSymbol, "BTCUSD") >= 0 || StringFind(upperSymbol, "BTC") >= 0) {
        precision = 0; // Bitcoin: 118710 (no decimals, total 6 chars)
    } else {
        precision = 4; // Forex: 1.2550 (4 decimals, total 6 chars)
    }
    
    // Format TP values with appropriate precision
    string tp1Str = DoubleToString(tp1, precision);
    string tp2Str = DoubleToString(tp2, precision);
    
    // Remove trailing zeros if needed (except for the required format)
    if(precision > 0) {
        // For decimal numbers, ensure we maintain the required format length
        while(StringLen(tp1Str) > 1 && StringGetCharacter(tp1Str, StringLen(tp1Str)-1) == '0' && StringFind(tp1Str, ".") >= 0)
        {
            tp1Str = StringSubstr(tp1Str, 0, StringLen(tp1Str)-1);
        }
        if(StringLen(tp1Str) > 1 && StringGetCharacter(tp1Str, StringLen(tp1Str)-1) == '.')
        {
            tp1Str = StringSubstr(tp1Str, 0, StringLen(tp1Str)-1);
        }
        
        while(StringLen(tp2Str) > 1 && StringGetCharacter(tp2Str, StringLen(tp2Str)-1) == '0' && StringFind(tp2Str, ".") >= 0)
        {
            tp2Str = StringSubstr(tp2Str, 0, StringLen(tp2Str)-1);
        }
        if(StringLen(tp2Str) > 1 && StringGetCharacter(tp2Str, StringLen(tp2Str)-1) == '.')
        {
            tp2Str = StringSubstr(tp2Str, 0, StringLen(tp2Str)-1);
        }
    }
    
    // Build the comment: GID|CHANNEL|TP1|TP2
    string comment = IntegerToString(groupId) + "|" + cleanChannel + "|" + tp1Str + "|" + tp2Str;
    
    // Ensure comment fits within MT4's 31-character limit
    if(StringLen(comment) > 31)
    {
        // If too long, truncate precision further
        if(precision > 0) {
            precision = MathMax(0, precision - 1);
            tp1Str = DoubleToString(tp1, precision);
            tp2Str = DoubleToString(tp2, precision);
            comment = IntegerToString(groupId) + "|" + cleanChannel + "|" + tp1Str + "|" + tp2Str;
        }
        
        // If still too long, truncate the TP strings
        if(StringLen(comment) > 31) {
            int maxTPLen = (31 - StringLen(IntegerToString(groupId)) - StringLen(cleanChannel) - 3) / 2; // -3 for pipes
            if(maxTPLen > 0) {
                tp1Str = StringSubstr(tp1Str, 0, maxTPLen);
                tp2Str = StringSubstr(tp2Str, 0, maxTPLen);
                comment = IntegerToString(groupId) + "|" + cleanChannel + "|" + tp1Str + "|" + tp2Str;
            }
        }
    }
    
    return comment;
}

//+------------------------------------------------------------------+
//| ProcessDynamicTrailingStop: Main trailing stop logic           |
//+------------------------------------------------------------------+
void ProcessDynamicTrailingStop()
{
    // Clean up inactive trailing stops first
    CleanupInactiveTrailingStops();
    
    // Update all active trailing stop states based on history
    for(int i = 0; i < gTrailingStopsCount; i++)
    {
        UpdateTrailingStopState(gTrailingStops[i].gid, gTrailingStops[i].channel);
    }
}

//+------------------------------------------------------------------+
//| CleanupInactiveTrailingStops: Remove GIDs with no open orders  |
//+------------------------------------------------------------------+
void CleanupInactiveTrailingStops()
{
    for(int i = gTrailingStopsCount - 1; i >= 0; i--) // Reverse loop for safe removal
    {
        bool hasOpenOrders = false;
        
        // Check if this GID has any open orders
        for(int o = 0; o < OrdersTotal(); o++)
        {
            if(!OrderSelect(o, SELECT_BY_POS, MODE_TRADES)) continue;
            if(OrderMagicNumber() != MAGIC_NUMBER) continue;
            if(OrderSymbol() != gTrailingStops[i].symbol) continue;
            
            int orderGid;
            string orderChannel;
            if(!ParseOrderCommentFull(OrderComment(), orderGid, orderChannel)) continue;
            if(orderGid == gTrailingStops[i].gid && orderChannel == gTrailingStops[i].channel) {
                hasOpenOrders = true;
                break;
            }
        }
        
        // If no open orders and more than 5 minutes old, remove from array
        if(!hasOpenOrders && TimeCurrent() - gTrailingStops[i].lastUpdate > 300) {
            // Shift array elements down to remove this entry
            for(int j = i; j < gTrailingStopsCount - 1; j++) {
                gTrailingStops[j] = gTrailingStops[j + 1];
            }
            gTrailingStopsCount--;
        }
    }
}

//+------------------------------------------------------------------+
//| InitializeTrailingStop: Set up new trailing stop state         |
//+------------------------------------------------------------------+
void InitializeTrailingStop(int gid, string channel, string symbol, bool isBuy, 
                           double entry, double sl, double &tpLevels[], int tpCount)
{
    // Check if this GID already exists
    int existingIndex = GetTrailingStopIndex(gid, channel);
    if(existingIndex >= 0) {
        return;
    }
    
    // Add new trailing stop state
    if(gTrailingStopsCount >= 100) {
        PrintLog(eaName + ": Warning: Maximum trailing stop entries reached, skipping GID:" + IntegerToString(gid));
        return;
    }
    
    TrailingStopState newState;
    newState.gid = gid;
    newState.channel = channel;
    newState.symbol = symbol;
    newState.isBuy = isBuy;
    newState.originalEntry = entry;
    newState.originalSL = sl;
    newState.tpHitLevel = 0; // No TPs hit yet
    newState.tpCount = tpCount;
    newState.lastUpdate = TimeCurrent();
    
    // Copy TP levels
    for(int i = 0; i < tpCount && i < 20; i++) {
        newState.tpLevels[i] = tpLevels[i];
    }
    
    gTrailingStops[gTrailingStopsCount] = newState;
    gTrailingStopsCount++;
    
    PrintLog(eaName + ": Trailing stop initialized for GID:" + IntegerToString(gid) + 
           " Channel:" + channel + " TPCount:" + IntegerToString(tpCount) + 
           " Entry:" + DoubleToString(entry, MarketInfo(symbol, MODE_DIGITS)) +
           " SL:" + DoubleToString(sl, MarketInfo(symbol, MODE_DIGITS)));
    
    // Debug: print all TP levels
    if(debugMode) {
        for(int j = 0; j < tpCount && j < 20; j++) {
            PrintLog(eaName + ": TP[" + IntegerToString(j+1) + "] = " + 
                   DoubleToString(newState.tpLevels[j], MarketInfo(symbol, MODE_DIGITS)));
        }
    }
}

//+------------------------------------------------------------------+
//| UpdateTrailingStopState: Check history and update SL           |
//+------------------------------------------------------------------+
void UpdateTrailingStopState(int gid, string channel)
{
    int index = GetTrailingStopIndex(gid, channel);
    if(index < 0) return;
    
    if(debugMode) PrintLog(eaName + ": Updating trailing stop state for GID:" + IntegerToString(gid) + 
                          " Channel:" + channel + " Current level:" + IntegerToString(gTrailingStops[index].tpHitLevel));
    
    int newTpHitLevel = 0;
    
    // Check history for closed orders with profit (TP hits)
    int historyTotal = OrdersHistoryTotal();
    for(int h = 0; h < historyTotal; h++)
    {
        if(!OrderSelect(h, SELECT_BY_POS, MODE_HISTORY)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        if(OrderSymbol() != gTrailingStops[index].symbol) continue;
        
        // Parse order comment to check if it belongs to our GID
        int orderGid;
        string orderChannel;
        if(!ParseOrderCommentFull(OrderComment(), orderGid, orderChannel)) continue;
        if(orderGid != gid || orderChannel != channel) continue;
        
        // Check if order was closed with profit (TP hit) after our last update
        datetime closeTime = OrderCloseTime();
        double profit = OrderProfit();
        
        if(closeTime > gTrailingStops[index].lastUpdate && profit > 0 && closeTime > 0) {
            // Extract the TP level this order was targeting from comment
            // Comment format: GID|CHANNEL|TP1|ORDER_TP
            string comment = OrderComment();
            
            // Parse comment step by step to avoid nested StringFind errors
            int firstPipe = StringFind(comment, "|");
            if(firstPipe >= 0) {
                int secondPipe = StringFind(comment, "|", firstPipe + 1);
                if(secondPipe >= 0) {
                    int thirdPipe = StringFind(comment, "|", secondPipe + 1);
                    if(thirdPipe >= 0) {
                        string orderTPStr = StringSubstr(comment, thirdPipe + 1);
                        double orderTP = StrToDouble(orderTPStr);
                        
                        if(debugMode) PrintLog(eaName + ": Analyzing closed order TP: " + DoubleToString(orderTP, MarketInfo(gTrailingStops[index].symbol, MODE_DIGITS)) + 
                                              " Profit: " + DoubleToString(profit, 2));
                        
                        // Find which TP level this corresponds to
                        for(int tp = 0; tp < gTrailingStops[index].tpCount && tp < 20; tp++) {
                            double diff = MathAbs(orderTP - gTrailingStops[index].tpLevels[tp]);
                            if(debugMode) PrintLog(eaName + ": Comparing with TP[" + IntegerToString(tp+1) + "] = " + 
                                                  DoubleToString(gTrailingStops[index].tpLevels[tp], MarketInfo(gTrailingStops[index].symbol, MODE_DIGITS)) + 
                                                  " Diff: " + DoubleToString(diff, 8));
                            if(diff <= 0.00001) {
                                int detectedLevel = tp + 1; // TP levels are 1-indexed
                                newTpHitLevel = MathMax(newTpHitLevel, detectedLevel);
                                if(debugMode) PrintLog(eaName + ": MATCH FOUND! TP" + IntegerToString(detectedLevel) + " hit, new level: " + IntegerToString(newTpHitLevel));
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    
    // If new TP level was hit, update SL for remaining orders
    if(newTpHitLevel > gTrailingStops[index].tpHitLevel) {
        gTrailingStops[index].tpHitLevel = newTpHitLevel;
        gTrailingStops[index].lastUpdate = TimeCurrent();
        
        double newSL = CalculateNewSL(gTrailingStops[index].tpHitLevel, gTrailingStops[index].originalEntry, gTrailingStops[index].originalSL, 
                                     gTrailingStops[index].tpLevels, gTrailingStops[index].tpCount, gTrailingStops[index].symbol, gTrailingStops[index].isBuy);
        
        PrintLog(eaName + ": TP" + IntegerToString(newTpHitLevel) + " hit for GID:" + IntegerToString(gid) + 
               " - Moving SL to:" + DoubleToString(newSL, MarketInfo(gTrailingStops[index].symbol, MODE_DIGITS)));
        
        // Update SL for all remaining open orders of this GID
        for(int o = 0; o < OrdersTotal(); o++)
        {
            if(!OrderSelect(o, SELECT_BY_POS, MODE_TRADES)) continue;
            if(OrderMagicNumber() != MAGIC_NUMBER) continue;
            if(OrderSymbol() != gTrailingStops[index].symbol) continue;
            
            int orderGid;
            string orderChannel;
            if(!ParseOrderCommentFull(OrderComment(), orderGid, orderChannel)) continue;
            if(orderGid != gid || orderChannel != channel) continue;
            
            // Only update market positions (not pending orders)
            if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
            
            double currentSL = OrderStopLoss();
            if(MathAbs(currentSL - newSL) > SL_MODIFY_THRESHOLD)
            {
                bool modified = OrderModify(OrderTicket(), OrderOpenPrice(), newSL, 
                                          OrderTakeProfit(), 0, clrOrange);
                if(modified) {
                    PrintLog(eaName + ": Trailing SL updated for ticket:" + IntegerToString(OrderTicket()) +
                           " GID:" + IntegerToString(gid) + " from " + 
                           DoubleToString(currentSL, MarketInfo(gTrailingStops[index].symbol, MODE_DIGITS)) + 
                           " to " + DoubleToString(newSL, MarketInfo(gTrailingStops[index].symbol, MODE_DIGITS)));
                } else {
                    PrintLog(eaName + ": Failed to update trailing SL for ticket:" + IntegerToString(OrderTicket()) +
                           " Error:" + IntegerToString(GetLastError()));
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| CalculateNewSL: Calculate new SL based on TP hit level         |
//+------------------------------------------------------------------+
double CalculateNewSL(int tpHitLevel, double originalEntry, double originalSL, 
                     double &tpLevels[], int tpCount, string symbol, bool isBuy)
{
    if(tpHitLevel <= 0 || tpCount <= 0) return originalSL;
    
    int digits = MarketInfo(symbol, MODE_DIGITS);
    double newSL = originalSL;
    
    switch(tpHitLevel) {
        case 1: // TP1 hit -> move SL to (SL+entry)/2
            newSL = (originalSL + originalEntry) / 2.0;
            break;
            
        case 2: // TP2 hit -> move SL to TP1
            newSL = tpLevels[0];
            break;
            
        case 3: // TP3 hit -> move SL to TP2
            if(tpCount > 1) newSL = tpLevels[1];
            else return originalSL;
            break;
            
        case 4: // TP4 hit -> move SL to TP3
            if(tpCount > 2) newSL = tpLevels[2];
            else return originalSL;
            break;
            
        default: // TP5+ hit -> move SL to previous TP level
            if(tpHitLevel > 4 && tpHitLevel <= tpCount) {
                int targetIndex = tpHitLevel - 2; // Previous TP level (0-indexed)
                if(targetIndex >= 0 && targetIndex < tpCount && targetIndex < 20) {
                    newSL = tpLevels[targetIndex];
                } else return originalSL;
            } else return originalSL;
            break;
    }
    
    // Validate SL direction for BUY/SELL - ensure it moves in favorable direction only
    if(isBuy) {
        // For BUY: new SL should be higher than current SL (more favorable)
        // But allow equal SL in case of breakeven moves
        if(newSL < originalSL) {
            if(debugMode) PrintLog(eaName + ": BUY - New SL " + DoubleToString(newSL, digits) + 
                                  " would be worse than original " + DoubleToString(originalSL, digits) + ", keeping original");
            return originalSL;
        }
    } else {
        // For SELL: new SL should be lower than current SL (more favorable)  
        // But allow equal SL in case of breakeven moves
        if(newSL > originalSL) {
            if(debugMode) PrintLog(eaName + ": SELL - New SL " + DoubleToString(newSL, digits) + 
                                  " would be worse than original " + DoubleToString(originalSL, digits) + ", keeping original");
            return originalSL;
        }
    }
    
    if(debugMode) PrintLog(eaName + ": SL calculation successful - Level:" + IntegerToString(tpHitLevel) + 
                          " Original:" + DoubleToString(originalSL, digits) + 
                          " New:" + DoubleToString(newSL, digits) + 
                          " Direction:" + (isBuy ? "BUY" : "SELL"));
    
    return NormalizeDouble(newSL, digits);
}

//+------------------------------------------------------------------+
//| GetTrailingStopIndex: Find index of GID in trailing stop array |
//+------------------------------------------------------------------+
int GetTrailingStopIndex(int gid, string channel)
{
    for(int i = 0; i < gTrailingStopsCount; i++) {
        if(gTrailingStops[i].gid == gid && gTrailingStops[i].channel == channel) {
            return i;
        }
    }
    return -1;
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
