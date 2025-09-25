//+------------------------------------------------------------------+
//|                                     TelegramSignalForwarder.mq4  |
//|                           Copyright 2025, OpenAI & User Request  |
//+------------------------------------------------------------------+
#property strict
#property version "2.4.2"

//+------------------------------------------------------------------+
//|--- Extern Parameters (EA Configuration)                         |
//+------------------------------------------------------------------+
extern bool   debugMode                = true;  // Enable detailed logging
extern int    brokerTimeOffsetMinutes  = 120;   // Broker time offset from UTC in minutes (e.g., UTC+2 = 120)
extern int    signalMaxAgeMinutes      = 5;     // Maximum signal age in minutes before rejection
extern string symbolPostfix            = "";     // Broker-specific symbol postfix (e.g., ".m", ".ecn")
extern double fallbackLotSize             = 0.02;  // Default lot size for FX orders
extern double accountRiskPercentage = 1.0; // Risk percentage per trade
extern double stopLossMultiplier       = 0.2;   // Factor to adjust SL at TP1 - 0.0 = entry, 1.0 = keep original SL
extern double marginBufferPercentage             = 70.0;   // Amount of free margin to use maximum
extern int    warmupTimeoutMinutes     = 1;     // Warmup signal timeout in minutes (close if no MODIFY)

//+------------------------------------------------------------------+
//|--- Constants & File Paths                                        |
//+------------------------------------------------------------------+
#define SL_MODIFY_THRESHOLD   0.00001            // Minimum SL diff to apply

static string gTempFile       = "processing.txt";     // Temp file to avoid re-read
static string gSignalFile               = "signals.txt";       // Incoming signal file

static int slippage = 20;  // maximum allowed slippage during order creation/modification

int trailingScanPeriodSeconds = 3;

struct Signal {
  long               timestamp;
  string             type;
  string             symbol;
  double             entry;
  double             tpLevels[10];
  int                tpCount;
  double             stopLoss;
  int                groupId;
  string             channelName;
  bool               isValid;

                     Signal()
  {
    timestamp    = 0;
    type         = "";
    symbol       = "";
    entry        = 0.0;
    ArrayInitialize(tpLevels, 0.0);
    tpCount      = 0;
    stopLoss     = 0.0;
    groupId      = 0;
    channelName  = "";
    isValid      = false;
  }
};

struct WarmupOrder {
  int                groupId;
  string             channelName;
  datetime           createdTime;
  bool               isActive;
  
                     WarmupOrder()
  {
    groupId      = 0;
    channelName  = "";
    createdTime  = 0;
    isActive     = false;
  }
};

//+------------------------------------------------------------------+
//|--- Global State Variables                                       |
//+------------------------------------------------------------------+
string   eaName               = "TelegramSignalForwarder";
int      signalFileHandle = -1;                  // File handle for reading signals in test mode
string   storedTestSignal = "";

// Warmup order tracking
WarmupOrder warmupOrders[100];  // Max 100 concurrent warmup orders
int         warmupOrderCount = 0;

//+------------------------------------------------------------------+
//|--- Function Prototypes                                          |
//+------------------------------------------------------------------+
void    PrintLog(string message);

Signal ReadSignalFile();
Signal ReadSignalLine(string line, bool shouldValidateTimestamp = false);
Signal ParseBuySellSignal(string &parts[], bool shouldValidateTimestamp);
Signal ParseActionSignal(string &parts[], bool shouldValidateTimestamp);
void    UpdateExistingOrdersSL(Signal &signal);
void    SendOrders(Signal &signal);
void    ProcessModifySlSignal(Signal &signal);
void    ProcessCloseSignal(Signal &signal);
void    ProcessCloseHalfBreakevenSignal(Signal &signal);
void    ProcessDynamicTrailingStop();
double  CalculateNewSL(int tpHitLevel, double currentStop, Signal &signal, string channelName);
bool    ParseOrderComment(string comment, int &groupId, string &channelName);
bool CloseCurrentOrder(Signal &signal);
bool SetCurrentOrderStopLoss(Signal &signal);

// Warmup order management
void    AddWarmupOrder(int groupId, string channelName);
void    RemoveWarmupOrder(int groupId, string channelName);
void    ProcessWarmupTimeouts();
void    CloseWarmupOrders(int groupId, string channelName);
int     GetActiveWarmupCount();

