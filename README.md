# dsh-bili-scroll 排查记录：volatile 配置字段被静默丢弃

> 一个 DSH 插件的配置加载 bug —— 20 个设置项全部失效，表现为「扫码画不出二维码」和「MCP 子进程起不来」。
> 排查时间 2026-10-19，插件版本 `dsh-bili-scroll@0.1.7`。

## TL;DR

插件里 `normalize()` 按 `typeof v === 'string'` 之类的方式挑配置值，但 DSH 宿主 schema 里
标了 `.extra('volatile', true)` 的字段，解析出来**不是标量，而是 `{ get() }` 引用对象**。

于是所有类型判断全部落空，每个键都被静默丢弃、一律回落默认值 —— 用户在设置页改的**任何**东西都不生效。

最直接的后果：`pythonPath` 永远是 `'python'`，而那个裸 `python` 里没装 `bilibili_api` 和 `qrcode`，
所以 MCP 子进程起不来、二维码画不出来。

修法只有 3 行：取值前先解引用。

```js
let v = src?.[k]
if (v && typeof v === 'object' && typeof v.get === 'function') { try { v = v.get() } catch {} }
```

---

## 环境

| 项 | 值 |
|---|---|
| DSH | `0.2.0-rc.2`（Electron，profile = `desktop`） |
| 插件 | `dsh-bili-scroll@0.1.7`（装在 `~/.dsh/profiles/desktop/node_modules/`） |
| OS | macOS（Apple Silicon） |
| Python | 3.13.13（`uv venv --seed` 建的独立 venv） |
| venv 路径 | `~/.dsh/bili-duty/.venv/bin/python` |

venv 里的依赖是**齐全的**（这点很关键，后面排除了半天）：

```
bilibili-api-python 17.4.2
mcp                 1.30.0
qrcode              8.2
Pillow              13.0.0
httpx               0.28.1
lxml / pyyaml / aiohttp
```

`install.log` 显示每次装依赖都是 `exit 0`、`venvReady=true`。

---

## 症状

三个看起来不相关的故障，其实是同一个根因：

### 1）扫码登录弹不出二维码

`bili_login_start` 返回：

```json
{ "ok": true, "key": "...", "url": "https://account.bilibili.com/...", "png": null,
  "hint": "没画出 PNG：先去设置里点「建 venv 装依赖」（venv 里要有 qrcode）" }
```

但 venv 里 `qrcode` 明明能 import，手动画图也正常（`qrcode.make(url).save(png)` 出 1652 B / 570×570 的清晰二维码）。

### 2）搜索报 MCP 子进程崩溃

```
Error: MCP 子进程退出（code=1）：
Traceback (most recent call last):
  File "~/.dsh/bili-duty/mcp_server.py", line 26, in <module>
    from bilibili_api import video, search, comment, Credential, dynamic, opus
ModuleNotFoundError: No module named 'bilibili_api'
```

### 3）设置页改的值静默失效

`duty.log` 里明明写着「设置已更新：{...}（DSH 那边已同步）」，`config.json` 和 `cordis.patch.yml`
两份文件也都落盘了正确的值，但 `GET /api/bili-duty/config` 读回来永远是 `pythonPath: "python"`、
`peakValley: false`、`autoComment: false`。

---

## 排查过程（排除法）

### ❌ 假设一：venv 依赖没装好

直接跑 venv python：

```bash
~/.dsh/bili-duty/.venv/bin/python -c "import bilibili_api, qrcode; print('ok')"
```

结果 `ok`，`sys.prefix` 正确指向 `.venv`。**排除**。

### ❌ 假设二：Electron 环境下 spawn 的 Python 行为不同

用宿主的 Electron 二进制（`ELECTRON_RUN_AS_NODE=1`）逐字复现 spawn：

```
OUT prefix /Users/zhangjm/.dsh/bili-duty/.venv
launcher None
bili ok
exit 0
```

再用插件自己的 `lib/mcp.mjs` 起 MCP 跑 `bili_search`，返回真实数据。
**排除** —— 解释器和运行环境都没问题。

### ❌ 假设三：环境变量污染

宿主进程（pid 72064）的 38 个环境变量里，`PYTHONHOME` / `PYTHONPATH` / `VIRTUAL_ENV` /
`__PYVENV_LAUNCHER__` **全都没有**。唯一能复现 `ModuleNotFoundError` 的方式是手动注入
`__PYVENV_LAUNCHER__`，但宿主并没有这个变量。**排除**。

