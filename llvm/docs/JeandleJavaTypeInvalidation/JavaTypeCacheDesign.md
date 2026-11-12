# JavaType 四类缓存及失效契约

本文件描述当前实现。基础类型、definedness、条件追踪及 CFG 查询共同使用
`llvm/lib/IR/Jeandle/JavaType.cpp` 中的一套求解算法；
`CachedJavaType.cpp` 保留完整的缓存查询包装：函数绑定、Base 查询
起止统计以及 Final 查找和发布。四类缓存、Facts 的查找/写入策略、
监控和失效仍实现在独立的 `JavaTypeCache.h/.cpp`，Analysis 接口不变。

## 组织与查询入口

`JavaTypeCache` 是单个 Function 的聚合所有者，分别持有四个独立类：

| 成员 / 类 | 保存内容 | 复用边界 |
| --- | --- | --- |
| `Base` / `JavaTypeBaseCache` | `Value* → JavaType` 的基础类型结果 | 相同 IR、VM 类型环境；修改后可保留不受影响的值 |
| `Defined` / `JavaTypeDefinedCache` | `Value* → bool` 的完成 definedness 证明 | 同上；`false` 表示未能证明 defined |
| `Facts` / `JavaTypeFactsCache` | `(V, BB)` 的累计路径事实；边缓存保留为另一查询模式 | 稳定 oracle 下跨查询复用；IR/oracle 修改后清空 |
| `Final` / `JavaTypeFinalCache` | `(V, ContextBB)` 的完整顶层查询结果 | 通知之间复用；IR 修改或 oracle 维护后整体清空 |

Analysis 及现有调用方仍使用最外层的单个缓存引用：

```cpp
JavaType getCachedJavaType(Value *V, DominatorTree *DT,
                            Instruction *Context, IsNullEdgeOracle IsNullEdge,
                            JavaTypeCache &Cache);
```

缓存包装先处理函数绑定和 Final 命中，开始 Base 查询统计后，调用
`JavaType.cpp` 新增的共享求解重载；返回路径由包装负责结束统计和
发布 Final：

```cpp
JavaType getJavaType(Value *V, DominatorTree *DT, Instruction *Context,
                     IsNullEdgeOracle IsNullEdge, JavaTypeCache &Cache);
```

原来的四参数 `getJavaType` 和 `sharpen` 继续使用查询内的本地存储。
五参数共享求解重载借用外部的 Base / Defined，并在 Facts 计算点调用
独立缓存类。它不处理 Final、函数绑定或查询起止管理；这些策略继续留在
缓存包装中。原文件新增的求解适配辅助代码单独分区；原有算法只增加
必要的参数、存储选择和计数，不再维护第二份求解器。

`DefinedMemo` 是文件内的存储选择器：普通查询使用自己的本地 bool 表，
缓存查询借用 `JavaTypeDefinedCache` 的表并记录计数。查询上下文同样
选择本地或外部的 Base / Defined；进行中的求解状态仍不跨查询共享。

预算、递归栈、SCC 工作图、`Processed` 和 `ValueTypes` 仍是单次查询状态。
只有完整顶层结果进入 Final；递归中的 `valueDimension` / `factsAt`
不读取 Final。预算只限制底层求解工作，不参与 Final 的键及查找、插入、
删除接口。Context 用所在块作键，对应当前算法按块求路径事实的语义。
改变求解预算不会使已有答案失效，也不会新增另一个 Final 条目。
当前仍允许缓存底层截断后返回的保守顶层答案；提高预算不会自动细化
这样的缓存答案，需要重新求解时可显式清空 Final（Analysis 使用 clear）。

每个缓存类拥有自己的累计 `Stats`，默认关闭。聚合类提供统一开关及
`resetStats()`；`clear()` 清结果但保留累计计数。Base 的跨查询命中细分
需另开详细统计，才建立查询开始时的键快照。Analysis 的 Observer
汇总这些计数的差分及查询时间；无 Observer 时不复制计数快照、不读时钟。
Facts 计数包含路径命中及边 helper 请求/计算，不能直接解释为 LVI 内部
求解次数或耗时。

## Base 与 Defined：共享修改前的 users 闭包

聚合类在 IR 修改前，从通知的值出发收集完整旧 SSA users 闭包，
供 Base、Defined 选择性失效；Facts 和 Final 无需闭包，直接整体清空。
遍历不因值不是指针、
或值没有缓存条目而停止；整数条件和 poison 相关 flag 修改也会传播。
Base 为空时仍处理 Defined。

普通修改只删除闭包中的 Base / Defined 键。兼容现有只提供修改源的
CFG 通知时，两者额外丢弃派生结果，保留不受影响的叶子结果。
Base 的 returned-argument call 是 identity 表达式，不作为独立叶子保留。
Defined 的冻结结果等是否为叶子，按其自身证明规则判断。

