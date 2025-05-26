#!/bin/bash

# Copies all MQL4 files from the current directory to the Experts directory of the MT4 installation specified in the .env file.

# Load environment variables from .env file
if [ -f "../forwarder/.env" ]; then
    export $(grep -v '^#' ../forwarder/.env | xargs)
else
    echo "Error: .env file not found at ../forwarder/.env"
    exit 1
fi

# Check if MT4_FOLDER is set
if [ -z "$MT4_FOLDER" ]; then
    echo "Error: MT4_FOLDER not found in .env file"
    exit 1
fi

# Check if MT4_FOLDER directory exists
if [ ! -d "$MT4_FOLDER" ]; then
    echo "Error: MT4_FOLDER directory does not exist: $MT4_FOLDER"
    exit 1
fi

# Create Experts directory if it doesn't exist
EXPERTS_DIR="$MT4_FOLDER/MQL4/Experts"
mkdir -p "$EXPERTS_DIR"

# Find and copy all MQL4 files to Experts directory
echo "Copying MQL4 files to $EXPERTS_DIR"
find . -name "*.mq4" -exec cp {} "$EXPERTS_DIR/" \;

if [ $? -eq 0 ]; then
    echo "Successfully copied MQL4 files to Experts directory"
else
    echo "Error: Failed to copy MQL4 files"
    exit 1
fi
