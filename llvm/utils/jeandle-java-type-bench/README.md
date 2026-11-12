# JavaType cache performance suite

整理自 2026-11-03 five-way-cache 实验的 10 个合成场景。测试输入、C++ 驱动和
fixture 保留原始内容；不包含历史结果、构建日志、编译器二进制或优化实现补丁。
本目录位于 `llvm/utils/jeandle-java-type-bench/`，不依赖日志仓库。

| 类型 | 场景 | 测量内容 |
| --- | --- | --- |
| native | same | 同一上下文重复查询 |
| native | cross-unique | 32 个不同上下文各查询一次 |
| native | cross | 16 个上下文轮转，累计 32 次查询 |
| native | same-edit | 查询间修改同块中的无关指令，并通知失效 |
| native | other-edit | 查询间修改其他块中的无关指令，并通知失效 |
| opt | deep-static | 深 select 链的静态调用去虚化 |
| opt | wide-static | 宽静态调用工作负载 |
| opt | leaf-static | 叶节点静态调用工作负载 |
| opt | tce-cha | type-check-elimination + cha-devirtualization |
| opt | virtual-cfg | 带控制流的虚调用去虚化 |

这些是定向合成微基准，不能据此推断 Java 应用整体运行速度。
native 计时范围包含每批 cache/LVI 清理和场景中的失效处理，排除 IR 解析和 fixture 构建。
opt 测量完整进程 CPU 时间，包含启动、解析和 pass 执行；两类指标不要合并。

## 环境和运行

需要 Linux、Python 3.12+、C++ 编译器和已构建的 Jeandle LLVM（含 opt、llvm-config、
静态库和对应头文件）。普通上游 LLVM 不支持这里的 API、pass 和 VM callback。
各版本应使用一致的 Release/O3/NDEBUG、assertions 和链接设置，测量期间避免并行构建。

```sh
cd llvm/utils/jeandle-java-type-bench
python3 prepare.py
python3 build.py --llvm-config /absolute/baseline/build/bin/llvm-config \
  --api legacy --out ./replay-base
python3 build.py --llvm-config /absolute/candidate/build/bin/llvm-config \
  --api new --out ./replay-new
cp versions.example.json versions.local.json
# 将 versions.local.json 中的 opt、replay 改为真实绝对路径，并记录源码 revision。
python3 run.py --versions versions.local.json --cpu 8 --out results-local
python3 audit.py results-local
```

`build.py --api` 支持 `legacy`、`v2`、`new` 和 `reference`。
`reference` 使用 legacy 头文件中的无缓存 `getJavaType`，应配套同版本源码；
opt 的无缓存模式需在对应版本配置中设置
`"opt_flags": ["-jeandle-disable-java-type-cache=true"]`。
`new` 对应 final-cache 的 `JavaTypeCache` / `getCachedJavaType` 接口。
每次构建使用该版本自己的 llvm-config；不会替换其他版本的 include/library 路径。
配置至少包含 `base` 和一个对照版本，也支持历史五路 raw/base/null/v2/new 配置。

`prepare.py` 校验 SHA256 并解包约 40 MB 的冻结 opt 语料，只改写 cases.json 的路径。
压缩归档约 362 KB，解包文件不会入 Git。脚本拒绝覆盖现有输入、二进制和结果目录。

## 方法与输出

保留原实验默认设置：固定单核、串行随机交错，3 轮预热、15 轮 base/base A/A、
31 轮版本比较、seed 20261103。native 自动校准至每个样本约 360 ms CPU，
以每 32 次查询一批归一化。正式样本低于 200 ms 时只标记 inconclusive。
opt 输入不自动扩容，以保留原始输入身份。

诊断与计时分开：native 诊断逐查询对比 fresh DT/AC/LVI 的 uncached 结果，
并检查 klass=22、checksum 和各版本 IR 哈希；opt 启用缓存验证并要求诊断、验证
以及不同版本的优化后 IR 字节一致。正式计时不加统计、验证或 summary 选项。
所有 native 进程使用结果目录中的独立工作目录，不改写冻结输入。

对逐轮配对变化中位数进行 4000 次 bootstrap，95% CI 必须整体超过同场景
A/A 绝对变化 P95 才判定 improvement/regression。负百分比表示右侧版本更快。
保留历史统计方法；CI 不排除系统漂移，且不代表生产语料分布。

结果包含 `manifest.json`（配置、二进制/输入/runner SHA256、核心信息）、
`samples.jsonl`、`diagnostics.json`、验证/诊断 IR、`summary.json` 和 `SUCCESS`。
`SUCCESS` 仅表示流程完成。`audit.py` 独立复查样本数量、时长、输入和二进制哈希、
IR 一致性、成本中位数和配对变化，输出 `audit.json`；短样本仍允许审计通过，
但 `sample_duration_ok=false`，不能宣称显著提速。默认五路共 1850 个正式样本。
为保留 Python 和 C++ 中的校验，不要以 `python -O` 或 `PYTHONOPTIMIZE` 运行脚本。

## 来源与放置建议

冻结输入和 native 源码来自日志仓库
`jeandle-develop-log/artifacts/five-way-cache-20261103/`，日期 2026-11-03。
`inputs/SHA256.json` 保存复制时的原始哈希；未改动 C++ fixture 的许可头。
新的运行入口去除了原实验服务器绝对路径、历史 replay 二进制复制和旧结果依赖，
因此新结果应单独记录，不能与旧会话拼接中位数。

建议随 Jeandle LLVM 源码放在 `llvm/utils/`，让 API 变化与 benchmark 同步维护。
正确性回归另放 lit/unittest；性能基准保留独立运行入口，不放入常规 lit 计时门禁。
报告、perf 原始数据和网页查看器继续放开发日志/展示仓库。
等到有多个编译器后端或独立发布、维护需求时，再拆独立 benchmark 项目。

## 本次整理的验证范围

运行 `python3 -m unittest discover -s tests -v` 检查全部十场景的模拟编排、
短样本判定、IR 不一致中止、冻结输入哈希及覆盖保护。这些检查不产生性能结论。
整理时未在配套 Jeandle Linux 构建上实际编译或跑分；C++ 源码和输入保留历史原件，
迁入源码仓库后仍需按上面的命令做一次真实构建和完整运行。
