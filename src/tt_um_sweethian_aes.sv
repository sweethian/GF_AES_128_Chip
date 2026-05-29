/*
 * Copyright (c) 2026 MusangChip [Goh Swee Thian, Shahum Saeed]
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_sweethian_aes (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // Wire the dedicated inputs
  wire [7:0] serial_in = ui_in;
  wire shift_enable = uio_in[0];

  // Instantiate serial wrapper
  // Set NUM_SBOX to 1 for lowest possible area.
  // Increasing to 2 just increased utilization of TT by 2%
  // Increasing to 4 GDS task fails with unresolvable routing/time/placement violations
  // Maybe more tiles wil fix, but not worth the extra cost
  // Gonna do a one round flow just to see the stats
  // Final design LRSP with 2-Sbox, area 3*2
  AES_serial_wrapper #(
      .NUM_SBOX(2),
      .ONE_ROUND(0),
      .ROM(0)
  ) aes_wrapper_inst (
      .clk(clk),
      .rst_n(rst_n),
      .serial_in(serial_in),
      .shift_enable(shift_enable),
      .serial_out(uo_out[7:0]),
      .busy(uio_out[1]),
      .done(uio_out[2])
  );

  // Tie off the unused bidirectional outputs
  assign uio_out[0] = 1'b0;  // Input pin, output path is tied low
  assign uio_out[7:3] = 5'b0;  // Tie off unused upper pins to ground

  assign uio_oe = 8'b11111110;  // Set bidirectional pins (1=output)

endmodule
