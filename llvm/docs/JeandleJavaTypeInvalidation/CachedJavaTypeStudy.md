# JavaType 缓存：第一阶段复用实验记录

> 本文保留第一阶段的实验条件和结果。当前四类缓存、统一接口及 Analysis 接入见 [JavaTypeCacheDesign.md](JavaTypeCacheDesign.md)；V1 专属实现及测试已移除，下面的旧接口、历史路径和“尚未接入”描述仅对应当时状态。

本次以工作区最新版 `JavaType.cpp` 为语义基准，按
`/home/zjj/.codex/skills/jeandle-javatype-cache/SKILL.md` 开发。
实验设计、Base 依赖、CFG/Facts 三个方向分别由 subagent 研究，再汇总实现与验证。
保留的改动包括 Cached 的 Base 缓存管理、诊断接口和可选 Facts 边级缓存。
Facts 方案先在 `/tmp` 验证，再按用户要求保留到现有缓存实现；详见 [FactsEdgeCache.md](FactsEdgeCache.md)。
原版查询、公共 JavaType 定义、LVI、V1 和消费者 pass 均不改。

## 1. 实验目标：减少可避免的 miss，并检查实际少做的工作

命中率必须标明层次和分母。一次 `getJavaType` 内就可能有许多 Base 命中，
把这些计为跨查询收益会掩盖每次查询重新求解的问题。
不同根可以全部 miss，却复用共同的深子图；一个便宜的 argument 高频 hit 也不一定带来时间收益。

本次缓存实现的统计约定：

| 观察值 | 定义与解释 |
|---|---|
| `Info.BaseHits/BaseMisses` | 每次 `getBaseJavaType` 入口是否已有结果，包括 contextual 查询中的入口；不含 SCC 内部回读 |
| `InputHits/InputMisses` | DFS 输入边命中完成结果 / 需要发现新节点；尚未完成的循环依赖不计作 miss |
| `OpenNodeEdges` | 指向尚在求解的 SCC 节点的边，属于算法工作，不是重新求解已有结果 |
| `PriorQueryHits/CurrentQueryHits` | 将入口和输入边命中按条目是否在顶层查询开始时已存在分类；不能再与前两项相加 |
| `NodesEvaluated` | 直接叶子求值和新发现 Base 节点数，排除单纯查表 |
| `InputEdgesVisited` | DFS 实际处理的边，等于 InputHits + InputMisses + OpenNodeEdges；不含 SCC 细化 |
| `CyclicSCCs/RefinementSteps` | 实际求解的循环分量数及内部 worklist 出队处理次数（包括结果未变化的处理） |
| `EntriesAdded` | 一次顶层查询后的完成条目净增量，不把 SCC 中间更新当作新结果 |
| `BaseRemoved/ValuesVisited/UsesVisited/FullClear` | 失效擦除量、遍历量与整表回退；由 invalidate 返回 |
| null oracle 调用、LVI solve、时间 | 三种不同成本；减少 oracle 调用不等于同比减少 solve 或 CPU |

`PriorQueryHits` 需要查询开始时的 key 快照，只在传入可选 Diagnostics 时启用。
正式计时传 `nullptr`，关闭快照和详细工作量计数；`Info` 的入口计数仍然存在，不能称为完全无统计开销。
缓存实现 不共享完整块 Facts/Final，因此这两层的共享命中率应显示 N/A。可选边缓存的计数使用独立的 JavaTypeFactsCache::Stats。

推荐同时报告：

- 入口 miss 率，以及依赖输入 miss 率，分别计算分母。
- 跨查询复用比例：PriorQueryHits / 完成结果的入口与输入查找总量，排除 OpenNodeEdges。
- 工作量减少：`1 - warm.NodesEvaluated / cold.NodesEvaluated`，并列输入边和 SCC steps。
- 缓存净收益：`1 - warm.totalCPU / cold.totalCPU`，总成本包括查询、失效、清空、分配和销毁。
- 实际跨 pass 的 producer/consumer pass ID、命中 key、失效事件与原因；跨函数不共享 Base 结果。

