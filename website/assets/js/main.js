/* ============================================================
   Bonk — Main interactions
   导航 / 移动端菜单 / 滚动入场 / 平滑滚动 / 终端自动演示
   ============================================================ */

(function () {
  "use strict";

  /* ---------- 1. 导航滚动毛玻璃 ---------- */
  const nav = document.getElementById("nav");
  let ticking = false;

  function onScroll() {
    if (!ticking) {
      window.requestAnimationFrame(() => {
        if (nav) nav.classList.toggle("scrolled", window.scrollY > 16);
        ticking = false;
      });
      ticking = true;
    }
  }
  window.addEventListener("scroll", onScroll, { passive: true });

  /* ---------- 2. 移动端菜单 ---------- */
  const navToggle = document.getElementById("nav-toggle");
  function closeMenu() {
    if (nav) nav.classList.remove("is-open");
    if (navToggle) navToggle.setAttribute("aria-expanded", "false");
  }
  if (navToggle && nav) {
    navToggle.addEventListener("click", () => {
      const open = nav.classList.toggle("is-open");
      navToggle.setAttribute("aria-expanded", String(open));
    });
    nav.querySelectorAll(".nav__link").forEach((link) => link.addEventListener("click", closeMenu));
  }

  /* ---------- 3. 滚动入场动画 ---------- */
  const revealEls = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && revealEls.length) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.1, rootMargin: "0px 0px -60px 0px" }
    );
    revealEls.forEach((el) => io.observe(el));
  } else {
    revealEls.forEach((el) => el.classList.add("is-visible"));
  }

  /* ---------- 4. 平滑滚动 ---------- */
  document.querySelectorAll('a[href^="#"]').forEach((anchor) => {
    anchor.addEventListener("click", (e) => {
      const href = anchor.getAttribute("href");
      if (href === "#" || href.length < 2) return;
      const target = document.querySelector(href);
      if (target) {
        e.preventDefault();
        const navHeight = nav ? nav.offsetHeight : 0;
        const top = target.getBoundingClientRect().top + window.scrollY - navHeight - 8;
        window.scrollTo({ top, behavior: "smooth" });
      }
    });
  });

  /* ============================================================
     5. 终端自动演示（白色主题，自动打字循环）
     ============================================================ */
  const terminal = document.getElementById("demo-terminal");
  const body = document.getElementById("demo-body");
  const history = document.getElementById("demo-history");

  if (terminal && body && history) {
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    function lang() {
      return window.BonkI18n ? BonkI18n.getLang() : "zh";
    }

    function esc(s) {
      return String(s).replace(/[&<>"']/g, (ch) => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      }[ch]));
    }

    function sleep(ms) {
      return new Promise((r) => setTimeout(r, ms));
    }

    function promptHtml(user, path) {
      return (
        '<span class="term-user">' + esc(user) + "</span>" +
        '<span class="term-path"> ' + esc(path) + " </span>" +
        '<span class="term-prompt">$ </span>'
      );
    }

    function appendLine(html, cls) {
      const div = document.createElement("div");
      div.className = "term-line" + (cls ? " " + cls : "");
      div.innerHTML = html;
      history.appendChild(div);
      body.scrollTop = body.scrollHeight;
    }

    async function typeCommand(cmd) {
      const line = document.createElement("div");
      line.className = "term-line";
      line.innerHTML = promptHtml("joy@bonk", "~") + '<span class="term-cmd"></span><span class="term-cursor"></span>';
      history.appendChild(line);
      const cmdEl = line.querySelector(".term-cmd");

      if (reduceMotion) {
        cmdEl.textContent = cmd;
        await sleep(250);
      } else {
        for (const ch of cmd) {
          cmdEl.textContent += ch;
          body.scrollTop = body.scrollHeight;
          await sleep(45);
        }
        await sleep(180);
      }
      line.querySelector(".term-cursor").remove();
      return line;
    }

    async function showOutputs(outputs) {
      for (const out of outputs) {
        appendLine(out.html, out.cls);
        body.scrollTop = body.scrollHeight;
        await sleep(reduceMotion ? 80 : 320);
      }
    }

    // 脚本：自动演示一段真实工作流
    function buildScript() {
      const zh = lang() === "zh";
      const t = {
        connected: zh ? "✔ 已连接 · Keychain 认证" : "✔ connected · keychain auth",
        osc: zh ? "OSC 7 已同步" : "OSC 7 synced",
        sftp: zh ? "✔ SFTP 窗口已打开 — 拖拽即可上传" : "✔ SFTP window opened — drag & drop to upload",
        split: zh ? "✔ 已垂直分屏（⇧⌘D）" : "✔ Split vertically (⇧⌘D)",
      };
      return [
        {
          cmd: "ssh prod-server",
          outputs: [
            { html: t.connected + " · " + t.osc, cls: "term-ok" },
            { html: promptHtml("deploy@prod", "/var/www") + '<span class="term-cmd">docker ps</span>' },
            { html: "CONTAINER   STATUS         PORTS", cls: "term-out" },
            { html: "nginx      Up 12 days     0.0.0.0:443", cls: "term-out" },
            { html: "postgres   Up 12 days     5432", cls: "term-out" },
            { html: promptHtml("deploy@prod", "/var/www") + '<span class="term-cmd">sftp .</span>' },
            { html: t.sftp, cls: "term-ok" },
          ],
        },
        {
          cmd: "split",
          outputs: [
            { html: t.split, cls: "term-ok" },
          ],
        },
      ];
    }

    async function runDemo() {
      const script = buildScript();
      for (const step of script) {
        await typeCommand(step.cmd);
        await showOutputs(step.outputs);
        await sleep(reduceMotion ? 200 : 500);
      }
      // 结尾：稍作停顿后循环
      await sleep(reduceMotion ? 600 : 2600);
      history.innerHTML = "";
      runDemo();
    }

    // 首屏延迟启动，等 Hero 稳定
    setTimeout(runDemo, reduceMotion ? 100 : 700);
  }
})();
