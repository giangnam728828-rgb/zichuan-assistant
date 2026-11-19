/**
 * 子川助手 · 浏览器端插件（client half）
 *
 * 手写 bundle：不需要 tsdown/打包，只要按 __ModuleLoader__ 的协议注册工厂。
 * 挂在三个官方插槽上：
 *   - conversation.session.header.corner  会话标题栏右侧的「川」按钮
 *   - shell.overlay                       浮动工作台面板
 *   - conversation.input.dock             输入框上方的三个快捷胶囊
 */
window.__ModuleLoader__.load({
  id: "zichuan-suite",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;

    var React = require("react");
    var h = React.createElement;

    var VERSION = "1.0.0";
    var STYLE_ID = "zichuan-suite-style";

    /* --------------------------------------------------------------- store */
    var store = { open: false, status: null, build: null, busy: false, toast: "", toastAt: 0 };
    var listeners = new Set();
    function emit() {
      listeners.forEach(function (fn) { try { fn(); } catch (_) {} });
    }
    function patch(next) {
      Object.assign(store, next);
      emit();
    }
    function useStore() {
      var pair = React.useState(0);
      var bump = pair[1];
      React.useEffect(function () {
        var fn = function () { bump(function (n) { return (n + 1) % 1000000; }); };
        listeners.add(fn);
        return function () { listeners.delete(fn); };
      }, []);
      return store;
    }

    // 深链：#zichuan 直接打开工作台（方便截图与分享）
    try {
      if (/zichuan/.test(location.hash)) store.open = true;
    } catch (_) {}

    function toast(text) {
      patch({ toast: text, toastAt: Date.now() });
      setTimeout(function () {
        if (Date.now() - store.toastAt >= 1600) patch({ toast: "" });
      }, 1800);
    }

    /* ---------------------------------------------------------------- styles */
    var CSS = [
      ".zc-hud{--zc-ink:#0f1418;--zc-ink2:#161d23;--zc-line:rgba(255,255,255,.10);--zc-fg:#e9eef2;--zc-dim:#93a1ac;--zc-tone:#3ad6c0;",
      "font-family:var(--dsh-font-family-text,ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,'Noto Sans SC',sans-serif);}",
      ".zc-btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;height:28px;min-width:28px;padding:0 8px;border-radius:9px;border:1px solid var(--zc-line);background:rgba(255,255,255,.04);color:var(--zc-fg);font-size:12px;line-height:1;cursor:pointer;transition:background .14s ease,border-color .14s ease,transform .14s ease}",
      ".zc-btn:hover{background:rgba(58,214,192,.14);border-color:rgba(58,214,192,.5)}",
      ".zc-btn:active{transform:scale(.97)}",
      ".zc-btn[data-tone='accent']{background:rgba(58,214,192,.16);border-color:rgba(58,214,192,.45);color:#bffff4}",
      ".zc-panel{position:fixed;z-index:2147483000;right:14px;top:56px;width:min(360px,calc(100vw - 28px));max-height:min(74vh,680px);overflow:auto;",
      "background:linear-gradient(180deg,var(--zc-ink2),var(--zc-ink));color:var(--zc-fg);border:1px solid var(--zc-line);border-radius:16px;",
      "box-shadow:0 18px 60px rgba(0,0,0,.55),inset 0 1px 0 rgba(255,255,255,.06);padding:12px 12px 14px;",
      "backdrop-filter:blur(18px) saturate(1.2);-webkit-backdrop-filter:blur(18px) saturate(1.2)}",
      ".zc-panel *{box-sizing:border-box}",
      ".zc-head{display:flex;align-items:center;gap:8px;margin-bottom:10px}",
      ".zc-logo{width:24px;height:24px;border-radius:8px;display:grid;place-items:center;font-size:13px;font-weight:700;color:#04211d;",
      "background:linear-gradient(135deg,#66f0da,#2fb8a6);box-shadow:0 2px 10px rgba(58,214,192,.35)}",
      ".zc-title{font-size:13px;font-weight:600;letter-spacing:.2px}",
      ".zc-sub{font-size:11px;color:var(--zc-dim)}",
      ".zc-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:6px;margin:8px 0 10px}",
      ".zc-metric{background:rgba(255,255,255,.035);border:1px solid var(--zc-line);border-radius:10px;padding:7px 8px}",
      ".zc-metric b{display:block;font-size:13px;font-weight:600}",
      ".zc-metric span{font-size:10px;color:var(--zc-dim)}",
      ".zc-h{display:flex;align-items:center;justify-content:space-between;margin:10px 0 6px;font-size:11px;color:var(--zc-dim);letter-spacing:.4px;text-transform:uppercase}",
      ".zc-cards{display:grid;grid-template-columns:1fr 1fr;gap:6px}",
      ".zc-card{text-align:left;border:1px solid var(--zc-line);background:rgba(255,255,255,.03);color:var(--zc-fg);border-radius:10px;padding:8px 9px;cursor:pointer;transition:border-color .14s ease,background .14s ease}",
      ".zc-card:hover{border-color:rgba(58,214,192,.55);background:rgba(58,214,192,.10)}",
      ".zc-card b{display:block;font-size:12px;font-weight:600;margin-bottom:2px}",
      ".zc-card span{display:block;font-size:10px;color:var(--zc-dim);line-height:1.35}",
      ".zc-row{display:flex;gap:6px;flex-wrap:wrap}",
      ".zc-pre{margin:8px 0 0;padding:8px 9px;border-radius:10px;border:1px solid var(--zc-line);background:rgba(0,0,0,.42);",
      "color:#cfe6e1;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;line-height:1.45;max-height:170px;overflow:auto;white-space:pre-wrap;word-break:break-word}",
      ".zc-foot{margin-top:10px;font-size:10px;color:var(--zc-dim);line-height:1.5}",
      ".zc-toast{position:fixed;left:50%;bottom:72px;transform:translateX(-50%);z-index:2147483001;padding:7px 12px;border-radius:999px;",
      "background:rgba(16,22,26,.94);border:1px solid rgba(58,214,192,.45);color:#d8fff8;font-size:12px;box-shadow:0 8px 30px rgba(0,0,0,.5)}",
      ".zc-dock{display:flex;gap:6px;align-items:center;padding:0 2px 6px;flex-wrap:wrap}",
      ".zc-pill{height:24px;padding:0 9px;border-radius:999px;border:1px solid var(--zc-line, rgba(127,127,127,.28));background:transparent;color:inherit;",
      "font-size:11px;cursor:pointer;opacity:.85;transition:opacity .14s ease,border-color .14s ease}",
      ".zc-pill:hover{opacity:1;border-color:rgba(58,214,192,.6)}",
      ".zc-corner{width:28px;height:28px;padding:0;border-radius:9px;display:inline-grid;place-items:center;cursor:pointer;",
      "border:1px solid rgba(127,127,127,.26);background:transparent;color:inherit;font-size:12px;font-weight:700;letter-spacing:0}",
      ".zc-corner[data-on='1']{border-color:rgba(58,214,192,.65);color:#2fb8a6;background:rgba(58,214,192,.12)}"
    ].join("");

    function ensureStyle() {
      if (document.getElementById(STYLE_ID) !== null) return;
      var node = document.createElement("style");
      node.id = STYLE_ID;
      node.textContent = CSS;
      document.head.appendChild(node);
    }

    /* ------------------------------------------------------------- templates */
    var TEMPLATES = [
      { key: "code", title: "写功能", hint: "读现有结构 → 改 → 构建验证", text: "在这个仓库里实现下面这个功能。先读相关文件确认现有结构与约定，再改代码，最后用 zichuan_build 跑一次构建或测试验证，把结果贴回来。\n功能：<在这里写需求>" },
      { key: "bug", title: "修 Bug", hint: "复现 → 定位根因 → 修 → 回归", text: "复现并修复这个 bug。先确认根因（不要猜），再改，然后用 zichuan_build 跑测试回归，最后说明改了哪几处。\n现象：<报错原文 / 复现步骤>" },
      { key: "build", title: "跑构建", hint: "install → build → test 全链路", text: "在当前工作区跑一次完整构建链路：安装依赖 → 构建 → 测试。失败就贴原文并继续修，直到全绿；把最终命令与耗时汇总。" },
      { key: "phone", title: "操作手机", hint: "读屏 → 点按 → 复核", text: "用 mcp__phone__screen 读一下当前屏幕，然后<要做的操作>。每一步动作后重新读屏核对结果，遇到登录/验证码/支付就 handoff 给我。" },
      { key: "research", title: "深度调研", hint: "多来源 + 引用 + 落盘", text: "调研 <主题>：至少找 5 个来源，做成带链接引用的对比表，写清楚共识与分歧，最后用 zichuan_deliver 把报告存到手机下载目录。" },
      { key: "reverse", title: "逆向分析", hint: "craft-anything 证据化分析", text: "用 craft-anything 打开 <目标 APK / 二进制 / 站点>，先给摘要，再定位关键函数或接口，结论要带 evidence id，观察与推断分开写。" },
      { key: "team", title: "多智能体", hint: "拆分子任务并行", text: "把这件事拆成 3 个互不依赖的子任务，用 subagent 并行执行（各自独立上下文），汇总后统一验证一遍再给我结论。\n任务：<目标>" },
      { key: "ship", title: "交付报告", hint: "Markdown 落到下载目录", text: "把这轮做过的事整理成一份 Markdown 报告（结论、改动清单、验证命令与结果、未解决的问题），用 zichuan_deliver 存到 /sdcard/Download/DSH-Go/。" }
    ];

    var QUICK = [
      { key: "code", label: "写代码" },
      { key: "build", label: "跑构建" },
      { key: "phone", label: "手机" }
    ];

    function templateOf(key) {
      for (var i = 0; i < TEMPLATES.length; i += 1) if (TEMPLATES[i].key === key) return TEMPLATES[i];
      return TEMPLATES[0];
    }

    /* ------------------------------------------------------------- composer */
    function findComposer() {
      var nodes = document.querySelectorAll('[contenteditable="true"]');
      var best = null;
      for (var i = 0; i < nodes.length; i += 1) {
        var el = nodes[i];
        if (el.getAttribute("contenteditable") !== "true") continue;
        var rect = el.getBoundingClientRect();
        if (rect.width < 120 || rect.height < 12) continue;
        if (best === null || rect.bottom > best.getBoundingClientRect().bottom) best = el;
      }
      return best;
    }

    function insertTemplate(text) {
      var el = findComposer();
      var inserted = false;
      if (el !== null) {
        try {
          el.focus();
          var range = document.createRange();
          range.selectNodeContents(el);
          range.collapse(false);
          var sel = window.getSelection();
          if (sel !== null) {
            sel.removeAllRanges();
            sel.addRange(range);
          }
          inserted = document.execCommand("insertText", false, text);
        } catch (_) {
          inserted = false;
        }
      }
      if (!inserted) {
        try { navigator.clipboard.writeText(text); } catch (_) {}
        toast("已复制到剪贴板，粘贴进输入框即可");
        return false;
      }
      toast("模板已写入输入框，改好占位符后发送");
      patch({ open: false });
      return true;
    }

    /* ------------------------------------------------------------ data fetch */
    function refreshStatus() {
      fetch("/zichuan/api/status", { headers: { accept: "application/json" } })
        .then(function (res) { return res.json(); })
        .then(function (data) { patch({ status: data }); })
        .catch(function () { patch({ status: { error: "宿主接口不可达" } }); });
    }

    function runBuild(command) {
      if (store.busy) return;
      patch({ busy: true, build: { command: command, output: "运行中…", ok: false, durationMs: 0 } });
      fetch("/zichuan/api/build", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ command: command, timeoutMs: 540000 })
      })
        .then(function (res) { return res.json(); })
        .then(function (data) { patch({ build: data, busy: false }); })
        .catch(function (error) { patch({ build: { command: command, output: String(error), ok: false, durationMs: 0 }, busy: false }); });
    }

    function fmtUptime(sec) {
      if (typeof sec !== "number") return "—";
      if (sec < 90) return sec + "s";
      if (sec < 5400) return Math.round(sec / 60) + "m";
      return (Math.round(sec / 360) / 10) + "h";
    }

    /* ------------------------------------------------------------ components */
    function Corner() {
      var state = useStore();
      return h("button", {
        type: "button",
        className: "zc-corner zc-btn",
        "data-on": state.open ? "1" : "0",
        title: "子川助手工作台（点击开关）",
        onClick: function () {
          var open = !store.open;
          patch({ open: open });
          if (open && store.status === null) refreshStatus();
        }
      }, "川");
    }

    function Dock() {
      return h("div", { className: "zc-dock" }, QUICK.map(function (item) {
        var tpl = templateOf(item.key);
        return h("button", {
          key: item.key,
          type: "button",
          className: "zc-pill",
          title: tpl.hint,
          onClick: function () { insertTemplate(tpl.text); }
        }, item.label);
      }), h("button", {
        key: "all",
        type: "button",
        className: "zc-pill",
        onClick: function () { patch({ open: !store.open }); if (store.status === null) refreshStatus(); }
      }, "工作台"));
    }

    function Panel() {
      var state = useStore();
      React.useEffect(function () {
        if (state.open && state.status === null) refreshStatus();
        if (!state.open || state.status !== null) return;
        var timer = setInterval(refreshStatus, 15000);
        return function () { clearInterval(timer); };
      }, [state.open, state.status]);
      React.useEffect(function () {
        var onKey = function (event) {
          if (event.key === "Escape") patch({ open: false });
          if (event.altKey && (event.key === "z" || event.key === "Z")) {
            event.preventDefault();
            patch({ open: !store.open });
            if (store.status === null) refreshStatus();
          }
        };
        window.addEventListener("keydown", onKey);
        return function () { window.removeEventListener("keydown", onKey); };
      }, []);
      if (!state.open) {
        return state.toast
          ? h("div", { className: "zc-toast" }, state.toast)
          : null;
      }
      var st = state.status || {};
      var build = state.build;
      var metrics = [
        { label: "运行时长", value: fmtUptime(st.uptimeSec) },
        { label: "内存空闲", value: st.memFreeGb === undefined ? "—" : st.memFreeGb + " GB" },
        { label: "手机盘可用", value: st.diskFreeGb === undefined ? "—" : st.diskFreeGb.sdcard + " GB" },
        { label: "Node", value: st.node || "—" }
      ];
      return h(React.Fragment, null,
        h("div", { className: "zc-panel zc-hud", role: "dialog", "aria-label": "子川助手工作台" },
          h("div", { className: "zc-head" },
            h("div", { className: "zc-logo" }, "川"),
            h("div", { style: { flex: "1 1 auto" } },
              h("div", { className: "zc-title" }, "子川助手"),
              h("div", { className: "zc-sub" }, "v" + VERSION + (st.profile ? " · " + st.profile : "") + (st.cwd ? " · " + String(st.cwd).split("/").slice(-1)[0] : ""))
            ),
            h("button", {
              type: "button",
              className: "zc-btn",
              title: "刷新状态",
              onClick: refreshStatus
            }, "↻"),
            h("button", {
              type: "button",
              className: "zc-btn",
              title: "关闭",
              onClick: function () { patch({ open: false }); }
            }, "✕")
          ),
          st.error ? h("div", { className: "zc-pre" }, st.error) : null,
          h("div", { className: "zc-grid" }, metrics.map(function (m) {
            return h("div", { className: "zc-metric", key: m.label },
              h("b", null, String(m.value)),
              h("span", null, m.label)
            );
          })),
          h("div", { className: "zc-h" }, h("span", null, "快捷任务"), h("span", null, TEMPLATES.length + " 个模板")),
          h("div", { className: "zc-cards" }, TEMPLATES.map(function (tpl) {
            return h("button", {
              key: tpl.key,
              type: "button",
              className: "zc-card",
              onClick: function () { insertTemplate(tpl.text); }
            }, h("b", null, tpl.title), h("span", null, tpl.hint));
          })),
          h("div", { className: "zc-h" }, h("span", null, "构建"), h("span", null, st.httpBuild === false ? "接口已关闭" : "本机执行")),
          h("div", { className: "zc-row" },
            ["pnpm run build", "pnpm test", "node -v"].map(function (command) {
              return h("button", {
                key: command,
                type: "button",
                className: "zc-btn",
                "data-tone": command === "pnpm run build" ? "accent" : undefined,
                disabled: state.busy,
                onClick: function () { runBuild(command); }
              }, state.busy && build && build.command === command ? "运行中…" : command);
            })
          ),
          build
            ? h("pre", { className: "zc-pre" },
                (build.ok ? "PASS" : "FAIL") + " · exit " + (build.exitCode === undefined ? "?" : build.exitCode) + " · " + (build.durationMs || 0) + "ms\n" +
                (build.output === undefined ? "" : String(build.output).slice(-4000)))
            : null,
          h("div", { className: "zc-foot" },
            "模板会直接写进输入框（不自动发送）。构建按钮在宿主以 bash 执行，命令受白名单限制。",
            st.deliverDir ? h("div", null, "产物目录：" + st.deliverDir) : null
          )
        ),
        state.toast ? h("div", { className: "zc-toast" }, state.toast) : null
      );
    }

    /* ---------------------------------------------------------------- plugin */
    var name = "zichuan-suite";
    var inject = ["slots"];

    // 槽位注册做幂等：inject 回调可能被再次触发，而 header.corner 是单实例槽，
    // 重复注册直接抛错，所以每个槽只装一次。
    // 挂在 window 上：客户端模块可能被模块图 reconcile 重新实例化，
    // 模块级变量会重置，导致同一个单实例槽被注册两次（直接抛错）。
    var SEATS = window.__ZICHUAN_SEATS__ || (window.__ZICHUAN_SEATS__ = {});

    function seat(ctx, name, spec, Component) {
      ctx.slots.inject(name, function* () {
        if (SEATS[name]) return;
        try {
          var dispose = ctx.slots.register(spec, Component);
          SEATS[name] = dispose;
          yield dispose;
        } catch (error) {
          // 客户端模块图 reconcile 可能让同一个单实例槽被再次注册；
          // 已经有一份在渲染时，这一份安静地让位，不把异常抛到页面上。
          var message = String((error && error.message) || error);
          if (message.indexOf("already has a registration") < 0 && message.indexOf("already has an entry") < 0) throw error;
        }
      });
    }

    function apply(ctx) {
      ensureStyle();
      // 标题栏角标是 single 槽位，多会话/多实例下注册会撞车；
      // 改用 utilities 列表槽位，天然按 id 去重。
      seat(ctx, "conversation.session.header.utilities", {
        name: "conversation.session.header.utilities",
        id: "zichuan-suite:corner",
        order: 60
      }, Corner);
      seat(ctx, "shell.overlay", {
        name: "shell.overlay",
        id: "zichuan-suite:panel"
      }, Panel);
      seat(ctx, "conversation.input.dock", {
        name: "conversation.input.dock",
        id: "zichuan-suite:dock",
        order: 40
      }, Dock);
    }

    exports.name = name;
    exports.inject = inject;
    exports.apply = apply;
    exports.version = VERSION;
    return module.exports;
  }
});
