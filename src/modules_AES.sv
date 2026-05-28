// verilog_lint: waive-start module-filename

module key_expansion (
    input logic [3:0] round_count,  // Round 0 to 10
    input logic [31:0] sub_word,  // Use outside sub_word module inst
    output logic [31:0] rot_word,

    input  logic [127:0] in,
    output logic [127:0] out
);

  localparam int NumBits = 8;
  logic [31:0] w0, w1, w2, w3;
  logic [31:0] nw0, nw1, nw2, nw3;
  logic [31:0] rcon_word;

  always_comb begin
    unique case (round_count)
      4'd1: rcon_word = 32'h01000000;
      4'd2: rcon_word = 32'h02000000;
      4'd3: rcon_word = 32'h04000000;
      4'd4: rcon_word = 32'h08000000;
      4'd5: rcon_word = 32'h10000000;
      4'd6: rcon_word = 32'h20000000;
      4'd7: rcon_word = 32'h40000000;
      4'd8: rcon_word = 32'h80000000;
      4'd9: rcon_word = 32'h1b000000;
      4'd10: rcon_word = 32'h36000000;
      default: rcon_word = 32'h00000000;
    endcase
  end

  assign {w0, w1, w2, w3} = in;
  assign rot_word = {w3[23:0], w3[31:24]};

  assign nw0 = w0 ^ sub_word ^ rcon_word;
  assign nw1 = w1 ^ nw0;
  assign nw2 = w2 ^ nw1;
  assign nw3 = w3 ^ nw2;

  // always_comb begin
  //   if (!round_count) begin
  //     out = in;
  //   end
  //   else begin
  //     out = {nw0, nw1, nw2, nw3};
  //   end
  // end

  assign out = {nw0, nw1, nw2, nw3};

endmodule

// // Purely combinational
// module shift_rows (
//     input  logic [127:0] in,
//     output logic [127:0] out
// );
//   // Index = col * NUM_ROWS + row (Column major indexing)
//   localparam int NumRows = 4, NumCols = 4, NumBits = 8;

//   // Helper functions, yeah I know seems excessive, but it felt more elegant than hardcoding
//   function automatic logic [NumBits-1:0] get_byte(input logic [127:0] state, input int row,
//                                                   input int col);
//     get_byte = state[127-NumBits*(NumRows*col+row)-:NumBits];
//   endfunction

//   function automatic void set_byte(inout logic [127:0] state, input int row, input int col,
//                                    input logic [NumBits-1:0] value);
//     state[127-NumBits*(NumRows*col+row)-:NumBits] = value;
//   endfunction
//   // End of Helper functions

//   always_comb begin
//     out = '0;

//     for (int row = 0; row < NumRows; row++) begin
//       for (int col = 0; col < NumCols; col++) begin
//         set_byte(out, row, col, get_byte(in, row, (col + row) % NumCols));
//       end
//     end
//   end
// endmodule

module shift_rows (
    input  logic [127:0] in,
    output logic [127:0] out
);
  // Index = col * NUM_ROWS + row (Column major indexing)
  localparam int NumRows = 4, NumCols = 4, NumBits = 8;

  // Helper: read a byte (function is fine -- all inputs, returns a value)
  function automatic logic [NumBits-1:0] get_byte(input logic [127:0] state, input int row,
                                                  input int col);
    get_byte = state[127-NumBits*(NumRows*col+row)-:NumBits];
  endfunction

  // Helper: write a byte. MUST be a task, not a function -- functions cannot
  // have inout/output args in Verilog (Icarus enforces this strictly).
  task automatic set_byte(inout logic [127:0] state, input int row, input int col,
                          input logic [NumBits-1:0] value);
    state[127-NumBits*(NumRows*col+row)-:NumBits] = value;
  endtask

  always_comb begin
    out = '0;
    for (int row = 0; row < NumRows; row++) begin
      for (int col = 0; col < NumCols; col++) begin
        set_byte(out, row, col, get_byte(in, row, (col + row) % NumCols));
      end
    end
  end
endmodule

