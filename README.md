# SPI FLASH Controller With Async FIFO

本工程实现一个带异步 FIFO 的 SPI FLASH 主控模块，支持读取、页编程、扇区擦除和状态寄存器读取。

## 运行环境

本项目面向 **CentOS 7 虚拟机**，仿真工具链只采用 **Synopsys VCS + Verdi**。

进入工程根目录后，先设置工程路径：

```bash
source scripts/setup_env.sh
```

该脚本会自动获取工程根目录，并导出：

```bash
ROOT_PATH=/path/to/CompanyWork
```

VCS/Verdi 的安装环境由虚拟机或实验室 EDA 环境提供。加载完成后应能找到：

```bash
which vcs
which verdi
echo $VERDI_HOME
```

## 主要文件

- `rtl/async_fifo.v`：自研异步 FIFO
- `rtl/SPI_Flash.v`：SPI FLASH 主控顶层
- `tb/tb_SPI_Flash.sv`：基础 SystemVerilog 仿真平台
- `filelist/rtl.f`：RTL 文件清单
- `filelist/sim.f`：仿真文件清单
- `scripts/setup_env.sh`：工程根路径设置脚本
- `Makefile`：VCS 编译、仿真、Verdi 打开波形入口
- `docs/project_structure.md`：工程目录说明
- `docs/timing_analysis.md`：接口时序和最高频率计算方法

## 常用命令

```bash
source scripts/setup_env.sh
make env
make compile
make run
make selfcheck
make verdi
```

直接编译并运行：

```bash
make sim
```

执行 RTL 自检：

```bash
make selfcheck
```

`selfcheck` 会运行 VCS 仿真，并检查 `sim/sim.log` 中是否出现：

```text
RTL SELF CHECK PASS
```

清理仿真输出：

```bash
make clean
```

## 仿真输出

`make sim` 会在 `sim/` 目录下生成：

- `sim/simv`：VCS 仿真可执行文件
- `sim/compile.log`：编译日志
- `sim/vcs.log`：编译终端日志
- `sim/sim.log`：仿真日志
- `sim/spi_flash.fsdb`：Verdi 波形文件

## RTL 自检内容

当前 testbench 会自动检查 SPI MOSI 字节序：

- `RDSR`：`05 ff`
- `READ`：`03 00 12 34 ff ff ff ff`
- `PP`：`06`，然后 `02 00 20 00 11 22 33 44`
- `SE`：`06`，然后 `20 00 30 00`

如果指令码、地址、写数据、事务长度或事务数量不符合预期，仿真会打印 `RTL SELF CHECK FAIL` 并退出。
