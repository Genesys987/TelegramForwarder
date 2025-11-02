import re
import json # GID map perzisztenciához
from datetime import datetime, timezone
from telethon import TelegramClient, events
import traceback
import os
import logging
from warmup_signals import generate_warmup_signal, is_warmup_message
from signal_parser import clean_channel_name, parse_signal
from queue_manager import add_signal_to_queue
from stoploss_update import process_stoploss_reply, SignalType, process_signal, process_stoploss_non_reply
from config import (API_ID, API_HASH, INVITE_LINKS,
           LAST_GID_FILE, MESSAGE_GID_MAP_FILE, ARCHIVE_CHANNEL, NON_REPLY_SL_CHANNEL_ID, WARMUP_SIGNAL_CHANNEL)
from signal_parser import SignalData

logger = logging.getLogger(__name__)

# --- Perzisztens Group ID Számláló ---
current_group_id = 1000
def load_last_gid(): # Betöltés indításkor
    global current_group_id
    try:
        if os.path.exists(LAST_GID_FILE):
            with open(LAST_GID_FILE, "r") as f: current_group_id = int(f.read().strip())
            logger.info(f"Utolsó GID betöltve: {current_group_id}. Következő: {current_group_id + 1}")
        else: logger.info(f"{LAST_GID_FILE} nem található, GID indul: {current_group_id + 1}")
    except Exception as e: logger.error(f"Hiba GID betöltésekor: {e}. Indul: {current_group_id + 1}")
def save_last_gid(): # Mentés növelés után
    global current_group_id
    try:
        with open(LAST_GID_FILE, "w") as f: f.write(str(current_group_id))
    except Exception as e: logger.error(f"Hiba GID mentésekor: {e}")
def get_next_group_id(): # Következő GID lekérése és mentése
    global current_group_id; current_group_id += 1; save_last_gid(); return current_group_id



# --- Perzisztens Message ID <-> GID Összerendelés ---
message_id_to_group_id = {}

# --- Warmup Signal Tracking ---
# Store the last warmup signal GID from FXTM channel
current_warmup_gid = None
def load_message_gid_map(): # Betöltés indításkor
    global message_id_to_group_id
    try:
        if os.path.exists(MESSAGE_GID_MAP_FILE):
            with open(MESSAGE_GID_MAP_FILE, "r", encoding='utf-8') as f:
                data = json.load(f); message_id_to_group_id = {int(k): v for k, v in data.items()}
            logger.info(f"{len(message_id_to_group_id)} üzenet->GID map betöltve.")
        else: logger.info(f"{MESSAGE_GID_MAP_FILE} nem található, üres map."); message_id_to_group_id = {}
    except Exception as e: logger.error(f"Hiba map betöltésekor: {e}"); message_id_to_group_id = {}
def save_message_gid_map(): # Mentés hozzáadás után
    global message_id_to_group_id
    try:
        with open(MESSAGE_GID_MAP_FILE, "w", encoding='utf-8') as f:
             json.dump({str(k): v for k, v in message_id_to_group_id.items()}, f, indent=4)
    except Exception as e: logger.error(f"Hiba map mentésekor: {e}")
def add_gid_mapping(message_id: int, group_id: int): # Hozzáadás és mentés
     if not isinstance(message_id, int) or not isinstance(group_id, int): return
     message_id_to_group_id[message_id] = group_id; save_message_gid_map()

# --- Telethon Client Setup ---
SESSION_NAME = "userbot_session"
client = TelegramClient(SESSION_NAME, API_ID, API_HASH)

# --- Fő Feldolgozó Függvények ---
sl_clause="(sl|stoploss|stop loss)?"
stoploss_regexp=fr"{sl_clause}.*(level|change|move|moving|adjust|set|update).*{sl_clause}.*\d+"

def populate_signal_metadata(signal_data, message_date, channel_name, is_warmup=False):
    """
    Populate signal_data with channel name and UTC timestamp.
    For warmup signals, set .original_channel instead of .channel_name.
    """
    # Add cleaned channel name to signal data
    clean_name = clean_channel_name(channel_name) if channel_name else clean_channel_name("UNKNOWN")
    if is_warmup:
      signal_data.original_channel = clean_name
    else:
      signal_data.channel_name = clean_name
    logger.info(f"   Csatorna név hozzáadva: '{channel_name or 'UNKNOWN'}' -> '{clean_name}'")

    # Extract UTC timestamp in milliseconds
    if message_date:
        # Convert to UTC if not already
        if message_date.tzinfo is None:
            message_date = message_date.replace(tzinfo=timezone.utc)
        else:
            message_date = message_date.astimezone(timezone.utc)
        timestamp = int(message_date.timestamp())
        signal_data.timestamp_utc = timestamp
        logger.info(f"   Timestamp hozzáadva: {timestamp} ({message_date.isoformat()})")
    else:
        logger.warning(f"   Figyelmeztetés: Nincs üzenet dátum, jelenlegi időt használjuk")
        timestamp = int(datetime.now(timezone.utc).timestamp())
        signal_data.timestamp_utc = timestamp