// Width can be only in multiples of 32 and max is 128
// default width parallelizes with four instance of mix_column_one_col
// If you do not want this decrease the width and handle it in the top module
module mix_columns #(
    parameter int WIDTH = 128
) (
    input  logic [WIDTH-1:0] in,
    output logic [WIDTH-1:0] out
);

  localparam int WordSize = 32;
  localparam int NumCol = WIDTH / WordSize;
  genvar col;

  generate
    for (col = 0; col < NumCol; col++) begin : g_MIX_COL
      mix_columns_one_col u_mix_col (
          .col_in (in[(WIDTH-1)-WordSize*col-:WordSize]),
          .col_out(out[(WIDTH-1)-WordSize*col-:WordSize])
      );
    end
  endgenerate

endmodule

module mix_columns_one_col (  //The Galois Field Matrix Multiplication
    input  logic [31:0] col_in,
    output logic [31:0] col_out
);

  logic [7:0] s0, s1, s2, s3;
  logic [7:0] x0, x1, x2, x3;
  logic [7:0] m0, m1, m2, m3;

  assign {s0, s1, s2, s3} = col_in;

  assign x0 = xtime(s0);
  assign x1 = xtime(s1);
  assign x2 = xtime(s2);
  assign x3 = xtime(s3);

  assign m0 = x0 ^ (x1 ^ s1) ^ s2 ^ s3;
  assign m1 = s0 ^ x1 ^ (x2 ^ s2) ^ s3;
  assign m2 = s0 ^ s1 ^ x2 ^ (x3 ^ s3);
  assign m3 = (x0 ^ s0) ^ s1 ^ s2 ^ x3;

  assign col_out = {m0, m1, m2, m3};

  function automatic logic [7:0] xtime(input logic [7:0] b);
    xtime = {b[6:0], 1'b0} ^ (8'h1b & {8{b[7]}});
  endfunction

endmodule

// This is probably the most resource intensive part
// default params instantiates 16 s_box
// for multi cycle adjust the NUM_SBOX and handle it in top level
module sub_bytes #(
    parameter int NUM_SBOX = 16,
    parameter int WIDTH = NUM_SBOX * 8,
    parameter int ROM = 0  // Use ROM or Case
) (
    input  logic [WIDTH-1:0] in,
    output logic [WIDTH-1:0] out
);

  localparam int NumBits = 8;
  localparam int NumBytes = WIDTH / NumBits;

  genvar i;

  generate
    if (ROM) begin : g_SUB_BYTES_ROM
      for (i = 0; i < NumBytes; i++) begin : g_SBOX_ROM
        sbox_rom u_sbox_rom (
            .byte_in (in[(WIDTH-1)-NumBits*i-:NumBits]),
            .byte_out(out[(WIDTH-1)-NumBits*i-:NumBits])
        );
      end
    end
    else begin : g_SUB_BYTES_CASE
      for (i = 0; i < NumBytes; i++) begin : g_SBOX
        sbox u_sbox (
            .byte_in (in[(WIDTH-1)-NumBits*i-:NumBits]),
            .byte_out(out[(WIDTH-1)-NumBits*i-:NumBits])
        );
      end
    end
  endgenerate

endmodule

