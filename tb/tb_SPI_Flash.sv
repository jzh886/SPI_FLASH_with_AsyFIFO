`timescale 1ns/1ps

module tb_SPI_Flash;

    localparam [1:0] CMD_READ = 2'd0;
    localparam [1:0] CMD_PP   = 2'd1;
    localparam [1:0] CMD_SE   = 2'd2;
    localparam [1:0] CMD_RDSR = 2'd3;

    reg         sys_clk;
    reg         sys_rst_n;
    reg         spi_clk;
    reg         spi_rst_n;

    reg         cmd_valid;
    wire        cmd_ready;
    reg  [1:0]  cmd;
    reg  [23:0] addr;
    reg  [15:0] length;
    wire        busy;
    wire        done;

    reg  [7:0]  tx_data;
    reg         tx_wr;
    wire        tx_full;

    wire [7:0]  rx_data;
    reg         rx_rd;
    wire        rx_empty;

    wire        flash_cs_n;
    wire        flash_sclk;
    wire        flash_mosi;
    reg         flash_miso;

    integer     spi_bit_cnt;
    integer     spi_byte_cnt;
    integer     spi_trans_cnt;
    integer     error_cnt;
    reg  [7:0]  mosi_shift;
    reg  [7:0]  miso_shift;

    SPI_Flash #(
        .FIFO_ADDR_WIDTH(4),
        .SCLK_HALF_DIV  (2)
    ) dut (
        .sys_clk     (sys_clk),
        .sys_rst_n   (sys_rst_n),
        .spi_clk     (spi_clk),
        .spi_rst_n   (spi_rst_n),
        .cmd_valid   (cmd_valid),
        .cmd_ready   (cmd_ready),
        .cmd         (cmd),
        .addr        (addr),
        .length      (length),
        .busy        (busy),
        .done        (done),
        .tx_data     (tx_data),
        .tx_wr       (tx_wr),
        .tx_full     (tx_full),
        .rx_data     (rx_data),
        .rx_rd       (rx_rd),
        .rx_empty    (rx_empty),
        .flash_cs_n  (flash_cs_n),
        .flash_sclk  (flash_sclk),
        .flash_mosi  (flash_mosi),
        .flash_miso  (flash_miso)
    );

    initial begin
        sys_clk = 1'b0;
        forever #5 sys_clk = ~sys_clk;
    end

    initial begin
        spi_clk = 1'b0;
        forever #4 spi_clk = ~spi_clk;
    end

    initial begin
        if ($test$plusargs("DUMP_FSDB")) begin
            $fsdbDumpfile("spi_flash.fsdb");
            $fsdbDumpvars(0, tb_SPI_Flash);
        end
    end

    initial begin
        sys_rst_n = 1'b0;
        spi_rst_n = 1'b0;
        cmd_valid = 1'b0;
        cmd       = CMD_READ;
        addr      = 24'h0;
        length    = 16'h0;
        tx_data   = 8'h0;
        tx_wr     = 1'b0;
        rx_rd     = 1'b0;
        flash_miso = 1'b0;
        spi_bit_cnt = 0;
        spi_byte_cnt = 0;
        spi_trans_cnt = 0;
        error_cnt = 0;
        mosi_shift = 8'h00;
        miso_shift = 8'hA5;

        repeat (10) @(posedge sys_clk);
        sys_rst_n = 1'b1;
        spi_rst_n = 1'b1;

        repeat (10) @(posedge sys_clk);

        write_tx_fifo(8'h11);
        write_tx_fifo(8'h22);
        write_tx_fifo(8'h33);
        write_tx_fifo(8'h44);

        send_cmd(CMD_RDSR, 24'h000000, 16'd0);
        wait_done();
        read_rx_fifo();

        send_cmd(CMD_READ, 24'h001234, 16'd4);
        wait_done();
        read_rx_fifo();
        read_rx_fifo();
        read_rx_fifo();
        read_rx_fifo();

        send_cmd(CMD_PP, 24'h002000, 16'd4);
        wait_done();

        send_cmd(CMD_SE, 24'h003000, 16'd0);
        wait_done();

        #1000;
        if (spi_trans_cnt != 6) begin
            $display("[%0t] ERROR: SPI transaction count mismatch, expect 6, got %0d",
                     $time, spi_trans_cnt);
            error_cnt = error_cnt + 1;
        end

        if (error_cnt == 0) begin
            $display("[%0t] RTL SELF CHECK PASS", $time);
        end else begin
            $display("[%0t] RTL SELF CHECK FAIL, error_cnt=%0d", $time, error_cnt);
            $fatal;
        end
        $finish;
    end

    task send_cmd;
        input [1:0]  t_cmd;
        input [23:0] t_addr;
        input [15:0] t_len;
        begin
            @(posedge sys_clk);
            while (!cmd_ready) begin
                @(posedge sys_clk);
            end
            cmd       <= t_cmd;
            addr      <= t_addr;
            length    <= t_len;
            cmd_valid <= 1'b1;
            @(posedge sys_clk);
            cmd_valid <= 1'b0;
            $display("[%0t] CMD start: cmd=%0d addr=%06h len=%0d", $time, t_cmd, t_addr, t_len);
        end
    endtask

    task wait_done;
        begin
            @(posedge sys_clk);
            while (!done) begin
                @(posedge sys_clk);
            end
            $display("[%0t] CMD done", $time);
        end
    endtask

    task write_tx_fifo;
        input [7:0] data;
        begin
            @(posedge sys_clk);
            while (tx_full) begin
                @(posedge sys_clk);
            end
            tx_data <= data;
            tx_wr   <= 1'b1;
            @(posedge sys_clk);
            tx_wr   <= 1'b0;
            $display("[%0t] TX FIFO write: %02h", $time, data);
        end
    endtask

    task read_rx_fifo;
        begin
            @(posedge sys_clk);
            while (rx_empty) begin
                @(posedge sys_clk);
            end
            rx_rd <= 1'b1;
            @(posedge sys_clk);
            $display("[%0t] RX FIFO read: %02h", $time, rx_data);
            rx_rd <= 1'b0;
        end
    endtask

    function integer expected_len;
        input integer trans_idx;
        begin
            case (trans_idx)
                0: expected_len = 2; // RDSR: 05 + dummy
                1: expected_len = 8; // READ: 03 + addr + 4 dummy bytes
                2: expected_len = 1; // WREN before page program
                3: expected_len = 8; // PP: 02 + addr + 4 data bytes
                4: expected_len = 1; // WREN before sector erase
                5: expected_len = 4; // SE: 20 + addr
                default: expected_len = -1;
            endcase
        end
    endfunction

    function [7:0] expected_mosi_byte;
        input integer trans_idx;
        input integer byte_idx;
        begin
            expected_mosi_byte = 8'hxx;
            case (trans_idx)
                0: begin
                    case (byte_idx)
                        0: expected_mosi_byte = 8'h05;
                        1: expected_mosi_byte = 8'hff;
                    endcase
                end
                1: begin
                    case (byte_idx)
                        0: expected_mosi_byte = 8'h03;
                        1: expected_mosi_byte = 8'h00;
                        2: expected_mosi_byte = 8'h12;
                        3: expected_mosi_byte = 8'h34;
                        4: expected_mosi_byte = 8'hff;
                        5: expected_mosi_byte = 8'hff;
                        6: expected_mosi_byte = 8'hff;
                        7: expected_mosi_byte = 8'hff;
                    endcase
                end
                2: begin
                    case (byte_idx)
                        0: expected_mosi_byte = 8'h06;
                    endcase
                end
                3: begin
                    case (byte_idx)
                        0: expected_mosi_byte = 8'h02;
                        1: expected_mosi_byte = 8'h00;
                        2: expected_mosi_byte = 8'h20;
                        3: expected_mosi_byte = 8'h00;
                        4: expected_mosi_byte = 8'h11;
                        5: expected_mosi_byte = 8'h22;
                        6: expected_mosi_byte = 8'h33;
                        7: expected_mosi_byte = 8'h44;
                    endcase
                end
                4: begin
                    case (byte_idx)
                        0: expected_mosi_byte = 8'h06;
                    endcase
                end
                5: begin
                    case (byte_idx)
                        0: expected_mosi_byte = 8'h20;
                        1: expected_mosi_byte = 8'h00;
                        2: expected_mosi_byte = 8'h30;
                        3: expected_mosi_byte = 8'h00;
                    endcase
                end
            endcase
        end
    endfunction

    task check_mosi_byte;
        input [7:0] got;
        reg [7:0] exp;
        begin
            exp = expected_mosi_byte(spi_trans_cnt, spi_byte_cnt);
            if (got !== exp) begin
                $display("[%0t] ERROR: MOSI mismatch trans=%0d byte=%0d expect=%02h got=%02h",
                         $time, spi_trans_cnt, spi_byte_cnt, exp, got);
                error_cnt = error_cnt + 1;
            end else begin
                $display("[%0t] SPI MOSI byte OK: trans=%0d byte=%0d value=%02h",
                         $time, spi_trans_cnt, spi_byte_cnt, got);
            end
        end
    endtask

    always @(negedge flash_cs_n) begin
        spi_bit_cnt = 0;
        spi_byte_cnt = 0;
        mosi_shift  = 8'h00;
    end

    always @(posedge flash_sclk) begin
        if (!flash_cs_n) begin
            mosi_shift = {mosi_shift[6:0], flash_mosi};
            spi_bit_cnt = spi_bit_cnt + 1;
            if (spi_bit_cnt == 8) begin
                check_mosi_byte(mosi_shift);
                spi_byte_cnt = spi_byte_cnt + 1;
                spi_bit_cnt = 0;
            end
        end
    end

    always @(negedge flash_sclk or posedge flash_cs_n) begin
        if (flash_cs_n) begin
            if (spi_byte_cnt != 0) begin
                if (spi_byte_cnt != expected_len(spi_trans_cnt)) begin
                    $display("[%0t] ERROR: SPI transaction length mismatch trans=%0d expect=%0d got=%0d",
                             $time, spi_trans_cnt, expected_len(spi_trans_cnt), spi_byte_cnt);
                    error_cnt = error_cnt + 1;
                end else begin
                    $display("[%0t] SPI transaction OK: trans=%0d len=%0d",
                             $time, spi_trans_cnt, spi_byte_cnt);
                end
                spi_trans_cnt = spi_trans_cnt + 1;
            end
            miso_shift <= 8'hA5;
            flash_miso <= 1'b0;
        end else begin
            flash_miso <= miso_shift[7];
            miso_shift <= {miso_shift[6:0], ~miso_shift[7]};
        end
    end

endmodule
