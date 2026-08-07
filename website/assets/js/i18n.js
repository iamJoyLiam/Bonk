/* ============================================================
   Bonk — i18n (中文 / English)
   ============================================================ */

(function () {
  "use strict";

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

      "hero.badge": "开源 · 免费 · macOS 原生 · MIT",
      "hero.title": "原生 macOS SSH 终端",
      "hero.desc":
        "一款原生、快速、开箱即用的 macOS SSH 终端。多标签分屏、SFTP、端口转发、工作区——一个窗口，搞定所有远程工作。",
      "hero.cta.download": "下载 for Mac",
      "hero.cta.source": "查看源码",
      "hero.meta.os": "macOS 15+",
      "hero.meta.arch": "arm64 / x86_64",
      "hero.meta.size": "约 9 MB",

      "term.title": "Bonk — SSH",
      "term.tab1": "prod-server",
      "term.tab2": "staging",
      "term.tab3": "dev-box",
      "term.hint": "正在自动演示 Bonk 终端…",

      "features.eyebrow": "核心功能",
      "features.title": "为远程工作而生",
      "features.subtitle": "连接、传输、转发、自动化——专业运维每天都在用的，Bonk 都准备好了。",
      "features.f1.title": "SSH 终端",
      "features.f1.desc": "多标签、水平/垂直分屏，一个窗口同时盯多台机器。",
      "features.f2.title": "SFTP 文件管理",
      "features.f2.desc": "独立窗口的可视化文件浏览器，拖拽上传下载，无需离开 Bonk。",
      "features.f3.title": "端口转发",
      "features.f3.desc": "本地、远程、动态（SOCKS5）三种模式，穿透内网一步到位。",
      "features.f4.title": "串口连接",
      "features.f4.desc": "直连 /dev/tty.* 串口设备，调试路由器、嵌入式硬件。",
      "features.f5.title": "跳板机",
      "features.f5.desc": "多级 Jump Host 链式跳转，复杂网络拓扑从容应对。",
      "features.f6.title": "工作区",
      "features.f6.desc": "保存并一键恢复整套多会话布局，开机即回到工作现场。",
      "features.f7.title": "代码片段 · 命令历史",
      "features.f7.desc": "常用命令存成片段随时调用，历史自动记录，告别重复输入。",
      "features.f8.title": "Quake 下拉终端",
      "features.f8.desc": "全局热键 ⌘` 呼出下拉终端，任何应用里随时一键到达。",
      "features.f9.title": "自定义工具栏",
      "features.f9.desc": "原生 NSToolbar，拖拽排序、右键自定义，布局自动保存。",
      "features.f10.title": "主题系统",
      "features.f10.desc": "Dark、Dracula、Nord、Solarized 等多套内置主题，支持自定义。",
      "features.f11.title": "广播输入",
      "features.f11.desc": "一次输入，同步到所有分屏面板——批量运维利器。",
      "features.f12.title": "安全优先",
      "features.f12.desc": "Secure Enclave P256 密钥、Keychain 凭据、主机密钥校验。",

      "specs.eyebrow": "技术规格",
      "specs.title": "开箱即用的专业功能",
      "specs.row1.k": "连接",
      "specs.row1.v": "SSH · SFTP · 端口转发（本地/远程/SOCKS5）· 串口 · 跳板机",
      "specs.row2.k": "安全",
      "specs.row2.v": "Secure Enclave P256 · Keychain 凭据 · 主机密钥校验 · SSH 配置导入 · Zmodem",
      "specs.row3.k": "效率",
      "specs.row3.v": "工作区 · 代码片段 · 命令历史 · 广播 · Quake 下拉终端 · 自定义工具栏 · 主题",
      "specs.row4.k": "平台",
      "specs.row4.v": "macOS 15+ · arm64 / x86_64 · iCloud 同步 · Sparkle 自动更新 · MIT 协议",

      "download.eyebrow": "立即下载",
      "download.title": "免费开始使用",
      "download.subtitle": "开源、免费、原生。选你的架构下载 DMG，拖进 Applications 即可。",
      "download.arm.title": "Apple Silicon",
      "download.arm.desc": "M 系列芯片的 Mac",
      "download.intel.title": "Intel",
      "download.intel.desc": "搭载 Intel 处理器的 Mac",
      "download.btn": "下载 DMG",
      "download.meta.os": "需要 macOS 15 或更高版本",
      "download.meta.license": "MIT 开源协议",
      "download.meta.version": "当前版本",

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

      "hero.badge": "Open source · Free · macOS native · MIT",
      "hero.title": "The native macOS SSH terminal",
      "hero.desc":
        "A native, fast macOS SSH terminal. Tabs, split panes, SFTP, port forwarding, workspaces — one window for all your remote work.",
      "hero.cta.download": "Download for Mac",
      "hero.cta.source": "View Source",
      "hero.meta.os": "macOS 15+",
      "hero.meta.arch": "arm64 / x86_64",
      "hero.meta.size": "~9 MB",

      "term.title": "Bonk — SSH",
      "term.tab1": "prod-server",
      "term.tab2": "staging",
      "term.tab3": "dev-box",
      "term.hint": "Auto-playing a Bonk terminal demo…",

      "features.eyebrow": "Core Features",
      "features.title": "Built for remote work",
      "features.subtitle": "Connect, transfer, forward, automate — everything a pro operator reaches for every day.",
      "features.f1.title": "SSH Terminal",
      "features.f1.desc": "Tabs and horizontal/vertical split panes — watch several machines at once.",
      "features.f2.title": "SFTP File Browser",
      "features.f2.desc": "A visual browser in its own window. Drag-and-drop uploads without leaving Bonk.",
      "features.f3.title": "Port Forwarding",
      "features.f3.desc": "Local, remote, and dynamic (SOCKS5) forwarding — pierce intranets in one step.",
      "features.f4.title": "Serial Connection",
      "features.f4.desc": "Connect directly to /dev/tty.* devices — debug routers and embedded hardware.",
      "features.f5.title": "Jump Hosts",
      "features.f5.desc": "Multi-hop Jump Host chains, handling complex network topologies.",
      "features.f6.title": "Workspaces",
      "features.f6.desc": "Save and restore entire multi-session layouts — back to work instantly.",
      "features.f7.title": "Snippets · History",
      "features.f7.desc": "Store frequent commands as snippets, auto-record history — never type twice.",
      "features.f8.title": "Quake Terminal",
      "features.f8.desc": "Drop-down terminal on the global ⌘` hotkey, from any app.",
      "features.f9.title": "Custom Toolbar",
      "features.f9.desc": "Native NSToolbar — drag to reorder, right-click to customize, layout auto-saved.",
      "features.f10.title": "Theme System",
      "features.f10.desc": "Dark, Dracula, Nord, Solarized and more, with full customization.",
      "features.f11.title": "Broadcast Input",
      "features.f11.desc": "Type once, echo across every split pane — a batch-ops powerhouse.",
      "features.f12.title": "Security First",
      "features.f12.desc": "Secure Enclave P256 keys, Keychain credentials, host key validation.",

      "specs.eyebrow": "Specs",
      "specs.title": "Pro features, ready out of the box",
      "specs.row1.k": "Connect",
      "specs.row1.v": "SSH · SFTP · Port forwarding (local / remote / SOCKS5) · Serial · Jump hosts",
      "specs.row2.k": "Security",
      "specs.row2.v": "Secure Enclave P256 · Keychain credentials · Host key validation · SSH config import · Zmodem",
      "specs.row3.k": "Productivity",
      "specs.row3.v": "Workspaces · Snippets · Command history · Broadcast · Quake terminal · Custom toolbar · Themes",
      "specs.row4.k": "Platform",
      "specs.row4.v": "macOS 15+ · arm64 / x86_64 · iCloud sync · Sparkle auto-update · MIT License",

      "download.eyebrow": "Get Started",
      "download.title": "Start using it, free",
      "download.subtitle": "Open source, free, native. Pick your architecture, download the DMG, drag into Applications.",
      "download.arm.title": "Apple Silicon",
      "download.arm.desc": "Macs with M-series chips",
      "download.intel.title": "Intel",
      "download.intel.desc": "Macs with Intel processors",
      "download.btn": "Download DMG",
      "download.meta.os": "Requires macOS 15 or later",
      "download.meta.license": "MIT License",
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
    const dict = Object.assign({}, I18N[lang], window.BonkPageI18n ? window.BonkPageI18n[lang] : {});
    if (!dict) return;

    document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";

    document.querySelectorAll("[data-i18n]").forEach((el) => {
      const key = el.getAttribute("data-i18n");
      if (dict[key] !== undefined) {
        el.textContent = dict[key];
      }
    });

    document.querySelectorAll(".lang-switch button").forEach((btn) => {
      btn.classList.toggle("is-active", btn.dataset.lang === lang);
      btn.setAttribute("aria-pressed", String(btn.dataset.lang === lang));
    });

    localStorage.setItem(STORAGE_KEY, lang);
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

  window.BonkI18n = { applyLang, getLang, dict: I18N };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
