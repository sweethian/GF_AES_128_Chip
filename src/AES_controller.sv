module AES_controller #(
    parameter int NUM_SBOX = 4,  //total number of physical 8-bit S-boxes to build
    parameter int ROM = 0  //flag to enable ROM
) (
    input logic clk,
    input logic rst_n,

    input  logic startSignal,  // wrapper startSignal
    output logic doneSignal,   // core doneSignal

    input  logic [127:0] plaintext,  //initial text
    input  logic [127:0] cipherkey,  //initial key
    output logic [127:0] ciphertext  //final encrypted text
);

  localparam int NumRounds = 10;  //10 rounds for AES encryption
  //number of clock cycles needed for subbyte operation, which is also how many chunks 128 bit need to be divided to
  localparam int StateChunks = (16 + NUM_SBOX - 1) / NUM_SBOX;
  //remaining bits in the last chunks if number of sbox doesnt divide 16 perfectly
  localparam int LastStateBits = 128 - ((StateChunks - 1) * 8 * NUM_SBOX);
  // localparam int PadStateBits = (8 * NUM_SBOX) - LastStateBits;
  localparam int CountW = (StateChunks <= 1) ? 1 : $clog2(
      StateChunks
  );  //base 2 logarithm, how many bits needed to store StateChunks

  localparam int NumSBoxKey = (NUM_SBOX < 4) ? NUM_SBOX :
      4;  //number of sbox subword for key needs is capped at 4
  localparam
      int KeyChunks = (4 + NumSBoxKey - 1) / NumSBoxKey;  //how many chunks for the 32 bit key
  localparam
      int LastKeyBits = 32 - ((KeyChunks - 1) * 8 * NumSBoxKey);  //remaining bits in last chunk
  // localparam int PadKeyBits = (8 * NumSBoxKey) - LastKeyBits;

  localparam logic [1:0] PhaseIdle = 2'd0;  //idle while waiting for start signal
  localparam logic [1:0] PhaseSubState = 2'd1;  //subbyte operation ongoing
  localparam logic [1:0] PhaseSubKey = 2'd2;  //subword operation ongoing
  localparam logic [1:0] PhaseApply = 2'd3;  //add roundkey step

  logic busySignal;  //flag to ensure doesnt restart mid operation

  logic [1:0] phase;  //reg to store current phase
  logic [3:0] round_count;  //reg to store which round (0-9) currently in
  logic [CountW-1:0]
      chunk_count;  //reg to store which chunk going through Sbox, and how many cycles

  logic [127:0] state_reg;  //reg to hold 128 bit ciphertext
  logic [127:0] state_sub_reg;  //reg to hold 128 bit of S-boxes output

  logic [127:0] key_in;  //reg to hold 128 bit AES key for current round
  logic [127:0] key_out;  //reg to hold 128 bit AES key for next round

  logic [31:0] rot_word;  //reg to hold 32 bit output of key expansion module
  logic [31:0] sub_word_reg;  // reg to hold 32 bit output of S-box

  logic [NUM_SBOX*8 - 1:0] sbox_in;  //wire to fetch input of Sbox
  logic [NUM_SBOX*8 - 1:0] sbox_out;  //wire to fetch output of Sbox

  logic [127:0] shift_rows_out;  //wire to fetch output of Shiftrow
  logic [127:0] mix_columns_out;  //wire to fetch output of MixColumn

  key_expansion key_expansion_inst (
      .round_count(round_count),
      .sub_word   (sub_word_reg),
      .rot_word   (rot_word),
      .in         (key_in),
      .out        (key_out)
  );

  sub_bytes #(
      .NUM_SBOX(NUM_SBOX),
      .ROM(ROM)
  ) sub_bytes_inst (
      .in (sbox_in),
      .out(sbox_out)
  );

  shift_rows shift_rows_inst (
      .in (state_sub_reg),
      .out(shift_rows_out)
  );

  mix_columns mix_columns_inst (
      .in (shift_rows_out),
      .out(mix_columns_out)
  );

  always_comb begin
    sbox_in = '0;

    if (phase == PhaseSubState) begin
      if (chunk_count + 1 == StateChunks)
        sbox_in = state_reg[127-(chunk_count*8*NUM_SBOX)-:LastStateBits];
      // sbox_in = {{PadStateBits{1'b0}}, state_reg[127-(chunk_count*8*NUM_SBOX)-:LastStateBits]};
      else
        sbox_in = state_reg[127-(chunk_count*8*NUM_SBOX)-:8*NUM_SBOX];
    end
    else if (phase == PhaseSubKey) begin
      if (chunk_count + 1 == KeyChunks)
        sbox_in = rot_word[31-(chunk_count*8*NumSBoxKey)-:LastKeyBits];
      // sbox_in = {{PadKeyBits{1'b0}}, rot_word[31-(chunk_count*8*NumSBoxKey)-:LastKeyBits]};
      else
        sbox_in = rot_word[31-(chunk_count*8*NumSBoxKey)-:8*NumSBoxKey];
    end
  end

  // FSM machine for control
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ciphertext    <= '0;
      doneSignal    <= '0;
      busySignal    <= '0;

      phase         <= PhaseIdle;
      round_count   <= '0;
      chunk_count   <= '0;

      state_reg     <= '0;
      state_sub_reg <= '0;

      key_in        <= '0;
      sub_word_reg  <= '0;
    end
    else begin
      doneSignal <= '0;

      if (startSignal && !busySignal) begin
        // Round zero: Initial AddRoundKey
        ciphertext    <= '0;
        // doneSignal    <= '0;
        busySignal    <= 1'b1;

        phase         <= PhaseSubState;
        round_count   <= 4'd1;
        chunk_count   <= '0;

        state_reg     <= plaintext ^ cipherkey;
        state_sub_reg <= '0;

        key_in        <= cipherkey;
        sub_word_reg  <= '0;
      end

      else if (busySignal) begin

        case (phase)
          // two different phases as subbyte for text and subword for key shares same s-boxes
          PhaseSubState: begin
            if (chunk_count == StateChunks - 1) begin
              state_sub_reg[127-(chunk_count*8*NUM_SBOX)-:LastStateBits] <=
                  sbox_out[0+:LastStateBits];
              chunk_count <= '0;
              phase <= PhaseSubKey;
            end
            else begin
              state_sub_reg[127-(chunk_count*8*NUM_SBOX)-:8*NUM_SBOX] <= sbox_out;
              chunk_count <= chunk_count + CountW'(1);
            end
          end

          PhaseSubKey: begin
            if (chunk_count == KeyChunks - 1) begin
              sub_word_reg[31-(chunk_count*8*NumSBoxKey)-:LastKeyBits] <= sbox_out[0+:LastKeyBits];
              chunk_count                                              <= '0;
              phase                                                    <= PhaseApply;
            end
            else begin
              sub_word_reg[31-(chunk_count*8*NumSBoxKey)-:8*NumSBoxKey] <= sbox_out;
              chunk_count <= chunk_count + CountW'(1);
            end
          end

          PhaseApply: begin
            if (round_count < NumRounds) begin
              // Rounds 1 to 9:
              // SubBytes -> ShiftRows -> MixColumns -> AddRoundKey
              state_reg     <= mix_columns_out ^ key_out;
              state_sub_reg <= '0;

              key_in        <= key_out;
              sub_word_reg  <= '0;

              round_count   <= round_count + 4'd1;
              chunk_count   <= '0;
              phase         <= PhaseSubState;
            end
            else begin
              // Round 10:
              // SubBytes -> ShiftRows -> AddRoundKey
              // No MixColumns
              ciphertext  <= shift_rows_out ^ key_out;
              doneSignal  <= 1'b1;
              busySignal  <= 1'b0;

              phase       <= PhaseIdle;
              round_count <= '0;
              chunk_count <= '0;
            end
          end

          default: begin
            phase <= PhaseIdle;
          end

        endcase
      end
    end

  end

endmodule