### ❌ 假设四：设置没写进去

```bash
curl -X POST http://127.0.0.1:19387/api/bili-duty/config \
  -d '{"pythonPath":"/Users/zhangjm/.dsh/bili-duty/.venv/bin/python"}'
```

返回 `host: {"ok": true, "ns": "bili-scroll"}`，`config.json` 和 `cordis.patch.yml` 都立即落盘正确值。
**写入是通的**。

但紧接着 `GET /api/bili-duty/config` 读回 `python` —— 写进去了，读不出来。

### ✅ 假设五：读取时被 normalize 层吞掉

把 `config.json` 的 `pythonPath` 手改成 `/ZZZ_MARKER_PY`，接口仍读回 `python`；
改 `mentionName`、`dshBin` 也读回空。

⇒ **不是单键问题，是所有键都被吞**。

还有个对照实验特别能说明问题：

| 操作 | 运行时 `pythonPath` |
|---|---|
| `cordis.patch.yml` 里有 `pythonPath` 行 | `python` ❌ |
| **删掉**那一行 | venv 路径 ✅ |
| 再加回去 | `python` ❌ |

因为 `loadCfg()` 的逻辑是「`row.user[k] === undefined` 才回落 `config.json`」：

```js
for (const k of Object.keys(DEFAULTS)) if (user[k] === undefined) out[k] = saved[k]
```

删掉 patch 里的键 ⇒ 走 `config.json`（正确）；留着 ⇒ 走 `hostCfg()`，而 `hostCfg()` 里的
`normalize(config, DEFAULTS)` 把值丢了。

---

## 根因

用宿主同款 `schemastery` 实测：

```js
import z from '@deepseek-ai/schemastery'

const S = z.object({
  perDay:     z.natural().default(5).extra('volatile', true),
  pythonPath: z.string().default('python').extra('volatile', true),
  keywords:   z.array(z.string()).default([]).extra('volatile', true),
})

const parsed = S({ perDay: 7, pythonPath: '/x/y', keywords: ['a'] })
```

输出：

```
keys: [ 'perDay', 'pythonPath', 'keywords' ]
  perDay:     typeof=object  isVolatile=true  get=7
  pythonPath: typeof=object  isVolatile=true  get="/x/y"
  keywords:   typeof=object  isVolatile=true  get=["a"]
```

**全部不是标量，是 `{ get() }` 引用对象。**

而 `index.js:164` 的 `normalize()` 是这样写的：

```js
const out = { ...base }
for (const k of Object.keys(base)) {
  const v = src?.[k]
  if (v === undefined || v === null) continue
  if (Array.isArray(base[k])) { if (Array.isArray(v)) out[k] = v.filter((x) => typeof x === 'string') }
  else if (typeof base[k] === 'number')  { const n = Number(v); if (Number.isFinite(n)) out[k] = n }
  else if (typeof base[k] === 'boolean') { if (typeof v === 'boolean') out[k] = v }
  else if (typeof base[k] === 'string')  { if (typeof v === 'string')  out[k] = v }
}
return out
```

`{ get() }` 是个 object：

- `Array.isArray(v)` → false
- `Number(v)` → `NaN`（`Number.isFinite` 拦掉）
- `typeof v === 'boolean'` → false
- `typeof v === 'string'` → false

**四个分支全部落空，`out[k]` 保持 base 里的默认值。**

插件 schema 里有 **20 个字段**全都标了 `.extra('volatile', true)`，所以这 20 个设置项全部失效：

```
perDay, peakValley, noon, night, autoComment, dmMode, dmUid, transcribe, asrModel,
commentPerRound, mentionName, keywords, pythonPath, dshBin, headlessProfile,
overlayMcp, workspace, reportLevel, replyToComments, replyPerRound
```

### 为什么必须是 volatile

`index.js:39` 的注释写得很清楚：

> 🔴 每个字段都要 `.extra('volatile', true)`：DSH 的 `settings.update()` 只认 volatile 字段

所以不是「去掉 volatile 就好了」—— 去掉之后设置页根本写不进去。**必须解引用**。

### 为什么 pythonPath 的后果最明显

`pythonPath` 回落到 `'python'`，而 `PATH` 里第一个 `python` 是
`/opt/miniconda3/envs/vibe-trading-ai/bin/python` —— 那里既没有 `bilibili_api` 也没有 `qrcode`。

于是：

