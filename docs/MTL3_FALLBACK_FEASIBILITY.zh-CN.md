# iPhone 11（A13）支持可行性勘察报告

> 历史调查记录：包含当时的假设、失败实验和待验证事项。当前实现、实测进展与已知问题以 [iPhone 11 实验性支持](IPHONE11.zh-CN.md)为准；尤其不要按早期建议移除经典路径驻留集。

> 目标：评估为 d2r-mobile 增加 Metal 3（经典 API）回退后端、使 iPhone 11（A13）能运行所需的改动与风险。
> 本报告基于对 `dm/gfx/nvn/`（核心 `nvn_mtl.m`，5848 行）的全量代码勘察与 Apple 官方文档。
> 勘察日期：2026-10-13。

## 一、结论速览

| 项 | 评估 |
|---|---|
| 技术可行性 | **可行，无原理性障碍**——所有 MTL4 用法都有经典等价物或可降级 |
| 改动范围 | 提交后端、资源绑定、贴图上传、低内存配置与触摸入口；按实现和验证结果记录，不估算工期 |
| 最大风险 | ① 同步/屏障语义重推导（正确性）② 每 draw 绑定开销（性能）③ 4 GB 内存（容量） |
| 验证范围 | 已实测 iPhone 11（A13，4 GB，iOS 26.3）；其他老机型尚未验证 |
| 当前重点 | 已能进入游戏，继续定位 GPU 超时、控制发热与内存峰值，补充长会话回归 |

## 二、为什么 iPhone 11 跑不了：事实链

1. **Apple 官方**（support.apple.com/102894）：Metal 4 在 iOS 26 上支持 **iPhone 12 及以后**（A14 起）。iPhone 11（A13）是 iOS 26 所支持的最低端 iPhone，恰好也是唯一不支持 Metal 4 的在支持列表内的 iPhone。
2. **实测崩溃点**（iPhone 11 真机日志 `boot.txt`）：游戏本体已启动到 nnMain，崩在
   `-[AGXA13Device newMTL4CommandQueueWithDescriptor:error:]: unrecognized selector`——
   A13 的设备类没有实现 MTL4 队列创建方法。
3. **同日志证明**：经典 `newCommandQueue`、`newResidencySetWithDescriptor` 在 A13 上**都创建成功**——缺的只是 MTL4 这一层的 API 面。
4. 贴图格式关（BC→ASTC）已由 Legacy Device Pack 解决，与本案无关。

## 三、现状：MTL4 用面全清单

约 130 处调用、14 类 API（不含测试），分布：

### 3.1 提交模型（生命周期集中在 4 组函数，接缝清晰）

| 组件 | 位置 | 说明 |
|---|---|---|
| `g_q4` MTL4 队列 + feedbackQueue | `nvn_mtl.m:265-269` | 唯一提交通道；带 USER_INTERACTIVE 串行反馈队列 |
| 自适应分配器环 `g_alloc4[8]` | `mtl_sub_begin` 455-491 | 按完成围栏复用/扩容；曾试固定三缓冲因 CPU 等待劣化而废弃 |
| 主提交 `mtl_sub_commit` | 675-718 | `commit:options:` + 双 `addFeedbackHandler` + `signalEvent:` |
| 上传三缓冲 | `up_begin/up_flush` 939-1041 | deswizzle 计算 → BC 解码 → blit 的级联 |
| 呈现票据环 ×3 | `present_now` 5471-5582 | `waitForDrawable:`/`signalDrawable:`、可变步调（DisplayLink 三模式） |
| CPU 围栏 | feedback → `g_done` + cond | 唯一完成机制（错误恢复、遮挡查询回读、GPU 计时都在这里） |

### 3.2 绑定模型（游戏路径 100% 走参数表，但**集中在一个垫片层**）

- 编码器打开垫片：`enc_r_begin`（绑 g_vt/g_ft 双表）`enc_c_begin`（g_ct）`enc_b_begin`——`nvn_mtl.m:509-545`；
- **全部资源绑定收敛于一个函数** `encode_args`（2665-2779）：按 shader 反射把贴图 `gpuResourceID`、采样器 rid、缓冲 `gpuAddress` 编进每 shader 一个的**间接参数缓冲（IAB）**，整个 shader 只占表里一个地址槽；有脏标记 + 复用缓存（`g_args_dirty[6]`、同 pass 序列号快速路径）；
- 顶点缓冲固定占表槽 16-31，零缓冲固定槽 30（每 draw 重写，4372-4380）；
- 另有约 8 个一次性小参数表（present、bloom、相机外推、亮度 LUT、ASTC 解码、上传解码、deswizzle）——**一半已有经典孪生实现**（`present_encode` 5397、`nvn_deswz_gpu_encode` nvn_deswizzle_gpu.m:30）。

