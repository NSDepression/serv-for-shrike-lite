"""
Example main.py for Shrike-Lite
Copy this to main.py on the RP2040 to auto-load a program on boot

The program will:
1. Flash the FPGA bitstream (using shrike library)
2. Load the RISC-V program to BRAM (using serv_loader)
3. SERV starts executing automatically
"""

import time

# First, flash the FPGA bitstream if shrike library is available
try:
    import shrike
    print("Flashing FPGA bitstream...")
    shrike.flash("servant.bin")  # Your SERV bitstream
    time.sleep_ms(100)  # Wait for FPGA to configure
except ImportError:
    print("Note: shrike library not found, assuming FPGA already programmed")
except Exception as e:
    print(f"Warning: Could not flash bitstream: {e}")

# Now load the RISC-V program
import serv_loader

print("Loading RISC-V program...")
if serv_loader.load("blinky.hex"):
    print("Success! SERV is running.")
else:
    print("Failed to load program!")

# Optional: You can add your own RP2040 code here
# The RP2040 and SERV can run in parallel!
print("RP2040 ready for additional tasks...")
