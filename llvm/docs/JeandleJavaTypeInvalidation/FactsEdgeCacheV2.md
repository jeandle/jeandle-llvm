# JavaType V2 的 Facts 边缓存

> 本文保留 Facts 边缓存阶段的设计和验证记录。V1 专属实现及测试已移除，下面的旧路径、接口和测试数量对应当时提交；当前实现以 [JavaTypeCacheV2Design.md](JavaTypeCacheV2Design.md) 为准。

这个方案在 Facts 求解过程中复用两类边信息：完整根调用的 `edgeGuard` 结果，以及满足稳定 oracle 契约时的完整 `isNullEdge` 判断。它保持 `factsAt` 的遍历、查询内 memo、预算和循环处理方式，避免直接把依赖当前查询状态的 `(Value, BasicBlock)` 完整 Facts 结果跨查询发布。

实现位于独立的 [CachedJavaTypeV2.cpp](../../lib/Analysis/Jeandle/CachedJavaTypeV2.cpp) 和 [CachedJavaTypeV2.h](../../include/llvm/Analysis/Jeandle/CachedJavaTypeV2.h)。原版 [JavaType.cpp](../../lib/IR/Jeandle/JavaType.cpp) 和公共 `JavaType` 定义保持不变。缓存由调用方持有并通过聚合对象传入；当前通过 JavaTypeAnalysis 接入消费者 pass。

## 1. 当前接口和保存内容

四类缓存现由 `JavaTypeCacheV2` 聚合持有，定义移至 `JavaTypeCacheV2.h/.cpp`；查询入口只接收一个总 cache 引用。Facts 仍是独立成员，保留自己的模式、失效和计数。`JavaTypeAnalysis` 已切换到 V2，并显式使用稳定 oracle 模式。

```cpp
JavaTypeCacheV2 Cache(F, JavaTypeFactsCacheV2::Mode::StableOracleEpoch);
Cache.setStatsEnabled(true); // 默认关闭；Analysis由统计开关控制。
LVINullEdgeOracle Oracle{LVI};
JavaType T = getCachedJavaTypeV2(V, &DT, Context, Oracle, Cache);
```

默认 `GuardOnly` 不缓存 null 判断，也不启用会跳过 oracle 的 Final；Base、Defined和guard仍可复用。详细生命周期及 Final 选择性失效见 [JavaTypeCacheV2Design.md](JavaTypeCacheV2Design.md)。

两张表都使用原 helper 调用点的 `(V, From, To)` 作为 key。这里的 `V` 是原算法传给 helper 的实际值；不为了增加命中率，另行统一各 helper 不同的 casts/freeze/identity 归一化规则。

| 保存内容 | GuardOnly | StableOracleEpoch | 命中省掉的工作 |
|---|---|---|---|
| 完整根 `edgeGuard(From, To, V)` 返回的 `JavaType` | 保存 | 保存 | 条件追踪、精确 klass guard 识别、类型集合处理等 |
| 完整 `isNullEdge(V, From, To)` 返回的 bool | 不保存 | 保存 | oracle 调用及其可能触发的 LVI，以及结构性 null-path 回退检查 |
| `factsAt(V, BB)` 完整结果 | 不保存 | 不保存 | 不适用 |
| `Processed`、Facts/Phi 预算、活跃 PHI/Value 集合 | 保持查询内 | 保持查询内 | 不适用 |

`isNullEdge` 缓存的是包含可达性检查、oracle 和结构性回退的完整判断，不只是裸 LVI 的返回值。`false` 表示不能跳过这条边，同时包括“证明非 null”和“未能证明 null”；不能将其解释为非 null 证明。

`edgeGuard` 仅在 `ConditionDepth == 0` 时读写共享表。非零深度绕过缓存，避免把根调用的 32 层条件追踪额度用于嵌套调用。完整根返回的 unknown 也可缓存：在固定输入下，它的局部条件追踪限制是确定的，与会被整次查询共同消耗的 `FactsBudget` 不同。内部 `traceToCheckInstanceof` 子帧和它的 `Visited` 集合不持久化。

## 2. 为什么不直接保存完整 Facts

原版 `factsAt` 的可观察行为不只由 `(V, BB)` 决定，还受本次查询剩余预算、已有 `Processed`、前驱遍历顺序和当前循环入口影响。已有隔离反例包括：

