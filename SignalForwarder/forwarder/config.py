# --- config.py (Updated) ---
import os
from dotenv import dotenv_values

config = dotenv_values(".env")

# Get the directory where config.py is located
_basedir = os.path.dirname(os.path.abspath(__file__))

# ----------------------
# Telegram Bot Settings
# ----------------------
API_ID = config["TELEGRAM_API_ID"]
API_HASH = config["TELEGRAM_API_HASH"]
INVITE_LINKS = config["INVITE_LINKS"].split(",") if config["INVITE_LINKS"] else []
assert API_ID is not None, "TELEGRAM_API_ID is not set in .env file"
assert API_HASH is not None, "TELEGRAM_API_HASH is not set in .env file"

# ----------------------
# MT4 File Paths
# IMPORTANT: Verify these paths are correct for YOUR MT4 installation!
# Use raw strings (r"...") or double backslashes (\\) for Windows paths.
# ---
# Default MT4 Data Folder path component (adjust if needed)
# Often like: C:\Users\YourUsername\AppData\Roaming\MetaQuotes\Terminal\INSTANCE_ID
mt4_data_folders = config["MT4_FOLDERS"].split(",") if config["MT4_FOLDERS"] else None
assert mt4_data_folders is not None, "MT4_FOLDERS is not set in .env file"
for folder in mt4_data_folders:
    assert os.path.exists(folder), f"MT4 data folder does not exist: {folder}"
mql4_files_folder = os.path.join(mt4_data_folders[0], "MQL4", "Files")

# --- Files used for communication ---
# Queue file (Python writes signals here temporarily) - Can be anywhere Python has access
MT4_QUEUE_FILE_PATHS = os.path.join(_basedir, "signals_queue.txt") # Store alongside scripts
print(f"MT4_QUEUE_FILE_PATH: {MT4_QUEUE_FILE_PATHS}")

# Signal file (Python writes final signal here for EA) - MUST be in MQL4/Files
MT4_SIGNAL_FILE_PATHS = os.path.join(mql4_files_folder, "signals.txt")
print(f"MT4_SIGNAL_FILE_PATH: {MT4_SIGNAL_FILE_PATHS}")

# Stoploss update file (Python writes SL commands here for EA) - MUST be in MQL4/Files
STOPLOSS_UPDATE_FILE_PATHS = os.path.join(mql4_files_folder, "stoploss_update.txt")
print(f"STOPLOSS_UPDATE_FILE_PATH: {STOPLOSS_UPDATE_FILE_PATHS}")

# --- Files for Python Bot State ---
# File to store the last used Group ID (Python internal state) - Can be anywhere
LAST_GID_FILE = os.path.join(_basedir, "last_group_id.txt")

# File to store Message ID <-> Group ID mapping (Python internal state) - Can be anywhere
MESSAGE_GID_MAP_FILE = os.path.join(_basedir, "message_gid_map.json")

# ----------------------
# Risk Management and Lot Size
# ----------------------
USE_RISK_MANAGEMENT = False  # Set to True to use dynamic lot size calculation
FIXED_LOT_SIZE = 0.02        # Used if USE_RISK_MANAGEMENT is False

# --- Settings for Dynamic Lot Size (if USE_RISK_MANAGEMENT = True) ---
# These values are placeholders - adjust them!
ACCOUNT_BALANCE = 1000.0     # Account balance to use for calculation
RISK_PERCENTAGE = 1.0        # Percentage of balance to risk per trade (e.g., 1.0 for 1%)
# --- Pip Value Calculation ---
# This is highly dependent on the broker and symbol.
# You might need a more sophisticated way to determine this.
# Option 1: Assume a default (common for Forex majors on USD accounts)
DEFAULT_PIP_VALUE_PER_LOT = 10.0 # Value of 1 pip for 1 standard lot (e.g., $10)
# Option 2: Symbol-specific mapping (Example)
# SYMBOL_PIP_VALUES = {
#    "EURUSD": 10.0,
#    "GBPUSD": 10.0,
#    "XAUUSD": 10.0, # Pip value for Gold depends on contract size & quote currency
#    "BTCUSD": 1.0, # Pip value for BTC depends heavily on contract size
# }
# DEFAULT_PIP_VALUE_PER_LOT = 10.0 # Fallback if symbol not in map

# --- Pip Size ---
# Common pip sizes (adjust per symbol if necessary, though often consistent)
# Forex (5-digit): 0.0001
# Forex (JPY pairs, 3-digit): 0.01
# XAUUSD: 0.01 (usually)
# Indices/Other: Varies
DEFAULT_PIP_SIZE = 0.0001 # Adjust as needed, or make symbol-specific
SYMBOL_PIP_SIZES = {
    "XAUUSD": 0.01,
    "DEFAULT": 0.0001 # Fallback
}
