#!/usr/bin/env node
// 把 Swift 侧的线协议常量镜像与实际安装的 dsh host 包对拍。
//
// 为什么需要这个：这些常量改一个字符不会编译失败，只会在运行时静默失效——
// 流不来、事件不到、审批答不上，而且没有任何错误信息。上游升级时这是最先断的地方。
//
// 用法:
//   node Tools/check-wire-drift.mjs                  # 自动找全局安装的 @deepseek-ai/dsh
//   node Tools/check-wire-drift.mjs <path-to-dsh>    # 指定包路径
//
// 退出码: 0 = 一致, 1 = 发现漂移, 2 = 找不到 host 包（CI 里应视为 skip 而非失败）

import { execSync } from 'node:child_process'
import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

function findHostPackage() {
  if (process.argv[2]) return process.argv[2]
  try {
    const root = execSync('npm root -g', { encoding: 'utf8' }).trim()
    const candidate = join(root, '@deepseek-ai', 'dsh')
    if (existsSync(candidate)) return candidate
  } catch {}
  return undefined
}

const hostPath = findHostPackage()
if (!hostPath || !existsSync(hostPath)) {
  console.error('skip: 找不到已安装的 @deepseek-ai/dsh —— 无法对拍，不算失败')
  process.exit(2)
}

const hostVersion = JSON.parse(
  readFileSync(join(hostPath, 'package.json'), 'utf8'),
).version
console.log(`host 包: ${hostPath}`)
console.log(`host 版本: ${hostVersion}`)

// ---- 读 host 侧的真值 ----

function readIfExists(p) {
  return existsSync(p) ? readFileSync(p, 'utf8') : ''
}

const gatewaySrc = readIfExists(
  join(hostPath, 'node_modules/@deepseek-ai/dsh-api-gateway/lib/index.js'),
)
const connectionSrc = readIfExists(
  join(hostPath, 'node_modules/@deepseek-ai/dsh-client-connection/lib/index.js'),
)

if (!gatewaySrc || !connectionSrc) {
  console.error('skip: host 包里找不到 gateway/connection 的 lib —— 结构可能变了')
  process.exit(2)
}

// 从 host 源码里抽常量。用具名捕获，匹配不到就报漂移而不是静默通过。
function extractString(src, pattern, label) {
  const m = src.match(pattern)
  if (!m) return { label, value: undefined, missing: true }
  return { label, value: m[1], missing: false }
}

const hostFacts = [
  extractString(gatewaySrc, /REMOTE_EVENT_STREAM_ENDPOINT\s*=\s*"([^"]+)"/, 'eventsEndpoint'),
  // 这个常量在打包产物里被内联了，所以按它的实际用处抽：
  // gateway 用 `endpoint === "$events/result"` 判断一元 RPC 的目标。
  extractString(gatewaySrc, /endpoint === "(\$events\/result)"/, 'eventsResultEndpoint'),
  extractString(gatewaySrc, /REMOTE_STREAM_MUX_PATH\s*=\s*"([^"]+)"/, 'muxPath'),
  extractString(connectionSrc, /COOKIE_PREFIX\s*=\s*"([^"]+)"/, 'cookieNamePrefix'),
]

// ---- 读 Swift 侧的镜像 ----

const swiftSrc = readFileSync(
  join(repoRoot, 'Sources/DshProtocol/WireConstants.swift'),
  'utf8',
)

function swiftConstant(name) {
  const m = swiftSrc.match(
    new RegExp(`static let ${name} = "([^"]+)"`),
  )
  return m?.[1]
}

const swiftValues = {
  eventsEndpoint: swiftConstant('eventsEndpoint'),
  eventsResultEndpoint: swiftConstant('eventsResultEndpoint'),
  muxPath: swiftConstant('muxPath'),
  cookieNamePrefix: swiftConstant('cookieNamePrefix'),
}

// ---- 对拍常量 ----

let drift = 0
console.log('\n## 常量')
for (const fact of hostFacts) {
  const mine = swiftValues[fact.label]
  if (fact.missing) {
    console.log(`  ?? ${fact.label}: 在 host 源码里没找到（抽取规则可能过时）`)
    drift++
    continue
  }
  if (mine === fact.value) {
    console.log(`  ok ${fact.label} = ${JSON.stringify(fact.value)}`)
  } else {
    console.log(
      `  !! ${fact.label}: host=${JSON.stringify(fact.value)} swift=${JSON.stringify(mine)}`,
    )
    drift++
  }
}

// ---- 对拍事件 allowlist ----

console.log('\n## 事件 allowlist')

// host 侧把 allowlist 编译进了 remotes 包；它在 lib 里是一串 { event: "...", mode: "..." }
const remotesSrc = readIfExists(
  join(hostPath, 'node_modules/@deepseek-ai/dsh-api-remotes/lib/index.js'),
)
const hostEvents = new Map()
if (remotesSrc) {
  const re = /event:\s*"([^"]+)"\s*,\s*mode:\s*"(emit|waterfall)"/g
  let m
  while ((m = re.exec(remotesSrc))) hostEvents.set(m[1], m[2])
}

if (hostEvents.size === 0) {
  console.log('  ?? 没能从 host 包里抽到事件表，跳过这一节')
} else {
  const swiftEvents = new Map()
  const re = /"([a-z0-9\-/]+)":\s*\.(emit|waterfall)/gi
  const block = swiftSrc.slice(
    swiftSrc.indexOf('forwardedEvents'),
    swiftSrc.indexOf('public enum EventMode'),
  )
  let m
  while ((m = re.exec(block))) swiftEvents.set(m[1], m[2])

  for (const [event, mode] of hostEvents) {
    const mine = swiftEvents.get(event)
    if (mine === undefined) {
      console.log(`  !! host 新增事件未镜像: ${event} (${mode})`)
      drift++
    } else if (mine !== mode) {
      console.log(`  !! ${event} 的 mode 不一致: host=${mode} swift=${mine}`)
      drift++
    }
  }
  for (const event of swiftEvents.keys()) {
    if (!hostEvents.has(event)) {
      console.log(`  !! swift 镜像了 host 已不转发的事件: ${event}`)
      drift++
    }
  }
  console.log(`  host ${hostEvents.size} 条 / swift ${swiftEvents.size} 条`)
  const waterfalls = [...hostEvents].filter(([, m]) => m === 'waterfall')
  console.log(`  waterfall: ${waterfalls.map(([e]) => e).join(', ')}`)
}

// ---- /connect 端点是否还在 ----

console.log('\n## /connect 端点')
if (connectionSrc.includes('authorizeConnect')) {
  console.log('  ok authorizeConnect 存在')
  const hasInteractions = /getAll\("interactions"\)/.test(connectionSrc)
  console.log(
    hasInteractions
      ? '  ok interactions 声明仍被解析'
      : '  !! interactions 不再被解析 —— 配对姿态的语义可能已变',
  )
  if (!hasInteractions) drift++
} else {
  console.log('  !! authorizeConnect 不存在 —— 原生配对链路可能已改')
  drift++
}

console.log(
  drift === 0
    ? `\n一致（host ${hostVersion}）`
    : `\n发现 ${drift} 处漂移（host ${hostVersion}）`,
)
process.exit(drift === 0 ? 0 : 1)