async def process_new_standard_signal(message_text: str, message_id: int, message_date, channel_name: str = None):
    logger.info(f"   Standard szignál feldolgozása (ID: {message_id}) csatornából: {channel_name or 'UNKNOWN'}...")
    signal_data = parse_signal(message_text)
    if not signal_data: logger.warning(f"   Szignál parse sikertelen."); return None

    # Use helper for metadata
    populate_signal_metadata(signal_data, message_date, channel_name, is_warmup=False)

    group_id = get_next_group_id() # Generáljuk az ÚJ GID-t
    signal_data.group_id = group_id # Hozzáadjuk a dict-hez
    logger.info(f"   Új GroupID: {group_id}")

    add_gid_mapping(message_id, group_id) # Eltároljuk az összerendelést
    logger.info(f"   Map tárolva: MsgID {message_id} -> GID {group_id}")

    # Hozzáadjuk a queue-hoz (a queue manager formázza és írja a queue fájlba)
    if add_signal_to_queue(signal_data): logger.info(f"   Jelzés queue-hoz adva (GID {group_id})."); return group_id
    else: logger.error(f"   Hiba: Jelzés queue-hoz adása sikertelen (GID {group_id})."); return None

async def process_warmup_signal(message_text: str, message_id: int, message_date, channel_name: str = None):
    """Process ready messages and generate warmup signals."""
    logger.info(f"   Warmup szignál feldolgozása (ID: {message_id}) csatornából: {channel_name or 'UNKNOWN'}...")

    is_ready, signal_type, _ = is_warmup_message(message_text)
    if not is_ready:
        return None

    logger.info(f"   Ready üzenet felismerve: {signal_type} (EA számítja ki TP/SL értékeket)")

    # Generate warmup signal
    signal_data = generate_warmup_signal(signal_type)
    if not signal_data:
        logger.error("   Warmup signal generálás sikertelen")
        return None

    # Use helper for metadata (is_warmup=True)
    populate_signal_metadata(signal_data, message_date, channel_name, is_warmup=True)

    group_id = get_next_group_id()
    signal_data.group_id = group_id
    logger.info(f"   Új Warmup GroupID: {group_id}")

    add_gid_mapping(message_id, group_id)
    logger.info(f"   Map tárolva: MsgID {message_id} -> GID {group_id}")

    # Store warmup signal GID for later modification
    global current_warmup_gid
    current_warmup_gid = group_id
    logger.info(f"   Warmup signal tárolva: GID {group_id}")

    # Add to queue
    if add_signal_to_queue(signal_data):
        logger.info(f"   Warmup jelzés queue-hoz adva (GID {group_id}).")
        return group_id
    else:
        logger.error(f"   Hiba: Warmup jelzés queue-hoz adása sikertelen (GID {group_id}).")
        # Clear warmup GID if failed to add to queue
        current_warmup_gid = None
        return None

async def process_fxtm_signal_modify(signal_data: SignalData):
    """Process FXTM signals as modifications to existing warmup signals."""
    global current_warmup_gid

    # Check if there's a pending warmup signal
    if not current_warmup_gid:
        logger.info(f"   Nincs várakozó warmup signal, standard processing.")
        return False

    logger.info(f"   FXTM signal modify: GID {current_warmup_gid} frissítése új TP/SL értékekkel")

    # Create modify signal with new TP/SL values but keep original GID
    modify_data = SignalData(
      signal_type="MODIFY",
      group_id=current_warmup_gid,  # Use original warmup GID
      symbol=signal_data.symbol or "XAUUSD",
      take_profits=signal_data.take_profits or [],
      stop_loss=signal_data.stop_loss,
      channel_name=WARMUP_SIGNAL_CHANNEL,  # Use configured channel for EA recognition
      timestamp_utc=signal_data.timestamp_utc,
      is_modify=True
    )

    # Add to queue as modification
    if add_signal_to_queue(modify_data):
        logger.info(f"   FXTM modify signal queue-hoz adva (GID {current_warmup_gid}).")
        # Clear warmup tracking as it's now processed
        warmup_gid = current_warmup_gid
        current_warmup_gid = None
        logger.info(f"   Warmup signal törölve a trackingből")
        return warmup_gid
    else:
        logger.error(f"   Hiba: FXTM modify signal queue-hoz adása sikertelen (GID {current_warmup_gid}).")
        return False

