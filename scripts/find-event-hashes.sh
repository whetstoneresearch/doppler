#!/bin/bash

# Script to find all events in Solidity contracts and calculate their topic 0 hashes

echo "Finding all events in Solidity contracts and calculating topic 0 hashes..."
echo "=================================================================="
echo

# Find all .sol files in src directory and subdirectories
find src -name "*.sol" -type f | sort | while read -r file; do
    # Extract events from the file using grep
    # Pattern matches: event EventName(params...);
    events=$(grep -E '^\s*event\s+[A-Za-z][A-Za-z0-9_]*\s*\(' "$file" | sed 's/^\s*//')
    
    if [ -n "$events" ]; then
        echo "File: $file"
        echo "----------------------------------------"
        
        # Process each event
        while IFS= read -r event_line; do
            # Clean up the event line
            event_cleaned=$(echo "$event_line" | sed 's/;//' | sed 's/^\s*event\s*//')
            
            # Extract just the event signature (name + params)
            # This handles multi-line events by taking everything up to the semicolon
            event_sig=$(echo "$event_cleaned" | sed 's/\s*$//')
            
            if [ -n "$event_sig" ]; then
                # Calculate the hash using cast
                hash=$(cast sig-event "$event_sig" 2>/dev/null)
                
                if [ $? -eq 0 ] && [ -n "$hash" ]; then
                    echo "  Event: $event_sig"
                    echo "  Topic0: $hash"
                    echo
                else
                    echo "  Event: $event_sig"
                    echo "  Topic0: [Error calculating hash]"
                    echo
                fi
            fi
        done <<< "$events"
        
        echo
    fi
done

echo "=================================================================="
echo "Event hash calculation complete!"