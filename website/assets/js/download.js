/* ============================================================
   Bonk — Download logic
   下载链接来自 appcast.xml 的 GitHub Release URL。
   Hero 主按钮默认指向 arm64（Apple Silicon 已是绝对主流），
   Intel 用户可直接使用下方 x86_64 卡片。
   ============================================================ */

(function () {
  "use strict";

  // 版本号（与 appcast.xml 同步，发布新版时改这里一处）
  const VERSION = "2026.1.1";

  const DOWNLOADS = {
    arm: `https://github.com/iamJoyLiam/Bonk/releases/download/v${VERSION}/Bonk-${VERSION}-arm64.dmg`,
    intel: `https://github.com/iamJoyLiam/Bonk/releases/download/v${VERSION}/Bonk-${VERSION}-x86_64.dmg`,
  };

  const GITHUB_RELEASES = `https://github.com/iamJoyLiam/Bonk/releases/tag/v${VERSION}`;

  function init() {
    // 1. Hero 主下载按钮 → arm64
    const heroBtn = document.getElementById("hero-download");
    if (heroBtn) heroBtn.href = DOWNLOADS.arm;

    // 2. 下载卡片按钮指向对应架构
    const armCard = document.getElementById("dl-arm");
    const intelCard = document.getElementById("dl-intel");
    if (armCard) {
      const btn = armCard.querySelector("a.dl-link");
      if (btn) btn.href = DOWNLOADS.arm;
    }
    if (intelCard) {
      const btn = intelCard.querySelector("a.dl-link");
      if (btn) btn.href = DOWNLOADS.intel;
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  // 暴露给外部（README 链接等）
  window.BonkDownload = { DOWNLOADS, GITHUB_RELEASES, VERSION };
})();
