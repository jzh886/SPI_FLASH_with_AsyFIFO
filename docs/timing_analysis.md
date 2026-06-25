# 接口时序和最高频率计算方法

## 1. 时钟域划分

本设计包含两个主要时钟域：

| 时钟 | 作用 |
|---|---|
| `sys_clk` | 系统侧接口时钟域，负责命令提交、TX FIFO 写入、RX FIFO 读取 |
| `spi_clk` | SPI 控制时钟域，负责 SPI 状态机、字节发送器、FIFO 的 SPI 侧端口 |

两个时钟之间没有固定相位关系，因此属于异步时钟域设计。

跨时钟域路径包括：

- `sys_clk -> spi_clk`：命令请求 `sys_req_toggle`
- `spi_clk -> sys_clk`：命令接收 `spi_ack_toggle`
- `spi_clk -> sys_clk`：命令完成 `spi_done_toggle`
- `spi_clk -> sys_clk`：忙状态 `spi_busy`
- TX FIFO：系统侧写入，SPI 侧读出
- RX FIFO：SPI 侧写入，系统侧读出

## 2. 系统侧命令接口时序

命令接收条件：

```verilog
cmd_valid && cmd_ready
```

当该条件在 `sys_clk` 上升沿成立时：

1. 锁存 `cmd/addr/length`。
2. 翻转 `sys_req_toggle`。
3. SPI 时钟域通过两级同步检测 toggle 翻转。
4. SPI 状态机开始执行命令。

`cmd_ready` 表示上一条命令已经被 SPI 时钟域接收：

```verilog
cmd_ready = (sys_req_toggle == ack_sync2)
```

`done` 是 `sys_clk` 域单周期完成脉冲：

```verilog
done = done_sync2 ^ done_sync2_d
```

## 3. FIFO 数据接口时序

TX FIFO 用于页编程数据，系统侧写入条件：

```verilog
tx_wr && !tx_full
```

RX FIFO 用于 FLASH 读回数据和状态寄存器返回值，系统侧读取条件：

```verilog
rx_rd && !rx_empty
```

异步 FIFO 内部使用二进制指针寻址，Gray 指针跨时钟域，并通过两级同步器降低亚稳态传播风险。`full` 在写时钟域产生，`empty` 在读时钟域产生。

## 4. SPI 引脚时序

本设计采用 SPI Mode 0：

| 项目 | 说明 |
|---|---|
| CPOL | 0，`flash_sclk` 空闲为低 |
| CPHA | 0，第一个上升沿采样 |
| MOSI 更新 | `flash_sclk` 下降沿 |
| MISO 采样 | `flash_sclk` 上升沿 |
| CS | 低有效，单条 SPI transaction 期间保持低 |

字节发送流程：

1. `byte_start` 有效后，先将 `byte_tx[7]` 放到 `flash_mosi`。
2. 每经过 `SCLK_HALF_DIV` 个 `spi_clk` 周期翻转一次 `flash_sclk`。
3. `flash_sclk` 上升沿采样 `flash_miso`。
4. `flash_sclk` 下降沿切换下一位 `flash_mosi`。
5. 8 bit 完成后产生 `byte_done`。

## 5. SPI 时钟频率计算

`flash_sclk` 由 `spi_clk` 分频产生：

```verilog
parameter integer SCLK_HALF_DIV = 2
```

半周期：

```text
T_sclk_half = SCLK_HALF_DIV * T_spi_clk
```

完整周期：

```text
T_sclk = 2 * SCLK_HALF_DIV * T_spi_clk
```

SPI 时钟频率：

```text
f_sclk = f_spi_clk / (2 * SCLK_HALF_DIV)
```

示例：

| `f_spi_clk` | `SCLK_HALF_DIV` | `f_sclk` |
|---:|---:|---:|
| 100 MHz | 2 | 25 MHz |
| 100 MHz | 4 | 12.5 MHz |
| 50 MHz | 2 | 12.5 MHz |

## 6. 单字节和命令耗时估算

一个 SPI 字节需要 8 个 `flash_sclk` 周期：

```text
T_byte = 8 * T_sclk
```

换成 `spi_clk` 周期：

```text
N_byte = 8 * 2 * SCLK_HALF_DIV
       = 16 * SCLK_HALF_DIV
```

当 `SCLK_HALF_DIV = 2` 时，一个 SPI 字节约为 32 个 `spi_clk` 周期。

各命令 SPI 传输字节数：

| 命令 | SPI 字节序列 | 字节数 |
|---|---|---:|
| RDSR | `05h + dummy` | 2 |
| READ | `03h + 24bit addr + N dummy` | `4 + N` |
| PP | `06h`，然后 `02h + 24bit addr + N data` | `1 + 4 + N` |
| SE | `06h`，然后 `20h + 24bit addr` | `1 + 4` |

传输时间估算：

```text
T_cmd ≈ Byte_Count * 8 / f_sclk
```

换成 `spi_clk` 周期：

```text
N_cmd ≈ Byte_Count * 16 * SCLK_HALF_DIV + N_state_overhead
```

其中 `N_state_overhead` 是状态机装载字节、等待 FIFO、拉高/拉低 CS 等控制周期。

## 7. 最高频率计算方法

最高频率需要分时钟域分析。

`sys_clk` 最高频率由系统侧关键路径决定：

```text
Fmax_sys = 1 / T_sys_min
```

`spi_clk` 最高频率由 SPI 状态机、字节发送器、计数器和 FIFO SPI 侧逻辑关键路径决定：

```text
Fmax_spi = 1 / T_spi_min
```

`flash_sclk` 是由 `spi_clk` 分频得到的输出时钟：

```text
Fmax_flash_sclk = Fmax_spi / (2 * SCLK_HALF_DIV)
```

同时还必须满足 FLASH 器件手册中的 SPI 最大时钟频率：

```text
F_sclk_final = min(Fmax_spi / (2 * SCLK_HALF_DIV), FLASH 手册允许最大频率)
```

## 8. 时序约束和注意事项

1. `cmd_valid/cmd_ready`、`tx_wr/tx_full`、`rx_rd/rx_empty` 都在 `sys_clk` 域使用。
2. `sys_clk` 和 `spi_clk` 是异步关系。
3. 多 bit 数据通过异步 FIFO 跨域。
4. 单 bit 控制信号通过 toggle + 两级同步跨域。
5. STA 中应将 `sys_clk` 和 `spi_clk` 设为异步时钟组，或对 CDC 路径设置 false path。
6. Gray 指针同步寄存器应保留，避免综合优化破坏 CDC 结构。