module AES_test_vector_rom (
    input  logic [  3:0] vector_sel,
    output logic [127:0] plaintext,
    output logic [127:0] key,
    output logic [127:0] expected_ciphertext
);

  always_comb begin
    plaintext           = 128'd0;
    key                 = 128'd0;
    expected_ciphertext = 128'd0;

    case (vector_sel)

      4'd0: begin  // AI Generated
        plaintext           = 128'h00112233445566778899aabbccddeeff;
        key                 = 128'h000102030405060708090a0b0c0d0e0f;
        expected_ciphertext = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
      end

      4'd1: begin  // AI Generated
        plaintext           = 128'h00000000000000000000000000000000;
        key                 = 128'h00000000000000000000000000000000;
        expected_ciphertext = 128'h66e94bd4ef8a2c3b884cfa59ca342b2e;
      end

      // From Federal Information Processing Standards Publication 197
      // November 26, 2001 Announcing the ADVANCED ENCRYPTION STANDARD (AES)
      4'd3: begin
        plaintext           = 128'h00112233445566778899aabbccddeeff;
        key                 = 128'h000102030405060708090a0b0c0d0e0f;
        expected_ciphertext = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
      end

      4'd4: begin
        plaintext           = 128'h00000000000000000000000000000000;
        key                 = 128'h00000000000000000000000000000000;
        expected_ciphertext = 128'h66e94bd4ef8a2c3b884cfa59ca342b2e;
      end

      // From NIST https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program/block-ciphers
      4'd5: begin
        plaintext           = 128'h00000000000000000000000000000000;
        key                 = 128'h80000000000000000000000000000000;
        expected_ciphertext = 128'h0edd33d3c621e546455bd8ba1418bec8;
      end

      4'd6: begin
        plaintext           = 128'h00000000000000000000000000000000;
        key                 = 128'hc0000000000000000000000000000000;
        expected_ciphertext = 128'h4bc3f883450c113c64ca42e1112a9e87;
      end

      4'd7: begin
        plaintext           = 128'h00000000000000000000000000000000;
        key                 = 128'hfffffffffffffffffffc000000000000;
        expected_ciphertext = 128'h284ca2fa35807b8b0ae4d19e11d7dbd7;
      end

      4'd8: begin
        plaintext           = 128'h00000000000000000000000000000000;
        key                 = 128'hffffffffffffffffffffffffffffffff;
        expected_ciphertext = 128'ha1f6258c877d5fcd8964484538bfc92c;
      end

      4'd9: begin
        plaintext           = 128'h80000000000000000000000000000000;
        key                 = 128'h00000000000000000000000000000000;
        expected_ciphertext = 128'h3ad78e726c1ec02b7ebfe92b23d9ec34;
      end

      4'd9: begin
        plaintext           = 128'hffffffff000000000000000000000000;
        key                 = 128'h00000000000000000000000000000000;
        expected_ciphertext = 128'hc26277437420c5d634f715aea81a9132;
      end

      4'd10: begin
        plaintext           = 128'hffffffffffffffffffffffffffffffff;
        key                 = 128'h00000000000000000000000000000000;
        expected_ciphertext = 128'h3f5b8cc9ea855a0afa7347d23e8d664e;
      end

      4'd11: begin
        plaintext           = 128'hffffffffffffffffffffffffc0000000;
        key                 = 128'h00000000000000000000000000000000;
        expected_ciphertext = 128'h76da1fbe3a50728c50fd2e621b5ad885;
      end

      4'd12: begin
        plaintext           = 128'h00000000000000000000000000000000;
        key                 = 128'hffffffffffffffffffffc00000000000;
        expected_ciphertext = 128'hdbdfb527060e0a71009c7bb0c68f1d44;
      end

      4'd13: begin
        plaintext           = 128'h00000000000000000000000000000000;
        key                 = 128'hfff80000000000000000000000000000;
        expected_ciphertext = 128'hb5f1a33e50d40d103764c76bd4c6b6f8;
      end

      4'd14: begin
        plaintext           = 128'h00000000000000000000000000000000;
        key                 = 128'hfffffffffffffffffffffffe00000000;
        expected_ciphertext = 128'hc440de014d3d610707279b13242a5c36;
      end

      4'd15: begin
        plaintext           = 128'hfe000000000000000000000000000000;
        key                 = 128'h00000000000000000000000000000000;
        expected_ciphertext = 128'hb6da0bb11a23855d9c5cb1b4c6412e0a;
      end

      default: begin
        plaintext           = 128'h00112233445566778899aabbccddeeff;
        key                 = 128'h000102030405060708090a0b0c0d0e0f;
        expected_ciphertext = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
      end

    endcase
  end

endmodule

