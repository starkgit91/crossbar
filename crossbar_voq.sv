`timescale 1ns/1ps

module crossbar_voq #(
    parameter int N_INPUTS = 4,
    parameter int N_OUTPUTS = 4,
    parameter int DATA_W = 32,
    parameter int FIFO_DEPTH = 4
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic [N_INPUTS-1:0]          in_valid,
    output logic [N_INPUTS-1:0]          in_ready,
    input  logic [N_INPUTS-1:0][DATA_W-1:0] in_data,
    input  logic [N_INPUTS-1:0][((N_OUTPUTS <= 1) ? 1 : $clog2(N_OUTPUTS))-1:0] in_dest,
    output logic [N_OUTPUTS-1:0]         out_valid,
    output logic [N_OUTPUTS-1:0][DATA_W-1:0] out_data,
    output logic [N_OUTPUTS-1:0][((N_INPUTS <= 1) ? 1 : $clog2(N_INPUTS))-1:0] out_src
);
    localparam int DEST_W = (N_OUTPUTS <= 1) ? 1 : $clog2(N_OUTPUTS);
    localparam int SRC_W = (N_INPUTS <= 1) ? 1 : $clog2(N_INPUTS);
    localparam int PTR_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
    localparam int COUNT_W = $clog2(FIFO_DEPTH + 1);

    logic [DATA_W-1:0] storage [N_INPUTS][N_OUTPUTS][FIFO_DEPTH];
    logic [PTR_W-1:0] rd_ptr [N_INPUTS][N_OUTPUTS];
    logic [PTR_W-1:0] wr_ptr [N_INPUTS][N_OUTPUTS];
    logic [COUNT_W-1:0] count [N_INPUTS][N_OUTPUTS];
    logic [SRC_W-1:0] rr_ptr [N_OUTPUTS];

    logic request [N_OUTPUTS][N_INPUTS];
    logic tentative_valid [N_OUTPUTS];
    integer tentative_src [N_OUTPUTS];
    logic grant_valid [N_OUTPUTS];
    integer grant_src [N_OUTPUTS];
    logic pop [N_INPUTS][N_OUTPUTS];
    logic push [N_INPUTS][N_OUTPUTS];

    integer input_idx;
    integer output_idx;
    integer scan_idx;
    integer candidate;
    logic [N_INPUTS-1:0] input_granted;

    always_comb begin
        for (output_idx = 0; output_idx < N_OUTPUTS; output_idx = output_idx + 1) begin
            tentative_valid[output_idx] = 1'b0;
            tentative_src[output_idx] = 0;
            for (input_idx = 0; input_idx < N_INPUTS; input_idx = input_idx + 1)
                request[output_idx][input_idx] = (count[input_idx][output_idx] != 0);

            for (scan_idx = 0; scan_idx < N_INPUTS; scan_idx = scan_idx + 1) begin
                candidate = int'(rr_ptr[output_idx]) + scan_idx;
                if (candidate >= N_INPUTS)
                    candidate = candidate - N_INPUTS;
                if (!tentative_valid[output_idx] && request[output_idx][candidate]) begin
                    tentative_valid[output_idx] = 1'b1;
                    tentative_src[output_idx] = candidate;
                end
            end
        end

        // Resolve the case where independent output arbiters chose one input
        // for multiple outputs. Lowest output index wins this scheduler pass.
        input_granted = '0;
        for (output_idx = 0; output_idx < N_OUTPUTS; output_idx = output_idx + 1) begin
            grant_valid[output_idx] = 1'b0;
            grant_src[output_idx] = 0;
            if (tentative_valid[output_idx] && !input_granted[tentative_src[output_idx]]) begin
                grant_valid[output_idx] = 1'b1;
                grant_src[output_idx] = tentative_src[output_idx];
                input_granted[tentative_src[output_idx]] = 1'b1;
            end
        end

        for (input_idx = 0; input_idx < N_INPUTS; input_idx = input_idx + 1) begin
            in_ready[input_idx] = 1'b0;
            if (int'(in_dest[input_idx]) < N_OUTPUTS)
                in_ready[input_idx] = (int'(count[input_idx][in_dest[input_idx]]) < FIFO_DEPTH);
        end

        for (output_idx = 0; output_idx < N_OUTPUTS; output_idx = output_idx + 1) begin
            out_valid[output_idx] = grant_valid[output_idx];
            out_data[output_idx] = '0;
            out_src[output_idx] = grant_src[output_idx][SRC_W-1:0];
            if (grant_valid[output_idx])
                out_data[output_idx] = storage[grant_src[output_idx]][output_idx][rd_ptr[grant_src[output_idx]][output_idx]];
        end

        for (input_idx = 0; input_idx < N_INPUTS; input_idx = input_idx + 1)
            for (output_idx = 0; output_idx < N_OUTPUTS; output_idx = output_idx + 1) begin
                pop[input_idx][output_idx] = 1'b0;
                push[input_idx][output_idx] = 1'b0;
            end

        for (output_idx = 0; output_idx < N_OUTPUTS; output_idx = output_idx + 1)
            if (grant_valid[output_idx])
                pop[grant_src[output_idx]][output_idx] = 1'b1;

        for (input_idx = 0; input_idx < N_INPUTS; input_idx = input_idx + 1)
            if (in_valid[input_idx] && in_ready[input_idx])
                push[input_idx][in_dest[input_idx]] = 1'b1;
    end

    integer i;
    integer o;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N_INPUTS; i = i + 1)
                for (o = 0; o < N_OUTPUTS; o = o + 1) begin
                    rd_ptr[i][o] <= '0;
                    wr_ptr[i][o] <= '0;
                    count[i][o] <= '0;
                end
            for (o = 0; o < N_OUTPUTS; o = o + 1)
                rr_ptr[o] <= '0;
        end else begin
            for (i = 0; i < N_INPUTS; i = i + 1)
                for (o = 0; o < N_OUTPUTS; o = o + 1) begin
                    if (push[i][o]) begin
                        storage[i][o][wr_ptr[i][o]] <= in_data[i];
                        if (int'(wr_ptr[i][o]) == FIFO_DEPTH - 1)
                            wr_ptr[i][o] <= '0;
                        else
                            wr_ptr[i][o] <= wr_ptr[i][o] + 1'b1;
                    end
                    if (pop[i][o]) begin
                        if (int'(rd_ptr[i][o]) == FIFO_DEPTH - 1)
                            rd_ptr[i][o] <= '0;
                        else
                            rd_ptr[i][o] <= rd_ptr[i][o] + 1'b1;
                    end
                    case ({push[i][o], pop[i][o]})
                        2'b10: count[i][o] <= count[i][o] + 1'b1;
                        2'b01: count[i][o] <= count[i][o] - 1'b1;
                        default: count[i][o] <= count[i][o];
                    endcase
                end

            for (o = 0; o < N_OUTPUTS; o = o + 1)
                if (grant_valid[o]) begin
                    if (grant_src[o] == N_INPUTS - 1)
                        rr_ptr[o] <= '0;
                    else
                        rr_ptr[o] <= SRC_W'(grant_src[o] + 1);
                end
        end
    end
endmodule