超过 4096 个值或 16384 条 use 边、遇到非局部修改或跨函数值，
聚合类回退全清。该预算仅限制失效工作，不修改查询求解预算。

## Facts：累计路径复用，修改时保守清空

稳定 oracle 下，默认保存完整的 `(V, BB) → JavaType` 累计路径事实。
`factsAt` 在 seed cuts 后、查询内 `Processed` 和前驱遍历前查表；命中
直接返回，跳过整段前驱求解。不再限制根 Value 为 Argument/entry-select，
也不以全函数块数作为准入条件。预算耗尽或未切断循环设置查询内
`FactsTruncated`，之后不再发布块结果；此前完成的结果和完整 unknown
仍可复用。命中不消耗预算，暖查询可能比同预算冷查询更精确。

路径模式直接执行边计算，不同时填边表，以减少重复写入。
`setPathEnabled(false)` 可关闭路径复用并继续使用下述边缓存。

两个表分别保存根 guard 和 null-edge 判断，键都保留实际传入的
`(V, From, To)`。它们表示沿哪条边成立的事实，单个 Context 不能区分
同一块的不同入边及其分支方向。

缓存策略由 `JavaTypeFactsCache::getNullEdge` 和 `getGuard` 管理：
它们接收边和 Value，以及一个执行原计算的 `Compute` 回调；负责模式
检查、命中、未命中后的写入和统计。`getGuard` 还接收当前条件追踪深度。
原 `JavaType.cpp` 保留 `computeNullEdge` / `computeEdgeGuard` 的算法，
在未共享 Paths 时将原计算交给上述方法包装，路径模式或无缓存时直接计算。

根 guard 仅在 `ConditionDepth == 0` 时读写缓存，递归条件追踪保留
原来的深度约束。默认 `GuardOnly` 不缓存 null 判断，也不启用 Final；
因此允许任意随调用变化的 oracle。

显式选择 `StableOracleEpoch` 后，调用方承诺通知之间 oracle 判断可复用，
才允许共享 Paths、null 判断及 Final。IR 修改时 Facts 整体清空。只维护/重置 oracle、
IR 不变时，也必须调用聚合类 `notifyOracleChanged()`。

## Final：轻量结果表，通知时整体清空

保留缓存实现的独立 Final 类、外部持有方式和统计开关，内部使用轻量的
`DenseMap<(Value*, ContextBB*), JavaType>` 结果表。只有完整顶层查询读写
Final；递归求解继续使用当前算法，不读取或发布 Final。
查找和发布只发生在 `CachedJavaType.cpp` 的顶层包装中，原求解器
不读取或写入 Final。命中直接返回结果，未命中完成求解后插入；插入
不再遍历操作数或 CFG 前驱来收集依赖，也不维护 `ByValue` / `ByBlock`
反向索引。

任意 IR 修改通知都整体清空 Final，包括普通指令修改和 CFG 结构修改。
`notifyOracleChanged()` 同样清空 Final 与 Facts。Final 不再保存 null-edge
观察或待验证标记，也不在命中时调用 oracle 重验证。Base / Defined 的
选择性失效和 Facts 的现有策略保持不变。

这是轻量存储与保守失效的取舍：减少每次发布结果的依赖收集、索引写入
和观察记录，代价是不能跨修改保留无关 Final 项。相同有效期内仍可跨
查询、跨正确保留分析的 pass 复用。修改通知同时清理 LVI，因此也整体
丢弃 Final，避免复用依赖旧 oracle 状态的结果。

Final 只记录共性的命中、未命中、插入、删除、失效和清空计数，不再
提供重验证、验证失败或依赖收集超限旁路计数。失效返回被清除的项数；
不再扫描幸存项标记验证，因此 `FinalTypesSlotsScanned` 不再增加。

## Analysis、PassManager 与调用方职责

`JavaTypeAnalysisResult` 持有聚合缓存，使用 `StableOracleEpoch`，查询
走缓存实现。其主动修改通知转发给聚合类，并执行 `LVI.clear()`；
DT 仍由调用方在下一次查询前更新。完整 `clear()` 清四类缓存及 LVI。
`-jeandle-verify-java-type-cache` 使用同一求解器的无跨查询缓存入口重新
计算并比较完整结果。若结果不同且冷查询实际发生 Facts 预算或未切断
CFG 循环的截断，该次比较不报错，也不计为验证通过；未截断的差异仍报错。
累计路径命中省下预算，因此即使配置不变，暖查询也可能比冷查询更精确。
这类跳过比较不构成结果正确性的证明；需要精度对照时应选用预算充足、
完整求解的参考查询。

普通 IR API 不会自动调用 JavaType 的失效方法。这里有两种不同入口：

