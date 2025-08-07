//+------------------------------------------------------------------+
//|                                     TelegramSignalForwarder.mq4  |
//|                Clean, Modular & Readable Code Refactoring       |
//|                           Copyright 2025, OpenAI & User Request  |
//+------------------------------------------------------------------+
#property strict
#property version "2.2.0"

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

//+------------------------------------------------------------------+
//|--- Constants & File Paths                                        |
//+------------------------------------------------------------------+
#define SL_MODIFY_THRESHOLD   0.00001            // Minimum SL diff to apply

static string gTempFile       = "processing.txt";     // Temp file to avoid re-read
static string gExternalSLFile = "stoploss_update.txt";// External SL updates
static string gSignalFile               = "signals.txt";       // Incoming signal file

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
void    UpdateExistingOrdersSL(Signal &signal);
void    SendOrders(Signal &signal);
void    ProcessExternalSLUpdates();
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
int init()
{
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
  if(debugMode)
    PrintLog(eaName + ": Deinitialized");
  return(0);
}

//+------------------------------------------------------------------+
//| Expert tick handler                                              |
//+------------------------------------------------------------------+
int start()
{
  if (!IsTradeAllowed() || !IsConnected() || IsStopped()) {
    return(0);
  }
// Process dynamic trailing stop for existing positions
  ProcessDynamicTrailingStop();

// Process new signal
  Signal signal = ReadSignalFile();
  if(!signal.isValid) return(0);
  if(debugMode)
    PrintLog(eaName + ": Processing NEW signal from channel '" + signal.channelName + "' - GID=" + IntegerToString(signal.groupId) + " with " + IntegerToString(signal.tpCount) + " TP levels");

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

// Process external SL updates
  ProcessExternalSLUpdates();
  return(0);
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
// Expect: 123456789|TYPE|SYMBOL|ENTRY|TP1,TP2,TP3,...|SL|GID:<id>|CHANNEL_NAME
  string parts[];
  if(StringSplit(line, '|', parts) < 8) {
    PrintLog(eaName + ": Invalid signal format, expected 8 parts but got " + IntegerToString(ArraySize(parts)));
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
  if(signal.type != "BUY" && signal.type != "SELL") {
    PrintLog(eaName + ": Invalid signal type '" + signal.type + "', expected BUY or SELL");
    return signal;
  }

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

// Enforce maximum TP count limit (array size is 10)
  if(signal.tpCount > 10) {
    PrintLog(eaName + ": Warning: TP count " + IntegerToString(signal.tpCount) + " exceeds maximum 10, truncating");
    signal.tpCount = 10;
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
// Validate SL position relative to entry price (if not market erntry
  if(signal.entry != 0.0) {
    if(shouldBuy && signal.stopLoss >= signal.entry) {
      PrintLog(eaName + ": Warning: SL " + DoubleToString(signal.stopLoss, MarketInfo(signal.symbol, MODE_DIGITS)) +
               " should be below entry " + DoubleToString(signal.entry, MarketInfo(signal.symbol, MODE_DIGITS)) + " for BUY");
    } else if(!shouldBuy && signal.stopLoss <= signal.entry) {
      PrintLog(eaName + ": Warning: SL " + DoubleToString(signal.stopLoss, MarketInfo(signal.symbol, MODE_DIGITS)) +
               " should be above entry " + DoubleToString(signal.entry, MarketInfo(signal.symbol, MODE_DIGITS)) + " for SELL");
    }
  }

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
    PrintLog(eaName + ": Parsed signal GID=" + IntegerToString(signal.groupId) + " from channel '" + signal.channelName + "'");

  signal.isValid = true;
  return signal;
}

//+------------------------------------------------------------------+
//| UpdateExistingOrdersSL: Update SL of existing orders from same channel |
//+------------------------------------------------------------------+
void UpdateExistingOrdersSL(Signal &signal)
{
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
//| ProcessExternalSLUpdates: Apply external SL update commands     |
//+------------------------------------------------------------------+
void ProcessExternalSLUpdates()
{
  if(!FileExists(gExternalSLFile))
    return;
  if(signalFileHandle == -1) {
    signalFileHandle = FileOpen(gExternalSLFile, FILE_READ|FILE_SHARE_READ|FILE_TXT|FILE_ANSI);
  }
  if(signalFileHandle == INVALID_HANDLE)
    return;
  string cmd = FileReadString(signalFileHandle);
  if(!IsTesting()) {
    FileClose(signalFileHandle);
    signalFileHandle = -1;
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
  for(int i=0; i<total; i++) {
    if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
      PrintLog(eaName + ": ext SL order select failed at index " + IntegerToString(i));
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
      if(debugMode)
        PrintLog(eaName + ": Ignoring order at index " + IntegerToString(i) + " - GID mismatch");
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
      PrintLog(eaName + ": cannot find signal in file for GID " + IntegerToString(signal.groupId) + ", skipping TS update");
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
    double diff = MathAbs(signal.entry - signal.stopLoss) * stopLossMultiplier;
    newSL = isBuy ? signal.entry - diff : signal.entry + diff;
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

// the value of our risk per lot, in the quote currency
  double riskedTicks = MathAbs(signal.entry - signal.stopLoss) / tickSize;
  double riskValuePerLot = tickValue * riskedTicks;

// Calculate maximum loss based on risk percentage (1%)
  double riskAmount = AccountBalance() * accountRiskPercentage / 100.0;

// Calculate total lot size based on risk
  double totalLots = riskAmount / riskValuePerLot;

// Divide across TP levels
  double positionSize = totalLots / signal.tpCount;

// Round down to the nearest valid lot step
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
