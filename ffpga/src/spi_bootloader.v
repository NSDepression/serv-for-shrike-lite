`default_nettype none
// SPI Bootloader for SERV on Shrike-Lite
//
// Uses the existing SPI connection from RP2040 to FPGA:
//   RP2040 Pin 3 → FPGA: SPI Clock (SCLK)
//   RP2040 Pin 1 → FPGA: Chip Select (SS, active low)
//   RP2040 Pin 5 → FPGA: MOSI (Master Out, Slave In)
//   RP2040 Pin 6 → FPGA: MISO (Master In, Slave Out)
//
// Protocol (RP2040 sends):
//   1. Assert SS low
//   2. Send command byte:
//      - 0x01: Start program load (resets address counter)
//      - 0x02: Write data byte (next byte is data)
//      - 0x03: End program load (releases SERV from reset)
//      - 0x04: Query status (FPGA sends back status byte)
//   3. For write: send data byte
//   4. Deassert SS high
//
// Status byte (returned on command 0x04):
//   - Bit 0: boot_done
//   - Bit 1: boot_error
//   - Bits 7:2: reserved
//
module spi_bootloader #(
    parameter MAX_BYTES = 512  // 128 words * 4 bytes
) (
    input wire clk,
    input wire rst,

    // SPI interface (directly from RP2040)
    input wire spi_sck,   // SPI clock from RP2040
    input wire spi_ss_n,  // Chip select (active low)
    input wire spi_mosi,  // Data from RP2040
    output reg spi_miso,  // Data to RP2040

    // BRAM write interface
    output reg [8:0] boot_bram_addr,
    output reg [7:0] boot_bram_data,
    output reg boot_bram_wen,
    output reg boot_bram_wclken,

    // Status
    output reg boot_done,
    output reg boot_error
);

    // SPI clock domain synchronization
    reg [2:0] sck_sync;
    reg [2:0] ss_sync;
    reg [2:0] mosi_sync;

    wire sck_rising;
    wire sck_falling;
    wire ss_active;
    wire mosi_bit;

    // Synchronize SPI signals to system clock
    always @(posedge clk) begin
        sck_sync <= {sck_sync[1:0], spi_sck};
        ss_sync <= {ss_sync[1:0], spi_ss_n};
        mosi_sync <= {mosi_sync[1:0], spi_mosi};
    end

    // Edge detection
    assign sck_rising = (sck_sync[2:1] == 2'b01);
    assign sck_falling = (sck_sync[2:1] == 2'b10);
    assign ss_active = ~ss_sync[2];
    assign mosi_bit = mosi_sync[2];

    // SPI receiver state
    reg [2:0] bit_count;
    reg [7:0] rx_shift;
    reg [7:0] rx_byte;
    reg rx_valid;

    // SPI transmitter state
    reg [7:0] tx_shift;
    reg [7:0] tx_byte;
    reg tx_load;

    // Command processing state
    reg [7:0] cmd_byte;
    reg cmd_valid;
    reg expect_data;

    // Commands
    localparam CMD_START = 8'h01;
    localparam CMD_WRITE = 8'h02;
    localparam CMD_END   = 8'h03;
    localparam CMD_STATUS = 8'h04;

    // SPI receive shift register (sample on rising edge)
    always @(posedge clk) begin
        if (rst || !ss_active) begin
            bit_count <= 3'd0;
            rx_shift <= 8'b0;
            rx_valid <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            if (sck_rising) begin
                rx_shift <= {rx_shift[6:0], mosi_bit};
                bit_count <= bit_count + 1;
                if (bit_count == 3'd7) begin
                    rx_valid <= 1'b1;
                    rx_byte <= {rx_shift[6:0], mosi_bit};
                end
            end
        end
    end

    // SPI transmit shift register (shift on falling edge)
    always @(posedge clk) begin
        if (rst || !ss_active) begin
            tx_shift <= 8'hFF;
            spi_miso <= 1'b1;
        end else begin
            if (tx_load) begin
                tx_shift <= tx_byte;
                spi_miso <= tx_byte[7];
            end else if (sck_falling) begin
                tx_shift <= {tx_shift[6:0], 1'b1};
                spi_miso <= tx_shift[6];
            end
        end
    end

    // Command processing and BRAM write
    always @(posedge clk) begin
        if (rst) begin
            boot_done <= 1'b0;
            boot_error <= 1'b0;
            boot_bram_addr <= 9'b0;
            boot_bram_data <= 8'b0;
            boot_bram_wen <= 1'b0;
            boot_bram_wclken <= 1'b0;
            cmd_byte <= 8'b0;
            cmd_valid <= 1'b0;
            expect_data <= 1'b0;
            tx_byte <= 8'hFF;
            tx_load <= 1'b0;
        end else begin
            // Default: disable BRAM write
            boot_bram_wen <= 1'b0;
            boot_bram_wclken <= 1'b0;
            tx_load <= 1'b0;

            if (rx_valid) begin
                if (expect_data) begin
                    // This is a data byte following CMD_WRITE
                    expect_data <= 1'b0;

                    if (boot_bram_addr < MAX_BYTES) begin
                        boot_bram_data <= rx_byte;
                        boot_bram_wen <= 1'b1;
                        boot_bram_wclken <= 1'b1;
                        boot_bram_addr <= boot_bram_addr + 1;
                    end else begin
                        boot_error <= 1'b1;  // Overflow
                    end
                end else begin
                    // This is a command byte
                    case (rx_byte)
                        CMD_START: begin
                            // Reset for new program load
                            boot_bram_addr <= 9'b0;
                            boot_done <= 1'b0;
                            boot_error <= 1'b0;
                        end

                        CMD_WRITE: begin
                            // Next byte will be data
                            expect_data <= 1'b1;
                        end

                        CMD_END: begin
                            // Program load complete
                            boot_done <= 1'b1;
                        end

                        CMD_STATUS: begin
                            // Send status byte back
                            tx_byte <= {6'b0, boot_error, boot_done};
                            tx_load <= 1'b1;
                        end

                        default: begin
                            // Unknown command - ignore
                        end
                    endcase
                end
            end
        end
    end

endmodule
