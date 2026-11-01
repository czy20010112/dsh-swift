#!/usr/bin/env node
// 从本机 ~/.dsh/sessions 挑会话、解压、脱敏，导出成 Swift 回放测试用的夹具。
//
// 为什么要用真实会话而不是手写夹具：线格式有三代（v0 / v3 / v4），字段差异只在
// 真实数据里才暴露（例如 v0 的 replace 用 start/end 而不是 startSeq/endSeq，
// v3 的 tool/result 没有 message.toolCallId）。手写夹具只会验证我们以为的格式。
//
// 用法:
//   node Tools/export-fixtures.mjs                      # 默认读 ~/.dsh/sessions，写 Tests/Fixtures
//   node Tools/export-fixtures.mjs --sessions <dir> --out <dir> --max 15
//
// 退出码: 0 = 成功, 1 = 脱敏自检失败或体积超限（此时不应提交夹具）, 2 = 找不到会话目录

import { readFileSync, readdirSync, statSync, existsSync, mkdirSync, writeFileSync, unlinkSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { homedir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'
import zlib from 'node:zlib'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

function arg(name, fallback) {
  const i = process.argv.indexOf(name)
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback
}

const sessionsRoot = arg('--sessions', join(homedir(), '.dsh', 'sessions'))
const outDir = arg('--out', join(repoRoot, 'Tests', 'Fixtures'))
const maxSessions = Number(arg('--max', '15'))

// 体积上限。公开仓库里夹具越大，越难人工复核脱敏结果。
const FILE_BUDGET = 150 * 1024
const FILE_HARD_LIMIT = 200 * 1024
const TOTAL_LIMIT = 2 * 1024 * 1024
const STRING_LIMIT = 2048
// 单条 run 保留的分片数。run 动辄上万分片，全留会撑爆体积；截断时记下原始计数，
// 这样 dt/texts 的长度关系仍然能在原始数据上验证。
const RUN_CHUNK_LIMIT = 48
// 单条事件序列化后的上限。request/header 带全套工具定义，不压就是几十 KB 一条。
const EVENT_LIMIT = 6 * 1024

if (!existsSync(sessionsRoot)) {
  console.error(`找不到会话目录: ${sessionsRoot}`)
  process.exit(2)
}

// ---------------------------------------------------------------- 解压

// 会话文件是追加写的多帧 zstd：每次追加一个独立 frame。单次解压只会读出第一帧，
// 所以必须按 magic 切开逐帧解。
const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])

function decompressMultiFrame(buf) {
  const starts = []
  let at = buf.indexOf(ZSTD_MAGIC)
  while (at >= 0) {
    starts.push(at)
    at = buf.indexOf(ZSTD_MAGIC, at + 4)
  }
  const parts = []
  for (let k = 0; k < starts.length; k++) {
    const end = k + 1 < starts.length ? starts[k + 1] : buf.length
    try {
      parts.push(zlib.zstdDecompressSync(buf.subarray(starts[k], end)))
    } catch {
      // 帧内容里偶然出现 magic 字节时切点是错的；前一帧会因此解压失败。
      // 把这段并回上一段再试，比整份文件放弃更稳。
      if (k + 1 < starts.length) {
        starts.splice(k + 1, 1)
        k--
        continue
      }
      throw new Error(`zstd 帧解压失败 @${starts[k]}`)
    }
  }
  return Buffer.concat(parts).toString('utf8')
}

function readSession(path) {
  const lines = decompressMultiFrame(readFileSync(path)).split('\n').filter(Boolean)
  const header = JSON.parse(lines[0])
  const events = lines.slice(1).map((l) => JSON.parse(l))
  return { header, events }
}