- 子节点因预算返回 unknown 后，祖先仍可在本查询内保存受截断影响的结果。
- 先以充足预算获得完整结果，再在低预算查询直接返回该结果，会改变原版低预算结果。
- 不可约循环中，从不同入口进入可以产生不同的查询内中间结果。
- PHI 活跃栈内跳过某个 incoming 得到的局部 ValueTypes 结果，不能作为独立查询的完整答案。

本方案每次仍执行原 `factsAt` 的 seed cuts、`Processed` 查找/进行中标记、预算递减、按原顺序访问前驱、backedge/null-edge 判断、递归、guard 合并及 join。命中边缓存不会直接跳过整个 CFG 子图，也不会以固定 cost 扣减预算。这样，跨查询复用发生在独立的边操作层，查询内状态仍由原算法逐步建立。

`DefinedValues` 现在引用聚合对象中的跨查询证明缓存，证明工作图仍在查询内。guard 命中会省掉部分证明调用，因此它的键覆盖可以与无共享缓存的执行不同；每条实际保存的证明仍应等于相同输入的独立证明。不能为了要求所有容器逐字相同而恢复已经省掉的工作。

## 3. 启用前需要确认的条件

### 3.1 函数所有权和 epoch

缓存只服务构造时的那个函数，不在不同 IR 函数之间复用裸 `Value *` / `BasicBlock *` key。同一函数在稳定 epoch 内可以跨查询、跨只读 pass 使用，pass 边界本身不要求清空。

`clear()` 清空两张表并开启新 epoch，保留构造时的 mode。当前采用明确的整体失效策略，不实现 Facts 的 SSA users 闭包失效或 CFG 局部修复。调用方必须在相关修改、RAUW 或删除发生前清空，避免旧裸指针 key 被错误复用；随后在下一次查询前更新依赖分析。

| 变化 | 处理原则 |
|---|---|
| 只读查询、只读 pass，依赖分析仍有效 | 保留 |
| guard 的 klass/object 参数、比较、branch/switch 条件改变 | 清空 |
| 对象或条件的 SSA、identity/freeze 证明、属性/元数据改变 | 清空 |
| CFG 边、可达性、支配关系、前驱顺序、定义所在块改变 | 清空 |
| assume/guard、nonnull/dereferenceable/noundef 等 oracle 依赖改变 | 清空 |
| 删除、RAUW、函数生命周期结束 | 在 key 失效前清空或销毁 |
| VM 类型关系或 compilation 身份改变 | 清空 |
| 不能证明与这两类 helper 无关的修改 | 保守清空 |
| StableOracleEpoch 中的 LVI 清空、维护、替换或 oracle 策略改变 | 开启新 epoch |

Base 的选择性失效不能自动满足 Facts 的失效规则。类型 guard 不一定是查询对象的 SSA user，条件 PHI 的追踪还会读取 DT；LVI 又可能扫描块内其它指令。Base 与 Facts 的保留窗口应分别判断。

### 3.2 默认模式对 oracle 的要求

`GuardOnly` 不缓存 null 判断，保留原来的 oracle 请求。它可以使用会随调用而改善知识的 sound oracle，不额外要求 oracle 答案在 epoch 内固定；仍需遵守原接口“true 必须是正证明”的契约。

**默认模式不会减少 oracle/LVI 调用。** 它的收益来自 guard 根计算复用。是否值得使用，需要用实际条件追踪成本与缓存维护成本衡量。

### 3.3 StableOracleEpoch 的额外要求

该模式要求同 epoch 内，同一 key 的完整 `isNullEdge` bool 稳定；跳过已完成的重复查询也不能改变后续查询需要的 oracle 状态。一般的 `IsNullEdgeOracle` bool 接口只承诺证明正确性，不自动承诺这两点。

对当前 `LVINullEdgeOracle` 使用的 pointer edge 路径，可以采用以下具体合同：

1. 使用同一 LVI、AssumptionCache 和 DataLayout；IR、属性/元数据、CFG/DT、assume/guard 以及所有相关输入保持不变。
2. 不调用 `clear`、`forgetValue`、`eraseBlock`、`threadEdge`、`releaseMemory`，也不替换分析或触发 Value 删除/RAUW 的回调失效。
3. 查询串行完成。oracle 固定查询 `getPredicateOnEdge(EQ, V, null, From, To, nullptr)`，不在相同 key 下更换策略或上下文。
4. 可以执行其它只读 LVI 查询填充新条目；当前实现不会因此重新求解已有的完成条目。

