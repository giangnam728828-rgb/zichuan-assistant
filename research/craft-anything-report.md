# Investigation report

_No brief was recorded for this investigation._

## What we looked at

- Asaiuta_dsh-genui-enhanced (js-app)
- dsh-market_dsh-market (js-app)
- omdsh-dev_DSH-better-sidebar (js-app)

## What we found

### DSH-better-sidebar 把侧栏做成可扩展底座（registerTab/FileViewer/FileIcon/FileAction/TabAction 五个扩展点，CodeMirror 语言包做编辑器），自身暴露 267 routes/46 endpoints，因此能养出大量第三方页面；先做扩展点再做功能是这个生态杠杆最高的设计。

- **Confidence:** Worked it out (derived)
- **Evidence:**
  - `ev_ac143c6af8d70177838d8a2132e5039a7215bc2685ca1543c18a8c9f8e4e4642` — Node package omdsh-dev_DSH-better-sidebar 0.32.1: 584 source files, 0 IPC channel(s) (0 paired), 0 window(s), 46 endpoint(s), 267 route(s). (path=/tmp/research/omdsh-dev_DSH-better-sidebar)

### dsh-market 的市场能力由自建 HTTP 面支撑（67 routes/167 endpoints，含 update-notifications 与 api/v1 目录接口，并以 sessionStorage 记录 toast 状态），是独立小后端而不是纯前端列表。

- **Confidence:** Worked it out (derived)
- **Evidence:**
  - `ev_21e4c5ba369793cfad96c94d80b263b7e2b62eadf8057c9adc26a00c34129957` — Web app dsh-market_dsh-market 1.73.23: 324 source files, 0 IPC channel(s) (0 paired), 0 window(s), 167 endpoint(s), 67 route(s), bundled with esbuild. (path=/tmp/research/dsh-market_dsh-market)

### dsh-genui-enhanced 把生成式 UI 的运行面压到极小：1 个 endpoint、0 条 route、0 个 IPC，靠 cachedBundle 本地缓存与 pele 引擎替换 mermaid（依赖 katex/mdast/pele/react），并带本地 achievement 存储。

- **Confidence:** Worked it out (derived)
- **Evidence:**
  - `ev_fc96f669c9e0c202c6ea210ac5f14949498d13271cc8505a466571e49bb7c63d` — Node package Asaiuta_dsh-genui-enhanced 0.14.0-fork.3: 116 source files, 0 IPC channel(s) (0 paired), 0 window(s), 1 endpoint(s), 0 route(s). (path=/tmp/research/Asaiuta_dsh-genui-enhanced)

### DSH 生态项目普遍用 package.json 的 dsh.bundle.patch（cordis.patch.yml 的 insert 行）+ dsh.client 声明挂载，不改上游即可同时装进 host 能力与浏览器 UI；dsh-market（341/392 文件、esbuild、167 endpoints）与 DSH-better-sidebar（500/584 文件、46 endpoints、267 routes）都是这一模式的实例。

- **Confidence:** Worked it out (derived)
- **Evidence:**
  - `ev_21e4c5ba369793cfad96c94d80b263b7e2b62eadf8057c9adc26a00c34129957` — Web app dsh-market_dsh-market 1.73.23: 324 source files, 0 IPC channel(s) (0 paired), 0 window(s), 167 endpoint(s), 67 route(s), bundled with esbuild. (path=/tmp/research/dsh-market_dsh-market)
  - `ev_ac143c6af8d70177838d8a2132e5039a7215bc2685ca1543c18a8c9f8e4e4642` — Node package omdsh-dev_DSH-better-sidebar 0.32.1: 584 source files, 0 IPC channel(s) (0 paired), 0 window(s), 46 endpoint(s), 267 route(s). (path=/tmp/research/omdsh-dev_DSH-better-sidebar)

### 自研 zichuan-suite 用「一个 bundle 同时给 host 工具 + 浏览器三处座位」落地：host 注册 zichuan_build/zichuan_deliver 与 /zichuan/api/{status,build,ping}；浏览器挂 shell.overlay、conversation.input.dock、conversation.session.header.utilities；实测面板渲染 8 个模板卡与 4 个指标，点 node -v 返回 PASS · exit 0 · 177ms · v24.22.1。

- **Confidence:** Seen it (observed)
- **Evidence:**
  - `ev_c04233b68c236dded0d98b61bcad0daca1ab72b62c39f65fb197b8f483afb668` — Captured a 500×789 PNG of http://127.0.0.1:3081/ (28796 bytes). (url=http://127.0.0.1:3081/)
  - `ev_21e4c5ba369793cfad96c94d80b263b7e2b62eadf8057c9adc26a00c34129957` — Web app dsh-market_dsh-market 1.73.23: 324 source files, 0 IPC channel(s) (0 paired), 0 window(s), 167 endpoint(s), 67 route(s), bundled with esbuild. (path=/tmp/research/dsh-market_dsh-market)

## Open questions

_None outstanding._

## How this was done

- **Mode:** Deep (the original's code and files could be read)
- **Engines:** builtin, cdp
- **Limitations:**
  - One image of the page's current state.
  - Only one page of module summaries is included; tools that take this evidence need every module, so pass the input path to them or use offset=0 with a limit above modules_total.
  - Static reading only: code built at run time (eval, computed requires, remote content) is invisible; IPC pairs need literal channel names.

## Evidence ledger

- `ev_21e4c5ba369793cfad96c94d80b263b7e2b62eadf8057c9adc26a00c34129957` **js_app_map** — Web app dsh-market_dsh-market 1.73.23: 324 source files, 0 IPC channel(s) (0 paired), 0 window(s), 167 endpoint(s), 67 route(s), bundled with esbuild. (Worked it out)
- `ev_ac143c6af8d70177838d8a2132e5039a7215bc2685ca1543c18a8c9f8e4e4642` **js_app_map** — Node package omdsh-dev_DSH-better-sidebar 0.32.1: 584 source files, 0 IPC channel(s) (0 paired), 0 window(s), 46 endpoint(s), 267 route(s). (Worked it out)
- `ev_fc96f669c9e0c202c6ea210ac5f14949498d13271cc8505a466571e49bb7c63d` **js_app_map** — Node package Asaiuta_dsh-genui-enhanced 0.14.0-fork.3: 116 source files, 0 IPC channel(s) (0 paired), 0 window(s), 1 endpoint(s), 0 route(s). (Worked it out)
- `ev_c04233b68c236dded0d98b61bcad0daca1ab72b62c39f65fb197b8f483afb668` **web_page_screenshot_take** — Captured a 500×789 PNG of http://127.0.0.1:3081/ (28796 bytes). (Seen it)