### 3.3 深层 MTL4 依赖（比参数表本身更贵的东西）

| 依赖 | 用法 | 经典 Metal 对策 |
|---|---|---|
| `gpuAddress` 裸地址寻址 | 零拷贝内存池（`newBufferWithBytesNoCopy`）、IAB 场景、索引缓冲、顶点槽 | 地址→(MTLBuffer, offset) 反查注册表——池子是自管理的，可行，但是新增一层翻译 |
| `drawIndexedPrimitives:...indexBuffer:<uint64>` | 530 | 经典要 MTLBuffer 对象 + 偏移 → 同上反查 |
| `MTL4ArgumentTable` 的 `setTexture:<rid>`（rid 写进表/IAB 内存） | 全游戏路径 | **经典参数缓冲必须用 MTLArgumentEncoder 编码对象，不能手写 rid 字节** → IAB 每 draw 重编或摊平成逐槽 setter（见 §五.2） |
| 保守屏障（每编码器开/尾 `MTLStageAll`+`MTL4VisibilityOptionDevice`，8 处） | 全部编码器 | **无等价物**。经典同队列 CB 有序但跨 CB/跨编码器的可见性要重新用 event/fence/pass 依赖推导（§五.3） |
| 手动驻留 `MTLResidencySet`（约 30 处 res_add + 延迟释放联动） | 全资源生命周期 | 早期曾考虑取消显式驻留；A13 实测失败，当前保留驻留集并采用按需登记 |
| `MTL4CommitFeedback` | 围栏/错误恢复/查询回填 | `addCompletedHandler` 一一对应，直译 |
| blit-即-计算编码器 | `enc_b_begin` 538 已有运行时分支 | 经典有真 blit 编码器，**更简单** |
| `waitForDrawable:/signalDrawable:` | 呈现 | 经典模式：先取 drawable 再建 CB，直译 |
| 反射校验用的 `MTLArgumentEncoder`（2006-2011） | shader 装载 | 本来就是经典 API，保留 |

### 3.4 已经存在的经典代码（作者的缝）

老 `MTLCommandQueue g_q`（readback/截图/诊断）、经典呈现实现、deswizzle 经典孪生、`enc_b_begin` 的 `respondsToSelector` 分支。**说明代码作者本来就保留着经典路径的形状**，MTL4 是主路径而非唯一路径。

## 四、不适用项（无需担心）

- **着色器**：离线翻译的 MSL 是经典写法（`[[buffer(n)]]`/`[[texture(n)]]`），A13 能编译；运行时内核（deswizzle/LUT/ASTC 解码）也是经典 MSL；
- 遮挡查询 `visibilityResultBuffer`、GPU 计时、`sampleBufferAttachments`：经典 API 均有；
- 无 ITexture / 无 placement heap / 无 memoryless 附件 / 无 `supportsFamily` 复杂分叉——现有硬件分支只有 `supportsBCTextureCompression`（A16 以下）一处，且已工作。

## 五、三个真正的难点（按风险排序）

### 5.1 内存：4 GB vs 实测底线 6 GB（未知风险，只有真机能回答）
Switch 整机 4 GB 能跑本作，但 iOS 常驻开销 + 本项目宿主叠加。缓解：`increased-memory-limit` 权限在 4 GB 机器上也生效（上限更低）；需真机压测三幕+地狱难度长会话。**这一项与渲染改造正交，可以先测**——不需要等 MTL3 后端，用一个只在启动即退的试验包即可观察jetsam阈值。

### 5.2 绑定翻译：每 draw CPU 开销（性能风险）
经典回退有两条路线：
- **路线 A（保 IAB）**：保留间接参数缓冲布局，每 draw 用 `MTLArgumentEncoder` 把对象重新编码进 IAB 缓冲，然后 `setFragmentBuffer:` 绑 IAB。改动集中在 `encode_args` 一处，但每 draw 多一次编码（脏缓存机制可复用，热路径近似免费）；
- **路线 B（摊平）**：把 IAB 内容拆成逐槽 `setFragmentTexture:` 等。改动散、状态跟踪复杂，不推荐。
当前采用路线 A。A13 默认配置为 **30 FPS**；以真机帧率、CPU 开销和温控数据评估，不承诺更高帧率。