1. `Result.invalidate(Changed)`：pass 主动调用，在修改前读取旧依赖图，
   选择性处理 Base / Defined，整体清空 Facts / Final。修改后在同一
   pass 内再次查询需要这条路径。
2. `Result.invalidate(F, PA, Inv)`：PassManager 在 pass 返回后，依据
   `PreservedAnalyses` 判断整个分析结果是否应丢弃；JavaType、DT 或 LVI
   未被有效保留时，Result 失效。该回调不会从 IR 自动推导修改集。

因此跨 pass 保留要求 pass 正确维护缓存及其依赖，再声明 preserve。
不维护的 pass 可以让分析在边界失效；不能在修改后继续使用旧 Result，
再指望 pass 返回时的失效修复此前的查询。`DenseMap<Value*, ...>` 不会
自动监听 `setOperand`、metadata/attribute 修改、RAUW 或删除。

```cpp
// 修改既有指令：通知必须在修改前，旧 users 图此时仍可遍历。
Result.invalidate(*I);
I->setOperand(Index, NewValue);

// 插入或移动还要通知目标块，覆盖新出现的块内事实。
Value *Changed[] = {MovedInstruction, DestinationBlock};
Result.invalidate(Changed);
// 执行移动；若同时改变 CFG，改用 CFGChanged=true 并维护 DT。
```

所有语义修改通知走聚合/Analysis 入口。单独清某个子缓存只适用于容量
管理等不改变 IR/oracle 的操作。VM 类型环境或未知范围变化使用全清。
不得在查询进行中修改 IR、失效或逐出 SCC 求解中的条目。

## 验证与限制

本次调整需要验证 Final 在相同有效期内命中、不同上下文分别缓存、
普通修改与 CFG 修改后清空、oracle 维护后清空，以及修改后冷重算与
无跨查询缓存的完整结果一致。原有依赖索引、选择性保留、重验证和依赖超限旁路
测试应改为覆盖新的失效契约。Base / Defined / Facts 及 Analysis
生命周期的回归继续保留。V1 查询实现、专属测试、微基准和回放程序已
移除；历史实验数据仍保留，复现旧版本时使用对应历史提交。

历史基线（调整前的依赖索引版本，并非本次验证结果）：

- `JavaTypeQueryTests` 共 83 项，82 项通过；缓存实现 的 36 项全部通过。
  唯一失败是既有直接 V1 `JavaTypeQueryTest.CachedEntryNormalizesFreeze`。
- `llvm/test/Jeandle` 的 lit 回归：807 项，782 通过、25 unsupported，
  0 失败。
- 历史原版对照测试观察到 LVI 清理或预热能改变查询精度。这一行为仍
  是 oracle 维护后丢弃 Facts / Final 的原因，但当前不再通过重验证处理。

历史轻量 Final 验证（2026-11-02，删除 V1 前）：

- `cmake --build build/build-ninja-release --target JavaTypeQueryTests opt -j 2`
  构建通过。
- `JavaTypeQueryTests` 共 84 项，83 项通过；缓存实现 的 37 项全部通过。
  唯一失败仍是既有直接 V1 `JavaTypeQueryTest.CachedEntryNormalizesFreeze`。
- `llvm/test/Jeandle` 的 lit 回归共 808 项，783 通过、25 unsupported，
  0 失败。TCE 的统计断言已同步为修改后清空全部 Final 项。
- 原版 JavaType 两文件、直接 V1 两文件和原版结构 CSV 与任务起点
  `79258fc1a` 一致；Cached CSV 保持四列。

清理后的构建与回归结果见后文各阶段验证记录。这里不宣称性能提升；应比较
原版、依赖索引历史版本、关闭 Final 的 缓存实现 和
轻量 Final 实现，并在相同求解器、Base / Defined / Facts 配置下测量
总耗时和修改后的重算成本。
当前没有增加全局容量上限或基于访问频次的逐出机制。原版结构 CSV
保留为迁移前基线，缓存接入的新增和调整记录在 Cached 结构 CSV。

## V1 清理验证（2026-11-02）

删除旧查询实现及其专属测试/回放工具，保留并迁移有用的失效和 Analysis
回归到当前缓存 API。`JavaTypeQueryTests` 73/73 通过；完整 Jeandle lit
回归 783 通过、25 unsupported、0 失败。旧 V1 freeze 失败用例不再属于
当前测试集；缓存实现 中可能 poison 与 noundef 输入的 freeze 正反例继续保留。
历史性能数据未改写，旧实现可从 Git 历史复现。

## 求解器合并验证

原四参数查询、`sharpen` 与缓存重载现在共享原文件内的算法，原有缓存实现
缓存和 Analysis 生命周期测试继续验证复用及失效。合并后的构建、原版
IR 单元测试、缓存单元测试和 Jeandle lit 结果见下一节；前面的历史
结果不能代替本阶段验证。