function listSessionFiles() {
  const out = []
  for (const ws of readdirSync(sessionsRoot).sort()) {
    const wsDir = join(sessionsRoot, ws)
    if (!statSync(wsDir).isDirectory()) continue
    for (const sid of readdirSync(wsDir).sort()) {
      const dir = join(wsDir, sid)
      if (!statSync(dir).isDirectory()) continue
      for (const f of readdirSync(dir).sort()) {
        if (/^session(\.v\d+)?\.jsonl\.zstd$/.test(f)) out.push({ workspace: ws, sessionDir: sid, file: f, path: join(dir, f) })
      }
    }
  }
  return out
}

// ---------------------------------------------------------------- 结构辅助

const RUN_TYPES = new Set(['reasoning-chunks', 'text-chunks', 'tool-call-chunks'])

function generationOf(header) {
  // v0 的 header 实际带 version:0；缺省也按 v0 处理，兼容更早的文件。
  return `v${header.version ?? 0}`
}

function runPieces(run) {
  // tool-call-chunks 的分片字段叫 args，其余叫 texts。
  return Array.isArray(run.texts) ? run.texts : Array.isArray(run.args) ? run.args : undefined
}

function runsOf(event) {
  if (RUN_TYPES.has(event.type)) return [event.data]
  if (Array.isArray(event.data?.stream)) return event.data.stream.filter((s) => RUN_TYPES.has(s.type))
  return []
}

function toolResultCallId(event) {
  // v4 才有 message.toolCallId；v0/v3 只能从 source.callId 或内嵌的 tool-result 块拿。
  const m = event.data?.message ?? {}
  return m.toolCallId ?? m.source?.callId ?? m.content?.find?.((c) => c?.type === 'tool-result')?.toolCallId
}

function seqOf(event) {
  return event.seq ?? event.seq0
}

// 会话特征：除了事件类型，还把我们关心的格式变体当成覆盖目标，
// 否则贪心挑选可能刚好避开这些最容易出错的样本。
function featuresOf(gen, events) {
  const f = new Set()
  const callIds = new Set(events.filter((e) => e.type === 'tool/call').map((e) => e.data.callId))
  const resultsPerCall = {}
  for (const e of events) {
    if (e.surfaceOp && typeof e.surfaceOp === 'object') {
      f.add(`surfaceOp:${e.surfaceOp.op}:${'startSeq' in e.surfaceOp ? 'startSeq/endSeq' : 'start/end'}`)
    }
    for (const r of runsOf(e)) {
      if (Array.isArray(r.dt) && r.dt.some((d) => d < 0)) f.add('run:negative-dt')
      if (r.type === 'tool-call-chunks' && r.name === undefined) f.add('run:tool-call-without-name')
    }
    if (e.type === 'tool/result') {
      const id = toolResultCallId(e)
      if (!callIds.has(id)) f.add('tool/result:orphan')
      resultsPerCall[id] = (resultsPerCall[id] ?? 0) + 1
      if (e.data.message?.content?.some?.((c) => c?.type === 'image')) f.add('tool/result:image')
    }
    if (Array.isArray(e.data?.stream)) {
      for (const s of e.data.stream) if (s.type === 'chunk') f.add(`stream-chunk:${s.chunk?.type}`)
    }
  }
  if (Object.values(resultsPerCall).some((n) => n > 1)) f.add('tool/result:multiple-per-call')
  return [...f].map((x) => `${gen}|${x}`)
}

// ---------------------------------------------------------------- 脱敏

