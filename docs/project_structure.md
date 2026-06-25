# SPI FLASH Controller Project

## 目录结构

```text
.
├── Makefile               # VCS/Verdi 编译、仿真、波形入口
├── rtl/                   # 可综合 RTL 源码
│   ├── async_fifo.v        # 自研异步 FIFO
│   └── SPI_Flash.v         # 带异步 FIFO 的 SPI FLASH 主控
├── tb/                    # SystemVerilog 仿真平台
│   └── tb_SPI_Flash.sv     # 顶层基础自检 testbench
├── filelist/              # 文件清单
│   ├── rtl.f               # 仅 RTL 源码清单
│   └── sim.f               # RTL + testbench 仿真清单
├── scripts/               # 工程脚本
│   └── setup_env.sh        # 工程根路径设置脚本
├── sim/                   # VCS/Verdi 仿真输出目录
└── docs/                  # 设计说明文档
    ├── project_structure.md
    └── timing_analysis.md
```

## 使用流程

```bash
cd /path/to/CompanyWork
source scripts/setup_env.sh
make env
make selfcheck
make verdi
```

## Makefile 目标

- `make env`：打印 `ROOT_PATH`、`SIM_DIR`、文件清单和顶层名
- `make compile`：调用 VCS 编译 `tb_SPI_Flash`
- `make run`：运行 `sim/simv +DUMP_FSDB`
- `make sim`：先编译再运行
- `make selfcheck`：运行 RTL 自检并检查 PASS 标志
- `make verdi`：打开 `sim/spi_flash.fsdb`
- `make clean`：删除 VCS/Verdi 生成文件

## 约定

1. RTL 设计文件放在 `rtl/`。
2. testbench、仿真模型、激励文件放在 `tb/`。
3. VCS 生成的 `simv`、`csrc/`、`*.log`、`*.fsdb` 等输出放在 `sim/`。
4. 新增 RTL 后同步更新 `filelist/rtl.f` 和 `filelist/sim.f`。
5. 新增 testbench 或仿真模型后同步更新 `filelist/sim.f`。
