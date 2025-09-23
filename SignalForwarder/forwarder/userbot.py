import re
import json # GID map perzisztenciához
from datetime import datetime, timezone
from telethon import TelegramClient, events
import traceback
import os
import asyncio
from signal_parser import clean_channel_name
import logging
from signal_parser import parse_signal, is_ready_message, generate_warmup_signal
from queue_manager import add_signal_to_queue
from stoploss_update import process_stoploss_reply, SignalType, process_signal
from config import (API_ID, API_HASH, INVITE_LINKS,
           LAST_GID_FILE, MESSAGE_GID_MAP_FILE, ARCHIVE_CHANNEL, WARMUP_SIGNAL_ENABLED, WARMUP_SIGNAL_CHANNEL,
           MT4_SIGNAL_FILE_PATHS)
import time

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

async def get_current_market_price(symbol: str = "XAUUSD", timeout: int = 5) -> float:
    """
    Request current market price from EA.
    Sends GET_PRICE request and waits for response.
    """
    try:
        # Send price request to EA via price_request.txt
        request_message = f"GET_PRICE|{symbol}"
        
        for signal_path in MT4_SIGNAL_FILE_PATHS:
            # Use price_request.txt in the same directory as signals.txt
            price_request_path = os.path.join(os.path.dirname(signal_path), "price_request.txt")
            
            # Check if price request file already exists (EA might be busy)
            if os.path.exists(price_request_path):
                continue  # EA is processing another request, try next path
            
            # Try to create the request file
            try:
                with open(price_request_path, "w", encoding='utf-8') as f:
                    f.write(request_message)
                logger.info(f"   GET_PRICE kérés küldve az EA-nak: {symbol}")
                break
            except Exception as e:
                logger.error(f"   Hiba GET_PRICE kérés küldésekor: {e}")
                continue
        else:
            logger.warning("   Minden EA foglalt - EA futása szükséges a price request-ekhez")
            return None
        
        # Wait for response file (price_response.txt)
        response_file = os.path.join(os.path.dirname(signal_path), "price_response.txt")
        
        for _ in range(timeout * 10):  # Check every 100ms
            if os.path.exists(response_file):
                try:
                    with open(response_file, "r", encoding='utf-8') as f:
                        response = f.read().strip()
                    
                    # Delete response file
                    os.remove(response_file)
                    
                    # Parse response: "PRICE|XAUUSD|3746.50"
                    parts = response.split("|")
                    if len(parts) == 3 and parts[0] == "PRICE" and parts[1] == symbol:
                        price = float(parts[2])
                        logger.info(f"   Market price kapva EA-tól: {symbol} = {price}")
                        
                        # Clean up request file after successful response
                        try:
                            if os.path.exists(price_request_path):
                                os.remove(price_request_path)
                        except Exception:
                            pass  # Ignore cleanup errors
                        
                        return price
                    else:
                        logger.error(f"   Hibás price response formátum: {response}")
                        return None
                        
                except Exception as e:
                    logger.error(f"   Hiba price response olvasásakor: {e}")
                    return None
            
            await asyncio.sleep(0.1)  # Wait 100ms
        
        # Cleanup request file on timeout 
        try:
            if os.path.exists(price_request_path):
                os.remove(price_request_path)
                logger.warning(f"   Price request fájl törölve timeout miatt")
        except Exception:
            pass  # Ignore cleanup errors
            
        logger.warning(f"   Timeout: Nem érkezett price response {timeout}s alatt")
        return None
        
    except Exception as e:
        logger.error(f"   Hiba get_current_market_price-ban: {e}")
        return None

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

