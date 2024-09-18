import sys
import re
import json
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.patches as patches
import numpy as np

output = sys.stdin.read()

match = re.search(r'Logs:\s*(\{.*?\})(?:\n|$)', output, re.DOTALL)
if match:
    json_str = match.group(1)
else:
    print("No JSON data found in the Forge test output.")
    sys.exit(1)

try:
    data = json.loads(json_str)
except json.JSONDecodeError as e:
    print(f"Error parsing JSON: {e}")
    sys.exit(1)

slugs = data.get('data', [])
if not slugs:
    print("No slug data found in the JSON.")
    sys.exit(1)

df = pd.DataFrame(slugs)

df['liquidity'] = df['liquidity'] / 1e18

fig, ax = plt.subplots(figsize=(10, 6))

max_liquidity = df['liquidity'].max()
max_tick = df['tickUpper'].max()
min_tick = df['tickLower'].min()

slug_colors = {
    'lowerSlug': 'blue',
    'upperSlug': 'red',
    'pdSlug': 'green'
}

for index, row in df.iterrows():
    tick_lower = row['tickLower']
    tick_upper = row['tickUpper']
    liquidity = row['liquidity']
    slug_name = row['slugName']

    width = tick_upper - tick_lower
    height = np.log(liquidity) if liquidity > 0 else 0

    color = "gray" 

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

current_tick = (df['tickLower'].mean() + df['tickUpper'].mean()) / 2
ax.axvline(current_tick, color='dodgerblue', linestyle="--", label='Current Tick')

ax.set_xlim(min_tick - 1000, max_tick + 1000)
ax.set_ylim(0, np.log(max_liquidity) * 1.1 if max_liquidity > 0 else 1)

ax.set_xlabel('Ticks')
ax.set_ylabel('Log Liquidity')
ax.set_title('Liquidity Positions (Slugs)')

handles, labels = ax.get_legend_handles_labels()
unique_labels = dict(zip(labels, handles))
ax.legend(unique_labels.values(), unique_labels.keys())

ax.grid(True)

plt.show()
