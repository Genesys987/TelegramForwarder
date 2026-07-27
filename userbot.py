import json  # GID map perzisztenciához
import logging
import os
import re
import traceback
from datetime import datetime, timezone

from telethon import TelegramClient, events

from config import (
    API_HASH,
    API_ID,
    ARCHIVE_CHANNEL,
    ENABLE_BREAKEVEN_SIGNALS,
    INVITE_LINKS,
    LAST_GID_FILE,
    MESSAGE_GID_MAP_FILE,
    NON_REPLY_SL_CHANNEL_ID,
    SESSION_NAME,
    WARMUP_SIGNAL_CHANNEL,
)
from file_locks import last_gid_lock, message_gid_map_lock
from queue_manager import add_signal_to_queue
from signal_parser import SignalData, clean_channel_name, parse_signal
from stoploss_update import (
    find_latest_group_id_for_channel,
    process_signal,
    process_stoploss_non_reply,
    process_stoploss_reply,
)
from warmup_signals import generate_warmup_signal, is_warmup_message

logger = logging.getLogger(__name__)

# --- Perzisztens Group ID Számláló ---
current_group_id = 1000


@last_gid_lock
def load_last_gid():  # Betöltés indításkor
    global current_group_id
    try:
        if os.path.exists(LAST_GID_FILE):
            with open(LAST_GID_FILE, "r") as f:
                current_group_id = int(f.read().strip())
            logger.info(
                f"Utolsó GID betöltve: {current_group_id}. Következő: {current_group_id + 1}"
            )
        else:
            logger.info(
                f"{LAST_GID_FILE} nem található, GID indul: {current_group_id + 1}"
            )
    except Exception as e:
        logger.error(f"Hiba GID betöltésekor: {e}. Indul: {current_group_id + 1}")


@last_gid_lock
def save_last_gid():  # Mentés növelés után
    global current_group_id
    try:
        with open(LAST_GID_FILE, "w") as f:
            f.write(str(current_group_id))
    except Exception as e:
        logger.error(f"Hiba GID mentésekor: {e}")


@last_gid_lock
def get_next_group_id():  # Következő GID lekérése és mentése
    global current_group_id
    load_last_gid()
    current_group_id += 1
    save_last_gid()
    return current_group_id


# --- Perzisztens Message ID <-> GID Összerendelés ---
message_id_to_group_id = {}

# --- Warmup Signal Tracking ---
# Store the last warmup signal GID from FXTM channel
current_warmup_gid = None


