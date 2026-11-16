// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: a PS/2 keyboard with two keys, F1 and F2, on the machine's keyboard lines
//
// Upstream's keyboard controller (KBCONV) talks to a PS/2 keyboard: at every reset it sends FF and waits
// for the keyboard's AA, then reads its ID and sets its LEDs, and only then passes keys on. With its
// lines resting high it waited for ever. This answers it as a keyboard does and sends F1 and F2 (set 2
// codes 05 and 06, F0 before a release), the one-player and two-player start of the games that read
// the keyboard for it.
//
// The lines are separate both ways, as the machine's PS2IF takes them: dev_clk/dev_dat are the
// keyboard's (pPs2Clkin/Datin), host_clk/host_dat the controller's (pPs2Clkout/Datout). Everything
// counts the machine's clock enable, so a byte under way stands still with the controller when the
// game is paused. A bit is 80 us. Keys wait until the controller has finished its setup and is back
// at rest (KBCONV waits 20 ms after each answer and drops a byte that comes in then), and keep 20 ms
// between bytes, so the program has read one code before the next comes in.

`default_nettype none

module pocket_kbd #(
    parameter integer HALF  = 400,       // half a bit, clock enables (10 MHz: 40 us)
    parameter integer QUIET = 300000,    // after an answer, before a key: 30 ms
    parameter integer GAP   = 200000     // between key bytes: 20 ms
) (
    input  wire       clk,
    input  wire       ce,
    input  wire       rst,               // the machine in reset
    input  wire [1:0] keys,              // {F2, F1} held
    input  wire       host_clk,
    input  wire       host_dat,
    output reg        dev_clk = 1'b1,
    output reg        dev_dat = 1'b1,
    output reg        ready = 1'b0       // the controller has set the keyboard up
);
    localparam [2:0] S_IDLE = 3'd0, S_SEND = 3'd1, S_RTS = 3'd2, S_RECV = 3'd3, S_WAIT = 3'd4;

    reg  [2:0]  st = S_IDLE;
    reg  [18:0] t = 19'd0;               // the quiet time before the next byte
    reg  [9:0]  ph = 10'd0;              // the time within a bit
    reg  [3:0]  n = 4'd0;                // bits done
    reg  [10:0] sh = 11'd0;              // a byte going out, start bit first
    reg  [7:0]  rx = 8'd0;
    reg  [23:0] q = 24'd0;               // up to three bytes to send, the first in [7:0]
    reg  [1:0]  qn = 2'd0;
    reg         arg = 1'b0;              // the next byte from the controller is a command's argument
    reg         led_arg = 1'b0;          // and that command was ED (LEDs), the last of the setup
    reg  [1:0]  told = 2'b00;            // the keys as the controller has them
    reg  [1:0]  brk = 2'b00;             // a release under way: F0 sent, the code next

    function [10:0] frame(input [7:0] b);
        frame = {1'b1, ~^b, b, 1'b0};
    endfunction

    // the code for key k
    function [7:0] code(input integer k);
        code = k ? 8'h06 : 8'h05;
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; dev_clk <= 1'b1; dev_dat <= 1'b1;
            q <= 24'd0; qn <= 2'd0; arg <= 1'b0; led_arg <= 1'b0;
            told <= 2'b00; brk <= 2'b00; ready <= 1'b0; t <= QUIET[18:0];
        end else if (ce) begin
            if (t != 0) t <= t - 19'd1;
            case (st)
            S_IDLE: begin
                dev_clk <= 1'b1; dev_dat <= 1'b1;
                if (!host_clk) begin
                    st <= S_RTS;                       // the controller wants to send, or holds us off
                end else if (qn != 0) begin
                    if (t == 0 || t < QUIET - 19'd2000) begin   // answers go after 200 us
                        sh <= frame(q[7:0]); q <= {8'd0, q[23:8]}; qn <= qn - 2'd1;
                        n <= 4'd0; ph <= 10'd0; st <= S_SEND;
                    end
                end else if (ready && t == 0) begin
                    // a key: a release goes F0, then its code; a press, its code
                    if (brk[0])                      begin sh <= frame(code(0)); brk[0] <= 1'b0; told[0] <= 1'b0; n <= 4'd0; ph <= 10'd0; st <= S_SEND; t <= GAP[18:0]; end
                    else if (brk[1])                 begin sh <= frame(code(1)); brk[1] <= 1'b0; told[1] <= 1'b0; n <= 4'd0; ph <= 10'd0; st <= S_SEND; t <= GAP[18:0]; end
                    else if (keys[0] && !told[0])    begin sh <= frame(code(0)); told[0] <= 1'b1; n <= 4'd0; ph <= 10'd0; st <= S_SEND; t <= GAP[18:0]; end
                    else if (keys[1] && !told[1])    begin sh <= frame(code(1)); told[1] <= 1'b1; n <= 4'd0; ph <= 10'd0; st <= S_SEND; t <= GAP[18:0]; end
                    else if (!keys[0] && told[0])    begin sh <= frame(8'hF0);   brk[0] <= 1'b1; n <= 4'd0; ph <= 10'd0; st <= S_SEND; t <= GAP[18:0]; end
                    else if (!keys[1] && told[1])    begin sh <= frame(8'hF0);   brk[1] <= 1'b1; n <= 4'd0; ph <= 10'd0; st <= S_SEND; t <= GAP[18:0]; end
                end
            end

            // Keyboard to controller: the data set half way through the clock's high time, the clock
            // low for half a bit (the controller takes the bit as it falls), then high again.
            S_SEND: begin
                ph <= ph + 10'd1;
                if (ph == HALF / 2) dev_dat <= sh[0];
                if (ph == HALF)     dev_clk <= 1'b0;
                if (ph == 2 * HALF - 1) begin
                    dev_clk <= 1'b1; ph <= 10'd0; sh <= {1'b1, sh[10:1]}; n <= n + 4'd1;
                    if (n == 4'd10) begin dev_dat <= 1'b1; st <= S_IDLE; end
                end
            end

            // Controller to keyboard: it holds the clock low, takes the data low and lets the clock go;
            // a clock held low with the data high is only holding the keyboard off.
            S_RTS: begin
                if (host_clk) begin
                    if (!host_dat) begin n <= 4'd0; ph <= 10'd0; st <= S_RECV; end
                    else st <= S_IDLE;
                end
            end

            // The keyboard clocks the controller's bits in: the controller sets each as the clock falls,
            // and it's taken as the clock rises. Bits 0-7, parity, stop, then the data held low through
            // an eleventh clock as the acknowledgement.
            S_RECV: begin
                ph <= ph + 10'd1;
                if (ph == HALF) dev_clk <= 1'b0;
                if (ph == 2 * HALF - 1) begin
                    dev_clk <= 1'b1; ph <= 10'd0; n <= n + 4'd1;
                    if (n < 4'd8)   rx <= {host_dat, rx[7:1]};
                    if (n == 4'd9)  dev_dat <= 1'b0;   // after the stop bit: the acknowledgement
                    if (n == 4'd10) begin dev_dat <= 1'b1; st <= S_WAIT; end
                end
            end

            // The byte, answered as a keyboard does.
            S_WAIT: begin
                st <= S_IDLE;
                t <= QUIET[18:0];
                if (arg) begin
                    q <= 24'h0000FA; qn <= 2'd1; arg <= 1'b0;
                    if (led_arg) ready <= 1'b1;
                    led_arg <= 1'b0;
                end else case (rx)
                8'hFF: begin q <= 24'h00AAFA; qn <= 2'd2; ready <= 1'b0; told <= 2'b00; brk <= 2'b00; end
                8'hF2: begin q <= 24'h83ABFA; qn <= 2'd3; end
                8'hED: begin q <= 24'h0000FA; qn <= 2'd1; arg <= 1'b1; led_arg <= 1'b1; end
                8'hF3: begin q <= 24'h0000FA; qn <= 2'd1; arg <= 1'b1; end
                8'hEE: begin q <= 24'h0000EE; qn <= 2'd1; end
                default: begin q <= 24'h0000FA; qn <= 2'd1; end
                endcase
            end

            default: st <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