miss 原因在诊断 replay 中按事件区分：首次查询、实验刻意清空、pass 边界清空、相关变更、
保守整表清空、无法分类。不能仅从一次查表失败推断原因。当前无容量驱逐，DenseMap 扩容不是 eviction。
Unknown 是一种可完成、可缓存的结果，不能计入“未缓存”。

### 对照与案例

使用同一缓存实现 算法比较 cold/warm，原版仅作为逐查询语义 reference，避免混入 V1 与最新版算法差异。

1. 每查询清空、查询间保留：隔离跨查询复用。
2. 每次编辑全清、精确通知后选择性失效：隔离失效范围。
3. pass-local、cross-pass：在两阶段 API replay 中先验证生命周期；接入真实消费者后再测真实 pipeline。
4. contextual 查询采用 Base cold/warm × LVI cold/warm 的 2×2 对照；两模式保持相同 IR、预算和查询次序。

解析和构造放计时区间外；正确性诊断启用 fresh reference，计时关闭 reference 和详细诊断。
预先固定规模、轮数和配对顺序，保存 source/binary/IR hash、逐轮结果及 CPU affinity。
pass 计时与整个 opt 进程（包括 IR 解析）的计时分别报告。

| 案例 | 要验证的机制 |
|---|---|
| 便宜 typed argument 重复、宽浅无共享多值 | 命中机会有限或单次收益很小时的维护成本 |
| 深 select DAG 同根重复、不同根共用深子图 | 入口命中和依赖命中分别如何减少实际求值 |
| Unknown 重复、null/poison/undef arm | 完成结果与类型精度正交；保留原版非空契约 |
| SCC 成员交替、逆序查询及成员输入变化 | 完整分量复用、正确失效、无查询顺序依赖 |
| freeze、整数条件、returned call seed | 不能遗漏证明依赖或独立种子 |
| metadata/参数属性变化、RAUW/删除 | 修改前通知覆盖旧 users 图，避免悬空 key |
| 无关编辑、纯拆块、局部 PHI 修改 | 保留不受影响结果，量化额外失效 |
| 同一值不同 guard 位置、切换预算 | Base 共享不泄漏上下文事实，不改变原版截断语义 |
| 两个只读 pass、有修改的 pass 边界 | 区分有能力跨 pass 保留和实际出现跨 pass 命中 |

## 2. getBaseJavaType：算法与复用条件

实现见 [原版 JavaType.cpp](../../lib/IR/Jeandle/JavaType.cpp)。

Base 读取 Argument 参数属性、Call/Invoke 返回属性、Load metadata 或 oop-handle VM 信息作为 seed。
PHI/select 合并输入，identity 表达式转发输入；literal null/poison arm 在非空 oop 契约下跳过，
undef 保持吸收性。常量 select condition 只选择对应 arm。

求解使用显式 DFS 栈与 path-based SCC 检测，没有沿值图递归消耗 C++ 栈：

1. 查已完成 memo；缺失时发现节点，并保存该节点独立 seed。
2. 逐输入求解，已完成输入可立即复用；unknown 可使当前合并提前结束。
3. 无环节点合并输入并与 seed 相交；freeze 只有 operand 被证明 defined 才能转发。
4. SCC 先用完成的外部输入构造共同上界，再将各成员 seed 传播，工作队列细化至稳定。
5. SCC 中间值暂写同一表，但只在整个同步求解返回后对外可见；不能在求解中途并发查询/失效。

图发现为 O(V+E)；总成本还包括 SCC 重复细化、类型集合操作和 VM 回调，不能把整个算法一概称为线性。
Definedness 是另一套基于依赖图、grounding 和不支持输入反向传播的证明；本次仍为查询局部。

可跨查询保存的不仅是顶层结果：完成的叶子、共享子图节点和完整 SCC 成员都可复用。
DefinedMemo 的完成证明也具有上下文无关的复用条件，但需要同步维护其证明依赖和失效；本次不延长它的生命周期。
编译期间稳定的 VM 类型查询、接口闭包也可能单独 memo，是否划算应统计重复回调及其成本；
不能把会产生副作用的 VM 回调一概缓存。DFS frames、SCC roots、pending worklist 和未完成分量不能跨查询保留。

### 指令与失效矩阵

