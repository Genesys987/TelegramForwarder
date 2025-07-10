#!/usr/bin/env python3
"""
Test script to verify duplicate order prevention in MT4 EA.
This creates a test signal and verifies the EA logic.
"""

import os
import time
from signal_parser import parse_signal
from queue_manager import add_signal_to_queue

def test_duplicate_prevention():
    """Test duplicate signal prevention"""
    print("Testing Duplicate Order Prevention")
    print("="*50)
    
    # Create a test signal
    signal_text = """BUY BTCUSD
ENTRY 89300.00
Take profit 1 at 89500.00
Take profit 2 at 89800.00
Take profit 3 at 90300.00
Take profit 4 at 90600.00
Take profit 5 at 91000.00
Stop loss at 88600.00"""
    
    parsed = parse_signal(signal_text)
    if not parsed:
        print("❌ Failed to parse test signal")
        return
    
    print(f"✅ Parsed signal: {parsed['signal_type']} {parsed['symbol']}")
    print(f"✅ Entry: {parsed['entry']}")
    print(f"✅ TPs: {len(parsed['take_profits'])} levels")
    print(f"✅ SL: {parsed['stop_loss']}")
    
    # Create signal data with same GID
    same_gid = 12345
    signal_data = {
        "timestamp_utc": int(time.time() * 1000),
        "signal_type": parsed["signal_type"],
        "symbol": parsed["symbol"],
        "entry": parsed["entry"],
        "take_profits": parsed["take_profits"],
        "stop_loss": parsed["stop_loss"],
        "group_id": same_gid,
        "channel_name": "TEST_DUPLICATE"
    }
    
    print(f"\n--- Adding signal with GID {same_gid} first time ---")
    success1 = add_signal_to_queue(signal_data)
    print(f"✅ First signal added: {success1}")
    
    print(f"\n--- Adding SAME signal with GID {same_gid} second time ---")
    signal_data["timestamp_utc"] = int(time.time() * 1000) + 1000  # Slightly different timestamp
    success2 = add_signal_to_queue(signal_data)
    print(f"✅ Second signal added: {success2}")
    
    print(f"\n--- Adding signal with DIFFERENT GID ---")
    signal_data["group_id"] = 54321
    signal_data["timestamp_utc"] = int(time.time() * 1000) + 2000
    success3 = add_signal_to_queue(signal_data)
    print(f"✅ Third signal (different GID) added: {success3}")
    
    print(f"\n--- Expected EA Behavior ---")
    print(f"- First signal (GID {same_gid}): Should create {len(parsed['take_profits'])} orders")
    print(f"- Second signal (GID {same_gid}): Should be SKIPPED (duplicate prevention)")
    print(f"- Third signal (GID 54321): Should create {len(parsed['take_profits'])} more orders")
    print(f"- Total orders expected: {len(parsed['take_profits']) * 2} (not {len(parsed['take_profits']) * 3})")
    
    print(f"\n✅ Test signals generated!")
    print(f"✅ Check MT4 EA logs for duplicate prevention messages")
    print(f"✅ Verify that only {len(parsed['take_profits']) * 2} orders are created total")

if __name__ == '__main__':
    test_duplicate_prevention()
