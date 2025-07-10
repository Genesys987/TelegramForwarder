# Trailing Stop Logic Fejlesztés Dokumentáció

## 📋 Áttekintés
Ez a dokumentum a `TelegramSignalForwarder.mq4` EA trailing stop logikájának jelentős fejlesztését írja le, lecserélve a problémás közelség-alapú rendszert egy robusztus TP-hit megerősítő rendszerre.

## 🚨 Probléma Leírása
Az eredeti trailing stop logika idő előtt aktiválódott a TP szintekhez való ár közelség alapján, ami okozta:
- Korai SL módosítások a valós TP találat előtt
- Idő előtti kereskedés lezárások
- Inkonzisztens trailing stop viselkedés

## ✅ Megvalósított Megoldás

### Új HandleTrailingStopsDynamic() Függvény
A régi `HandleTrailingStops()` lecserélve egy robusztus kétfázisú rendszerre:

**1. Fázis: TP Találat Észlelés**
- Az utolsó órában lezárt orderek vizsgálata
- Ellenőrzi, hogy az orderek a TP árán zárultak-e (nem csak közelében)
- Azonosítja melyik TP szint került ténylegesen eltalálásra (TP1, TP2, TP3, stb.)
- `OrderTakeProfit()` vs `OrderClosePrice()` összehasonlítást használ

**2. Fázis: SL Frissítés**
- Az ugyanazon csoportban lévő nyitott orderek SL frissítése
- Dinamikus SL mozgatás a kiváltott TP szint alapján
- Broker korlátok validálása (freeze/stop szintek)

### Dinamikus TP Szint Támogatás
- 1-6 TP szint támogatása (kiterjeszthető 20-ra)
- Automatikus TP szint rekonstrukció meglévő orderekből
- Megfelelő kezelés a régi és új komment formátumokhoz

### Fejlett Order Komment Elemzés
- `ParseOrderCommentDynamic()`: Kiterjesztett elemző TP szint támogatással
- `ParseOrderCommentFull()`: Kezeli a régi (`GID:123|SL:1.234`) és új (`123|FOREX|1.234`) formátumokat
- `ReconstructTPLevelsFromOrders()`: Újraépíti a TP tömböket az order előzményekből

## 🔧 Kulcs Függvények Hozzáadva/Módosítva

### Új Függvények
1. **`HandleTrailingStopsDynamic()`** - Fő trailing stop logika
2. **`ParseOrderCommentDynamic()`** - Fejlett komment elemző
3. **`ReconstructTPLevelsFromOrders()`** - TP szint rekonstrukció
4. **`GetHighestTriggeredTP()`** - Legmagasabb kiváltott TP keresése egy csoportban
5. **`GetOrderType()`** - Signal típus MT4 order típus konvertáló

### Módosított Függvények
1. **`FormatMT4Comment()`** - Befejezett implementáció megfelelő string kezeléssel
2. **`AddTriggeredGroup()`** - Fejlesztve TP szint frissítések kezelésére
3. **`init()`** - Megfelelő inicializálás a triggered groups tömb számára

## 📊 Trailing Stop Logika Folyamat

### TP Találat Észlelés Logika
```
1. Lezárt orderek vizsgálata (csak utolsó óra)
2. Ellenőrzi, hogy az order a TP árán zárult-e
3. TP ár egyeztetése a TP szint tömbbel
4. Kiváltott TP szint rögzítése a TriggeredGroup struktúrában
```

### SL Mozgatás Szabályok
```
- TP1 találat → SL = Belépési Ár (Breakeven)
- TP2 találat → SL = TP1 Ár
- TP3 találat → SL = TP2 Ár
- TP4 találat → SL = TP3 Ár
- TP5 találat → SL = TP4 Ár
- TP6 találat → SL = TP5 Ár
```

## 🏗️ Adatstruktúrák

### TriggeredGroup Struktúra
```mql4
struct TriggeredGroup {
    int groupId;           // Csoport ID
    int triggeredTPLevel;  // Melyik TP került eltalálásra (1-6)
    datetime triggerTime;  // Mikor történt a kiváltás
};
```

