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

ARCHIVE_CHANNEL = config.get("ARCHIVE_CHANNEL", None)

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

# --- Helper function to get MT4 data folder ID ---
def getMT4DataFolderId(folder_path):
    """
    Get the MT4 data folder ID from the last directory name.
    Takes the first 6 characters of the last folder name.
    Example: /path/to/7D024799C00A011848A10ECEDFE5CBC2 -> 7D0247
    """
    # Remove trailing separators (both / and \) first, then get basename
    cleaned_path = folder_path.rstrip("/\\")
    if not cleaned_path:
        return ""
    folder_name = os.path.basename(cleaned_path)
    return folder_name[:6] if len(folder_name) >= 6 else folder_name

# --- Files used for communication ---
# Queue files (Python writes signals here temporarily) - Can be anywhere Python has access
MT4_QUEUE_FILE_PATHS = []
for folder in mt4_data_folders:
    folder_id = getMT4DataFolderId(folder)
    queue_filename = f"signals_queue_{folder_id}.txt"
    queue_path = os.path.join(_basedir, queue_filename)
    MT4_QUEUE_FILE_PATHS.append(queue_path)
    print(f"MT4_QUEUE_FILE_PATH: {queue_path}")

# Signal files (Python writes final signal here for EA) - MUST be in MQL4/Files
MT4_SIGNAL_FILE_PATHS = []
for folder in mt4_data_folders:
    mql4_files_folder = os.path.join(folder, "MQL4", "Files")
    signal_path = os.path.join(mql4_files_folder, "signals.txt")
    MT4_SIGNAL_FILE_PATHS.append(signal_path)
    print(f"MT4_SIGNAL_FILE_PATH: {signal_path}")

# --- Files for Python Bot State ---
# File to store the last used Group ID (Python internal state) - Can be anywhere
LAST_GID_FILE = os.path.join(_basedir, "last_group_id.txt")

# File to store Message ID <-> Group ID mapping (Python internal state) - Can be anywhere
MESSAGE_GID_MAP_FILE = os.path.join(_basedir, "message_gid_map.json")