当前源码的依据是：pointer 的 edge-local 条件处理只读 IR；需要的 `(V, From)` block 结果在首次查询完成后已缓存，500 工作项截断也会缓存 overdefined；命中后的 assume/guard 精化在副本上以 `UseBlockValue=false` 进行。固定输入下，重复 pointer edge 查询不会重新求解已有项。这个结论限定于当前实现和上述路径，不是对所有未来 LVI 实现及任意自定义 oracle 的泛化保证。

## 4. 已完成的临时原型验证

以下结果来自迁入仓库前的独立原型，位于 `/tmp/facts-edge-cache-prototype/`；它们是方案证据，不代替保留版的编译和仓库回归。原型名称 `FactsEdgeCache`、可修改 mode 和 `invalidate()` 并非最终 API；保留版采用 `JavaTypeFactsCacheV2`、固定 mode 和 `clear()`。

原型使用最新版 V2 的独立副本，只在两个 helper 外层增加查表。对比原版完整 `JavaType`，不只比较 `Klass`；每次顶层对比清空 Base cache，以隔离边缓存收益。普通案例使用真实 `LVINullEdgeOracle`，另有稳定/动态自定义 oracle 用于状态与契约测试。

覆盖共享前缀、同 block 重查、多对象、低/高预算切换、循环 PHI、不可约 CFG 多入口、switch guard、条件 PHI 循环、guard 修改、CFG bypass 和定义位置移动。结果如下：

| 检查 | 实际结果 |
|---|---:|
| 完整 JavaType 相等比较 | 162 次通过 |
| 查询内状态比较 | 106 次通过 |
| GuardOnly 与原版的完整 oracle 请求轨迹比较 | 80 次通过 |
| 每种 mode 的主查询数 | 80 |
| 每种 mode 的 guard 请求 / 命中 | 218 / 171 |
| GuardOnly 原版 / 缓存版 oracle 调用 | 218 / 218 |
| StableOracleEpoch 原版 / 缓存版 oracle 调用 | 218 / 47 |

162 次包含两种 mode 各 80 次主查询，以及动态 oracle 案例中两次恢复正确行为的检查。动态 oracle 在不变 IR 上由 false 变 true、却不切换 epoch 时，测试故意观察到了 stale 答案；禁用 null memo 或开启新 epoch 后恢复与原版一致。这个负例验证额外契约的必要性，不是实现符合契约时的正确性失败。

106 次状态比较检查剩余 Facts/Phi 预算、`ConditionDepth`、`ValueCycles`、`Processed` 的完整键/optional 状态/类型，以及 ValueTypes、BaseTypes 和活跃集合。DefinedValues 允许键覆盖不同，但逐条与独立证明核对。额外覆盖初始非空 `Processed`、预算 0、活跃循环占位符，以及嵌套 guard 的深度 1/32 绕过根缓存。

源码审计还确认原型的 `factsAt`、`phiValueType`、`valueDimension`、条件追踪及原 helper 算法体未被重写，缓存参数显式经过查询入口和 QueryContext 传递。原型审计只针对它当时的源码快照；仓库实现需要重新检查。

## 5. 真实 LVI 的补充验证与结论更正

### 5.1 不同历史的精度差异

`/tmp/facts-cache-epoch-lvi/probe.cpp` 构造 600 层最终恒为 null 的 select。IR 完全相同时：

- 冷 LVI 直接查询根得到 unknown。
- 先每 100 层预热，再查询根得到 true。
- 冷根先缓存 unknown，再补查前缀，根仍为 unknown。
- 清空后直接查询根又得到 unknown。

源码中的 500 工作项限制及 overdefined 缓存解释了这个现象。**它证明首次求值历史和清空前后可能产生精度差异；不能据此断言，同一 LVI 稳定 epoch 内跳过重复查询会改变结果。**

另一个真实 LVI 实验在条件与其 noundef use 之间插入 32 条未使用、没有相关 SSA 依赖的 add。null 判断由 true 变 unknown，因为 ValueTracking 的指令扫描被截断。这说明“不是对象的 SSA user”不足以证明一个修改对 Facts 精度无关；它是修改前后的实验，也不是固定 IR 下重复查询不稳定的反例。

### 5.2 相同初态、相同外部序列的配对实验

