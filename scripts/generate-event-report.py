#!/usr/bin/env python3

import json
from pathlib import Path
from collections import defaultdict

def main():
    # Load the event hashes
    with open('event-hashes.json', 'r') as f:
        events = json.load(f)
    
    # Group events by contract
    events_by_contract = defaultdict(list)
    for event in events:
        contract_name = Path(event['file']).stem
        events_by_contract[contract_name].append(event)
    
    # Generate markdown report
    report = []
    report.append("# Doppler Protocol Event Reference")
    report.append("\n## Summary")
    report.append(f"- Total Events: {len(events)}")
    report.append(f"- Total Contracts: {len(events_by_contract)}")
    
    report.append("\n## Events by Contract")
    
    for contract_name in sorted(events_by_contract.keys()):
        contract_events = events_by_contract[contract_name]
        report.append(f"\n### {contract_name}")
        report.append(f"File: `{contract_events[0]['file']}`\n")
        
        report.append("| Event | Signature | Topic0 |")
        report.append("|-------|-----------|--------|")
        
        for event in contract_events:
            event_name = event['name']
            params = event['params']
            topic0 = event['topic0']
            
            # Truncate long signatures for readability
            sig = event['signature']
            if len(sig) > 50:
                sig = sig[:47] + "..."
            
            report.append(f"| {event_name} | `{sig}` | `{topic0}` |")
    
    # Write report
    with open('event-reference.md', 'w') as f:
        f.write('\n'.join(report))
    
    print("Event reference generated: event-reference.md")

if __name__ == "__main__":
    main()