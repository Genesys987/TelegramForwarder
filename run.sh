#!/bin/bash

if [ "$#" -gt 0 ]; then
    pipenv run python main.py $1
    exit 0
fi

mapfile -t env_files < <(find . -maxdepth 1 -name ".env*" ! -name ".env.example")

# Keep track of PIDs
pids=()

echo "Starting Python scripts..."
echo "Environment files found: ${env_files[@]}"

# Start each script in the background
for e in "${env_files[@]}"; do
    pipenv run python main.py $e &
    # Store PID
    pids+=($!)
done

echo "Process IDs: ${pids[@]}"

# Function to kill all started processes
cleanup() {
    echo "Stopping all Python scripts..."
    for pid in "${pids[@]}"; do
        kill -SIGTERM "$pid" 2>/dev/null || true
    done
    # Wait for them to exit
    wait
    exit 0
}

# Trap Ctrl‑C (SIGINT) and also SIGTERM
trap cleanup SIGINT SIGTERM

# Wait for all background jobs to finish
wait
