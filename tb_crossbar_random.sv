`timescale 1ns/1ps

module tb_crossbar_random;
    localparam int N = 4;
    localparam int W = 16;
    localparam int D = 4;
    localparam int PORT_W = $clog2(N);
    localparam int RANDOM_CYCLES = 300;
    localparam int DRAIN_CYCLES = 100;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n;
    logic [N-1:0] in_valid;
    logic [N-1:0] in_ready;
    logic [N-1:0][W-1:0] in_data;
    logic [N-1:0][PORT_W-1:0] in_dest;
    logic [N-1:0] out_valid;
    logic [N-1:0][W-1:0] out_data;
    logic [N-1:0][PORT_W-1:0] out_src;

    crossbar_voq #(
        .N_INPUTS(N),
        .N_OUTPUTS(N),
        .DATA_W(W),
        .FIFO_DEPTH(D)
    ) dut (.*);

    logic [W-1:0] model_storage [N][N][D];
    integer model_rd [N][N];
    integer model_wr [N][N];
    integer model_count [N][N];
    integer model_rr [N];
    logic expected_valid [N];
    integer expected_src [N];
    logic [W-1:0] expected_data [N];

    integer i;
    integer o;
    integer slot;
    integer candidate;
    integer scan;
    integer total_injected;
    integer total_delivered;
    integer errors;
    logic [N-1:0] used_source;

    task automatic clear_inputs;
        integer k;
        begin
            in_valid = '0;
            in_data = '0;
            in_dest = '0;
            for (k = 0; k < N; k = k + 1)
                in_dest[k] = PORT_W'($urandom_range(0, N - 1));
        end
    endtask

    task automatic randomize_inputs(input integer cycle_number);
        integer k;
        begin
            for (k = 0; k < N; k = k + 1) begin
                in_valid[k] = ($urandom_range(0, 99) < 70);
                in_dest[k] = PORT_W'($urandom_range(0, N - 1));
                in_data[k] = W'(cycle_number * N + k);
            end
        end
    endtask

    task automatic model_schedule;
        begin
            for (i = 0; i < N; i = i + 1)
                used_source[i] = 1'b0;
            for (o = 0; o < N; o = o + 1) begin
                expected_valid[o] = 0;
                expected_src[o] = 0;
                expected_data[o] = '0;

                for (scan = 0; scan < N; scan = scan + 1) begin
                    candidate = model_rr[o] + scan;
                    if (candidate >= N)
                        candidate = candidate - N;
                    if (!expected_valid[o] && model_count[candidate][o] != 0) begin
                        expected_valid[o] = 1;
                        expected_src[o] = candidate;
                        expected_data[o] = model_storage[candidate][o][model_rd[candidate][o]];
                    end
                end
            end

            // Match the RTL's input-side conflict resolution: the lowest
            // output index keeps a source when multiple outputs selected it.
            for (o = 0; o < N; o = o + 1)
                if (expected_valid[o]) begin
                    if (used_source[expected_src[o]])
                        expected_valid[o] = 0;
                    else
                        used_source[expected_src[o]] = 1;
                end
        end
    endtask

    task automatic update_model;
        integer source;
        integer destination;
        begin
            for (o = 0; o < N; o = o + 1) begin
                if (expected_valid[o]) begin
                    source = expected_src[o];
                    model_rd[source][o] = (model_rd[source][o] + 1) % D;
                    model_count[source][o] = model_count[source][o] - 1;
                    model_rr[o] = (source + 1) % N;
                    total_delivered = total_delivered + 1;
                end
            end

            for (i = 0; i < N; i = i + 1) begin
                if (in_valid[i] && in_ready[i]) begin
                    destination = int'(in_dest[i]);
                    model_storage[i][destination][model_wr[i][destination]] = in_data[i];
                    model_wr[i][destination] = (model_wr[i][destination] + 1) % D;
                    model_count[i][destination] = model_count[i][destination] + 1;
                    total_injected = total_injected + 1;
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            model_schedule();

            for (i = 0; i < N; i = i + 1) begin
                if (int'(in_dest[i]) >= N) begin
                    $display("ERROR: invalid destination on input %0d", i);
                    errors = errors + 1;
                end
                if (in_ready[i] !== (model_count[i][int'(in_dest[i])] < D)) begin
                    $display("ERROR: in_ready mismatch input=%0d rtl=%b model=%b", i,
                             in_ready[i], (model_count[i][in_dest[i]] < D));
                    errors = errors + 1;
                end
            end

            for (o = 0; o < N; o = o + 1) begin
                if (out_valid[o] !== expected_valid[o]) begin
                    $display("ERROR: out_valid mismatch output=%0d rtl=%b model=%b", o,
                             out_valid[o], expected_valid[o]);
                    errors = errors + 1;
                end
                if (expected_valid[o]) begin
                    if (out_src[o] !== PORT_W'(expected_src[o])) begin
                        $display("ERROR: source mismatch output=%0d rtl=%0d model=%0d", o,
                                 out_src[o], expected_src[o]);
                        errors = errors + 1;
                    end
                    if (out_data[o] !== expected_data[o]) begin
                        $display("ERROR: payload mismatch output=%0d rtl=%h model=%h", o,
                                 out_data[o], expected_data[o]);
                        errors = errors + 1;
                    end
                end
            end

            used_source = '0;
            for (o = 0; o < N; o = o + 1)
                if (out_valid[o]) begin
                    if (used_source[out_src[o]]) begin
                        $display("ERROR: source %0d granted twice in one cycle", out_src[o]);
                        errors = errors + 1;
                    end
                    used_source[out_src[o]] = 1;
                end

            update_model();
        end
    end

    initial begin
        rst_n = 1'b0;
        clear_inputs();
        total_injected = 0;
        total_delivered = 0;
        errors = 0;

        for (i = 0; i < N; i = i + 1) begin
            model_rr[i] = 0;
            for (o = 0; o < N; o = o + 1) begin
                model_rd[i][o] = 0;
                model_wr[i][o] = 0;
                model_count[i][o] = 0;
            end
        end

        repeat (2) @(posedge clk);
        rst_n = 1'b1;

        for (slot = 0; slot < RANDOM_CYCLES; slot = slot + 1) begin
            @(negedge clk);
            randomize_inputs(slot);
        end

        @(negedge clk);
        clear_inputs();
        for (slot = 0; slot < DRAIN_CYCLES; slot = slot + 1)
            @(negedge clk);

        for (i = 0; i < N; i = i + 1)
            for (o = 0; o < N; o = o + 1)
                if (model_count[i][o] != 0) begin
                    $display("ERROR: model queue not drained input=%0d output=%0d count=%0d",
                             i, o, model_count[i][o]);
                    errors = errors + 1;
                end

        if (errors != 0)
            $fatal(1, "Random verification failed with %0d errors", errors);
        $display("PASS: random verification injected %0d flits and delivered %0d flits",
                 total_injected, total_delivered);
        $finish;
    end
endmodule
