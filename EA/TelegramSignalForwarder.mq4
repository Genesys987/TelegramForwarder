//+------------------------------------------------------------------+
//|                                     TelegramSignalForwarder.mq4  |
//|                           Copyright 2025, OpenAI & User Request  |
//+------------------------------------------------------------------+
// Formatting style: K&R, 2 spaces
#property strict
#property version "2.15.0"

#define MAX_TP_LEVELS 10

//+------------------------------------------------------------------+
//|--- Input Parameters (EA Configuration)                         |
//+------------------------------------------------------------------+
input bool   debugMode                = true;  // Enable detailed logging
input int    brokerTimeOffsetMinutes  = 120;   // Broker time offset from UTC in minutes (e.g., UTC+2 = 120)
input int    signalMaxAgeMinutes      = 5;     // Maximum signal age in minutes before rejection
input string symbolPostfix            = "";     // Broker-specific symbol postfix (e.g., ".m", ".ecn")
input double accountRiskPercentage = 1.0; // Risk percentage per trade
input double stopLossMultiplier       = 0.2;   // Factor to adjust SL at TP1 - 0.0 = entry, 1.0 = keep original SL
input double marginBufferPercentage             = 70.0;   // Amount of free margin to use maximum
input int    warmupTimeoutSeconds = 120; // Time in seconds to keep warmup orders before auto-closing
input string lotSizeFactorConfig = ""; // Lot size factor. Format: "channel1:factor1,channel2:factor2"
input double defaultLotSizeFactor = 1.0; // Default TP Weighting, 1.0 = same lots, ~0.7 = exponential
input int    limitOrderExpirationMinutes = 30; // Limit order expiration in minutes
input string channelAllowList = ""; // Channel allowlist. If unfilled, allow all groups. Ex. "THEA,FXPL"
input double stopLossReductionFactor = 0.0; // Factor to reduce original SL for XAUUSD - 0.0 no change, 0.2 reduce by 20% etc.
input bool   aggressiveTrailingStopStrategy = true; // true=Aggressive (TP1->BE, TP2->TP1), false=Conservative (TP1->nothing, TP2->BE, TP3->TP1)
input int    exposureLimit = 0; // maximum amount of simultaneously open trades per channel, 0 = all allowed

//+------------------------------------------------------------------+
//|--- Constants & File Paths                                        |
//+------------------------------------------------------------------+
const double SL_MODIFY_THRESHOLD = 0.00001;            // Minimum SL diff to apply

const string gTempFile       = "processing.txt";     // Temp file to avoid re-read
const string gSignalFile     = "signals.txt";       // Incoming signal file

const int SLIPPAGE = 20;  // maximum allowed slippage during order creation/modification

const int TRAILING_SCAN_PERIOD_SECONDS = 2;

string allowedChannels[];

/*
 * Represents a signal coming from the forwarder.
 * Stored in signals.txt and also in Group ID text files.
 */
struct Signal {
  long               timestamp;
  string             type;
  string             symbol;
  double             entry;
  double             tpLevels[MAX_TP_LEVELS];
  double             lotSizes[MAX_TP_LEVELS];
  int                tpCount;
  double             stopLoss;
  int                groupId;
  string             channelName;
  bool               isValid;
  bool               isWarmup;
  string             signalLine;

                     Signal()
  {
    timestamp    = 0;
    type         = "";
    symbol       = "";
    entry        = 0.0;
    ArrayInitialize(tpLevels, 0.0);
    ArrayInitialize(lotSizes, 0.0);
    tpCount      = 0;
    stopLoss     = 0.0;
    groupId      = 0;
    channelName  = "";
    isValid      = false;
    isWarmup     = false;
    signalLine   = "";
  }
};

/*
 * Represents information stored in order comments.
 */
struct OrderCommentInfo {
  int                groupId;
  string             channelName;
  int                tpLevel;
  bool               isValid;

                     OrderCommentInfo()
  {
    groupId      = 0;
    channelName  = "";
    tpLevel      = 0;
    isValid      = false;
  }
};

//+------------------------------------------------------------------+
//|--- Global State Variables                                       |
//+------------------------------------------------------------------+
string   eaName               = "TelegramSignalForwarder";
int      signalFileHandle = -1;                  // File handle for reading signals in test mode
string   storedTestSignal = "";
int      warmupTickets[];

//+------------------------------------------------------------------+
//|--- Function Prototypes                                          |
//+------------------------------------------------------------------+
void    PrintLog(string message);
Signal ReadSignalFile();
Signal ReadSignalLine(string line, bool isStored);
Signal ParseBuySellSignal(string &parts[], string line, bool isStored);
Signal ParseActionSignal(string &parts[], string line, bool isStored);
void    UpdateExistingOrdersSL(Signal &signal);
void    SendOrders(Signal &signal);
void    ProcessModifySlSignal(Signal &signal);
void    ProcessCloseSignal(Signal &signal);
void    ProcessDynamicTrailingStop();
double  CalculateNewSL(int tpHitLevel, double currentStop, Signal &signal, string channelName);
OrderCommentInfo    ParseOrderComment();
bool CloseCurrentOrder(Signal &signal);
bool SetCurrentOrderStopLoss(Signal &signal);
void SaveSignalToFile(Signal &signal);

// Utility functions
bool    IsChannelAllowed(string channelName);
bool    IsSignalTooOld(long signalTimestampMs, int maxAgeSeconds);
bool    FileExists(string filename);
bool    IsValidDouble(string s);
string  CleanChannelName(string channelName);
string  FormatMT4Comment(int groupId, string channelName, int tpLevel);
int     GetMagic(string channelName);
double  GetLotSizeFactorForChannel(string channelName);
void    SetSignalLotSizes(Signal &signal);
void    ReduceStopLossDistance(Signal &signal, bool isStored);
bool IsTradeAllowed(Signal &signal);

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
    PrintLog(": Initialized");

  StringSplit(channelAllowList, ',', allowedChannels);
  for(int i = 0; i < ArraySize(allowedChannels); i++) {
    StringTrimRight(allowedChannels[i]);
    StringTrimLeft(allowedChannels[i]);
  }

// Use event timer for events
  EventSetTimer(TRAILING_SCAN_PERIOD_SECONDS);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  if(debugMode)
    PrintLog(": Deinitialized, Reason: " + IntegerToString(reason));
}

datetime lastTrailingScanTime = 0;

/*
 * Only used for EA testing - Timer won't run in test mode
 */
void OnTick()
{
  if (!IsTesting()) return;
  datetime currentTime = TimeCurrent();

  if (currentTime - lastTrailingScanTime >= TRAILING_SCAN_PERIOD_SECONDS) {
    lastTrailingScanTime = currentTime;
    OnTimer();
  }
}

//+------------------------------------------------------------------+
//| Timer handler (TRAILING_SCAN_PERIOD_SECONDS)                      |
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

  if(!IsTradeAllowed(signal)) {
    PrintLog("Trade not allowed: " + signal.type + " signal from channel '" + signal.channelName + "' - GID=" + IntegerToString(signal.groupId) + " with " + IntegerToString(signal.tpCount) + " TP levels");
    return;
  }

  if(!IsChannelAllowed(signal.channelName)) {
    PrintLog("Channel not allowed: " + signal.channelName);
    return; // Channel not allowed
  }

