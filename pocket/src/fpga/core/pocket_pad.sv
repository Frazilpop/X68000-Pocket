// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: a Pocket's keys as one of the machine's joystick port wirings
//
// Upstream's table (its X68000.sv) for the kinds this core offers. j is {R, L, Y, X, Select, Run, B,
// A, up, down, left, right}, active high; joy is what the port reads, active low. The pads with more
// buttons than wires answer the machine's strobe, str, with their second half.

`default_nettype none

module pocket_pad (
    input  wire        clk,
    input  wire [1:0]  kind,      // 0 two buttons, 1 Mega Drive 3, 2 Capcom 6, 3 Magical 6
    input  wire [11:0] j,
    input  wire        str,
    output reg  [5:0]  joy
);
    wire [5:0] two  = ~{j[5:4], j[0] | j[6], j[1] | j[6], j[2] | j[7], j[3] | j[7]};
    wire [5:0] md_0 = ~{j[6], j[4], 1'b1, 1'b1, j[2], j[3]};
    wire [5:0] md_1 = ~{j[9], j[5], j[0], j[1], j[2], j[3]};
    wire [5:0] cap0 = ~{j[5], j[4], j[0], j[1], j[2], j[3]};
    wire [5:0] cap1 = ~{j[6], j[10], j[7], j[8], j[9], j[11]};
    wire [5:0] mag0 = ~{j[9], j[8], j[0], j[1], j[2], j[3]};
    wire [5:0] mag1 = ~{j[5], j[4], j[10], j[11], 1'b1, 1'b1};

    always @(posedge clk) begin
        case (kind)
        2'd1:    joy <= str ? md_1 : md_0;
        2'd2:    joy <= str ? cap1 : cap0;
        2'd3:    joy <= str ? mag1 : mag0;
        default: joy <= two;
        endcase
    end
endmodule

`default_nettype wire