`/tmp/facts-cache-epoch-lvi/same-epoch.cpp` 为每个 fixture 建立两个初始为空的独立 LVI/AC，使用相同不可变 IR：baseline 每次调用真实 LVI；candidate 只在每个 key 首次出现时调用，之后 memo 返回。每个请求都比较答案，同时检查 baseline 同 key 的答案在首次完成后不变；后续新 key 也比较，因此覆盖跳过重复对后续求解的影响。

| 序列 | 请求数 | candidate 实际调用 | 跳过重复 | 对比 |
|---|---:|---:|---:|---|
| 深 select，先根后前缀 | 2,400 | 600 | 1,800 | 全部相等 |
| 深 select，顺序查询 | 1,200 | 600 | 600 | 全部相等 |
| 深 select，随机排列 | 4,800 | 600 | 4,200 | 全部相等 |
| logical branch、assume、select、freeze、dereference | 260 | 13 | 247 | 全部相等 |
| 相互引用的循环 PHI | 240 | 12 | 228 | 全部相等 |
| 合计 | 8,900 | 1,825 | 7,075 | 全部相等 |

深 select 的 root-first 和随机序列包含预算截断后的 unknown。没有发现满足合同的同 key 答案变化，也没有发现跳过重复使后续新 key 结果变化。该实验支持当前 pointer edge 路径的源码分析，仍不是所有 LLVM IR 和所有 LVI API 的形式化证明。

## 6. 性能指标和限制

需要分别记录 guard/null 请求、命中、实际计算、因非根上下文而绕过，以及 clear 次数、丢弃条目数和存储开销。命中率应区分同查询与跨查询复用；仅有总体高命中率不能证明跨 pass 收益。模式也必须明确，否则 GuardOnly 的零 null 命中容易被误读。

原型中 StableOracleEpoch 将 oracle 回调从 218 次降到 47 次，说明可以避免重复入口。这个数不是 LVI 内部 cache miss、`solve()` 次数或 CPU 时间；部分 oracle 本身可能走结构 fast path，已有 LVI cache 也可能早已命中。8,900 次配对实验是查询序列等价性实验，同样不是时间 benchmark。

本方案仍遍历原来的 Facts CFG，仍消耗原来的逻辑预算。它不解决频繁 IR 修改导致的短 epoch，也不声称减少的 JavaType 包含时间全部是整个优化 pipeline 的净收益。最终应分别测：

- JavaType/边缓存冷暖和 LVI 冷暖的组合；
- 无修改、多次相关修改、跨只读 pass 三种使用窗口；
- oracle 入口、实际 LVI solve/work items、缓存维护成本；
- consumer 时间及完整 pipeline 时间。

以下时间收益限制仍成立：接口接入和语义回归不等同于真实 workload 性能提升。Analysis使用当前LVI稳定契约启用StableOracleEpoch，失效及重验证见四缓存设计文档。

## 7. 第一阶段保留版验证结果（历史）

已执行：

```sh
cmake --build build/build-ninja-release --target JavaTypeQueryTests -j 2
build/build-ninja-release/unittests/IR/JavaTypeQueryTests \
  --gtest_output=json:/tmp/facts-v2-retained-test-results.json
```

目标编译通过。V2 共 27/27 项测试通过，其中新增 7 项 Facts 回归：真实 LVI 双模式与共享边、预算/PHI/不可约循环/switch、动态 oracle、guard/CFG 修改、RAUW/删除、定义点移动、原始 PHI 输入 key 身份。测试按完整 JavaType 与原版比较。

全套结果为 73/74。唯一失败是既有 V1 用例 `JavaTypeQueryTest.CachedEntryNormalizesFreeze`，此前已在不链接 V2 的独立程序复现（`/tmp/javatype-v2-legacy-baseline/`）；不属于本次 Facts 改动。本次没有修改 V1 或该测试。

与任务开始状态逐文件 SHA256 比较，原版 JavaType.cpp/.h、LVI、LVINullEdgeOracle、原版 CSV、已有 CMake 修改及 SCC-getBaseType.md 全部未变。保留版的 factsAt、phiValueType、valueDimension、computeNullEdge、computeEdgeGuard、isProvenDefined 主体与已验证原型一致。审计记录为 `/tmp/facts-v2-retained-boundary-audit.json`。原型的内部状态检查与仓库公开接口回归是两组独立证据，不混用计数。