# --- Main Bot Logic ---
async def run_userbot():
    logger.info("Bot indítása...")
    load_last_gid()
    load_message_gid_map()
    try: await client.start(); logger.info("Sikeres csatlakozás Telethon kliensként.")
    except Exception as e: logger.error(f"Hiba kliens indításakor: {e}"); return

    # Fill entity cache with channel IDs
    dialogs = await client.get_dialogs()
    with open("channels.txt", "w", encoding='utf-8') as f:
        for dialog in dialogs:
            if dialog.is_channel:
                entity = dialog.entity
                if hasattr(entity, 'id') and hasattr(entity, 'title'):
                    access_hash = getattr(entity, 'access_hash', None)
                    if access_hash is not None:
                        f.write(f"{entity.id} - {entity.title} - access_hash: {access_hash}\n")
                    else:
                        f.write(f"{entity.id} - {entity.title} - access_hash: None\n")
                else:
                    f.write(f"{entity.id} - (Nincs cím)\n")
    logger.info("Csatorna cache kiírva 'channels.txt'-be.")
    joined_chats_entity = []
    if not INVITE_LINKS: logger.warning("Figyelmeztetés: Nincsenek csatornák megadva.")
    else:
        for link_or_channel_id in INVITE_LINKS:
            try:
                logger.info(f"Csatlakozás ehhez: {link_or_channel_id}...")
                # Convert to int if digits only, otherwise keep as string
                if re.match(r'^[\d-]+$', link_or_channel_id):
                    link_or_channel_id = int(link_or_channel_id)
                entity = await client.get_entity(link_or_channel_id)
                title = getattr(entity, 'title', f"ID: {entity.id}")
                logger.info(f"✅ Figyelés beállítva erre: {title}")
                joined_chats_entity.append(entity)
            except Exception as e: logger.error(f"❌ Hiba csatorna kezelésekor ({link_or_channel_id}): {e}")
    if not joined_chats_entity:
        logger.warning("Figyelmeztetés: Nem figyelünk csatornákat.")
        quit()


    @client.on(events.NewMessage(chats=joined_chats_entity))
    async def new_message_handler(event):
        message = event.message; message_text = message.text; message_id = message.id
        chat_title = getattr(event.chat, 'title', None) or getattr(event.chat, 'username', None) or str(event.chat_id)
        if not message_text: return
        logger.info(f"📩 Új üzenet innen: '{chat_title}' (ID: {message_id})")

        # === Reply üzenet kezelése ===
        if message.is_reply:
            reply_to_msg_id = message.reply_to_msg_id
            logger.info(f"   Válasz. Eredeti ID: {reply_to_msg_id}")
            reply_original_message = await message.get_reply_message()
            if reply_original_message:
                # Extract common variables for reply commands
                retrieved_group_id = message_id_to_group_id.get(reply_to_msg_id)
                clean_channel = clean_channel_name(chat_title)

                # --- Unified trading instruction pattern matching ---
                signal_type = None
                # CLOSE
                if re.search(r'close.*(profit|half|all).*breakeven', message_text, re.IGNORECASE) or \
                     re.search(r'close.*half.*hold', message_text, re.IGNORECASE) or \
                     re.search(r'close.*entries.*breakeven', message_text, re.IGNORECASE) or \
                     re.search(r'secure.*(entry|entries|first|profit)', message_text, re.IGNORECASE) or \
                     re.search(r'(close|exit|entries\s+are\s+closed)', message_text, re.IGNORECASE):
                    signal_type = SignalType.CLOSE
                # MODIFY (SL adjust)
                elif re.search(stoploss_regexp, message_text, re.IGNORECASE):
                    signal_type = SignalType.MODIFY
                # BREAKEVEN
                elif re.search(r'(breakeven|break\s*even|set\s+breakeven)', message_text, re.IGNORECASE):
                    signal_type = SignalType.BREAKEVEN

                if signal_type:
                    logger.info(f"Processing trading instruction: {signal_type}")
                    if retrieved_group_id:
                        is_success = False
                        if signal_type == SignalType.MODIFY:
                            is_success = process_stoploss_reply(message_text, retrieved_group_id, clean_channel)
                        else:
                            is_success = process_signal(signal_type, retrieved_group_id, clean_channel)
                        if is_success:
                            await forward_to_archive(message, chat_title, retrieved_group_id)
                        else:
                            logger.error(f"❌ Parancs hiba: {signal_type}")
                    else:
                        logger.warning(f"Nincs GID találat (ID: {reply_to_msg_id}). A kereskedési utasítás nem lett feldolgozva!")
                else:
                    logger.info(f"Ismeretlen kereskedési utasítás.")

            else: logger.error(f"   Hiba: Eredeti üzenet lekérése sikertelen (ID: {reply_to_msg_id}).")
            return

        # === Standard szignál és warmup feldolgozás ===
        else:
            # Check for non-reply SL modification messages
            if re.search(stoploss_regexp, message_text, re.IGNORECASE):
                logger.info(f"Non-reply SL modification észlelve: {message_text}")
                try:
                    # Non-reply SL modification konfigurálható csatornán (teszteléshez)
                    # Konfigurációból vesszük a csatorna nevet (alapértelmezett: FXTM)
                    channel_name = NON_REPLY_SL_CHANNEL_ID
                    success = process_stoploss_non_reply(message_text, channel_name)
                    if success:
                        logger.info(f"Non-reply SL modification sikeresen feldolgozva {channel_name} csatornából")
                        await forward_to_archive(message, chat_title, None)  # Forward to archive without group_id
                    else:
                        logger.warning(f"Non-reply SL modification feldolgozása sikertelen {channel_name} csatornából")
                except Exception as e:
                    logger.error(f"Hiba non-reply SL modification feldolgozásakor: {e}")
                    traceback.print_exc()
                return  # Don't process as standard signal

            # === Standard szignál feldolgozás ===
            try:
                group_id = None

                # First check if warmup signals are enabled and this is a ready message
                is_ready, signal_type, _ = is_warmup_message(message_text)
                if is_ready:
                    # Process warmup signal (EA will calculate TP/SL from zeros)
                    group_id = await process_warmup_signal(message_text, message_id, message.date, chat_title)
                    if group_id is not None:
                        await forward_to_archive(message, chat_title, group_id)
                    return  # Don't process as standard signal

                # Try to parse as standard signal
                signal_data = parse_signal(message_text)
                if signal_data:
                    # Check if this is from warmup channel and should modify a warmup signal
                    clean_name = clean_channel_name(chat_title)
                    warmup_channel_clean = clean_channel_name(WARMUP_SIGNAL_CHANNEL)
                    if clean_name == warmup_channel_clean and current_warmup_gid:
                        # Add metadata to signal_data
                        if message.date:
                            if message.date.tzinfo is None:
                                message_date = message.date.replace(tzinfo=timezone.utc)
                            else:
                                message_date = message.date.astimezone(timezone.utc)
                            signal_data.timestamp_utc = int(message_date.timestamp())
                        else:
                            signal_data.timestamp_utc = int(datetime.now(timezone.utc).timestamp())

                        # Process as modify signal
                        warmup_gid = await process_fxtm_signal_modify(signal_data)
                        if warmup_gid:
                            await forward_to_archive(message, chat_title, warmup_gid)
                        return  # Don't process as standard signal

                # Process as standard signal if not warmup or FXTM modify
                group_id = await process_new_standard_signal(message_text, message_id, message.date, chat_title)
                if group_id is not None:
                    await forward_to_archive(message, chat_title, group_id)

            except Exception as e:
                logger.error(f"   Hiba signal feldolgozás hívásakor: {e}"); traceback.print_exc()

    logger.info("🟢 Userbot elindult. Várakozás...")
    await client.run_until_disconnected()

async def forward_to_archive(message, channel_name, group_id):
    """
    Forward a message to the archive channel.
    """
    if ARCHIVE_CHANNEL:
        try:
            if group_id is not None:
                cleaned_channel = f"#{clean_channel_name(channel_name)} - {group_id}"
            else:
                # For non-reply SL modifications, don't include group_id
                cleaned_channel = f"#{clean_channel_name(channel_name)} - SL_MOD"
            message_text = f"{cleaned_channel}\n\n{message.text}"
            await client.send_message(ARCHIVE_CHANNEL, message_text)
            logger.info(f"📤 Üzenet továbbítva az archív csatornára: {ARCHIVE_CHANNEL}")
        except Exception as e:
            logger.error(f"❌ Hiba az üzenet továbbítása során az archív csatornára ({ARCHIVE_CHANNEL}): {e}")
    else:
        logger.warning("Figyelmeztetés: Nincs archív csatorna megadva.")