@message_gid_map_lock
def load_message_gid_map():  # Betöltés indításkor
    global message_id_to_group_id
    try:
        if os.path.exists(MESSAGE_GID_MAP_FILE):
            with open(MESSAGE_GID_MAP_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                message_id_to_group_id = {int(k): v for k, v in data.items()}
            logger.info(f"{len(message_id_to_group_id)} üzenet->GID map betöltve.")
        else:
            logger.info(f"{MESSAGE_GID_MAP_FILE} nem található, üres map.")
            message_id_to_group_id = {}
    except Exception as e:
        logger.error(f"Hiba map betöltésekor: {e}")
        message_id_to_group_id = {}


@message_gid_map_lock
def save_message_gid_map():  # Mentés hozzáadás után
    global message_id_to_group_id
    try:
        with open(MESSAGE_GID_MAP_FILE, "w", encoding="utf-8") as f:
            json.dump(
                {str(k): v for k, v in message_id_to_group_id.items()}, f, indent=4
            )
    except Exception as e:
        logger.error(f"Hiba map mentésekor: {e}")


@message_gid_map_lock
def add_gid_mapping(message_id: int, group_id: int):  # Hozzáadás és mentés
    if not isinstance(message_id, int) or not isinstance(group_id, int):
        return
    load_message_gid_map()
    message_id_to_group_id[message_id] = group_id
    save_message_gid_map()


# --- Telethon Client Setup ---
client = None


# --- Message Handler ---
async def handle_new_message(event):
    message = event.message
    message_text = message.text
    message_id = message.id
    chat_title = (
        getattr(event.chat, "title", None)
        or getattr(event.chat, "username", None)
        or str(event.chat_id)
    )
    if not message_text:
        return
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
            signal_type = detect_signal_type(message_text, stoploss_regexp)

            if signal_type:
                logger.info(f"Processing trading instruction: {signal_type}")
                if retrieved_group_id:
                    is_success = False
                    if signal_type == "MODIFY":
                        is_success = process_stoploss_reply(
                            message_text, retrieved_group_id, clean_channel
                        )
                    else:
                        is_success = process_signal(
                            signal_type, retrieved_group_id, clean_channel
                        )
                    if is_success:
                        await forward_to_archive(
                            message, chat_title, retrieved_group_id
                        )
                    else:
                        logger.error(f"❌ Parancs hiba: {signal_type}")
                else:
                    logger.warning(
                        f"Nincs GID találat (ID: {reply_to_msg_id}). A kereskedési utasítás nem lett feldolgozva!"
                    )
            else:
                # Check if reply contains a new signal instead of just logging unknown
                signal_data = parse_signal(message_text)
                if signal_data:
                    # Check if this is a reply to a known warmup signal
                    if (
                        retrieved_group_id is not None
                        and current_warmup_gid is not None
                        and retrieved_group_id == current_warmup_gid
                    ):
                        logger.info(
                            f"Reply warmup modify felismerve: GID {retrieved_group_id}, TP/SL frissítés"
                        )
                        if message.date:
                            if message.date.tzinfo is None:
                                message_date = message.date.replace(tzinfo=timezone.utc)
                            else:
                                message_date = message.date.astimezone(timezone.utc)
                            signal_data.timestamp_utc = int(message_date.timestamp())
                        else:
                            signal_data.timestamp_utc = int(
                                datetime.now(timezone.utc).timestamp()
                            )
                        warmup_gid = await process_warmup_signal_modify(signal_data)
                        if warmup_gid:
                            await forward_to_archive(message, chat_title, warmup_gid)
                    else:
                        logger.info("Reply üzenetben új szignál felismerve!")
                        group_id = await process_new_standard_signal(
                            message_text, message_id, message.date, chat_title
                        )
                        if group_id is not None:
                            await forward_to_archive(message, chat_title, group_id)
                else:
                    logger.info("Ismeretlen kereskedési utasítás.")

        else:
            logger.error(
                f"   Hiba: Eredeti üzenet lekérése sikertelen (ID: {reply_to_msg_id})."
            )
        return

    # === Standard szignál és warmup feldolgozás ===
    else:
        # Check for trading instructions in non-reply messages
        signal_type = detect_signal_type(message_text, stoploss_regexp)

        if signal_type:
            logger.info(f"Non-reply trading instruction detected: {signal_type}")
            try:
                clean_channel = clean_channel_name(chat_title)

                # Find the latest group ID for this channel (same as process_stoploss_non_reply)
                latest_group_id = find_latest_group_id_for_channel(clean_channel)

                if latest_group_id is not None:
                    is_success = False

                    if signal_type == "MODIFY":
                        # Handle SL modification using existing logic
                        channel_name = NON_REPLY_SL_CHANNEL_ID
                        is_success = process_stoploss_non_reply(
                            message_text, channel_name, latest_group_id
                        )
                        if is_success:
                            logger.info(
                                f"Non-reply SL modification successfully processed from {channel_name}"
                            )
                    else:
                        # Handle CLOSE and BREAKEVEN operations on latest signal
                        is_success = process_signal(
                            signal_type, latest_group_id, clean_channel
                        )
                        if is_success:
                            logger.info(
                                f"Non-reply {signal_type} operation successfully processed with GID: {latest_group_id}"
                            )

                    if is_success:
                        await forward_to_archive(message, chat_title, latest_group_id)
                    else:
                        logger.warning(
                            f"Non-reply {signal_type} processing failed for GID: {latest_group_id}"
                        )
                else:
                    logger.warning(
                        f"No recent signals found for channel {clean_channel}, cannot process {signal_type}"
                    )

            except Exception as e:
                logger.error(f"Error processing non-reply trading instruction: {e}")
                traceback.print_exc()
            return  # Don't process as standard signal

        # === Standard szignál feldolgozás ===
        try:
            group_id = None
            clean_name = clean_channel_name(chat_title)
            warmup_channel_clean = clean_channel_name(WARMUP_SIGNAL_CHANNEL)
            if clean_name == warmup_channel_clean:
                # Warmup message
                logger.info(
                    "Checking for ready/warmup modify message in warmup channel."
                )
                # First check if warmup signals are enabled and this is a ready message
                is_ready, signal_type, _ = is_warmup_message(message_text)
                if is_ready:
                    # Process warmup signal (EA will calculate TP/SL from zeros)
                    group_id = await process_warmup_signal(
                        message_text, message_id, message.date, chat_title
                    )
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
                            signal_data.timestamp_utc = int(
                                datetime.now(timezone.utc).timestamp()
                            )

                        # Process as modify signal
                        warmup_gid = await process_warmup_signal_modify(signal_data)
                        if warmup_gid:
                            await forward_to_archive(message, chat_title, warmup_gid)
                        return  # Don't process as standard signal
                else:
                    return  # parse failed (e.g. ✅ marker) – nothing to do

            # Process as standard signal if not warmup or warmup modify
            group_id = await process_new_standard_signal(
                message_text, message_id, message.date, chat_title
            )
            if group_id is not None:
                await forward_to_archive(message, chat_title, group_id)

        except Exception as e:
            logger.error(f"   Hiba signal feldolgozás hívásakor: {e}")
            traceback.print_exc()


# --- Fő Feldolgozó Függvények ---
sl_clause = "(sl|stoploss|stop loss)?"
stoploss_regexp = (
    rf"{sl_clause}.*(change|move|moving|adjust|set|update).*{sl_clause}.*\d+"
)


def detect_signal_type(message_text, stoploss_regexp):
    """
    Detect the type of trading signal from message text.
    Returns SignalType enum value or None if no match.

    When ENABLE_BREAKEVEN_SIGNALS is True (default):
      - BREAKEVEN messages  -> "BREAKEVEN"
      - CLOSE messages      -> "BREAKEVEN"  (positions moved to BE, never closed)
    When ENABLE_BREAKEVEN_SIGNALS is False:
      - BREAKEVEN and CLOSE messages are ignored (returns None)
    MODIFY (SL adjust) is always active regardless of the toggle.
    """
    is_breakeven = bool(
        re.search(r"(breakeven|break\s*even)", message_text, re.IGNORECASE)
        or re.search(r"\bBE\b", message_text)  # uppercase BE = break even abbreviation
        or re.fullmatch(r"\s*Sl\s+entry\s*", message_text, re.IGNORECASE)  # standalone "Sl entry" = move SL to entry (breakeven)
        or re.search(r"go(?:ing)?\s+risk\s+free", message_text, re.IGNORECASE)  # "Going risk free" / "Go risk free"
    )
    is_close = bool(
        re.search(r"close.*(profit|half|all).*breakeven", message_text, re.IGNORECASE)
        or re.search(r"close.*half.*hold", message_text, re.IGNORECASE)
        or re.search(r"close.*entries.*breakeven", message_text, re.IGNORECASE)
        or re.search(
            r"secure.*(entry|entries|first|profit)", message_text, re.IGNORECASE
        )
        or re.search(
            r"(close|exit|entries\s+are\s+closed)", message_text, re.IGNORECASE
        )
    )

    # CLOSE: limit order deletion (reply-only in practice, but detected here)
    if (
        re.search("limit order expired", message_text, re.IGNORECASE)
        or re.search(r"delete\s+limit\s+order", message_text, re.IGNORECASE)
        or re.fullmatch(r"\s*delete\s*", message_text, re.IGNORECASE)
    ):
        return "CLOSE"

    # Both CLOSE and BREAKEVEN map to BREAKEVEN when the feature is enabled
    if ENABLE_BREAKEVEN_SIGNALS and (is_breakeven or is_close):
        return "BREAKEVEN"

    # MODIFY (SL adjust) – always active
    if re.search(stoploss_regexp, message_text, re.IGNORECASE):
        return "MODIFY"

    return None


GOLD_SHIFT_CHANNELS = ["BENS", "GOLD", "VIPE"]


def populate_signal_metadata(
    signal_data: SignalData,
    message_date: datetime | None,
    channel_name: str | None,
    is_warmup=False,
):
    """
    Populate signal_data with channel name and UTC timestamp.
    For warmup signals, set .original_channel instead of .channel_name.
    """
    # Add cleaned channel name to signal data
    clean_name = (
        clean_channel_name(channel_name)
        if channel_name
        else clean_channel_name("UNKNOWN")
    )
    if is_warmup:
        signal_data.original_channel = clean_name
    else:
        signal_data.channel_name = clean_name
    logger.info(
        f"   Csatorna név hozzáadva: '{channel_name or 'UNKNOWN'}' -> '{clean_name}'"
    )

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
        logger.warning(
            "   Figyelmeztetés: Nincs üzenet dátum, jelenlegi időt használjuk"
        )
        timestamp = int(datetime.now(timezone.utc).timestamp())
        signal_data.timestamp_utc = timestamp

    # For Art of Trading gold trades, add 1$ to the range
    if (
        signal_data.symbol == "XAUUSD"
        and signal_data.entry is not None
        and signal_data.channel_name in GOLD_SHIFT_CHANNELS
    ):
        logger.info("Shifting Gold signal by 1$")
        signal_data.entry = (
            signal_data.entry + 1
            if signal_data.signal_type == "BUY"
            else signal_data.entry - 1
        )


async def process_new_standard_signal(
    message_text: str, message_id: int, message_date, channel_name: str | None = None
):
    logger.info(
        f"   Standard szignál feldolgozása (ID: {message_id}) csatornából: {channel_name or 'UNKNOWN'}..."
    )
    signal_data = parse_signal(message_text)
    if not signal_data:
        logger.warning("   Szignál parse sikertelen.")
        return None

    # Use helper for metadata
    populate_signal_metadata(signal_data, message_date, channel_name, is_warmup=False)

    group_id = get_next_group_id()  # Generáljuk az ÚJ GID-t
    signal_data.group_id = group_id  # Hozzáadjuk a dict-hez
    logger.info(f"   Új GroupID: {group_id}")

    add_gid_mapping(message_id, group_id)  # Eltároljuk az összerendelést
    logger.info(f"   Map tárolva: MsgID {message_id} -> GID {group_id}")

    # Hozzáadjuk a queue-hoz (a queue manager formázza és írja a queue fájlba)
    if add_signal_to_queue(signal_data):
        logger.info(f"   Jelzés queue-hoz adva (GID {group_id}).")
        return group_id
    else:
        logger.error(f"   Hiba: Jelzés queue-hoz adása sikertelen (GID {group_id}).")
        return None


async def process_warmup_signal(
    message_text: str, message_id: int, message_date, channel_name: str | None = None
):
    """Process ready messages and generate warmup signals."""
    logger.info(
        f"   Warmup szignál feldolgozása (ID: {message_id}) csatornából: {channel_name or 'UNKNOWN'}..."
    )

    is_ready, signal_type, warmup_symbol = is_warmup_message(message_text)
    if not is_ready:
        return None

    logger.info(
        f"   Ready üzenet felismerve: {signal_type} {warmup_symbol} (EA számítja ki TP/SL értékeket)"
    )

    # Generate warmup signal with detected symbol
    signal_data = generate_warmup_signal(signal_type, warmup_symbol)
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
        logger.error(
            f"   Hiba: Warmup jelzés queue-hoz adása sikertelen (GID {group_id})."
        )
        # Clear warmup GID if failed to add to queue
        current_warmup_gid = None
        return None


async def process_warmup_signal_modify(signal_data: SignalData):
    """Process FXTM signals as modifications to existing warmup signals."""
    global current_warmup_gid

    # Check if there's a pending warmup signal
    if not current_warmup_gid:
        logger.info("   Nincs várakozó warmup signal, standard processing.")
        return False

    logger.info(
        f"   FXTM signal modify: GID {current_warmup_gid} frissítése új TP/SL értékekkel"
    )

    # Create modify signal with new TP/SL values but keep original GID
    modify_data = SignalData(
        signal_type="MODIFY",
        group_id=current_warmup_gid,  # Use original warmup GID
        symbol=signal_data.symbol or "XAUUSD",
        take_profits=signal_data.take_profits or [],
        stop_loss=signal_data.stop_loss,
        channel_name=WARMUP_SIGNAL_CHANNEL,  # Use configured channel for EA recognition
        timestamp_utc=signal_data.timestamp_utc,
        is_modify=True,
    )

    # Add to queue as modification
    if add_signal_to_queue(modify_data):
        logger.info(
            f"   Warmup modify signal queue-hoz adva (GID {current_warmup_gid})."
        )
        # Clear warmup tracking as it's now processed
        warmup_gid = current_warmup_gid
        current_warmup_gid = None
        logger.info("   Warmup signal törölve a trackingből")
        return warmup_gid
    else:
        logger.error(
            f"   Hiba: warmup modify signal queue-hoz adása sikertelen (GID {current_warmup_gid})."
        )
        return False


# --- Main Bot Logic ---
async def run_userbot():
    logger.info("Bot indítása...")
    load_last_gid()
    load_message_gid_map()
    # Create the Telethon client here (only after the event loop exists)
    global client
    client = TelegramClient(SESSION_NAME, API_ID, API_HASH)
    try:
        await client.start()
        logger.info("Sikeres csatlakozás Telethon kliensként.")
    except Exception as e:
        logger.error(f"Hiba kliens indításakor: {e}")
        return

    # Fill entity cache with channel IDs
    dialogs = await client.get_dialogs()
    with open(f"channels_{SESSION_NAME}.txt", "w", encoding="utf-8") as f:
        for dialog in dialogs:
            if dialog.is_channel:
                entity = dialog.entity
                if hasattr(entity, "id") and hasattr(entity, "title"):
                    access_hash = getattr(entity, "access_hash", None)
                    if access_hash is not None:
                        f.write(
                            f"{entity.id} - {entity.title} - access_hash: {access_hash}\n"
                        )
                    else:
                        f.write(f"{entity.id} - {entity.title} - access_hash: None\n")
                else:
                    f.write(f"{entity.id} - (Nincs cím)\n")
    logger.info("Csatorna cache kiírva 'channels.txt'-be.")
    joined_chats_entity = []
    if not INVITE_LINKS:
        logger.warning("Figyelmeztetés: Nincsenek csatornák megadva.")
    else:
        for link_or_channel_id in INVITE_LINKS:
            try:
                logger.info(f"Csatlakozás ehhez: {link_or_channel_id}...")
                # Convert to int if digits only, otherwise keep as string
                if re.match(r"^[\d-]+$", link_or_channel_id):
                    link_or_channel_id = int(link_or_channel_id)
                entity = await client.get_entity(link_or_channel_id)
                title = getattr(entity, "title", f"ID: {entity.id}")
                logger.info(f"✅ Figyelés beállítva erre: {title}")
                joined_chats_entity.append(entity)
            except Exception as e:
                logger.error(
                    f"❌ Hiba csatorna kezelésekor ({link_or_channel_id}): {e}"
                )
    if not joined_chats_entity:
        logger.warning("Figyelmeztetés: Nem figyelünk csatornákat.")
        quit()

    @client.on(events.NewMessage(chats=joined_chats_entity))
    async def new_message_handler(event):
        await handle_new_message(event)

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
            logger.error(
                f"❌ Hiba az üzenet továbbítása során az archív csatornára ({ARCHIVE_CHANNEL}): {e}"
            )
    else:
        logger.warning("Figyelmeztetés: Nincs archív csatorna megadva.")
