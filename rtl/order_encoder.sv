// This file was generated with the help of Claude Code.
//
// Order encoder: turns one order_request_t per valid cycle into a whole order
// entry message (EnterOrder, ReplaceOrder, or CancelOrder).
//
// Timing: the message is registered, so order_valid is high exactly one cycle
// after request_valid. A new request may arrive every cycle. The message's
// length is implied by its type byte; bytes past the end are zero.
module order_encoder
    import messages_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst,

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic                    request_valid,
    input  order_request_t          request,
    /* verilator lint_on UNUSEDSIGNAL */

    output logic                    order_valid,
    output logic [MESSAGE_BITS-1:0] order_data
);

    logic                    order_valid_next;
    logic [MESSAGE_BITS-1:0] order_data_next;

    always_comb begin
        // TODO: encode request into order_data_next, based on request.kind
        // (ORDER_ENTER / ORDER_REPLACE / ORDER_CANCEL). See the design doc's
        // order API appendix for each type's byte layout, and
        // messages_pkg.sv for the field offsets (ORDER_*_OFFSET constants),
        // TYPE_* type bytes, and the instrument/time-in-force constants.
        //
        //  - Fields a given message type doesn't set should stay zero
        //    (bytes past the message's end are zero).
        //  - order_valid_next should be high exactly when request_valid is
        //    high and request.kind is one of the three known kinds (the
        //    message is registered, so order_valid becomes high one cycle
        //    later).
        // A field n bytes long at byte offset o is order_data[8*o +: 8*n]
        // (design doc, Appendix C). Bytes a message doesn't use stay zero.
        order_valid_next = request_valid;
        order_data_next  = '0;

        case (request.kind)
            ORDER_ENTER: begin
                order_data_next[8*0  +: 8]  = TYPE_ENTER;                            // type, byte 0
                order_data_next[8*1  +: 64] = request.token;                         // token, bytes 1-8
                order_data_next[8*9  +: 8]  = request.is_buy ? SIDE_BUY : SIDE_SELL;  // side, byte 9
                order_data_next[8*10 +: 32] = request.shares;                        // shares, bytes 10-13
                order_data_next[8*14 +: 16] = INSTRUMENT;                            // instrument, bytes 14-15
                order_data_next[8*16 +: 64] = request.price;                         // price, bytes 16-23
                order_data_next[8*24 +: 8]  = TIME_IN_FORCE_DAY;                     // time in force, byte 24
            end
            ORDER_REPLACE: begin
                order_data_next[8*0  +: 8]  = TYPE_REPLACE;            // type, byte 0
                order_data_next[8*1  +: 64] = request.existing_token;  // existing token, bytes 1-8
                order_data_next[8*9  +: 64] = request.token;           // replacement token, bytes 9-16
                order_data_next[8*17 +: 32] = request.shares;          // shares, bytes 17-20
                order_data_next[8*21 +: 64] = request.price;           // price, bytes 21-28
            end
            ORDER_CANCEL: begin
                order_data_next[8*0 +: 8]  = TYPE_CANCEL;     // type, byte 0
                order_data_next[8*1 +: 64] = request.token;   // token, bytes 1-8
                order_data_next[8*9 +: 32] = request.shares;  // shares remaining, bytes 9-12
            end
            default: begin
                order_valid_next = 1'b0;  // unknown kind: no message
            end
        endcase

    end

    always_ff @(posedge clk) begin
        if (rst) begin
            order_valid <= 1'b0;
        end else begin
            order_valid <= order_valid_next;
        end
        // No reset: the message only matters when order_valid is high.
        order_data <= order_data_next;
    end

endmodule
