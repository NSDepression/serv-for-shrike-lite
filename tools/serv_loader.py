#!/usr/bin/env python3
"""
SERV Bootloader - Load RISC-V programs to Shrike-Lite FPGA via UART

Protocol:
  1. Send sync bytes: "SERV" (0x53, 0x45, 0x52, 0x56)
  2. Send word count (2 bytes, little-endian)
  3. Send program data (word_count * 4 bytes, little-endian words)

Usage:
  python serv_loader.py <hex_file> [serial_port] [baud_rate]

Example:
  python serv_loader.py blinky.hex /dev/ttyUSB0 115200
"""

import sys
import time
import struct

def load_hex_file(filename):
    """Load a hex file and return list of 32-bit words"""
    words = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                # Parse hex value
                try:
                    word = int(line, 16)
                    words.append(word)
                except ValueError:
                    print(f"Warning: Skipping invalid line: {line}")
    return words

def create_boot_packet(words):
    """Create bootloader packet from program words"""
    packet = bytearray()

    # Sync bytes: "SERV"
    packet.extend(b'SERV')

    # Word count (2 bytes, little-endian)
    word_count = len(words)
    if word_count > 128:
        raise ValueError(f"Program too large: {word_count} words (max 128)")
    packet.extend(struct.pack('<H', word_count))

    # Program data (little-endian words)
    for word in words:
        packet.extend(struct.pack('<I', word))

    return packet

def load_program(port, baud, hex_file):
    """Load program to FPGA via UART"""
    try:
        import serial
    except ImportError:
        print("Error: pyserial not installed. Run: pip install pyserial")
        sys.exit(1)

    # Load hex file
    print(f"Loading {hex_file}...")
    words = load_hex_file(hex_file)
    print(f"  {len(words)} words ({len(words) * 4} bytes)")

    # Create boot packet
    packet = create_boot_packet(words)
    print(f"  Boot packet: {len(packet)} bytes")

    # Open serial port
    print(f"Opening {port} at {baud} baud...")
    ser = serial.Serial(port, baud, timeout=1)
    time.sleep(0.1)  # Let port settle

    # Send packet
    print("Sending program...")
    ser.write(packet)
    ser.flush()

    # Wait for transmission to complete
    time.sleep(len(packet) * 10 / baud + 0.1)

    ser.close()
    print("Done! SERV should now be running the program.")

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("\nAvailable arguments:")
        print("  hex_file    - Path to .hex file (required)")
        print("  serial_port - Serial port (default: /dev/ttyUSB0)")
        print("  baud_rate   - Baud rate (default: 115200)")
        sys.exit(1)

    hex_file = sys.argv[1]
    port = sys.argv[2] if len(sys.argv) > 2 else '/dev/ttyUSB0'
    baud = int(sys.argv[3]) if len(sys.argv) > 3 else 115200

    load_program(port, baud, hex_file)

if __name__ == '__main__':
    main()