| 指令/信息 | 依赖与需通知的变化 | 可以保留的情况 |
|---|---|---|
| Argument | java-klass/exact、definedness 参数属性；通知对应 Argument | 无关 CFG/内存变化 |
| PHI | incoming values；修改输入值/数量通知 PHI，删除前通知自身 | 仅 incoming block 标签变化且 values 不变 |
| select | arm、常量条件选边；freeze 证明还读条件 definedness | 无关 CFG 重排 |
| freeze | operand 类型及完整 definedness 依赖 | 未改变上述依赖的移动/拆块 |
| bitcast、addrspacecast、零 GEP | identity operand；GEP 索引改变可能取消 identity | 位置变化；addrspacecast 的 definedness 仍遵循原版保守规则 |
| returned/invariant-group call | forwarded operand 与独立返回 seed 同时存在 | 无关变更；不能按 CallBase 类别一律保留 |
| 普通 Call/Invoke | 调用点 seed，definedness 可能读取 callee 属性/名字 | 无关内存、CFG 改动 |
| Load | metadata、oop-handle 地址/名称/ID；definedness metadata | 普通 store 不改变这些类型声明时无需因 alias 全清 |
| 整数运算/比较 | 可能只作为 freeze 的证明依赖，从未进入 BaseMemo | 仅能保留不在实际受影响 users 闭包中的结果 |
| Function/callee/global/VM 信息 | 存在非 SSA 字段依赖；枚举相关 call sites，或 clear | 本阶段不细分跨函数/VM 失效 |
| RAUW/删除 | 修改前通知旧值及旧 users 图；每个删除值都要通知 | 其余独立子图保留 |

关键反例：`add → icmp → select(pointer) → freeze`。
给 add 增加 nsw 会破坏 definedness，尽管 add 没有 Base 条目，仍必须失效 freeze。
另外，callee 的 `returned` / `noundef` 等属性可被调用点读取；callee Argument 的 users 不含 caller，
通知该 Argument 不够，应通知相关调用点或用 Function 根触发全清。

### 本次选择性失效

`JavaTypeCache::invalidate(Changed)` 在变更前沿完整 SSA users 图求闭包，然后按 key 擦除。
该图是 Base 与证明依赖的保守超集；不要求查询时维护新的反向依赖索引，也不扫描整张缓存表。
遍历超过 4096 个值或 16384 条 use、遇到非 Instruction/Argument 的非本地根时回退 clear。

CFG 本身不在 Base 的 key 中。调用方列出被改输入/删除的 PHI 和所有删除值即可；
仅通知旧 terminator 不足以涵盖它不作为 SSA operand 的 PHI 修改。纯拆块和不改 values 的边标签变化可保留 Base。
无法完整枚举修改集时 clear。调用方仍需为上下文查询更新 DT/LVI，但这不要求无条件丢弃无关 Base。

这不是最小语义依赖图：整数条件的改动可能同时擦掉一个类型本身未变的 select。
它以较小实现复杂度覆盖隐藏证明依赖。后续若该保守性成为主要 miss 来源，再测按类型/证明分开的依赖图，
不应为了少删几个 key 先漏掉 freeze 的依赖。多个编辑可在下一次读取前合并通知，减少重复遍历。

同一个函数、相关依赖未改变时，完成结果可以跨调用复用；外部 cache 被下一 pass 保留时可以跨 pass 复用。
本次没有修改生产 pass/FAM 接入，也没有把两阶段 API 复用声称为真实跨 pass 加速。

## 3. CFG/Facts：减少 LVI 触发的机会与边界

`getJavaType` 组合 value dimension 与查询块入口的 `factsAt`：

- value dimension 处理 PHI incoming 和 forwarder 定义点的事实。
- `factsAt(V, BB)` 先规范化身份表达式，处理入口/定义块/不可达快路径，再查 `(V, BB)`。
- 遍历前驱，跳过支配回边、确定 null 的边；递归前驱 facts，叠加 edgeGuard，再合并。
- `isNullEdge` 先调用 oracle，再作结构性支配 null 检查；本项目 oracle 通常使用 LVI。
- edgeGuard 追踪 instanceof/exact-klass 条件及 branch/switch 的结果；它本身不直接调用 LVI。