// Handle different signal types
  if(signal.type == "BUY" || signal.type == "SELL") {
    // Process trading signals
    if(debugMode)
      PrintLog(": Processing " + signal.type + " signal from channel '" + signal.channelName + "' - GID=" + IntegerToString(signal.groupId) + " with " + IntegerToString(signal.tpCount) + " TP levels");

    // Check if orders with this GID already exist
    bool hasExistingOrders = false;
    for(int i=0; i<OrdersTotal(); i++) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
        OrderCommentInfo info = ParseOrderComment();
        if(info.isValid) {
          if(info.groupId == signal.groupId && info.channelName == signal.channelName) {
            hasExistingOrders = true;
            break;
          }
        }
      }
    }

    UpdateExistingOrdersSL(signal);

    if(hasExistingOrders) {
      if(debugMode)
        PrintLog(": Orders with GID=" + IntegerToString(signal.groupId) + " already exist, only updating SL");
    } else {
      if(debugMode)
        PrintLog(": No existing orders found, creating new orders");
      SendOrders(signal);
    }

  } else if(signal.type == "MODIFY" || signal.type == "BREAKEVEN") {
    ProcessModifySlSignal(signal);
  } else if(signal.type == "CLOSE") {
    ProcessCloseSignal(signal);
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
        PrintLog(": Opening signal file " + gSignalFile);
        if(signalFileHandle == INVALID_HANDLE) {
          PrintLog(": Failed to open signal file");
          return signal;
        }
      }

      if(signalFileHandle == INVALID_HANDLE) {
        PrintLog(": Failed to open temp file for reading");
        return signal;
      }
      // in test mode, we keep the file open to read multiple signals
      if(IsTesting() && FileIsEnding(signalFileHandle)) {
        FileClose(signalFileHandle);
        return signal;
      }
      line = FileReadString(signalFileHandle);
      if(debugMode) {
        PrintLog(": Read signal line: [" + line + "]");
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
      PrintLog(": Empty signal line, skipping");
      return signal;
    }

    signal = ReadSignalLine(line, /* isStored */ false);

    bool isSymbolMatching = signal.symbol == Symbol();
    shouldKeepReading = IsTesting() && signal.isValid && !isSymbolMatching && !FileIsEnding(signalFileHandle);
    if(shouldKeepReading) {
      storedTestSignal = "";
      PrintLog(": Continuing to read next signal line for testing - current symbol: " + Symbol() +
               ", signal symbol: " + signal.symbol);
    }
  } while(shouldKeepReading);

  if(signal.isValid) {
    PrintLog(": Found valid signal: " + line);
    storedTestSignal = "";
    SaveSignalToFile(signal);
  }

  return signal;
}

//+------------------------------------------------------------------+
//|  ReadSignalLine: Parse a single signal line into Signal struct   |
//|  isStored: if false, will check signal age                       |
//|  (stored: test file or stored signal files)                      |
//+------------------------------------------------------------------+
Signal ReadSignalLine(string line, bool isStored)
{
  Signal signal;
  signal.signalLine = line;
// Expect different formats based on signal type:
// BUY/SELL: 123456789|TYPE|SYMBOL|ENTRY|TP1,TP2,TP3,...|SL|GID:<id>|CHANNEL_NAME
// BREAKEVEN/CLOSE: 123456789|TYPE|GID:<id>|CHANNEL_NAME
// MODIFY: 123456789|TYPE|NEW_SL|GID:<id>|CHANNEL_NAME
  string parts[];
  int partCount = StringSplit(line, '|', parts);

  if(partCount < 4) {
    PrintLog(": Invalid signal format, expected at least 4 parts but got " + IntegerToString(partCount));
    return signal;
  }

  for(int i = 0; i < ArraySize(parts); i++) {
    StringTrimRight(parts[i]);
    StringTrimLeft(parts[i]);
  }

// 0) Extract and validate timestamp (first part, no prefix)
  string timestampStr = parts[0];
  long signalTimestamp = StrToInteger(timestampStr);
  signal.timestamp = signalTimestamp;
  if(!isStored && IsSignalTooOld(signalTimestamp, signalMaxAgeMinutes * 60)) {
    if(!IsTesting()) {
      PrintLog(": Signal too old, skipping. Timestamp=" + IntegerToString(signalTimestamp));
    } else {
      storedTestSignal = line;
    }
    return signal;
  }

  bool isLive = !isStored;
// 1) Signal type
  signal.type = parts[1];
  StringToUpper(signal.type);
  if(signal.type != "BUY" && signal.type != "SELL" && signal.type != "BREAKEVEN" && signal.type != "CLOSE" && signal.type != "MODIFY" && !isStored) {
    PrintLog(": Invalid signal type '" + signal.type + "', expected BUY, SELL, BREAKEVEN, CLOSE, MODIFY");
    return signal;
  }

// Handle different signal types with different parsing logic
  if(signal.type == "BUY" || signal.type == "SELL") {
    // Full trading signal format: TIMESTAMP|TYPE|SYMBOL|ENTRY|TP1,TP2,...|SL|GID:xxx|CHANNEL
    if(partCount < 8 && isLive) {
      PrintLog(": Invalid BUY/SELL signal format, expected 8 parts but got " + IntegerToString(partCount));
      return signal;
    }

    // Parse full trading signal
    return ParseBuySellSignal(parts, line, isStored);

  } else if(signal.type == "BREAKEVEN" || signal.type == "CLOSE" || signal.type == "MODIFY") {
    // Action signal format: TIMESTAMP|TYPE|GID:xxx|CHANNEL
    if(partCount < 4) {
      if (isLive)
        PrintLog(": Invalid " + signal.type + " signal format, expected 4 parts but got " + IntegerToString(partCount));
      return signal;
    }

    return ParseActionSignal(parts, line, isStored);

  }

  return signal; // Should not reach here
}

