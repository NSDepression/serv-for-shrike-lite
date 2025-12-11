`default_nettype none
// UART Bootloader for SERV on Renesas ForgeFPGA
//
// Protocol:
//   1. Wait for 4 sync bytes: 0x53, 0x45, 0x52, 0x56 ("SERV")
//   2. Receive 2 bytes: word count (little-endian, max 128 words = 512 bytes)
//   3. Receive program data (word_count * 4 bytes, little-endian words)
//   4. Assert boot_done when complete
//
// UART: 8N1 format, default 115200 baud @ 50MHz clock
//
module uart_bootloader #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD_RATE = 115200,
    parameter MAX_WORDS = 128
) (
    input wire clk,
    input wire rst,

    // UART interface
    input wire uart_rx,

    // BRAM write interface (directly to BRAM, not through Wishbone)
    output reg [8:0] boot_bram_addr,
    output reg [7:0] boot_bram_data,
    output reg boot_bram_wen,
    output reg boot_bram_wclken,

    // Status
    output reg boot_done,
    output reg boot_error
);

    // UART baud rate divider
    localparam BAUD_DIV = CLK_FREQ / BAUD_RATE;
    localparam BAUD_DIV_HALF = BAUD_DIV / 2;
    localparam BAUD_BITS = $clog2(BAUD_DIV);

    // UART receiver state
    reg [BAUD_BITS-1:0] baud_counter;
    reg [3:0] bit_counter;
    reg [7:0] rx_shift;
    reg [2:0] uart_state;
    reg rx_sync0, rx_sync1, rx_sync2;
    wire rx_bit = rx_sync2;

    localparam UART_IDLE = 3'd0;
    localparam UART_START = 3'd1;
    localparam UART_DATA = 3'd2;
    localparam UART_STOP = 3'd3;

    reg rx_valid;
    reg [7:0] rx_data;

    // Synchronize RX input
    always @(posedge clk) begin
        rx_sync0 <= uart_rx;
        rx_sync1 <= rx_sync0;
        rx_sync2 <= rx_sync1;
    end

    // UART RX state machine
    always @(posedge clk) begin
        if (rst) begin
            uart_state <= UART_IDLE;
            baud_counter <= 0;
            bit_counter <= 0;
            rx_shift <= 8'b0;
            rx_valid <= 1'b0;
            rx_data <= 8'b0;
        end else begin
            rx_valid <= 1'b0;

            case (uart_state)
                UART_IDLE: begin
                    if (~rx_bit) begin  // Start bit detected
                        uart_state <= UART_START;
                        baud_counter <= BAUD_DIV_HALF[BAUD_BITS-1:0];  // Sample in middle
                    end
                end

                UART_START: begin
                    if (baud_counter == 0) begin
                        if (~rx_bit) begin  // Verify start bit
                            uart_state <= UART_DATA;
                            baud_counter <= BAUD_DIV[BAUD_BITS-1:0] - 1;
                            bit_counter <= 0;
                        end else begin
                            uart_state <= UART_IDLE;  // False start
                        end
                    end else begin
                        baud_counter <= baud_counter - 1;
                    end
                end

                UART_DATA: begin
                    if (baud_counter == 0) begin
                        rx_shift <= {rx_bit, rx_shift[7:1]};  // LSB first
                        baud_counter <= BAUD_DIV[BAUD_BITS-1:0] - 1;
                        if (bit_counter == 7) begin
                            uart_state <= UART_STOP;
                        end else begin
                            bit_counter <= bit_counter + 1;
                        end
                    end else begin
                        baud_counter <= baud_counter - 1;
                    end
                end

                UART_STOP: begin
                    if (baud_counter == 0) begin
                        if (rx_bit) begin  // Valid stop bit
                            rx_valid <= 1'b1;
                            rx_data <= rx_shift;
                        end
                        uart_state <= UART_IDLE;
                    end else begin
                        baud_counter <= baud_counter - 1;
                    end
                end

                default: uart_state <= UART_IDLE;
            endcase
        end
    end

    // Bootloader state machine
    reg [3:0] boot_state;
    reg [15:0] word_count;
    reg [15:0] bytes_remaining;
    reg [1:0] byte_in_word;

    localparam BOOT_SYNC0 = 4'd0;   // Wait for 'S' (0x53)
    localparam BOOT_SYNC1 = 4'd1;   // Wait for 'E' (0x45)
    localparam BOOT_SYNC2 = 4'd2;   // Wait for 'R' (0x52)
    localparam BOOT_SYNC3 = 4'd3;   // Wait for 'V' (0x56)
    localparam BOOT_CNT_L = 4'd4;   // Word count low byte
    localparam BOOT_CNT_H = 4'd5;   // Word count high byte
    localparam BOOT_DATA  = 4'd6;   // Receiving program data
    localparam BOOT_WRITE = 4'd7;   // Writing byte to BRAM
    localparam BOOT_DONE  = 4'd8;   // Boot complete

    always @(posedge clk) begin
        if (rst) begin
            boot_state <= BOOT_SYNC0;
            boot_done <= 1'b0;
            boot_error <= 1'b0;
            boot_bram_addr <= 9'b0;
            boot_bram_data <= 8'b0;
            boot_bram_wen <= 1'b0;
            boot_bram_wclken <= 1'b0;
            word_count <= 16'b0;
            bytes_remaining <= 16'b0;
            byte_in_word <= 2'b0;
        end else begin
            // Default: disable BRAM write
            boot_bram_wen <= 1'b0;
            boot_bram_wclken <= 1'b0;

            case (boot_state)
                BOOT_SYNC0: begin
                    if (rx_valid) begin
                        if (rx_data == 8'h53) // 'S'
                            boot_state <= BOOT_SYNC1;
                        // Stay in SYNC0 if wrong byte
                    end
                end

                BOOT_SYNC1: begin
                    if (rx_valid) begin
                        if (rx_data == 8'h45) // 'E'
                            boot_state <= BOOT_SYNC2;
                        else if (rx_data == 8'h53) // 'S' - restart sync
                            boot_state <= BOOT_SYNC1;
                        else
                            boot_state <= BOOT_SYNC0;
                    end
                end

                BOOT_SYNC2: begin
                    if (rx_valid) begin
                        if (rx_data == 8'h52) // 'R'
                            boot_state <= BOOT_SYNC3;
                        else if (rx_data == 8'h53) // 'S' - restart sync
                            boot_state <= BOOT_SYNC1;
                        else
                            boot_state <= BOOT_SYNC0;
                    end
                end

                BOOT_SYNC3: begin
                    if (rx_valid) begin
                        if (rx_data == 8'h56) // 'V'
                            boot_state <= BOOT_CNT_L;
                        else if (rx_data == 8'h53) // 'S' - restart sync
                            boot_state <= BOOT_SYNC1;
                        else
                            boot_state <= BOOT_SYNC0;
                    end
                end

                BOOT_CNT_L: begin
                    if (rx_valid) begin
                        word_count[7:0] <= rx_data;
                        boot_state <= BOOT_CNT_H;
                    end
                end

                BOOT_CNT_H: begin
                    if (rx_valid) begin
                        word_count[15:8] <= rx_data;
                        // Validate word count
                        if ({rx_data, word_count[7:0]} == 0 || {rx_data, word_count[7:0]} > MAX_WORDS) begin
                            boot_error <= 1'b1;
                            boot_state <= BOOT_SYNC0;  // Reset and wait for valid transfer
                        end else begin
                            bytes_remaining <= {rx_data, word_count[7:0]} << 2;  // * 4
                            boot_bram_addr <= 9'b0;
                            byte_in_word <= 2'b0;
                            boot_state <= BOOT_DATA;
                        end
                    end
                end

                BOOT_DATA: begin
                    if (rx_valid) begin
                        boot_bram_data <= rx_data;
                        boot_state <= BOOT_WRITE;
                    end
                end

                BOOT_WRITE: begin
                    // Write byte to BRAM
                    boot_bram_wen <= 1'b1;
                    boot_bram_wclken <= 1'b1;

                    // Advance address and counters
                    boot_bram_addr <= boot_bram_addr + 1;
                    bytes_remaining <= bytes_remaining - 1;

                    if (bytes_remaining == 1) begin
                        boot_state <= BOOT_DONE;
                    end else begin
                        boot_state <= BOOT_DATA;
                    end
                end

                BOOT_DONE: begin
                    boot_done <= 1'b1;
                    // Stay in done state until reset
                end

                default: boot_state <= BOOT_SYNC0;
            endcase
        end
    end

endmodule