### 5.3 同步语义重推导（正确性风险，工作量最容易低估）
现在的正确性靠"便宜的全量屏障"兜底。经典 Metal 里：
- 同一 CB 内编码器有序执行（TBDR 天然串行），CB 内部的开/尾屏障可以直接删；
- **跨 CB**（上传 CB → 主帧 CB → 呈现 CB 同队列）经典语义是"按序提交、执行可重叠"——需要补 `MTLEvent`/fence 或依赖 `waitUntilCompleted` 的 CPU 序（上传路径已有 CPU 等待先例 `q_cb()` 443）；
- 相机外推 `rt_ex`、bloom 捕获等辅助 pass 间有真实的读写依赖（作者注释记录过缺屏障导致读回全黑的缺陷），要逐个推导。
**这是唯一可能产生"看起来能跑但画面间歇错乱"类缺陷的部分**，好在项目自带 gfxq 真值对照测试（`dm/verify/gfxq/`，truth_out.sh/shoot.sh）可以作为回归网。

## 六、实现状态与待验证项

本分支使用 AI 辅助开发，以代码、测试与真机结果记录进展，不提供按人天或周计算的工期估算。

| 部分 | 当前状态 | 剩余验证 |
|---|---|---|
| **设备探测** | 真调用并捕获异常，Metal 4 不可用时进入经典回退 | 其他 A13 / A12 设备尚未验证 |
| **提交后端** | 已接入经典队列、命令缓冲、完成回调与呈现 | 定位进局 GPU 超时及连续提交失败 |
| **绑定与贴图** | 已实现 IAB 对象编码、顶点 / 索引对象绑定、经典上传及辅助路径 | 更多场景、辅助通道与切图回归 |
| **内存与触摸** | 已启用按需驻留、低内存配置及原生角色按钮 | 内存峰值、反复进出游戏、按钮完整流程回归 |
| **真机稳定性** | 已验证短时游玩，合并后静置约 30 FPS | 长会话、后续章节、更高难度、发热和上传卡顿 |

桌面测试与编译结果见 [iPhone 11 实验性支持](IPHONE11.zh-CN.md)。测试通过的范围与尚未验证的范围分开记录，不以工期估算代替稳定性证据。

## 七、建议

> **P0 结果（2026-10-14，mtl3-fallback 分支）**：✅ 通过。iPhone 11（A13，iOS 26.3）上经典队列稳定出图（清屏直写 drawable）。三个新事实：
> 1. **`respondsToSelector:` 探测 MTL4 不可靠**——A13 的 `AGXA13Device` 对 `newMTL4CommandQueueWithDescriptor:error:` 返回 YES，但方法是抛 `doesNotRecognizeSelector:` 的桩；探测必须真调用 + `@try/@catch`。
> 2. **设备级 `[device newCommandBuffer]` 是 MTL4 用法**，经典只能 `[queue commandBuffer…]`。
> 3. **游戏池内存交换链纹理（newBufferWithBytesNoCopy 覆盖客体内存的池）在经典路径被 GPU 访问即 PageFault/Timeout**（清屏写附件与 blit 采样均触发）——不清 drawable 就稳定。这是 P1 的头号课题：池纹理的 GPU 地址/驻留模型与经典 API 的相容性。

1. 保留已验证可玩的版本，后续修改围绕 GPU 超时、发热、内存峰值与切图卡顿逐项进行。
2. 每项修改完成后检查对应测试与真机日志，避免仅凭能启动就认定稳定。
3. 在个人 fork 的实验分支保留实现和测试记录；是否向上游提交 PR，由实际验证结果决定。
4. 不把单台 iPhone 11 的结果推广到整个 A13 / A12 或 4 GB 设备范围。

## 附：本报告的证据来源

- Apple 官方 Metal 支持列表（102894）：Metal 4 = iPhone 12+；
- iPhone 11 真机崩溃日志（`Documents/boot.txt`，2026-10-13）：崩溃于 `newMTL4CommandQueueWithDescriptor`，此前经典队列与 ResidencySet 创建成功；
- 代码勘察：`nvn_mtl.m`（5848 行）全量、`nvn_rtex.inc`、`nvn_deswizzle_gpu.m`、`nvn_refl.h`；MTL4 符号统计 14 类约 130 处；参数表创建 10 处、绑定 11 处；`res_add` 约 30 处；经典 setter 现存 5 处（texdump/present/deswizzle）。