async def process_new_standard_signal(message_text: str, message_id: int, message_date, channel_name: str = None):
    logger.info(f"   Standard szignál feldolgozása (ID: {message_id}) csatornából: {channel_name or 'UNKNOWN'}...")
    signal_data = parse_signal(message_text)
    if not signal_data: logger.warning(f"   Szignál parse sikertelen."); return None
    
    # Add cleaned channel name to signal data
    if channel_name:
        clean_name = clean_channel_name(channel_name)
        signal_data["channel_name"] = clean_name
        logger.info(f"   Csatorna név hozzáadva: '{channel_name}' -> '{clean_name}'")
    else:
        signal_data["channel_name"] = clean_channel_name("UNKNOWN")
        logger.warning(f"   Figyelmeztetés: Nincs csatorna név, 'UNKN' használata")
    
    # Extract UTC timestamp in milliseconds
    if message_date:
        # Convert to UTC if not already
        if message_date.tzinfo is None:
            message_date = message_date.replace(tzinfo=timezone.utc)
        else:
            message_date = message_date.astimezone(timezone.utc)
        
        # Convert to UNIX milliseconds
        timestamp = int(message_date.timestamp())
        signal_data["timestamp_utc"] = timestamp
        logger.info(f"   Timestamp hozzáadva: {timestamp} ({message_date.isoformat()})")
    else:
        logger.warning(f"   Figyelmeztetés: Nincs üzenet dátum, jelenlegi időt használjuk")
        timestamp = int(datetime.now(timezone.utc).timestamp())
        signal_data["timestamp_utc"] = timestamp

    group_id = get_next_group_id() # Generáljuk az ÚJ GID-t
    signal_data["group_id"] = group_id # Hozzáadjuk a dict-hez
    logger.info(f"   Új GroupID: {group_id}")

    add_gid_mapping(message_id, group_id) # Eltároljuk az összerendelést
    logger.info(f"   Map tárolva: MsgID {message_id} -> GID {group_id}")

    # Hozzáadjuk a queue-hoz (a queue manager formázza és írja a queue fájlba)
    if add_signal_to_queue(signal_data): logger.info(f"   Jelzés queue-hoz adva (GID {group_id})."); return group_id
    else: logger.error(f"   Hiba: Jelzés queue-hoz adása sikertelen (GID {group_id})."); return None

async def process_warmup_signal(message_text: str, message_id: int, message_date, channel_name: str = None, market_price: float = None):
    """Process ready messages and generate warmup signals."""
    logger.info(f"   Warmup szignál feldolgozása (ID: {message_id}) csatornából: {channel_name or 'UNKNOWN'}...")
    
    is_ready, signal_type, _ = is_ready_message(message_text)
    if not is_ready:
        return None
        
    logger.info(f"   Ready üzenet felismerve: {signal_type} (instant execution)")
    if market_price:
        logger.info(f"   Market price használva: {market_price}")
    
    # Generate warmup signal
    signal_data = generate_warmup_signal(signal_type, market_price)
    if not signal_data:
        logger.error("   Warmup signal generálás sikertelen")
        return None
    
    # Add metadata
    if channel_name:
        clean_name = clean_channel_name(channel_name)
        signal_data["original_channel"] = clean_name  # Store original channel
        logger.info(f"   Eredeti csatorna: '{channel_name}' -> '{clean_name}'")
    else:
        signal_data["original_channel"] = clean_channel_name("UNKNOWN")
        logger.warning(f"   Figyelmeztetés: Nincs csatorna név, 'UNKN' használata")
    
    # Extract UTC timestamp
    if message_date:
        if message_date.tzinfo is None:
            message_date = message_date.replace(tzinfo=timezone.utc)
        else:
            message_date = message_date.astimezone(timezone.utc)
        timestamp = int(message_date.timestamp())
        signal_data["timestamp_utc"] = timestamp
        logger.info(f"   Timestamp hozzáadva: {timestamp} ({message_date.isoformat()})")
    else:
        timestamp = int(datetime.now(timezone.utc).timestamp())
        signal_data["timestamp_utc"] = timestamp

    group_id = get_next_group_id()
    signal_data["group_id"] = group_id
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

