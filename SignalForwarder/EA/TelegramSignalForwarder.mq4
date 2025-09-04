//+------------------------------------------------------------------+
//|                                     TelegramSignalForwarder.mq4  |
//|                Clean, Modular & Readable Code Refactoring       |
//|                           Copyright 2025, OpenAI & User Request  |
//+------------------------------------------------------------------+
#property strict
#property version "2.3.3"

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

//+------------------------------------------------------------------+
//|--- Constants & File Paths                                        |
//+------------------------------------------------------------------+
#define SL_MODIFY_THRESHOLD   0.00001            // Minimum SL diff to apply

static string gTempFile       = "processing.txt";     // Temp file to avoid re-read
static string gSignalFile               = "signals.txt";       // Incoming signal file

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

//+------------------------------------------------------------------+
//|--- Global State Variables                                       |
//+------------------------------------------------------------------+
string   eaName               = "TelegramSignalForwarder";
int      signalFileHandle = -1;                  // File handle for reading signals in test mode
string   storedTestSignal = "";

//+------------------------------------------------------------------+
//|--- Function Prototypes                                          |
//+------------------------------------------------------------------+
void    PrintLog(string message);
Signal ReadSignalFile();
Signal ReadSignalLine(string line, bool shouldValidateTimestamp = false);
Signal ParseFullTradingSignal(string &parts[], bool shouldValidateTimestamp, string line);
Signal ParseActionSignal(string &parts[], bool shouldValidateTimestamp);
Signal ParseModifySignal(string &parts[], bool shouldValidateTimestamp);
void    UpdateExistingOrdersSL(Signal &signal);
void    SendOrders(Signal &signal);
void    ProcessModifySignal(Signal &signal);
void    ProcessBreakevenSignal(Signal &signal);
void    ProcessCloseSignal(Signal &signal);
void    ProcessCloseHalfBreakevenSignal(Signal &signal);
void    ProcessDynamicTrailingStop();
double  CalculateNewSL(int tpHitLevel, Signal &signal);
bool    ParseOrderComment(string comment, int &groupId, string &channelName);

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

    if(hasExistingOrders) {
      if(debugMode)
        PrintLog(eaName + ": Orders with GID=" + IntegerToString(signal.groupId) + " already exist, only updating SL");
      UpdateExistingOrdersSL(signal);
    } else {
      if(debugMode)
        PrintLog(eaName + ": No existing orders found, creating new orders");
      UpdateExistingOrdersSL(signal);
      SendOrders(signal);
    }
    
  } else if(signal.type == "MODIFY") {
    // Process SL modification
    if(debugMode)
      PrintLog(eaName + ": Processing MODIFY signal - GID=" + IntegerToString(signal.groupId) + " NewSL=" + DoubleToString(signal.stopLoss, 5));
    ProcessModifySignal(signal);
    
  } else if(signal.type == "BREAKEVEN") {
    // Process breakeven
    if(debugMode)
      PrintLog(eaName + ": Processing BREAKEVEN signal - GID=" + IntegerToString(signal.groupId));
    ProcessBreakevenSignal(signal);
    
  } else if(signal.type == "CLOSE") {
    // Process close all orders
    if(debugMode)
      PrintLog(eaName + ": Processing CLOSE signal - GID=" + IntegerToString(signal.groupId));
    ProcessCloseSignal(signal);
    
  } else if(signal.type == "CLOSE_HALF_BREAKEVEN") {
    // Process close half + breakeven rest
    if(debugMode)
      PrintLog(eaName + ": Processing CLOSE_HALF_BREAKEVEN signal - GID=" + IntegerToString(signal.groupId));
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
      return signal;
    }
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
    return ParseFullTradingSignal(parts, shouldValidateTimestamp, line);
    
  } else if(signal.type == "BREAKEVEN" || signal.type == "CLOSE") {
    // Action signal format: TIMESTAMP|TYPE|GID:xxx|CHANNEL
    if(partCount < 4) {
      PrintLog(eaName + ": Invalid " + signal.type + " signal format, expected 4 parts but got " + IntegerToString(partCount));
      return signal;
    }
    
    return ParseActionSignal(parts, shouldValidateTimestamp);
    
  } else if(signal.type == "CLOSE_HALF_BREAKEVEN") {
    // Close half + breakeven signal format: TIMESTAMP|TYPE|GID:xxx|CHANNEL
    if(partCount < 4) {
      PrintLog(eaName + ": Invalid CLOSE_HALF_BREAKEVEN signal format, expected 4 parts but got " + IntegerToString(partCount));
      return signal;
    }
    
    return ParseActionSignal(parts, shouldValidateTimestamp);
    
  } else if(signal.type == "MODIFY") {
    // Modify signal format: TIMESTAMP|TYPE|NEW_SL|GID:xxx|CHANNEL
    if(partCount < 5) {
      PrintLog(eaName + ": Invalid MODIFY signal format, expected 5 parts but got " + IntegerToString(partCount));
      return signal;
    }
    
    return ParseModifySignal(parts, shouldValidateTimestamp);
  }

  return signal; // Should not reach here
}

