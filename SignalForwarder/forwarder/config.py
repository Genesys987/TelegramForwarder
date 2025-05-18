# --- config.py (Updated) ---
import os

# Get the directory where config.py is located
_basedir = os.path.dirname(os.path.abspath(__file__))

# ----------------------
# Telegram Bot Settings
# ----------------------
API_ID = 23927353  # Replace with your API ID
API_HASH = "6b90fd26af02e0a3a642b9f846417c3e"  # Replace with your API Hash
INVITE_LINKS = [
    "https://t.me/+MlRMaKSc0_gxMGNk",
    "https://t.me/+Qs5PUoQSXWxlNzBk"
       
]
# Ensure INVITE_LINKS contains valid targets

# ----------------------
# MT4 File Paths
# IMPORTANT: Verify these paths are correct for YOUR MT4 installation!
# Use raw strings (r"...") or double backslashes (\\) for Windows paths.
# ---
# Default MT4 Data Folder path component (adjust if needed)
# Often like: C:\Users\YourUsername\AppData\Roaming\MetaQuotes\Terminal\INSTANCE_ID
_mt4_data_folder = "C:\\Users\\Juhász Áron\\AppData\\Roaming\\MetaQuotes\\Terminal\\893F70E9EF760D3B32BDD358B27B8555"
_mql4_files_folder = os.path.join(_mt4_data_folder, "MQL4", "Files")

# --- Files used for communication ---
# Queue file (Python writes signals here temporarily) - Can be anywhere Python has access
MT4_QUEUE_FILE_PATH = os.path.join(_basedir, "signals_queue.txt") # Store alongside scripts

# Signal file (Python writes final signal here for EA) - MUST be in MQL4/Files
MT4_SIGNAL_FILE_PATH = os.path.join(_mql4_files_folder, "signals.txt")

# Stoploss update file (Python writes SL commands here for EA) - MUST be in MQL4/Files
STOPLOSS_UPDATE_FILE_PATH = os.path.join(_mql4_files_folder, "stoploss_update.txt")

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