| 候选缓存 | 可避免的工作 | 持久化条件 |
|---|---|---|
| Final `(V, context BB)` | 整次重复查询，包括 value dimension 和 facts 中的 oracle 调用 | 所有类型、CFG、DT/oracle 依赖有效，处理预算/循环契约 |
| PathFacts `(V, BB)` | 共同前驱子图的遍历和 oracle 调用 | 完成、无活跃栈依赖；对 guard/CFG/定义位置/null 证明变化失效 |
| ValueTypes `V` | PHI incoming/定义点派生部分 | key 只有 V 不代表 CFG 无关；不得发布依赖活跃 PHI 栈的贡献 |
| 根条件 trace / edgeGuard | 条件识别、接口闭包等 | 完整 root trace，考虑 depth/visited/DT 和 IR 依赖；通常不直接减少 oracle 调用 |
| null-edge 证明 | 同一边的重复 oracle 查询 | 明确值/边/IR/oracle 的有效期；bool=false 混合非 null 与未证明，不能当完整非 null 证明 |

Facts 的失效范围不能照搬 Base 的 users 闭包。分支条件不一定是被查询对象的 SSA user；
移入 load/store、修改 call/assume/nullability 属性可能改变 LVI 的 non-null 事实；
CFG/支配变化、值的定义位置变化也会改变 facts 的切断条件。
无关编辑能否保留，取决于这些依赖是否真的无关，而非是否改变了指针操作数。
LVI.clear 可能只是结果驱逐，也可能伴随语义变化，不能仅凭对象是否存在判断 facts 有效。

未来可研究“函数不存在可识别 Java 类型 guard”的摘要，以证明 factsAt 只能返回空约束并省掉遍历。
这仍需覆盖全部 guard 识别形态及失效；即使没有类型 guard，PHI 的 null incoming 筛选也可能改善类型，
不能把整个 value dimension 的 null 查询一起跳过。本次未实现该方案。

### 隔离验证：直接搬出 memo 不成立

使用原版未修改源码快照，在同一临时 TU 中访问私有辅助函数，通过复制 Processed 模拟跨查询共享。
以下早期实验验证完整 Facts memo 的风险，该完整 memo 方案没有保留。后续保留的是边级缓存（见单独文档）。5 组探针均通过预期检查：

| 探针 | 实测结果 | 意义 |
|---|---|---|
| 无环、完整 facts 共享 | 查询下一块 oracle 4→1；同块再次查询为 0 | 共同前缀缓存确实能减少进入 oracle |
| 子查询预算截断 | 祖先仍保存 unknown；恢复预算后复用为 unknown，fresh 为 klass 22 | engaged 不代表未受截断影响；需传递截断状态 |
| 完整结果用于低预算查询 | warm 为 22，cold 为 unknown | 即使只存完整结果，也可能改变原版预算行为 |
| 活跃 PHI 栈的局部贡献 | 独立类型为父类 1，嵌套局部为 33；强行发布后错误地过窄 | 原版正确拒绝发布；不能绕过该保护 |
| 不可约 CFG 循环入口变化 | 根 A 为 22，嵌套 B memo 为 unknown；独立 fresh B 为 22 | 结果返回/写 memo 不代表独立于求解入口 |
| guard/CFG 修改 | guard 改后 stale22 / fresh33；将检查失败路径接入查询块后 stale33 / fresh unknown | 需要失效；清空后恢复正确答案 |

因此 Facts 方案需要分别规定：结果完成性、循环依赖、预算精度契约、失效范围。
保守精度下降与错误过窄是不同问题；若允许缓存改善低预算精度，需要显式批准这种行为差异。
本任务保留最新版截断语义，未把这些实验性行为接入缓存实现。
oracle 调用数是边界计数，本实验未测 LVI 内部新 solve 次数或 CPU 时间。

## 4. Base 缓存实测

全部使用 缓存实现 同一实现、同一查询/编辑序列，逐次比较原版 JavaType 的完整结果；编辑后验证 IR。

