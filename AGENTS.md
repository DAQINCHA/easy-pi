# AGENTS.md — easy-pi-webui

本文件是根 `AGENTS.md` 的补充，**只在改动这个项目的界面 / 皮肤时参考**。目录结构、技术选型、测试与发布规矩仍按根 `AGENTS.md`。

## 皮肤是怎么工作的

- 皮肤 = 一套 CSS 变量。`html[data-skin="<id>"]` 定义形状（`--radius`、`--radius-lg`、`--border-width`），`html[data-skin="<id>"][data-theme="light|dark"]` 定义颜色。
- 每个 `data-skin` 块**必须浅色、深色两套都给**；只给一套会掉回基础配色，看起来像「皮肤只改了一半」。
- 皮肤 id 与菜单名登记在 `public/js/app.js` 的 `SKINS`；改 id 要在 `SKIN_ALIASES` 里加迁移，否则已选过的人会被重置。
- 几个容易误解的变量：`--ink` 是描边色（基础规则里 `border: var(--border-width) solid var(--ink)` 有 30 多处），`--paper` 是输入框 / 排队区的底色，`--bg-hover` 是「悬停底色」，`--accent-fg` 是「压在 `--accent` 和 `--bg-hover` 上的前景色」。
- `--bg-hover` 与 `--accent-fg` 必须过 AAA（对比度 ≥ 7）。`tests/skill-invoke.test.mjs`、`tests/attachment-compact.test.mjs` 会逐个块检查。

## 加一套新皮肤的检查清单

按顺序过一遍，每条都对应一次真实踩过的坑：

1. **左下角「工作区」按钮**：基础规则里 `.workspace:hover` 只把底色换回 `--paper`、边框换回 `--ink`，等于零变化。每套皮肤都要自己写一条 `.workspace:hover`，并一起覆盖 `.ws-name` / `.ws-icon` / `.ws-caret` 的颜色。
2. **「N 个文件已更改」卡片**：`.turn-list` 有 6px 上下内边距，悬停底色会上下留边、填不满卡片。每套皮肤都要写 `.turn-list { padding: 0 }` + `.turn-file { padding: 10px 16px }`。
3. **三处图标圆角必须同一档**：`.brand-mark`（左上角品牌）、`.msg .avatar`（对话头像）、`.empty-mark`（空对话大图标）。基础值都是 `var(--radius)`；单独改就三处一起改。小尺寸（26px / 32px）的圆角不能超过边长一半，否则会被浏览器压成圆形，和大图标对不上。
4. **π 图标被压黑**：`.brand-mark img`、`.empty-mark img`、`.msg .avatar img` 上都有 `filter: brightness(0)`。`--brand-tile` 一旦用深色（浅色皮肤的深青、深色皮肤的深蓝），黑 π 就看不见，要补 `filter: none`（参考 `aurora` 深色那三条）。
5. **悬浮侧栏要补拖动热区**：给 `.app` 加外边距让侧栏「浮起来」之后，`.sidebar-resizer` 还是按原来的轨道位置算，热区会和侧栏边缘差一个边距。
6. **扁平皮肤不要外投影**：靠细线、留白、底色区分层级；别留 `box-shadow` 的柔影。
7. **发送键跟随主题色**，并且 `[disabled]` 与 `.is-stop`（停止中）两个状态要单独覆盖，否则会被皮肤规则盖掉。
8. **浅色 / 深色都要看一眼**：浅色下容易「按钮和侧栏同底色，只剩一根 1px 线」，深色下容易「深色字压深色底」。

## ⚠️ 会话行悬停：最容易反复踩的一个坑

侧栏每一行的结构是：

```html
<div class="session-wrap">
  <button class="session-item">…标题、时间戳…</button>
  <button class="session-action pin|archive|more">…</button>   <!-- 兄弟节点，绝对定位盖在行右侧 -->
</div>
```

三个操作按钮是 `.session-item` 的**兄弟节点**，不在行里面。由此带来两个必须同时满足的条件：

- **前景色和底色要用同一个条件**。`.session-wrap:hover` 会把标题刷成 `--accent-fg`；如果底色只写在 `.session-item:hover` 上，那么悬停三个按钮时（行没被悬停）标题会变成 `--accent-fg`、底色却不变。而每套皮肤的 `--accent-fg` 都刻意贴近侧栏底色（单色反差深色是黑压黑、极光玻璃深色是深墨压深蓝），结果就是**整行标题直接消失**。所以基础里那条 `.session-wrap:not(:has(.session-item.active)):hover .session-item { background: var(--bg-hover) }` 不能删。
- **按钮自己要有区分**。行底色既然也是 `--bg-hover`，被悬停的按钮和行底就同色了，看不出悬停到哪一个。所以 `.session-action:hover` 后面还有一条规则，把按钮填充改成 `color-mix(in srgb, var(--bg-hover) 78%, var(--accent-fg))` —— 同一色相再差一档：深色皮肤压深、浅色皮肤提亮，**不画任何线条**（描边试过，观感不好）。不要为了「干净」把它删掉，也不要改回上面那条 `background: var(--bg-hover)`。

改这一段之前先读 `tests/session-sidebar.test.mjs`：它用一个手写的小匹配器近似算选择器优先级，**把 `:not(:has(...))` 当成「多一个类」**。所以看起来更「正确」的写法（例如把条件从 `.session-wrap:hover` 改成 `.session-item:hover ~ .session-action`）会让它判成选中行静止时用错了前景色，测试报红。要改结构就连测试一起改，别偷偷绕过去。

## 改完怎么验

```bash
npm run check                          # node --check 过一遍所有 JS
node --test tests/session-sidebar.test.mjs   # 会话行悬停与图标颜色的回归
```

再确认 `public/styles.css` 的大括号成对（`{` 和 `}` 数量相等）。视觉最终得人眼看，不要用无头浏览器。

## 已知的既有红灯（不是自己改坏的）

- `tests/skill-invoke.test.mjs` / `tests/attachment-compact.test.mjs`：极光玻璃浅色的悬停对 `#f5fdff` 压 `#0d7a86` 只有 5.05，测试要求 7。
- `tests/brand-mark.test.mjs` 两条：极光玻璃深色那句 `filter: none` 打破了「最后一条 `.brand-mark img` 规则必须是 `brightness(0)`」的断言。

动这两块之前先跟作者确认；不要为了让测试变绿就删断言。
