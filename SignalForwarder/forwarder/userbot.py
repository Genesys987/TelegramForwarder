# --- userbot.py (Refaktorálva a Python GID generáláshoz) ---

import asyncio
import re
import json # GID map perzisztenciához
from datetime import datetime, timezone
from telethon import TelegramClient, events
import traceback
import os

# --- Configuration ---
try:
    # Csak azokat importáljuk, amiket KÖZVETLENÜL használunk itt
    from config import (API_ID, API_HASH, INVITE_LINKS,
                        LAST_GID_FILE, MESSAGE_GID_MAP_FILE)
except ImportError as e:
    print(f"Hiba: Hianyzó alap beállítások a config.py-ban: {e}")
    exit()

# --- Feldolgozó és segéd modulok importálása ---
try: from signal_parser import parse_signal
except ImportError: print("Hiba: signal_parser.py/parse_signal hiányzik."); exit()
try: from queue_manager import add_signal_to_queue
except ImportError: print("Hiba: queue_manager.py/add_signal_to_queue hiányzik."); exit()
try: from stoploss_update import process_stoploss_reply
except ImportError: print("Hiba: stoploss_update.py/process_stoploss_reply hiányzik."); exit()


# --- Perzisztens Group ID Számláló ---
current_group_id = 1000
def load_last_gid(): # Betöltés indításkor
    global current_group_id
    try:
        if os.path.exists(LAST_GID_FILE):
            with open(LAST_GID_FILE, "r") as f: current_group_id = int(f.read().strip())
            print(f"Utolsó GID betöltve: {current_group_id}. Következő: {current_group_id + 1}")
        else: print(f"{LAST_GID_FILE} nem található, GID indul: {current_group_id + 1}")
    except Exception as e: print(f"Hiba GID betöltésekor: {e}. Indul: {current_group_id + 1}")
def save_last_gid(): # Mentés növelés után
    global current_group_id
    try:
        with open(LAST_GID_FILE, "w") as f: f.write(str(current_group_id))
    except Exception as e: print(f"Hiba GID mentésekor: {e}")
def get_next_group_id(): # Következő GID lekérése és mentése
    global current_group_id; current_group_id += 1; save_last_gid(); return current_group_id

# --- Perzisztens Message ID <-> GID Összerendelés ---
message_id_to_group_id = {}
def load_message_gid_map(): # Betöltés indításkor
    global message_id_to_group_id
    try:
        if os.path.exists(MESSAGE_GID_MAP_FILE):
            with open(MESSAGE_GID_MAP_FILE, "r", encoding='utf-8') as f:
                data = json.load(f); message_id_to_group_id = {int(k): v for k, v in data.items()}
            print(f"{len(message_id_to_group_id)} üzenet->GID map betöltve.")
        else: print(f"{MESSAGE_GID_MAP_FILE} nem található, üres map."); message_id_to_group_id = {}
    except Exception as e: print(f"Hiba map betöltésekor: {e}"); message_id_to_group_id = {}
def save_message_gid_map(): # Mentés hozzáadás után
    global message_id_to_group_id
    try:
        with open(MESSAGE_GID_MAP_FILE, "w", encoding='utf-8') as f:
             json.dump({str(k): v for k, v in message_id_to_group_id.items()}, f, indent=4)
    except Exception as e: print(f"Hiba map mentésekor: {e}")
def add_gid_mapping(message_id: int, group_id: int): # Hozzáadás és mentés
     if not isinstance(message_id, int) or not isinstance(group_id, int): return
     message_id_to_group_id[message_id] = group_id; save_message_gid_map()

# --- Telethon Client Setup ---
SESSION_NAME = "userbot_session"
client = TelegramClient(SESSION_NAME, API_ID, API_HASH)

# --- Fő Feldolgozó Függvények ---