//+------------------------------------------------------------------+
//| ParseFullTradingSignal: Parse BUY/SELL trading signals          |
//+------------------------------------------------------------------+
Signal ParseBuySellSignal(string &parts[], string line, bool isStored)
{
  Signal signal;
  signal.signalLine = line;
  bool isLive = !isStored;

// Set basic info
  signal.timestamp = StrToInteger(parts[0]);
  signal.type = parts[1];
  StringToUpper(signal.type);

// 2) Symbol validation
  signal.symbol = parts[2] + symbolPostfix;
  if(MarketInfo(signal.symbol, MODE_TIME) == 0) {
    if (isLive)
      PrintLog(": Invalid symbol '" + signal.symbol + "', skipping");
    return signal;
  }

// 3) Entry price
  if(!IsValidDouble(parts[3])) {
    if (isLive)
      PrintLog(": Invalid entry price '" + parts[3] + "', skipping");
    return signal;
  }
  signal.entry = NormalizeDouble(StrToDouble(parts[3]), MarketInfo(signal.symbol, MODE_DIGITS));

// 4) TP levels - dynamic parsing with bounds checking
  string tpsArr[];
  signal.tpCount = StringSplit(parts[4], ',', tpsArr);
  if(signal.tpCount < 1) {
    if (isLive)
      PrintLog(": Invalid TP levels '" + parts[4] + "', skipping");
    return signal;
  }

// Resize array to hold all TPs (up to maximum)
  ArrayResize(signal.tpLevels, signal.tpCount);
// Parse all TP levels
  for(int i=0; i<signal.tpCount; i++) {
    if(!IsValidDouble(tpsArr[i])) {
      if (isLive)
        PrintLog(": Invalid TP level[" + IntegerToString(i) + "] '" + tpsArr[i] + "', skipping");
      return signal;
    }
    signal.tpLevels[i] = NormalizeDouble(StrToDouble(tpsArr[i]), MarketInfo(signal.symbol, MODE_DIGITS));
  }

// Validate TP order and remove duplicates
  bool shouldBuy = signal.type == "BUY";
  for(int i=0; i<signal.tpCount; i++) {
    // Check TP direction relative to entry
    if (signal.entry != 0.0) {
      if(i > 0) {
        if(shouldBuy && signal.tpLevels[i] <= signal.tpLevels[i-1] && isLive) {
          PrintLog(": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(signal.tpLevels[i], MarketInfo(signal.symbol, MODE_DIGITS)) +
                   " should be higher than TP[" + IntegerToString(i-1) + "] " + DoubleToString(signal.tpLevels[i-1], MarketInfo(signal.symbol, MODE_DIGITS)) + " for BUY");
        } else if(!shouldBuy && signal.tpLevels[i] >= signal.tpLevels[i-1] && !isStored) {
          PrintLog(": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(signal.tpLevels[i], MarketInfo(signal.symbol, MODE_DIGITS)) +
                   " should be lower than TP[" + IntegerToString(i-1) + "] " + DoubleToString(signal.tpLevels[i-1], MarketInfo(signal.symbol, MODE_DIGITS)) + " for SELL");
        }
      }

      if(shouldBuy && signal.tpLevels[i] <= signal.entry && isLive) {
        PrintLog(": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(signal.tpLevels[i], MarketInfo(signal.symbol, MODE_DIGITS)) +
                 " should be higher than entry " + DoubleToString(signal.entry, MarketInfo(signal.symbol, MODE_DIGITS)) + " for BUY");
      } else if(!shouldBuy && signal.tpLevels[i] >= signal.entry && isLive) {
        PrintLog(": Warning: TP[" + IntegerToString(i) + "] " + DoubleToString(signal.tpLevels[i], MarketInfo(signal.symbol, MODE_DIGITS)) +
                 " should be lower than entry " + DoubleToString(signal.entry, MarketInfo(signal.symbol, MODE_DIGITS)) + " for SELL");
      }
    }
  }

// 5) Stop loss
  string rawSL = parts[5];

  if(!IsValidDouble(rawSL)) {
    if (!isStored)
      PrintLog(": Invalid stop loss '" + rawSL + "', skipping");
    return signal;
  }

  signal.stopLoss = NormalizeDouble(StrToDouble(rawSL), MarketInfo(signal.symbol, MODE_DIGITS));
  ReduceStopLossDistance(signal, isStored);
// Validate SL position relative to entry price (if not market entry)
  if(signal.entry != 0.0) {
    if(shouldBuy && signal.stopLoss >= signal.entry && !isStored) {
      PrintLog(": Warning: SL " + DoubleToString(signal.stopLoss, MarketInfo(signal.symbol, MODE_DIGITS)) +
               " should be below entry " + DoubleToString(signal.entry, MarketInfo(signal.symbol, MODE_DIGITS)) + " for BUY");
      return signal;
    } else if(!shouldBuy && signal.stopLoss <= signal.entry && !isStored) {
      PrintLog(": Warning: SL " + DoubleToString(signal.stopLoss, MarketInfo(signal.symbol, MODE_DIGITS)) +
               " should be above entry " + DoubleToString(signal.entry, MarketInfo(signal.symbol, MODE_DIGITS)) + " for SELL");
      return signal;
    }
  }

// 6) Group ID
  string gidPart = parts[6];
  if(StringFind(gidPart, "GID:") != 0) {
    PrintLog(": Invalid group ID format '" + gidPart + "', skipping");
    return signal;
  }

  signal.groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
  if(signal.groupId <= 0) {
    PrintLog(": Invalid group ID '" + IntegerToString(signal.groupId) + "', skipping");
    return signal;
  }

// 7) Channel Name
  if(ArraySize(parts) >= 8) {
    string rawChannelName = parts[7];
    if(StringLen(rawChannelName) == 0)
      rawChannelName = "UNKNOWN";
    signal.channelName = CleanChannelName(rawChannelName);
  } else {
    signal.channelName = "LEGC";
  }

  signal.isWarmup = (signal.entry == 0.0 && signal.stopLoss == 0.0 &&
                     signal.tpCount >= 2 && signal.tpLevels[0] == 0.0 && signal.tpLevels[1] == 0.0);

  if(!isStored) {
    PrintLog(": Parsed trading signal GID=" + IntegerToString(signal.groupId) + " from channel '" + signal.channelName + "'");
  }

  signal.isValid = true;

  return signal;
}

