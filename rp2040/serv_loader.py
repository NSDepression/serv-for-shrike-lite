"""
SERV Program Loader for Shrike-Lite
MicroPython script for RP2040 to load RISC-V programs to FPGA via SPI

Usage:
    1. Copy this file and your .hex program to the RP2040
    2. In REPL: import serv_loader
    3. serv_loader.load("blinky.hex")

Or set as main.py to auto-load on boot:
    import serv_loader
    serv_loader.load("program.hex")

SPI Protocol:
    CMD_START  (0x01): Reset address counter, prepare for load
    CMD_WRITE  (0x02): Write data byte (followed by data byte)
    CMD_END    (0x03): Finish loading, release SERV from reset
    CMD_STATUS (0x04): Query status (returns status byte)
"""

from machine import Pin, SPI
import time

# SPI pins for FPGA connection on Shrike-Lite
# From Shrike-Lite pinout: https://vicharak-in.github.io/shrike-lite/shrike_pinouts.html
# FPGA PIN 3 (GPIO12) ↔ RP2040 GPIO 2 = SCK
# FPGA PIN 4 (GPIO13) ↔ RP2040 GPIO 1 = SS
# FPGA PIN 5 (GPIO14) ↔ RP2040 GPIO 3 = MOSI
# FPGA PIN 18 (GPIO5) ↔ RP2040 GPIO 14 = MISO
SPI_SCK_PIN = 2    # GP2 - SPI Clock
SPI_MOSI_PIN = 3   # GP3 - Master Out Slave In
SPI_MISO_PIN = 14  # GP14 - Master In Slave Out (directly from FPGA GPIO5)
SPI_CS_PIN = 1     # GP1 - Chip Select

# Commands
CMD_START = 0x01
CMD_WRITE = 0x02
CMD_END = 0x03
CMD_STATUS = 0x04

class ServLoader:
    def __init__(self):
        # Initialize SPI
        # Using SPI0, but with custom pins via PIO would be more flexible
        # For now, use bitbang SPI for maximum compatibility
        self.sck = Pin(SPI_SCK_PIN, Pin.OUT, value=0)
        self.mosi = Pin(SPI_MOSI_PIN, Pin.OUT, value=0)
        self.miso = Pin(SPI_MISO_PIN, Pin.IN)
        self.cs = Pin(SPI_CS_PIN, Pin.OUT, value=1)  # Active low, start high

    def _spi_transfer(self, data):
        """Transfer one byte over SPI, return received byte"""
        result = 0
        for i in range(8):
            # Set MOSI
            self.mosi.value((data >> (7-i)) & 1)
            # Clock high
            self.sck.value(1)
            # Read MISO
            result = (result << 1) | self.miso.value()
            # Clock low
            self.sck.value(0)
        return result

    def _send_cmd(self, cmd):
        """Send a command byte"""
        self.cs.value(0)
        time.sleep_us(10)
        self._spi_transfer(cmd)
        time.sleep_us(10)
        self.cs.value(1)
        time.sleep_us(10)

    def _send_cmd_data(self, cmd, data):
        """Send a command followed by data byte"""
        self.cs.value(0)
        time.sleep_us(10)
        self._spi_transfer(cmd)
        self._spi_transfer(data)
        time.sleep_us(10)
        self.cs.value(1)
        time.sleep_us(10)

    def _get_status(self):
        """Query bootloader status"""
        self.cs.value(0)
        time.sleep_us(10)
        self._spi_transfer(CMD_STATUS)
        status = self._spi_transfer(0xFF)  # Dummy byte to clock out response
        time.sleep_us(10)
        self.cs.value(1)
        return status

    def load_hex(self, filename):
        """Load a hex file to FPGA BRAM"""
        print(f"Loading {filename}...")

        # Read hex file
        words = []
        try:
            with open(filename, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        try:
                            word = int(line, 16)
                            words.append(word)
                        except ValueError:
                            pass
        except OSError as e:
            print(f"Error reading file: {e}")
            return False

        if not words:
            print("No valid data found in hex file")
            return False

        print(f"  {len(words)} words ({len(words) * 4} bytes)")

        # Start loading
        print("  Sending to FPGA...")
        self._send_cmd(CMD_START)
        time.sleep_ms(1)

        # Send each word as 4 bytes (little-endian)
        byte_count = 0
        for word in words:
            # Little-endian: LSB first
            self._send_cmd_data(CMD_WRITE, word & 0xFF)
            self._send_cmd_data(CMD_WRITE, (word >> 8) & 0xFF)
            self._send_cmd_data(CMD_WRITE, (word >> 16) & 0xFF)
            self._send_cmd_data(CMD_WRITE, (word >> 24) & 0xFF)
            byte_count += 4

            # Progress indicator
            if byte_count % 64 == 0:
                print(".", end="")

        print()  # Newline after progress dots

        # End loading - this releases SERV from reset
        self._send_cmd(CMD_END)
        time.sleep_ms(1)

        # Check status
        status = self._get_status()
        boot_done = status & 0x01
        boot_error = (status >> 1) & 0x01

        if boot_error:
            print("  ERROR: Boot error flag set!")
            return False

        if boot_done:
            print(f"  Done! Loaded {byte_count} bytes")
            print("  SERV is now running!")
            return True
        else:
            print("  WARNING: boot_done not set")
            return False

    def reset(self):
        """Reset the bootloader (does not reload program)"""
        self._send_cmd(CMD_START)
        print("Bootloader reset - SERV is held in reset")
        print("Load a program to start SERV")

    def status(self):
        """Print current bootloader status"""
        status = self._get_status()
        boot_done = status & 0x01
        boot_error = (status >> 1) & 0x01
        print(f"Status: 0x{status:02X}")
        print(f"  boot_done:  {boot_done}")
        print(f"  boot_error: {boot_error}")


# Global loader instance
_loader = None

def _get_loader():
    global _loader
    if _loader is None:
        _loader = ServLoader()
    return _loader

def load(filename):
    """Load a hex file to the FPGA"""
    return _get_loader().load_hex(filename)

def reset():
    """Reset the bootloader"""
    _get_loader().reset()

def status():
    """Check bootloader status"""
    _get_loader().status()


# If run directly, show usage
if __name__ == "__main__":
    print(__doc__)
    print("\nQuick start:")
    print("  import serv_loader")
    print("  serv_loader.load('blinky.hex')")
