#!/usr/bin/env python3
"""
SERV Program Loader for Shrike-Lite (Host-side)

This script sends RISC-V programs to the Shrike-Lite board via USB.
The RP2040 on the board receives the program and loads it into the FPGA's BRAM.

Usage:
  python serv_loader.py <hex_file> [serial_port]

Example (macOS):
  python serv_loader.py blinky.hex /dev/tty.usbmodem*

Example (Linux):
  python serv_loader.py blinky.hex /dev/ttyACM0

Requirements:
  pip install pyserial

The hex file format is simple: one 32-bit hex value per line
Example:
  40000537
  00050513
  ...
"""

import sys
import time
import glob

def find_serial_port():
    """Auto-detect Shrike-Lite serial port"""
    # Common patterns for RP2040 on different OSes
    patterns = [
        '/dev/tty.usbmodem*',      # macOS
        '/dev/ttyACM*',            # Linux
        '/dev/ttyUSB*',            # Linux (some boards)
        'COM*',                     # Windows
    ]

    for pattern in patterns:
        ports = glob.glob(pattern)
        if ports:
            return ports[0]

    return None

def load_hex_file(filename):
    """Load a hex file and return list of 32-bit words"""
    words = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and not line.startswith('//'):
                try:
                    word = int(line, 16)
                    words.append(word)
                except ValueError:
                    print(f"Warning: Skipping invalid line: {line}")
    return words

def load_via_repl(port, hex_file):
    """Load program via MicroPython REPL on RP2040"""
    try:
        import serial
    except ImportError:
        print("Error: pyserial not installed. Run: pip install pyserial")
        sys.exit(1)

    # Load hex file
    print(f"Loading {hex_file}...")
    words = load_hex_file(hex_file)
    if not words:
        print("Error: No valid data in hex file")
        sys.exit(1)
    print(f"  {len(words)} words ({len(words) * 4} bytes)")

    # Open serial port to RP2040 REPL
    print(f"Connecting to {port}...")
    try:
        ser = serial.Serial(port, 115200, timeout=2)
    except serial.SerialException as e:
        print(f"Error: Could not open {port}: {e}")
        sys.exit(1)

    time.sleep(0.5)  # Let port settle

    # Enter raw REPL mode for reliable command execution
    ser.write(b'\x03')  # Ctrl+C to interrupt any running program
    time.sleep(0.1)
    ser.write(b'\x03')  # Ctrl+C again
    time.sleep(0.1)
    ser.read(ser.in_waiting)  # Clear buffer

    # Enter raw REPL mode
    ser.write(b'\x01')  # Ctrl+A
    time.sleep(0.1)
    response = ser.read(ser.in_waiting)

    print("  Sending program to RP2040...")

    # Build the MicroPython commands
    commands = [
        "import serv_loader",
        "loader = serv_loader.ServLoader()",
        "loader._send_cmd(0x01)",  # CMD_START
        "import time",
        "time.sleep_ms(1)",
    ]

    # Add write commands for each byte
    for word in words:
        # Little-endian: LSB first
        for shift in [0, 8, 16, 24]:
            byte_val = (word >> shift) & 0xFF
            commands.append(f"loader._send_cmd_data(0x02, {byte_val})")

    # End loading
    commands.append("loader._send_cmd(0x03)")  # CMD_END
    commands.append("time.sleep_ms(1)")
    commands.append("status = loader._get_status()")
    commands.append("print('STATUS:', status)")

    # Send commands in raw REPL mode
    code = '\n'.join(commands)
    ser.write(code.encode() + b'\x04')  # Ctrl+D to execute

    # Wait for execution
    time.sleep(0.5 + len(words) * 0.01)  # Rough estimate

    # Read response
    response = ser.read(ser.in_waiting).decode('utf-8', errors='ignore')

    # Exit raw REPL
    ser.write(b'\x02')  # Ctrl+B
    time.sleep(0.1)

    ser.close()

    # Check for success
    if 'STATUS:' in response:
        # Extract status
        for line in response.split('\n'):
            if 'STATUS:' in line:
                print(f"  {line.strip()}")
        print("Done! SERV should now be running.")
        return True
    elif 'Error' in response or 'Traceback' in response:
        print(f"Error from RP2040:\n{response}")
        return False
    else:
        print("  Program sent (could not verify status)")
        print("Done! SERV should now be running.")
        return True

def copy_to_rp2040(port, hex_file):
    """Alternative: Copy hex file to RP2040 filesystem"""
    print("\nAlternative method: Copy files to RP2040")
    print("=" * 50)
    print("1. Connect to RP2040 using Thonny IDE or ampy")
    print(f"2. Copy {hex_file} to the RP2040")
    print("3. Copy rp2040/serv_loader.py to the RP2040")
    print("4. In REPL, run:")
    print(f"   >>> import serv_loader")
    print(f"   >>> serv_loader.load('{hex_file}')")

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("\nUsage: python serv_loader.py <hex_file> [serial_port]")
        print("\nExamples:")
        print("  python serv_loader.py blinky.hex")
        print("  python serv_loader.py blinky.hex /dev/tty.usbmodem14101")
        sys.exit(1)

    hex_file = sys.argv[1]

    # Find or use specified port
    if len(sys.argv) > 2:
        port = sys.argv[2]
    else:
        port = find_serial_port()
        if not port:
            print("Error: Could not auto-detect serial port")
            print("Please specify the port manually:")
            print("  python serv_loader.py blinky.hex /dev/tty.usbmodemXXXX")
            sys.exit(1)
        print(f"Auto-detected port: {port}")

    # Try to load via REPL
    try:
        load_via_repl(port, hex_file)
    except Exception as e:
        print(f"Error: {e}")
        print("\nIf the direct method fails, try the manual method:")
        copy_to_rp2040(port, hex_file)

if __name__ == '__main__':
    main()