async def process_fxtm_signal_modify(signal_data: dict):
    """Process FXTM signals as modifications to existing warmup signals."""
    global current_warmup_gid
    
    # Check if there's a pending warmup signal
    if not current_warmup_gid:
        logger.info(f"   Nincs várakozó warmup signal, standard processing.")
        return False
        
    logger.info(f"   FXTM signal modify: GID {current_warmup_gid} frissítése új TP/SL értékekkel")
    
    # Create modify signal with new TP/SL values but keep original GID
    modify_data = {
        "signal_type": "MODIFY",
        "group_id": current_warmup_gid,  # Use original warmup GID
        "symbol": signal_data.get("symbol", "XAUUSD"),
        "take_profits": signal_data.get("take_profits", []),
        "stop_loss": signal_data.get("stop_loss"),
        "channel_name": WARMUP_SIGNAL_CHANNEL,  # Use configured channel for EA recognition
        "timestamp_utc": signal_data.get("timestamp_utc"),
        "is_modify": True
    }
    
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
                original_message_text = reply_original_message.text
                
                # Extract common variables for reply commands
                retrieved_group_id = message_id_to_group_id.get(reply_to_msg_id)
                clean_channel = clean_channel_name(chat_title)

                # --- Unified trading instruction pattern matching ---
                signal_type = None
                # MODIFY (SL adjust)
                if re.search(r'(change|move|adjust|set).*(sl|stoploss|stop loss)', message_text, re.IGNORECASE):
                    signal_type = SignalType.MODIFY
                # CLOSE_HALF_BREAKEVEN
                elif re.search(r'close.*(profit|half|all).*breakeven', message_text, re.IGNORECASE) or \
                     re.search(r'close.*half.*hold', message_text, re.IGNORECASE) or \
                     re.search(r'close.*entries.*breakeven', message_text, re.IGNORECASE) or \
                     re.search(r'secure.*(entry|entries|first|profit)', message_text, re.IGNORECASE):
                    signal_type = SignalType.CLOSE_HALF_BREAKEVEN
                # BREAKEVEN
                elif re.search(r'(breakeven|break\s*even|set\s+breakeven)', message_text, re.IGNORECASE):
                    signal_type = SignalType.BREAKEVEN
                # CLOSE
                elif re.search(r'(close|exit|entries\s+are\s+closed)', message_text, re.IGNORECASE):
                    signal_type = SignalType.CLOSE
                
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
            try:
                group_id = None
                
                # First check if warmup signals are enabled and this is a ready message
                if WARMUP_SIGNAL_ENABLED:
                    is_ready, signal_type, _ = is_ready_message(message_text)
                    if is_ready:
                        # Get current market price from EA (EA must be running!)
                        market_price = await get_current_market_price("XAUUSD")
                        if market_price:
                            group_id = await process_warmup_signal(message_text, message_id, message.date, chat_title, market_price)
                            if group_id is not None:
                                await forward_to_archive(message, chat_title, group_id)
                        else:
                            logger.error("   EA nem fut vagy nem elérhető - warmup signal kihagyva (EA futása szükséges!)")
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
                            signal_data["timestamp_utc"] = int(message_date.timestamp())
                        else:
                            signal_data["timestamp_utc"] = int(datetime.now(timezone.utc).timestamp())
                        
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
            cleaned_channel = f"#{clean_channel_name(channel_name)} - {group_id}"
            message_text = f"{cleaned_channel}\n\n{message.text}"
            await client.send_message(ARCHIVE_CHANNEL, message_text)
            logger.info(f"📤 Üzenet továbbítva az archív csatornára: {ARCHIVE_CHANNEL}")
        except Exception as e:
            logger.error(f"❌ Hiba az üzenet továbbítása során az archív csatornára ({ARCHIVE_CHANNEL}): {e}")
    else:
        logger.warning("Figyelmeztetés: Nincs archív csatorna megadva.")