// 规则顺序有讲究：先处理路径和域名（结构化的大块），再处理用户名这类会出现在
// 路径/域名内部的片段，最后才是兜底的长 token。顺序反了会留下半截路径。
const SCRUBBERS = [
  // 私有域名必须在通用 URL 规则之前，否则只会改掉带 scheme 的那部分。
  [/[A-Za-z0-9.-]*user/gi, 'example.internal'],
  // 整条 URL 都换掉：路径和 query 里同样可能有用户名、签名参数。
  [/\b(?:https?|wss?|ftp|smb):\/\/[^\s"'`<>)\]]+/gi, 'https://example.com'],
  // Windows 绝对路径，含 JSON 字符串里被转义成 \\ 的形式（tool/call 的 arguments 就是 JSON 字符串）。
  [/\b[A-Za-z]:(?:\\{1,4}|\/)(?:[^\s"'`<>|*?\\/\r\n]+(?:\\{1,4}|\/)?)*/g, (m) => workspacePath(m)],
  // UNC 路径
  [/\\{2,8}[A-Za-z0-9._-]+(?:\\{1,4}[^\s"'`<>|*?\\\r\n]+)+/g, (m) => workspacePath(m)],
  // Git Bash / MSYS 的 /c/... /d/... 路径
  [/(?<![\w.~-])\/[a-z]\/(?:[^\s"'`<>|*?\\/\r\n]+\/?)+/g, (m) => workspacePath(m)],
  // 类 Unix 主目录
  [/(?<![\w.~-])\/(?:home|Users|root)\/(?:[^\s"'`<>|*?\\/\r\n]+\/?)*/g, (m) => workspacePath(m)],
  [/[\w.+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g, 'user@example.com'],
  // 私网和公网 IP 一律替换：VPS 的公网 IP 和内网 IP 同样敏感。回环地址留着，它对理解日志有用。
  [/\b(?!127\.0\.0\.1\b)(?!0\.0\.0\.0\b)(?:\d{1,3}\.){3}\d{1,3}\b/g, '203.0.113.1'],
  // 各家 key/token 的固定前缀
  [/\b(?:sk|pk|rk)-[A-Za-z0-9_-]{12,}/g, '[redacted-key]'],
  [/\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{16,}/g, '[redacted-key]'],
  [/\bxox[abposr]-[A-Za-z0-9-]{10,}/g, '[redacted-key]'],
  [/\bAKIA[0-9A-Z]{16}\b/g, '[redacted-key]'],
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g, '[redacted-jwt]'],
  [/\b(Bearer|Basic|Token)\s+[A-Za-z0-9._~+/=-]{8,}/gi, '$1 [redacted]'],
  // key=value 形式的凭据。值的边界用引号/空白/分隔符，宁可多删。
  [
    /\b((?:api[_-]?key|access[_-]?key|secret[_-]?key|client[_-]?secret|auth[_-]?token|access[_-]?token|refresh[_-]?token|token|secret|password|passwd|pwd|authorization|cookie)\s*["']?\s*[:=]\s*["']?)[^\s"',;&}]+/gi,
    '$1[redacted]',
  ],
  [/((?:密码|口令|令牌|密钥|验证码)\s*[:：=是为]?\s*)\S+/g, '$1[redacted]'],
  // 用户名、主机名、真名拼音、GitHub 账号。任何含 czy 的词都整体替换。
  [/[A-Za-z0-9._-]*czy[A-Za-z0-9._-]*/gi, 'user'],
  [/[A-Za-z0-9._-]*user[A-Za-z0-9._-]*/gi, 'user'],
  // 兜底：长串高熵 token（base64/hex）。不含 '-'，避免误杀 UUID 和 callId。
  [/[A-Za-z0-9+/_]{40,}={0,2}/g, '[redacted-token]'],
]

function workspacePath(raw) {
  // 只留最后一段，目录层级本身就可能泄露用户名和项目结构。
  const segments = raw.split(/[\\/]+/).filter(Boolean)
  const last = segments.length > 1 ? segments[segments.length - 1] : ''
  return `/workspace/${last}`
}

function scrub(text) {
  let s = text
  for (const [re, rep] of SCRUBBERS) s = s.replace(re, rep)
  return s
}

const TRUNCATED_MARK = '…[truncated]'

function truncateBytes(s, limit) {
  if (Buffer.byteLength(s, 'utf8') <= limit) return { value: s, cut: false }
  // 按字素截断代价太高；按码点截断足以保证不切坏 UTF-8。
  const chars = Array.from(s)
  let lo = 0
  let hi = chars.length
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1
    if (Buffer.byteLength(chars.slice(0, mid).join(''), 'utf8') <= limit) lo = mid
    else hi = mid - 1
  }
  return { value: chars.slice(0, lo).join('') + TRUNCATED_MARK, cut: true }
}

// 递归脱敏。stringLimit/arrayLimit 可调，用于把超大事件逐级压小。
function sanitizeValue(v, opts, ctx) {
  if (typeof v === 'string') {
    const r = truncateBytes(scrub(v), opts.stringLimit)
    if (r.cut) ctx.truncated = true
    return r.value
  }
  if (Array.isArray(v)) {
    const kept = v.length > opts.arrayLimit ? v.slice(0, opts.arrayLimit) : v
    if (kept.length < v.length) ctx.truncated = true
    return kept.map((x) => sanitizeValue(x, opts, ctx))
  }
  if (v && typeof v === 'object') {
    if (RUN_TYPES.has(v.type) || (Array.isArray(v.dt) && runPieces(v))) return sanitizeRun(v, opts, ctx)
    const out = {}
    for (const [k, x] of Object.entries(v)) out[scrub(k)] = sanitizeValue(x, opts, ctx)
    return out
  }
  return v
}

// run 的 texts 和 dt 必须**成对**截断（保留前 n 个分片和前 n-1 个 dt），
// 否则夹具本身就违反了 dt.count == texts.count - 1，测试会误报。
function sanitizeRun(run, opts, ctx) {
  const pieces = runPieces(run)
  const key = Array.isArray(run.texts) ? 'texts' : 'args'
  const out = {}
  for (const [k, x] of Object.entries(run)) {
    if (k === key || k === 'dt') continue
    out[k] = sanitizeValue(x, opts, ctx)
  }
  const n = Math.min(pieces.length, opts.runLimit)
  out[key] = pieces.slice(0, n).map((x) => sanitizeValue(x, opts, ctx))
  out.dt = Array.isArray(run.dt) ? run.dt.slice(0, Math.max(0, n - 1)) : run.dt
  if (n < pieces.length) {
    ctx.truncated = true
    out.original = {
      pieces: pieces.length,
      dt: Array.isArray(run.dt) ? run.dt.length : 0,
      negativeDt: Array.isArray(run.dt) ? run.dt.filter((d) => d < 0).length : 0,
    }
  }
  return out
}

// 顶层 run（v0）的 data 本身就是 run，但它没有 type 字段，要按事件类型认。
function sanitizeEvent(event) {
  const levels = [
    { stringLimit: STRING_LIMIT, arrayLimit: 64, runLimit: RUN_CHUNK_LIMIT },
    { stringLimit: 512, arrayLimit: 16, runLimit: RUN_CHUNK_LIMIT },
    { stringLimit: 128, arrayLimit: 4, runLimit: 16 },
    { stringLimit: 64, arrayLimit: 2, runLimit: 8 },
  ]
  let last
  for (const opts of levels) {
    const ctx = { truncated: false }
    const out = {}
    for (const [k, x] of Object.entries(event)) {
      if (k === 'data' && RUN_TYPES.has(event.type)) out.data = sanitizeRun(x, opts, ctx)
      else out[k] = sanitizeValue(x, opts, ctx)
    }
    if (ctx.truncated) out.truncated = true
    last = out
    if (Buffer.byteLength(JSON.stringify(out)) <= EVENT_LIMIT) break
  }
  return last
}

function sanitizeHeader(header, alias) {
  const ctx = { truncated: false }
  const out = sanitizeValue(header, { stringLimit: 256, arrayLimit: 8, runLimit: 1 }, ctx)
  // 会话 id 本身是随机串，但它是回溯到本机原始文件的钥匙，换成别名更干净。
  out.id = alias
  if ('cwd' in out) out.cwd = '/workspace'
  if ('parentSession' in out) out.parentSession = 'parent-session'
  return out
}

// 导出后的自检。任何一条命中都视为脱敏失败——宁可导不出来，也不能把隐私推上公开仓库。
const DENYLIST = [
  [/czy/i, '用户名/域名片段 czy'],
  [/user/i, '真名拼音'],
  [/\b192\.168\.\d/, '内网 IP 192.168.*'],
  [/\b172\.(?:1[6-9]|2\d|3[01])\.\d/, '内网 IP 172.16-31.*'],
  [/\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, '内网 IP 10.*'],
  [/[A-Za-z]:\\\\?(?:Users|AI|projects|Windows)/i, 'Windows 路径'],
  [/\b(?:sk|ghp|gho|github_pat)[-_][A-Za-z0-9]{12,}/, 'API key 前缀'],
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\./, 'JWT'],
  [/[\w.+-]+@(?!example\.com)[A-Za-z0-9-]+\.[A-Za-z]{2,}/, '邮箱'],
  [/\/(?:home|Users)\/(?!user\b)[A-Za-z0-9_-]+/, '主目录路径'],
]

function selfCheck(text) {
  const hits = []
  for (const [re, label] of DENYLIST) {
    const m = text.match(re)
    if (m) hits.push(`${label}: …${text.slice(Math.max(0, m.index - 20), m.index + 30).replace(/\s+/g, ' ')}…`)
  }
  return hits
}

// ---------------------------------------------------------------- 事件挑选

// 每个会话只导出一个子序列：必选的是每种类型的首次出现和每个特征的首次出现，
// 其余按时间顺序从头填到预算为止。tool/call 和它的 tool/result 必须同进同出，
// 不然回放测试里的"配不上"会混进我们自己造成的假阳性。
function pickEvents(gen, events, sanitized) {
  const size = sanitized.map((e) => Buffer.byteLength(JSON.stringify(e)) + 1)
  const total = size.reduce((a, b) => a + b, 0)
  if (total <= FILE_BUDGET) return events.map((_, i) => i)

  const partners = new Map()
  const byCall = new Map()
  events.forEach((e, i) => {
    if (e.type === 'tool/call') byCall.set(e.data.callId, [...(byCall.get(e.data.callId) ?? []), i])
    if (e.type === 'tool/result') {
      const id = toolResultCallId(e)
      byCall.set(id, [...(byCall.get(id) ?? []), i])
    }
  })
  for (const group of byCall.values()) for (const i of group) partners.set(i, group)

  const chosen = new Set()
  let used = 0
  const take = (i) => {
    for (const j of partners.get(i) ?? [i]) {
      if (!chosen.has(j)) {
        chosen.add(j)
        used += size[j]
      }
    }
  }

  const seenType = new Set()
  const seenFeature = new Set()
  events.forEach((e, i) => {
    const fs = featuresOf(gen, [e]).filter((f) => !f.endsWith('tool/result:orphan') && !f.endsWith('multiple-per-call'))
    const novel = !seenType.has(e.type) || fs.some((f) => !seenFeature.has(f))
    if (novel) {
      seenType.add(e.type)
      fs.forEach((f) => seenFeature.add(f))
      take(i)
    }
  })
  // 孤儿 result 和"一个 call 多个 result"是会话级特征，单看一条事件认不出来，单独补。
  const callIds = new Set(events.filter((e) => e.type === 'tool/call').map((e) => e.data.callId))
  const orphan = events.findIndex((e) => e.type === 'tool/result' && !callIds.has(toolResultCallId(e)))
  if (orphan >= 0) take(orphan)
  const multi = [...byCall.values()].find((g) => g.filter((i) => events[i].type === 'tool/result').length > 1)
  if (multi) take(multi[0])

  for (let i = 0; i < events.length && used < FILE_BUDGET; i++) {
    if (chosen.has(i)) continue
    const group = partners.get(i) ?? [i]
    const cost = group.filter((j) => !chosen.has(j)).reduce((a, j) => a + size[j], 0)
    if (used + cost > FILE_BUDGET) continue
    take(i)
  }
  return [...chosen].sort((a, b) => a - b)
}

// ---------------------------------------------------------------- 主流程

console.log(`扫描 ${sessionsRoot} …`)
const files = listSessionFiles()
const candidates = []
for (const f of files) {
  const { header, events } = readSession(f.path)
  const gen = generationOf(header)
  const types = new Set(events.map((e) => e.type))
  const keys = new Set([...[...types].map((t) => `${gen}|${t}`), ...featuresOf(gen, events)])
  candidates.push({ ...f, gen, keys, types, eventCount: events.length })
}
const genCount = {}
for (const c of candidates) genCount[c.gen] = (genCount[c.gen] ?? 0) + 1
console.log(`共 ${candidates.length} 个会话文件: ${Object.entries(genCount).map(([g, n]) => `${g}=${n}`).join(' ')}`)

// 贪心集合覆盖。覆盖键带代际前缀，所以每一代都会被选到——同一个事件类型在不同代里
// 结构不同（tool/result 就是例子），只覆盖一次等于没测另一代。
// 同分时选事件少的：小会话更可能整段导出，回放更接近真实顺序。
const universe = new Set(candidates.flatMap((c) => [...c.keys]))
const covered = new Set()
const picked = []
while (picked.length < maxSessions) {
  let best
  let bestGain = 0
  for (const c of candidates) {
    if (picked.includes(c)) continue
    const gain = [...c.keys].filter((k) => !covered.has(k)).length
    if (gain > bestGain || (gain === bestGain && gain > 0 && c.eventCount < best.eventCount)) {
      best = c
      bestGain = gain
    }
  }
  if (!best) break
  best.newKeys = [...best.keys].filter((k) => !covered.has(k))
  best.keys.forEach((k) => covered.add(k))
  picked.push(best)
}
// 贪心可能 10 个以内就收敛；补到下限 10 个，用各代里体积最小、尚未入选的会话，
// 给 seq/配对这些不变量多一些样本。
for (const gen of ['v4', 'v0', 'v3']) {
  while (picked.length < Math.min(10, maxSessions)) {
    const extra = candidates
      .filter((c) => c.gen === gen && !picked.includes(c) && c.eventCount >= 50)
      .sort((a, b) => a.eventCount - b.eventCount)[0]
    if (!extra) break
    extra.newKeys = []
    picked.push(extra)
    if (picked.filter((p) => p.gen === gen).length >= 4) break
  }
}

mkdirSync(outDir, { recursive: true })
for (const f of readdirSync(outDir)) {
  // 只清理本脚本生成的文件，别的东西不碰。
  if (/^v\d+-\d+\.json$/.test(f) || f === 'manifest.json') unlinkSync(join(outDir, f))
}

const manifest = {
  formatVersion: 1,
  generatedBy: 'Tools/export-fixtures.mjs',
  redaction:
    '路径→/workspace/<basename>；URL→https://example.com；IP→203.0.113.1（保留 127.0.0.1）；' +
    '邮箱→user@example.com；含 czy 的词→user；key/token/password→[redacted]；' +
    `字符串截断到 ${STRING_LIMIT} 字节并以 "${TRUNCATED_MARK}" 结尾；run 分片截断后在 original 里记原始计数`,
  fixtures: [],
}
const perGenIndex = {}
const failures = []
let totalBytes = 0
const allTypes = new Set()

for (const c of picked) {
  perGenIndex[c.gen] = (perGenIndex[c.gen] ?? 0) + 1
  const name = `${c.gen}-${String(perGenIndex[c.gen]).padStart(2, '0')}`
  const { header, events } = readSession(c.path)
  const sanitized = events.map(sanitizeEvent)
  const keep = pickEvents(c.gen, events, sanitized)
  const kept = keep.map((i) => sanitized[i])
  const fixture = {
    fixtureFormat: 1,
    name,
    generation: c.gen,
    sourceFile: c.file,
    header: sanitizeHeader(header, name),
    events: kept,
  }
  // 每条事件一行：便于 diff 和人工逐条复核脱敏。
  const text =
    '{\n' +
    Object.entries(fixture)
      .filter(([k]) => k !== 'events')
      .map(([k, v]) => `  ${JSON.stringify(k)}: ${JSON.stringify(v)},`)
      .join('\n') +
    '\n  "events": [\n' +
    kept.map((e) => '    ' + JSON.stringify(e)).join(',\n') +
    '\n  ]\n}\n'

  const hits = selfCheck(text)
  if (hits.length) failures.push(`${name}: 脱敏自检命中\n    ${hits.join('\n    ')}`)
  const bytes = Buffer.byteLength(text)
  if (bytes > FILE_HARD_LIMIT) failures.push(`${name}: ${bytes} 字节超过单文件上限 ${FILE_HARD_LIMIT}`)
  totalBytes += bytes
  writeFileSync(join(outDir, `${name}.json`), text)

  const typeCounts = {}
  for (const e of kept) typeCounts[e.type] = (typeCounts[e.type] ?? 0) + 1
  Object.keys(typeCounts).forEach((t) => allTypes.add(t))
  const keptCallIds = new Set(kept.filter((e) => e.type === 'tool/call').map((e) => e.data.callId))
  const orphanToolResults = kept.filter((e) => e.type === 'tool/result' && !keptCallIds.has(toolResultCallId(e))).length

  c.out = { name, bytes, kept: kept.length, typeCounts }
  manifest.fixtures.push({
    file: `${name}.json`,
    generation: c.gen,
    headerVersion: header.version ?? null,
    sourceFile: c.file,
    // 本机回溯用：sha256(session id) 的前 12 位，公开仓库里不暴露原始 id。
    sourceRef: createHash('sha256').update(String(header.id)).digest('hex').slice(0, 12),
    originalEventCount: events.length,
    eventCount: kept.length,
    complete: kept.length === events.length,
    bytes,
    types: Object.fromEntries(Object.entries(typeCounts).sort()),
    features: featuresOf(c.gen, events).map((f) => f.slice(c.gen.length + 1)).sort(),
    orphanToolResults,
  })
}

const manifestText = JSON.stringify(
  { ...manifest, totals: { fixtures: picked.length, typesCovered: allTypes.size, bytes: totalBytes } },
  null,
  2,
) + '\n'
writeFileSync(join(outDir, 'manifest.json'), manifestText)
totalBytes += Buffer.byteLength(manifestText)
if (totalBytes > TOTAL_LIMIT) failures.push(`夹具总大小 ${totalBytes} 超过 ${TOTAL_LIMIT}`)

// ---------------------------------------------------------------- 报告

const pad = (s, n) => String(s).padEnd(n)
console.log('')
console.log(pad('夹具', 8) + pad('代际', 5) + pad('来源会话', 40) + pad('事件(导出/原始)', 18) + pad('KB', 7) + '新增覆盖')
for (const c of picked) {
  const src = `${c.sessionDir.slice(0, 16)}…/${c.file.replace('.jsonl.zstd', '')}`
  console.log(
    pad(c.out.name, 8) + pad(c.gen, 5) + pad(src, 40) + pad(`${c.out.kept}/${c.eventCount}`, 18) +
      pad((c.out.bytes / 1024).toFixed(0), 7) + c.newKeys.map((k) => k.slice(c.gen.length + 1)).join(', '),
  )
}
console.log('')
console.log(`覆盖键（代际|类型/特征）: ${covered.size}/${universe.size}`)
console.log(`夹具里出现的事件类型: ${allTypes.size} 种（全库 ${new Set(candidates.flatMap((c) => [...c.types])).size} 种）`)
console.log(`夹具总大小: ${(totalBytes / 1024).toFixed(0)} KB`)
const missing = [...universe].filter((k) => !covered.has(k))
if (missing.length) console.log(`未覆盖: ${missing.join(', ')}`)

if (failures.length) {
  console.error('\n失败:\n  ' + failures.join('\n  '))
  process.exit(1)
}
console.log('脱敏自检通过')