// Utility functions
bool    IsSignalTooOld(long signalTimestampMs);
bool    FileExists(string filename);
bool    IsValidDouble(string s);
string  CleanChannelName(string channelName);
string  FormatMT4Comment(int groupId, string channelName, int tpLevel);
int     GetMagic(string channelName);
double  GetPositionSize(Signal &signal);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
void OnInit()
{
// Use chart's expert name if provided
  string customName = WindowExpertName();
  if(StringLen(customName) > 0)
    eaName = customName;

  if(debugMode)
    PrintLog(eaName + ": Initialized");

// Use event timer for events
  EventSetTimer(trailingScanPeriodSeconds);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit()
{
  if(debugMode)
    PrintLog(eaName + ": Deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick handler                                              |
//+------------------------------------------------------------------+
void OnTimer()
{
  if (!IsTradeAllowed() || !IsConnected() || IsStopped()) {
    return;
  }

// Process warmup order timeouts first
  ProcessWarmupTimeouts();
  
// Process dynamic trailing stop for existing positions
  ProcessDynamicTrailingStop();

// Process new signal
  Signal signal = ReadSignalFile();

// Check if we have a valid signal
  if(!signal.isValid) {
    return; // No valid signal
  }

// Handle different signal types
  if(signal.type == "BUY" || signal.type == "SELL") {
    // Process trading signals
    if(debugMode)
      PrintLog(eaName + ": Processing " + signal.type + " signal from channel '" + signal.channelName + "' - GID=" + IntegerToString(signal.groupId) + " with " + IntegerToString(signal.tpCount) + " TP levels");

    // Check if orders with this GID already exist
    bool hasExistingOrders = false;
    for(int i=0; i<OrdersTotal(); i++) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
        int orderGid;
        string orderChannel;
        if(ParseOrderComment(OrderComment(), orderGid, orderChannel)) {
          if(orderGid == signal.groupId && orderChannel == signal.channelName) {
            hasExistingOrders = true;
            break;
          }
        }
      }
    }

    UpdateExistingOrdersSL(signal);

    if(hasExistingOrders) {
      if(debugMode)
        PrintLog(eaName + ": Orders with GID=" + IntegerToString(signal.groupId) + " already exist, only updating SL");
    } else {
      if(debugMode)
        PrintLog(eaName + ": No existing orders found, creating new orders");
      SendOrders(signal);
    }

  } else if(signal.type == "MODIFY" || signal.type == "BREAKEVEN") {
    ProcessModifySlSignal(signal);
  } else if(signal.type == "CLOSE") {
    ProcessCloseSignal(signal);
  } else if(signal.type == "CLOSE_HALF_BREAKEVEN") {
    ProcessCloseHalfBreakevenSignal(signal);
  }

  return;
}

//+------------------------------------------------------------------+
//| ReadSignalFile: Parses a signal line from file                   |
//+------------------------------------------------------------------+
Signal ReadSignalFile()
{
  Signal signal;
  string line = "";
  bool shouldKeepReading = false;
  do {
    if(StringLen(storedTestSignal) == 0) {
      if(signalFileHandle == -1) {
        if(!FileExists(gSignalFile))
          return signal;
        signalFileHandle = FileOpen(gSignalFile, FILE_READ|FILE_SHARE_READ | FILE_TXT | FILE_ANSI);
        PrintLog(eaName + ": Opening signal file " + gSignalFile);
        if(signalFileHandle == INVALID_HANDLE) {
          PrintLog(eaName + ": Failed to open signal file");
          return signal;
        }
      }

      if(signalFileHandle == INVALID_HANDLE) {
        PrintLog(eaName + ": Failed to open temp file for reading");
        return signal;
      }
      // in test mode, we keep the file open to read multiple signals
      if(IsTesting() && FileIsEnding(signalFileHandle)) {
        FileClose(signalFileHandle);
        return signal;
      }
      line = FileReadString(signalFileHandle);
      if(debugMode) {
        PrintLog(eaName + ": Read signal line: [" + line + "]");
      }
      if(!IsTesting()) {
        FileClose(signalFileHandle);
        signalFileHandle = -1;
        FileDelete(gSignalFile);
      }
    } else {
      line = storedTestSignal;
    }
    if(StringLen(line) == 0) {
      PrintLog(eaName + ": Empty signal line, skipping");
      return signal;
    }

    signal = ReadSignalLine(line, true);

    bool isSymbolMatching = signal.symbol == Symbol();
    shouldKeepReading = IsTesting() && signal.isValid && !isSymbolMatching && !FileIsEnding(signalFileHandle);
    if(shouldKeepReading) {
      storedTestSignal = "";
      PrintLog(eaName + ": Continuing to read next signal line for testing - current symbol: " + Symbol() +
               ", signal symbol: " + signal.symbol);
    }
  } while(shouldKeepReading);

  if(signal.isValid) {
    PrintLog(eaName + ": Found valid signal: " + line);
    storedTestSignal = "";
    SaveSignalToFile(line, signal.groupId);
  }

  return signal;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
Signal ReadSignalLine(string line, bool shouldValidateTimestamp = false)
{
  Signal signal;
// Expect different formats based on signal type:
// BUY/SELL: 123456789|TYPE|SYMBOL|ENTRY|TP1,TP2,TP3,...|SL|GID:<id>|CHANNEL_NAME
// BREAKEVEN/CLOSE: 123456789|TYPE|GID:<id>|CHANNEL_NAME
// MODIFY: 123456789|TYPE|NEW_SL|GID:<id>|CHANNEL_NAME
  string parts[];
  int partCount = StringSplit(line, '|', parts);

  if(partCount < 4) {
    PrintLog(eaName + ": Invalid signal format, expected at least 4 parts but got " + IntegerToString(partCount));
    return signal;
  }

  for(int i = 0; i < ArraySize(parts); i++) {
    parts[i] = StringTrimLeft(StringTrimRight(parts[i]));
  }

// 0) Extract and validate timestamp (first part, no prefix)
  string timestampStr = parts[0];
  long signalTimestamp = StrToInteger(timestampStr);
  signal.timestamp = signalTimestamp;
  if(shouldValidateTimestamp && IsSignalTooOld(signalTimestamp)) {
    if(!IsTesting()) {
      PrintLog(eaName + ": Signal too old, skipping. Timestamp=" + IntegerToString(signalTimestamp));
    } else {
      storedTestSignal = line;
    }
    return signal;
  }

// 1) Signal type
  signal.type = parts[1];
  StringToUpper(signal.type);
  if(signal.type != "BUY" && signal.type != "SELL" && signal.type != "BREAKEVEN" && signal.type != "CLOSE" && signal.type != "MODIFY" && signal.type != "CLOSE_HALF_BREAKEVEN") {
    PrintLog(eaName + ": Invalid signal type '" + signal.type + "', expected BUY, SELL, BREAKEVEN, CLOSE, MODIFY, or CLOSE_HALF_BREAKEVEN");
    return signal;
  }

// Handle different signal types with different parsing logic
  if(signal.type == "BUY" || signal.type == "SELL") {
    // Full trading signal format: TIMESTAMP|TYPE|SYMBOL|ENTRY|TP1,TP2,...|SL|GID:xxx|CHANNEL
    if(partCount < 8) {
      PrintLog(eaName + ": Invalid BUY/SELL signal format, expected 8 parts but got " + IntegerToString(partCount));
      return signal;
    }

    // Parse full trading signal
    return ParseBuySellSignal(parts, shouldValidateTimestamp);

  } else if(signal.type == "BREAKEVEN" || signal.type == "CLOSE"  || signal.type == "CLOSE_HALF_BREAKEVEN" ||
            signal.type == "MODIFY") {
    // Action signal format: TIMESTAMP|TYPE|GID:xxx|CHANNEL
    if(partCount < 4) {
      PrintLog(eaName + ": Invalid " + signal.type + " signal format, expected 4 parts but got " + IntegerToString(partCount));
      return signal;
    }

    return ParseActionSignal(parts, shouldValidateTimestamp);

  }

  return signal; // Should not reach here
}

//+------------------------------------------------------------------+
//| ParseFullTradingSignal: Parse BUY/SELL trading signals          |
//+------------------------------------------------------------------+
Signal ParseBuySellSignal(string &parts[], bool shouldValidateTimestamp)
{
  Signal signal;

// Set basic info
  signal.timestamp = StrToInteger(parts[0]);
  signal.type = parts[1];
  StringToUpper(signal.type);

// 2) Symbol validation
  signal.symbol = parts[2] + symbolPostfix;
  if(MarketInfo(signal.symbol, MODE_TIME) == 0) {
    PrintLog(eaName + ": Invalid symbol '" + signal.symbol + "', skipping");
    return signal;
  }

// 3) Entry price
  if(!IsValidDouble(parts[3])) {
    PrintLog(eaName + ": Invalid entry price '" + parts[3] + "', skipping");
    return signal;
  }
  signal.entry = NormalizeDouble(StrToDouble(parts[3]), MarketInfo(signal.symbol, MODE_DIGITS));

// 4) TP levels - dynamic parsing with bounds checking
  string tpsArr[];
  signal.tpCount = StringSplit(parts[4], ',', tpsArr);
  if(signal.tpCount < 1) {
    PrintLog(eaName + ": Invalid TP levels '" + parts[4] + "', skipping");
    return signal;
  }

// Enforce maximum TP count limit (array size is 6)
  if(signal.tpCount > 6) {
    PrintLog(eaName + ": Warning: TP count " + IntegerToString(signal.tpCount) + " exceeds maximum 6, truncating");
    signal.tpCount = 6;
  }

// Resize array to hold all TPs (up to maximum)
  ArrayResize(signal.tpLevels, signal.tpCount);
// Parse all TP levels
  for(int i=0; i<signal.tpCount; i++) {
    if(!IsValidDouble(tpsArr[i])) {
      PrintLog(eaName + ": Invalid TP level[" + IntegerToString(i) + "] '" + tpsArr[i] + "', skipping");
      return signal;
    }
    signal.tpLevels[i] = NormalizeDouble(StrToDouble(tpsArr[i]), MarketInfo(signal.symbol, MODE_DIGITS));
  }

// Validate TP order and remove duplicates
  bool shouldBuy = signal.type == "BUY";
  for(int i=0; i<signal.tpCount; i++) {
    if(i > 0) {
      if(shouldBuy && signal.tpLevels[i] <= signal.tpLevels[i-1]) {
        PrintLog(eaName + ": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(signal.tpLevels[i], MarketInfo(signal.symbol, MODE_DIGITS)) +
                 " should be higher than TP[" + IntegerToString(i-1) + "] " + DoubleToString(signal.tpLevels[i-1], MarketInfo(signal.symbol, MODE_DIGITS)) + " for BUY");
      } else if(!shouldBuy && signal.tpLevels[i] >= signal.tpLevels[i-1]) {
        PrintLog(eaName + ": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(signal.tpLevels[i], MarketInfo(signal.symbol, MODE_DIGITS)) +
                 " should be lower than TP[" + IntegerToString(i-1) + "] " + DoubleToString(signal.tpLevels[i-1], MarketInfo(signal.symbol, MODE_DIGITS)) + " for SELL");
      }
    }

    // Check TP direction relative to entry
    if (signal.entry != 0.0) {
      if(shouldBuy && signal.tpLevels[i] <= signal.entry) {
        PrintLog(eaName + ": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(signal.tpLevels[i], MarketInfo(signal.symbol, MODE_DIGITS)) +
                 " should be higher than entry " + DoubleToString(signal.entry, MarketInfo(signal.symbol, MODE_DIGITS)) + " for BUY");
      } else if(!shouldBuy && signal.tpLevels[i] >= signal.entry) {
        PrintLog(eaName + ": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(signal.tpLevels[i], MarketInfo(signal.symbol, MODE_DIGITS)) +
                 " should be lower than entry " + DoubleToString(signal.entry, MarketInfo(signal.symbol, MODE_DIGITS)) + " for SELL");
      }
    }
  }

// 5) Stop loss
  string rawSL = parts[5];

  if(!IsValidDouble(rawSL)) {
    PrintLog(eaName + ": Invalid stop loss '" + rawSL + "', skipping");
    return signal;
  }

  signal.stopLoss = NormalizeDouble(StrToDouble(rawSL), MarketInfo(signal.symbol, MODE_DIGITS));
// Validate SL position relative to entry price (if not market entry)
  if(signal.entry != 0.0) {
    if(shouldBuy && signal.stopLoss >= signal.entry) {
      PrintLog(eaName + ": Warning: SL " + DoubleToString(signal.stopLoss, MarketInfo(signal.symbol, MODE_DIGITS)) +
               " should be below entry " + DoubleToString(signal.entry, MarketInfo(signal.symbol, MODE_DIGITS)) + " for BUY");
    } else if(!shouldBuy && signal.stopLoss <= signal.entry) {
      PrintLog(eaName + ": Warning: SL " + DoubleToString(signal.stopLoss, MarketInfo(signal.symbol, MODE_DIGITS)) +
               " should be above entry " + DoubleToString(signal.entry, MarketInfo(signal.symbol, MODE_DIGITS)) + " for SELL");
    }
  }

// 6) Group ID
  string gidPart = parts[6];
  if(StringFind(gidPart, "GID:") != 0) {
    PrintLog(eaName + ": Invalid group ID format '" + gidPart + "', skipping");
    return signal;
  }

  signal.groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
  if(signal.groupId <= 0) {
    PrintLog(eaName + ": Invalid group ID '" + IntegerToString(signal.groupId) + "', skipping");
    return signal;
  }

// 7) Channel Name (new field) - clean and truncate to 4 letters
  if(ArraySize(parts) >= 8) {
    string rawChannelName = parts[7];
    if(StringLen(rawChannelName) == 0)
      rawChannelName = "UNKNOWN";
    signal.channelName = CleanChannelName(rawChannelName);
  } else {
    signal.channelName = "LEGC";
  }

  if (shouldValidateTimestamp)
    PrintLog(eaName + ": Parsed trading signal GID=" + IntegerToString(signal.groupId) + " from channel '" + signal.channelName + "'");

  signal.isValid = true;
  return signal;
}

//+------------------------------------------------------------------+
//| ParseModifySignal: Parse MODIFY/CLOSE etc. SL signals                      |
//+------------------------------------------------------------------+
Signal ParseActionSignal(string &parts[], bool shouldValidateTimestamp)
{
  Signal signal;

// Set basic info
  signal.timestamp = StrToInteger(parts[0]);
  signal.type = parts[1];
  StringToUpper(signal.type);

  bool isModifySignal = signal.type == "MODIFY";
  
  if (isModifySignal) {
    // Check if this is the new 7-part MODIFY format or old 5-part format
    int partCount = ArraySize(parts);
    
    if (partCount >= 7) {
      // New format: TIMESTAMP|MODIFY|SYMBOL|ENTRY|TP1,TP2|SL|GID:xxx|CHANNEL
      signal.symbol = parts[2] + symbolPostfix;
      signal.entry = StrToDouble(parts[3]);
      
      // Parse TP levels
      string tpsArr[];
      signal.tpCount = StringSplit(parts[4], ',', tpsArr);
      ArrayResize(signal.tpLevels, signal.tpCount);
      for(int i=0; i<signal.tpCount; i++) {
        signal.tpLevels[i] = NormalizeDouble(StrToDouble(tpsArr[i]), MarketInfo(signal.symbol, MODE_DIGITS));
      }
      
      // Parse SL
      signal.stopLoss = StrToDouble(parts[5]);
      
      // Parse GID
      string gidPart = parts[6];
      if(StringFind(gidPart, "GID:") == 0) {
        signal.groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
      }
      
      // Parse channel name
      signal.channelName = CleanChannelName(parts[7]);
      
      if (shouldValidateTimestamp)
        PrintLog(eaName + ": Parsed new format MODIFY signal GID=" + IntegerToString(signal.groupId) + 
                 " Symbol=" + signal.symbol + 
                 " NewSL=" + DoubleToString(signal.stopLoss, MarketInfo(signal.symbol, MODE_DIGITS)) + 
                 " TPCount=" + IntegerToString(signal.tpCount) + 
                 " from channel '" + signal.channelName + "'");
      
    } else if (partCount >= 5) {
      // Old format: TIMESTAMP|MODIFY|NEW_SL|GID:xxx|CHANNEL
      string slPart = parts[2];
      if(!IsValidDouble(slPart)) {
        PrintLog(eaName + ": Invalid new SL value '" + slPart + "', skipping");
        return signal;
      }
      signal.stopLoss = StrToDouble(slPart);
      
      // Parse GID
      string gidPart = parts[3];
      if(StringFind(gidPart, "GID:") == 0) {
        signal.groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
      }
      
      // Parse channel name
      signal.channelName = CleanChannelName(parts[4]);
      
      if (shouldValidateTimestamp)
        PrintLog(eaName + ": Parsed old format MODIFY signal GID=" + IntegerToString(signal.groupId) + 
                 " NewSL=" + DoubleToString(signal.stopLoss, 5) + 
                 " from channel '" + signal.channelName + "'");
    } else {
      PrintLog(eaName + ": Invalid MODIFY signal format, expected at least 5 parts but got " + IntegerToString(partCount));
      return signal;
    }
    
  } else {
    // BREAKEVEN/CLOSE signals - use original logic
    int shift = 0;
    
    // Group ID
    string gidPart = parts[2 + shift];
    if(StringFind(gidPart, "GID:") != 0) {
      PrintLog(eaName + ": Invalid group ID format '" + gidPart + "', skipping");
      return signal;
    }

    signal.groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
    if(signal.groupId <= 0) {
      PrintLog(eaName + ": Invalid group ID '" + IntegerToString(signal.groupId) + "', skipping");
      return signal;
    }

    // Channel Name
    string rawChannelName = parts[3 + shift];
    if(StringLen(rawChannelName) == 0)
      rawChannelName = "UNKNOWN";
    signal.channelName = CleanChannelName(rawChannelName);
  }

  signal.isValid = true;
  return signal;
}

//+------------------------------------------------------------------+
//| UpdateExistingOrdersSL: Update SL of existing orders from same channel |
//+------------------------------------------------------------------+
void UpdateExistingOrdersSL(Signal &signal)
{
// Only update SL for trading signals (BUY/SELL)
  if(signal.type != "BUY" && signal.type != "SELL") {
    return;
  }

  string symbol = signal.symbol;
  StringToUpper(symbol);
  if(StringFind(symbol, "XAUUSD") >= 0 || StringFind(symbol, "GOLD") >= 0) {
    PrintLog(eaName + ": Skipping UpdateExistingOrdersSL for Gold symbol: " + symbol +
             " - avoiding interference with independent trades");
    return;
  }

  int targetOrderType = (signal.type == "BUY") ? OP_BUY : OP_SELL;

  for(int i=0; i<OrdersTotal(); i++) {
    if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
      PrintLog(eaName + ": Failed to select order at index " + IntegerToString(i) + " - error=" + IntegerToString(GetLastError()));
      continue;
    }
    if(OrderSymbol() != symbol || OrderType() != targetOrderType) {
      if(debugMode)
        PrintLog(eaName + ": Ignoring order at index " + IntegerToString(i) + " - symbol/type mismatch");
      continue;
    }

    // Parse the order's comment to get channel information
    int orderGid;
    string orderChannelName;
    if(!ParseOrderComment(OrderComment(), orderGid /* unused */, orderChannelName)) {
      PrintLog(eaName + ": Failed to parse order comment for ticket " + IntegerToString(OrderTicket()) + ": " + OrderComment());
      continue;
    }

    // Only update SL if the order is from the same channel
    if(orderChannelName != signal.channelName) {
      if(debugMode)
        PrintLog(eaName + ": Ignoring order ticket " + IntegerToString(OrderTicket()) +
                 " - different channel (order='" + orderChannelName + "', signal='" + signal.channelName + "')");
      continue;
    }

    double currSL = OrderStopLoss();
    if(MathAbs(currSL - signal.stopLoss) > SL_MODIFY_THRESHOLD) {
      double openP = OrderOpenPrice();
      double tp    = OrderTakeProfit();
      bool ok = OrderModify(OrderTicket(), openP, signal.stopLoss, tp, 0, clrBlue);
      if(ok)
        PrintLog(eaName + ": Updated SL for ticket=" + IntegerToString(OrderTicket()) +
                 " from channel '" + signal.channelName + "' (" + DoubleToString(currSL, MarketInfo(symbol, MODE_DIGITS)) +
                 " -> " + DoubleToString(signal.stopLoss, MarketInfo(symbol, MODE_DIGITS)) + ")");
      else
        PrintLog(eaName + ": SL update failed ticket=" + IntegerToString(OrderTicket()) +
                 " err=" + IntegerToString(GetLastError()));
    } else {
      PrintLog(eaName + ": SL change too small for ticket " + IntegerToString(OrderTicket()) +
               " - current=" + DoubleToString(currSL, MarketInfo(symbol, MODE_DIGITS)) +
               " new=" + DoubleToString(signal.stopLoss, MarketInfo(symbol, MODE_DIGITS)));
    }
  }

  PrintLog(eaName + ": Completed SL update for existing orders from channel '" + signal.channelName + "'");
}

//+------------------------------------------------------------------+
//| SendOrders: Place up to four market orders with SL & TP        |
//+------------------------------------------------------------------+
void SendOrders(Signal &signal)
{
// Only send orders for trading signals (BUY/SELL)
  if(signal.type != "BUY" && signal.type != "SELL") {
    return;
  }

  // Check for warmup signal (entry=0, TP=0, SL=0)
  bool isWarmupSignal = (signal.entry == 0.0 && signal.stopLoss == 0.0 && 
                         signal.tpCount >= 2 && signal.tpLevels[0] == 0.0 && signal.tpLevels[1] == 0.0);
  
  if(isWarmupSignal) {
    PrintLog(eaName + ": WARMUP SIGNAL detected - Calculating TP/SL levels for GID=" + IntegerToString(signal.groupId));
    CalculateWarmupLevels(signal);
    
    // Add to warmup tracking (will be monitored for timeout)
    AddWarmupOrder(signal.groupId, signal.channelName);
  }

  if(signal.entry == 0.0) {
    // using market entry
    RefreshRates();
    double currentAsk = MarketInfo(signal.symbol, MODE_ASK);
    double currentBid = MarketInfo(signal.symbol, MODE_BID);

    signal.entry = (signal.type == "BUY") ? currentAsk : currentBid;

    PrintLog(eaName + ": IMMEDIATE ENTRY detected - Using market price: " +
             DoubleToString(signal.entry, MarketInfo(signal.symbol, MODE_DIGITS)) +
             " for GID=" + IntegerToString(signal.groupId));
  }

  int digits    = MarketInfo(signal.symbol, MODE_DIGITS);
  double point  = MarketInfo(signal.symbol, MODE_POINT);
  int stopLevel = MarketInfo(signal.symbol, MODE_STOPLEVEL);

  RefreshRates();
  double ask = MarketInfo(signal.symbol, MODE_ASK);
  double bid = MarketInfo(signal.symbol, MODE_BID);
  bool shouldBuy = signal.type == "BUY";
  double tp1 = signal.tpLevels[0];

  double price = shouldBuy ? ask : bid;
  int orderType = (shouldBuy) ? OP_BUY : OP_SELL;
  price = NormalizeDouble(price, digits);

  if(shouldBuy ? price > tp1 : price < tp1) {
    PrintLog(eaName + ": Entry price " + DoubleToString(price, digits) +
             " is beyond TP1 " + DoubleToString(tp1, digits) +
             " for GID=" + IntegerToString(signal.groupId) +
             ", skipping order creation");
    return;
  }

// Always use the original stop loss from signal
  double rawSL = NormalizeDouble(signal.stopLoss, digits);
  double fallbackSL = (shouldBuy)
                      ? price - MathAbs(signal.entry - signal.stopLoss)
                      : price + MathAbs(signal.stopLoss - signal.entry);
  fallbackSL = NormalizeDouble(fallbackSL, digits);

// Apply minimum distance for SL if needed
  double minDist = MathMax(stopLevel * point, point);
  if(shouldBuy && price - fallbackSL < minDist)
    fallbackSL = price - minDist;
  if(!shouldBuy && fallbackSL - price < minDist)
    fallbackSL = price + minDist;
  fallbackSL = NormalizeDouble(fallbackSL, digits);

// Normalize all TP levels and ensure minimum distance
  for(int j=0; j<signal.tpCount; j++) {
    signal.tpLevels[j] = NormalizeDouble(signal.tpLevels[j], digits);
    double dist = MathAbs(signal.tpLevels[j] - signal.entry);
    if(dist < minDist)
      signal.tpLevels[j] = (shouldBuy) ? price + minDist : price - minDist;
    signal.tpLevels[j] = NormalizeDouble(signal.tpLevels[j], digits);
  }

  PrintLog(eaName + ": Sending orders for GID=" + IntegerToString(signal.groupId) +
           " from channel '" + signal.channelName + "'" +
           " Using SL=" + DoubleToString(rawSL, digits) +
           " TP Count=" + IntegerToString(signal.tpCount));

  color cols[6] = { clrBlue, clrGreen, clrRed, clrYellow, clrMagenta, clrCyan };
  double lotSize = GetPositionSize(signal);

// Create orders for each TP level
  for(int k=0; k < signal.tpCount; k++) {
    // for market orders we want to get the correct current price
    // to avoid off-quotes errors
    RefreshRates();
    ask = MarketInfo(signal.symbol, MODE_ASK);
    bid = MarketInfo(signal.symbol, MODE_BID);
    price = (shouldBuy) ? ask : bid;
    string comment = FormatMT4Comment(signal.groupId, signal.channelName, k + 1);
    int magicNumber = GetMagic(signal.channelName);
    PrintLog(eaName + ": Order[" + IntegerToString(k) + "] parameters: " +
             "Symbol=" + signal.symbol +
             " Type=" + IntegerToString(orderType) +
             " Lots=" + DoubleToString(lotSize, 2) +
             " Price=" + DoubleToString(price, digits) +
             " SL=" + DoubleToString(rawSL, digits) +
             " TP=" + DoubleToString(signal.tpLevels[k], digits) +
             " Comment=" + comment +
             " Magic=" + magicNumber);

    int colorIndex = k % 6;
    int ticket = OrderSend(signal.symbol, orderType, lotSize, price, slippage,
                           rawSL, signal.tpLevels[k], comment, magicNumber, 0 /* expiration */, cols[colorIndex]);

    if(ticket < 0) {
      PrintLog(eaName + ": Error creating order[" + IntegerToString(k) + "] ticket=" + IntegerToString(ticket) + " error=" + IntegerToString(GetLastError()));
      Sleep(1000);
      RefreshRates();
      PrintLog(eaName + ": Retrying with fallback SL=" + DoubleToString(fallbackSL, digits));
      ticket = OrderSend(signal.symbol, orderType, lotSize, price, slippage,
                         fallbackSL, signal.tpLevels[k], comment, magicNumber, 0 /* expiration */, cols[colorIndex]);
    }

    PrintLog(eaName + ": Order[" + IntegerToString(k) + "] ticket=" + IntegerToString(ticket));
  }
}

//+------------------------------------------------------------------+
//| ProcessModifySignal: Apply SL modification for specific GID     |
//+------------------------------------------------------------------+
void ProcessModifySlSignal(Signal &signal)
{
  if(signal.groupId <= 0) {
    PrintLog(eaName + ": Invalid GID in signal: " + IntegerToString(signal.groupId));
    return;
  }

// Remove from warmup tracking (MODIFY signal received)
  RemoveWarmupOrder(signal.groupId, signal.channelName);

// if not modify, then breakeven
  bool isModifySignal = signal.type == "MODIFY";
  string operation = isModifySignal ? "SL modification" : "SL breakeven";
  PrintLog(eaName + ": Processing " + operation + " - GID=" + IntegerToString(signal.groupId) +
           " NewSL=" + DoubleToString(signal.stopLoss, 5));

  int updatedCount = 0;
  int total = OrdersTotal();
// Close orders in reverse order to avoid index issues
  for(int i=total-1; i>=0; i--) {
    if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
      continue;
    }

    // Parse order comment to check GID match
    int orderGid;
    string orderChannel;
    if(!ParseOrderComment(OrderComment(), orderGid, orderChannel)) {
      continue;
    }

    if(orderGid != signal.groupId || orderChannel != signal.channelName) {
      continue;
    }

    if(SetCurrentOrderStopLoss(signal)) {
      updatedCount++;
    }
  }

  if(updatedCount == 0) {
    PrintLog(eaName + ": ⚠️ No orders found with GID=" + IntegerToString(signal.groupId) + " for " + operation);
  } else {
    PrintLog(eaName + ": ✅ " + operation + " for " + IntegerToString(updatedCount) + " orders with GID=" + IntegerToString(signal.groupId));
  }
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool SetCurrentOrderStopLoss(Signal &signal)
{
  bool isModifySignal = signal.type == "MODIFY";
  string operation = isModifySignal ? "SL modification" : "SL breakeven";
  double newStopLoss = isModifySignal ? signal.stopLoss : OrderOpenPrice();
  
  double currentSL = OrderStopLoss();
  double currentTP = OrderTakeProfit();
  int digits = MarketInfo(OrderSymbol(), MODE_DIGITS);
  double normalizedNewSL = NormalizeDouble(newStopLoss, digits);
  
  // For new format MODIFY with TP levels, also update TP if provided
  bool shouldUpdateTp = false;
  double newTp = currentTP; // Keep current TP by default
  
  if (isModifySignal && signal.tpCount > 0) {
    // Extract TP level from order comment (format: GID|CHANNEL|TP_LEVEL)
    string commentParts[];
    int commentPartCount = StringSplit(OrderComment(), '|', commentParts);
    if (commentPartCount >= 3) {
      int orderTpLevel = StrToInteger(commentParts[2]);
      if (orderTpLevel > 0 && orderTpLevel <= signal.tpCount) {
        newTp = signal.tpLevels[orderTpLevel - 1]; // Array is 0-based, TP levels are 1-based
        newTp = NormalizeDouble(newTp, digits);
        shouldUpdateTp = true;
      }
    }
  }

  bool slChanged = MathAbs(currentSL - normalizedNewSL) > SL_MODIFY_THRESHOLD;
  bool tpChanged = shouldUpdateTp && MathAbs(currentTP - newTp) > SL_MODIFY_THRESHOLD;

  if (slChanged || tpChanged) {
    double op = OrderOpenPrice();

    if (OrderModify(OrderTicket(), op, normalizedNewSL, newTp, 0, clrGold)) {
      string logMsg = "✅ " + operation + " success for ticket " + IntegerToString(OrderTicket()) +
                      " GID=" + IntegerToString(signal.groupId);
      
      if (slChanged) {
        logMsg += " SL: " + DoubleToString(currentSL, digits) + " -> " + DoubleToString(normalizedNewSL, digits);
      }
      
      if (tpChanged) {
        logMsg += " TP: " + DoubleToString(currentTP, digits) + " -> " + DoubleToString(newTp, digits);
      }
      
      PrintLog(eaName + ": " + logMsg);
      return true;
    } else {
      int error = GetLastError();
      PrintLog(eaName + ": ❌ " + operation + " failed for ticket " + IntegerToString(OrderTicket()) +
               " GID=" + IntegerToString(signal.groupId) +
               " error=" + IntegerToString(error));

      if (error == 130 && !isModifySignal) {
        PrintLog(eaName + ": Error 130 detected - breakeven too close, closing order instead");
        return CloseCurrentOrder(signal);
      } else {
        return false;
      }
    }
  } else {
    PrintLog(eaName + ": No significant changes for ticket " + IntegerToString(OrderTicket()) +
             " - SL=" + DoubleToString(normalizedNewSL, digits) +
             " TP=" + DoubleToString(newTp, digits));
    return false;
  }
}

//+------------------------------------------------------------------+
//| ProcessCloseSignal: Close all orders for specific GID          |
//+------------------------------------------------------------------+
void ProcessCloseSignal(Signal &signal)
{
  if(signal.groupId <= 0) {
    PrintLog(eaName + ": Invalid GID in CLOSE signal: " + IntegerToString(signal.groupId));
    return;
  }

  PrintLog(eaName + ": Processing close all orders - GID=" + IntegerToString(signal.groupId));

  int closedCount = 0;
  int total = OrdersTotal();

// Close orders in reverse order to avoid index issues
  for(int i=total-1; i>=0; i--) {
    if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
      continue;
    }

    // Parse order comment to check GID match
    int orderGid;
    string orderChannel;
    if(!ParseOrderComment(OrderComment(), orderGid, orderChannel)) {
      continue;
    }

    if(orderGid != signal.groupId || orderChannel != signal.channelName) {
      continue;
    }

    if (CloseCurrentOrder(signal)) {
      closedCount++;
    }
  }

  if(closedCount == 0) {
    PrintLog(eaName + ": ⚠️ No orders found with GID=" + IntegerToString(signal.groupId) + " to close");
  } else {
    PrintLog(eaName + ": ✅ Closed " + IntegerToString(closedCount) + " orders with GID=" + IntegerToString(signal.groupId));
  }
}

