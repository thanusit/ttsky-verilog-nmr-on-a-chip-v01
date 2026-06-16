/*
 * Copyright (c) 2026 Thanusit Burinprakhon
 * SPDX-License-Identifier: Apache-2.0
 */


`timescale 1ns / 1ps
`default_nettype none

module tb;

    // -------------------------------------------------------------------------
    // Testbench Wire and Register Declarations
    // -------------------------------------------------------------------------
    reg [7:0] ui_in;
    reg [7:0] uio_in;
    reg       ena;
    reg       clk;
    reg       rst_n;

    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

   // Dedicated Output Port Aliases (uo_out)
    wire rf_pulse_A   = uo_out[0];
    wire rf_pulse_B   = uo_out[1];
    wire rx_gate      = uo_out[2];
    wire status_busy  = uo_out[3];
    wire spi_out_sclk = uo_out[4];
    wire spi_out_miso = uo_out[5];
    wire spi_out_busy = uo_out[6];

    // -------------------------------------------------------------------------
    // Device Under Test (DUT) Instantiation
    // -------------------------------------------------------------------------
    tt_um_thanusit_nmr_cores user_project (
        .ui_in(ui_in),
        .uo_out(uo_out),
        .uio_in(uio_in),
        .uio_out(uio_out),
        .uio_oe(uio_oe),
        .ena(ena),
        .clk(clk),
        .rst_n(rst_n)
    );

    // -------------------------------------------------------------------------
    // Clock Generation (20 MHz System Clock -> 50ns cycle period)
    // -------------------------------------------------------------------------
    always begin
        #25 clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // Hardware Simulation Control Tasks
    // -------------------------------------------------------------------------
    
    // Task: System-Wide Active-Low Reset Initialization
    task reset_system;
     begin
        $display("[TB] Asserting Master Reset Vector...");
        rst_n = 1'b0;
        ui_in  = 8'h08; // Set spi_ss_n = 1 (inactive), all others 0
        uio_in = 8'h00;
        #(100);
        @(posedge clk);
        #1 rst_n = 1'b1;
        $display("[TB] Master Reset Released Successfully.");
     end
    endtask

    // Task: Streams full 128-bit pulse sequence config register array
    task configure_sequencer(
        input [31:0] tA,
        input [31:0] t_tau,
        input [31:0] tB,
        input [31:0] e_count
    );
        reg [127:0] config_vector;
        integer i;
        begin
            config_vector = {tA, t_tau, tB, e_count};
            $display("[TB] Loading 128-bit Sequencer Matrix Configuration...");
            $display("     tA=%0d, tau=%0d, tB=%0d, e_count=%0d", tA, t_tau, tB, e_count);
            
            // Drop Select Line Active (ui_in[3] = spi_ss_n)
            #1 ui_in[3] = 1'b0; 
            #(100);
            
            for (i = 127; i >= 0; i = i - 1) begin
                ui_in[2] = config_vector[i]; // Drive spi_mosi (ui_in[2])
                ui_in[1] = 1'b0;             // spi_sclk Low   (ui_in[1])
                #(100);
                ui_in[1] = 1'b1;             // spi_sclk High  (Capture edge)
                #(100);
            end
            
            ui_in[1] = 1'b0; // Clean clock line state
            #(100);
            ui_in[3] = 1'b1; // Pull spi_ss_n High to execute parallel latch transfer
            #(200);          
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Stimulus Pipeline Block
    // -------------------------------------------------------------------------
    initial begin
        // Setup waveform tracking output files for GTKWave/ModelSim
        $dumpfile("tb.vcd");
        $dumpvars(0, tb);

        // Establish safe power-on initial hardware vector
        clk    = 1'b0;
        rst_n  = 1'b1;
        ena    = 1'b1; 
        ui_in  = 8'h00; // Set spi_ss_n high initially
        uio_in = 8'h00;

       // Step 1: System Boot and Power Reset execution
        #(100);
        reset_system();
        #(100);

        // Step 2: Push 128-bit sequence limits to internal configuration registers
        // Params: tA=6 cycles, tau=35 cycles, tB=12 cycles, echo_count=2 loops
        configure_sequencer(32'd6, 32'd35, 32'd12, 32'd2);

        // Step 3: Trigger the Sequence Engine via Start Input Pin
        $display("[TB] Asserting Pulse Sequencer Start Signal...");
        @(posedge clk);
        #1 ui_in[0] = 1'b1; // Drive start high (ui_in[0])
        @(posedge clk);
        #1 ui_in[0] = 1'b0; // De-assert start line

        // Step 4: Run loop simulation tracking the window logic processing
        $display("[TB] Monitoring CPMG Sequence Execution Phase...");
        
        // Dynamic wait block runs based on the loaded loop parameter count
        repeat (2) begin
            // Wait for rx_gate to turn high
            wait(rx_gate == 1'b1); 
            $display("[TB] rx_gate opened. Processing high-frequency digitized data on rx_in (ui_in[4])...");
            
            // Stream raw alternating 1-bit input waves while gate is held high by sequencer
            while (rx_gate == 1'b1) begin
                @(posedge clk);
                #1 ui_in[4] = ~ui_in[4]; // Toggle simulated rx_in bit
            end
            $display("[TB] rx_gate closed.");
        end

        // Step 5: Catch the falling-edge logic shift to watch the SPI data offload
        $display("[TB] Sequence completed. Waiting for falling edge SPI TX push trigger...");
        
        // Track the rising busy activity flag output pin from the spi_tx core
        wait(spi_out_busy == 1'b1);
        $display("[TB] SPI TX Host Bus Busy. Streaming 16-bit payload (8-bit I + 8-bit Q).");

        // Actively dump bits to testbench terminal window logs while streaming
        while (spi_out_busy == 1'b1) begin
            @(posedge spi_out_sclk);
            $display("Time=%0t ns | Host SCLK Pulse Edge | MISO Bit Stream = %b", $time, spi_out_miso);
        end
        
        $display("[TB] SPI TX Channel Released. Data transfer pipeline concluded.");

        // Clear run-time cooling off zone
        #(2000); 

        // Terminate active environment simulation frame
        $display("[TB] System verification complete without runtime hangs.");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Concurrent Hardware Signal Monitoring Terminal
    // -------------------------------------------------------------------------
    initial begin
        $monitor("Time=%0t ns | Reset=%b | RF_A=%b | RF_B=%b | RX_Gate=%b | SPI_Busy=%b | SCLK=%b | MISO=%b", 
                 $time, rst_n, rf_pulse_A, rf_pulse_B, rx_gate, spi_out_busy, spi_out_sclk, spi_out_miso);
    end

endmodule
