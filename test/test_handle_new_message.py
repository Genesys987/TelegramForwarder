"""
Unit test for userbot.handle_new_message - specifically verifies that a
"close" style message triggers processing as a CLOSE signal and that
the message is forwarded to the archive when processing succeeds.

This test creates a minimal fake event / message object with only the
attributes accessed by `handle_new_message`.
"""

import unittest
import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

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

    def test_close_signal_reply_forwards_and_processes(self):
        """
        Simulate a reply message that contains a 'close' instruction.
        Expectation:
         - userbot.process_signal is awaited with SignalType.CLOSE and the mapped group id
         - userbot.forward_to_archive is awaited with the original message, channel title and the same group id
        """
        # The message text to test (should be interpreted as a "close" style message)
        message_text = (
            "GOLD SELL HIT TP 1☄️‼️\n\n"
            "👉👉+30pips hit!\n\n"
            "MOVE SL TO ENTRY AND SECURE SOME PROFITS 🫦 "
        )

        # Setup fake message and event
        reply_to_msg_id = 12345
        mapped_gid = 67890
        chat_title = "TestChannel"
        msg_id = 54321

        # Add mapping for reply
        ub.message_id_to_group_id[reply_to_msg_id] = mapped_gid

        fake_message = FakeMessage(
            text=message_text,
            msg_id=msg_id,
            is_reply=True,
            reply_to_msg_id=reply_to_msg_id,
        )
        event = FakeEvent(fake_message, chat_title=chat_title, chat_id=111)

        # Patch process_signal and forward_to_archive to monitor calls
        with (
            patch.object(ub, "process_signal", new_callable=AsyncMock) as proc_mock,
            patch.object(
                ub, "forward_to_archive", new_callable=AsyncMock
            ) as archive_mock,
            patch.object(ub, "logger") as logger_mock,
        ):
            proc_mock.return_value = True  # Simulate successful processing

            asyncio.run(ub.handle_new_message(event))

            # Validate the arguments passed to process_signal
            called_args = proc_mock.call_args[0]  # positional args of the last call
            # First argument should be the CLOSE SignalType stored in module
            self.assertEqual(
                called_args[0],
                ub.SignalType.CLOSE,
                "process_signal was not called with CLOSE signal type",
            )
            # Second argument should be the mapped group id
            self.assertEqual(
                called_args[1],
                mapped_gid,
                "process_signal was not called with the expected group id",
            )

            # Ensure forward_to_archive was awaited
            self.assertTrue(
                archive_mock.await_count >= 1, "forward_to_archive was not awaited"
            )
            archive_args = archive_mock.call_args[0]
            self.assertIs(
                archive_args[0],
                fake_message,
                "forward_to_archive did not receive the correct message",
            )
            self.assertEqual(
                archive_args[1],
                chat_title,
                "forward_to_archive did not receive the correct chat title",
            )
            self.assertEqual(
                archive_args[2],
                mapped_gid,
                "forward_to_archive did not receive the correct group id",
            )


if __name__ == "__main__":
    unittest.main()
