// 最小复现：volatile 配置字段被 normalize() 静默丢弃
//
// 用法：
//   node repro/normalize-volatile.mjs
//
// 需要 @deepseek-ai/schemastery（DSH profile 里就有）。
// 已经能解析到这个包就直接跑；否则用 SCHEMASTERY 指过去：
//   SCHEMASTERY=~/.dsh/profiles/desktop/node_modules/@deepseek-ai/schemastery/lib/index.mjs \
//     node repro/normalize-volatile.mjs

const SPEC = process.env.SCHEMASTERY || '@deepseek-ai/schemastery'
const { default: z } = await import(SPEC)

const DEFAULTS = { perDay: 5, pythonPath: 'python', keywords: [], peakValley: false }

// ── 插件的原实现（dsh-bili-scroll@0.1.7 index.js:164-174） ──
const normOld = (src, base) => {
  const out = { ...base }
  for (const k of Object.keys(base)) {
    const v = src?.[k]
    if (v === undefined || v === null) continue
    if (Array.isArray(base[k])) { if (Array.isArray(v)) out[k] = v.filter((x) => typeof x === 'string') }
    else if (typeof base[k] === 'number') { const n = Number(v); if (Number.isFinite(n)) out[k] = n }
    else if (typeof base[k] === 'boolean') { if (typeof v === 'boolean') out[k] = v }
    else if (typeof base[k] === 'string') { if (typeof v === 'string') out[k] = v }
  }
  return out
}

// ── 修复后：取值前先解引用 ──
const normFixed = (src, base) => {
  const out = { ...base }
  for (const k of Object.keys(base)) {
    let v = src?.[k]
    if (v && typeof v === 'object' && typeof v.get === 'function') { try { v = v.get() } catch { /* 拿不到就当没设 */ } }
    if (v === undefined || v === null) continue
    if (Array.isArray(base[k])) { if (Array.isArray(v)) out[k] = v.filter((x) => typeof x === 'string') }
    else if (typeof base[k] === 'number') { const n = Number(v); if (Number.isFinite(n)) out[k] = n }
    else if (typeof base[k] === 'boolean') { if (typeof v === 'boolean') out[k] = v }
    else if (typeof base[k] === 'string') { if (typeof v === 'string') out[k] = v }
  }
  return out
}

// ── 宿主 schema 的形状（照抄 dsh-bili-scroll index.js:46-88，只留几个字段） ──
const Config = z.object({
  perDay: z.natural().default(5).extra('volatile', true),
  pythonPath: z.string().default('python').extra('volatile', true),
  keywords: z.array(z.string()).default([]).extra('volatile', true),
  peakValley: z.boolean().default(false).extra('volatile', true),
})

import { homedir } from 'node:os'
import { join } from 'node:path'

const VENV = process.env.VENV_PY || join(homedir(), '.dsh/bili-duty/.venv/bin/python')

// 宿主 apply(ctx, config) 拿到的就是这个形状
const fiberConfig = Config({ perDay: 7, pythonPath: VENV, keywords: ['b站'], peakValley: true })

console.log('=== 宿主给我们的 config 长什么样 ===')
for (const k of Object.keys(fiberConfig)) {
  const v = fiberConfig[k]
  const kind = typeof v === 'object' && typeof v.get === 'function' ? 'volatile 引用' : typeof v
  const actual = typeof v?.get === 'function' ? v.get() : v
  console.log(`  ${k.padEnd(12)} ${kind.padEnd(14)} get=${JSON.stringify(actual)}`)
}

console.log('\n=== normalize 结果对比 ===')
const oldOut = normOld(fiberConfig, { ...DEFAULTS })
const newOut = normFixed(fiberConfig, { ...DEFAULTS })
console.log('旧:', JSON.stringify(oldOut))
console.log('新:', JSON.stringify(newOut))

const pass =
  oldOut.pythonPath === 'python' &&
  newOut.pythonPath === VENV &&
  oldOut.peakValley === false &&
  newOut.peakValley === true &&
  newOut.perDay === 7 &&
  newOut.keywords.length === 1

console.log('\n' + (pass ? 'PASS —— 修复在真实 schema 形状下成立' : 'FAIL —— 结论不成立，别信这份文档'))
process.exit(pass ? 0 : 1)
