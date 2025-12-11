`default_nettype none
`define BRAM_IMPL
// Renesas ForgeFPGA BRAM interface
// BRAM has 8-bit data interface, 9-bit address (512 bytes per port)
// We need 32-bit access for SERV, so we perform 4 sequential byte accesses
// With byte addressing: address[1:0] selects byte within 32-bit word
//                       address[8:2] selects which 32-bit word (128 words max)
module servant_ram
  #(//Memory parameters
    parameter depth = 128,
    parameter aw    = $clog2(depth),
    parameter RESET_STRATEGY = "",
    parameter memfile = "")
   (
`ifdef BRAM_IMPL
   // bram ports
   	output [1:0] BRAM0_RATIO,
  	output reg [7:0] BRAM0_DATA_IN,
  	output reg BRAM0_WEN,
  	output reg BRAM0_WCLKEN,
  	output reg [8:0] BRAM0_WRITE_ADDR,
  	input [7:0] BRAM0_DATA_OUT,
  	output reg BRAM0_REN,
  	output reg BRAM0_RCLKEN,
  	output reg [8:0] BRAM0_READ_ADDR,
`endif
  	//
   input wire 		i_wb_clk,
    input wire 		i_wb_rst,
    input wire [aw-1:2] i_wb_adr,
    input wire [31:0] 	i_wb_dat,
    input wire [3:0] 	i_wb_sel,
    input wire 		i_wb_we,
    input wire 		i_wb_cyc,
    output reg [31:0] 	o_wb_rdt,
    output reg 		o_wb_ack);

