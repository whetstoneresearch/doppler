#!/usr/bin/env python3

import os
import re
import subprocess
import json
from pathlib import Path

def extract_events_from_file(filepath):
    """Extract event definitions from a Solidity file."""
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Regex to match event definitions (handles multi-line)
    # Matches: event EventName(params) with optional indexed keywords
    event_pattern = r'event\s+(\w+)\s*\((.*?)\)\s*;'
    events = re.findall(event_pattern, content, re.DOTALL | re.MULTILINE)
    
    parsed_events = []
    for name, params in events:
        # Clean up parameters (remove newlines, extra spaces, and 'indexed' keyword for signature)
        params_clean = re.sub(r'\s+', ' ', params.strip())
        # For the signature, we need to remove 'indexed' keywords
        params_for_sig = re.sub(r'\s*indexed\s*', ' ', params_clean)
        # Clean up extra spaces
        params_for_sig = re.sub(r'\s+', ' ', params_for_sig).strip()
        
        parsed_events.append({
            'name': name,
            'params': params_clean,  # Original params with indexed
            'signature': f"{name}({params_for_sig})"
        })
    
    return parsed_events

def calculate_event_hash(event_signature):
    """Use cast to calculate the event hash (topic 0)."""
    try:
        result = subprocess.run(
            ['cast', 'sig-event', event_signature],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return None

def main():
    print("Finding all events in Solidity contracts and calculating topic 0 hashes...")
    print("=" * 80)
    print()
    
    # Find all .sol files in src directory
    src_dir = Path('src')
    sol_files = sorted(src_dir.rglob('*.sol'))
    
    all_events = []
    
    for sol_file in sol_files:
        events = extract_events_from_file(sol_file)
        
        if events:
            print(f"File: {sol_file}")
            print("-" * 40)
            
            for event in events:
                # Calculate hash
                hash_value = calculate_event_hash(event['signature'])
                
                if hash_value:
                    print(f"  Event: {event['name']}({event['params']})")
                    print(f"  Signature: {event['signature']}")
                    print(f"  Topic0: {hash_value}")
                    
                    all_events.append({
                        'file': str(sol_file),
                        'name': event['name'],
                        'params': event['params'],
                        'signature': event['signature'],
                        'topic0': hash_value
                    })
                else:
                    print(f"  Event: {event['name']}({event['params']})")
                    print(f"  Signature: {event['signature']}")
                    print(f"  Topic0: [Error calculating hash]")
                
                print()
            
            print()
    
    # Save results to JSON file
    output_file = 'event-hashes.json'
    with open(output_file, 'w') as f:
        json.dump(all_events, f, indent=2)
    
    print("=" * 80)
    print(f"Event hash calculation complete!")
    print(f"Results saved to: {output_file}")
    print(f"Total events found: {len(all_events)}")

if __name__ == "__main__":
    main()