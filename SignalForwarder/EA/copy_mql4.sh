#!/bin/bash

# Copies all MQL4 files from the current directory to the Experts directory of the MT4 installation specified in the .env file.

# Load environment variables from .env file
ENV_FILE="../forwarder/.env"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo "Loaded environment variables from $ENV_FILE"
else
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

# Check if MT4_FOLDERS is set
if [ -z "$MT4_FOLDERS" ]; then
    echo "Error: MT4_FOLDERS not found in .env file"
    exit 1
fi

# Split MT4_FOLDERS by comma and process each folder
IFS=',' read -ra FOLDERS <<< "$MT4_FOLDERS"

for FOLDER in "${FOLDERS[@]}"; do
    # Trim whitespace
    FOLDER=$(echo "$FOLDER" | xargs)
    
    # Check if directory exists
    if [ ! -d "$FOLDER" ]; then
        echo "Warning: MT4 folder does not exist: $FOLDER"
        continue
    fi
    
    # Create Experts directory if it doesn't exist
    EXPERTS_DIR="$FOLDER/MQL4/Experts"
    mkdir -p "$EXPERTS_DIR"
    
    # Find and copy all MQL4 files to Experts directory
    echo "Copying MQL4 files to $EXPERTS_DIR"
    find . -name "*.mq4" -exec cp {} "$EXPERTS_DIR/" \;
    
    if [ $? -eq 0 ]; then
        echo "Successfully copied MQL4 files to $EXPERTS_DIR"
    else
        echo "Error: Failed to copy MQL4 files to $EXPERTS_DIR"
    fi
done
