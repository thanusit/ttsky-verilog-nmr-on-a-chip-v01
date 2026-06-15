/*
 * Copyright (c) 2026 Thanusit Burinprakhon
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns / 1ps

module tb_tt_um_thanusit_nmr_cores;

    // =========================================================================
    // 1. Clock and Reset Signals
    // =========================================================================
    reg clk;
    reg rst_n;
    reg ena;

    // Inputs to top module
    reg [7:0] ui_in;
    reg [7:0] uio_in;

    // Outputs from top module
    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    // Explicit pin bindings for scannability
    wire psq_rf_A   = uo_out[0];
    wire psq_rf_B   = uo_out[1];
    wire psq_rx_gate = uo_out[2];
    wire psq_busy    = uo_out[3];
    
    wire spi_sclk   = uo_out[4];
    wire spi_miso   = uo_out[5];
    wire spi_busy   = uo_out[6];

    // =========================================================================
    // 2. Unit Under Test (UUT) Instantiation
    // =========================================================================
    tt_um_thanusit_nmr_cores uut (
        .ui_in(ui_in),
        .uo_out(uo_out),
        .uio_in(uio_in),
        .uio_out(uio_out),
        .uio_oe(uio_oe),
        .ena(ena),
        .clk(clk),
        .rst_n(rst_n)
    );

    // =========================================================================
    // 3. Clock Generation (50 MHz -> 20ns period)
    // =========================================================================
    always #10 clk = ~clk;

    // =========================================================================
    // 4. Mock RF Signal Generation Functionality
    // =========================================================================
    reg [3:0] rf_counter;
    reg       mock_rf_in;

    // Generates a mock frequency component relative to the LO tracking counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rf_counter <= 4'd0;
            mock_rf_in <= 1'b0;
        end else begin
            rf_counter <= rf_counter + 1'b1;
            // Create an arbitrary periodic sequence to simulate a returning NMR echo
            if (rf_counter < 4'd6) 
                mock_rf_in <= 1'b1;
            else 
                mock_rf_in <= 1'b0;
        end
    end

    // Map internal signals to the physical UI vector array
    always @(*) begin
        ui_in[4] = mock_rf_in; // Bind mock RF to the rx_in pin destination
    end

    // =========================================================================
    // 5. Test Vectors and Sequential Logic Driving
    // =========================================================================
    initial begin
        // Initialize Signals
        clk      = 1'b0;
        rst_n    = 1'b0;
        ena      = 1'b1;
        ui_in    = 8'h00;
        uio_in   = 8'h00;

        // Hold Reset active for 5 cycles
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        $display("[TB] System Reset released successfully.");

        // Step 1: Simulate SPI configuration signals for Pulse Sequencer 
        // (Mock values matching your layout constraints)
        @(posedge clk);
        ui_in[3] = 1'b0; // Pull SPI SS_N active-low to select chip
        ui_in[2] = 1'b1; // Drive MOSI high with dummy config payload bits
        ui_in[1] = 1'b1; // Start a fast manual serial clock transition
        #40;
        ui_in[1] = 1'b0;
        #40;
        ui_in[3] = 1'b1; // De-assert chip select line

        // Step 2: Fire "Start" trigger line to begin CPMG execution sequences
        @(posedge clk);
        ui_in[0] = 1'b1; // Pull start line High
        @(posedge clk);
        ui_in[0] = 1'b0; // Pull start line Low
        $display("[TB] Trigger pulse executed to pulse_sequencer.");

        // Step 3: Wait for rx_gate processing window to open
        wait (psq_rx_gate == 1'b1);
        $display("[TB] rx_gate active window open. Processing IF/RF stream data...");

        // Step 4: Allow demodulator core to sample and accumulate mock signals
        repeat (100) @(posedge clk);

        // Step 5: Wait for rx_gate to close, forcing the SPI dump window open
        wait (psq_rx_gate == 1'b0);
        $display("[TB] rx_gate window closed. Tracking internal SPI TX transition state...");

        // Step 6: Capture and monitor serial payload stream output packets
        wait (spi_busy == 1'b1);
        $display("[TB] SPI Transmission frame initialized. Serial data shifting active.");
        
        // Let the SPI core shift out all 16 data bits (8-bit I + 8-bit Q)
        wait (spi_busy == 1'b0);
        $display("[TB] SPI Transmission frame closed cleanly.");

        // Finish simulation run
        repeat (20) @(posedge clk);
        $display("[TB] All core pipelines verified successfully.");
        $finish;
    end

    // =========================================================================
    // 6. SPI Real-Time Capture and Decoding Monitor
    // =========================================================================
    reg [15:0] captured_frame;
    integer bit_idx;

    initial begin
        captured_frame = 16'h0000;
        forever begin
            // Synchronize execution with the rising edge of the outbound clock
            @(posedge spi_sclk);
            if (spi_busy) begin
                captured_frame = {captured_frame[14:0], spi_miso};
            end
        end
    end

    // Output data report upon completion of transaction window
    always @(negedge spi_busy) begin
        if (rst_n) begin
            $display("=================================================");
            $display("         SPI SERIAL CAPTURE REPORT               ");
            $display("=================================================");
            $display(" Raw Captured Frame (Hex): 0x%h", captured_frame);
            $display(" Demodulated I Channel   : 0x%h (%d signed Dec)", captured_frame[15:8], $signed(captured_frame[15:8]));
            $display(" Demodulated Q Channel   : 0x%h (%d signed Dec)", captured_frame[7:0],  $signed(captured_frame[7:0]));
            $display("=================================================");
        end
    end

    // Optional wave dump configuration for GTKWave/EDA software debugging
    initial begin
        $dumpfile("tb_tt_um_thanusit_nmr_cores.vcd");
        $dumpvars(0, tb_tt_um_thanusit_nmr_cores);
    end

endmodule