- `lib/mcp.mjs` spawn 它跑 `mcp_server.py` → `ModuleNotFoundError: No module named 'bilibili_api'` → MCP 起不来
- `lib/login.mjs` 的 `renderQrPng()` spawn 它画二维码 → `ModuleNotFoundError: No module named 'qrcode'` → `resolve(null)` → `png: null`

而 venv 路径明明一直正确躺在 `config.json` 里，只是被 `normalize()` 丢掉了。

---

## 修复

`index.js` 的 `normalize()` 函数内，取值之后、类型判断之前，加 3 行解引用：

```diff
  const out = { ...base }
  for (const k of Object.keys(base)) {
-   const v = src?.[k]
+   // ⭐ volatile 字段在 config 里是**引用对象**（{ get() }），不是标量 —— 不解引用就等于全被丢弃、
+   //    一律回落默认值 ⇒ 设置页里改的每个键都静默失效（pythonPath 永远 'python' 就是这条）。
+   let v = src?.[k]
+   if (v && typeof v === 'object' && typeof v.get === 'function') { try { v = v.get() } catch { /* 拿不到就当没设 */ } }
    if (v === undefined || v === null) continue
    if (Array.isArray(base[k])) { if (Array.isArray(v)) out[k] = v.filter((x) => typeof x === 'string') }
    else if (typeof base[k] === 'number')  { const n = Number(v); if (Number.isFinite(n)) out[k] = n }
    else if (typeof base[k] === 'boolean') { if (typeof v === 'boolean') out[k] = v }
    else if (typeof base[k] === 'string')  { if (typeof v === 'string')  out[k] = v }
  }
```

为什么用 `typeof v.get === 'function'` 而不是 `isVolatile(v)`：不想为了这一处再引一个 `@deepseek-ai/cosmokit`
依赖，鸭子类型判断够用，而且对普通对象（没有 `get` 方法）零影响。

### 顺带的好处

`{ get() }` 是**活引用** —— 宿主改配置时会就地更新它（`cordis` 的 `_commitVolatile()`）。
所以解引用之后拿到的永远是最新值，比「启动时快照 + 手动 refresh」更可靠。

---

## 验证

### 1）语法与加载

```bash
node --check index.js          # 无输出 = 通过
node -e "import('./index.js').then(m => console.log(m.name, m.inject))"
# bili-scroll [ 'webServer', 'tools', 'settings' ]
```

### 2）用真实 schema 形状做端到端对比

```js
const raw = { perDay: 5, peakValley: true, autoComment: true,
              pythonPath: '/Users/zhangjm/.dsh/bili-duty/.venv/bin/python', ... }
const fiberConfig = Config(raw)   // 宿主 apply(ctx, config) 拿到的就是这个形状

normOld(fiberConfig, DEFAULTS).pythonPath   // 'python'      ❌
normFixed(fiberConfig, DEFAULTS).pythonPath // venv 路径      ✅
normOld(fiberConfig, DEFAULTS).peakValley   // false         ❌
normFixed(fiberConfig, DEFAULTS).peakValley // true          ✅
```

输出 `PASS`。

### 3）运行时实测（打上 workaround 之后）

| 检查项 | 结果 |
|---|---|
| `GET /api/bili-duty/config` → `pythonPath` | ✅ venv 路径 |
| `bili_search({keyword:'test', num:1})` | ✅ 返回 `BV1jx411w7FP` |
| `bili_login_start` → `png` | ✅ `/Users/zhangjm/.dsh/bili-duty/qrcode_login.png` |
| `POST /login/start` → `qr`（设置页 `<img src>` 用的） | ✅ 2150–2310 字节 base64 |
| 二维码 PNG 实体 | ✅ 570×570，清晰可扫 |

---

## 临时绕过（不重启 DSH 也能用）

如果不想立刻重启，把 `cordis.patch.yml` 里 bili-scroll 段的 `pythonPath` 那一行**删掉**：

```yaml
- id: bili-scroll
  name: dsh-bili-scroll
  config:
    enabled: true
    perDay: 5
    # pythonPath: ...   ← 删掉这一行
```

这样 `row.user['pythonPath'] === undefined` 成立，`loadCfg()` 会回落到 `config.json` 里的 venv 路径。

**代价**：只有 `pythonPath` 这一个键恢复，其余 19 个设置项照旧失效。

⚠️ 修好之后记得把这行加回去 —— 否则设置页里改 `pythonPath` 仍不生效（会被 `config.json` 盖住）。

