from signal_parser import parse_signal

# Test 1: Slash-separated TP format (the one we fixed)
print("=== Test 1: Slash-separated TP format ===")
test_signal1 = '''GOLD SELL 3334/3337
3332/3330/3328/3325
SL: 3340
'''
result1 = parse_signal(test_signal1)
if result1:
    print(f'✅ Symbol: {result1.get("symbol")}')
    print(f'✅ Signal Type: {result1.get("signal_type")}')
    print(f'✅ Entry: {result1.get("entry")}')
    print(f'✅ Take Profits: {result1.get("take_profits")}')
    print(f'✅ Stop Loss: {result1.get("stop_loss")}')
else:
    print("❌ Failed to parse signal 1")

print("\n" + "="*50 + "\n")

# Test 2: Standard TP format with labels
print("=== Test 2: Standard TP format with labels ===")
test_signal2 = '''BUY BTCUSD
ENTRY 89300.00
TP1: 89500.00
TP2: 89800.00
TP3: 90300.00
SL: 88600.00
'''
result2 = parse_signal(test_signal2)
if result2:
    print(f'✅ Symbol: {result2.get("symbol")}')
    print(f'✅ Signal Type: {result2.get("signal_type")}')
    print(f'✅ Entry: {result2.get("entry")}')
    print(f'✅ Take Profits: {result2.get("take_profits")}')
    print(f'✅ Stop Loss: {result2.get("stop_loss")}')
else:
    print("❌ Failed to parse signal 2")

print("\n" + "="*50 + "\n")

# Test 3: Emoji TP format
print("=== Test 3: Emoji TP format ===")
test_signal3 = '''XAUUSD BUY 3417
🤑TP1: 3420
✅TP2 3423
🤑TP3: 3426
SL: 3414
'''
result3 = parse_signal(test_signal3)
if result3:
    print(f'✅ Symbol: {result3.get("symbol")}')
    print(f'✅ Signal Type: {result3.get("signal_type")}')
    print(f'✅ Entry: {result3.get("entry")}')
    print(f'✅ Take Profits: {result3.get("take_profits")}')
    print(f'✅ Stop Loss: {result3.get("stop_loss")}')
else:
    print("❌ Failed to parse signal 3")

print("\n" + "="*50 + "\n")

# Test 4: Mixed format
print("=== Test 4: Mixed format ===")
test_signal4 = '''SELL XAUUSD 3290.5
TP 3287
TP 3284
3281/3278/3275
SL: 3294
'''
result4 = parse_signal(test_signal4)
if result4:
    print(f'✅ Symbol: {result4.get("symbol")}')
    print(f'✅ Signal Type: {result4.get("signal_type")}')
    print(f'✅ Entry: {result4.get("entry")}')
    print(f'✅ Take Profits: {result4.get("take_profits")}')
    print(f'✅ Stop Loss: {result4.get("stop_loss")}')
else:
    print("❌ Failed to parse signal 4")

print("\n" + "="*50 + "\n")

# Test 5: Single TP format
print("=== Test 5: Single TP format ===")
test_signal5 = '''BUY EURUSD
ENTRY 1.1200
TP: 1.1250
SL: 1.1150
'''
result5 = parse_signal(test_signal5)
if result5:
    print(f'✅ Symbol: {result5.get("symbol")}')
    print(f'✅ Signal Type: {result5.get("signal_type")}')
    print(f'✅ Entry: {result5.get("entry")}')
    print(f'✅ Take Profits: {result5.get("take_profits")}')
    print(f'✅ Stop Loss: {result5.get("stop_loss")}')
else:
    print("❌ Failed to parse signal 5")

print("\n" + "="*50 + "\n")

# Test 6: Numeric only TP (single number)
print("=== Test 6: Numeric only TP (single number) ===")
test_signal6 = '''GOLD BUY 3300
3305
SL: 3295
'''
result6 = parse_signal(test_signal6)
if result6:
    print(f'✅ Symbol: {result6.get("symbol")}')
    print(f'✅ Signal Type: {result6.get("signal_type")}')
    print(f'✅ Entry: {result6.get("entry")}')
    print(f'✅ Take Profits: {result6.get("take_profits")}')
    print(f'✅ Stop Loss: {result6.get("stop_loss")}')
else:
    print("❌ Failed to parse signal 6")