//+------------------------------------------------------------------+
//| ParseModifySignal: Parse MODIFY/CLOSE etc. SL signals                      |
//+------------------------------------------------------------------+
Signal ParseActionSignal(string &parts[], string line, bool isStored)
{
  Signal signal;
  signal.signalLine = line;

// Set basic info
  signal.timestamp = StrToInteger(parts[0]);
  signal.type = parts[1];
  StringToUpper(signal.type);

  bool isModifySignal = signal.type == "MODIFY";

  if (isModifySignal) {
    int partCount = ArraySize(parts);

    if (partCount == 8) {
      // Warmup finalization format (also sets TP): TIMESTAMP|MODIFY|SYMBOL|ENTRY|TP1,TP2|SL|GID:xxx|CHANNEL
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
      // We adjust the SL based on the "official" entry in the signal
      ReduceStopLossDistance(signal, isStored);

      // Parse GID
      string gidPart = parts[6];
      if(StringFind(gidPart, "GID:") == 0) {
        signal.groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
      }

      // Parse channel name
      signal.channelName = CleanChannelName(parts[7]);

      if (!isStored)
        PrintLog(": Parsed MODIFY signal GID=" + IntegerToString(signal.groupId) +
                 " Symbol=" + signal.symbol +
                 " NewSL=" + DoubleToString(signal.stopLoss, MarketInfo(signal.symbol, MODE_DIGITS)) +
                 " TPCount=" + IntegerToString(signal.tpCount) +
                 " from channel '" + signal.channelName + "'");
    } else if (partCount == 5) {
      // Regular SL modification format: TIMESTAMP|MODIFY|NEW_SL|GID:xxx|CHANNEL
      string slPart = parts[2];
      if(!IsValidDouble(slPart)) {
        PrintLog(eaName + ": Invalid new SL value '" + slPart + "', skipping");
        return signal;
      }
      signal.stopLoss = StrToDouble(slPart);
      // ReduceStopLossDistance is not called for regular SL modify

      // Parse GID
      string gidPart = parts[3];
      if(StringFind(gidPart, "GID:") == 0) {
        signal.groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
      }

      // Parse channel name
      signal.channelName = CleanChannelName(parts[4]);

      PrintLog(eaName + ": Parsed old format MODIFY signal GID=" + IntegerToString(signal.groupId) +
               " NewSL=" + DoubleToString(signal.stopLoss, 5) +
               " from channel '" + signal.channelName + "'");
    } else {
      PrintLog(eaName + ": Invalid MODIFY signal format, expected 5 or 8 parts but got " + IntegerToString(partCount));
      return signal;
    }
  } else {
    // BREAKEVEN/CLOSE signals
    // Example: TIMESTAMP|CLOSE|GID:xxx|CHANNEL
    int shift = 0;

    // Group ID
    string gidPart = parts[2 + shift];
    if(StringFind(gidPart, "GID:") != 0) {
      PrintLog(": Invalid group ID format '" + gidPart + "', skipping");
      return signal;
    }

    signal.groupId = (int)StrToInteger(StringSubstr(gidPart, 4));
    if(signal.groupId <= 0) {
      PrintLog(": Invalid group ID '" + IntegerToString(signal.groupId) + "', skipping");
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

// Keep original symbol for MarketInfo lookups (case-sensitive)
  string symbol = signal.symbol;
// Use an uppercase copy only for string comparisons (e.g. symbol name contains "XAUUSD")
  string symbolUpper = symbol;
  StringToUpper(symbolUpper);

  if(StringFind(symbolUpper, "XAUUSD") >= 0) {
    PrintLog(": Skipping UpdateExistingOrdersSL for Gold symbol: " + symbol +
             " - avoiding interference with independent trades");
    return;
  }

  bool isBuy = signal.type == "BUY";

// Read digits for the real broker symbol once and reuse it
  int digits = MarketInfo(symbol, MODE_DIGITS);

// Determine expected order types clearly
  int expectedMarketType = isBuy ? OP_BUY : OP_SELL;
  int expectedLimitType  = isBuy ? OP_BUYLIMIT : OP_SELLLIMIT;

  for(int i=0; i<OrdersTotal(); i++) {
    if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
      PrintLog(": Failed to select order at index " + IntegerToString(i) + " - error=" + IntegerToString(GetLastError()));
      continue;
    }

    // Symbol or type mismatch -> skip
    if(OrderSymbol() != signal.symbol || (OrderType() != expectedMarketType && OrderType() != expectedLimitType)) {
      if(debugMode)
        PrintLog(": Ignoring order at index " + IntegerToString(i) + " - symbol/type mismatch");
      continue;
    }

    // Parse the order's comment to get channel information
    OrderCommentInfo info = ParseOrderComment();
    if(!info.isValid) {
      PrintLog(": Failed to parse order comment for ticket " + IntegerToString(OrderTicket()) + ": " + OrderComment());
      continue;
    }

    // Only update SL if the order is from the same channel
    if(info.channelName != signal.channelName) {
      if(debugMode)
        PrintLog(": Ignoring order ticket " + IntegerToString(OrderTicket()) +
                 " - different channel (order='" + info.channelName + "', signal='" + signal.channelName + "')");
      continue;
    }

    double currSL = OrderStopLoss();
    if(MathAbs(currSL - signal.stopLoss) > SL_MODIFY_THRESHOLD) {
      double openP = OrderOpenPrice();
      double tp    = OrderTakeProfit();
      bool ok = OrderModify(OrderTicket(), openP, signal.stopLoss, tp, OrderExpiration(), clrBlue);
      if(ok)
        PrintLog(": Updated SL for ticket=" + IntegerToString(OrderTicket()) +
                 " from channel '" + signal.channelName + "' (" + DoubleToString(currSL, digits) +
                 " -> " + DoubleToString(signal.stopLoss, digits) + ")");
      else
        PrintLog(": SL update failed ticket=" + IntegerToString(OrderTicket()) +
                 " err=" + IntegerToString(GetLastError()));
    } else {
      PrintLog(": SL change too small for ticket " + IntegerToString(OrderTicket()) +
               " - current=" + DoubleToString(currSL, digits) +
               " new=" + DoubleToString(signal.stopLoss, digits));
    }
  }

  PrintLog(": Completed UpdateExistingOrdersSL check for existing orders from channel '" + signal.channelName + "'");
}

//+------------------------------------------------------------------+
//| SendOrders: Place market or limit orders with SL & TP        |
//+------------------------------------------------------------------+
void SendOrders(Signal &signal)
{
// Only send orders for trading signals (BUY/SELL)
  if(signal.type != "BUY" && signal.type != "SELL") {
    return;
  }

  if(signal.isWarmup) {
    PrintLog(": WARMUP SIGNAL detected - Calculating TP/SL levels for GID=" + IntegerToString(signal.groupId));
    SetWarmupLevels(signal);
  }

// if the signal entry is 0, we always enter with market order
// otherwise, if there's an entry price, we treat it as an entry limit
  bool isImmediateOrder = signal.entry == 0.0;
  if(isImmediateOrder) {
    // using market entry
    RefreshRates();
    double currentAsk = MarketInfo(signal.symbol, MODE_ASK);
    double currentBid = MarketInfo(signal.symbol, MODE_BID);

    signal.entry = (signal.type == "BUY") ? currentAsk : currentBid;

    PrintLog(": IMMEDIATE ENTRY detected - Using market price: " +
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
// we save the orginial TP1 before modifying lot sizes/TP levels
  double tp1 = signal.tpLevels[0];

  double price = shouldBuy ? ask : bid;
  price = NormalizeDouble(price, digits);

  bool isPriceBeyondTp1 = shouldBuy ? price > tp1 : price < tp1;
  if(isPriceBeyondTp1 && isImmediateOrder) {
    PrintLog(": Entry price for immediate order " + DoubleToString(price, digits) +
             " is beyond TP1 " + DoubleToString(tp1, digits) +
             " for GID=" + IntegerToString(signal.groupId) +
             ", skipping order creation");
    return;
  }

// Always use the original stop loss from signal
  double rawSL = NormalizeDouble(signal.stopLoss, digits);

// Apply minimum distance for SL if needed
  double minDist = MathMax(stopLevel * point, point);
  if(shouldBuy && price - rawSL < minDist)
    rawSL = price - minDist;
  if(!shouldBuy && rawSL - price < minDist)
    rawSL = price + minDist;
  rawSL = NormalizeDouble(rawSL, digits);

// Normalize all TP levels and ensure minimum distance
  for(int j=0; j<signal.tpCount; j++) {
    signal.tpLevels[j] = NormalizeDouble(signal.tpLevels[j], digits);
    double dist = MathAbs(signal.tpLevels[j] - signal.entry);
    if(dist < minDist)
      signal.tpLevels[j] = (shouldBuy) ? price + minDist : price - minDist;
    signal.tpLevels[j] = NormalizeDouble(signal.tpLevels[j], digits);
  }

  PrintLog(": Sending orders for GID=" + IntegerToString(signal.groupId) +
           " from channel '" + signal.channelName + "'" +
           " Using SL=" + DoubleToString(rawSL, digits) +
           " TP Count=" + IntegerToString(signal.tpCount));

  color cols[6] = { clrBlue, clrGreen, clrRed, clrYellow, clrMagenta, clrCyan };
  SetSignalLotSizes(signal);

// We allow entering halfway until TP1
  double allowedEntryLevel = (signal.entry + tp1) / 2;

// Create orders for each TP level
  for(int k=0; k < signal.tpCount; k++) {
    double lotSize = signal.lotSizes[k];
    if(lotSize <= 0) {
      PrintLog("TP levels from " + IntegerToString(k + 1) + " to " + IntegerToString(signal.tpCount) + " have been dropped to limit risk");
      break;
    }
    // for market orders we want to get the correct current price
    // to avoid off-quotes errors
    RefreshRates();
    ask = MarketInfo(signal.symbol, MODE_ASK);
    bid = MarketInfo(signal.symbol, MODE_BID);
    bool shouldUseLimitOrder = !isImmediateOrder && (shouldBuy ? (allowedEntryLevel <= bid) : (ask <= allowedEntryLevel));
    if (shouldUseLimitOrder) {
      PrintLog("Using limit order for TP level " + IntegerToString(k + 1));
    }
    price = shouldUseLimitOrder ? allowedEntryLevel : (shouldBuy ? ask : bid);
    int orderType = shouldBuy ? (shouldUseLimitOrder ? OP_BUYLIMIT : OP_BUY) : (shouldUseLimitOrder ? OP_SELLLIMIT : OP_SELL);
    string comment = FormatMT4Comment(signal.groupId, signal.channelName, k + 1);
    int magicNumber = GetMagic(signal.channelName);
    datetime expiration = shouldUseLimitOrder ? (TimeCurrent() + limitOrderExpirationMinutes * 60) : 0;
    PrintLog(": Order[" + IntegerToString(k) + "] parameters: " +
             "Symbol=" + signal.symbol +
             " Type=" + IntegerToString(orderType) +
             " Lots=" + DoubleToString(lotSize, 2) +
             " Price=" + DoubleToString(price, digits) +
             " SL=" + DoubleToString(rawSL, digits) +
             " TP=" + DoubleToString(signal.tpLevels[k], digits) +
             " Expiration=" + TimeToString(expiration, TIME_DATE | TIME_SECONDS) +
             " Comment=" + comment +
             " Magic=" + magicNumber);

    int colorIndex = k % 6;

    int ticket = OrderSend(signal.symbol, orderType, lotSize, price, SLIPPAGE,
                           rawSL, signal.tpLevels[k], comment, magicNumber, expiration, cols[colorIndex]);

    if(ticket < 0) {
      PrintLog(": ❌ Failed to create order[" + IntegerToString(k) + "] - " +
               "Error=" + IntegerToString(GetLastError()) +
               " (SL may be too close to entry price)");
    }

    if(ticket > 0 && signal.isWarmup) {
      PrintLog(": Warmup order created, storing ticket=" + IntegerToString(ticket) + " for GID=" + IntegerToString(signal.groupId));
      ArrayResize(warmupTickets, ArraySize(warmupTickets) + 1);
      warmupTickets[ArraySize(warmupTickets) - 1] = ticket;
    }

    PrintLog(": Order[" + IntegerToString(k) + "] ticket=" + IntegerToString(ticket));
  }
}

//+------------------------------------------------------------------+
//| ProcessModifySignal: Apply SL modification for specific GID     |
//+------------------------------------------------------------------+
void ProcessModifySlSignal(Signal &signal)
{
  if(signal.groupId <= 0) {
    PrintLog(": Invalid GID in signal: " + IntegerToString(signal.groupId));
    return;
  }

// if not modify, then breakeven
  bool isModifySignal = signal.type == "MODIFY";
  string operation = isModifySignal ? "SL modification" : "SL breakeven";
  PrintLog(": Processing " + operation + " - GID=" + IntegerToString(signal.groupId) +
           " NewSL=" + DoubleToString(signal.stopLoss, 5));

  int updatedCount = 0;
  int total = OrdersTotal();
// Close orders in reverse order to avoid index issues
  for(int i=total-1; i>=0; i--) {
    if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
      continue;
    }

    // Parse order comment to check GID match
    OrderCommentInfo info = ParseOrderComment();
    if(!info.isValid) {
      continue;
    }

    if(info.groupId != signal.groupId || info.channelName != signal.channelName) {
      continue;
    }

    if(SetCurrentOrderStopLoss(signal)) {
      updatedCount++;
    }
  }

  if(updatedCount == 0) {
    PrintLog(": ⚠️ No orders found with GID=" + IntegerToString(signal.groupId) + " for " + operation);
  } else {
    PrintLog(": ✅ " + operation + " for " + IntegerToString(updatedCount) + " orders with GID=" + IntegerToString(signal.groupId));
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

    if (OrderModify(OrderTicket(), op, normalizedNewSL, newTp, OrderExpiration(), clrGold)) {
      string logMsg = "✅ " + operation + " success for ticket " + IntegerToString(OrderTicket()) +
                      " GID=" + IntegerToString(signal.groupId);

      if (slChanged) {
        logMsg += " SL: " + DoubleToString(currentSL, digits) + " -> " + DoubleToString(normalizedNewSL, digits);
      }

      if (tpChanged) {
        logMsg += " TP: " + DoubleToString(currentTP, digits) + " -> " + DoubleToString(newTp, digits);
      }

      PrintLog(": " + logMsg);
      return true;
    } else {
      int error = GetLastError();
      PrintLog(": ❌ " + operation + " failed for ticket " + IntegerToString(OrderTicket()) +
               " GID=" + IntegerToString(signal.groupId) +
               " error=" + IntegerToString(error));

      if (error == ERR_INVALID_STOPS && !isModifySignal) {
        PrintLog(": Error 130 detected - breakeven too close, closing order instead");
        return CloseCurrentOrder(signal);
      } else {
        return false;
      }
    }
  } else {
    PrintLog(": No significant changes for ticket " + IntegerToString(OrderTicket()) +
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
    PrintLog(": Invalid GID in CLOSE signal: " + IntegerToString(signal.groupId));
    return;
  }

  PrintLog(": Processing close all orders - GID=" + IntegerToString(signal.groupId));

  int closedCount = 0;
  int total = OrdersTotal();

// Close orders in reverse order to avoid index issues
  for(int i=total-1; i>=0; i--) {
    if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
      continue;
    }

    // Parse order comment to check GID match
    OrderCommentInfo info = ParseOrderComment();
    if(!info.isValid) {
      continue;
    }

    if(info.groupId != signal.groupId || info.channelName != signal.channelName) {
      continue;
    }

    if (CloseCurrentOrder(signal)) {
      closedCount++;
    }
  }

  if(closedCount == 0) {
    PrintLog(": No orders found with GID=" + IntegerToString(signal.groupId) + " to close");
  } else {
    PrintLog(": Closed " + IntegerToString(closedCount) + " orders with GID=" + IntegerToString(signal.groupId));
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
  double closePrice = 0.0;
  if(orderType == OP_BUY) {
    closePrice = MarketInfo(symbol, MODE_BID);
  } else if(orderType == OP_SELL) {
    closePrice = MarketInfo(symbol, MODE_ASK);
  }

  bool isPendingOrder = orderType == OP_BUYLIMIT || orderType == OP_SELLLIMIT;
  if(isPendingOrder ?
      OrderDelete(ticket) :
      OrderClose(ticket, lots, closePrice, SLIPPAGE, clrRed)) {
    PrintLog(": ✅ Closed order ticket " + IntegerToString(ticket) +
             " GID=" + IntegerToString(signal.groupId) +
             " Symbol=" + symbol +
             " Lots=" + DoubleToString(lots, 2));
    return true;
  } else {
    PrintLog(": ❌ Failed to close order ticket " + IntegerToString(ticket) +
             " GID=" + IntegerToString(signal.groupId) +
             " error=" + IntegerToString(GetLastError()));
    return false;
  }
}

//+------------------------------------------------------------------+
//| ParseOrderGidChannel: Extract GID and channel name from order comment |
//+------------------------------------------------------------------+
OrderCommentInfo ParseOrderComment()
{
// 1234|ABCD|1.2550,1.2600 (GID|CHANNEL|TP1,TP2,...)
  string comment = OrderComment();
  OrderCommentInfo info;
  string parts[];
  int partCount = StringSplit(comment, '|', parts);
  if(partCount < 3 && debugMode) {
    PrintLog(": Invalid comment format, expected at least 2 parts but got " + IntegerToString(partCount));
    info.isValid = false;
    return(info);
  }

// Extract GID (first part)
  info.groupId = StrToInteger(parts[0]);
  if(info.groupId <= 0) {
    if(debugMode)
      PrintLog(": Invalid GID in comment: " + comment);
    info.isValid = false;
    return(info);
  }

// Extract channel name (second part, should be 4 letters)
  info.channelName = parts[1];
  if(StringLen(info.channelName) != 4) {
    if(debugMode)
      PrintLog(": Invalid channel name length in new comment: " + comment);
    info.channelName = "UNKN"; // Fallback
  }

// may have [sl] or [tp] postfix in closed order comment
  info.tpLevel = StrToInteger(StringSubstr(parts[2], 0, 1));

  info.isValid = true;
  return(info);
}

//+-------------------------------------------------------------------------+
//| Determines whether a channel is allowed based on the channel allowlist. |
//+-------------------------------------------------------------------------+
bool IsChannelAllowed(string channelName)
{
  if(StringLen(channelName) != 4)
    return(false);

// if array is not set, then we allow all channels
  if(ArraySize(allowedChannels) == 0)
    return(true);

  for(int i = 0; i < ArraySize(allowedChannels); i++) {
    if(StringCompare(channelName, allowedChannels[i], false) == 0)
      return(true);
  }
  return(false);
}

//+------------------------------------------------------------------+
//| IsSignalTooOld: validate if signal timestamp is too old         |
//+------------------------------------------------------------------+
bool IsSignalTooOld(long signalTimestamp, int maxAgeSeconds)
{
  if(signalTimestamp <= 0)
    return(true);

  datetime signalTime = (datetime)(signalTimestamp);

// Get current broker time and convert to UTC
  datetime brokerTime = TimeCurrent();
  datetime utcTime = brokerTime - (brokerTimeOffsetMinutes * 60);

// Calculate age in minutes
  int ageSeconds = (int)(utcTime - signalTime);

  if(IsTesting() && ageSeconds < 0) {
    // In testing mode, allow negative age (future signals)
    return(true);
  }

  bool isTooOld = ageSeconds > maxAgeSeconds;

  if(debugMode || isTooOld)
    PrintLog(": Signal age check - UTC now: " + TimeToString(utcTime) +
             ", Signal time: " + TimeToString(signalTime) +
             ", Age: " + IntegerToString(ageSeconds / 60) + " minutes");

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
  OrderCommentInfo lastOrderInfos[5];
  int totalOrders = OrdersHistoryTotal();

// look back on the last 5 closed orders to check for momentary TP hits
  int ordersProcessed = 0;

  for (int i = totalOrders - 1; i >= 0 && ordersProcessed < 5; i--) {
    if (OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) {
      if (OrderType() == OP_BUY || OrderType() == OP_SELL) {
        lastOrderInfos[ordersProcessed] = ParseOrderComment();

        if(lastOrderInfos[ordersProcessed].isValid)
          ordersProcessed++;
      }
    }
  }

// Iterate through all open orders
  for(int o = 0; o < OrdersTotal(); o++) {
    if(!OrderSelect(o, SELECT_BY_POS, MODE_TRADES))
      continue;

    // Only consider buy & sell orders
    if(OrderType() != OP_BUY && OrderType() != OP_SELL)
      continue;

    // Parse order comment to get GID and channel name
    OrderCommentInfo info = ParseOrderComment();
    if(!info.isValid) {
      if(debugMode)
        PrintLog(": Failed to parse order comment for ticket " + IntegerToString(OrderTicket()) + ": " + OrderComment());
      continue;
    }

    Signal signal = GetSignalFromFile(info.groupId);
    if(!signal.isValid) {
      if(debugMode)
        PrintLog(": cannot find signal in file for GID " + IntegerToString(info.groupId) + ", skipping TS update");
      continue;
    }
    if(signal.isWarmup) {
      bool isSignalTooOld = MathAbs(OrderOpenTime() - TimeCurrent()) > warmupTimeoutSeconds;
      if (isSignalTooOld) {
        PrintLog(": Warmup order ticket " + IntegerToString(OrderTicket()) +
                 " is too old, closing order");
        CloseCurrentOrder(signal);
      }
      continue;
    }

    if(signal.entry == 0.0)
      signal.entry = OrderOpenPrice(); // Use current open price if not set

    double tpLevels[MAX_TP_LEVELS];

    // get TP hit level based on current price
    int priceTpHitLevel = 0;
    double closePrice = OrderClosePrice();
    int orderType = OrderType();
    for(int i = 0; i < signal.tpCount; i++) {
      if((orderType == OP_BUY && closePrice >= signal.tpLevels[i]) ||
          (orderType == OP_SELL && closePrice <= signal.tpLevels[i])) {
        priceTpHitLevel = i + 1; // TP levels are 1-based
      }
    }

    // get TP hit level based on last closed orders
    // (e.g. if current price has already reversed)
    int lastClosedTpHitLevel = 0;
    for(int i = 0; i < 5; i++) {
      if(lastOrderInfos[i].groupId != signal.groupId) continue;
      lastClosedTpHitLevel = MathMax(lastClosedTpHitLevel, lastOrderInfos[i].tpLevel);
    }

    int tpHitLevel = MathMax(priceTpHitLevel, lastClosedTpHitLevel);

    if(tpHitLevel <= 0)
      continue; // No TPs hit yet, skip TS for this order
    double currentSL = OrderStopLoss();
    double newSL = CalculateNewSL(tpHitLevel, currentSL, signal, info.channelName);
    if(MathAbs(currentSL - newSL) > SL_MODIFY_THRESHOLD) {
      bool modified = OrderModify(OrderTicket(), OrderOpenPrice(), newSL,
                                  OrderTakeProfit(), OrderExpiration(), clrOrange);
      int digits = MarketInfo(OrderSymbol(), MODE_DIGITS);
      if(modified) {
        PrintLog(": Trailing SL updated for ticket:" + IntegerToString(OrderTicket()) +
                 " from " + DoubleToString(currentSL, digits) +
                 " to " + DoubleToString(newSL, digits));
      } else if (GetLastError() == ERR_INVALID_STOPS) {
        PrintLog(": Failed to update trailing SL for ticket:" + IntegerToString(OrderTicket()) +
                 " from " + DoubleToString(currentSL, digits) +
                 " to " + DoubleToString(newSL, digits) +
                 " at price " + DoubleToString(OrderClosePrice(), digits) +
                 " Error:" + IntegerToString(GetLastError()) + " - closing order");
        CloseCurrentOrder(signal);
      } else {
        PrintLog(": Failed to update trailing SL for ticket:" + IntegerToString(OrderTicket()) +
                 " from " + DoubleToString(currentSL, digits) +
                 " to " + DoubleToString(newSL, digits) +
                 " at price " + DoubleToString(OrderClosePrice(), digits) +
                 " Error:" + IntegerToString(GetLastError()));
      }
    }
  }
}

//+------------------------------------------------------------------+
//| CalculateNewSL: Calculate new SL based on TP hit level         |
//| Aggressive strategy: TP1->BE, TP2->TP1, TP3->TP2, etc.        |
//| Conservative strategy: TP1->nothing, TP2->BE, TP3->TP2        |
//+------------------------------------------------------------------+
double CalculateNewSL(int tpHitLevel, double currentStop, Signal &signal, string channelName)
{
  double newSL = currentStop;
  bool isBuy = (signal.type == "BUY");
  if(tpHitLevel <= 0 || signal.tpCount <= 0)
    return currentStop;

  int digits = MarketInfo(signal.symbol, MODE_DIGITS);

  if(stopLossMultiplier < 0) {
    return NormalizeDouble(currentStop, digits); // No multiplier set, return original SL
  }

// implication: when conservative, we don't do anything at all for TP1
  if (!aggressiveTrailingStopStrategy && tpHitLevel == 1) {
    // do nothing
  }  else if(tpHitLevel == (aggressiveTrailingStopStrategy ? 1 : 2)) {
    double diff = MathAbs(OrderOpenPrice() - signal.stopLoss) * stopLossMultiplier;
    newSL = isBuy ? OrderOpenPrice() - diff : OrderOpenPrice() + diff;
    if(debugMode)
      PrintLog(": breakeven TP hit - partial trailing with multiplier: " + DoubleToString(newSL, digits));
  } else {
    // TP2+ (aggressive) or TP3+ (conservative) hit: Trail to previous TP level
    // Aggressive: 1 TP behind, conservative: 2 TP behind
    if (signal.tpCount < tpHitLevel) {
      PrintLog(": Invalid TP hit level " + IntegerToString(tpHitLevel) +
               " for GID=" + IntegerToString(signal.groupId) +
               ", using original SL");
      return currentStop;
    }

    int indexOffset = aggressiveTrailingStopStrategy ? 2 : 3;
    int idx = tpHitLevel - indexOffset;
    if (idx < 0 || idx >= signal.tpCount) {
      if (debugMode)
        PrintLog(": Invalid trailing index " + IntegerToString(idx) +
                 " for TP hit level " + IntegerToString(tpHitLevel) +
                 ", tpCount=" + IntegerToString(signal.tpCount) +
                 ", using original SL");
      return currentStop;
    }

    // aggressive:   TP2 hit (level 2) -> TP1 (index 0), TP3 hit (level 3) -> TP2 (index 1)
    // conservative: TP3 hit (level 3) -> TP1 (index 0), TP4 hit (level 4) -> TP2 (index 1)
    newSL = signal.tpLevels[idx];

    if(debugMode) {
      int behind = aggressiveTrailingStopStrategy ? 1 : 2;
      int targetTpLevel = tpHitLevel - behind;
      string modeLabel = aggressiveTrailingStopStrategy ? "Aggressive" : "Conservative";
      PrintLog(":" + modeLabel + ": TP" + IntegerToString(tpHitLevel) +
               " hit - trailing to TP" + IntegerToString(targetTpLevel) +
               ": " + DoubleToString(newSL, digits));
    }
  }

// Validate SL direction for BUY/SELL - ensure it moves in favorable direction only
  if(isBuy) {
    // For BUY: new SL should be higher than current SL (more favorable)
    if(newSL < currentStop) {
      if(debugMode)
        PrintLog(": BUY - New SL " + DoubleToString(newSL, digits) +
                 " would be worse than original " + DoubleToString(currentStop, digits) + ", keeping original");
      return currentStop;
    }
  } else {
    // For SELL: new SL should be lower than current SL (more favorable)
    if(newSL > currentStop) {
      if(debugMode)
        PrintLog(": SELL - New SL " + DoubleToString(newSL, digits) +
                 " would be worse than original " + DoubleToString(currentStop, digits) + ", keeping original");
      return currentStop;
    }
  }

  if(debugMode)
    PrintLog(": SL calculation successful, channel:" + channelName +
             " Symbol:" + signal.symbol + " Level:" + IntegerToString(tpHitLevel) +
             " Multiplier:" + DoubleToString(stopLossMultiplier, 2) +
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
void SaveSignalToFile(Signal &signal)
{
  string dir = "signals";
  string filename = dir + "/" + IntegerToString(signal.groupId) + ".txt";
  string signalLine = signal.signalLine;
  if(signal.type == "MODIFY") {
    if (signal.tpCount == 0) {
      // TODO overwrite original SL in signal file with this modified one
      PrintLog("Skipping saving stoploss modify command to file.");
      return;
    }
    // try to find original signal and use its signal type (buy/sell)
    Signal modifiedSignal = GetSignalFromFile(signal.groupId);
    if (modifiedSignal.isValid) {
      PrintLog("Replacing warmup MODIFY with " + modifiedSignal.type);
      StringReplace(signalLine, "MODIFY", modifiedSignal.type);
    }
  }
  int handle = FileOpen(filename, FILE_WRITE|FILE_TXT|FILE_ANSI);
  if(handle == INVALID_HANDLE) {
    Print("SaveSignalToFile: Failed to open file: ", filename);
    return;
  }
  FileWrite(handle, signalLine);
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
      PrintLog(": GetSignalFromFile: File not found for GID=" + IntegerToString(groupId));
    return signal;
  }
  int handle = FileOpen(filename, FILE_READ|FILE_SHARE_READ|FILE_TXT|FILE_ANSI);
  if(handle == INVALID_HANDLE) {
    PrintLog(": GetSignalFromFile: Failed to open file: " + filename);
    return signal;
  }
  string line = FileReadString(handle);
  FileClose(handle);
  if(StringLen(line) == 0) {
    PrintLog(": GetSignalFromFile: Empty signal file for GID=" + IntegerToString(groupId));
    return signal;
  }
  signal = ReadSignalLine(line, /* isStored */ true);
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
//| SetWarmupLevels: Calculate TP/SL for warmup signals       |
//+------------------------------------------------------------------+
void SetWarmupLevels(Signal &signal)
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
  PrintLog(": Warmup levels calculated - Entry: " + DoubleToString(signal.entry, digits) +
           " TP1: " + DoubleToString(signal.tpLevels[0], digits) +
           " TP2: " + DoubleToString(signal.tpLevels[1], digits) +
           " SL: " + DoubleToString(signal.stopLoss, digits));
}

//+------------------------------------------------------------------+
//| GetLotSizeFactorForChannel: Calculate lot size factor based on channel|
//+------------------------------------------------------------------+
double GetLotSizeFactorForChannel(string channelName)
{
// If config string is empty, return default
  if(StringLen(lotSizeFactorConfig) == 0) {
    return defaultLotSizeFactor;
  }

// Parse the configuration string
// Format: "channel1:factor1,channel2:factor2,..."
  string pairs[];
  int pairCount = StringSplit(lotSizeFactorConfig, ',', pairs);

  for(int i = 0; i < pairCount; i++) {
    string keyValue[];
    if(StringSplit(pairs[i], ':', keyValue) == 2) {
      StringTrimRight(keyValue[0]);
      StringTrimLeft(keyValue[0]);
      string configChannel = keyValue[0];
      if(configChannel == channelName) {
        StringTrimRight(keyValue[1]);
        StringTrimLeft(keyValue[1]);
        double factor = StringToDouble(keyValue[1]);
        if(debugMode) {
          PrintLog(": Found lot size factor " + DoubleToString(factor, 2) + " for channel '" + channelName + "'");
        }
        return factor;
      }
    }
  }

// If channel not found in config, return default
  if(debugMode) {
    PrintLog(": Using default lot size factor " + DoubleToString(defaultLotSizeFactor, 2) + " for channel '" + channelName + "'");
  }
  return defaultLotSizeFactor;
}

//+--------------------------------------------------------------------+
//| SelectTPIndices: Select which TP indices to keep when reducing TPs |
//| Strategy: Keep first, last, and evenly distribute middle ones      |
//+--------------------------------------------------------------------+
int SelectTPIndices(int totalTPs, int maxPositions, int &selectedIndices[])
{
  if(maxPositions <= 0) return 0;
  if(maxPositions >= totalTPs) {
    // Keep all
    for(int i = 0; i < totalTPs; i++) {
      selectedIndices[i] = i;
    }
    return totalTPs;
  }

  if (maxPositions == 1) {
    // Keep biggest TP
    selectedIndices[0] = totalTPs - 1;
    return 1;
  }

// Distribute positions evenly
  int positions = maxPositions;
  for(int i = 0; i < positions; i++) {
    // Calculate evenly spaced indices between 0 and totalTPs-1
    double position = (double)i * (totalTPs - 1) / (maxPositions - 1);
    selectedIndices[i] = (int)MathRound(position);
  }

  ArraySort(selectedIndices, maxPositions);
  return maxPositions;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SetSignalLotSizes(Signal &signal)
{
  if(!signal.isValid || signal.tpCount <= 0) {
    PrintLog(": Invalid signal for position sizing");
    return;
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
  double adjustedPositionSize = MathFloor(totalLots / lotStep) * lotStep;
  double originalPositionSize = adjustedPositionSize;

// decrease position size until it fits existing margin
// e.g. if we want to use up 70% maximum, we need 100%-70% = 30% remaining
  double minimumRemainingMargin = AccountFreeMargin() * (1 - marginBufferPercentage / 100.0);
  int orderType = (signal.type == "BUY") ? OP_BUY : OP_SELL;
  double freeMarginRemaining = 1.0;
  while(adjustedPositionSize >= minLot) {
    freeMarginRemaining = AccountFreeMarginCheck(symbol, orderType, adjustedPositionSize);
    if (debugMode) {
      PrintLog(": Checking margin for " + symbol + ", lot size " + DoubleToString(adjustedPositionSize, 2) + " - Free remains: " + DoubleToString(freeMarginRemaining, 2) + ", Needed free: " + DoubleToString(minimumRemainingMargin, 2));
    }
    if(freeMarginRemaining >= 0 && freeMarginRemaining >= minimumRemainingMargin && GetLastError() == 0)
      break;
    adjustedPositionSize -= lotStep;
    adjustedPositionSize = MathFloor(adjustedPositionSize / lotStep) * lotStep;
  }

  if(adjustedPositionSize != originalPositionSize)
    PrintLog(": Adjusted position size for " + symbol + " from " + DoubleToString(originalPositionSize, 2) + " to " + DoubleToString(adjustedPositionSize, 2));

// Calculate maximum number of positions we can afford at minimum lot size
  int maxPositions = MathFloor(adjustedPositionSize / minLot);
  int originalTPCount = signal.tpCount;

// If we have more TPs than we can afford at minimum lot size, reduce TPs
  if(maxPositions < signal.tpCount && maxPositions > 0) {
    int selectedIndices[MAX_TP_LEVELS];
    int selectedCount = SelectTPIndices(signal.tpCount, maxPositions, selectedIndices);

    // Compact the TP arrays to only include selected TPs
    double tempTPLevels[MAX_TP_LEVELS];
    for(int i = 0; i < selectedCount; i++) {
      tempTPLevels[i] = signal.tpLevels[selectedIndices[i]];
    }
    ArrayFill(signal.tpLevels, 0, MAX_TP_LEVELS, 0.0);
    ArrayCopy(signal.tpLevels, tempTPLevels);

    signal.tpCount = selectedCount;
    PrintLog(": Reduced TPs from " + IntegerToString(originalTPCount) + " to " + IntegerToString(selectedCount) +
             " due to risk constraints.");
  }

  double weights[MAX_TP_LEVELS];
  double weightSum = 0.0;
  double channelLotSizeFactor = GetLotSizeFactorForChannel(signal.channelName);
  for(int i = 0; i < signal.tpCount; i++) {
    weights[i] = MathPow(channelLotSizeFactor, i);
    weightSum += weights[i];
  }

  string lotSizesLog = "[";
  double allocatedPositionSize = 0.0;
  for(int i = 0; i < signal.tpCount; i++) {
    double nextLotSize = adjustedPositionSize * (weights[i] / weightSum);
    nextLotSize = MathMax(minLot, MathMin(maxLot, nextLotSize));
    nextLotSize = MathFloor(nextLotSize / lotStep) * lotStep;
    if (i != 0) lotSizesLog += ", ";
    if (allocatedPositionSize + nextLotSize > adjustedPositionSize) {
      double remainder = adjustedPositionSize - allocatedPositionSize;
      // using MathRound - MathFloor resulted in weird rounding errors
      remainder = MathRound(remainder / lotStep) * lotStep;
      if (remainder >= minLot) {
        signal.lotSizes[i] = remainder;
        lotSizesLog += DoubleToString(remainder, 2);
        allocatedPositionSize += remainder;
      }
      break;
    }
    signal.lotSizes[i] = nextLotSize;
    lotSizesLog += DoubleToString(nextLotSize, 2);
    allocatedPositionSize += nextLotSize;
  }
  lotSizesLog += "]";

  PrintLog(": Position sizing: " + symbol +
           " FreeMargin= " + DoubleToString(AccountFreeMargin(), 2) +
           " FreeMarginRemaining= " + DoubleToString(freeMarginRemaining, 2) +
           " RiskAmount=" + DoubleToString(riskAmount, 2) +
           " RiskPerLot=" + DoubleToString(riskValuePerLot, 4) +
           " TotalLots=" + DoubleToString(totalLots, 2) +
           " MarginAdjustedLots=" + DoubleToString(allocatedPositionSize, 2) +
           " LotSizes=" + lotSizesLog +
           " TPCount=" + IntegerToString(signal.tpCount));
}
//+------------------------------------------------------------------+

//+--------------------------------------------------------------------------+
//| ReduceStopLossDistance: Decreases the stop loss of a signal by a factor. |
//| Only applies to XAUUSD, other instruments keep original stop loss        |
//+--------------------------------------------------------------------------+
void ReduceStopLossDistance(Signal &signal, bool isStored)
{
  if (stopLossReductionFactor <= 0.0 || stopLossReductionFactor >= 1.0 || signal.entry == 0.0) return;

// Only apply stop loss reduction to XAUUSD (case-insensitive)
  string symbolUpper = signal.symbol;
  StringToUpper(symbolUpper);
  if (StringFind(symbolUpper, "XAUUSD") == -1) return;
  double originalStopLoss = signal.stopLoss;
// for BUY, (entry - SL) is positive and we add this to the SL to reduce its distance from entry
// for SELL, (entry - SL) is negative and we subtract this from the SL to reduce its distance from entry
  double distance = (signal.entry - signal.stopLoss) * stopLossReductionFactor;
  signal.stopLoss += distance;

  if (signal.stopLoss != originalStopLoss && !isStored)
    PrintLog(": Stop loss distance reduced by factor of " + DoubleToString(stopLossReductionFactor, 2) +
             " from " + DoubleToString(originalStopLoss, 2) +
             " to " + DoubleToString(signal.stopLoss, 2));
}
//+--------------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Disallows a trade if it's over the single-channel exposure limit.|
//+------------------------------------------------------------------+
bool IsTradeAllowed(Signal &signal)
{
  string symbolUpper = signal.symbol;
  StringUpper(symbolUpper);
// Gold (XAUUSD) is always allowed, no exposure limit
// If exposureLimit is 0, feature is turned off
  if (StringFind(symbolUpper, "XAUUSD") != -1 || exposureLimit == 0) {
    return true;
  }

// Count open forex positions for the same channel
  int openPositionsCount = 0;
  for (int i = 0; i < OrdersTotal(); i++) {
    if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
      string sym = OrderSymbol();
      if (StringFind(symbolUpper, "XAUUSD") == -1) {  // Exclude gold
        OrderCommentInfo info = ParseOrderComment();
        if (info.isValid && info.channelName == signal.channelName) {
          openPositionsCount++;
        }
      }
    }
  }

// Allow if count is less than limit
  return openPositionsCount < exposureLimit;
}
//+------------------------------------------------------------------+
