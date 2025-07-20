//+------------------------------------------------------------------+
//|                                   AntiWhipsawProtection.mq4     |
//|                    Anti-Whipsaw Trailing Stop Protection        |
//+------------------------------------------------------------------+

// FEJLESZTÉS: Buffer Protection mechanizmus
// Ha a trigger után a számított új SL túl közel van a jelenlegi árhoz,
// akkor 5 percet vár mielőtt végrehajtja a SL módosítást.
// Ez megakadályozza, hogy a piaci zaj azonnal kiüsse a pozíciót.

//+------------------------------------------------------------------+
//| ANTI-WHIPSAW STRUKTÚRÁK ÉS VÁLTOZÓK                           |
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

// Global arrays for pending trailing stops
PendingTrailingStop pendingStops[100];
int pendingStopCount = 0;

// Configuration - ezeket a főfájl tetején kellene definiálni
int antiWhipsawDelaySeconds = 300;        // 5 perc várakozás
double minSLDistancePips_BTC = 100.0;     // BTC minimum távolság (pips)
double minSLDistancePips_GOLD = 50.0;     // XAU minimum távolság (pips) 
double minSLDistancePips_FOREX = 20.0;    // Forex minimum távolság (pips)
double minSLDistancePips_CRYPTO = 80.0;   // Egyéb crypto minimum távolság (pips)

