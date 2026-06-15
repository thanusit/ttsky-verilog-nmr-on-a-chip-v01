/*
 * Copyright (c) 2026 Thanusit Burinprakhon
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_thanusit_nmr_cores (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high)
    input  wire       ena,      // always 1 when design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // Internal wires connecting the sub-module outputs
    wire psq_rf_A;
    wire psq_rf_B;
    wire psq_rx_gate;
    wire psq_busy;
    
    wire [7:0] demod_i;
    wire [7:0] demod_q;
    
    wire spi_out_sclk;
    wire spi_out_miso;
    wire spi_out_busy;

    // Edge detector to trigger SPI transmission when rx_gate closes
    reg rx_gate_d;
    wire tx_trigger = (rx_gate_d && !psq_rx_gate);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_gate_d <= 1'b0;
        else         rx_gate_d <= psq_rx_gate;
    end

    // 1. Instantiate Pulse Sequencer
    pulse_sequencer psq_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(ui_in[0]),
        .spi_sclk(ui_in[1]),
        .spi_mosi(ui_in[2]),
        .spi_ss_n(ui_in[3]),
        .rf_pulse_A(psq_rf_A),   
        .rf_pulse_B(psq_rf_B),   
        .rx_gate(psq_rx_gate),   
        .status_busy(psq_busy)
    );

    // 2. Instantiate Quadrature Demodulator (Full 8-bit core resolution)
    quadrature_demodulator demod_inst (
        .clk(clk),
        .rst_n(rst_n),
        .rx_gate(psq_rx_gate),   
        .rx_in(ui_in[4]),        // 1-Bit Digitized Input RF connection
        .i_out(demod_i),
        .q_out(demod_q)
    );

    // 3. Instantiate SPI Serial Stream Core
    spi_tx spi_tx_inst (
        .clk(clk),
        .rst_n(rst_n),
        .trig_load(tx_trigger), // Trigger serial readout when processing block shuts
        .data_i(demod_i),       // Raw 8-bit precision component
        .data_q(demod_q),       // Raw 8-bit precision component
        .spi_sclk(spi_out_sclk),
        .spi_miso(spi_out_miso),
        .spi_busy(spi_out_busy)
    );

    // Bind physical dedicated outputs 
    assign uo_out[0] = psq_rf_A;
    assign uo_out[1] = psq_rf_B;
    assign uo_out[2] = psq_rx_gate;
    assign uo_out[3] = psq_busy;
    
    // Assign Serial Outputs to dedicated pin lines
    assign uo_out[4] = spi_out_sclk; // Outgoing clock for your DAQ host
    assign uo_out[5] = spi_out_miso; // Serial data output stream (16 bits)
    assign uo_out[6] = spi_out_busy; // High while data transmission is active
    assign uo_out[7] = 1'b0;         // Unused pin tied low

    // Tie off remaining Bidirectional I/O pins cleanly
    assign uio_out = 8'b00000000;
    assign uio_oe  = 8'b00000000; // Configured completely as inputs to avoid contention

endmodule