module sbox (
    input  logic [7:0] byte_in,
    output logic [7:0] byte_out
);

  always_comb begin
    case (byte_in)
      // Row 0
      8'h00: byte_out = 8'h63;
      8'h01: byte_out = 8'h7c;
      8'h02: byte_out = 8'h77;
      8'h03: byte_out = 8'h7b;
      8'h04: byte_out = 8'hf2;
      8'h05: byte_out = 8'h6b;
      8'h06: byte_out = 8'h6f;
      8'h07: byte_out = 8'hc5;
      8'h08: byte_out = 8'h30;
      8'h09: byte_out = 8'h01;
      8'h0a: byte_out = 8'h67;
      8'h0b: byte_out = 8'h2b;
      8'h0c: byte_out = 8'hfe;
      8'h0d: byte_out = 8'hd7;
      8'h0e: byte_out = 8'hab;
      8'h0f: byte_out = 8'h76;

      // Row 1
      8'h10: byte_out = 8'hca;
      8'h11: byte_out = 8'h82;
      8'h12: byte_out = 8'hc9;
      8'h13: byte_out = 8'h7d;
      8'h14: byte_out = 8'hfa;
      8'h15: byte_out = 8'h59;
      8'h16: byte_out = 8'h47;
      8'h17: byte_out = 8'hf0;
      8'h18: byte_out = 8'had;
      8'h19: byte_out = 8'hd4;
      8'h1a: byte_out = 8'ha2;
      8'h1b: byte_out = 8'haf;
      8'h1c: byte_out = 8'h9c;
      8'h1d: byte_out = 8'ha4;
      8'h1e: byte_out = 8'h72;
      8'h1f: byte_out = 8'hc0;

      // Row 2
      8'h20: byte_out = 8'hb7;
      8'h21: byte_out = 8'hfd;
      8'h22: byte_out = 8'h93;
      8'h23: byte_out = 8'h26;
      8'h24: byte_out = 8'h36;
      8'h25: byte_out = 8'h3f;
      8'h26: byte_out = 8'hf7;
      8'h27: byte_out = 8'hcc;
      8'h28: byte_out = 8'h34;
      8'h29: byte_out = 8'ha5;
      8'h2a: byte_out = 8'he5;
      8'h2b: byte_out = 8'hf1;
      8'h2c: byte_out = 8'h71;
      8'h2d: byte_out = 8'hd8;
      8'h2e: byte_out = 8'h31;
      8'h2f: byte_out = 8'h15;

      // Row 3
      8'h30: byte_out = 8'h04;
      8'h31: byte_out = 8'hc7;
      8'h32: byte_out = 8'h23;
      8'h33: byte_out = 8'hc3;
      8'h34: byte_out = 8'h18;
      8'h35: byte_out = 8'h96;
      8'h36: byte_out = 8'h05;
      8'h37: byte_out = 8'h9a;
      8'h38: byte_out = 8'h07;
      8'h39: byte_out = 8'h12;
      8'h3a: byte_out = 8'h80;
      8'h3b: byte_out = 8'he2;
      8'h3c: byte_out = 8'heb;
      8'h3d: byte_out = 8'h27;
      8'h3e: byte_out = 8'hb2;
      8'h3f: byte_out = 8'h75;

      // Row 4
      8'h40: byte_out = 8'h09;
      8'h41: byte_out = 8'h83;
      8'h42: byte_out = 8'h2c;
      8'h43: byte_out = 8'h1a;
      8'h44: byte_out = 8'h1b;
      8'h45: byte_out = 8'h6e;
      8'h46: byte_out = 8'h5a;
      8'h47: byte_out = 8'ha0;
      8'h48: byte_out = 8'h52;
      8'h49: byte_out = 8'h3b;
      8'h4a: byte_out = 8'hd6;
      8'h4b: byte_out = 8'hb3;
      8'h4c: byte_out = 8'h29;
      8'h4d: byte_out = 8'he3;
      8'h4e: byte_out = 8'h2f;
      8'h4f: byte_out = 8'h84;

      // Row 5
      8'h50: byte_out = 8'h53;
      8'h51: byte_out = 8'hd1;
      8'h52: byte_out = 8'h00;
      8'h53: byte_out = 8'hed;
      8'h54: byte_out = 8'h20;
      8'h55: byte_out = 8'hfc;
      8'h56: byte_out = 8'hb1;
      8'h57: byte_out = 8'h5b;
      8'h58: byte_out = 8'h6a;
      8'h59: byte_out = 8'hcb;
      8'h5a: byte_out = 8'hbe;
      8'h5b: byte_out = 8'h39;
      8'h5c: byte_out = 8'h4a;
      8'h5d: byte_out = 8'h4c;
      8'h5e: byte_out = 8'h58;
      8'h5f: byte_out = 8'hcf;

      // Row 6
      8'h60: byte_out = 8'hd0;
      8'h61: byte_out = 8'hef;
      8'h62: byte_out = 8'haa;
      8'h63: byte_out = 8'hfb;
      8'h64: byte_out = 8'h43;
      8'h65: byte_out = 8'h4d;
      8'h66: byte_out = 8'h33;
      8'h67: byte_out = 8'h85;
      8'h68: byte_out = 8'h45;
      8'h69: byte_out = 8'hf9;
      8'h6a: byte_out = 8'h02;
      8'h6b: byte_out = 8'h7f;
      8'h6c: byte_out = 8'h50;
      8'h6d: byte_out = 8'h3c;
      8'h6e: byte_out = 8'h9f;
      8'h6f: byte_out = 8'ha8;

      // Row 7
      8'h70: byte_out = 8'h51;
      8'h71: byte_out = 8'ha3;
      8'h72: byte_out = 8'h40;
      8'h73: byte_out = 8'h8f;
      8'h74: byte_out = 8'h92;
      8'h75: byte_out = 8'h9d;
      8'h76: byte_out = 8'h38;
      8'h77: byte_out = 8'hf5;
      8'h78: byte_out = 8'hbc;
      8'h79: byte_out = 8'hb6;
      8'h7a: byte_out = 8'hda;
      8'h7b: byte_out = 8'h21;
      8'h7c: byte_out = 8'h10;
      8'h7d: byte_out = 8'hff;
      8'h7e: byte_out = 8'hf3;
      8'h7f: byte_out = 8'hd2;

      // Row 8
      8'h80: byte_out = 8'hcd;
      8'h81: byte_out = 8'h0c;
      8'h82: byte_out = 8'h13;
      8'h83: byte_out = 8'hec;
      8'h84: byte_out = 8'h5f;
      8'h85: byte_out = 8'h97;
      8'h86: byte_out = 8'h44;
      8'h87: byte_out = 8'h17;
      8'h88: byte_out = 8'hc4;
      8'h89: byte_out = 8'ha7;
      8'h8a: byte_out = 8'h7e;
      8'h8b: byte_out = 8'h3d;
      8'h8c: byte_out = 8'h64;
      8'h8d: byte_out = 8'h5d;
      8'h8e: byte_out = 8'h19;
      8'h8f: byte_out = 8'h73;

      // Row 9
      8'h90: byte_out = 8'h60;
      8'h91: byte_out = 8'h81;
      8'h92: byte_out = 8'h4f;
      8'h93: byte_out = 8'hdc;
      8'h94: byte_out = 8'h22;
      8'h95: byte_out = 8'h2a;
      8'h96: byte_out = 8'h90;
      8'h97: byte_out = 8'h88;
      8'h98: byte_out = 8'h46;
      8'h99: byte_out = 8'hee;
      8'h9a: byte_out = 8'hb8;
      8'h9b: byte_out = 8'h14;
      8'h9c: byte_out = 8'hde;
      8'h9d: byte_out = 8'h5e;
      8'h9e: byte_out = 8'h0b;
      8'h9f: byte_out = 8'hdb;

      // Row A
      8'ha0: byte_out = 8'he0;
      8'ha1: byte_out = 8'h32;
      8'ha2: byte_out = 8'h3a;
      8'ha3: byte_out = 8'h0a;
      8'ha4: byte_out = 8'h49;
      8'ha5: byte_out = 8'h06;
      8'ha6: byte_out = 8'h24;
      8'ha7: byte_out = 8'h5c;
      8'ha8: byte_out = 8'hc2;
      8'ha9: byte_out = 8'hd3;
      8'haa: byte_out = 8'hac;
      8'hab: byte_out = 8'h62;
      8'hac: byte_out = 8'h91;
      8'had: byte_out = 8'h95;
      8'hae: byte_out = 8'he4;
      8'haf: byte_out = 8'h79;

      // Row B
      8'hb0: byte_out = 8'he7;
      8'hb1: byte_out = 8'hc8;
      8'hb2: byte_out = 8'h37;
      8'hb3: byte_out = 8'h6d;
      8'hb4: byte_out = 8'h8d;
      8'hb5: byte_out = 8'hd5;
      8'hb6: byte_out = 8'h4e;
      8'hb7: byte_out = 8'ha9;
      8'hb8: byte_out = 8'h6c;
      8'hb9: byte_out = 8'h56;
      8'hba: byte_out = 8'hf4;
      8'hbb: byte_out = 8'hea;
      8'hbc: byte_out = 8'h65;
      8'hbd: byte_out = 8'h7a;
      8'hbe: byte_out = 8'hae;
      8'hbf: byte_out = 8'h08;

      // Row C
      8'hc0: byte_out = 8'hba;
      8'hc1: byte_out = 8'h78;
      8'hc2: byte_out = 8'h25;
      8'hc3: byte_out = 8'h2e;
      8'hc4: byte_out = 8'h1c;
      8'hc5: byte_out = 8'ha6;
      8'hc6: byte_out = 8'hb4;
      8'hc7: byte_out = 8'hc6;
      8'hc8: byte_out = 8'he8;
      8'hc9: byte_out = 8'hdd;
      8'hca: byte_out = 8'h74;
      8'hcb: byte_out = 8'h1f;
      8'hcc: byte_out = 8'h4b;
      8'hcd: byte_out = 8'hbd;
      8'hce: byte_out = 8'h8b;
      8'hcf: byte_out = 8'h8a;

      // Row D
      8'hd0: byte_out = 8'h70;
      8'hd1: byte_out = 8'h3e;
      8'hd2: byte_out = 8'hb5;
      8'hd3: byte_out = 8'h66;
      8'hd4: byte_out = 8'h48;
      8'hd5: byte_out = 8'h03;
      8'hd6: byte_out = 8'hf6;
      8'hd7: byte_out = 8'h0e;
      8'hd8: byte_out = 8'h61;
      8'hd9: byte_out = 8'h35;
      8'hda: byte_out = 8'h57;
      8'hdb: byte_out = 8'hb9;
      8'hdc: byte_out = 8'h86;
      8'hdd: byte_out = 8'hc1;
      8'hde: byte_out = 8'h1d;
      8'hdf: byte_out = 8'h9e;

      // Row E
      8'he0: byte_out = 8'he1;
      8'he1: byte_out = 8'hf8;
      8'he2: byte_out = 8'h98;
      8'he3: byte_out = 8'h11;
      8'he4: byte_out = 8'h69;
      8'he5: byte_out = 8'hd9;
      8'he6: byte_out = 8'h8e;
      8'he7: byte_out = 8'h94;
      8'he8: byte_out = 8'h9b;
      8'he9: byte_out = 8'h1e;
      8'hea: byte_out = 8'h87;
      8'heb: byte_out = 8'he9;
      8'hec: byte_out = 8'hce;
      8'hed: byte_out = 8'h55;
      8'hee: byte_out = 8'h28;
      8'hef: byte_out = 8'hdf;

      // Row F
      8'hf0: byte_out = 8'h8c;
      8'hf1: byte_out = 8'ha1;
      8'hf2: byte_out = 8'h89;
      8'hf3: byte_out = 8'h0d;
      8'hf4: byte_out = 8'hbf;
      8'hf5: byte_out = 8'he6;
      8'hf6: byte_out = 8'h42;
      8'hf7: byte_out = 8'h68;
      8'hf8: byte_out = 8'h41;
      8'hf9: byte_out = 8'h99;
      8'hfa: byte_out = 8'h2d;
      8'hfb: byte_out = 8'h0f;
      8'hfc: byte_out = 8'hb0;
      8'hfd: byte_out = 8'h54;
      8'hfe: byte_out = 8'hbb;
      8'hff: byte_out = 8'h16;

      default: byte_out = 8'h00;  // Catch-all for safety
    endcase
  end
endmodule

// Probably need to make this synchronous if we wish to make Quartus actually synthesize this to rom
module sbox_rom (
    input  logic [7:0] byte_in,
    output logic [7:0] byte_out
);

  logic [7:0] rom[256];

  initial begin
    $readmemh("sbox_rom.mem", rom);
  end

  assign byte_out = rom[byte_in];

endmodule
// verilog_lint: waive-stop module-filename