//+------------------------------------------------------------------+
//| CloseCurrentOrder: Closes the currently selected order          |
//+------------------------------------------------------------------+
bool CloseCurrentOrder(Signal &signal)
{
// Close the order
  int ticket = OrderTicket();
  double lots = OrderLots();
  string symbol = OrderSymbol();
  int orderType = OrderType();

  RefreshRates();
  double closePrice;
  if(orderType == OP_BUY) {
    closePrice = MarketInfo(symbol, MODE_BID);
  } else if(orderType == OP_SELL) {
    closePrice = MarketInfo(symbol, MODE_ASK);
  } else {
    return false; // Skip pending orders for now
  }

  if(OrderClose(ticket, lots, closePrice, slippage, clrRed)) {
    PrintLog(eaName + ": ✅ Closed order ticket " + IntegerToString(ticket) +
             " GID=" + IntegerToString(signal.groupId) +
             " Symbol=" + symbol +
             " Lots=" + DoubleToString(lots, 2));
    return true;
  } else {
    PrintLog(eaName + ": ❌ Failed to close order ticket " + IntegerToString(ticket) +
             " GID=" + IntegerToString(signal.groupId) +
             " error=" + IntegerToString(GetLastError()));
    return false;
  }
}

//+------------------------------------------------------------------+
//| ProcessCloseHalfBreakevenSignal: Close half orders, breakeven rest |
//+------------------------------------------------------------------+
void ProcessCloseHalfBreakevenSignal(Signal &signal)
{
  if(signal.groupId <= 0) {
    PrintLog(eaName + ": Invalid GID in CLOSE_HALF_BREAKEVEN signal: " + IntegerToString(signal.groupId));
    return;
  }

  PrintLog(eaName + ": Processing close half + breakeven rest - GID=" + IntegerToString(signal.groupId));

// First collect all matching orders
  int matchingTickets[];
  int matchingCount = 0;
  int total = OrdersTotal();

// Close orders in reverse order to avoid index issues
  for(int i=total-1; i>=0; i--) {
    if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
      continue;
    }

    // Parse order comment to check GID match
    int orderGid;
    string orderChannel;
    if(!ParseOrderComment(OrderComment(), orderGid, orderChannel)) {
      continue;
    }

    if(orderGid != signal.groupId || orderChannel != signal.channelName) {
      continue;
    }

    // Only include market orders (BUY/SELL)
    int orderType = OrderType();
    if(orderType == OP_BUY || orderType == OP_SELL) {
      ArrayResize(matchingTickets, matchingCount + 1);
      matchingTickets[matchingCount] = OrderTicket();
      matchingCount++;
    }
  }

  if(matchingCount == 0) {
    PrintLog(eaName + ": ⚠️ No orders found with GID=" + IntegerToString(signal.groupId) + " for close+breakeven");
    return;
  }

