from signal_parser import parse_signal

# Test the exact 7 signal formats provided by the user
exact_signals = [
    # Signal 1
    '''BUY BTCUSD
ENTRY 89300.00
Take profit 1 at 89500.00
Take profit 2 at 89800.00
Take profit 3 at 90300.00
Stop loss at 88600.00''',
    
    # Signal 2
    '''GOLD BUY FROM 3362/3360

TP 3364
TP 3366
TP 3368
TP 3370
TP 3372
SL 3350

USE RISK MANAGEMENT''',
    
    # Signal 3
    '''SIGNAL ALERT

SELL XAUUSD 3290.5

🤑TP1: 3289.0
🤑TP2: 3287.5
🤑TP3: 3281.4
🔴SL: 3298.8 (830 pips)''',
    
    # Signal 4
    '''EURUSD BUY

ENTRY 1.1435

TP: 1.1455
TP: 1.1485
TP: 1.1535
SL: 1.1345''',
    
    # Signal 5
    '''XAUUSD BUY

ENTRY: 3418

TP1 3420
TP2 3423
TP3 3428
SL 3412''',
    
    # Signal 6
    '''BTCUSD | BUY 109500

❌ Stop Loss 109000 (500 pips)

✅TP1 109700
✅TP2 109900
✅TP3 110500''',
    
    # Signal 7 (duplicate of 6)
    '''BTCUSD | BUY 109500

❌ Stop Loss 109000 (500 pips)

✅TP1 109700
✅TP2 109900
✅TP3 110500''',
    
    # Signal 8 - NEW FORMAT
    '''XAUUSD BUY 3417

SL:  3411.68
TP:  3443.68
--Trade by Matthew'''
]

print("🔍 FINAL COMPREHENSIVE TEST OF ALL 8 PROVIDED SIGNALS")
print("=" * 60)

all_passed = True
for i, signal in enumerate(exact_signals, 1):
    result = parse_signal(signal)
    if result:
        print(f'✅ Signal {i}: PASS')
        print(f'   Type: {result["signal_type"]}')
        print(f'   Symbol: {result["symbol"]}')
        print(f'   Entry: {result["entry"]}')
        print(f'   Take Profits: {result["take_profits"]}')
        print(f'   Stop Loss: {result["stop_loss"]}')
        
        # Validate sorting
        if result["signal_type"] == "BUY":
            sorted_tps = sorted(result["take_profits"])
            if result["take_profits"] != sorted_tps:
                print(f'   ⚠️  WARNING: TPs not sorted correctly for BUY signal')
                all_passed = False
        else:  # SELL
            sorted_tps = sorted(result["take_profits"], reverse=True)
            if result["take_profits"] != sorted_tps:
                print(f'   ⚠️  WARNING: TPs not sorted correctly for SELL signal')
                all_passed = False
    else:
        print(f'❌ Signal {i}: FAIL')
        all_passed = False
    print()

print("=" * 60)
if all_passed:
    print("🎉 ALL SIGNALS PASSED! The parser is working correctly.")
else:
    print("❌ Some signals failed or have issues.")
    
print("\n📊 SUMMARY:")
print(f"Total signals tested: {len(exact_signals)} (all 8 user-provided formats)")
passed = sum(1 for signal in exact_signals if parse_signal(signal) is not None)
print(f"Passed: {passed}/{len(exact_signals)} ({passed/len(exact_signals)*100:.1f}%)")
