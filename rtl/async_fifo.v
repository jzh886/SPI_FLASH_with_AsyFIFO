// -----------------------------------------------------------------------------
// 模块名称 : async_fifo
// 功能说明 : 自研异步 FIFO，用于两个不同时钟域之间传递多字节数据。
//
// 设计思路 :
// 1. 写端和读端分别使用 wr_clk、rd_clk，彼此没有固定相位关系。
// 2. FIFO 存储体 mem 使用双端口 RAM 风格描述：写端写入，读端异步读出。
// 3. 本地时钟域内部使用二进制指针 wr_bin/rd_bin 进行地址累加。
// 4. 跨时钟域同步时不直接传二进制指针，而是传 Gray 指针。
//    Gray 码相邻计数值只有 1 bit 翻转，可以降低多 bit 跨时钟采样时的错误风险。
// 5. 对跨域来的 Gray 指针使用两级触发器同步，降低亚稳态传播概率。
// 6. full 在写时钟域产生，empty 在读时钟域产生。
//
// 参数说明 :
// DATA_WIDTH : FIFO 单个数据宽度，默认 8 bit。
// ADDR_WIDTH : FIFO 地址宽度，实际深度为 2^ADDR_WIDTH。
// -----------------------------------------------------------------------------
module async_fifo #(
    parameter integer DATA_WIDTH = 8,
    parameter integer ADDR_WIDTH = 4
) (
    // 写时钟域接口
    input  wire                  wr_clk,    // 写时钟
    input  wire                  wr_rst_n,  // 写时钟域异步低有效复位
    input  wire                  wr_en,     // 写请求，高电平有效；full 为 0 时真正写入
    input  wire [DATA_WIDTH-1:0] wr_data,   // 写入 FIFO 的数据
    output reg                   full,      // FIFO 满标志，属于写时钟域

    // 读时钟域接口
    input  wire                  rd_clk,    // 读时钟
    input  wire                  rd_rst_n,  // 读时钟域异步低有效复位
    input  wire                  rd_en,     // 读请求，高电平有效；empty 为 0 时真正读出
    output wire [DATA_WIDTH-1:0] rd_data,   // 当前读指针指向的数据
    output reg                   empty      // FIFO 空标志，属于读时钟域
);

    // 指针宽度比地址宽度多 1 bit。
    // 低 ADDR_WIDTH bit 用于访问 RAM，高 1 bit 用于区分“地址相同但圈数不同”的情况。
    localparam integer PTR_WIDTH = ADDR_WIDTH + 1;

    // FIFO 存储体。深度为 2^ADDR_WIDTH，每个存储单元 DATA_WIDTH bit。
    reg [DATA_WIDTH-1:0] mem [0:(1 << ADDR_WIDTH)-1];

    // 写端二进制指针和 Gray 指针。
    reg [PTR_WIDTH-1:0] wr_bin;
    reg [PTR_WIDTH-1:0] wr_gray;

    // 读端二进制指针和 Gray 指针。
    reg [PTR_WIDTH-1:0] rd_bin;
    reg [PTR_WIDTH-1:0] rd_gray;

    // 将读指针 Gray 码同步到写时钟域，用于写侧判断 full。
    reg [PTR_WIDTH-1:0] rd_gray_sync1;
    reg [PTR_WIDTH-1:0] rd_gray_sync2;

    // 将写指针 Gray 码同步到读时钟域，用于读侧判断 empty。
    reg [PTR_WIDTH-1:0] wr_gray_sync1;
    reg [PTR_WIDTH-1:0] wr_gray_sync2;

    // 真正发生写/读的条件。
    // 注意：外部即使拉高 wr_en/rd_en，也必须同时满足非满/非空。
    wire                 wr_fire;
    wire                 rd_fire;

    // 下一拍二进制指针和 Gray 指针。
    wire [PTR_WIDTH-1:0] wr_bin_next;
    wire [PTR_WIDTH-1:0] wr_gray_next;
    wire [PTR_WIDTH-1:0] rd_bin_next;
    wire [PTR_WIDTH-1:0] rd_gray_next;

    // 写侧 full 判断时使用的读指针比较值。
    wire [PTR_WIDTH-1:0] rd_gray_full_cmp;

    assign wr_fire = wr_en && !full;
    assign rd_fire = rd_en && !empty;

    // 二进制指针每次成功传输加 1。
    // Verilog 会把 1 bit 的 wr_fire/rd_fire 自动扩展到指针宽度参与加法。
    assign wr_bin_next  = wr_bin + wr_fire;
    assign rd_bin_next  = rd_bin + rd_fire;

    // 二进制转 Gray：gray = bin ^ (bin >> 1)。
    assign wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    assign rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    // FIFO 满判断：
    // 当“下一写指针 Gray 码”等于“同步过来的读指针 Gray 码最高两位取反、其余位相同”
    // 时，表示写指针已经追上读指针一整圈，即 FIFO 将满。
    assign rd_gray_full_cmp = {
        ~rd_gray_sync2[PTR_WIDTH-1:PTR_WIDTH-2],
         rd_gray_sync2[PTR_WIDTH-3:0]
    };

    // 读数据采用组合读方式：rd_data 始终等于当前读指针位置的数据。
    // 当 rd_fire 有效时，读指针在下一个 rd_clk 上升沿前进。
    assign rd_data = mem[rd_bin[ADDR_WIDTH-1:0]];

    // 写时钟域逻辑：
    // 1. full 为 0 且 wr_en 有效时，将 wr_data 写入当前写地址。
    // 2. 更新写指针。
    // 3. 根据下一写指针和同步来的读指针更新 full。
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin  <= {PTR_WIDTH{1'b0}};
            wr_gray <= {PTR_WIDTH{1'b0}};
            full    <= 1'b0;
        end else begin
            if (wr_fire) begin
                mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
            end
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
            full    <= (wr_gray_next == rd_gray_full_cmp);
        end
    end

    // 读时钟域逻辑：
    // 1. empty 为 0 且 rd_en 有效时，读指针前进。
    // 2. 根据下一读指针和同步来的写指针更新 empty。
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin  <= {PTR_WIDTH{1'b0}};
            rd_gray <= {PTR_WIDTH{1'b0}};
            empty   <= 1'b1;
        end else begin
            rd_bin  <= rd_bin_next;
            rd_gray <= rd_gray_next;
            empty   <= (rd_gray_next == wr_gray_sync2);
        end
    end

    // 读指针 Gray 码跨到写时钟域。
    // 两级同步器可以降低亚稳态继续向后级逻辑传播的概率。
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_sync1 <= {PTR_WIDTH{1'b0}};
            rd_gray_sync2 <= {PTR_WIDTH{1'b0}};
        end else begin
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
        end
    end

    // 写指针 Gray 码跨到读时钟域。
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_gray_sync1 <= {PTR_WIDTH{1'b0}};
            wr_gray_sync2 <= {PTR_WIDTH{1'b0}};
        end else begin
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
        end
    end

endmodule
