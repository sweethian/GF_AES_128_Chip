module AES_serial_wrapper #(
    parameter int NUM_SBOX = 1,
    parameter int ONE_ROUND = 0,
    parameter int ROM = 0
) (
    input logic clk,
    input logic rst_n,

    input logic [7:0] serial_in,  //8 bit serial input shared by key and text
    input logic shift_enable,  //start signal replaced by shift enable
    output logic [7:0] serial_out,  //8 bit serial output

    //output logic [15:0] latency_cycles,
    output logic busy,
    output logic done

);

  typedef enum logic [1:0] {
    S_IDLE,
    S_RUN,
    S_DONE
  } wrapper_state_t;

  wrapper_state_t state;

  logic start_pulse;
  logic core_done;

  logic [255:0] shift_reg_in;
  logic [127:0] shift_reg_out;
  logic [5:0] shift_counter;  //count up to 31

  logic [127:0] plaintext_wire;
  logic [127:0] key_wire;
  logic [127:0] ciphertext_wire;

  assign plaintext_wire = shift_reg_in[127:0];
  assign key_wire = shift_reg_in[255:128];

  assign serial_out = shift_reg_out[127:120];  //shift 8 MSB out

  generate
    if (ONE_ROUND) begin : g_ONE_ROUND_CONTROLLER

      AES_controller_one_round #(
          .ROM(ROM)
      ) aes_core_inst (
          .clk        (clk),
          .rst_n      (rst_n),
          .startSignal(start_pulse),
          .doneSignal (core_done),
          .plaintext  (plaintext_wire),
          .cipherkey  (key_wire),
          .ciphertext (ciphertext_wire)
      );
    end
    else begin : g_LRSP_CONTROLLER

      AES_controller #(
          .NUM_SBOX(NUM_SBOX),
          .ROM(ROM)
      ) aes_core_inst (
          .clk        (clk),
          .rst_n      (rst_n),
          .startSignal(start_pulse),
          .doneSignal (core_done),
          .plaintext  (plaintext_wire),
          .cipherkey  (key_wire),
          .ciphertext (ciphertext_wire)
      );
    end
  endgenerate

  // Finite State Machine
  always_ff @(posedge clk) begin
    if (!rst_n) begin  //reset all
      state         <= S_IDLE;
      start_pulse   <= 1'b0;
      shift_reg_in  <= 256'd0;
      shift_reg_out <= 128'd0;
      busy          <= 1'b0;
      done          <= 1'b0;
      //latency_cycles <= 16'd0;
      shift_counter <= 6'b0;
    end
    else begin
      start_pulse <= 1'b0;

      case (state)

        S_IDLE: begin
          busy <= 1'b0;
          done <= 1'b0;

          if (shift_enable) begin
            shift_reg_in  <= {shift_reg_in[247:0], serial_in};  //shifting 8 bits
            shift_counter <= shift_counter + 6'd1;

            if (shift_counter == 6'd31) begin  //start after all 32x8 bits entered
              start_pulse   <= 1'b1;
              //latency_cycles <= 16'd0;
              shift_counter <= 6'b0;  //reset shift counter
              busy          <= 1'b1;
              state         <= S_RUN;
            end
          end
        end

        S_RUN: begin
          busy <= 1'b1;
          done <= 1'b0;

          if (!core_done) begin
            //latency_cycles <= latency_cycles + 16'd1;
          end
          else begin
            shift_reg_out <= ciphertext_wire;
            busy          <= 1'b0;
            done          <= 1'b1;
            state         <= S_DONE;
          end
        end

        S_DONE: begin
          busy <= 1'b0;
          done <= 1'b1;

          if (shift_enable) begin
            shift_reg_out <= {shift_reg_out[119:0], 8'h00};  //MSB shifted out from serial_out
            shift_counter <= shift_counter + 6'd1;

            if (shift_counter == 6'd15) begin  //15x8=128
              shift_counter <= 6'b0;
              done          <= 1'b0;
              state         <= S_IDLE;
            end
          end
        end

        default: begin
          state <= S_IDLE;
          busy  <= 1'b0;
          done  <= 1'b0;
        end

      endcase
    end
  end

endmodule