| 场景 | 策略 | 入口 hit/miss | 跨查询 hits | 节点评估 | SCC steps |
|---|---|---:|---:|---:|---:|
| 24 层共享 DAG，9 查询，含无关编辑和 metadata 改动 | 每查询清空 | 0/9 | 0 | 159 | 0 |
| 同上 | 编辑时全清 | 1/8 | 5 | 83 | 0 |
| 同上 | 选择性失效 | 4/5 | 8 | 55 | 0 |
| 双 PHI SCC，10 查询，含拆边和 incoming 变化 | 每查询清空 | 0/10 | 0 | 26 | 14 |
| 同上 | 编辑时全清 | 4/6 | 4 | 13 | 6 |
| 同上 | 选择性失效 | 7/3 | 8 | 7 | 4 |

57/57 次完整类型比较通过。选择性失效相对编辑时全清，节点评估分别下降 33.7%、46.2%。
这些是 Base-only 查询，oracle 调用均为 0，不据此声称减少 LVI 耗时。

另做真实 LVINullEdgeOracle 的 contextual 2×2：24 层 select，同一值在 guard 后 4 个位置查询 3 轮，预算 128。

| Base 策略 | LVI 策略 | 入口 hit/miss | 跨查询 hits | Base 节点评估 | oracle 调用 |
|---|---|---:|---:|---:|---:|
| 每查询清空 | 每查询清空 | 576/12 | 0 | 300 | 138 |
| 每查询清空 | 保留 | 576/12 | 0 | 300 | 138 |
| 保留 | 每查询清空 | 587/1 | 539 | 25 | 138 |
| 保留 | 保留 | 587/1 | 539 | 25 | 138 |

48/48 次与 fresh DT/AC/LVI 的原版查询完整相等。Base 求值减少 91.7%，但 oracle 调用没减少。
而每查询清空 Base 时入口 hit 率仍有 98.0%：这些主要是同一顶层查询内部的 memo 命中。
这说明优化实验应以跨查询命中和避免的工作共同衡量，不能只提高一个不区分来源的 hit 比例。
上述实验没有测时间，不构成生产编译加速结论。

## 5. 实现、验证与复现

当时涉及的修改（链接和命令使用当前名称，历史职责与结果以当时提交为准）：

- [CachedJavaType.h](../../include/llvm/Analysis/Jeandle/CachedJavaType.h)：外部持有 Base、修改前失效合同、可选诊断。
- [CachedJavaType.cpp](../../lib/Analysis/Jeandle/CachedJavaType.cpp)：完整 users 闭包失效、Base 语义入口/输入统计；SCC 求解不变。
- [CachedJavaTypeTest.cpp](../../unittests/IR/CachedJavaTypeTest.cpp)：原有 20 项测试覆盖冷/热、共享子图、SCC、证明链、CFG、删除、fallback 和上下文隔离；本次另增 7 项 Facts 回归。
- [CachedJavaTypeDataStructures.csv](CachedJavaTypeDataStructures.csv)：四列记录新增、调整、复用；原版 CSV 保持原样。

```sh
cmake --build build/build-ninja-release --target JavaTypeQueryTests -j 2
build/build-ninja-release/unittests/IR/JavaTypeQueryTests \
  --gtest_filter='CachedJavaTypeTest.*'
```

相关目标编译成功，缓存实现 20/20 通过。完整 JavaTypeQueryTests 为 66/67，通过之外的一项为旧测试
`JavaTypeQueryTest.CachedEntryNormalizesFreeze`：参数没有 noundef，原版 freeze 返回 unknown，
V1 入口无条件剥 freeze 返回 22。已构建完全不链接缓存实现的旧测试程序独立复现；不修改 V1 或原版来迁就此旧断言。

临时实验覆盖 Base 固定编辑序列（57 次查询）、contextual 2×2
（48 次查询）、Facts 反例与复用机会，以及不链接缓存实现的旧失败用例。
这些临时源码、逐事件记录、精确编译命令和原始路径保留在对应历史提交
的实验记录中，未作为当前查询实现或工具加入仓库。

相对任务开始快照验证 `JavaType.cpp`、`JavaType.h`、原版 CSV 未变；已有 CMake 修改保持原样。
原版 cpp 的 SHA256 为 `a32dda5470cf2f0af67558f9a3620b4058f1648fdc1cd4caafbf69ff44685b69`。
数据结构 CSV 均符合“名字、功能、成员变量、成员函数”四列。公开 JavaType 类型与类型运算继续复用原实现。
缓存实现 尚未接入生产 pass；本次证明的是查询/失效机制和受控工作量收益。