//+------------------------------------------------------------------+
//| GetMinimumSLDistance: Symbol-specific minimum SL distance       |
//+------------------------------------------------------------------+
//| Funkció: Visszaadja a minimum SL távolságot pipben különböző    |
//|          instrumentumok esetében                                |
//| Bemenetek: symbol - A kereskedési instrument szimbóluma        |
//| Kimenet: Minimum távolság pipben                                |
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
//| Funkció: Meghatározza hogy a számított új SL túl közel van-e a |
//|          jelenlegi piaci árhoz, ezért várni kell-e              |
//| Bemenetek:                                                       |
//|   - symbol: Kereskedési instrument                              |
//|   - newSL: Javasolt új SL szint                                |
//|   - currentPrice: Jelenlegi piaci ár                           |
//|   - isBuyOrder: BUY vagy SELL order                            |
//| Kimenet: true ha túl közel van (várni kell)                   |
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
//| Funkció: Hozzáad egy trailing stop módosítást a várakozó listához |
//| Bemenetek:                                                       |
//|   - ticket: Order ticket szám                                  |
//|   - groupId: Csoport azonosító                                 |
//|   - triggeredTPLevel: Melyik TP szint lett elérve             |
//|   - calculatedSL: Kiszámított új SL                           |
//|   - currentPrice: Trigger időpontjának ára                    |
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
//| Funkció: Ellenőrzi és végrehajtja a lejárt pending trailing stops|
//| Meghívás: Minden tick-en a main OnTick()-ből                   |
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
            validDirection = (currentSL <= 0 || proposedSL > currentSL);
        } else {
            // SELL order: új SL alacsonyabb legyen mint a jelenlegi (vagy 0)
            validDirection = (currentSL <= 0 || proposedSL < currentSL);
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
            modifiedTickets[modifiedCount] = ticket;
            modifiedCount++;
        } else {
            int error = GetLastError();
            PrintLog("❌ Anti-Whipsaw FAILED: Ticket " + IntegerToString(ticket) + 
                     " Error: " + IntegerToString(error) + " - " + ErrorDescription(error));
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
//| MÓDOSÍTOTT HandleTrailingStopsDynamic FÜGGVÉNY                 |
//| Enhanced version with Anti-Whipsaw Protection                   |
//+------------------------------------------------------------------+
void HandleTrailingStopsDynamic_WithAntiWhipsaw()
{
    datetime now = TimeCurrent();
    if(now - lastTrailingScan < trailingCheckIntervalSec) return;
    
    // Először dolgozzuk fel a függőben lévő trailing stops-okat
    ProcessPendingTrailingStops();
    
    lastTrailingScan = now;

    if(debugMode) PrintLog(eaName + ": TS scan starting (with Anti-Whipsaw)...");

    modifiedCount = 0;
    ArrayInitialize(modifiedTickets, -1);

    // [... Az eredeti trigger detection logika ugyanaz ...]
    // Itt csak a SL módosítási részt módosítottuk:

    // PHASE 3: Update SL for remaining open orders based on triggered TPs
    // DE MOST ANTI-WHIPSAW PROTECTION-nal
    
    int totalModifications = 0;
    int openTotal = OrdersTotal();
    
    for(int m = 0; m < openTotal; m++)
    {
        if(!OrderSelect(m, SELECT_BY_POS, MODE_TRADES)) continue;
        if(OrderMagicNumber() != MAGIC_NUMBER) continue;
        
        if(OrderCloseTime() != 0) continue;
        
        int ticket = OrderTicket();
        if(HasBeenModified(ticket)) continue;

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
        
        if(triggeredTPLevel == 0) continue;

        // Calculate new SL
        double newSL;
        double openPrice = OrderOpenPrice();
        int digits = MarketInfo(OrderSymbol(), MODE_DIGITS);
        string symbol = OrderSymbol();
        
        if(triggeredTPLevel == 1)
        {
            newSL = NormalizeDouble(openPrice, digits);
        }
        else if(triggeredTPLevel > 1)
        {
            double tpLevels[20];
            int tpCount;
            
            if(ReconstructTPLevelsFromOrders(gid, tpLevels, tpCount) && triggeredTPLevel <= tpCount)
            {
                newSL = NormalizeDouble(tpLevels[triggeredTPLevel - 2], digits);
            }
            else continue;
        }
        else continue;
        
        // ANTI-WHIPSAW PROTECTION CHECK
        RefreshRates();
        bool isBuyOrder = (OrderType() == OP_BUY);
        double currentPrice = isBuyOrder ? 
                             MarketInfo(symbol, MODE_BID) : MarketInfo(symbol, MODE_ASK);
        
        bool slTooClose = CheckIfSLTooClose(symbol, newSL, currentPrice, isBuyOrder);
        
        if(slTooClose) {
            // SL túl közel van -> pending listára
            PrintLog("🔄 Anti-Whipsaw DELAY: Ticket " + IntegerToString(ticket) + 
                     " SL too close to current price, delaying 5 minutes");
            AddPendingTrailingStop(ticket, gid, triggeredTPLevel, newSL, currentPrice);
            continue;
        }
        
        // SL elég távol van -> azonnal végrehajtjuk
        double currentSL = OrderStopLoss();
        
        // Direction validation
        bool validDirection = true;
        if(isBuyOrder) {
            validDirection = (currentSL <= 0 || newSL > currentSL);
        } else {
            validDirection = (currentSL <= 0 || newSL < currentSL);
        }
        
        if(!validDirection) continue;
        
        // Immediate execution
        bool success = OrderModify(ticket, openPrice, newSL, OrderTakeProfit(), OrderExpiration());
        
        if(success) {
            PrintLog("✅ IMMEDIATE SUCCESS: Modified ticket " + IntegerToString(ticket) + 
                     " SL: " + DoubleToString(currentSL, digits) + 
                     " -> " + DoubleToString(newSL, digits));
                     
            modifiedTickets[modifiedCount] = ticket;
            modifiedCount++;
            totalModifications++;
        }
    }

    if(debugMode) {
        PrintLog(eaName + ": TS completed - Immediate: " + IntegerToString(totalModifications) + 
                 ", Pending: " + IntegerToString(CountActivePendingStops()));
    }
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

//+------------------------------------------------------------------+
//| TESZT FUNKCIÓ: Anti-Whipsaw működés tesztelése                |
//+------------------------------------------------------------------+
void TestAntiWhipsawLogic()
{
    Print("\n=== ANTI-WHIPSAW PROTECTION TESTS ===\n");
    
    // Test 1: Bitcoin - nagy távolság szükséges
    Print("Test 1: Bitcoin SL Distance Check");
    bool result1 = CheckIfSLTooClose("BTCUSD", 45000.0, 45080.0, true);
    Print("BTCUSD: SL=45000, Price=45080, Too Close: " + (result1 ? "YES" : "NO"));
    Print("Expected: YES (80 pips < 100 minimum)\n");
    
    // Test 2: Gold - közepes távolság
    Print("Test 2: Gold SL Distance Check");
    bool result2 = CheckIfSLTooClose("XAUUSD", 2100.0, 2100.3, true);
    Print("XAUUSD: SL=2100.0, Price=2100.3, Too Close: " + (result2 ? "YES" : "NO"));
    Print("Expected: YES (30 pips < 50 minimum)\n");
    
    // Test 3: Forex - kicsi távolság elegendő
    Print("Test 3: Forex SL Distance Check");
    bool result3 = CheckIfSLTooClose("EURUSD", 1.2000, 1.2025, true);
    Print("EURUSD: SL=1.2000, Price=1.2025, Too Close: " + (result3 ? "YES" : "NO"));
    Print("Expected: NO (25 pips > 20 minimum)\n");
    
    // Test 4: SELL order direction
    Print("Test 4: SELL Order Direction");
    bool result4 = CheckIfSLTooClose("GBPUSD", 1.3050, 1.3025, false);
    Print("GBPUSD SELL: SL=1.3050, Price=1.3025, Too Close: " + (result4 ? "YES" : "NO"));
    Print("Expected: NO (25 pips > 20 minimum)\n");
    
    Print("=== TESTS COMPLETED ===\n");
}
