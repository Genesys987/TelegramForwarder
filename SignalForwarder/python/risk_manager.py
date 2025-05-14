# --- risk_manager.py (Example/Placeholder) ---

from config import (USE_RISK_MANAGEMENT, FIXED_LOT_SIZE, ACCOUNT_BALANCE,
                    RISK_PERCENTAGE, DEFAULT_PIP_VALUE_PER_LOT,
                    SYMBOL_PIP_SIZES, DEFAULT_PIP_SIZE)
                    # Consider adding SYMBOL_PIP_VALUES from config if using that option

def calculate_lot_size(symbol: str, entry_price: float, stop_loss: float) -> float:
    """
    Calculates the appropriate lot size based on risk settings or returns a fixed size.
    """
    if not USE_RISK_MANAGEMENT:
        print(f"DEBUG RM: Using fixed lot size: {FIXED_LOT_SIZE}")
        return FIXED_LOT_SIZE

    if entry_price is None or stop_loss is None or ACCOUNT_BALANCE <= 0 or RISK_PERCENTAGE <= 0:
        print("Hiba RM: Hiányzó adatok vagy érvénytelen beállítások a lot számításhoz. Visszatérés fix lottal.")
        return FIXED_LOT_SIZE

    # Calculate stop loss distance in pips
    sl_distance_price = abs(entry_price - stop_loss)
    if sl_distance_price == 0:
        print("Hiba RM: Stop loss távolság nulla. Visszatérés fix lottal.")
        return FIXED_LOT_SIZE

    # Determine pip size for the symbol
    pip_size = SYMBOL_PIP_SIZES.get(symbol.upper(), DEFAULT_PIP_SIZE)
    if pip_size <= 0:
        print(f"Hiba RM: Érvénytelen pip méret ({pip_size}) a '{symbol}'-hoz. Visszatérés fix lottal.")
        return FIXED_LOT_SIZE

    sl_distance_pips = sl_distance_price / pip_size
    if sl_distance_pips <= 0: # Should not happen if sl_distance_price > 0
         print("Hiba RM: Stop loss távolság pip-ben nulla vagy negatív. Visszatérés fix lottal.")
         return FIXED_LOT_SIZE

    # Determine pip value per lot for the symbol
    # More sophisticated logic might be needed here based on broker/account currency
    # Using simple default for now
    pip_value_per_lot = DEFAULT_PIP_VALUE_PER_LOT
    # Example using map (if defined in config):
    # pip_value_per_lot = SYMBOL_PIP_VALUES.get(symbol.upper(), DEFAULT_PIP_VALUE_PER_LOT)
    if pip_value_per_lot <= 0:
         print(f"Hiba RM: Érvénytelen pip érték/lot ({pip_value_per_lot}) a '{symbol}'-hoz. Visszatérés fix lottal.")
         return FIXED_LOT_SIZE


    # Calculate risk amount in account currency
    risk_amount = ACCOUNT_BALANCE * (RISK_PERCENTAGE / 100.0)

    # Calculate lot size
    # lot_size = (Risk Amount) / (SL Distance in Pips * Pip Value per Lot)
    calculated_lot = risk_amount / (sl_distance_pips * pip_value_per_lot)

    # Apply basic rounding or adjustments if needed (e.g., to nearest 0.01)
    # Be aware of broker minimum/maximum lot sizes and step - EA handles final adjustment
    calculated_lot = round(calculated_lot, 2) # Round to 2 decimal places

    print(f"DEBUG RM: Kockázat Számítás:")
    print(f"  Egyenleg: {ACCOUNT_BALANCE}, Kockázat %: {RISK_PERCENTAGE}")
    print(f"  Kockáztatott összeg: {risk_amount:.2f}")
    print(f"  Entry: {entry_price}, SL: {stop_loss}, Táv (ár): {sl_distance_price}")
    print(f"  Pip Méret: {pip_size}, Táv (pip): {sl_distance_pips:.1f}")
    print(f"  Pip Érték/Lot: {pip_value_per_lot}")
    print(f"  Számított Lot: {calculated_lot}")

    # Basic sanity check for calculated lot
    if calculated_lot <= 0:
        print("Hiba RM: Számított lot nulla vagy negatív. Visszatérés fix lottal.")
        return FIXED_LOT_SIZE

    # Optional: Apply a max lot cap here if desired
    # max_allowed_lot = 10.0 # Example cap
    # if calculated_lot > max_allowed_lot:
    #    print(f"Figyelmeztetés RM: Számított lot ({calculated_lot}) meghaladja a limitet ({max_allowed_lot}). Korlátozva.")
    #    calculated_lot = max_allowed_lot

    return calculated_lot