### Globális Változók
- `TriggeredGroup triggeredGroups[MAX_GROUPS]` - Kiváltott csoportok tömbje
- `int triggeredCount` - Kiváltott csoportok száma
- `int modifiedTickets[MAX_MODIFIED_TICKETS]` - Duplikált módosítások megelőzése

## 🛡️ Biztonsági Funkciók

### Broker Korlát Validálás
- Freeze szint ellenőrzés `CheckFreezeLevel()` segítségével
- Stop szint validálás `CheckStopLevel()` segítségével
- Minimum SL változás küszöb (`SL_MODIFY_THRESHOLD`)

### Duplikáció Megelőzés
- Ticket módosítás követése
- Idő-alapú szűrés (1 órás ablak)
- Csoport-alapú TP szint frissítések

### Hibakezelés
- Átfogó hiba naplózás
- Kecses visszatérési mechanizmusok
- Komment elemzés validálás

## 📈 Dinamikus TP Támogatás

### Signal Formátum Támogatás
```
Eredeti: 123456789|BUY|EURUSD|1.0500|1.0550,1.0600,1.0650|1.0450|GID:123|FOREX
TP Számláló: Automatikusan észleli a vesszővel elválasztott értékekből
Max TP: 20 (tipikusan 1-6 használatos)
```

### TP Tömb Kezelés
- Dinamikus tömb átméretezés TP szám alapján
- Automatikus rendezés (növekvő BUY-nál, csökkenő SELL-nél)
- TP sorrend és belépési ponthoz való távolság validálás

## 🔍 Hibakeresés és Monitoring

### Debug Kimenet Példák
```
TS detected TP1 hit for GID 123 at price 1.05500
TS successfully modified ticket 12345 to SL=1.05000 (TP1 triggered)
TS found 2 triggered groups
TS checking 15 open orders
```

### Konfigurációs Paraméterek
- `debugMode`: Részletes naplózás engedélyezése
- `trailingCheckIntervalSec`: Vizsgálati intervallum (alapértelmezett: 5 másodperc)
- `triggerTolerancePips`: Ár tolerancia TP találat észleléshez (alapértelmezett: 5 pip)

## 🔄 Visszakompatibilitás

### Komment Formátum Támogatás
- **Régi formátum**: `GID:123|SL:1.234` vagy `GID:123|FOREX|SL:1.234`
- **Új formátum**: `123|FOREX|1.234`
- Automatikus észlelés és elemzés mindkét formátumhoz

### Meglévő Order Integráció
- Működik az előző verziók által létrehozott meglévő orderekkel
- Automatikus TP szint rekonstrukció az order előzményekből
- Zökkenőmentes migráció manuális beavatkozás nélkül

## 🎯 Teljesítmény Optimalizálások

### Hatékony Vizsgálat
- Korlátozott előzmény vizsgálat (1 órás ablak)
- Korai befejezés érvénytelen ordereknél
- Gyorsítótárazott TP szint tömbök

### Memória Kezelés
- Fix méretű tömbök határérték ellenőrzéssel
- Automatikus tisztítás a régi kiváltott csoportoknál
- Hatékony string műveletek

## 📝 Használati Megjegyzések

### Konfigurációs Ajánlások
- Állítsd be `debugMode = true` kezdeti teszteléshez
- Állítsd be `triggerTolerancePips` értékét a broker spread alapján
- Monitorozd a logokat TP találat megerősítésekhez

### Tesztelési Ellenőrzőlista
1. Ellenőrizd, hogy TP1 találat breakeven-re mozgatja az SL-t
2. Erősítsd meg, hogy TP2+ találatok az előző TP-re mozgatják az SL-t
3. Ellenőrizd a több TP találatot ugyanazon csoportban
4. Validáld a broker korlát kezelést
5. Teszteld különböző TP számokkal (1-6)

## 🔮 Jövőbeli Fejlesztések

### Lehetséges Javítások
- Kiterjesztett komment formátum beágyazott TP szintekkel
- Konfigurálható SL mozgatási arányok
- Fejlett TP találat megerősítési módszerek
- Teljesítmény metrikák gyűjtése

---

**Utolsó Frissítés:** 2025. július 9.  
**Verzió:** 2.0  
**Szerző:** AI Asszisztens  
**Státusz:** Produkció Kész
