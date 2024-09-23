import sys
import re
import json
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.patches as patches
import numpy as np

# Read the Forge test output from stdin
output = sys.stdin.read()

# Split the output into lines
lines = output.splitlines()

# Find the index of the line that contains 'Logs:'
logs_index = None
for idx, line in enumerate(lines):
    if 'Logs:' in line:
        logs_index = idx
        break

if logs_index is None:
    print("No logs found in the Forge test output.")
    sys.exit(1)

# Collect all JSON lines after 'Logs:'
json_lines = []
for line in lines[logs_index+1:]:
    # Match lines that start with optional whitespace and a '{', and end with a '}'
    if re.match(r'\s*\{.*\}\s*$', line):
        json_lines.append(line.strip())
    else:
        # Stop collecting if the line doesn't match a JSON object
        break

if not json_lines:
    print("No JSON data found in the Forge test output.")
    sys.exit(1)

for i, json_str in enumerate(json_lines):
    try:
        data = json.loads(json_str)
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON: {e}")
        continue  # Skip this instance if JSON is invalid

    slugs = data.get('data', [])
    if not slugs:
        print("No slug data found in the JSON.")
        continue  # Skip if no slug data

    df = pd.DataFrame(slugs)

    # Convert liquidity to a more readable scale
    df['liquidity'] = df['liquidity'] / 1e18

    # Extract timestamp for naming and labeling
    timestamp = df['timestamp'].iloc[0] if 'timestamp' in df.columns else None

    current_tick = df['currentTick'].iloc[0] if 'currentTick' in df.columns else None

    fig, ax = plt.subplots(figsize=(10, 6))

    max_liquidity = df['liquidity'].max()
    max_tick = df['tickUpper'].max()
    min_tick = df['tickLower'].min()

    for index, row in df.iterrows():
        tick_lower = row['tickLower']
        tick_upper = row['tickUpper']
        liquidity = row['liquidity']
        slug_name = row['slugName']

        width = tick_upper - tick_lower
        height = np.log(liquidity) if liquidity > 0 else 0

        rect = patches.Rectangle(
            (tick_lower, 0),
            width,
            height,
            linewidth=1,
            edgecolor='black',
            facecolor='none',
            label=slug_name
        )
        ax.add_patch(rect)

        ax.text(
            tick_lower + width / 2,
            height + 0.1,
            slug_name,
            ha='center',
            va='bottom',
            fontsize=8
        )

    ax.axvline(current_tick, color='dodgerblue', linestyle="--", label='Current Tick')

    ax.set_xlim(min_tick - 1000, max_tick + 1000)
    ax.set_ylim(0, np.log(max_liquidity) * 1.1 if max_liquidity > 0 else 1)

    ax.set_xlabel('Ticks')
    ax.set_ylabel('Log Liquidity')
    if timestamp is not None:
        ax.set_title(f'Liquidity Positions (Slugs) at Timestamp {timestamp}')
    else:
        ax.set_title('Liquidity Positions (Slugs)')

    handles, labels = ax.get_legend_handles_labels()
    unique_labels = dict(zip(labels, handles))
    ax.legend(unique_labels.values(), unique_labels.keys())

    ax.grid(True)

    # Save the figure with a unique filename
    if timestamp is not None:
        plt.savefig(f"slug_plot_{timestamp}.png")
    else:
        plt.savefig(f"slug_plot_{i}.png")
    plt.close()

print("Charts have been generated and saved.")