//+------------------------------------------------------------------+
//| ParseFullTradingSignal: Parse BUY/SELL trading signals          |
//+------------------------------------------------------------------+
Signal ParseFullTradingSignal(string &parts[], bool shouldValidateTimestamp, string line)
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
//| ParseActionSignal: Parse BREAKEVEN/CLOSE action signals         |
//+------------------------------------------------------------------+
Signal ParseActionSignal(string &parts[], bool shouldValidateTimestamp)
{
  Signal signal;
  
  // Set basic info
  signal.timestamp = StrToInteger(parts[0]);
  signal.type = parts[1];
  StringToUpper(signal.type);

// 2) Group ID
  string gidPart = parts[2];
  if(StringFind(gidPart, "GID:") != 0) {
    PrintLog(eaName + ": Invalid group ID format '" + gidPart + "', skipping");
    return signal;
  }

  signal.groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
  if(signal.groupId <= 0) {
    PrintLog(eaName + ": Invalid group ID '" + IntegerToString(signal.groupId) + "', skipping");
    return signal;
  }

// 3) Channel Name
  string rawChannelName = parts[3];
  if(StringLen(rawChannelName) == 0)
    rawChannelName = "UNKNOWN";
  signal.channelName = CleanChannelName(rawChannelName);

  if (shouldValidateTimestamp)
    PrintLog(eaName + ": Parsed " + signal.type + " signal GID=" + IntegerToString(signal.groupId) + " from channel '" + signal.channelName + "'");

  signal.isValid = true;
  return signal;
}

