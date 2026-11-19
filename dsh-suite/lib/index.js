/**
 * 子川助手 · 宿主插件（host half）
 *
 * 三件事：
 *  1) 两个模型可见工具：`zichuan_build`（跑构建/测试并把输出尾部带回来）、
 *     `zichuan_deliver`（把产物直接投递到手机下载目录）
 *  2) 一段系统提示词：把「先动手、构建验证、产物落 /sdcard/Download/DSH-Go/、手机操控走 mcp__phone__*」
 *     变成这个 profile 的默认工作流
 *  3) 两条本地 HTTP 接口给浏览器面板用：/zichuan/api/status、/zichuan/api/build
 *
 * 没有构建步骤：纯 ESM，import 自 profile 里已有的 @deepseek-ai/* 包。
 */
import { spawn } from 'node:child_process'
import { copyFile, mkdir, stat, statfs, writeFile } from 'node:fs/promises'
import { dirname, isAbsolute, join, normalize, resolve } from 'node:path'
import process from 'node:process'
import os from 'node:os'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'

export const name = 'zichuan-suite'

/** 工具是主能力；systemPrompt / webServer 视 profile 而定，用 ctx.inject 软挂载。 */
export const inject = ['tools']

export const Config = z.object({
  /** 是否注入「子川工作流」系统提示词段。 */
  injectWorkflow: z.boolean().default(true),
  /** 是否对浏览器面板开放 /zichuan/api/build（默认开，仅回环地址监听时才有意义）。 */
  allowHttpBuild: z.boolean().default(true),
  /** 交付目录，默认手机下载目录。 */
  deliverDir: z.string().default('/sdcard/Download/DSH-Go'),
  /** 单条构建命令的超时上限（毫秒）。 */
  maxTimeoutMs: z.number().default(900000)
})

const VERSION = '1.0.0'

/** profile 名：环境变量没有时从 `--profile <name>` 启动参数推断。 */
function profileName() {
  const argv = process.argv
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--profile' && argv[i + 1]) return argv[i + 1]
    if (argv[i].startsWith('--profile=')) return argv[i].slice(10)
  }
  // 启动参数优先：同一个 shell 里 DSH_PROFILE 可能还指向上一个 profile。
  return process.env.DSH_PROFILE || 'unknown'
}
const STARTED_AT = Date.now()
const TAIL_BYTES = 160000

/** HTTP 面板允许跑的构建命令前缀白名单：构建、包管理、语言运行时、只读系统查询。 */
const HTTP_ALLOW = [
  '^pnpm\\b', '^npm\\b', '^npx\\b', '^node\\b', '^yarn\\b',
  '^python3?\\b', '^pip3?\\b', '^uv\\b', '^go\\b', '^cargo\\b',
  '^make\\b', '^cmake\\b', '^gradle\\b', '^\\.\\/', '^bash scripts\\/',
  '^git (status|diff|log)\\b', '^(ls|df|du|free|uname|which)\\b',
  '^cat (package|pnpm-workspace|tsconfig|build|Makefile)'
].map((pattern) => new RegExp(pattern))

const WORKFLOW = `## 子川工作流（本机装配）

- 目标优先：用户给了任务就直接动手，先给可执行结果，再补解释。缺少参数用占位符继续，不反问。
- 改代码后必须验证：跑一次构建/测试（优先 \`zichuan_build\`），把失败原文贴回来，再修到达成。
- 产物落盘：给用户的文件写成**绝对路径**放进 /sdcard/Download/DSH-Go/（可用 \`zichuan_deliver\`），别只写在聊天里。
- 手机操控：读屏 → 点按 → 再读屏核对；优先 \`mcp__phone__intent\` 走系统意图，登录/验证码/支付用 handoff。
- 长任务：先用 todo 列表拆步，构建与安装类命令放后台跑，不要空转等待。
- 汇报时区分「观察到的」与「推断的」，命令原文与报错保持原样。`

/** 运行一条 shell 命令，收集输出尾部。 */
function runShell(command, cwd, timeoutMs, signal) {
  return new Promise((done) => {
    const started = Date.now()
    let buf = ''
    let timedOut = false
    let child
    const push = (chunk) => {
      buf += chunk
      if (buf.length > TAIL_BYTES * 2) buf = buf.slice(-TAIL_BYTES)
    }
    try {
      child = spawn('/bin/bash', ['-lc', command], { cwd, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] })
    } catch (error) {
      done({ code: -1, timedOut: false, aborted: false, output: String(error && error.message), durationMs: 0 })
      return
    }
    child.stdout.on('data', (d) => push(d.toString()))
    child.stderr.on('data', (d) => push(d.toString()))
    const timer = setTimeout(() => {
      timedOut = true
      try { child.kill('SIGKILL') } catch {}
    }, timeoutMs)
    let aborted = false
    const onAbort = () => {
      aborted = true
      try { child.kill('SIGKILL') } catch {}
    }
    if (signal) signal.addEventListener('abort', onAbort, { once: true })
    const finish = (code) => {
      clearTimeout(timer)
      if (signal) signal.removeEventListener('abort', onAbort)
      done({ code, timedOut, aborted, output: buf.slice(-TAIL_BYTES), durationMs: Date.now() - started })
    }
    child.on('close', (code) => finish(code ?? -1))
    child.on('error', (error) => { push(`\n${error.message}`); finish(-1) })
  })
}

