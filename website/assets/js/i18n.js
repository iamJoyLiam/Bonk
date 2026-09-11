/* ============================================================
   Bonk — i18n (中文 / English)
   ============================================================ */

(() => {
  const I18N = {
    /* ==================== 中文 ==================== */
    zh: {
      "nav.features": "功能",
      "nav.specs": "规格",
      "nav.download": "下载",
      "nav.github": "GitHub",
      "nav.source": "源码",
      "nav.compare": "对比",
      "nav.docs": "文档",

      "hero.cta.download": "下载 for Mac",
      "hero.cta.source": "查看源码",
      "hero.meta.os": "macOS 15+",
      "hero.meta.arch": "arm64 / x86_64",
      "hero.meta.size": "约 24 MB",

      "term.tab1": "prod-server",
      "term.tab2": "staging",
      "term.tab3": "dev-box",
      "app.search": "搜索",

      "specs.eyebrow": "技术规格",
      "specs.title": "开箱即用的专业功能",
      "specs.row1.k": "连接",
      "specs.row1.v":
        "SSH · SFTP · 端口转发（本地/远程/SOCKS5）· 串口 · 跳板机",
      "specs.row2.k": "安全",
      "specs.row2.v":
        "Secure Enclave P256 · Keychain 凭据 · 主机密钥校验 · SSH 配置导入 · Zmodem",
      "specs.row3.k": "效率",
      "specs.row3.v":
        "工作区 · 代码片段 · 命令历史 · 广播 · Quake 下拉终端 · 自定义工具栏 · 主题",
      "specs.row4.k": "平台",
      "specs.row4.v":
        "macOS 15+ · arm64 / x86_64 · iCloud 同步 · Sparkle 自动更新 · MIT 协议",

      "download.eyebrow": "立即下载",
      "download.title": "免费开始使用",
      "download.subtitle":
        "开源、免费、原生。选你的架构下载 DMG，拖进 Applications 即可。",
      "download.arm.title": "Apple Silicon",
      "download.arm.desc": "M 系列芯片的 Mac",
      "download.intel.title": "Intel",
      "download.intel.desc": "搭载 Intel 处理器的 Mac",
      "download.btn": "下载 DMG",
      "download.meta.os": "需要 macOS 15 或更高版本",
      "download.meta.license": "MIT 开源协议",
      "download.meta.version": "当前版本",

      "hero.title.a": "原生 macOS",
      "hero.title.b": "SSH 终端",
      "hero.desc":
        "免费开源。约 1 秒连上服务器：多标签分屏、SFTP、端口转发，一个窗口管完所有机器；Agent 模式与行内补全帮你干活。",

      "proof.s1": "约 1 秒建连",
      "proof.s2": "MIT 开源免费",
      "proof.s3": "原生 Swift 构建",
      "proof.s4": "约 24 MB 轻量包",

      "sig.eyebrow": "招牌功能",
      "sig.title": "每天都在用的六件事",
      "sig.subtitle":
        "Agent、补全、连接、协作、监控、传输——Bonk 的日常工作流。",
      "sig.f1.title": "Agent 模式",
      "sig.f1.desc":
        "分步执行先报计划、再要授权，跑偏自动熔断——监督式执行，不抢方向盘。",
      "sig.f2.title": "行内补全",
      "sig.f2.desc":
        "灰字提示跟随输入：本地即时层先行，AI 通道补位，按 Tab 一键接受。",
      "sig.f3.title": "VNext 连接引擎",
      "sig.f3.desc":
        "原生优先、OpenSSH 兜底：约 1 秒建连，睡眠与网络切换后自动自愈。",
      "sig.f4.title": "团队共享",
      "sig.f4.desc":
        "Bonjour 发现局域网主机，IP/PIN 配对，访客窗口带发言权控制。",
      "sig.f5.title": "服务器监控",
      "sig.f5.desc": "每个标签页的实时资源状态，异常一眼可见，并同步进工具栏。",
      "sig.f6.title": "SFTP 流水线",
      "sig.f6.desc": "大文件不断流：无间隙流水线传输，拖拽即走。",

      "specs.row5.k": "AI",
      "specs.row5.v":
        "Agent 模式 · 行内补全 · 推理流 · 自定义提供商 · Copilot / Claude / OpenAI / Gemini / Ollama",
      "specs.row6.k": "可靠性",
      "specs.row6.v":
        "VNext 混合引擎 · 约 1 秒建连 · 睡眠/网络切换自愈 · 认证重试与清晰报错",
      "specs.row7.k": "终端",
      "specs.row7.v":
        "SF Mono 14 · 块光标闪烁 · 深色/浅色/跟随系统 · 16 色 ANSI",
      "specs.row8.k": "录制回放",
      "specs.row8.v": "会话录制 · 录制列表管理 · 回放与删除",

      "footer.col.product": "产品",
      "footer.col.compare": "对比",
      "footer.col.resources": "资源",
      "footer.l.ssh": "SSH 终端",
      "footer.l.sftp": "SFTP",
      "footer.l.workspaces": "工作区",
      "footer.l.quake": "Quake 终端",
      "footer.l.iterm2": "iTerm2",
      "footer.l.warp": "Warp",
      "footer.l.tabby": "Tabby",
      "footer.l.termius": "Termius",
      "footer.l.docs": "文档",
      "footer.l.support": "支持 Bonk",
      "footer.copy": "© 2026 Bonk. 保留所有权利。",
      "footer.built": "Built with SwiftUI · SwiftTerm · Citadel",
    },

    /* ==================== English ==================== */
    en: {
      "nav.features": "Features",
      "nav.specs": "Specs",
      "nav.download": "Download",
      "nav.github": "GitHub",
      "nav.source": "Source",
      "nav.compare": "Compare",
      "nav.docs": "Docs",

      "hero.cta.download": "Download for Mac",
      "hero.cta.source": "View Source",
      "hero.meta.os": "macOS 15+",
      "hero.meta.arch": "arm64 / x86_64",
      "hero.meta.size": "~24 MB",

      "term.tab1": "prod-server",
      "term.tab2": "staging",
      "term.tab3": "dev-box",
      "app.search": "Search",

      "specs.eyebrow": "Specs",
      "specs.title": "Pro features, ready out of the box",
      "specs.row1.k": "Connect",
      "specs.row1.v":
        "SSH · SFTP · Port forwarding (local / remote / SOCKS5) · Serial · Jump hosts",
      "specs.row2.k": "Security",
      "specs.row2.v":
        "Secure Enclave P256 · Keychain credentials · Host key validation · SSH config import · Zmodem",
      "specs.row3.k": "Productivity",
      "specs.row3.v":
        "Workspaces · Snippets · Command history · Broadcast · Quake terminal · Custom toolbar · Themes",
      "specs.row4.k": "Platform",
      "specs.row4.v":
        "macOS 15+ · arm64 / x86_64 · iCloud sync · Sparkle auto-update · MIT License",

      "download.eyebrow": "Get Started",
      "download.title": "Start using it, free",
      "download.subtitle":
        "Open source, free, native. Pick your architecture, download the DMG, drag into Applications.",
      "download.arm.title": "Apple Silicon",
      "download.arm.desc": "Macs with M-series chips",
      "download.intel.title": "Intel",
      "download.intel.desc": "Macs with Intel processors",
      "download.btn": "Download DMG",
      "download.meta.os": "Requires macOS 15 or later",
      "download.meta.license": "MIT License",
      "download.meta.version": "Current version",

      "hero.title.a": "The native macOS",
      "hero.title.b": "SSH terminal",
      "hero.desc":
        "Free and open source. Connect in ~1s: tabbed splits, SFTP, port forwarding — every machine in one window, with Agent mode and inline completions helping.",

      "proof.s1": "~1s connects",
      "proof.s2": "MIT open source",
      "proof.s3": "Native Swift build",
      "proof.s4": "~24 MB lightweight",

      "sig.eyebrow": "Signature",
      "sig.title": "Six things you use every day",
      "sig.subtitle":
        "Agent, completions, connections, sharing, monitoring, transfers — the Bonk daily workflow.",
      "sig.f1.title": "Agent Mode",
      "sig.f1.desc":
        "Plans first, asks permission, auto-stops on drift — supervised execution that never grabs the wheel.",
      "sig.f2.title": "Inline Completions",
      "sig.f2.desc":
        "Ghost text as you type: instant local tier first, AI channel as backup, Tab to accept.",
      "sig.f3.title": "VNext Engine",
      "sig.f3.desc":
        "Native-first with OpenSSH fallback: ~1s connects, self-healing after sleep and network changes.",
      "sig.f4.title": "Team Sharing",
      "sig.f4.desc":
        "Bonjour discovery for LAN hosts, IP/PIN pairing, guest windows with floor control.",
      "sig.f5.title": "Server Monitor",
      "sig.f5.desc":
        "Live resource stats per tab, anomalies at a glance, mirrored into the toolbar.",
      "sig.f6.title": "SFTP Pipeline",
      "sig.f6.desc":
        "Large files without stalls: gap-free pipelined transfers, drag and go.",

      "specs.row5.k": "AI",
      "specs.row5.v":
        "Agent mode · Inline completions · Reasoning streams · Custom providers · Copilot / Claude / OpenAI / Gemini / Ollama",
      "specs.row6.k": "Reliability",
      "specs.row6.v":
        "VNext hybrid engine · ~1s connects · Sleep/network-change healing · Auth retry with clear errors",
      "specs.row7.k": "Terminal",
      "specs.row7.v":
        "SF Mono 14 · Blinking block cursor · Dark/Light/System themes · 16 ANSI colors",
      "specs.row8.k": "Recording",
      "specs.row8.v":
        "Session recording · Recording library · Playback and delete",

      "footer.col.product": "Product",
      "footer.col.compare": "Compare",
      "footer.col.resources": "Resources",
      "footer.l.ssh": "SSH Terminal",
      "footer.l.sftp": "SFTP",
      "footer.l.workspaces": "Workspaces",
      "footer.l.quake": "Quake Terminal",
      "footer.l.iterm2": "iTerm2",
      "footer.l.warp": "Warp",
      "footer.l.tabby": "Tabby",
      "footer.l.termius": "Termius",
      "footer.l.docs": "Docs",
      "footer.l.support": "Support Bonk",
      "footer.copy": "© 2026 Bonk. All rights reserved.",
      "footer.built": "Built with SwiftUI · SwiftTerm · Citadel",
    },
  };

  const STORAGE_KEY = "bonk-lang";
  const DEFAULT_LANG = "zh";

  function getLang() {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved === "zh" || saved === "en") return saved;
    return DEFAULT_LANG;
  }

  function applyLang(lang) {
    const dict = Object.assign(
      {},
      I18N[lang],
      window.BonkPageI18n ? window.BonkPageI18n[lang] : {},
    );
    if (!dict) return;

    document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";

    for (const el of document.querySelectorAll("[data-i18n]")) {
      const key = el.getAttribute("data-i18n");
      if (dict[key] !== undefined) {
        el.textContent = dict[key];
      }
    }

    for (const btn of document.querySelectorAll(".lang-switch button")) {
      btn.classList.toggle("is-active", btn.dataset.lang === lang);
      btn.setAttribute("aria-pressed", String(btn.dataset.lang === lang));
    }

    localStorage.setItem(STORAGE_KEY, lang);
    window.dispatchEvent(
      new CustomEvent("bonk:langchange", { detail: { lang } }),
    );
  }

  function init() {
    const lang = getLang();
    applyLang(lang);

    for (const btn of document.querySelectorAll(".lang-switch button")) {
      btn.addEventListener("click", () => {
        applyLang(btn.dataset.lang);
      });
    }
  }

  window.BonkI18n = { applyLang, getLang, dict: I18N };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