async def process_new_standard_signal(message_text: str, message_id: int, message_date):
    """Parse-ol, lot-ot számol, GID-t generál, map-et tárol, queue-hoz ad, timestamp-et ad hozzá."""
    print(f"   Standard szignál feldolgozása (ID: {message_id})...")
    signal_data = parse_signal(message_text)
    if not signal_data: print(f"   Szignál parse sikertelen."); return None
    
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
        print(f"   Timestamp hozzáadva: {timestamp} ({message_date.isoformat()})")
    else:
        print(f"   Figyelmeztetés: Nincs üzenet dátum, jelenlegi időt használjuk")
        timestamp = int(datetime.now(timezone.utc).timestamp())
        signal_data["timestamp_utc"] = timestamp

    group_id = get_next_group_id() # Generáljuk az ÚJ GID-t
    signal_data["group_id"] = group_id # Hozzáadjuk a dict-hez
    print(f"   Új GroupID: {group_id}")

    add_gid_mapping(message_id, group_id) # Eltároljuk az összerendelést
    print(f"   Map tárolva: MsgID {message_id} -> GID {group_id}")

    # Hozzáadjuk a queue-hoz (a queue manager formázza és írja a queue fájlba)
    if add_signal_to_queue(signal_data): print(f"   Jelzés queue-hoz adva (GID {group_id})."); return group_id
    else: print(f"   Hiba: Jelzés queue-hoz adása sikertelen (GID {group_id})."); return None

# --- Main Bot Logic ---
async def run_userbot():
    print("Bot indítása...")
    load_last_gid()
    load_message_gid_map()
    try: await client.start(); print("Sikeres csatlakozás Telethon kliensként.")
    except Exception as e: print(f"Hiba kliens indításakor: {e}"); return

    joined_chats_entity = []
    if not INVITE_LINKS: print("Figyelmeztetés: Nincsenek csatornák megadva.")
    else:
        for link in INVITE_LINKS:
            try:
                print(f"Csatlakozás ehhez: {link}...")
                entity = await client.get_entity(link)
                title = getattr(entity, 'title', f"ID: {entity.id}")
                print(f"✅ Figyelés beállítva erre: {title}")
                joined_chats_entity.append(entity)
            except Exception as e: print(f"❌ Hiba csatorna kezelésekor ({link}): {e}")
    if not joined_chats_entity: 
        print("Figyelmeztetés: Nem figyelünk csatornákat.")
        quit()
    

    @client.on(events.NewMessage(chats=joined_chats_entity))
    async def new_message_handler(event):
        message = event.message; message_text = message.text; message_id = message.id
        chat_title = getattr(event.chat, 'title', None) or getattr(event.chat, 'username', None) or event.chat_id
        if not message_text: return
        print(f"📩 Új üzenet innen: '{chat_title}' (ID: {message_id})")

        # === Reply üzenet kezelése ===
        if message.is_reply:
            reply_to_msg_id = message.reply_to_msg_id
            print(f"   Válasz. Eredeti ID: {reply_to_msg_id}")
            reply_original_message = await message.get_reply_message()
            if reply_original_message:
                original_message_text = reply_original_message.text
                if re.search(r'(adjust|set|move)\s+(your\s+)?sl', message_text, re.IGNORECASE):
                    print(f"   SL állítás detektálva.")
                    # --- === GROUP_ID MEGSZERZÉSE === ---
                    retrieved_group_id = message_id_to_group_id.get(reply_to_msg_id)
                    # --- =========================== ---
                    if retrieved_group_id:
                        print(f"   Talált GID: {retrieved_group_id}")
                        command_written = process_stoploss_reply(message_text, original_message_text, retrieved_group_id)
                        if command_written: print(f"   ✅ SL parancs kiírva.")
                        else: print(f"   ❌ SL parancs hiba.")
                    else: print(f"   FIGYELEM: Nem található GID (ID: {reply_to_msg_id}). SL válasz nem feldolgozható!")
                else: print(f"   Nem SL állításnak tűnő válasz.")
            else: print(f"   Hiba: Eredeti üzenet lekérése sikertelen (ID: {reply_to_msg_id}).")
            return

        # === Standard szignál feldolgozás ===
        else:
            try: await process_new_standard_signal(message_text, message_id, message.date)
            except Exception as e: print(f"   Hiba process_new_standard_signal hívásakor: {e}"); traceback.print_exc()

    print("🟢 Userbot elindult. Várakozás...")
    await client.run_until_disconnected()

if __name__ == '__main__':
    try: asyncio.run(run_userbot())
    except KeyboardInterrupt: print("\nBot leállítva.")
    except Exception as e: print(f"\nKritikus hiba: {e}"); traceback.print_exc()
