import os

from filelock import FileLock

from config import LAST_GID_FILE, MESSAGE_GID_MAP_FILE


_basedir = os.path.dirname(os.path.abspath(__file__))

signal_archive_lock = FileLock(os.path.join(_basedir, "logs", "signals_archive_lock.txt"), timeout=5)
queue_files_lock = FileLock(os.path.join(_basedir, "queue_files.lock"), timeout=5)
last_gid_lock = FileLock(LAST_GID_FILE + ".lock", timeout=5)
message_gid_map_lock = FileLock(MESSAGE_GID_MAP_FILE + ".lock", timeout=5)
