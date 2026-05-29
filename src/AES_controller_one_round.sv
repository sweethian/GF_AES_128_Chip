// The AES-128 core uses an iterative one-round-per-cycle
// architecture with a counter-controlled controller. A single
// AES round data-path is reused across all encryption rounds,
// reducing hardware duplication compared to fully unrolled or
// pipelined architectures. Control sequencing is implemented
// using a round counter and busy flag rather than an explicitly
// enumerated FSM.
module AES_controller_one_round #(
    parameter int ROM = 0
) (
    input logic clk,
    input logic rst_n,

    input  logic startSignal,
    output logic doneSignal,

    input  logic [127:0] plaintext,
    input  logic [127:0] cipherkey,
    output logic [127:0] ciphertext
);
  localparam int NumRounds = 10;
  logic busySignal;
  logic [3:0] round_count;
  logic [31:0] rot_word;
  logic [31:0] sub_word;
  logic [127:0] key_in;
  logic [127:0] key_out;

  logic [127:0] sub_bytes_in;
  logic [127:0] sub_bytes_out;
  logic [127:0] shift_rows_out;
  logic [127:0] mix_columns_out;

  key_expansion key_expansion_inst (
      .round_count(round_count),
      .sub_word(sub_word),
      .rot_word(rot_word),
      .in(key_in),
      .out(key_out)
  );

  sub_bytes #(
      .NUM_SBOX(4),
      .ROM(ROM)
  ) sub_bytes_key_inst (
      .in (rot_word),
      .out(sub_word)
  );

  sub_bytes sub_bytes_inst (
      .in (sub_bytes_in),
      .out(sub_bytes_out)
  );
  shift_rows shift_rows_inst (
      .in (sub_bytes_out),
      .out(shift_rows_out)
  );
  mix_columns mix_columns_inst (
      .in (shift_rows_out),
      .out(mix_columns_out)
  );

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    ciphertext   <= '0;
    doneSignal   <= 1'b0;
    busySignal   <= 1'b0;
    round_count  <= '0;
    key_in       <= '0;
    sub_bytes_in <= '0;
  end
  else begin
    doneSignal <= 1'b0;

    if (startSignal && !busySignal) begin //initial AddRoundKey 
      busySignal   <= 1'b1;
      round_count  <= 4'd1;
      sub_bytes_in <= plaintext ^ cipherkey;
      key_in       <= cipherkey;
    end
    else if (busySignal) begin
      if (round_count < NumRounds) begin
        round_count  <= round_count + 4'd1;
        sub_bytes_in <= mix_columns_out ^ key_out;
        key_in       <= key_out;
      end
      else begin
        ciphertext   <= shift_rows_out ^ key_out;
        doneSignal   <= 1'b1;
        busySignal   <= 1'b0;
        round_count  <= '0;
      end
    end
  end
end

endmodule
