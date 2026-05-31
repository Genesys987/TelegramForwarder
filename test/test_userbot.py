"""
Unit test for userbot.handle_new_message - specifically verifies that a
"close" style message triggers processing as a BREAKEVEN signal (because
ENABLE_BREAKEVEN_SIGNALS maps both CLOSE and BREAKEVEN to BREAKEVEN) and
that the message is forwarded to the archive when processing succeeds.

This test creates a minimal fake event / message object with only the
attributes accessed by `handle_new_message`.
"""

import unittest
import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

# Import the function and types to test
import sys
import os

# Add the project root to sys.path so 'userbot' can be imported
TEST_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(TEST_DIR)
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

# Patch 'telethon' with required attributes before importing userbot
sys.modules["telethon"] = SimpleNamespace(TelegramClient=None, events=None)

from config import signal_path
import userbot as ub


class FakeMessage:
    def __init__(self, text, msg_id, is_reply=False, reply_to_msg_id=None):
        self.text = text
        self.id = msg_id
        self.is_reply = is_reply
        self.reply_to_msg_id = reply_to_msg_id
        self.date = None

    async def get_reply_message(self):
        # Return a truthy object to simulate the original message being retrievable
        return SimpleNamespace(text="original")


class FakeEvent:
    def __init__(self, message, chat_title=None, chat_id=None):
        self.message = message
        # Simulate Telethon event.chat object which may have title or username
        self.chat = (
            SimpleNamespace(title=chat_title) if chat_title is not None else None
        )
        self.chat_id = chat_id


class TestHandleNewMessage(unittest.TestCase):
    def setUp(self):
        # Ensure mapping is clean before each test
        ub.message_id_to_group_id.clear()

    def test_handle_non_reply_close_signal(self):
        """
        Simulate a non-reply message that contains a 'close' instruction.
        Expectation:
         - userbot.process_signal is called with "BREAKEVEN" and the mapped group id
           (ENABLE_BREAKEVEN_SIGNALS maps both CLOSE and BREAKEVEN to BREAKEVEN)
         - userbot.forward_to_archive is awaited with the original message, channel title and the same group id
        """
        # The message text to test (should be interpreted as a "close" style message)
        signal_text = """
        Gold Sell now 3969-3973

        Sl : 3976

        TP1: 3963
        TP2:3955
        """
        message_text = (
            "GOLD SELL HIT TP 1☄️‼️\n\n"
            "👉👉+30pips hit!\n\n"
            "MOVE SL TO ENTRY AND SECURE SOME PROFITS 🫦 "
        )

        # Setup fake message and event
        mapped_gid = 12345
        chat_title = "TestChannel"

        fake_signal_message = FakeMessage(
            text=signal_text,
            msg_id=mapped_gid,
            is_reply=False,
        )
        signal_event = FakeEvent(
            fake_signal_message, chat_title=chat_title, chat_id=111
        )

        fake_close_message = FakeMessage(
            text=message_text,
            msg_id=67890,
            is_reply=False,
        )
        close_event = FakeEvent(fake_close_message, chat_title=chat_title, chat_id=111)

        # Patch process_signal and forward_to_archive to monitor calls
        with (
            patch.object(
                ub, "process_new_standard_signal", new_callable=AsyncMock
            ) as standard_signal_mock,
            patch.object(ub, "process_signal", new_callable=Mock) as proc_mock,
            patch.object(
                ub, "forward_to_archive", new_callable=AsyncMock
            ) as archive_mock,
            patch.object(
                ub, "find_latest_group_id_for_channel", new_callable=Mock
            ) as latest_gid_mock,
            patch.object(ub, "logger") as logger_mock,
        ):
            # Setup mocks
            standard_signal_mock.return_value = (
                mapped_gid  # First message creates group ID
            )
            proc_mock.return_value = True  # Second message processing succeeds
            latest_gid_mock.return_value = mapped_gid  # Latest group ID lookup succeeds

            # Process the first message (signal)
            asyncio.run(ub.handle_new_message(signal_event))

            # Verify first message was processed as standard signal
            self.assertTrue(
                standard_signal_mock.await_count >= 1,
                "process_new_standard_signal was not awaited for first message",
            )

            # Process the second message (close)
            asyncio.run(ub.handle_new_message(close_event))

            # Validate the arguments passed to process_signal for the close message
            called_args = proc_mock.call_args[0]  # positional args of the last call
            # First argument should be BREAKEVEN (CLOSE is remapped to BREAKEVEN)
            self.assertEqual(
                called_args[0],
                "BREAKEVEN",
                "process_signal was not called with BREAKEVEN signal type",
            )
            # Second argument should be the mapped group id
            self.assertEqual(
                called_args[1],
                mapped_gid,
                "process_signal was not called with the expected group id",
            )

            # Ensure forward_to_archive was awaited twice (once for each message)
            self.assertEqual(
                archive_mock.await_count,
                2,
                "forward_to_archive should be called twice (once for each message)",
            )

            # Check the second call to forward_to_archive (for the close message)
            second_call_args = archive_mock.call_args_list[1][0]
            self.assertIs(
                second_call_args[0],
                fake_close_message,
                "forward_to_archive did not receive the correct close message",
            )
            self.assertEqual(
                second_call_args[1],
                chat_title,
                "forward_to_archive did not receive the correct chat title",
            )
            self.assertEqual(
                second_call_args[2],
                mapped_gid,
                "forward_to_archive did not receive the correct group id",
            )


if __name__ == "__main__":
    unittest.main()