// NEW LOGIC: If only 1 order, do nothing - let it run
  if(matchingCount == 1) {
    PrintLog(eaName + ": ⚠️ Only 1 order found with GID=" + IntegerToString(signal.groupId) + " - letting it run (no action taken)");
    return;
  }

// Calculate how many to close vs breakeven (only for 2+ orders)
// If odd number: close more than half (e.g., 3 orders: close 2, breakeven 1)
// If even number: close exactly half (e.g., 4 orders: close 2, breakeven 2)
  int ordersToClose = (matchingCount + 1) / 2;  // This gives us ceil(count/2)
  int ordersToBreakeven = matchingCount - ordersToClose;

  PrintLog(eaName + ": Found " + IntegerToString(matchingCount) + " orders - closing " +
           IntegerToString(ordersToClose) + ", breakeven " + IntegerToString(ordersToBreakeven));

  int closedCount = 0;
  int breakevenCount = 0;

// Close first half of orders
  for(int i=0; i<ordersToClose && i<matchingCount; i++) {
    if(!OrderSelect(matchingTickets[i], SELECT_BY_TICKET)) {
      continue;
    }

    if (CloseCurrentOrder(signal)) {
      closedCount++;
    }
  }

// Move remaining orders to breakeven
  for(int i=ordersToClose; i<matchingCount; i++) {
    if(!OrderSelect(matchingTickets[i], SELECT_BY_TICKET)) {
      continue;
    }

    if (SetCurrentOrderStopLoss(signal)) {
      breakevenCount++;
    }

  }

  PrintLog(eaName + ": ✅ Close+Breakeven completed - Closed: " + IntegerToString(closedCount) +
           ", Breakeven: " + IntegerToString(breakevenCount) + " for GID=" + IntegerToString(signal.groupId));
}