//+------------------------------------------------------------------+
//| ParseModifySignal: Parse MODIFY SL signals                      |
//+------------------------------------------------------------------+
Signal ParseModifySignal(string &parts[], bool shouldValidateTimestamp)
{
  Signal signal;
  
  // Set basic info
  signal.timestamp = StrToInteger(parts[0]);
  signal.type = parts[1];
  StringToUpper(signal.type);

// 2) New SL value
  if(!IsValidDouble(parts[2])) {
    PrintLog(eaName + ": Invalid new SL value '" + parts[2] + "', skipping");
    return signal;
  }
  signal.stopLoss = StrToDouble(parts[2]); // Will be normalized later when we know the symbol

// 3) Group ID
  string gidPart = parts[3];
  if(StringFind(gidPart, "GID:") != 0) {
    PrintLog(eaName + ": Invalid group ID format '" + gidPart + "', skipping");
    return signal;
  }

  signal.groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
  if(signal.groupId <= 0) {
    PrintLog(eaName + ": Invalid group ID '" + IntegerToString(signal.groupId) + "', skipping");
    return signal;
  }

// 4) Channel Name
  string rawChannelName = parts[4];
  if(StringLen(rawChannelName) == 0)
    rawChannelName = "UNKNOWN";
  signal.channelName = CleanChannelName(rawChannelName);

  if (shouldValidateTimestamp)
    PrintLog(eaName + ": Parsed MODIFY signal GID=" + IntegerToString(signal.groupId) + " NewSL=" + DoubleToString(signal.stopLoss, 5) + " from channel '" + signal.channelName + "'");

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
    if(debugMode)
      PrintLog(eaName + ": Skipping UpdateExistingOrdersSL for Gold symbol: " + symbol +
               " - avoiding interference with independent trades");
    return;
  }

  int targetOrderType = (signal.type == "BUY") ? OP_BUY : OP_SELL;

  for(int i=0; i<OrdersTotal(); i++) {
    if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
      if(debugMode)
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
    if(!ParseOrderComment(OrderComment(), orderGid, orderChannelName)) {
      if(debugMode)
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
      if(debugMode)
        PrintLog(eaName + ": SL change too small for ticket " + IntegerToString(OrderTicket()) +
                 " - current=" + DoubleToString(currSL, MarketInfo(symbol, MODE_DIGITS)) +
                 " new=" + DoubleToString(signal.stopLoss, MarketInfo(symbol, MODE_DIGITS)));
    }
  }
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

  int slippage = 20;
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
void ProcessModifySignal(Signal &signal)
{
  if(signal.groupId <= 0) {
    PrintLog(eaName + ": Invalid GID in MODIFY signal: " + IntegerToString(signal.groupId));
    return;
  }

  PrintLog(eaName + ": Processing SL modification - GID=" + IntegerToString(signal.groupId) +
           " NewSL=" + DoubleToString(signal.stopLoss, 5));

  int updatedCount = 0;
  int total = OrdersTotal();
  for(int i=0; i<total; i++) {
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

    // Update SL for matching order
    double currentSL = OrderStopLoss();
    int digits = MarketInfo(OrderSymbol(), MODE_DIGITS);
    double normalizedNewSL = NormalizeDouble(signal.stopLoss, digits);

    if(MathAbs(currentSL - normalizedNewSL) > SL_MODIFY_THRESHOLD) {
      double op = OrderOpenPrice();
      double tp = OrderTakeProfit();

      if(OrderModify(OrderTicket(), op, normalizedNewSL, tp, 0, clrGold)) {
        PrintLog(eaName + ": ✅ SL updated for ticket " + IntegerToString(OrderTicket()) +
                 " GID=" + IntegerToString(signal.groupId) +
                 " from " + DoubleToString(currentSL, digits) +
                 " to " + DoubleToString(normalizedNewSL, digits));
        updatedCount++;
      } else {
        PrintLog(eaName + ": ❌ SL update failed for ticket " + IntegerToString(OrderTicket()) +
                 " GID=" + IntegerToString(signal.groupId) +
                 " error=" + IntegerToString(GetLastError()));
      }
    } else {
      PrintLog(eaName + ": SL change too small for ticket " + IntegerToString(OrderTicket()) +
               " - current=" + DoubleToString(currentSL, digits) +
               " new=" + DoubleToString(normalizedNewSL, digits));
    }
  }

  if(updatedCount == 0) {
    PrintLog(eaName + ": ⚠️ No orders found with GID=" + IntegerToString(signal.groupId) + " for SL update");
  } else {
    PrintLog(eaName + ": ✅ Updated SL for " + IntegerToString(updatedCount) + " orders with GID=" + IntegerToString(signal.groupId));
  }
}

