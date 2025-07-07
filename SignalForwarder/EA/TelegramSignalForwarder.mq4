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
//|--- Triggered Group Structure                                    |
//+------------------------------------------------------------------+
struct TriggeredGroup {
    int gid;
    int triggeredTPLevel;  // Which TP level was triggered (1-6)
    datetime triggerTime;  // When it was triggered
};

//+------------------------------------------------------------------+
//|--- Global State Variables                                       |
//+------------------------------------------------------------------+
TriggeredGroup triggeredGroups[MAX_GROUPS];    // Array of triggered groups with TP levels
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
                       double &stopLoss, double &tpLevels[],
                       int &groupId, string &channelName);
void    UpdateExistingOrdersSL(string symbol, string signalType, double newSL, string channelName);
void    SendOrders(string signalType, string symbol,
                         double entryPrice, double stopLoss, double &tpLevels[],
                         int groupId, string channelName);
int     GetOrderType(string signalType);
void    HandleTrailingStopsDynamic();
void    ProcessExternalSLUpdates();
bool    ParseOrderComment(string comment, int &groupId, double &signalSL);
bool    ParseOrderCommentFull(string comment, int &groupId, double &signalSL, string &channelName);
bool    ParseOrderCommentDynamic(string comment, int &groupId, double &signalSL, 
                                 string &channelName, double &tpLevels[]);