## 共享底层接口验证（2026-11-02）

缓存入口与策略继续独立放在 Analysis 的缓存文件中；原 JavaType 文件仅
增加必要的共享存储/参数适配，以及单独分区的底层求解接口。

- `JavaTypeQueryTests`、`IRTests`、`opt`、`llvm-as` 构建通过。
- 缓存与 Analysis 查询回归 76/76 通过，包含新增的底层入口不发布 Final、
  freeze 正反例、Context 隔离和无缓存查询不受外部 memo 影响测试。
- 原 `JavaBaseTypeTest` 回归 69/69 通过。
- 完整 Jeandle lit 回归 783 通过、25 unsupported、0 失败。
- 11 个核心算法函数体与合并前原版逐字一致；Base、Defined 和
  valueDimension 只增加共享存储及统计适配，求解、循环和预算语义不变。
- 原版结构 CSV 保持不变；Cached 结构 CSV 继续使用四列。

尚未重新运行 perf；本次验证不构成性能提升的证据。按当前约定，直接
使用现有缓存类，库依赖方向的整理留待后续讨论。

## 消费者缓存接入审查（2026-11-03）

五个消费者的九个 getJavaType 源码调用点全部通过
`FAM.getResult<JavaTypeAnalysis>(F)` 获取分析，再调用
`JavaTypes.getJavaType`；没有直接调用无缓存入口。

| Pass | 查询点 | 修改后的生命周期 |
| --- | --- | --- |
| TypeCheckElimination | 1 处 | 折叠前批量通知；维护后 preserve JavaType、DT、LVI |
| CHADevirtualization | 2 处 | 修改通知覆盖 assume、参数、替换/删除和 CFG；更新 DT/LVI 后继续查询并 preserve |
| ConstantFieldFolding | 2 处 | 替换、删除前通知，pass 内可继续复用；有修改时只 preserve CFG，JavaType 在边界失效 |
| RecoverTypeInfo | 1 处 | 所有查询在 metadata 写入前完成；有修改时只 preserve CFG，JavaType 在边界失效 |
| CopySpecialization | 3 处 | arraycopy 源/目标及 instance-clone 源类型统一查询；先收集全部 CopyFacts，再改写；有修改时返回 none，JavaType/DT/LVI 在边界失效 |

RecoverTypeInfo 的 PHI 入边 `sharpen` 查询仍由其本地 EdgeSharpenCache
管理，语义不同于整值 getJavaType，不是同类查询绕过缓存。
CopySpecialization 的三处查询已加入同一 Analysis 与统计路径。所有
CopyFacts 在第一次改写前完成，后续扩展不再查询 JavaType，因此不需要
pass 内逐项失效；它有修改时不保留任何分析，由 FAM 丢弃旧结果。
新增消费者无需添加统计字段或专属计数器，查询事件会自动进入现有
Function 累计和进程汇总。FAM 边界丢弃不生成显式失效事件，
`invalidation requests: 0` 不意味着保留了缓存；存活状态由 FAM 或
cache-boundary 另行检查，条目数量只是最近事件的快照。

接入 CopySpecialization 之前的命名清理验证为 JavaTypeQueryTests
76/76、原 JavaBaseTypeTest 69/69 通过；完整 Jeandle lit 回归 783 通过、
25 unsupported、0 失败。这些是前一阶段结果，不能代替新增消费者验证。

新增 [copy-specialization/cache-reuse.ll](../../test/Jeandle/copy-specialization/cache-reuse.ll)
覆盖同块两次源查询的 Final 复用、改写后的 FAM 丢弃，以及缓存、禁用
缓存和严格验证模式的输出一致性。


## CopySpecialization 接入验证（2026-11-03）

- `JavaTypeQueryTests` 构建通过，79/79 通过：缓存测试 40 项，查询与
  Analysis 测试 39 项，含新增的无 copy、bulk clone 和字段标量化场景。
- CopySpecialization 定向 lit 11/11 通过。新增 `cache-reuse.ll` 覆盖同块
  Final 复用、边界丢弃及缓存/禁用缓存/严格验证的 IR 输出一致性。
- 已有 clone、整数宽度、引用数组 fixture 增加缓存与禁用缓存输出对照；
  `integer-width.ll` 还验证 arraycopy 源/目标各进入统一统计，两个相关
  函数各两次查询，而 payload array-clone 分支不查询 JavaType。
- 完整 Jeandle lit 共 809 项：784 通过、25 unsupported、0 失败。

本轮仅接入消费者与回归，底层求解算法、缓存类和统计 schema 未改；
新增三处查询自动进入原统计链路。未运行新的 perf 或计时实验，历史
结果保持原样，不能据此量化新增接入的性能收益。