//+------------------------------------------------------------------+
//| ProcessBreakevenSignal: Move SL to breakeven for specific GID   |
//+------------------------------------------------------------------+
void ProcessBreakevenSignal(Signal &signal)
{
  if(signal.groupId <= 0) {
    PrintLog(eaName + ": Invalid GID in BREAKEVEN signal: " + IntegerToString(signal.groupId));
    return;
  }

  PrintLog(eaName + ": Processing breakeven - GID=" + IntegerToString(signal.groupId));

  int updatedCount = 0;
  int total = OrdersTotal();
  for(int i=0; i<total; i++) {
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

    // Move SL to breakeven (entry price)
    double currentSL = OrderStopLoss();
    double breakeven = OrderOpenPrice();
    int digits = MarketInfo(OrderSymbol(), MODE_DIGITS);
    double normalizedBreakeven = NormalizeDouble(breakeven, digits);

    if(MathAbs(currentSL - normalizedBreakeven) > SL_MODIFY_THRESHOLD) {
      double tp = OrderTakeProfit();

      if(OrderModify(OrderTicket(), breakeven, normalizedBreakeven, tp, 0, clrBlue)) {
        PrintLog(eaName + ": ✅ SL moved to breakeven for ticket " + IntegerToString(OrderTicket()) +
                 " GID=" + IntegerToString(signal.groupId) +
                 " from " + DoubleToString(currentSL, digits) +
                 " to " + DoubleToString(normalizedBreakeven, digits));
        updatedCount++;
      } else {
        int error = GetLastError();
        PrintLog(eaName + ": ❌ Breakeven failed for ticket " + IntegerToString(OrderTicket()) +
                 " GID=" + IntegerToString(signal.groupId) +
                 " error=" + IntegerToString(error));
        
        // Error 130 = invalid stops (too close to market price)
        // In this case, close the order instead as signal provider likely sees reversal coming
        if(error == 130) {
          PrintLog(eaName + ": Error 130 detected - breakeven too close to market price, closing order instead");
          
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
            continue;
          }

          if(OrderClose(ticket, lots, closePrice, 30, clrOrange)) {
            PrintLog(eaName + ": ✅ Closed order ticket " + IntegerToString(ticket) + " (breakeven too close - error 130)");
            updatedCount++; // Count as processed
          } else {
            PrintLog(eaName + ": ❌ Failed to close order ticket " + IntegerToString(ticket) + 
                     " after breakeven error 130, error=" + IntegerToString(GetLastError()));
          }
        }
      }
    } else {
      PrintLog(eaName + ": SL already at breakeven for ticket " + IntegerToString(OrderTicket()));
    }
  }

  if(updatedCount == 0) {
    PrintLog(eaName + ": ⚠️ No orders found with GID=" + IntegerToString(signal.groupId) + " for breakeven");
  } else {
    PrintLog(eaName + ": ✅ Moved " + IntegerToString(updatedCount) + " orders to breakeven with GID=" + IntegerToString(signal.groupId));
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
      continue; // Skip pending orders for now
    }

    if(OrderClose(ticket, lots, closePrice, 30, clrRed)) {
      PrintLog(eaName + ": ✅ Closed order ticket " + IntegerToString(ticket) +
               " GID=" + IntegerToString(signal.groupId) +
               " Symbol=" + symbol +
               " Lots=" + DoubleToString(lots, 2));
      closedCount++;
    } else {
      PrintLog(eaName + ": ❌ Failed to close order ticket " + IntegerToString(ticket) +
               " GID=" + IntegerToString(signal.groupId) +
               " error=" + IntegerToString(GetLastError()));
    }
  }

  if(closedCount == 0) {
    PrintLog(eaName + ": ⚠️ No orders found with GID=" + IntegerToString(signal.groupId) + " to close");
  } else {
    PrintLog(eaName + ": ✅ Closed " + IntegerToString(closedCount) + " orders with GID=" + IntegerToString(signal.groupId));
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
  
  for(int i=0; i<total; i++) {
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
      continue;
    }

    if(OrderClose(ticket, lots, closePrice, 30, clrRed)) {
      PrintLog(eaName + ": ✅ Closed order ticket " + IntegerToString(ticket) + " (half-close)");
      closedCount++;
    } else {
      PrintLog(eaName + ": ❌ Failed to close order ticket " + IntegerToString(ticket) + 
               " error=" + IntegerToString(GetLastError()));
    }
  }

  // Move remaining orders to breakeven
  for(int i=ordersToClose; i<matchingCount; i++) {
    if(!OrderSelect(matchingTickets[i], SELECT_BY_TICKET)) {
      continue;
    }

    double currentSL = OrderStopLoss();
    double breakeven = OrderOpenPrice();
    int digits = MarketInfo(OrderSymbol(), MODE_DIGITS);
    double normalizedBreakeven = NormalizeDouble(breakeven, digits);

    if(MathAbs(currentSL - normalizedBreakeven) > SL_MODIFY_THRESHOLD) {
      double tp = OrderTakeProfit();

      if(OrderModify(OrderTicket(), breakeven, normalizedBreakeven, tp, 0, clrBlue)) {
        PrintLog(eaName + ": ✅ SL moved to breakeven for ticket " + IntegerToString(OrderTicket()) + " (half-breakeven)");
        breakevenCount++;
      } else {
        int error = GetLastError();
        PrintLog(eaName + ": ❌ Breakeven failed for ticket " + IntegerToString(OrderTicket()) + 
                 " error=" + IntegerToString(error));
        
        // Error 130 = invalid stops (too close to market price)
        // In this case, close the order instead as signal provider likely sees reversal coming
        if(error == 130) {
          PrintLog(eaName + ": Error 130 detected - breakeven too close to market price, closing order instead");
          
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
            continue;
          }

          if(OrderClose(ticket, lots, closePrice, 30, clrOrange)) {
            PrintLog(eaName + ": ✅ Closed order ticket " + IntegerToString(ticket) + " (breakeven too close - error 130)");
            closedCount++; // Count as closed instead of breakeven
          } else {
            PrintLog(eaName + ": ❌ Failed to close order ticket " + IntegerToString(ticket) + 
                     " after breakeven error 130, error=" + IntegerToString(GetLastError()));
          }
        }
      }
    } else {
      PrintLog(eaName + ": SL already at breakeven for ticket " + IntegerToString(OrderTicket()));
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
  if(StringSplit(comment, '|', parts) < 2) {
    PrintLog(eaName + ": Invalid comment format, expected at least 2 parts but got " + IntegerToString(ArraySize(parts)));
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
    Signal signal = GetSignalFromFile(OrderComment());
    if(!signal.isValid) {
      if (signal.groupId != 0)
        PrintLog(eaName + ": cannot find signal in file for GID " + IntegerToString(signal.groupId) + ", skipping TS update");
      continue;
    }

    if(signal.entry == 0.0)
      signal.entry = OrderOpenPrice(); // Use current open price if not set

    double tpLevels[10];

    int tpHitLevel = 0;
    // check if the current M5 bar has touched the TP level
    // it's possible that TP was a momentary spike
    for(int i = 0; i < signal.tpCount; i++) {
      if((OrderType() == OP_BUY && iHigh(OrderSymbol(), PERIOD_M5, 0) >= signal.tpLevels[i]) ||
          (OrderType() == OP_SELL && iLow(OrderSymbol(), PERIOD_M5, 0) <= signal.tpLevels[i])) {
        tpHitLevel = i + 1; // TP levels are 1-based
      }
    }
    if(tpHitLevel <= 0)
      continue; // No TPs hit yet, skip TS for this order
    double currentSL = OrderStopLoss();
    double newSL = CalculateNewSL(tpHitLevel, currentSL, signal);
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
double CalculateNewSL(int tpHitLevel, double currentStop, Signal &signal)
{
  double newSL = currentStop;
  bool isBuy = (signal.type == "BUY");
  if(tpHitLevel <= 0 || signal.tpCount <= 0)
    return currentStop;

  int digits = MarketInfo(signal.symbol, MODE_DIGITS);

  if(stopLossMultiplier < 0) {
    return NormalizeDouble(currentStop, digits); // No multiplier set, return original SL
  }

  if (tpHitLevel == 1) {
    // Use OrderOpenPrice and not signal.entry, because of slippage, actual open price might differ slightly
    double diff = MathAbs(OrderOpenPrice() - signal.stopLoss) * stopLossMultiplier;
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
    PrintLog(eaName + ": SL calculation successful - Level:" + IntegerToString(tpHitLevel) +
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