//+------------------------------------------------------------------+
//| ParseOrderGidChannel: Extract GID and channel name from order comment |
//+------------------------------------------------------------------+
bool ParseOrderComment(string comment, int &groupId, string &channelName)
{
// 1234|ABCD|1.2550,1.2600 (GID|CHANNEL|TP1,TP2,...)

  string parts[];
  int partCount = StringSplit(comment, '|', parts);
  if(partCount < 2) {
    PrintLog(eaName + ": Invalid comment format, expected at least 2 parts but got " + IntegerToString(partCount));
    return(false);
  }

// Extract GID (first part)
  groupId = StrToInteger(parts[0]);
  if(groupId <= 0) {
    if(debugMode)
      PrintLog(eaName + ": Invalid GID in comment: " + comment);
    return(false);
  }

// Extract channel name (second part, should be 4 letters)
  channelName = parts[1];
  if(StringLen(channelName) != 4) {
    if(debugMode)
      PrintLog(eaName + ": Invalid channel name length in new comment: " + comment);
    channelName = "UNKN"; // Fallback
  }

  return(true);
}

//+------------------------------------------------------------------+
//| IsSignalTooOld: validate if signal timestamp is too old         |
//+------------------------------------------------------------------+
bool IsSignalTooOld(long signalTimestamp)
{
  if(signalTimestamp <= 0)
    return(true);

  datetime signalTime = (datetime)(signalTimestamp);

// Get current broker time and convert to UTC
  datetime brokerTime = TimeCurrent();
  datetime utcTime = brokerTime - (brokerTimeOffsetMinutes * 60);

// Calculate age in minutes
  int ageSeconds = (int)(utcTime - signalTime);
  int ageMinutes = ageSeconds / 60;

  if(IsTesting() && ageMinutes < 0) {
    // In testing mode, allow negative age (future signals)
    return(true);
  }

  bool isTooOld = ageMinutes > signalMaxAgeMinutes;

  if(debugMode || isTooOld)
    PrintLog(eaName + ": Signal age check - UTC now: " + TimeToString(utcTime) +
             ", Signal time: " + TimeToString(signalTime) +
             ", Age: " + IntegerToString(ageMinutes) + " minutes");

  return isTooOld;
}

