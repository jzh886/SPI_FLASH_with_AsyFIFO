// -----------------------------------------------------------------------------
// 模块名称 : SPI_Flash
// 功能说明 : 带异步 FIFO 的 SPI FLASH 主控模块。
//
// 支持的 SPI FLASH 指令：
// 1. READ  : 03h，读取数据
// 2. PP    : 02h，页编程；本模块会自动先发送 WREN(06h)
// 3. SE    : 20h，4 KB 扇区擦除；本模块会自动先发送 WREN(06h)
// 4. RDSR  : 05h，读取状态寄存器
//
// 时钟域划分：
// 1. sys_clk : 系统侧接口时钟域。用户在该时钟域提交命令、写入 TX FIFO、读取 RX FIFO。
// 2. spi_clk : SPI 控制时钟域。状态机、SPI 字节发送器、FIFO 另一侧端口都在该时钟域。
//
// 数据通路：
// 1. 页编程数据：sys_clk 域通过 tx_wr/tx_data 写入 TX FIFO，
//    SPI 状态机在 spi_clk 域从 TX FIFO 取出并发送给 FLASH。
// 2. 读取数据/状态寄存器：SPI 状态机在 spi_clk 域写入 RX FIFO，
//    系统侧在 sys_clk 域通过 rx_rd/rx_data 读取。
//
// 命令通路：
// 命令数量少，且一次只允许一个命令在执行，因此没有使用命令 FIFO。
// 本模块使用 toggle 握手将 cmd/addr/length 从 sys_clk 域传递给 spi_clk 域。
//
// SPI 模式：
// Mode 0，CPOL=0，CPHA=0。
// flash_sclk 空闲为低，上升沿采样 flash_miso，下降沿更新 flash_mosi。
// -----------------------------------------------------------------------------
module SPI_Flash #(
    parameter integer FIFO_ADDR_WIDTH = 4, // TX/RX FIFO 深度为 2^FIFO_ADDR_WIDTH
    parameter integer SCLK_HALF_DIV   = 2  // flash_sclk 半周期分频系数
) (
    // 系统时钟域
    input  wire        sys_clk,
    input  wire        sys_rst_n,

    // SPI 控制时钟域
    input  wire        spi_clk,
    input  wire        spi_rst_n,

    // 命令接口。
    // 当 cmd_valid && cmd_ready 为 1 时，cmd/addr/length 被模块接收。
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [1:0]  cmd,       // 0:READ 1:PP 2:SE 3:RDSR
    input  wire [23:0] addr,      // 24 bit FLASH 地址
    input  wire [15:0] length,    // READ/PP 的字节数；RDSR/SE 可忽略
    output wire        busy,      // 命令已提交或 SPI 状态机正在工作
    output wire        done,      // 命令完成脉冲，sys_clk 域单周期有效

    // TX FIFO 系统侧写接口，用于页编程数据。
    input  wire [7:0]  tx_data,
    input  wire        tx_wr,
    output wire        tx_full,

    // RX FIFO 系统侧读接口，用于读数据和状态寄存器返回值。
    output wire [7:0]  rx_data,
    input  wire        rx_rd,
    output wire        rx_empty,

    // SPI FLASH 物理引脚
    output reg         flash_cs_n,
    output reg         flash_sclk,
    output reg         flash_mosi,
    input  wire        flash_miso
);

    // 系统侧命令编码。
    localparam [1:0] CMD_READ = 2'd0; // 读取 FLASH 数据
    localparam [1:0] CMD_PP   = 2'd1; // 页编程
    localparam [1:0] CMD_SE   = 2'd2; // 4 KB 扇区擦除
    localparam [1:0] CMD_RDSR = 2'd3; // 读取状态寄存器

    // SPI FLASH 指令码，兼容常见 W25Qxx 类器件。
    localparam [7:0] OP_READ = 8'h03;
    localparam [7:0] OP_PP   = 8'h02;
    localparam [7:0] OP_WREN = 8'h06;
    localparam [7:0] OP_RDSR = 8'h05;
    localparam [7:0] OP_SE   = 8'h20;
    localparam [7:0] OP_DMY  = 8'hff; // 读操作时 MOSI 发送的 dummy 字节

    // 主状态机状态编码。
    // 状态机工作在 spi_clk 域，负责按顺序发指令、地址、数据。
    localparam [4:0] ST_IDLE          = 5'd0;  // 空闲，等待新命令
    localparam [4:0] ST_WREN_LOAD     = 5'd1;  // 准备发送 WREN 指令
    localparam [4:0] ST_WREN_START    = 5'd2;  // 启动 WREN 字节发送
    localparam [4:0] ST_WREN_WAIT     = 5'd3;  // WREN 结束后拉高 CS
    localparam [4:0] ST_CMD_LOAD      = 5'd4;  // 准备发送具体操作指令
    localparam [4:0] ST_BYTE_START    = 5'd5;  // 通用字节发送启动状态
    localparam [4:0] ST_BYTE_WAIT     = 5'd6;  // 等待字节发送器完成
    localparam [4:0] ST_ADDR2_LOAD    = 5'd7;  // 发送地址高字节 addr[23:16]
    localparam [4:0] ST_ADDR1_LOAD    = 5'd8;  // 发送地址中字节 addr[15:8]
    localparam [4:0] ST_ADDR0_LOAD    = 5'd9;  // 发送地址低字节 addr[7:0]
    localparam [4:0] ST_READ_LOAD     = 5'd10; // 准备读取一个数据字节
    localparam [4:0] ST_READ_STORE    = 5'd11; // 将读到的数据写入 RX FIFO
    localparam [4:0] ST_PP_LOAD       = 5'd12; // 从 TX FIFO 取页编程数据
    localparam [4:0] ST_PP_START      = 5'd13; // 启动页编程数据字节发送
    localparam [4:0] ST_PP_NEXT       = 5'd14; // 页编程字节计数递减
    localparam [4:0] ST_RDSR_LOAD     = 5'd15; // 准备读取状态寄存器
    localparam [4:0] ST_RDSR_STORE    = 5'd16; // 将状态寄存器写入 RX FIFO
    localparam [4:0] ST_FINISH        = 5'd17; // 本次命令结束

    // sys_clk 域命令保持寄存器。
    // cmd_valid && cmd_ready 时锁存命令，随后通过 sys_req_toggle 通知 spi_clk 域。
    reg [1:0]  sys_cmd_hold;
    reg [23:0] sys_addr_hold;
    reg [15:0] sys_len_hold;
    reg        sys_req_toggle;

    // spi_clk 域返回给 sys_clk 域的握手/状态信号。
    reg spi_ack_toggle;  // SPI 状态机已经接收命令
    reg spi_done_toggle; // SPI 状态机完成命令
    reg spi_busy;        // SPI 状态机忙标志

    // toggle 握手同步寄存器。
    // req_* : sys_clk -> spi_clk
    // ack/done/busy_* : spi_clk -> sys_clk
    reg req_sync1;
    reg req_sync2;
    reg req_sync2_d;
    reg ack_sync1;
    reg ack_sync2;
    reg done_sync1;
    reg done_sync2;
    reg done_sync2_d;
    reg busy_sync1;
    reg busy_sync2;

    wire spi_cmd_fire; // spi_clk 域检测到新命令的单周期脉冲

    // cmd_ready 为 1 表示上一条命令已经被 SPI 域接收，可以提交下一条。
    assign cmd_ready = (sys_req_toggle == ack_sync2);

    // done_toggle 每翻转一次表示完成一次命令；同步回 sys_clk 后做边沿检测。
    assign done = done_sync2 ^ done_sync2_d;

    // busy 包含两部分：
    // 1. sys_clk 域命令已经提交，但 spi_clk 域尚未 ack；
    // 2. spi_clk 域状态机正在执行。
    assign busy = (sys_req_toggle != ack_sync2) || busy_sync2;

    // SPI 域检测 sys_req_toggle 翻转，形成新命令脉冲。
    assign spi_cmd_fire = req_sync2 ^ req_sync2_d;

    // 系统侧命令锁存。
    // 使用 cmd_ready 限制一次只接收一条命令，简化控制逻辑。
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sys_cmd_hold   <= CMD_READ;
            sys_addr_hold  <= 24'd0;
            sys_len_hold   <= 16'd0;
            sys_req_toggle <= 1'b0;
        end else if (cmd_valid && cmd_ready) begin
            sys_cmd_hold   <= cmd;
            sys_addr_hold  <= addr;
            sys_len_hold   <= length;
            sys_req_toggle <= ~sys_req_toggle;
        end
    end

    // 将 SPI 域的 ack/done/busy 同步回系统时钟域。
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            ack_sync1    <= 1'b0;
            ack_sync2    <= 1'b0;
            done_sync1   <= 1'b0;
            done_sync2   <= 1'b0;
            done_sync2_d <= 1'b0;
            busy_sync1   <= 1'b0;
            busy_sync2   <= 1'b0;
        end else begin
            ack_sync1    <= spi_ack_toggle;
            ack_sync2    <= ack_sync1;
            done_sync1   <= spi_done_toggle;
            done_sync2   <= done_sync1;
            done_sync2_d <= done_sync2;
            busy_sync1   <= spi_busy;
            busy_sync2   <= busy_sync1;
        end
    end

    // 将系统侧命令请求 toggle 同步到 SPI 时钟域。
    always @(posedge spi_clk or negedge spi_rst_n) begin
        if (!spi_rst_n) begin
            req_sync1   <= 1'b0;
            req_sync2   <= 1'b0;
            req_sync2_d <= 1'b0;
        end else begin
            req_sync1   <= sys_req_toggle;
            req_sync2   <= req_sync1;
            req_sync2_d <= req_sync2;
        end
    end

    // TX FIFO 的 SPI 侧读接口。
    // 页编程时，状态机从这里取出待写入 FLASH 的数据。
    wire       tx_fifo_empty;
    wire [7:0] tx_fifo_rd_data;
    reg        tx_fifo_rd_en;

    // RX FIFO 的 SPI 侧写接口。
    // 读 FLASH 数据或读状态寄存器时，状态机向这里写入返回值。
    wire       rx_fifo_full;
    reg        rx_fifo_wr_en;
    reg  [7:0] rx_fifo_wr_data;

    // 发送 FIFO：sys_clk 域写入，spi_clk 域读出。
    async_fifo #(
        .DATA_WIDTH(8),
        .ADDR_WIDTH(FIFO_ADDR_WIDTH)
    ) u_tx_fifo (
        .wr_clk   (sys_clk),
        .wr_rst_n (sys_rst_n),
        .wr_en    (tx_wr),
        .wr_data  (tx_data),
        .full     (tx_full),
        .rd_clk   (spi_clk),
        .rd_rst_n (spi_rst_n),
        .rd_en    (tx_fifo_rd_en),
        .rd_data  (tx_fifo_rd_data),
        .empty    (tx_fifo_empty)
    );

    // 接收 FIFO：spi_clk 域写入，sys_clk 域读出。
    async_fifo #(
        .DATA_WIDTH(8),
        .ADDR_WIDTH(FIFO_ADDR_WIDTH)
    ) u_rx_fifo (
        .wr_clk   (spi_clk),
        .wr_rst_n (spi_rst_n),
        .wr_en    (rx_fifo_wr_en),
        .wr_data  (rx_fifo_wr_data),
        .full     (rx_fifo_full),
        .rd_clk   (sys_clk),
        .rd_rst_n (sys_rst_n),
        .rd_en    (rx_rd),
        .rd_data  (rx_data),
        .empty    (rx_empty)
    );

    // SPI 主状态机寄存器。
    reg [4:0]  state;
    reg [4:0]  after_byte_state; // 通用字节发送完成后的返回状态
    reg [1:0]  op_cmd;           // 当前正在执行的命令
    reg [23:0] op_addr;          // 当前命令地址
    reg [15:0] bytes_left;       // READ/PP 剩余字节数

    // SPI 字节发送器寄存器。
    // 主状态机只负责装载 byte_tx 并拉高 byte_start；
    // 字节发送器负责产生 8 个 SCLK 周期并采样 MISO。
    reg [7:0]  byte_tx;          // 本次要发送的 8 bit
    reg        byte_start;       // 启动发送一个字节，spi_clk 域单周期脉冲
    reg        byte_busy;        // 字节发送器忙
    reg        byte_done;        // 字节发送完成，spi_clk 域单周期脉冲
    reg [7:0]  byte_rx;          // 本字节期间从 MISO 采样得到的数据
    reg [7:0]  tx_shift;         // MOSI 移位寄存器
    reg [7:0]  rx_shift;         // MISO 移位寄存器
    reg [2:0]  bit_cnt;          // 当前字节 bit 计数，0 到 7
    reg [15:0] div_cnt;          // SCLK 半周期分频计数器

    // SPI 字节发送器。
    // Mode 0 时序：
    // 1. 空闲时 flash_sclk = 0。
    // 2. 启动时先把最高位 byte_tx[7] 放到 MOSI。
    // 3. SCLK 上升沿采样 MISO。
    // 4. SCLK 下降沿切换到下一位 MOSI。
    always @(posedge spi_clk or negedge spi_rst_n) begin
        if (!spi_rst_n) begin
            byte_busy  <= 1'b0;
            byte_done  <= 1'b0;
            byte_rx    <= 8'd0;
            tx_shift   <= 8'd0;
            rx_shift   <= 8'd0;
            bit_cnt    <= 3'd0;
            div_cnt    <= 16'd0;
            flash_sclk <= 1'b0;
            flash_mosi <= 1'b0;
        end else begin
            byte_done <= 1'b0;

            if (byte_start && !byte_busy) begin
                // 装载新字节，准备发送最高位。
                byte_busy  <= 1'b1;
                tx_shift   <= byte_tx;
                rx_shift   <= 8'd0;
                bit_cnt    <= 3'd0;
                div_cnt    <= 16'd0;
                flash_sclk <= 1'b0;
                flash_mosi <= byte_tx[7];
            end else if (byte_busy) begin
                if (div_cnt == SCLK_HALF_DIV - 1) begin
                    div_cnt <= 16'd0;

                    if (!flash_sclk) begin
                        // 低到高：产生 SCLK 上升沿，并采样 MISO。
                        flash_sclk <= 1'b1;
                        rx_shift   <= {rx_shift[6:0], flash_miso};
                    end else begin
                        // 高到低：产生 SCLK 下降沿，并准备下一位 MOSI。
                        flash_sclk <= 1'b0;
                        if (bit_cnt == 3'd7) begin
                            // 8 bit 已经全部采样完成。
                            byte_busy <= 1'b0;
                            byte_done <= 1'b1;
                            byte_rx   <= rx_shift;
                        end else begin
                            bit_cnt    <= bit_cnt + 3'd1;
                            flash_mosi <= tx_shift[6];
                            tx_shift   <= {tx_shift[6:0], 1'b0};
                        end
                    end
                end else begin
                    div_cnt <= div_cnt + 16'd1;
                end
            end else begin
                flash_sclk <= 1'b0;
            end
        end
    end

    // SPI 主状态机。
    // 执行流程示例：
    // READ : CS拉低 -> 03h -> addr[23:16] -> addr[15:8] -> addr[7:0]
    //        -> dummy 字节换回读数据 -> 写 RX FIFO -> 重复 length 次 -> CS拉高 -> done
    // PP   : CS拉低 -> 06h -> CS拉高 -> CS拉低 -> 02h -> 24bit addr
    //        -> 从 TX FIFO 取数据并发送 -> 重复 length 次 -> CS拉高 -> done
    // SE   : CS拉低 -> 06h -> CS拉高 -> CS拉低 -> 20h -> 24bit addr -> CS拉高 -> done
    // RDSR : CS拉低 -> 05h -> dummy 字节换回状态寄存器 -> 写 RX FIFO -> CS拉高 -> done
    always @(posedge spi_clk or negedge spi_rst_n) begin
        if (!spi_rst_n) begin
            state           <= ST_IDLE;
            after_byte_state <= ST_IDLE;
            op_cmd          <= CMD_READ;
            op_addr         <= 24'd0;
            bytes_left      <= 16'd0;
            byte_tx         <= 8'd0;
            byte_start      <= 1'b0;
            flash_cs_n      <= 1'b1;
            spi_ack_toggle  <= 1'b0;
            spi_done_toggle <= 1'b0;
            spi_busy        <= 1'b0;
            tx_fifo_rd_en   <= 1'b0;
            rx_fifo_wr_en   <= 1'b0;
            rx_fifo_wr_data <= 8'd0;
        end else begin
            byte_start    <= 1'b0;
            tx_fifo_rd_en <= 1'b0;
            rx_fifo_wr_en <= 1'b0;

            case (state)
                ST_IDLE: begin
                    // 空闲时片选释放，等待来自 sys_clk 域的新命令。
                    flash_cs_n <= 1'b1;
                    spi_busy   <= 1'b0;
                    if (spi_cmd_fire) begin
                        op_cmd         <= sys_cmd_hold;
                        op_addr        <= sys_addr_hold;
                        bytes_left     <= sys_len_hold;
                        spi_ack_toggle <= req_sync2;
                        spi_busy       <= 1'b1;
                        // 页编程和扇区擦除会改变 FLASH 内容，必须先发送 WREN。
                        if ((sys_cmd_hold == CMD_PP) || (sys_cmd_hold == CMD_SE)) begin
                            state <= ST_WREN_LOAD;
                        end else begin
                            state <= ST_CMD_LOAD;
                        end
                    end
                end

                ST_WREN_LOAD: begin
                    // WREN 是单字节命令：CS 拉低后发送 06h。
                    flash_cs_n       <= 1'b0;
                    byte_tx          <= OP_WREN;
                    after_byte_state <= ST_WREN_WAIT;
                    state            <= ST_WREN_START;
                end

                ST_WREN_START: begin
                    byte_start <= 1'b1;
                    state      <= ST_BYTE_WAIT;
                end

                ST_WREN_WAIT: begin
                    // WREN 发送完成后释放 CS，再开始真正的 PP/SE 命令。
                    flash_cs_n <= 1'b1;
                    state      <= ST_CMD_LOAD;
                end

                ST_CMD_LOAD: begin
                    // 根据系统命令选择对应 SPI 指令码。
                    flash_cs_n <= 1'b0;
                    case (op_cmd)
                        CMD_READ: byte_tx <= OP_READ;
                        CMD_PP:   byte_tx <= OP_PP;
                        CMD_SE:   byte_tx <= OP_SE;
                        default:  byte_tx <= OP_RDSR;
                    endcase
                    after_byte_state <= (op_cmd == CMD_RDSR) ? ST_RDSR_LOAD : ST_ADDR2_LOAD;
                    state            <= ST_BYTE_START;
                end

                ST_ADDR2_LOAD: begin
                    // SPI FLASH 使用 24 bit 地址，先发高字节。
                    byte_tx          <= op_addr[23:16];
                    after_byte_state <= ST_ADDR1_LOAD;
                    state            <= ST_BYTE_START;
                end

                ST_ADDR1_LOAD: begin
                    byte_tx          <= op_addr[15:8];
                    after_byte_state <= ST_ADDR0_LOAD;
                    state            <= ST_BYTE_START;
                end

                ST_ADDR0_LOAD: begin
                    // 地址最后 1 字节发送完成后，根据命令类型进入不同数据阶段。
                    byte_tx <= op_addr[7:0];
                    if (op_cmd == CMD_READ) begin
                        after_byte_state <= ST_READ_LOAD;
                    end else if (op_cmd == CMD_PP) begin
                        after_byte_state <= ST_PP_LOAD;
                    end else begin
                        after_byte_state <= ST_FINISH;
                    end
                    state <= ST_BYTE_START;
                end

                ST_READ_LOAD: begin
                    // 读取数据时，MOSI 继续发送 dummy 字节，MISO 返回有效数据。
                    // 如果 RX FIFO 满，则暂停在这里，避免读回数据丢失。
                    if (bytes_left == 16'd0) begin
                        state <= ST_FINISH;
                    end else if (!rx_fifo_full) begin
                        byte_tx          <= OP_DMY;
                        after_byte_state <= ST_READ_STORE;
                        state            <= ST_BYTE_START;
                    end
                end

                ST_READ_STORE: begin
                    // 将刚刚从 MISO 收到的 1 字节写入 RX FIFO。
                    rx_fifo_wr_data <= byte_rx;
                    rx_fifo_wr_en   <= 1'b1;
                    bytes_left      <= bytes_left - 16'd1;
                    state           <= ST_READ_LOAD;
                end

                ST_PP_LOAD: begin
                    // 页编程时从 TX FIFO 取 1 字节待写数据。
                    // 如果 TX FIFO 空，则暂停等待系统侧继续写入数据。
                    if (bytes_left == 16'd0) begin
                        state <= ST_FINISH;
                    end else if (!tx_fifo_empty) begin
                        byte_tx       <= tx_fifo_rd_data;
                        tx_fifo_rd_en <= 1'b1;
                        state         <= ST_PP_START;
                    end
                end

                ST_PP_START: begin
                    after_byte_state <= ST_PP_NEXT;
                    state            <= ST_BYTE_START;
                end

                ST_PP_NEXT: begin
                    // 一个页编程数据字节发送完成，剩余计数减 1。
                    bytes_left <= bytes_left - 16'd1;
                    state      <= ST_PP_LOAD;
                end

                ST_RDSR_LOAD: begin
                    // 读状态寄存器只读 1 字节，返回值写入 RX FIFO。
                    if (!rx_fifo_full) begin
                        byte_tx          <= OP_DMY;
                        after_byte_state <= ST_RDSR_STORE;
                        state            <= ST_BYTE_START;
                    end
                end

                ST_RDSR_STORE: begin
                    rx_fifo_wr_data <= byte_rx;
                    rx_fifo_wr_en   <= 1'b1;
                    state           <= ST_FINISH;
                end

                ST_BYTE_START: begin
                    // 通用字节发送入口：拉高 byte_start 一个 spi_clk 周期。
                    byte_start <= 1'b1;
                    state      <= ST_BYTE_WAIT;
                end

                ST_BYTE_WAIT: begin
                    // 等待字节发送器完成，然后跳转到预设的 after_byte_state。
                    if (byte_done) begin
                        state <= after_byte_state;
                    end
                end

                ST_FINISH: begin
                    // 命令结束：释放片选，翻转 done toggle，返回空闲。
                    flash_cs_n      <= 1'b1;
                    spi_done_toggle <= ~spi_done_toggle;
                    spi_busy        <= 1'b0;
                    state           <= ST_IDLE;
                end

                default: begin
                    flash_cs_n <= 1'b1;
                    spi_busy   <= 1'b0;
                    state      <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
