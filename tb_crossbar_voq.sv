`timescale 1ns/1ps

module tb_crossbar_voq;
    localparam int N = 4;
    localparam int W = 16;
    localparam int D = 2;
    localparam int PORT_W = $clog2(N);

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

    crossbar_voq #(.N_INPUTS(N), .N_OUTPUTS(N), .DATA_W(W), .FIFO_DEPTH(D)) dut (.*);

    task automatic clear_inputs;
        integer k;
        begin
            in_valid = '0;
            in_data = '0;
            in_dest = '0;
            for (k = 0; k < N; k = k + 1)
                in_dest[k] = k[PORT_W-1:0];
        end
    endtask

    task automatic send_flit(input integer src, input integer dst, input integer payload);
        begin
            @(negedge clk);
            in_valid[src] = 1'b1;
            in_dest[src] = dst[PORT_W-1:0];
            in_data[src] = payload[W-1:0];
            while (!in_ready[src]) @(negedge clk);
            @(posedge clk);
            #1 in_valid[src] = 1'b0;
        end
    endtask

    integer cycle;
    integer seen_src [N];
    always @(posedge clk) begin
        if (rst_n) begin
            for (cycle = 0; cycle < N; cycle = cycle + 1)
                if (out_valid[cycle]) begin
                    if (seen_src[out_src[cycle]] != 0)
                        $fatal(1, "source %0d granted twice in one cycle", out_src[cycle]);
                    seen_src[out_src[cycle]] = 1;
                end
            for (cycle = 0; cycle < N; cycle = cycle + 1)
                seen_src[cycle] = 0;
        end
    end

    integer i;
    initial begin
        clear_inputs();
        rst_n = 1'b0;
        for (i = 0; i < N; i = i + 1) seen_src[i] = 0;
        repeat (2) @(posedge clk);
        rst_n = 1'b1;

        // Directed independent routing: all four inputs use all four outputs.
        @(negedge clk);
        for (i = 0; i < N; i = i + 1) begin
            in_valid[i] = 1'b1;
            in_dest[i] = i[PORT_W-1:0];
            in_data[i] = 16'h1000 + i[W-1:0];
        end
        @(posedge clk);
        #1 clear_inputs();
        @(posedge clk);
        for (i = 0; i < N; i = i + 1)
            if (!out_valid[i] || out_data[i] != (16'h1000 + i[W-1:0]))
                $fatal(1, "directed transfer failed at output %0d", i);

        // Same-cycle contention: three sources target output 0.
        @(negedge clk);
        in_valid[0] = 1'b1;
        in_valid[1] = 1'b1;
        in_valid[2] = 1'b1;
        in_dest[0] = 0;
        in_dest[1] = 0;
        in_dest[2] = 0;
        in_data[0] = 16'h2000;
        in_data[1] = 16'h2001;
        in_data[2] = 16'h2002;
        @(posedge clk);
        #1 clear_inputs();

        // The grants must preserve FIFO order and rotate through contenders.
        #1;
        if (!out_valid[0] || out_data[0] != 16'h2001)
            $fatal(1, "contention payload 1 was not delivered first");
        @(posedge clk);
        #1;
        if (!out_valid[0] || out_data[0] != 16'h2002)
            $fatal(1, "contention payload 2 was not delivered second");
        @(posedge clk);
        #1;
        if (!out_valid[0] || out_data[0] != 16'h2000)
            $fatal(1, "contention payload 0 was not delivered third");
        $display("PASS: VOQ crossbar directed and contention checks completed");
        $finish;
    end
endmodule
