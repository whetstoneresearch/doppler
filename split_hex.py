#!/usr/bin/env python3

def split_hex_to_words(hex_input):
    """
    Split a hex string into 256-bit (32-byte) words.
    
    Args:
        hex_input: Hex string with or without 0x prefix
    
    Returns:
        List of 256-bit words as hex strings
    """
    # Remove 0x prefix if present
    if hex_input.startswith('0x'):
        hex_input = hex_input[2:]
    
    # Ensure even number of characters
    if len(hex_input) % 2:
        hex_input = '0' + hex_input
    
    # Each word is 64 hex characters (32 bytes = 256 bits)
    word_size = 64
    words = []
    
    # Split into words
    for i in range(0, len(hex_input), word_size):
        word = hex_input[i:i + word_size]
        # Pad last word if necessary
        if len(word) < word_size:
            word = word.ljust(word_size, '0')
        words.append('0x' + word)
    
    return words


def main():
    hex_input = input("Enter hex value (with or without 0x prefix): ").strip()
    
    if not hex_input:
        print("No input provided")
        return
    
    try:
        # Validate hex input
        test_hex = hex_input[2:] if hex_input.startswith('0x') else hex_input
        int(test_hex, 16)
    except ValueError:
        print("Invalid hex input")
        return
    
    words = split_hex_to_words(hex_input)
    
    print(f"\nSplit into {len(words)} 256-bit words:\n")
    for i, word in enumerate(words):
        print(f"{word}")


if __name__ == "__main__":
    main()