/** 磁盘可用空间（GB，保留 1 位）。 */
async function diskFreeGb(path) {
  try {
    const info = await statfs(path)
    return Math.round((info.bavail * info.bsize) / 1e9 * 10) / 10
  } catch {
    return -1
  }
}

function safeName(input, fallback) {
  const base = (input || fallback || 'zichuan-output.txt').replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').trim()
  return base.length > 0 ? base.slice(0, 120) : 'zichuan-output.txt'
}

export function apply(ctx, config) {
  const settings = {
    injectWorkflow: config?.injectWorkflow ?? true,
    allowHttpBuild: config?.allowHttpBuild ?? true,
    deliverDir: config?.deliverDir ?? '/sdcard/Download/DSH-Go',
    maxTimeoutMs: config?.maxTimeoutMs ?? 900000
  }
  const bootCwd = process.cwd()
  let httpBuildBusy = false

  /* ---------------------------------------------------------------- 工具 1 */
  ctx.tools.register(defineTool({
    name: 'zichuan_build',
    description:
      'Run one project command (install/build/test/lint/typecheck/任意脚本) with a wall-clock timeout, and return its exit code plus the TAIL of stdout+stderr. Use it to verify a change before reporting done; output is truncated from the front, so the error usually survives.',
    parameters: {
      command: { type: 'string', required: true, description: 'Shell command line, e.g. `pnpm run build` or `python3 -m pytest -x -q`.' },
      dir: { type: 'string', description: 'Working directory (absolute or relative to the host process cwd). Defaults to the host process cwd.' },
      timeoutMs: { type: 'number', description: 'Wall-clock timeout in milliseconds. Default 600000 (10 min).' }
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          ok: { type: 'boolean', required: true },
          exitCode: { type: 'number', required: true },
          timedOut: { type: 'boolean', required: true },
          command: { type: 'string', required: true },
          cwd: { type: 'string', required: true },
          durationMs: { type: 'number', required: true },
          output: { type: 'string', required: true }
        }
      },
      render: (_args, value) => [{
        type: 'text',
        text: `${value.ok ? 'PASS' : 'FAIL'} · exit ${value.exitCode} · ${value.durationMs}ms · ${value.command}\n${value.timedOut ? '[timed out, killed]\n' : ''}${value.output}`
      }]
    },
    async execute(args, exec) {
      const cwd = args.dir ? resolve(exec?.cwd ?? bootCwd, args.dir) : (exec?.cwd ?? bootCwd)
      const timeoutMs = Math.min(Math.max(args.timeoutMs ?? 600000, 1000), settings.maxTimeoutMs)
      const result = await runShell(args.command, cwd, timeoutMs, exec?.signal)
      return {
        ok: result.code === 0 && !result.timedOut && !result.aborted,
        exitCode: result.code,
        timedOut: result.timedOut || result.aborted,
        command: args.command,
        cwd,
        durationMs: result.durationMs,
        output: result.output || '(no output)'
      }
    }
  }))

  /* ---------------------------------------------------------------- 工具 2 */
  ctx.tools.register(defineTool({
    name: 'zichuan_deliver',
    description:
      `Write text, or copy an existing file, into the phone download folder (${settings.deliverDir}) and return its absolute path plus size. Use it for every artifact the user should keep: reports, patches, scripts, screenshots.`,
    parameters: {
      name: { type: 'string', required: true, description: 'File name to create, e.g. `report.md`.' },
      text: { type: 'string', description: 'File contents to write (UTF-8). Mutually exclusive with `path`.' },
      path: { type: 'string', description: 'Existing file to copy instead of writing text.' },
      subdir: { type: 'string', description: 'Optional subfolder under the deliver directory.' }
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          ok: { type: 'boolean', required: true },
          path: { type: 'string', required: true },
          bytes: { type: 'number', required: true },
          message: { type: 'string', required: true }
        }
      },
      render: (_args, value) => [{ type: 'text', text: `${value.ok ? 'delivered' : 'failed'}: ${value.path} (${value.bytes} B)${value.message ? ` — ${value.message}` : ''}` }]
    },
    async execute(args) {
      const dir = args.subdir ? join(settings.deliverDir, safeName(args.subdir, 'misc')) : settings.deliverDir
      const target = join(dir, safeName(args.name, 'zichuan-output.txt'))
      try {
        await mkdir(dir, { recursive: true })
        if (typeof args.text === 'string') {
          await writeFile(target, args.text, 'utf8')
        } else if (args.path) {
          const source = isAbsolute(args.path) ? args.path : resolve(args.path)
          await mkdir(dirname(target), { recursive: true })
          await copyFile(source, target)
        } else {
          throw new Error('either `text` or `path` is required')
        }
        const info = await stat(target)
        return { ok: true, path: target, bytes: info.size, message: '' }
      } catch (error) {
        return { ok: false, path: target, bytes: 0, message: String(error && error.message ? error.message : error) }
      }
    }
  }))

  /* ------------------------------------------------------- 系统提示词章节 */
  if (settings.injectWorkflow) {
    ctx.inject(['systemPrompt'], (scoped) => {
      scoped.effect(() => scoped.systemPrompt.section({
        name: 'zichuan-workflow',
        order: 12000,
        text: WORKFLOW
      }), 'zichuan-suite: workflow section')
    })
  }

  /* ----------------------------------------------------- 浏览器面板的接口 */
  ctx.inject(['webServer'], (scoped) => {
    const json = (res, status, body) => {
      const text = JSON.stringify(body)
      res.writeHead(status, {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        'content-length': Buffer.byteLength(text)
      })
      res.end(text)
    }
    scoped.effect(() => scoped.webServer.register({
      kind: 'exact',
      path: '/zichuan/api/status',
      handler: (req, res) => {
        Promise.all([diskFreeGb('/sdcard'), diskFreeGb('/')]).then(([phoneGb, rootGb]) => {
          json(res, 200, {
            name: '子川助手',
            version: VERSION,
            dsh: profileName(),
            profile: profileName(),
            node: process.version,
            platform: `${os.type()} ${os.release()} · ${process.arch}`,
            cwd: process.cwd(),
            deliverDir: settings.deliverDir,
            uptimeSec: Math.round((Date.now() - STARTED_AT) / 1000),
            processUptimeSec: Math.round(process.uptime()),
            diskFreeGb: { sdcard: phoneGb, root: rootGb },
            memFreeGb: Math.round((os.freemem() / 1e9) * 10) / 10,
            cpuLoad: Math.round(os.loadavg()[0] * 100) / 100,
            tools: ['zichuan_build', 'zichuan_deliver'],
            httpBuild: settings.allowHttpBuild
          })
        })
      }
    }), 'zichuan-suite: status route')

    if (!settings.allowHttpBuild) return
    scoped.effect(() => scoped.webServer.register({
      kind: 'exact',
      path: '/zichuan/api/build',
      handler: (req, res) => {
        if (req.method !== 'POST') {
          json(res, 405, { ok: false, message: 'POST only' })
          return
        }
        let raw = ''
        req.on('data', (chunk) => {
          raw += chunk
          if (raw.length > 8192) req.destroy()
        })
        req.on('end', () => {
          let body
          try {
            body = JSON.parse(raw || '{}')
          } catch {
            json(res, 400, { ok: false, message: 'invalid JSON' })
            return
          }
          const command = String(body.command || '').trim()
          if (command.length === 0 || command.length > 400) {
            json(res, 400, { ok: false, message: 'command required (<=400 chars)' })
            return
          }
          if (!HTTP_ALLOW.some((rule) => rule.test(command))) {
            json(res, 403, { ok: false, message: `command not in the build whitelist: ${command.slice(0, 60)}` })
            return
          }
          if (httpBuildBusy) {
            json(res, 429, { ok: false, message: '另一个构建还在跑，等它结束' })
            return
          }
          httpBuildBusy = true
          const cwd = body.dir ? resolve(process.cwd(), String(body.dir)) : normalize(process.cwd())
          const timeoutMs = Math.min(Math.max(Number(body.timeoutMs) || 300000, 1000), 600000)
          runShell(command, cwd, timeoutMs, undefined)
            .then((result) => json(res, 200, {
              ok: result.code === 0 && !result.timedOut,
              exitCode: result.code,
              timedOut: result.timedOut,
              command,
              cwd,
              durationMs: result.durationMs,
              output: result.output || '(no output)'
            }))
            .catch((error) => json(res, 500, { ok: false, message: String(error && error.message ? error.message : error) }))
            .finally(() => { httpBuildBusy = false })
        })
      }
    }), 'zichuan-suite: build route')

    scoped.effect(() => scoped.webServer.register({
      kind: 'exact',
      path: '/zichuan/api/ping',
      handler: (_req, res) => json(res, 200, { ok: true, version: VERSION })
    }), 'zichuan-suite: ping route')
  })
}
