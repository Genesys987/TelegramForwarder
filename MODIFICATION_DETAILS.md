# Módosítások Összefoglalója - September 29, 2025

## 🔄 Trailing Stop Logika (XAUUSD/BTCUSD) - Reverse TP1-Based Logic
- **Cél**: Késői belépések biztonságosabb kezelése TP1-ből visszaszámítva
- **Fix Távolságok** (történeti elemzés alapján):
  - **XAUUSD**: 6.0 pips (TP1 ↔ ideális entry)
  - **BTCUSD**: 200 points (TP1 ↔ ideális entry)
- **25%-os Küszöb Logika**:
  - **BUY**: Entry ≥ (TP1 - 25%) → Késői → 0.2 multiplier, Entry < (TP1 - 25%) → Jó → breakeven
  - **SELL**: Entry ≤ (TP1 + 25%) → Késői → 0.2 multiplier, Entry > (TP1 + 25%) → Jó → breakeven
- **Példák**:
  - BTCUSD BUY: TP1=111820, Küszöb=50pt → Entry≥111770 = 0.2, Entry<111770 = breakeven
  - XAUUSD SELL: TP1=3748, Küszöb=1.5pip → Entry≤3749.5 = 0.2, Entry>3749.5 = breakeven
- **TP2+ után**: Standard trailing (TP1→SL, TP2→TP1, stb.)
- **Implementáció**: `CalculateNewSL()` - TP1-based reverse calculation with 25% threshold

## 🛑 Close_Half_Breakeven Fix
- **Probléma**: Profitban lévő pozíciók is breakeven-re kerültek
- **Megoldás**: Csak loss pozíciók (SL < entry BUY-nál, SL > entry SELL-nél)
- **Implementáció**: `ProcessCloseHalfBreakevenSignal()` intelligens ellenőrzéssel

## 📝 "Cut" Pattern + Smart Priority Logic
- **Új pattern**: `r'cut.*(lower\s+entries|entries)'`
- **Felismer**: "cut lower entries", "cut your entries" üzeneteket
- **Smart Priority**: Számérték detektálás alapú döntés
- **Logika**:
  - **SL keyword + pontosan 1 szám** (pl. "sl 1850") → `MODIFY` (negatív trade SL adjustment)
  - **SL + több szám** (pl. "ENTRY 3417 SL: 3411 TP: 3443") → **NEM MODIFY** (signal formátum)
  - **Secure/cut + nincs szám** (pl. "secure some profits") → `CLOSE_HALF_BREAKEVEN` (breakeven)
- **Regex**: `r'\b(sl|stoploss|stop\s*loss)\b.*?\b(\d{1,8}(?:\.\d{1,5})?)\b'` + számolás
- **Számolás**: `len(re.findall(r'\b\d{1,8}(?:\.\d{1,5})?\b', text)) == 1`
- **Előny**: Automatikusan felismeri a kontextust (manuális SL vs automatikus breakeven)
- **Implementáció**: `userbot.py` numeric detection with override priority

## 🚀 Warmup Signal Bővítés
- **Új formátumok**: "Gold buy now", "Gold sell now"
- **Pattern**: `r"Gold\s+(buy|sell)\s+now"`
- **Implementáció**: `signal_parser.py` patterns és parsing logic

## 🐛 Warmup Signal Log Spam Fix
- **Probléma**: TP validáció futott warmup signaloknál (0.00 értékekkel) → log spam
- **Megoldás**: Warmup signal detektálás a TP validáció előtt, skip validation warmup esetén
- **Implementáció**: `ReadSignalLine()` - korai warmup detektálás és conditional TP validation

## ✅ Status
**Completed & Tested** - Teljes backward compatibility, nincs breaking change