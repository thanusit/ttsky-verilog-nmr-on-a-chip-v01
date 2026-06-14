/*
 * Copyright (c) 2026 Thanusit Burinprakhon
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_thanusit_cpmg_pulse_sequencer (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // Unused bidirectionals assigned safely to zero inputs
    assign uio_out = 8'b00000000;
    assign uio_oe  = 8'b00000000;
    assign uo_out[7:4] = 4'b0000;

    // Pin Connections
    wire start    = ui_in[0];
    wire spi_sclk = ui_in[1];
    wire spi_mosi = ui_in[2];
    wire spi_ss_n = ui_in[3];

    reg rf_pulse_A;
    reg rf_pulse_B;
    reg rx_gate;
    reg status_busy;

    assign uo_out[0] = rf_pulse_A;
    assign uo_out[1] = rf_pulse_B;
    assign uo_out[2] = rx_gate;
    assign uo_out[3] = status_busy;

    // --- SPI CONFIGURATION STORAGE REGISTERS ---
    // Total 128 bits shifted via SPI (MSB first)
    // Structure: [32-bit cfg_tA] [32-bit tau] [32-bit cfg_tB] [32-bit cfg_echo_count]
    reg [127:0] spi_shift_reg;
    reg [31:0]  cfg_tA;
    reg [31:0]  tau;
    reg [31:0]  cfg_tB;
    reg [31:0]  cfg_echo_count;

    // SPI Slave capture path
    always @(posedge spi_sclk or negedge rst_n) begin
        if (!rst_n) begin
            spi_shift_reg <= 128'd0;
        end else if (!spi_ss_n) begin
            spi_shift_reg <= {spi_shift_reg[126:0], spi_mosi};
        end
    end

    // Parallel load on rising edge of SS_N (End of transaction)
    always @(posedge spi_ss_n or negedge rst_n) begin
        if (!rst_n) begin
            cfg_tA          <= 32'd10;   // Default fallback safe variables
            tau             <= 32'd50;
            cfg_tB          <= 32'd20;
            cfg_echo_count  <= 32'd4;
        end else begin
            cfg_tA          <= spi_shift_reg[127:96];
            tau             <= spi_shift_reg[95:64];
            cfg_tB          <= spi_shift_reg[63:32];
            cfg_echo_count  <= spi_shift_reg[31:0];
        end
    end

    // --- SEQUENCER FINITE STATE MACHINE ---
    localparam STATE_IDLE       = 3'd0,
               STATE_PULSE_A    = 3'd1,
               STATE_TAU_1      = 3'd2,
               STATE_PULSE_B    = 3'd3,
               STATE_TAU_2      = 3'd4;

    reg [2:0]  current_state, next_state;
    reg [31:0] time_counter;
    reg [31:0] echo_counter;

    // State Transitions
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= STATE_IDLE;
        end else begin
            current_state <= next_state;
        end
    end

    // Next State & Timer Logic
    always @(*) begin
        next_state = current_state;
        case (current_state)
            STATE_IDLE: begin
                if (start) next_state = STATE_PULSE_A;
            end
            STATE_PULSE_A: begin
                if (time_counter >= (cfg_tA - 1)) next_state = STATE_TAU_1;
            end
            STATE_TAU_1: begin
                if (time_counter >= (tau - 1)) next_state = STATE_PULSE_B;
            end
            STATE_PULSE_B: begin
                if (time_counter >= (cfg_tB - 1)) next_state = STATE_TAU_2;
            end
            STATE_TAU_2: begin
                if (time_counter >= (tau - 1)) begin
                    if (echo_counter >= (cfg_echo_count - 1))
                        next_state = STATE_IDLE;
                    else
                        next_state = STATE_TAU_1; // Loop back for next 180 block
                end
            end
            default: next_state = STATE_IDLE;
        endcase
    end

    // Counter Control
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            time_counter <= 32'd0;
            echo_counter <= 32'd0;
        end else begin
            if (current_state == STATE_IDLE) begin
                time_counter <= 32'd0;
                echo_counter <= 32'd0;
            end else if (current_state != next_state) begin
                time_counter <= 32'd0; // Reset timer on every state jump
                if (current_state == STATE_TAU_2) begin
                    echo_counter <= echo_counter + 1;
                end
            end else begin
                time_counter <= time_counter + 1;
            end
        end
    end

    // Output Mapping Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rf_pulse_A  <= 1'b0;
            rf_pulse_B  <= 1'b0;
            rx_gate     <= 1'b0;
            status_busy <= 1'b0;
        end else begin
            case (current_state)
                STATE_IDLE: begin
                    rf_pulse_A  <= 1'b0;
                    rf_pulse_B  <= 1'b0;
                    rx_gate     <= 1'b0;
                    status_busy <= 1'b0;
                end
                STATE_PULSE_A: begin
                    rf_pulse_A  <= 1'b1;
                    rf_pulse_B  <= 1'b0;
                    rx_gate     <= 1'b0;
                    status_busy <= 1'b1;
                end
                STATE_TAU_1: begin
                    rf_pulse_A  <= 1'b0;
                    rf_pulse_B  <= 1'b0;
                    rx_gate     <= 1'b0;
                    status_busy <= 1'b1;
                end
                STATE_PULSE_B: begin
                    rf_pulse_A  <= 1'b0;
                    rf_pulse_B  <= 1'b1;
                    rx_gate     <= 1'b0;
                    status_busy <= 1'b1;
                end
                STATE_TAU_2: begin
                    rf_pulse_A  <= 1'b0;
                    rf_pulse_B  <= 1'b0;
                    rx_gate     <= 1'b1; // RX acquisition open window during eco echo center
                    status_busy <= 1'b1;
                end
            endcase
        end
    end

endmodule
