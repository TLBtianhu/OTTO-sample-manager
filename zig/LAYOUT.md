# 响应式布局调研：前端的做法，以及 OTTO 该怎么借

> 目的：窗口被拉伸时，**内部的框要优雅地重排**，不是无脑等比放大。
> 依据：MDN 的 container queries、grid auto-placement、flexbox 文档（链接见末尾），
> 以及 OTTO 当前的固定布局（380×700）。

## 一、先纠正一个直觉

"响应式"在前端**从来不是"按比例缩放"**。等比缩放会让字体变大、按钮变大、
信息密度反而下降，窗口越大越难看。

前端的实际做法是**空间重分配 + 让位顺序**：

```
窗口变大  → 同样的字体和按钮，装下更多信息（更多列、更长文本、更多辅助信息）
窗口变小  → 次要信息先让位，主要信息始终保持可读、可点
```

**字体大小、行高、点击目标不随窗口尺寸改变。**

## 二、前端的五个机制（以及各自解决什么）

### 1. Media queries：按**视口**断点
```css
@media (max-width: 600px) { .sidebar { display: none } }
```
解决"整页在不同屏幕下的布局"。**粒度是整个窗口**，不适合面板内部的适配。

### 2. Container queries：按**组件自己的容器**断点（更贴合我们）
```css
.post { container-type: inline-size; }
@container (width > 700px) { .card h2 { font-size: 2em } }
```
**关键进步**：一个卡片放在侧栏就显示紧凑版、放在主区就显示完整版，
**不需要知道它被放在哪**。这正是我们"列表区域多宽就显示哪些列"需要的粒度。

参考：[MDN · CSS container queries](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Containment/Container_queries)

### 3. Flexbox：**剩余空间怎么分、先挤谁**
```
flex-grow   有富余时谁多分
flex-shrink 不够时谁先让
flex-basis  理想尺寸（内容/固定值）
```
**响应式的核心不是断点，而是"分配规则"**：定值（工具栏 32px）、比例（列表 1fr）、
以及 `min-width` / `max-width` 约束。**断点只是在分配规则失效时的补救。**

### 4. Grid + `auto-fit` / `minmax`：**列数随宽度自动变化**
```css
grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
```
容器越宽列数越多，每列不小于 160px。**列表/卡片类 UI 的主力机制。**

参考：[MDN · Auto-placement in grid layout](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Grid_layout/Auto-placement)

### 5. `clamp(min, preferred, max)`：流式但有上下限
```css
width: clamp(200px, 40%, 480px);
```
**防止"无限拉伸"**：预览区可以跟着长，但要有上下限，否则超高屏幕上全是预览、没有列表。

## 三、借到 OTTO：布局应该怎么写

### 原则 A：断点落在**容器**上，不是窗口上
列表区有多宽，决定显示哪些列；预览区有多高，决定波形画多少列。
**窗口只是最外层容器。**

### 原则 B：先写分配规则，再写断点
```
工具栏     固定 32 px
搜索框     固定 28 px
列表       占满剩余（1fr）
预览条     clamp(56 px, 25% 高, 180 px)
```
**大多数尺寸变化应该被分配规则自然吸收**，不需要断点。

### 原则 C：让位顺序写死，尺寸分配保持连续
```
采样率（含间距 80px）先在 640 → 560 宽之间让位
大小   （含间距 80px）再在 560 → 480 宽之间让位
格式   （含间距 56px）再在 480 → 424 宽之间让位
名称列始终吃剩余；时长列与名称最小可读宽度不让
预览条在 360 → 480 宽之间，从 56 插值到 clamp(56,25%高,180)
```
辅助列的 slot 同时包含列宽和它前面的 gap，所以列消失时不会突然还给名称一
整块 8px 间距。任何相邻整数宽度之间，名称、辅助列和预览高度最多变化 1px；
**先丢辅助信息，再压缩主要信息，绝不缩到不可读。**

### 原则 D：尺寸变化要"懒"
只在**容器尺寸真的变化**时重算布局；滚动、刷新、hover 都不重排。
否则拖动边框时会闪、会掉帧。

## 四、在 nanoui 里的实现形态

nanoui 没有 CSS，所以要一个**很小的布局求解器**（不需要通用 flexbox）：

```zig
const Track = union(enum) {
    fixed: u16,                    // 工具栏 32
    fraction: u8,                  // 列表 1（权重）
    minmax: struct { min: u16, max: u16, weight: u8 },  // 预览条
};

// 沿主轴分配：先满足 fixed 与 minmax.min，再按 weight 分剩余，最后夹到 max。
fn distribute(total: u16, tracks: []const Track) []u16;
```

再配一个**只描述结构密度、不再提供第二套尺寸**的 profile：

```zig
fn listProfile(container_width: u16) Profile {
    if (visible(sample_rate, container_width)) return .full;
    if (visible(format, container_width) or visible(size, container_width)) return .no_sample_rate;
    if (container_width >= 360) return .name_and_duration;
    return .compact_with_overflow;
}
```

**只有 profile 变化才重建显示列表**；宽度连续变化时只改数值。真正的列宽由
`auxiliarySlot` / `slotContent` 计算，profile 本身不参与尺寸跳变。

## 五、测试怎么写（前端很少做，但我们必须做）

1. **约束断言**（各密度区间 × 若干宽度，并遍历 280–900 的每个整数宽度）：
   - 无重叠、无负尺寸、无越界；
   - 可点目标 ≥ 24 px；
   - 文件名始终有最小可读宽度；
   - 相邻宽度的名称列、辅助列、预览高度变化 ≤ 1 px，列出现/消失也 ≤ 1 px。
2. **快照**：380 / 480 / 640 / 900 宽各一张，肉眼确认"重排"而不是"放大"。
3. **让位顺序断言**：宽度减小时，**先消失的必须是辅助列**，不能是文件名。
4. **性能**：连续拖动改变宽度 200 次，布局计算总耗时与滚动帧率不退化。

## 六、明确不做的

- 等比缩放整个 UI（字体、按钮跟着变大）；
- 按窗口宽度而不是容器宽度决定列可见性；
- 每帧无条件重算布局；
- 为了塞下更多内容而把字体或点击目标缩到不可用。

## 参考

- [MDN · CSS container queries](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Containment/Container_queries)
- [MDN · Auto-placement in grid layout](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Grid_layout/Auto-placement)
- [MDN · Basic concepts of flexbox](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Flexible_box_layout/Basic_concepts)
