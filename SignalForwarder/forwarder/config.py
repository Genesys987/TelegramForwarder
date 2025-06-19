# --- config.py (Refactored for .env use) ---
import os
import logging
from dotenv import dotenv_values

# Set up basic logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Helper function to ensure file and parent directories exist
def ensure_file(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "a").close()
    logging.debug(f"Ensured file exists: {path}")

# Get the directory where config.py is located
_basedir = os.path.dirname(os.path.abspath(__file__))

# Load configuration from .env file (using absolute path)
env_path = os.path.join(_basedir, ".env")
if not os.path.exists(env_path):
    print(f"Warning: .env file not found at {env_path}")
    config = {}
else:
    config = dotenv_values(env_path)
    print(f"Loaded configuration from {env_path}")

# ----------------------
# Telegram Bot Settings
# ----------------------
API_ID = config.get("TELEGRAM_API_ID")
API_HASH = config.get("TELEGRAM_API_HASH")

# Validate critical settings
if not API_ID:
    raise RuntimeError("TELEGRAM_API_ID is not set in .env file")
if not API_HASH:
    raise RuntimeError("TELEGRAM_API_HASH is not set in .env file")

# Log settings (masking sensitive data)
print(f"Loaded TELEGRAM_API_ID: {API_ID}")
print(f"Loaded TELEGRAM_API_HASH: {'*' * 8}")

# Load and parse channel join targets (includes invite links)
CHANNEL_JOIN_TARGETS_RAW = config.get("CHANNEL_JOIN_TARGETS", "")
CHANNEL_JOIN_TARGETS = [target.strip() for target in CHANNEL_JOIN_TARGETS_RAW.split(",") if target.strip()]

# Log the loaded targets
print(f"Loaded {len(CHANNEL_JOIN_TARGETS)} channel target(s)")
for i, target in enumerate(CHANNEL_JOIN_TARGETS):
    print(f"  Channel target {i+1}: {target}")

# For backward compatibility with older code
INVITE_LINKS = CHANNEL_JOIN_TARGETS

# ----------------------
# MT4 File Paths
# ----------------------
# Default MT4 Data Folder path component
mt4_data_folder = config.get("MT4_FOLDER")
if not mt4_data_folder:
    raise RuntimeError("MT4_FOLDER is not set in .env file")
if not os.path.exists(mt4_data_folder):
    raise RuntimeError(f"MT4 data folder does not exist: {mt4_data_folder}")

print(f"Loaded MT4_FOLDER: {mt4_data_folder}")
mql4_files_folder = os.path.join(mt4_data_folder, "MQL4", "Files")

# --- Files used for communication ---
# Queue file (Python writes signals here temporarily) - Now also in MQL4/Files to be accessible by EA
MT4_QUEUE_FILE_PATH = os.path.join(mql4_files_folder, "signals_queue.txt") # Store in MQL4/Files
print(f"MT4_QUEUE_FILE_PATH: {MT4_QUEUE_FILE_PATH}")
ensure_file(MT4_QUEUE_FILE_PATH)

# Signal file (Python writes final signal here for EA) - MUST be in MQL4/Files
MT4_SIGNAL_FILE_PATH = os.path.join(mql4_files_folder, "signals.txt")
print(f"MT4_SIGNAL_FILE_PATH: {MT4_SIGNAL_FILE_PATH}")
ensure_file(MT4_SIGNAL_FILE_PATH)

# Stoploss update file (Python writes SL commands here for EA) - MUST be in MQL4/Files
STOPLOSS_UPDATE_FILE_PATH = os.path.join(mql4_files_folder, "stoploss_update.txt")
print(f"STOPLOSS_UPDATE_FILE_PATH: {STOPLOSS_UPDATE_FILE_PATH}")
ensure_file(STOPLOSS_UPDATE_FILE_PATH)

# --- Files for Python Bot State ---
# File to store the last used Group ID (Python internal state) - Can be anywhere
LAST_GID_FILE = os.path.join(_basedir, "last_group_id.txt")
ensure_file(LAST_GID_FILE)

# File to store Message ID <-> Group ID mapping (Python internal state) - Can be anywhere
MESSAGE_GID_MAP_FILE = os.path.join(_basedir, "message_gid_map.json")
ensure_file(MESSAGE_GID_MAP_FILE)

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
