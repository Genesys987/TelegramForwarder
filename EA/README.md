# TelegramSignalForwarder EA

An MT4 Expert Advisor that reads trading signals written to `signals.txt` by the Telegram forwarder bot and automatically places, manages, and closes orders.

## How it works

1. The Telegram bot monitors channels and writes incoming signals to `signals.txt` in the MT4 `MQL4/Files` directory.
2. Every 2 seconds the EA's timer fires, reads the file, and dispatches one of the following signal types:
   - **BUY / SELL** – open new orders (one per TP level).
   - **MODIFY / BREAKEVEN** – adjust the stop loss on existing orders.
   - **CLOSE** – close all orders belonging to a signal group.
3. After each signal is processed, the EA also runs a dynamic trailing-stop scan over all open positions.

---

## Settings reference

### General

| Parameter | Default | Description |
|---|---|---|
| `debugMode` | `true` | Write verbose logs to `YYYYMMDD.log` in `MQL4/Files` and to the Experts tab. Disable in production to reduce noise. |
| `brokerTimeOffsetMinutes` | `120` | Your broker's clock offset from UTC in minutes. Used to convert broker time to UTC when checking signal age and writing log timestamps. `UTC+2 = 120`, `UTC+3 = 180`, etc. |
| `signalMaxAgeMinutes` | `5` | Signals older than this many minutes (measured in UTC) are silently discarded. Protects against processing a backlog of stale signals after a reconnect. |
| `symbolPostfix` | `""` | Appended to every symbol before placing orders. Set to your broker's suffix if their symbols differ from the signal source, e.g. `".m"` turns `EURUSD` into `EURUSD.m`. |

### Risk & position sizing

| Parameter | Default | Description |
|---|---|---|
| `accountRiskPercentage` | `1.0` | Percentage of **account balance** to risk on each signal. The EA calculates the total lot size so that hitting the stop loss costs exactly this amount. The total is then split across TP levels. |
| `marginBufferPercentage` | `70.0` | Maximum proportion of free margin the EA is allowed to consume for a single signal. If the risk-calculated lot size would require more than this, the position is scaled down in `lotStep` increments until it fits. `70` means at most 70 % of free margin can be used; 30 % is kept as a buffer. |
| `lotSizeFactorConfig` | `""` | Per-channel lot-size multiplier, applied **after** risk sizing. Format: `"CHAN:factor,OTHER:factor"`. A factor of `0.7` means each successive TP order gets 70 % of the previous one's weight (front-loaded). Channels not listed fall back to `defaultLotSizeFactor`. |
| `defaultLotSizeFactor` | `1.0` | Lot weighting factor used for any channel not listed in `lotSizeFactorConfig`. `1.0` = equal lots across all TP levels. Values below 1 (e.g. `0.7`) front-load the distribution so TP1 gets the largest share. |

### Stop-loss management

| Parameter | Default | Description |
|---|---|---|
| `stopLossMultiplier` | `0.2` | Controls where the SL is moved when the first trailing trigger fires (TP1 in aggressive mode, TP2 in conservative). `0.0` = move SL to entry (breakeven). `1.0` = leave SL at its original distance. `0.2` = move SL to 20 % of the original SL distance below entry. Set to a **negative value** to disable automatic trailing entirely. |
| `aggressiveTrailingStopStrategy` | `true` | Selects the trailing-stop schedule:<br>**`true` (Aggressive):** TP1 hit → SL moves to near-entry (per `stopLossMultiplier`). TP2 hit → SL trails to TP1. TP3 hit → SL trails to TP2, and so on.<br>**`false` (Conservative):** TP1 hit → no SL change. TP2 hit → SL moves to near-entry. TP3 hit → SL trails to TP1. TP4 hit → SL trails to TP2, and so on. |
| `stopLossReductionFactor` | `0.0` | **XAUUSD only.** Shrinks the signal's original SL distance from entry by this fraction before placing the order. `0.0` = no change. `0.2` = reduce SL distance by 20 % (tighter stop). Has no effect on non-gold symbols. |

### Order behavior

| Parameter | Default | Description |
|---|---|---|
| `limitOrderExpirationMinutes` | `30` | When the current market price is already inside the signal's entry zone a limit order is used instead of a market order. This setting controls how many minutes into the future that limit order's expiry is set. |
| `warmupTimeoutSeconds` | `120` | Warmup signals are synthetic signals used to pre-calibrate the trailing-stop engine without a real entry. Orders placed from a warmup signal are tracked and automatically closed after this many seconds if they are still open. |
| `forceTpLevel` | `0` | Force a minimum number of TP orders regardless of risk/margin calculations. E.g. `2` always places at least TP1 and TP2 orders, each at `minLot`, even if risk sizing would produce fewer. `0` disables this override and lets the risk engine decide. |

### Filtering

| Parameter | Default | Description |
|---|---|---|
| `channelAllowList` | `""` | Comma-separated list of 4-letter channel codes that the EA is allowed to trade, e.g. `"THEA,FXPL"`. When empty **all** channels are accepted. Signals from unlisted channels are logged and dropped. |
| `exposureLimit` | `0` | Maximum number of **simultaneously open signal groups** per channel for non-gold forex pairs. Each unique group ID (one per original signal) counts as one unit regardless of how many TP orders it generated. `0` disables the limit. XAUUSD is always exempt. |

---

## Signal file format

The forwarder writes one line per signal to `MQL4/Files/signals.txt`. Each processed signal for a group ID is also persisted to `MQL4/Files/signals/<GID>.txt` so the trailing-stop engine can look up the original TP/SL levels after a restart.

---

## Logging

When `debugMode` is `true` the EA writes a dated log file (`YYYYMMDD.log`) to `MQL4/Files/` and mirrors every message to the MT4 **Experts** tab. The log timestamps are expressed in UTC (broker time minus `brokerTimeOffsetMinutes`).
