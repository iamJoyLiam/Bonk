/* ============================================================
   Bonk — i18n (中文 / English)
   双语文案数据 + 切换逻辑。默认中文，localStorage 记忆。
   ============================================================ */

(function () {
  "use strict";

  const I18N = {
    /* ==================== 中文 ==================== */
    zh: {
      "nav.features": "功能",
      "nav.terminal": "终端",
      "nav.ai": "AI",
      "nav.download": "下载",
      "nav.github": "GitHub",
      "nav.source": "源码",

      "hero.badge.line": "开源 · 免费 · macOS 原生",
      "hero.badge.open": "开源",
      "hero.badge.free": "免费",
      "hero.badge.native": "macOS 原生",
      "hero.title": "原生 macOS SSH 终端",
      "hero.title.accent": "让 AI 帮你思考",
      "hero.desc":
        "Bonk 是一款用 SwiftUI + SwiftTerm + Citadel 构建的原生 SSH 终端。多标签、分屏、SFTP、内置 AI 助手与 Agent——一个终端，搞定所有远程工作。",
      "hero.cta.download": "下载 for Mac",
      "hero.cta.detecting": "选择版本",
      "hero.cta.source": "查看源码",
      "hero.meta.version": "最新版本",
      "hero.meta.size": "约 9 MB",

      "term.title": "Bonk — SSH",
      "term.tab1": "prod-server",
      "term.tab2": "staging",
      "term.tab3": "dev-box",

      "features.eyebrow": "核心功能",
      "features.title": "为效率而生的终端",
      "features.subtitle": "不只是连服务器，而是一整套远程开发工作流。",
      "features.f1.title": "SSH 终端",
      "features.f1.desc":
        "多标签、水平/垂直分屏，一个窗口同时盯着多台机器。广播模式可向所有面板同步执行命令。",
      "features.f2.title": "SFTP 文件管理",
      "features.f2.desc":
        "独立窗口的可视化文件浏览器，上传、下载、重命名一气呵成，无需离开 Bonk。",
      "features.f3.title": "AI 助手",
      "features.f3.desc":
        "内置 GitHub Copilot、Claude、OpenAI、Gemini、Ollama 等。在终端旁边问问题、生成命令、解释报错。",
      "features.f4.title": "AI Agent",
      "features.f4.desc":
        "Agent 会规划步骤并执行命令，危险操作需你确认。让 AI 真正帮你干活，而不只是聊天。",
      "features.f5.title": "端口转发 · 串口 · 跳板机",
      "features.f5.desc":
        "本地/远程端口转发、串口设备连接、多级跳板机跳转，复杂网络拓扑也能从容应对。",
      "features.f6.title": "代码片段 · 命令历史",
      "features.f6.desc":
        "把常用命令存成片段随时调用，自动记录每一条执行过的命令，告别重复输入。",

      "spotlight.eyebrow": "终端体验",
      "spotlight.title": "每一处细节，都为命令行而生",
      "spotlight.subtitle": "原生性能、流畅分屏、即时反馈——没有 Electron 的臃肿。",
      "spotlight.p1.title": "分屏与广播",
      "spotlight.p1.desc":
        "⌘D 水平分屏，⇧⌘D 垂直分屏。开启广播，一次输入，所有面板同时响应——批量运维利器。",
      "spotlight.p2.title": "多套主题",
      "spotlight.p2.desc":
        "内置多套精挑细选的终端配色，跟随系统深浅自动切换，也支持完全自定义。",
      "spotlight.p3.title": "原生性能",
      "spotlight.p3.desc":
        "基于 SwiftTerm 原生渲染，输入零延迟、滚动丝滑。SwiftUI 让 UI 与系统浑然一体。",

      "ai.eyebrow": "AI 深度集成",
      "ai.title": "你的终端，现在会思考",
      "ai.subtitle":
        "把最强 AI 模型直接嵌入工作流。问它、让它写命令、让它替你执行——全程在你掌控之下。",
      "ai.providers.title": "支持 8 种 Provider",
      "ai.providers.desc": "本地模型也行，你的密钥永远存在本机 Keychain。",
      "ai.agent.title": "Agent 自动执行",
      "ai.agent.desc":
        "Agent 能拆解任务、规划步骤，并在你的审批下执行真实命令。每一步都透明、可撤销、有日志。",
      "ai.safety.title": "安全第一",
      "ai.safety.desc":
        "危险命令强制人工确认，输出经过净化，密钥经 Keychain 加密，对话本地存储。",

      "caps.eyebrow": "完整能力",
      "caps.title": "开箱即用的专业功能",
      "caps.subtitle": "Bonk 把专业运维每天都要用的东西，全都准备好了。",
      "caps.c1.title": "Keychain 凭据管理",
      "caps.c1.desc": "密码、密钥安全存入系统 Keychain",
      "caps.c2.title": "iCloud 同步",
      "caps.c2.desc": "主机配置跨设备无缝同步",
      "caps.c3.title": "中英双语",
      "caps.c3.desc": "界面与终端输出双语完整支持",
      "caps.c4.title": "Sparkle 自动更新",
      "caps.c4.desc": "新版本发布即时提醒，一键安装",
      "caps.c5.title": "跳板机 (Jump Host)",
      "caps.c5.desc": "多级跳转，穿透复杂网络",
      "caps.c6.title": "串口连接",
      "caps.c6.desc": "直连串口设备，调试硬件",
      "caps.c7.title": "OSC 7 支持",
      "caps.c7.desc": "终端路径感知，与编辑器联动",
      "caps.c8.title": "Keep-Alive",
      "caps.c8.desc": "智能心跳，告别连接中断",

      "download.eyebrow": "立即下载",
      "download.title": "免费开始使用",
      "download.subtitle": "开源、免费、原生。选你的架构下载 DMG，拖进 Applications 即可。",
      "download.arm.title": "Apple Silicon",
      "download.arm.desc": "M1 / M2 / M3 / M4 系列芯片的 Mac",
      "download.intel.title": "Intel",
      "download.intel.desc": "搭载 Intel 处理器的 Mac",
      "download.btn": "下载 DMG",
      "download.meta.os": "需要 macOS 13 或更高版本",
      "download.meta.license": "开源协议",
      "download.meta.version": "当前版本",

      "footer.copy": "© 2026 Bonk. 保留所有权利。",
      "footer.built": "Built with SwiftUI · SwiftTerm · Citadel",
    },

    /* ==================== English ==================== */
    en: {
      "nav.features": "Features",
      "nav.terminal": "Terminal",
      "nav.ai": "AI",
      "nav.download": "Download",
      "nav.github": "GitHub",
      "nav.source": "Source",

      "hero.badge.line": "Open source · Free · macOS native",
      "hero.badge.open": "Open Source",
      "hero.badge.free": "Free",
      "hero.badge.native": "macOS Native",
      "hero.title": "The native macOS SSH terminal",
      "hero.title.accent": "that thinks with AI",
      "hero.desc":
        "Bonk is a native SSH terminal built with SwiftUI + SwiftTerm + Citadel. Tabs, split panes, SFTP, a built-in AI assistant and Agent — one terminal for all your remote work.",
      "hero.cta.download": "Download for Mac",
      "hero.cta.detecting": "Choose version",
      "hero.cta.source": "View Source",
      "hero.meta.version": "Latest version",
      "hero.meta.size": "~9 MB",

      "term.title": "Bonk — SSH",
      "term.tab1": "prod-server",
      "term.tab2": "staging",
      "term.tab3": "dev-box",

      "features.eyebrow": "Core Features",
      "features.title": "A terminal built for productivity",
      "features.subtitle": "Not just connecting to servers — a complete remote development workflow.",
      "features.f1.title": "SSH Terminal",
      "features.f1.desc":
        "Multiple tabs, horizontal & vertical split panes — watch several machines at once. Broadcast mode runs commands across all panes simultaneously.",
      "features.f2.title": "SFTP File Browser",
      "features.f2.desc":
        "A visual file browser in its own window. Upload, download, rename without ever leaving Bonk.",
      "features.f3.title": "AI Assistant",
      "features.f3.desc":
        "GitHub Copilot, Claude, OpenAI, Gemini, Ollama and more, built right in. Ask questions, generate commands, explain errors — right next to your terminal.",
      "features.f4.title": "AI Agent",
      "features.f4.desc":
        "The Agent plans steps and executes commands, asking for your approval on anything risky. AI that actually does the work — not just chat.",
      "features.f5.title": "Port Forward · Serial · Jump Host",
      "features.f5.desc":
        "Local & remote port forwarding, serial device connections, multi-hop jump hosts. Complex network topologies, handled gracefully.",
      "features.f6.title": "Snippets · Command History",
      "features.f6.desc":
        "Save frequent commands as snippets for instant recall. Every command is auto-recorded — never type the same thing twice.",

      "spotlight.eyebrow": "Terminal Experience",
      "spotlight.title": "Every detail, crafted for the command line",
      "spotlight.subtitle": "Native performance, fluid splits, instant feedback — no Electron bloat.",
      "spotlight.p1.title": "Splits & Broadcast",
      "spotlight.p1.desc":
        "⌘D splits horizontally, ⇧⌘D vertically. Turn on broadcast and one input echoes across every pane — a batch-ops powerhouse.",
      "spotlight.p2.title": "Multiple Themes",
      "spotlight.p2.desc":
        "Hand-picked terminal color schemes that follow the system light/dark mode, with full customization.",
      "spotlight.p3.title": "Native Performance",
      "spotlight.p3.desc":
        "Rendered natively via SwiftTerm — zero input lag, buttery scrolling. SwiftUI keeps the UI one with the system.",

      "ai.eyebrow": "Deep AI Integration",
      "ai.title": "Your terminal, now it thinks",
      "ai.subtitle":
        "Embed the most powerful AI models directly into your workflow. Ask it, let it write commands, let it execute for you — all under your control.",
      "ai.providers.title": "8 Providers Supported",
      "ai.providers.desc": "Local models too. Your keys never leave your Mac's Keychain.",
      "ai.agent.title": "Agent Auto-Execution",
      "ai.agent.desc":
        "The Agent breaks down tasks, plans steps, and executes real commands with your approval. Every step is transparent, reversible, and logged.",
      "ai.safety.title": "Safety First",
      "ai.safety.desc":
        "Dangerous commands require explicit confirmation. Output is sanitized, keys are encrypted via Keychain, conversations stay local.",

      "caps.eyebrow": "Complete Toolkit",
      "caps.title": "Pro features, ready out of the box",
      "caps.subtitle": "Bonk ships with everything pro operators reach for every day.",
      "caps.c1.title": "Keychain Credentials",
      "caps.c1.desc": "Passwords & keys stored securely in system Keychain",
      "caps.c2.title": "iCloud Sync",
      "caps.c2.desc": "Host configs sync seamlessly across devices",
      "caps.c3.title": "Bilingual",
      "caps.c3.desc": "Full Chinese & English UI and terminal support",
      "caps.c4.title": "Sparkle Auto-Update",
      "caps.c4.desc": "Instant alerts on new releases, one-click install",
      "caps.c5.title": "Jump Host",
      "caps.c5.desc": "Multi-hop routing through complex networks",
      "caps.c6.title": "Serial Connection",
      "caps.c6.desc": "Connect directly to serial devices, debug hardware",
      "caps.c7.title": "OSC 7 Support",
      "caps.c7.desc": "Terminal path awareness, editor integration",
      "caps.c8.title": "Keep-Alive",
      "caps.c8.desc": "Smart heartbeat, say goodbye to dropped connections",

      "download.eyebrow": "Get Started",
      "download.title": "Start using it, free",
      "download.subtitle": "Open source, free, native. Pick your architecture, download the DMG, drag into Applications.",
      "download.arm.title": "Apple Silicon",
      "download.arm.desc": "Macs with M1 / M2 / M3 / M4 series chips",
      "download.intel.title": "Intel",
      "download.intel.desc": "Macs with Intel processors",
      "download.btn": "Download DMG",
      "download.meta.os": "Requires macOS 13 or later",
      "download.meta.license": "Open Source License",
      "download.meta.version": "Current version",

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
    const dict = I18N[lang];
    if (!dict) return;

    document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";

    document.querySelectorAll("[data-i18n]").forEach((el) => {
      const key = el.getAttribute("data-i18n");
      if (dict[key] !== undefined) {
        el.textContent = dict[key];
      }
    });

    // For elements mixing static + translated (e.g. hero title with accent span)
    document.querySelectorAll("[data-i18n-html]").forEach((el) => {
      const key = el.getAttribute("data-i18n-html");
      if (dict[key] !== undefined) {
        el.innerHTML = dict[key];
      }
    });

    // Update lang switch active state
    document.querySelectorAll(".lang-switch button").forEach((btn) => {
      btn.classList.toggle("is-active", btn.dataset.lang === lang);
      btn.setAttribute("aria-pressed", String(btn.dataset.lang === lang));
    });

    localStorage.setItem(STORAGE_KEY, lang);

    // Notify other scripts (download.js may need label updates)
    window.dispatchEvent(new CustomEvent("bonk:langchange", { detail: { lang } }));
  }

  function init() {
    const lang = getLang();
    applyLang(lang);

    document.querySelectorAll(".lang-switch button").forEach((btn) => {
      btn.addEventListener("click", () => {
        applyLang(btn.dataset.lang);
      });
    });
  }

  // Expose for other scripts
  window.BonkI18n = { applyLang, getLang, dict: I18N };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
