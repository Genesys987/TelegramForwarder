#!/usr/bin/env python3
"""
Test to verify Python and MT4 channel name compatibility
"""
import hashlib
from signal_parser import clean_channel_name

def mt4_clean_channel_name_simulation(channel_name):
    """Simulate the updated MT4 CleanChannelName function"""
    if not channel_name:
        return "UNKN"
    
    # Extract only alphabetic characters and convert to uppercase
    alpha_only = ""
    for char in channel_name.upper():
        if char.isalpha():
            alpha_only += char
    
    # Simple truncation/padding logic to match Python exactly
    if len(alpha_only) > 0:
        if len(alpha_only) <= 4:
            result = alpha_only
            # Pad with 'X' if needed
            while len(result) < 4:
                result += "X"
        else:
            # Simple truncation for long names - take first 4 characters
            result = alpha_only[:4]
    else:
        result = "UNKN"
    
    return result[:4]

# Test cases
test_cases = [
    "TRADING_SIGNALS",
    "CRYPTO_MASTER", 
    "CHANNEL_A",
    "CHANNEL_B",
    "TEST123",
    "ABC",
    "ABCDEF",
    "",
]

print("Testing Python vs MT4 channel name compatibility:")
print("=" * 60)

for channel in test_cases:
    python_result = clean_channel_name(channel)
    mt4_result = mt4_clean_channel_name_simulation(channel)
    
    match = "✅" if python_result == mt4_result else "❌"
    print(f"{match} '{channel}' -> Python: '{python_result}' | MT4: '{mt4_result}'")

print("\nIf there are ❌ marks, the logic needs further adjustment.")
