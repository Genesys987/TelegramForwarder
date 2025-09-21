# -*- coding: utf-8 -*-
"""
fxtm_tracker.py

Tracks FXTM dummy signals and handles the ready message -> real signal workflow.
"""
import os
import json
import logging
from typing import Optional

logger = logging.getLogger(__name__)

class FXTMTracker:
    """
    Tracks FXTM dummy signals for the ready message -> real signal workflow.
    """
    
    def __init__(self, tracking_file: str = "fxtm_tracking.json"):
        self.tracking_file = os.path.join(os.getcwd(), tracking_file)
        self.dummy_signals = {}  # channel_name -> group_id mapping
        self.load_tracking_data()
    
    def load_tracking_data(self):
        """Load tracking data from file."""
        try:
            if os.path.exists(self.tracking_file):
                with open(self.tracking_file, "r", encoding='utf-8') as f:
                    self.dummy_signals = json.load(f)
                logger.info(f"FXTM tracking data loaded: {len(self.dummy_signals)} entries")
            else:
                logger.info("No FXTM tracking file found, starting with empty tracking")
                self.dummy_signals = {}
        except Exception as e:
            logger.error(f"Error loading FXTM tracking data: {e}")
            self.dummy_signals = {}
    
    def save_tracking_data(self):
        """Save tracking data to file."""
        try:
            with open(self.tracking_file, "w", encoding='utf-8') as f:
                json.dump(self.dummy_signals, f, indent=2)
            logger.debug("FXTM tracking data saved")
        except Exception as e:
            logger.error(f"Error saving FXTM tracking data: {e}")
    
    def add_dummy_signal(self, channel_name: str, group_id: int):
        """
        Record that a dummy signal was created for the given channel.
        
        Args:
            channel_name: The channel name (e.g., "FXTM")
            group_id: The group ID of the dummy signal
        """
        self.dummy_signals[channel_name.upper()] = group_id
        self.save_tracking_data()
        logger.info(f"FXTM dummy signal tracked: {channel_name.upper()} -> GID:{group_id}")
    
    def get_dummy_gid(self, channel_name: str) -> Optional[int]:
        """
        Get the group ID of the last dummy signal for the given channel.
        
        Args:
            channel_name: The channel name (e.g., "FXTM")
            
        Returns:
            The group ID of the dummy signal, or None if no dummy signal exists
        """
        return self.dummy_signals.get(channel_name.upper())
    
    def remove_dummy_signal(self, channel_name: str) -> Optional[int]:
        """
        Remove and return the dummy signal GID for the given channel.
        This is called when the real signal arrives to replace the dummy.
        
        Args:
            channel_name: The channel name (e.g., "FXTM")
            
        Returns:
            The group ID of the removed dummy signal, or None if no dummy existed
        """
        removed_gid = self.dummy_signals.pop(channel_name.upper(), None)
        if removed_gid:
            self.save_tracking_data()
            logger.info(f"FXTM dummy signal removed: {channel_name.upper()} -> GID:{removed_gid}")
        return removed_gid
    
    def has_dummy_signal(self, channel_name: str) -> bool:
        """
        Check if there's an active dummy signal for the given channel.
        
        Args:
            channel_name: The channel name (e.g., "FXTM")
            
        Returns:
            True if there's an active dummy signal, False otherwise
        """
        return channel_name.upper() in self.dummy_signals

# Global instance
fxtm_tracker = FXTMTracker()