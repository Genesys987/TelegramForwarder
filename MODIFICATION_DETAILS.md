# Módosítások Összefoglalója - September 29, 2025

## 🔄 Trailing Stop Logika (XAUUSD/BTCUSD)
- **Cél**: Nagyobb ingás biztosítása close entry esetén
- **Logika**: ≤75% progress hacia TP1 → breakeven (0.0), >75% → multiplier (0.2)
- **Érintett**: XAUUSD, GOLD, BTCUSD, BTC párok
- **Implementáció**: `CalculateNewSL()` - market progress alapú döntés

## 🛑 Close_Half_Breakeven Fix
- **Probléma**: Profitban lévő pozíciók is breakeven-re kerültek
- **Megoldás**: Csak loss pozíciók (SL < entry BUY-nál, SL > entry SELL-nél)
- **Implementáció**: `ProcessCloseHalfBreakevenSignal()` intelligens ellenőrzéssel

## 📝 "Cut" Pattern Hozzáadása
- **Új pattern**: `r'cut.*(lower\s+entries|entries)'`
- **Felismer**: "cut lower entries", "cut your entries" üzeneteket
- **Implementáció**: `userbot.py` signal recognition

## 🚀 Warmup Signal Bővítés
- **Új formátumok**: "Gold buy now", "Gold sell now"
- **Pattern**: `r"Gold\s+(buy|sell)\s+now"`
- **Implementáció**: `signal_parser.py` patterns és parsing logic