//+------------------------------------------------------------------+
//| FileExists: check if a file exists                              |
//+------------------------------------------------------------------+
bool FileExists(string filename)
{
  int tfh = FileOpen(filename, FILE_READ|FILE_SHARE_READ | FILE_TXT | FILE_ANSI);
  if(tfh != INVALID_HANDLE) {
    FileClose(tfh);
    return(true);
  }
  return(false);
}

//+------------------------------------------------------------------+
//| IsValidDouble: validate if string is numeric                    |
//+------------------------------------------------------------------+
bool IsValidDouble(string s)
{
  int len = StringLen(s);
  if(len == 0)
    return(false);
  bool dotFound = false;
  int start = (StringGetCharacter(s, 0) == '+' || StringGetCharacter(s, 0) == '-') ? 1 : 0;
  for(int i = start; i < len; i++) {
    int c = StringGetCharacter(s, i);
    if(c == '.') {
      if(dotFound)
        return(false);
      dotFound = true;
    } else if(c < '0' || c > '9')
      return(false);
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
  if(length == 0)
    return "UNKN";

// Convert to uppercase and extract only alphabetic characters
  string alphaOnly = "";
  for(int i = 0; i < length; i++) {
    int c = StringGetCharacter(channelName, i);
    if(c >= 'A' && c <= 'Z')
      alphaOnly += CharToStr(c);
    else if(c >= 'a' && c <= 'z')
      alphaOnly += CharToStr(c - 32); // Convert to uppercase
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
//| Format: 1234|ABCD|3 (GID|CHANNEL|TP_LEVEL)      |
//+------------------------------------------------------------------+
string FormatMT4Comment(int groupId, string channelName, int tpLevel)
{
  string cleanChannel = CleanChannelName(channelName);

  string result[3];
  result[0] = IntegerToString(groupId);
  result[1] = cleanChannel;
  result[2] = IntegerToString(tpLevel);

  return StringJoin(result, 3, "|");
}

//+------------------------------------------------------------------+
//| ProcessDynamicTrailingStop: Main trailing stop logic           |
//+------------------------------------------------------------------+
void ProcessDynamicTrailingStop()
{

  for(int o = 0; o < OrdersTotal(); o++) {
    if(!OrderSelect(o, SELECT_BY_POS, MODE_TRADES))
      continue;

    // Parse order comment to get GID and channel name
    int orderGid;
    string orderChannelName;
    if(!ParseOrderComment(OrderComment(), orderGid, orderChannelName)) {
      if(debugMode)
        PrintLog(eaName + ": Failed to parse order comment for ticket " + IntegerToString(OrderTicket()) + ": " + OrderComment());
      continue;
    }

    Signal signal = GetSignalFromFile(orderGid);
    if(!signal.isValid) {
      if(debugMode)
        PrintLog(eaName + ": cannot find signal in file for GID " + IntegerToString(orderGid) + ", skipping TS update");
      continue;
    }

    if(signal.entry == 0.0)
      signal.entry = OrderOpenPrice(); // Use current open price if not set

    double tpLevels[10];

    int tpHitLevel = 0;
    for(int i = 0; i < signal.tpCount; i++) {
      if((OrderType() == OP_BUY && OrderClosePrice() >= signal.tpLevels[i]) ||
          (OrderType() == OP_SELL && OrderClosePrice() <= signal.tpLevels[i])) {
        tpHitLevel = i + 1; // TP levels are 1-based
      }
    }
    if(tpHitLevel <= 0)
      continue; // No TPs hit yet, skip TS for this order
    double currentSL = OrderStopLoss();
    double newSL = CalculateNewSL(tpHitLevel, currentSL, signal, orderChannelName);
    if(MathAbs(currentSL - newSL) > SL_MODIFY_THRESHOLD) {
      bool modified = OrderModify(OrderTicket(), OrderOpenPrice(), newSL,
                                  OrderTakeProfit(), 0, clrOrange);
      if(modified) {
        PrintLog(eaName + ": Trailing SL updated for ticket:" + IntegerToString(OrderTicket()) +
                 " from " + DoubleToString(currentSL, MarketInfo(OrderSymbol(), MODE_DIGITS)) +
                 " to " + DoubleToString(newSL, MarketInfo(OrderSymbol(), MODE_DIGITS)));
      } else {
        PrintLog(eaName + ": Failed to update trailing SL for ticket:" + IntegerToString(OrderTicket()) +
                 " Error:" + IntegerToString(GetLastError()));
      }
    }
  }
}

//+------------------------------------------------------------------+
//| CalculateNewSL: Calculate new SL based on TP hit level         |
//+------------------------------------------------------------------+
double CalculateNewSL(int tpHitLevel, double currentStop, Signal &signal, string channelName)
{
  double newSL = currentStop;
  bool isBuy = (signal.type == "BUY");
  if(tpHitLevel <= 0 || signal.tpCount <= 0)
    return currentStop;

  int digits = MarketInfo(signal.symbol, MODE_DIGITS);
  string symbolUpper = signal.symbol;
  StringToUpper(symbolUpper);

// Special rules for specific channel+symbol combinations
  double dynamicStopLossMultiplier = stopLossMultiplier;
  bool stopTrailingAfterTP2 = false;

// FXPL + BTCUSD: always use 0.5 multiplier
  if(channelName == "FXPL" && (StringFind(symbolUpper, "BTCUSD") >= 0 || StringFind(symbolUpper, "BTC") >= 0)) {
    dynamicStopLossMultiplier = 0.5;
    if(debugMode)
      PrintLog(eaName + ": Using FXPL+BTCUSD rule: multiplier=0.5");
  }
// THEA + XAUUSD: use 0.2 multiplier and stop trailing after TP2
  else if(channelName == "THEA" && (StringFind(symbolUpper, "XAUUSD") >= 0 || StringFind(symbolUpper, "GOLD") >= 0)) {
    dynamicStopLossMultiplier = 0.2;
    stopTrailingAfterTP2 = true;
    if(debugMode)
      PrintLog(eaName + ": Using THEA+XAUUSD rule: multiplier=0.2, stop after TP2");
  }

// THEA special rule: if TP2+ hit and symbol is XAUUSD, move to breakeven and stop trailing
  if(stopTrailingAfterTP2 && tpHitLevel >= 2) {
    double breakevenSL = OrderOpenPrice();
    double normalizedBreakeven = NormalizeDouble(breakevenSL, digits);

    // Only move to breakeven if it's more favorable than current SL
    bool shouldMoveToBreakeven = false;
    if(isBuy && normalizedBreakeven > currentStop) {
      shouldMoveToBreakeven = true;
    } else if(!isBuy && normalizedBreakeven < currentStop) {
      shouldMoveToBreakeven = true;
    }

    if(shouldMoveToBreakeven) {
      if(debugMode)
        PrintLog(eaName + ": THEA+XAUUSD TP2+ hit - moving to breakeven and stopping trailing: " +
                 DoubleToString(normalizedBreakeven, digits));
      return normalizedBreakeven;
    } else {
      if(debugMode)
        PrintLog(eaName + ": THEA+XAUUSD TP2+ hit - breakeven would be worse, keeping current SL");
      return currentStop;
    }
  }

  if(dynamicStopLossMultiplier < 0) {
    return NormalizeDouble(currentStop, digits); // No multiplier set, return original SL
  }

  if (tpHitLevel == 1) {
    // Use OrderOpenPrice and not signal.entry, because of slippage, actual open price might differ slightly
    double diff = MathAbs(OrderOpenPrice() - signal.stopLoss) * dynamicStopLossMultiplier;
    newSL = isBuy ? OrderOpenPrice() - diff : OrderOpenPrice() + diff;
  } else {
    if (signal.tpCount < tpHitLevel) {
      PrintLog(eaName + ": Invalid TP hit level " + IntegerToString(tpHitLevel) +
               " for GID=" + IntegerToString(signal.groupId) +
               ", using original SL");
      return currentStop;
    }
    newSL = signal.tpLevels[tpHitLevel - 2]; // If TP2 is hit (tpHitLevel is 2), use TP1 as new SL (array index 0)
  }

// Validate SL direction for BUY/SELL - ensure it moves in favorable direction only
  if(isBuy) {
    // For BUY: new SL should be higher than current SL (more favorable)
    if(newSL < currentStop) {
      if(debugMode)
        PrintLog(eaName + ": BUY - New SL " + DoubleToString(newSL, digits) +
                 " would be worse than original " + DoubleToString(currentStop, digits) + ", keeping original");
      return currentStop;
    }
  } else {
    // For SELL: new SL should be lower than current SL (more favorable)
    if(newSL > currentStop) {
      if(debugMode)
        PrintLog(eaName + ": SELL - New SL " + DoubleToString(newSL, digits) +
                 " would be worse than original " + DoubleToString(currentStop, digits) + ", keeping original");
      return currentStop;
    }
  }

  if(debugMode)
    PrintLog(eaName + ": SL calculation successful - Channel:" + channelName +
             " Symbol:" + symbolUpper + " Level:" + IntegerToString(tpHitLevel) +
             " Multiplier:" + DoubleToString(dynamicStopLossMultiplier, 2) +
             " Original:" + DoubleToString(currentStop, digits) +
             " New:" + DoubleToString(newSL, digits) +
             " Direction:" + (isBuy ? "BUY" : "SELL"));

  return NormalizeDouble(newSL, digits);
}

//+------------------------------------------------------------------+
//| PrintLog: Write log to daily file and Experts log               |
//+------------------------------------------------------------------+
void PrintLog(string msg)
{
  if(IsTesting()) {
    Print(msg);
    return;
  }

  datetime currentTime = TimeCurrent() - (brokerTimeOffsetMinutes * 60);
  string dateStr = TimeToString(currentTime, TIME_DATE);
  string y = StringSubstr(dateStr, 0, 4);
  string m = StringSubstr(dateStr, 5, 2);
  string d = StringSubstr(dateStr, 8, 2);
  string logFile = y + m + d + ".log";
  int handle = FileOpen(logFile, FILE_WRITE|FILE_SHARE_READ|FILE_READ|FILE_TXT|FILE_ANSI);
  if(handle != INVALID_HANDLE) {
    FileSeek(handle, 0, SEEK_END);
    FileWrite(handle, TimeToString(currentTime, TIME_DATE|TIME_SECONDS), " ", msg);
    FileFlush(handle);
    FileClose(handle);
  }
// Also print to Experts log for convenience
  Print(msg);
}

//+------------------------------------------------------------------+
//| StringJoin: Join array of strings with a delimiter              |
//+------------------------------------------------------------------+
string StringJoin(string &arr[], int size, string delimiter)
{
  string result = "";
  for(int i = 0; i < size; i++) {
    if(i > 0 && StringLen(arr[i]) > 0)
      result += delimiter;
    result += arr[i];
  }
  return result;
}

//+------------------------------------------------------------------+
//| saveSignal: Save a signal struct to signals/<GID>.txt          |
//+------------------------------------------------------------------+
void SaveSignalToFile(string signal, int groupId)
{
  string dir = "signals";
  string filename = dir + "/" + IntegerToString(groupId) + ".txt";
  int handle = FileOpen(filename, FILE_WRITE|FILE_TXT|FILE_ANSI);
  if(handle == INVALID_HANDLE) {
    Print("SaveSignalToFile: Failed to open file: ", filename);
    return;
  }
  FileWrite(handle, signal);
  FileFlush(handle);
  FileClose(handle);
}

//+------------------------------------------------------------------+
//| getSignal: Load and parse signal for a given groupId           |
//+------------------------------------------------------------------+
Signal GetSignalFromFile(int groupId)
{
  Signal signal;
  string dir = "signals";
  string filename = dir + "/" + IntegerToString(groupId) + ".txt";
  if(!FileExists(filename)) {
    if(debugMode)
      PrintLog(eaName + ": GetSignalFromFile: File not found for GID=" + IntegerToString(groupId));
    return signal;
  }
  int handle = FileOpen(filename, FILE_READ|FILE_SHARE_READ|FILE_TXT|FILE_ANSI);
  if(handle == INVALID_HANDLE) {
    PrintLog(eaName + ": GetSignalFromFile: Failed to open file: " + filename);
    return signal;
  }
  string line = FileReadString(handle);
  FileClose(handle);
  if(StringLen(line) == 0) {
    PrintLog(eaName + ": GetSignalFromFile: Empty signal file for GID=" + IntegerToString(groupId));
    return signal;
  }
  signal = ReadSignalLine(line, false);
  return signal;
}

//+------------------------------------------------------------------+
//| GetMagic: Generate a magic number from a 4-letter channel name |
//+------------------------------------------------------------------+
int GetMagic(string channelName)
{
  if(StringLen(channelName) != 4)
    return 123456; // fallback to default

  int magic = 0;
  for(int i = 0; i < 4; i++) {
    magic = magic * 100 + StringGetCharacter(channelName, i);
  }
  return magic;
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CalculateWarmupLevels: Calculate TP/SL for warmup signals       |
//+------------------------------------------------------------------+
void CalculateWarmupLevels(Signal &signal)
{
  RefreshRates();
  double currentAsk = MarketInfo(signal.symbol, MODE_ASK);
  double currentBid = MarketInfo(signal.symbol, MODE_BID);
  
  // Use current market price as entry
  signal.entry = (signal.type == "BUY") ? currentAsk : currentBid;
  
  // Define warmup TP/SL differences (same as Python used before)
  double tp1Diff = 4.83;  // Average TP1 difference from historical signals
  double tp2Diff = 8.48;  // Average TP2 difference from historical signals  
  double slDiff = 6.0;    // Average SL difference from historical signals
  
  // Calculate TP and SL based on signal type
  if(signal.type == "BUY") {
    signal.tpLevels[0] = signal.entry + tp1Diff;
    signal.tpLevels[1] = signal.entry + tp2Diff;
    signal.stopLoss = signal.entry - slDiff;
  } else { // SELL
    signal.tpLevels[0] = signal.entry - tp1Diff;
    signal.tpLevels[1] = signal.entry - tp2Diff;
    signal.stopLoss = signal.entry + slDiff;
  }
  
  // Set TP count for warmup signals
  signal.tpCount = 2;
  
  int digits = MarketInfo(signal.symbol, MODE_DIGITS);
  PrintLog(eaName + ": Warmup levels calculated - Entry: " + DoubleToString(signal.entry, digits) +
           " TP1: " + DoubleToString(signal.tpLevels[0], digits) +
           " TP2: " + DoubleToString(signal.tpLevels[1], digits) +
           " SL: " + DoubleToString(signal.stopLoss, digits));
}

//+------------------------------------------------------------------+
//| getPositionSize: Calculate position size based on risk management|
//+------------------------------------------------------------------+
double GetPositionSize(Signal &signal)
{
  if(!signal.isValid || signal.tpCount <= 0) {
    PrintLog(eaName + ": Invalid signal for position sizing");
    return fallbackLotSize;
  }

  string symbol = signal.symbol;
  double minLot = MarketInfo(symbol, MODE_MINLOT);
  double maxLot = MarketInfo(symbol, MODE_MAXLOT);
  double lotStep = MarketInfo(symbol, MODE_LOTSTEP);
  double tickSize = MarketInfo(symbol, MODE_TICKSIZE);
  double tickValue = MarketInfo(symbol, MODE_TICKVALUE);
  double currentPrice = signal.type == "BUY" ? MarketInfo(symbol, MODE_ASK) : MarketInfo(symbol, MODE_BID);

// the value of our risk per lot, in the quote currency
  double riskedTicks = MathAbs(currentPrice - signal.stopLoss) / tickSize;
  double riskValuePerLot = tickValue * riskedTicks;

// Calculate maximum loss based on risk percentage (1%)
  double riskAmount = AccountBalance() * accountRiskPercentage / 100.0;

// Calculate total lot size based on risk
  double totalLots = riskAmount / riskValuePerLot;

// Round down to the nearest valid lot step
  double positionSize = MathFloor(totalLots / lotStep) * lotStep;
  double originalPositionSize = positionSize;

// decrease position size until it fits existing margin
// e.g. if we want to use up 70% maximum, we need 100%-70% = 30% remaining
  double minimumRemainingMargin = AccountFreeMargin() * (1 - marginBufferPercentage / 100.0);
  int orderType = (signal.type == "BUY") ? OP_BUY : OP_SELL;
  while(positionSize >= minLot) {
    double freeMarginRemaining = AccountFreeMarginCheck(symbol, orderType, positionSize);
    if (debugMode) {
      PrintLog(eaName + ": Checking margin for " + symbol + ", lot size " + DoubleToString(positionSize, 2) + " - Free remains: " + DoubleToString(freeMarginRemaining, 2) + ", Needed free: " + DoubleToString(minimumRemainingMargin, 2));
    }
    if(freeMarginRemaining >= 0 && freeMarginRemaining >= minimumRemainingMargin && GetLastError() == 0)
      break;
    positionSize -= lotStep;
    positionSize = MathFloor(positionSize / lotStep) * lotStep;
  }

  if(positionSize != originalPositionSize)
    PrintLog(eaName + ": Adjusted position size for " + symbol + " from " + DoubleToString(originalPositionSize, 2) + " to " + DoubleToString(positionSize, 2));

// Divide across TP levels
  positionSize = positionSize / signal.tpCount;
  positionSize = MathFloor(positionSize / lotStep) * lotStep;

// Ensure lot size is within allowed range
  positionSize = MathMax(minLot, MathMin(maxLot, positionSize));

  PrintLog(eaName + ": Position sizing: " + symbol +
           " RiskAmount=" + DoubleToString(riskAmount, 2) +
           " RiskPerLot=" + DoubleToString(riskValuePerLot, 4) +
           " TotalLots=" + DoubleToString(totalLots, 2) +
           " PerTP=" + DoubleToString(positionSize, 2) +
           " TPCount=" + IntegerToString(signal.tpCount));

  return positionSize;
}

//+------------------------------------------------------------------+
//| AddWarmupOrder: Add warmup order to tracking list               |
//+------------------------------------------------------------------+
void AddWarmupOrder(int groupId, string channelName)
{
  // Check if already exists (avoid duplicates)
  for(int i = 0; i < warmupOrderCount; i++) {
    if(warmupOrders[i].isActive && 
       warmupOrders[i].groupId == groupId && 
       warmupOrders[i].channelName == channelName) {
      PrintLog(eaName + ": Warmup order GID=" + IntegerToString(groupId) + " already tracked");
      return;
    }
  }
  
  // Find empty slot or add new
  int slot = -1;
  for(int i = 0; i < warmupOrderCount; i++) {
    if(!warmupOrders[i].isActive) {
      slot = i;
      break;
    }
  }
  
  if(slot == -1 && warmupOrderCount < 100) {
    slot = warmupOrderCount;
    warmupOrderCount++;
  }
  
  if(slot >= 0) {
    warmupOrders[slot].groupId = groupId;
    warmupOrders[slot].channelName = channelName;
    warmupOrders[slot].createdTime = TimeCurrent();
    warmupOrders[slot].isActive = true;
    
    PrintLog(eaName + ": Added warmup order tracking: GID=" + IntegerToString(groupId) + 
             " Channel=" + channelName + " Time=" + TimeToString(warmupOrders[slot].createdTime) +
             " (Active warmups: " + IntegerToString(GetActiveWarmupCount()) + ")");
  } else {
    PrintLog(eaName + ": ERROR: Warmup tracking array full, cannot add GID=" + IntegerToString(groupId));
  }
}

//+------------------------------------------------------------------+
//| RemoveWarmupOrder: Remove warmup order from tracking            |
//+------------------------------------------------------------------+
void RemoveWarmupOrder(int groupId, string channelName)
{
  for(int i = 0; i < warmupOrderCount; i++) {
    if(warmupOrders[i].isActive && 
       warmupOrders[i].groupId == groupId && 
       warmupOrders[i].channelName == channelName) {
      warmupOrders[i].isActive = false;
      PrintLog(eaName + ": Removed warmup tracking: GID=" + IntegerToString(groupId) + " (MODIFY received)" +
               " (Active warmups: " + IntegerToString(GetActiveWarmupCount()) + ")");
      return;
    }
  }
  
  if(debugMode) {
    PrintLog(eaName + ": Warmup order GID=" + IntegerToString(groupId) + " not found in tracking");
  }
}

//+------------------------------------------------------------------+
//| ProcessWarmupTimeouts: Close expired warmup orders              |
//+------------------------------------------------------------------+
void ProcessWarmupTimeouts()
{
  // Early return if no active warmup orders - performance optimization
  bool hasActiveWarmups = false;
  for(int i = 0; i < warmupOrderCount; i++) {
    if(warmupOrders[i].isActive) {
      hasActiveWarmups = true;
      break;
    }
  }
  
  if(!hasActiveWarmups) {
    return; // No warmup orders to check
  }
  
  datetime currentTime = TimeCurrent();
  int timeoutSeconds = warmupTimeoutMinutes * 60;
  
  for(int i = 0; i < warmupOrderCount; i++) {
    if(!warmupOrders[i].isActive) continue;
    
    // Check if warmup order has expired
    if(currentTime - warmupOrders[i].createdTime >= timeoutSeconds) {
      PrintLog(eaName + ": WARMUP TIMEOUT: GID=" + IntegerToString(warmupOrders[i].groupId) + 
               " Channel=" + warmupOrders[i].channelName + 
               " Age=" + IntegerToString(currentTime - warmupOrders[i].createdTime) + "s");
      
      // Close all orders with this GID and channel
      CloseWarmupOrders(warmupOrders[i].groupId, warmupOrders[i].channelName);
      
      // Remove from tracking
      warmupOrders[i].isActive = false;
      if(debugMode) {
        PrintLog(eaName + ": Remaining active warmups: " + IntegerToString(GetActiveWarmupCount()));
      }
    }
  }
}

//+------------------------------------------------------------------+
//| CloseWarmupOrders: Close orders by GID and channel              |
//+------------------------------------------------------------------+
void CloseWarmupOrders(int groupId, string channelName)
{
  int closedCount = 0;
  int total = OrdersTotal();
  
  // Close orders in reverse order to avoid index issues
  for(int i = total - 1; i >= 0; i--) {
    if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
      continue;
    }
    
    // Parse order comment to check GID and channel match
    int orderGid;
    string orderChannel;
    if(!ParseOrderComment(OrderComment(), orderGid, orderChannel)) {
      continue;
    }
    
    if(orderGid == groupId && orderChannel == channelName) {
      double closePrice = (OrderType() == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK);
      
      if(OrderClose(OrderTicket(), OrderLots(), closePrice, slippage, clrRed)) {
        PrintLog(eaName + ": Closed warmup order: Ticket=" + IntegerToString(OrderTicket()) + 
                 " GID=" + IntegerToString(groupId) + " (timeout)");
        closedCount++;
      } else {
        PrintLog(eaName + ": Failed to close warmup order: Ticket=" + IntegerToString(OrderTicket()) + 
                 " Error=" + IntegerToString(GetLastError()));
      }
    }
  }
  
  PrintLog(eaName + ": Closed " + IntegerToString(closedCount) + " warmup orders for GID=" + IntegerToString(groupId));
}

//+------------------------------------------------------------------+
//| GetActiveWarmupCount: Count active warmup orders in tracking    |
//+------------------------------------------------------------------+
int GetActiveWarmupCount()
{
  int count = 0;
  for(int i = 0; i < warmupOrderCount; i++) {
    if(warmupOrders[i].isActive) {
      count++;
    }
  }
  return count;
}
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