`ifdef BRAM_IMPL
    // BRAM RATIO: 00=8bit, 01=16bit, 10=32bit, 11=64bit internal organization
    // We use byte-addressing with 8-bit interface
    assign BRAM0_RATIO = 2'b00; // 8-bit mode for byte access

    // State machine for sequential byte access
    // States: IDLE(0), BYTE0(1), BYTE1(2), BYTE2(3), BYTE3(4), DONE(5)
    reg [2:0] state;
    reg [31:0] write_data_reg;
    reg [31:0] read_data_reg;
    reg [3:0] sel_reg;
    reg we_reg;
    reg [aw-1:2] adr_reg;

    localparam S_IDLE  = 3'd0;
    localparam S_BYTE0 = 3'd1;
    localparam S_BYTE1 = 3'd2;
    localparam S_BYTE2 = 3'd3;
    localparam S_BYTE3 = 3'd4;
    localparam S_DONE  = 3'd5;

    // Byte address = {word_addr[6:0], byte_sel[1:0]}
    wire [8:0] byte_addr_0 = {adr_reg[aw-1:2], 2'b00};
    wire [8:0] byte_addr_1 = {adr_reg[aw-1:2], 2'b01};
    wire [8:0] byte_addr_2 = {adr_reg[aw-1:2], 2'b10};
    wire [8:0] byte_addr_3 = {adr_reg[aw-1:2], 2'b11};

    always @(posedge i_wb_clk) begin
        if (i_wb_rst) begin
            state <= S_IDLE;
            o_wb_ack <= 1'b0;
            BRAM0_WEN <= 1'b0;
            BRAM0_WCLKEN <= 1'b0;
            BRAM0_REN <= 1'b0;
            BRAM0_RCLKEN <= 1'b0;
            read_data_reg <= 32'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    o_wb_ack <= 1'b0;
                    if (i_wb_cyc) begin
                        // Capture transaction parameters
                        adr_reg <= i_wb_adr;
                        write_data_reg <= i_wb_dat;
                        sel_reg <= i_wb_sel;
                        we_reg <= i_wb_we;
                        state <= S_BYTE0;

                        // Start first byte access
                        BRAM0_READ_ADDR <= {i_wb_adr[aw-1:2], 2'b00};
                        BRAM0_WRITE_ADDR <= {i_wb_adr[aw-1:2], 2'b00};
                        BRAM0_DATA_IN <= i_wb_dat[7:0];
                        BRAM0_WEN <= i_wb_we & i_wb_sel[0];
                        BRAM0_WCLKEN <= i_wb_we & i_wb_sel[0];
                        BRAM0_REN <= ~i_wb_we;
                        BRAM0_RCLKEN <= ~i_wb_we;
                    end else begin
                        BRAM0_WEN <= 1'b0;
                        BRAM0_WCLKEN <= 1'b0;
                        BRAM0_REN <= 1'b0;
                        BRAM0_RCLKEN <= 1'b0;
                    end
                end

                S_BYTE0: begin
                    // Capture byte 0 read data, setup byte 1
                    if (~we_reg) read_data_reg[7:0] <= BRAM0_DATA_OUT;
                    BRAM0_READ_ADDR <= byte_addr_1;
                    BRAM0_WRITE_ADDR <= byte_addr_1;
                    BRAM0_DATA_IN <= write_data_reg[15:8];
                    BRAM0_WEN <= we_reg & sel_reg[1];
                    BRAM0_WCLKEN <= we_reg & sel_reg[1];
                    BRAM0_REN <= ~we_reg;
                    BRAM0_RCLKEN <= ~we_reg;
                    state <= S_BYTE1;
                end

                S_BYTE1: begin
                    // Capture byte 1 read data, setup byte 2
                    if (~we_reg) read_data_reg[15:8] <= BRAM0_DATA_OUT;
                    BRAM0_READ_ADDR <= byte_addr_2;
                    BRAM0_WRITE_ADDR <= byte_addr_2;
                    BRAM0_DATA_IN <= write_data_reg[23:16];
                    BRAM0_WEN <= we_reg & sel_reg[2];
                    BRAM0_WCLKEN <= we_reg & sel_reg[2];
                    BRAM0_REN <= ~we_reg;
                    BRAM0_RCLKEN <= ~we_reg;
                    state <= S_BYTE2;
                end

                S_BYTE2: begin
                    // Capture byte 2 read data, setup byte 3
                    if (~we_reg) read_data_reg[23:16] <= BRAM0_DATA_OUT;
                    BRAM0_READ_ADDR <= byte_addr_3;
                    BRAM0_WRITE_ADDR <= byte_addr_3;
                    BRAM0_DATA_IN <= write_data_reg[31:24];
                    BRAM0_WEN <= we_reg & sel_reg[3];
                    BRAM0_WCLKEN <= we_reg & sel_reg[3];
                    BRAM0_REN <= ~we_reg;
                    BRAM0_RCLKEN <= ~we_reg;
                    state <= S_BYTE3;
                end

                S_BYTE3: begin
                    // Capture byte 3 read data, complete transaction
                    if (~we_reg) read_data_reg[31:24] <= BRAM0_DATA_OUT;
                    BRAM0_WEN <= 1'b0;
                    BRAM0_WCLKEN <= 1'b0;
                    BRAM0_REN <= 1'b0;
                    BRAM0_RCLKEN <= 1'b0;
                    state <= S_DONE;
                end

                S_DONE: begin
                    // Output read data and acknowledge
                    o_wb_rdt <= read_data_reg;
                    o_wb_ack <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
`else
   // No BRAM implementation

   wire [3:0] 		we = {4{i_wb_we & i_wb_cyc}} & i_wb_sel;

   reg [31:0] 		mem [0:depth/4-1] /* verilator public */;

   wire [aw-3:0] 	addr = i_wb_adr[aw-1:2];

   always @(posedge i_wb_clk)
     if (i_wb_rst & (RESET_STRATEGY != "NONE"))
       o_wb_ack <= 1'b0;
     else
       o_wb_ack <= i_wb_cyc & !o_wb_ack;

	// reg [31:0] data_in;
	// always @(posedge i_wb_clk) begin
 //      if(we[0]) begin data_in[7:0] <= i_wb_dat[7:0]; end
 //      if(we[1]) begin data_in[15:8]  <= i_wb_dat[15:8]; end
 //      if(we[2]) begin data_in[23:16] <= i_wb_dat[23:16]; end
 //      if(we[3]) begin data_in[31:24] <= i_wb_dat[31:24]; end
 //      o_wb_rdt <= mem[addr];
	// end

   always @(posedge i_wb_clk) begin
      if(we[0]) begin mem[addr][7:0]   <= i_wb_dat[7:0]; end
      if(we[1]) begin mem[addr][15:8]  <= i_wb_dat[15:8]; end
      if(we[2]) begin mem[addr][23:16] <= i_wb_dat[23:16]; end
      if(we[3]) begin mem[addr][31:24] <= i_wb_dat[31:24]; end
      o_wb_rdt <= mem[addr];
   end
`endif
//    initial
//      if(|memfile) begin
// `ifndef ISE
// `ifndef CCGM
// 	$display("Preloading %m from %s", memfile);
// `endif
// `endif
// 	$readmemh(memfile, mem);
//      end

endmodule