---

## 和上游 issue #22 的关系

上游已有 [issue #22](https://github.com/c1overzz/dsh-bili-scroll/issues/22) 报告了同一族症状
（`pythonPath` 变回 `'python'`、峰谷/评论/私信设置重启即丢），诊断是：

> 宿主加载时会跳过 volatile 字段 ⇒ `apply(ctx, config)` 拿到的 `config` 里这些键是 schema 默认值

**我这边的实测结论不太一样**：`config` 里不是默认值，而是 `{ get() }` 引用对象，
`get()` 返回的**是用户设的值**（`get="/x/y"`）。所以数据没丢，只是 `normalize()` 不会解引用。

issue #22 提的修法（`isSchemaDefault` 判定 + 回落 `config.json`）也能让症状消失，
但它是绕路 —— 把「读不到引用」变成「读不到就信 `config.json`」。
解引用是直接修在源头：拿到活引用，永远最新，也不用维护第二份真相。

两种修法不冲突，可以都上。但如果只能选一个，建议解引用。

---

## 附：最小复现代码

```js
// repro/normalize-volatile.mjs
import z from '@deepseek-ai/schemastery'

const DEFAULTS = { perDay: 5, pythonPath: 'python', keywords: [], peakValley: false }

// 插件的原实现
const normOld = (src, base) => {
  const out = { ...base }
  for (const k of Object.keys(base)) {
    const v = src?.[k]
    if (v === undefined || v === null) continue
    if (Array.isArray(base[k])) { if (Array.isArray(v)) out[k] = v.filter((x) => typeof x === 'string') }
    else if (typeof base[k] === 'number')  { const n = Number(v); if (Number.isFinite(n)) out[k] = n }
    else if (typeof base[k] === 'boolean') { if (typeof v === 'boolean') out[k] = v }
    else if (typeof base[k] === 'string')  { if (typeof v === 'string')  out[k] = v }
  }
  return out
}

// 修复后
const normFixed = (src, base) => {
  const out = { ...base }
  for (const k of Object.keys(base)) {
    let v = src?.[k]
    if (v && typeof v === 'object' && typeof v.get === 'function') { try { v = v.get() } catch {} }
    if (v === undefined || v === null) continue
    if (Array.isArray(base[k])) { if (Array.isArray(v)) out[k] = v.filter((x) => typeof x === 'string') }
    else if (typeof base[k] === 'number')  { const n = Number(v); if (Number.isFinite(n)) out[k] = n }
    else if (typeof base[k] === 'boolean') { if (typeof v === 'boolean') out[k] = v }
    else if (typeof base[k] === 'string')  { if (typeof v === 'string')  out[k] = v }
  }
  return out
}

const Config = z.object({
  perDay:     z.natural().default(5).extra('volatile', true),
  pythonPath: z.string().default('python').extra('volatile', true),
  keywords:   z.array(z.string()).default([]).extra('volatile', true),
  peakValley: z.boolean().default(false).extra('volatile', true),
})

const VENV = '/Users/zhangjm/.dsh/bili-duty/.venv/bin/python'
const fiberConfig = Config({ perDay: 7, pythonPath: VENV, keywords: ['b站'], peakValley: true })

console.log('旧:', normOld(fiberConfig, DEFAULTS))
console.log('新:', normFixed(fiberConfig, DEFAULTS))
```

输出：

```
旧: { perDay: 5, pythonPath: 'python', keywords: [], peakValley: false }
新: { perDay: 7, pythonPath: '/Users/zhangjm/.dsh/bili-duty/.venv/bin/python',
      keywords: [ 'b站' ], peakValley: true }
```

---

## 环境变量参考：能复现同一个报错的唯一方式

排查过程中发现，只有一种情况会让 venv python 报 `ModuleNotFoundError`：

```bash
__PYVENV_LAUNCHER__=/opt/miniconda3/bin/python ~/.dsh/bili-duty/.venv/bin/python -c "import bilibili_api"
# ModuleNotFoundError: No module named 'bilibili_api'
```

因为 `__PYVENV_LAUNCHER__` 会让 venv 的 `site.py` 认为自己在跑另一个解释器，从而跳过 venv 的 `site-packages`。

但 DSH 宿主进程的环境里**没有**这个变量（38 个键逐个查过），所以这不是本次的原因。
记在这里，供后续遇到同类报错时快速排除。