int     GetHighestTriggeredTP(double closePrice, double &tpLevels[], int orderType, double tolerance);
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

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int init()
{
    // Initialize triggered groups array
    for(int i = 0; i < MAX_GROUPS; i++) {
        triggeredGroups[i].gid = -1;
        triggeredGroups[i].triggeredTPLevel = 0;
        triggeredGroups[i].triggerTime = 0;
    }
    ArrayInitialize(modifiedTickets, -1);
    triggeredCount   = 0;
    modifiedCount    = 0;
    lastTrailingScan = 0;

    // Use chart's expert name if provided
    string customName = WindowExpertName();
    if(StringLen(customName) > 0)
        eaName = customName;

    if(debugMode)
        Print(eaName, ": Initialized with dynamic TP support");

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
    double entryPrice, stopLoss;
    double tpLevels[]; // Dynamic array for TP levels
    int    groupId;

    if(IsTradeAllowed() && IsConnected() && !IsStopped())
    {
        // Process new signal
        if(ReadSignalFile(signalType, symbol, entryPrice,
                          stopLoss, tpLevels, groupId, channelName))
        {
            if(debugMode)
                Print(eaName, ": Processing signal with ", IntegerToString(ArraySize(tpLevels)), 
                      " TP levels from channel '", channelName, "' - GID=", IntegerToString(groupId));
                
            Print(eaName, ": >>> Calling UpdateExistingOrdersSL with symbol=", symbol, 
                  " signalType=", signalType, " stopLoss=", DoubleToString(stopLoss, 5), 
                  " channelName='", channelName, "'");
            UpdateExistingOrdersSL(symbol, signalType, stopLoss, channelName);
            SendOrders(signalType, symbol,
                             entryPrice, stopLoss, tpLevels,
                             groupId, channelName);
        }
        // Apply dynamic trailing stop logic
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
                    double &stopLoss, double &tpLevels[],
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

    // 4) TP levels - dynamic parsing
    string tpsArr[];
    int tpCount = StringSplit(parts[4], ',', tpsArr);
    
    if(tpCount < 1 || tpCount > 6) {
        Print(eaName, ": Invalid TP count (", IntegerToString(tpCount), "), expected 1-6 levels");
        return(false);
    }
    
    // Resize tpLevels array and populate
    ArrayResize(tpLevels, tpCount);
    int digits = MarketInfo(symbol, MODE_DIGITS);
    
    for(int i = 0; i < tpCount; i++) {
        if(!IsValidDouble(tpsArr[i])) {
            Print(eaName, ": Invalid TP", IntegerToString(i+1), " value: '", tpsArr[i], "'");
            return(false);
        }
        
        tpLevels[i] = NormalizeDouble(StrToDouble(tpsArr[i]), digits);
        
        // Validate TP sequence (must be ascending for BUY, descending for SELL)
        if(i > 0) {
            bool validSequence = (signalType == "BUY") ? (tpLevels[i] > tpLevels[i-1]) 
                                                        : (tpLevels[i] < tpLevels[i-1]);
            if(!validSequence) {
                Print(eaName, ": Invalid TP sequence at TP", IntegerToString(i+1), 
                      " - expected ", signalType == "BUY" ? "ascending" : "descending", " order");
                return(false);
            }
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

    if(debugMode) {
        string tpDebug = "";
        for(int i = 0; i < tpCount; i++) {
            tpDebug += " TP" + IntegerToString(i+1) + ":" + DoubleToString(tpLevels[i], digits);
        }
        Print(eaName, ": Parsed ", IntegerToString(tpCount), " TP levels:", tpDebug, 
              " GID=", IntegerToString(groupId), " from channel '", channelName, "'");
    }

    return(true);
}

//+------------------------------------------------------------------+
//| UpdateExistingOrdersSL: Update SL of existing orders from same channel |
//+------------------------------------------------------------------+
void UpdateExistingOrdersSL(string symbol, string signalType, double newSL, string channelName)
{
    Print(eaName, ": === UPDATE EXISTING ORDERS SL START ===");
    Print(eaName, ": Looking for orders - symbol=", symbol, " signalType=", signalType, 
          " newSL=", DoubleToString(newSL, 5), " channel='", channelName, "'");
    
    // More flexible order type matching - match both market and limit orders
    bool isBuySignal = (signalType == "BUY");
    int ordersFound = 0;
    int ordersUpdated = 0;
    
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
        
        // Check symbol match
        if(OrderSymbol() != symbol) {
          if (debugMode) Print(eaName, ": Ignoring order at index ", IntegerToString(i), " - symbol mismatch (", OrderSymbol(), " vs ", symbol, ")");
          continue;
        }
        
        // Check order type compatibility (both market and limit orders)
        int orderType = OrderType();
        bool isOrderBuy = (orderType == OP_BUY || orderType == OP_BUYLIMIT);
        bool isOrderSell = (orderType == OP_SELL || orderType == OP_SELLLIMIT);
        
        if((isBuySignal && !isOrderBuy) || (!isBuySignal && !isOrderSell)) {
          if (debugMode) Print(eaName, ": Ignoring order at index ", IntegerToString(i), " - order type mismatch (orderType=", IntegerToString(orderType), " isBuySignal=", (isBuySignal ? "YES" : "NO"), ")");
          continue;
        }

        Print(eaName, ": Found potential order to update - ticket=", IntegerToString(OrderTicket()), 
              " symbol=", OrderSymbol(), " type=", IntegerToString(orderType), " comment=", OrderComment());

        // Parse the order's comment to get channel information
        int orderGid;
        double orderSL;
        string orderChannelName;
        if(!ParseOrderCommentFull(OrderComment(), orderGid, orderSL, orderChannelName)) {
            Print(eaName, ": Failed to parse order comment for ticket ", IntegerToString(OrderTicket()), ": ", OrderComment());
            continue;
        }

        Print(eaName, ": Parsed order comment - GID=", IntegerToString(orderGid), 
              " orderChannel='", orderChannelName, "' signalChannel='", channelName, "'");

        // More flexible channel matching - handle short format vs full names
        bool channelMatch = false;
        if(orderChannelName == channelName) {
            channelMatch = true;
        } else if(StringLen(orderChannelName) == 2 && StringLen(channelName) >= 2) {
            // Short format in comment vs full channel name in signal
            channelMatch = (StringSubstr(channelName, 0, 2) == orderChannelName);
        } else if(StringLen(channelName) == 2 && StringLen(orderChannelName) >= 2) {
            // Short format in signal vs full channel name in comment
            channelMatch = (StringSubstr(orderChannelName, 0, 2) == channelName);
        }
        
        if(!channelMatch) {
            Print(eaName, ": Ignoring order ticket ", IntegerToString(OrderTicket()), 
                                " - channel mismatch (order='", orderChannelName, "', signal='", channelName, "')");
            continue;
        }

        ordersFound++;
        Print(eaName, ": Order matches criteria - checking SL update...");

        double currSL = OrderStopLoss();
        Print(eaName, ": Current SL=", DoubleToString(currSL, 5), " New SL=", DoubleToString(newSL, 5), 
              " Difference=", DoubleToString(MathAbs(currSL - newSL), 8), " Threshold=", DoubleToString(SL_MODIFY_THRESHOLD, 8));
              
        if(MathAbs(currSL - newSL) > SL_MODIFY_THRESHOLD)
        {
            double openP = OrderOpenPrice();
            double tp    = OrderTakeProfit();
            
            // Validate new SL against broker requirements
            RefreshRates();
            double ask = MarketInfo(symbol, MODE_ASK);
            double bid = MarketInfo(symbol, MODE_BID);
            
            Print(eaName, ": Validating new SL - ask=", DoubleToString(ask, 5), " bid=", DoubleToString(bid, 5));
            
            if(!CheckStopLevel(symbol, orderType, newSL, ask, bid)) {
                Print(eaName, ": ❌ New SL failed broker validation for ticket=", IntegerToString(OrderTicket()));
                
                // Try to adjust SL to meet broker requirements
                double point = MarketInfo(symbol, MODE_POINT);
                int stopLevel = MarketInfo(symbol, MODE_STOPLEVEL);
                double minDist = MathMax(stopLevel * point, point);
                double adjustedSL = newSL;
                
                if(isOrderBuy) {
                    // For BUY orders, SL must be below bid with minimum distance
                    double maxSL = bid - minDist;
                    if(newSL > maxSL) {
                        adjustedSL = NormalizeDouble(maxSL, MarketInfo(symbol, MODE_DIGITS));
                        Print(eaName, ": Adjusted SL to ", DoubleToString(adjustedSL, 5), " (maxSL for BUY)");
                    }
                } else {
                    // For SELL orders, SL must be above ask with minimum distance  
                    double minSL = ask + minDist;
                    if(newSL < minSL) {
                        adjustedSL = NormalizeDouble(minSL, MarketInfo(symbol, MODE_DIGITS));
                        Print(eaName, ": Adjusted SL to ", DoubleToString(adjustedSL, 5), " (minSL for SELL)");
                    }
                }
                
                // Re-validate adjusted SL
                if(!CheckStopLevel(symbol, orderType, adjustedSL, ask, bid)) {
                    Print(eaName, ": ❌ Even adjusted SL failed validation, skipping ticket ", IntegerToString(OrderTicket()));
                    continue;
                }
                newSL = adjustedSL;
            }
            
            Print(eaName, ": Attempting to modify order ticket=", IntegerToString(OrderTicket()),
                  " openPrice=", DoubleToString(openP, 5), " newSL=", DoubleToString(newSL, 5), " TP=", DoubleToString(tp, 5));
            
            bool ok = OrderModify(OrderTicket(), openP, newSL, tp, 0, clrBlue);
            if(ok) {
                ordersUpdated++;
                Print(eaName, ": ✅ Successfully updated SL for ticket=", IntegerToString(OrderTicket()), 
                      " from channel '", channelName, "' (", DoubleToString(currSL, MarketInfo(symbol, MODE_DIGITS)), 
                      " -> ", DoubleToString(newSL, MarketInfo(symbol, MODE_DIGITS)), ")");
            } else {
                Print(eaName, ": ❌ SL update failed for ticket=", IntegerToString(OrderTicket()),
                      " error=", IntegerToString(GetLastError()));
            }
        } else {
            Print(eaName, ": SL change too small for ticket ", IntegerToString(OrderTicket()), 
                                " - current=", DoubleToString(currSL, MarketInfo(symbol, MODE_DIGITS)), 
                                " new=", DoubleToString(newSL, MarketInfo(symbol, MODE_DIGITS)));
        }
    }
    
    Print(eaName, ": === UPDATE EXISTING ORDERS SL COMPLETE ===");
    Print(eaName, ": Orders found=", IntegerToString(ordersFound), " Orders updated=", IntegerToString(ordersUpdated));
}

//+------------------------------------------------------------------+
//| SendOrders: Place three market or limit orders with SL & TP        |
//+------------------------------------------------------------------+
void SendOrders(string signalType, string symbol,
                      double entryPrice, double stopLoss, double &tpLevels[],
                      int groupId, string channelName)
{
    int tpCount = ArraySize(tpLevels);
    if(tpCount == 0) {
        Print(eaName, ": No TP levels provided, skipping orders");
        return;
    }

    int digits    = MarketInfo(symbol, MODE_DIGITS);
    double point  = MarketInfo(symbol, MODE_POINT);
    int stopLevel = MarketInfo(symbol, MODE_STOPLEVEL);

    RefreshRates();
    double ask = MarketInfo(symbol, MODE_ASK);
    double bid = MarketInfo(symbol, MODE_BID);
    double price;
    bool shouldBuy = signalType == "BUY";
    double midPrice = (entryPrice + tpLevels[0]) / 2.0; // Use TP1 for midpoint calculation
    
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
    bool missedTP1 = (shouldBuy) ? bid >= tpLevels[0] : ask <= tpLevels[0];

    // Determine which SL to use
    double rawSL, fallbackSL;
    if(missedTP1) {
        rawSL = NormalizeDouble(entryPrice, digits);
        fallbackSL = rawSL;
    } else {
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

    // Normalize all TP levels and apply minimum distance
    for(int j = 0; j < tpCount; j++) {
        tpLevels[j] = NormalizeDouble(tpLevels[j], digits);
        double dist = MathAbs(tpLevels[j] - entryPrice);
        if(dist < minDist)
            tpLevels[j] = (shouldBuy) ? price + minDist : price - minDist;
        tpLevels[j] = NormalizeDouble(tpLevels[j], digits);
    }

    Print(eaName, ": Sending ", IntegerToString(tpCount), " orders for GID=", IntegerToString(groupId),
          " from channel '", channelName, "'",
          " Missed TP1=", missedTP1 ? "Yes" : "No",
          " Using SL=", DoubleToString(rawSL, digits));

    int slippage = 5;
    color cols[3] = { clrBlue, clrGreen, clrRed };
    double lotSize = (symbol == "BTCUSD") ? fixedLotSizeBitcoin :
                        (symbol == "XAUUSD") ? fixedLotSizeGold : fixedLotSize;

    // Create orders for each TP level
    for(int k = 0; k < tpCount; k++) {
        RefreshRates();
        
        // ULTRA SHORT comment for MT4 31 character limit
        // Format: G{GID}|{Channel}|{SL}|{Entry}
        string comment = "G" + IntegerToString(groupId) + "|" + StringSubstr(channelName, 0, 2);
        if(StringLen(comment) < 20) { // Only add if we have space
            comment += "|" + DoubleToString(rawSL, 3);
            if(StringLen(comment) < 25) {
                comment += "|" + DoubleToString(entryPrice, 3); // Use ENTRY price, not TP1
            }
        }
    
        Print(eaName, ": Order[", IntegerToString(k+1), "/" , IntegerToString(tpCount), "] parameters: ",
              "Symbol=", symbol, " Type=", IntegerToString(orderType), " Lots=", DoubleToString(lotSize, 2),
              " Price=", DoubleToString(price, digits), " SL=", DoubleToString(rawSL, digits),
              " TP=", DoubleToString(tpLevels[k], digits));
        Print(eaName, ": Comment length=", IntegerToString(StringLen(comment)), " Comment=[", comment, "]");

        color orderColor = (k < 3) ? cols[k] : clrBlue; // Use default color for TP4+
        int ticket = OrderSend(symbol, orderType, lotSize, price, slippage,
                               rawSL, tpLevels[k], comment, MAGIC_NUMBER, 0, orderColor);
                               
        if(ticket < 0) {
            Print(eaName, ": Error creating order[", IntegerToString(k+1), "] ticket=", IntegerToString(ticket), " error=", IntegerToString(GetLastError()));
            
            if(GetLastError() == ERR_INVALID_STOPS) {
                RefreshRates();
                Print(eaName, ": Retrying with fallback SL=", DoubleToString(fallbackSL, digits));
                ticket = OrderSend(symbol, orderType, lotSize, price, slippage,
                                   fallbackSL, tpLevels[k], comment, MAGIC_NUMBER, 0, orderColor);
            }
        }
        
        if(ticket >= 0) {
            Print(eaName, ": Order[", IntegerToString(k+1), "] created - ticket=", IntegerToString(ticket));
        }
    }
}

//+------------------------------------------------------------------+
//| HandleTrailingStopsDynamic: Dynamic trailing stop logic         |
//+------------------------------------------------------------------+
void HandleTrailingStopsDynamic()
{
    datetime now = TimeCurrent();
    if(now - lastTrailingScan < trailingCheckIntervalSec) return;
    lastTrailingScan = now;

    int historyTotal = OrdersHistoryTotal();
    Print(eaName, ": Dynamic TS checking ", IntegerToString(historyTotal), " history orders, ", IntegerToString(OrdersTotal()), " open orders");

    // Reset triggered groups for this scan
    triggeredCount = 0;
    for(int i = 0; i < MAX_GROUPS; i++) {
        triggeredGroups[i].gid = -1;
        triggeredGroups[i].triggeredTPLevel = 0;
        triggeredGroups[i].triggerTime = 0;
    }

    // Scan history to find triggered TP levels
    for(int i = historyTotal-1; i >= 0; i--) {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        
        double closeP = OrderClosePrice();
        double tp = OrderTakeProfit();
        double tol = triggerTolerancePips * MarketInfo(OrderSymbol(), MODE_POINT);
        
        bool triggered = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT)
                        ? (closeP >= tp - tol)
                        : (closeP <= tp + tol);
        if(!triggered) continue;
        
        int gid;
        double sl;
        string channelName;
        double tpLevels[];
        
        if(!ParseOrderCommentDynamic(OrderComment(), gid, sl, channelName, tpLevels)) continue;
        
        // Determine which TP level was triggered
        int triggeredTPLevel = GetHighestTriggeredTP(closeP, tpLevels, OrderType(), tol);
        
        if(triggeredTPLevel == 0) continue;
        
        Print(eaName, ": GID ", IntegerToString(gid), " triggered TP", IntegerToString(triggeredTPLevel));
        AddTriggeredGroup(gid, triggeredTPLevel);
    }
    
    if(triggeredCount == 0) return;
    
    // Process open orders
    int openTotal = OrdersTotal();
    for(int m = 0; m < openTotal; m++) {
        if(!OrderSelect(m, SELECT_BY_POS, MODE_TRADES)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        
        int ticket = OrderTicket();
        
        if(HasBeenModified(ticket)) continue;
        
        int gid;
        double sl;
        string channelName;
        double tpLevels[];
        
        if(!ParseOrderCommentDynamic(OrderComment(), gid, sl, channelName, tpLevels)) continue;
        
        // Find if this order belongs to any triggered group
        int triggeredLevel = 0;
        for(int n = 0; n < triggeredCount; n++) {
            if(triggeredGroups[n].gid == gid) {
                triggeredLevel = triggeredGroups[n].triggeredTPLevel;
                break;
            }
        }
        
        if(triggeredLevel == 0) continue;
        
        // Calculate new SL based on triggered TP level
        double newSL = 0;
        double currentSL = OrderStopLoss();
        double openP = OrderOpenPrice();
        int d = MarketInfo(OrderSymbol(), MODE_DIGITS);
        
        Print(eaName, ": Processing ticket ", IntegerToString(ticket), " - TP", IntegerToString(triggeredLevel), " triggered");
        
        if(triggeredLevel == 1) {
            // TP1 triggered -> move SL to break-even (entry price)
            string orderComment = OrderComment();
            double entryFromComment = 0;
            
            if(StringGetCharacter(orderComment, 0) == 'G') {
                // Short format: G{GID}|{Channel}|{SL}|{Entry}
                string parts[];
                int partCount = StringSplit(orderComment, '|', parts);
                if(partCount >= 4) {
                    entryFromComment = StrToDouble(parts[3]);
                }
            }
            
            // Use entry from comment if available, otherwise fall back to OrderOpenPrice
            if(entryFromComment > 0) {
                newSL = NormalizeDouble(entryFromComment, d);
                Print(eaName, ": TP1 hit - moving SL to break-even: ", DoubleToString(newSL, d));
            } else {
                newSL = NormalizeDouble(openP, d);
                Print(eaName, ": TP1 hit - moving SL to break-even (OrderOpenPrice): ", DoubleToString(newSL, d));
            }
        } else if(triggeredLevel >= 2) {
            // TP2+ triggered -> move SL to previous TP level
            double targetSL = 0;
            
            // Validate array size before accessing
            if(ArraySize(tpLevels) == 0) {
                Print(eaName, ": ERROR - tpLevels array empty! Attempting emergency reconstruction for GID ", IntegerToString(gid));
                ReconstructTPLevelsFromOrders(gid, tpLevels);
            }
            
            if(triggeredLevel == 2) {
                // TP2 hit -> move SL to TP1 (which is tpLevels[0])
                if(ArraySize(tpLevels) >= 1) {
                    targetSL = tpLevels[0]; // TP1
                    Print(eaName, ": TP2 hit, moving SL to TP1=", DoubleToString(targetSL, d));
                } else {
                    Print(eaName, ": ERROR - Cannot access TP1, attempting emergency estimation...");
                    
                    // Emergency fallback: try to estimate TP1 based on remaining open orders
                    double emergencyTP1 = 0;
                    
                    for(int emerIdx = 0; emerIdx < OrdersTotal(); emerIdx++) {
                        if(!OrderSelect(emerIdx, SELECT_BY_POS, MODE_TRADES)) continue;
                        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
                        
                        string emerComment = OrderComment();
                        int emerGid; double emerSL; string emerChannel;
                        if(!ParseOrderCommentFull(emerComment, emerGid, emerSL, emerChannel)) continue;
                        if(emerGid != gid) continue;
                        
                        double emerTP = OrderTakeProfit();
                        if(emerTP > 0) {
                            if(emergencyTP1 == 0) {
                                emergencyTP1 = emerTP;
                            } else {
                                // For BUY orders, TP1 should be the lowest TP
                                // For SELL orders, TP1 should be the highest TP
                                bool isBuy = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT);
                                if((isBuy && emerTP < emergencyTP1) || (!isBuy && emerTP > emergencyTP1)) {
                                    emergencyTP1 = emerTP;
                                }
                            }
                        }
                    }
                    
                    if(emergencyTP1 > 0) {
                        targetSL = emergencyTP1;
                        Print(eaName, ": Emergency fallback successful - using estimated TP1=", DoubleToString(targetSL, d));
                    } else {
                        Print(eaName, ": Emergency fallback failed - no TP1 could be estimated");
                    }
                }
            } else if(triggeredLevel >= 3) {
                // TP3+ hit -> move SL to previous TP level
                int previousTPIndex = triggeredLevel - 2; // For TP3: index 1 = TP2, etc.
                if(ArraySize(tpLevels) > previousTPIndex) {
                    targetSL = tpLevels[previousTPIndex];
                    Print(eaName, ": TP", IntegerToString(triggeredLevel), " hit, moving SL to TP", IntegerToString(triggeredLevel-1), "=", DoubleToString(targetSL, d));
                } else {
                    Print(eaName, ": ERROR - Cannot access TP", IntegerToString(triggeredLevel-1), " from array, size=", IntegerToString(ArraySize(tpLevels)));
                }
            }
            
            if(targetSL <= 0) {
                Print(eaName, ": ERROR - Failed to determine valid target SL for TP", IntegerToString(triggeredLevel));
            } else {
                // Only move if current SL is worse than target
                bool shouldMove = false;
                if(OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT) {
                    shouldMove = (currentSL < targetSL);
                } else {
                    shouldMove = (currentSL > targetSL);
                }
                
                if(shouldMove) {
                    newSL = NormalizeDouble(targetSL, d);
                    Print(eaName, ": Moving SL to TP", IntegerToString(triggeredLevel-1), ": ", DoubleToString(newSL, d));
                } else {
                    Print(eaName, ": SL already better than target, keeping current SL");
                }
            }
        } else {
            Print(eaName, ": Invalid triggered level ", IntegerToString(triggeredLevel));
        }
        
        if(newSL <= 0) continue;
        
        // Validate and apply new SL
        RefreshRates();
        double ask = MarketInfo(OrderSymbol(), MODE_ASK);
        double bid = MarketInfo(OrderSymbol(), MODE_BID);
        
        if(!CheckFreezeLevel(OrderSymbol(), openP, ask, bid)) {
            Print(eaName, ": Freeze level check failed for ticket ", IntegerToString(ticket));
            continue;
        }
        
        if(!CheckStopLevel(OrderSymbol(), OrderType(), newSL, ask, bid)) {
            Print(eaName, ": Stop level check failed, attempting adjustment...");
            
            // Try to adjust SL to meet minimum distance requirements
            double point = MarketInfo(OrderSymbol(), MODE_POINT);
            int stopLevel = MarketInfo(OrderSymbol(), MODE_STOPLEVEL);
            double minDist = MathMax(stopLevel * point, point);
            
            if(OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT) {
                double maxSL = bid - minDist;
                if(newSL > maxSL) {
                    newSL = NormalizeDouble(maxSL, d);
                }
            } else {
                double minSL = ask + minDist;
                if(newSL < minSL) {
                    newSL = NormalizeDouble(minSL, d);
                }
            }
            
            // Re-validate adjusted SL
            if(!CheckStopLevel(OrderSymbol(), OrderType(), newSL, ask, bid)) {
                Print(eaName, ": Even adjusted SL failed validation, skipping ticket ", IntegerToString(ticket));
                continue;
            }
        }
        
        // CRITICAL FIX: Ensure the correct order is selected before OrderModify
        if(!OrderSelect(ticket, SELECT_BY_TICKET)) {
            Print(eaName, ": Failed to re-select ticket ", IntegerToString(ticket), " for modify");
            continue;
        }
        
        double currentTP = OrderTakeProfit();
        
        if(OrderModify(ticket, openP, newSL, currentTP, 0, clrMagenta)) {
            Print(eaName, ": SUCCESS - Modified ticket ", IntegerToString(ticket), " SL to ", DoubleToString(newSL, d));
            MarkAsModified(ticket);
        } else {
            Print(eaName, ": FAILED to modify ticket ", IntegerToString(ticket), " err=", IntegerToString(GetLastError()));
        }
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
        // Check if this order belongs to the target GID (both formats)
        string orderComment = OrderComment();
        bool belongsToGID = false;
        
        if(StringFind(orderComment, "GID:" + IntegerToString(gid)) >= 0) {
            belongsToGID = true; // Old format
        } else if(StringFind(orderComment, "G" + IntegerToString(gid) + "|") >= 0) {
            belongsToGID = true; // New short format
        }
        
        if(!belongsToGID) {
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
    // New short format: G123|CH|1.234|1.235
    // Old format: GID:1234|SL:1.2345 (for backward compatibility)
    
    if(StringLen(comment) == 0) {
        if(debugMode) Print(eaName, ": Empty comment");
        return(false);
    }
    
    // Check for new short format (starts with G)
    if(StringGetCharacter(comment, 0) == 'G') {
        string parts[];
        int partCount = StringSplit(comment, '|', parts);
        
        if(partCount < 2) {
            if(debugMode) Print(eaName, ": Invalid short format: ", comment);
            return(false);
        }
        
        // Extract GID (remove G prefix)
        groupId = StrToInteger(StringSubstr(parts[0], 1));
        if(groupId <= 0) {
            if(debugMode) Print(eaName, ": Invalid GID in short format: ", comment);
            return(false);
        }
        
        // Extract channel (if available)
        channelName = (partCount > 1) ? parts[1] : "SHORT";
        
        // Extract SL (if available)
        signalSL = (partCount > 2) ? StrToDouble(parts[2]) : 0.0;
        
        if(debugMode) {
            Print(eaName, ": Parsed short comment - GID:", IntegerToString(groupId), 
                  " Channel:", channelName, " SL:", DoubleToString(signalSL, 5));
        }
        
        return(true);
    }
    
    // Fallback to old format for backward compatibility
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
//| ParseOrderCommentDynamic: extracts available data from comment  |
//+------------------------------------------------------------------+
bool ParseOrderCommentDynamic(string comment, int &groupId, double &signalSL, 
                              string &channelName, double &tpLevels[])
{
    // For short format, we'll reconstruct TP levels from actual orders later
    // This function just extracts basic info
    
    ArrayResize(tpLevels, 0); // Clear array
    
    if(StringLen(comment) == 0) {
        if(debugMode) Print(eaName, ": Empty comment in dynamic parse");
        return(false);
    }
    
    // Use the existing ParseOrderCommentFull for basic parsing
    if(!ParseOrderCommentFull(comment, groupId, signalSL, channelName)) {
        return(false);
    }
    
    // For the short format, we can't store all TP levels in comment
    // We'll reconstruct them by scanning all orders with same GID
    if(StringGetCharacter(comment, 0) == 'G') {
        // Short format - get TP levels from actual orders
        ReconstructTPLevelsFromOrders(groupId, tpLevels);
    } else {
        // Try to extract TP levels from old long format
        ExtractTPLevelsFromLongComment(comment, tpLevels);
    }
    
    if(debugMode) {
        string tpDebug = "";
        for(int i = 0; i < ArraySize(tpLevels); i++) {
            tpDebug += " TP" + IntegerToString(i+1) + ":" + DoubleToString(tpLevels[i], 5);
        }
        Print(eaName, ": Parsed dynamic comment - GID:", IntegerToString(groupId), " Channel:", channelName, " SL:", DoubleToString(signalSL, 5), tpDebug);
    }
    
    return(true);
}

//+------------------------------------------------------------------+
//| ReconstructTPLevelsFromOrders: rebuild TP array from live orders|
//+------------------------------------------------------------------+
void ReconstructTPLevelsFromOrders(int targetGroupId, double &tpLevels[])
{
    ArrayResize(tpLevels, 0);
    double tempTPs[];
    int tpCount = 0;
    
    // Scan all open orders with same GID
    for(int i = 0; i < OrdersTotal(); i++) {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        
        // Check if this order belongs to our group
        string comment = OrderComment();
        int gid; double sl; string channel;
        if(!ParseOrderCommentFull(comment, gid, sl, channel)) continue;
        if(gid != targetGroupId) continue;
        
        double tp = OrderTakeProfit();
        if(tp <= 0) continue;
        
        // Add to temp array if not already there
        bool found = false;
        for(int j = 0; j < tpCount; j++) {
            if(MathAbs(tempTPs[j] - tp) < 0.00001) {
                found = true;
                break;
            }
        }
        
        if(!found) {
            ArrayResize(tempTPs, tpCount + 1);
            tempTPs[tpCount] = tp;
            tpCount++;
        }
    }
    
    // Also scan recent history orders to capture recently closed TP levels
    datetime cutoffTime = TimeCurrent() - 7200; // Look back 2 hours
    
    for(int i = OrdersHistoryTotal()-1; i >= 0; i--) {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        if(OrderCloseTime() < cutoffTime) break; // Stop if too old
        
        // Check if this order belongs to our group
        string comment = OrderComment();
        int gid; double sl; string channel;
        if(!ParseOrderCommentFull(comment, gid, sl, channel)) continue;
        if(gid != targetGroupId) continue;
        
        double tp = OrderTakeProfit();
        if(tp <= 0) continue;
        
        // Add to temp array if not already there
        bool found = false;
        for(int j = 0; j < tpCount; j++) {
            if(MathAbs(tempTPs[j] - tp) < 0.00001) {
                found = true;
                break;
            }
        }
        
        if(!found) {
            ArrayResize(tempTPs, tpCount + 1);
            tempTPs[tpCount] = tp;
            tpCount++;
        }
    }
    
    // Sort TP levels properly based on order type
    if(tpCount > 1) {
        // For reconstructed TPs, we need to determine the order type from one of the orders
        bool isBuyOrder = false;
        if(tpCount > 0) {
            // Get order type from first order we found
            for(int i = 0; i < OrdersTotal(); i++) {
                if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
                if(OrderMagicNumber() != MAGIC_NUMBER) continue;
                
                string comment = OrderComment();
                int gid; double sl; string channel;
                if(!ParseOrderCommentFull(comment, gid, sl, channel)) continue;
                if(gid != targetGroupId) continue;
                
                isBuyOrder = (OrderType() == OP_BUY || OrderType() == OP_BUYLIMIT);
                break;
            }
        }
        
        // Sort TPs: ascending for BUY, descending for SELL
        for(int i = 0; i < tpCount - 1; i++) {
            for(int j = 0; j < tpCount - 1 - i; j++) {
                bool shouldSwap = isBuyOrder ? (tempTPs[j] > tempTPs[j + 1]) : (tempTPs[j] < tempTPs[j + 1]);
                if(shouldSwap) {
                    double temp = tempTPs[j];
                    tempTPs[j] = tempTPs[j + 1];
                    tempTPs[j + 1] = temp;
                }
            }
        }
    }
    
    // Copy to output array
    ArrayResize(tpLevels, tpCount);
    for(int i = 0; i < tpCount; i++) {
        tpLevels[i] = tempTPs[i];
    }
    
    if(tpCount > 0) {
        string tpDebug = "";
        for(int i = 0; i < tpCount; i++) {
            tpDebug += " TP" + IntegerToString(i+1) + ":" + DoubleToString(tpLevels[i], 5);
        }
        Print(eaName, ": Reconstructed TP levels for GID ", IntegerToString(targetGroupId), ":", tpDebug);
    } else {
        Print(eaName, ": WARNING: No TP levels reconstructed for GID ", IntegerToString(targetGroupId));
    }
}

//+------------------------------------------------------------------+
//| ExtractTPLevelsFromLongComment: extract from old long format    |
//+------------------------------------------------------------------+
void ExtractTPLevelsFromLongComment(string comment, double &tpLevels[])
{
    ArrayResize(tpLevels, 0);
    
    // Extract all TP levels from old format dynamically
    int searchPos = 0;
    int tpIndex = 1;
    
    while(searchPos < StringLen(comment)) {
        string tpTag = "|TP" + IntegerToString(tpIndex) + ":";
        int tpPos = StringFind(comment, tpTag, searchPos);
        if(tpPos < 0) break; // No more TP levels found
        
        int tpEndPos = StringFind(comment, "|", tpPos + StringLen(tpTag));
        if(tpEndPos < 0) tpEndPos = StringLen(comment);
        
        double tpValue = StrToDouble(StringSubstr(comment, tpPos + StringLen(tpTag), tpEndPos - tpPos - StringLen(tpTag)));
        
        // Resize array and add TP level
        int currentSize = ArraySize(tpLevels);
        ArrayResize(tpLevels, currentSize + 1);
        tpLevels[currentSize] = tpValue;
        
        searchPos = tpEndPos;
        tpIndex++;
        
        if(tpIndex > 6) break; // Safety limit
    }
}
//+------------------------------------------------------------------+
//| GetHighestTriggeredTP: determines which TP level was hit        |
//+------------------------------------------------------------------+
int GetHighestTriggeredTP(double closePrice, double &tpLevels[], int orderType, double tolerance)
{
    // Returns the highest TP level that was triggered (1-based indexing)
    // Returns 0 if no TP was triggered
    
    int highestTriggered = 0;
    bool isBuy = (orderType == OP_BUY || orderType == OP_BUYLIMIT);
    
    for(int i = 0; i < ArraySize(tpLevels); i++) {
        bool tpTriggered = isBuy ? (closePrice >= tpLevels[i] - tolerance)
                                 : (closePrice <= tpLevels[i] + tolerance);
        if(tpTriggered) {
            highestTriggered = i + 1; // Convert to 1-based indexing
        }
    }
    
    return highestTriggered;
}
//+------------------------------------------------------------------+
//| AddTriggeredGroup: add groupId with TP level if not present     |
//+------------------------------------------------------------------+
void AddTriggeredGroup(int groupId, int tpLevel)
{
    // Check if group already exists - update if higher TP level
    for(int i = 0; i < triggeredCount; i++) {
        if(triggeredGroups[i].gid == groupId) {
            if(triggeredGroups[i].triggeredTPLevel < tpLevel) {
                triggeredGroups[i].triggeredTPLevel = tpLevel;
                triggeredGroups[i].triggerTime = TimeCurrent();
            }
            return;
        }
    }
    
    // Add new triggered group
    if(triggeredCount < MAX_GROUPS) {
        triggeredGroups[triggeredCount].gid = groupId;
        triggeredGroups[triggeredCount].triggeredTPLevel = tpLevel;
        triggeredGroups[triggeredCount].triggerTime = TimeCurrent();
        triggeredCount++;
    }
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
    
    Print(eaName, ": CheckStopLevel - symbol=", symbol, " orderType=", IntegerToString(orderType), 
          " sl=", DoubleToString(sl, digits), " ask=", DoubleToString(ask, digits), 
          " bid=", DoubleToString(bid, digits), " minDist=", DoubleToString(minStopLevelDist, digits));
    
    if(orderType == OP_BUY || orderType == OP_BUYLIMIT) {
         // For buy orders, SL must be below the bid price
         double distance = bid - sl;
         valid = (sl < bid && distance >= minStopLevelDist);
         Print(eaName, ": BUY order check - distance=", DoubleToString(distance, digits), 
               " required=", DoubleToString(minStopLevelDist, digits), " valid=", (valid ? "YES" : "NO"));
    } else if(orderType == OP_SELL || orderType == OP_SELLLIMIT) {
         // For sell orders, SL must be above the ask price
         double distance = sl - ask;
         valid = (sl > ask && distance >= minStopLevelDist);
         Print(eaName, ": SELL order check - distance=", DoubleToString(distance, digits), 
               " required=", DoubleToString(minStopLevelDist, digits), " valid=", (valid ? "YES" : "NO"));
    } else {
         valid = false;
         Print(eaName, ": Unknown order type: ", IntegerToString(orderType));
    }
    
    if(!valid)
        Print(eaName, ": SL validation FAILED for ", DoubleToString(sl, digits));
    else 
        Print(eaName, ": SL validation PASSED for ", DoubleToString(sl, digits));
        
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
//| GetOrderType: Determine order type based on signal and settings |
//+------------------------------------------------------------------+
int GetOrderType(string signalType)
{
    bool shouldBuy = (signalType == "BUY");
    bool shouldUseLimitOrders = useLimitOrders;
    
    if (shouldUseLimitOrders) {
        return (shouldBuy) ? OP_BUYLIMIT : OP_SELLLIMIT;
    } else {
        return (shouldBuy) ? OP_BUY : OP_SELL;
    }
}

//+------------------------------------------------------------------+
