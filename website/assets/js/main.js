/* ============================================================
   Bonk — Main interactions
   导航滚动态 / 移动端菜单 / 滚动入场动画 / GitHub Star 计数
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
    // 点击导航链接后收起菜单
    nav.querySelectorAll(".nav__link").forEach((link) => {
      link.addEventListener("click", closeMenu);
    });
  }

  /* ---------- 3. 滚动入场动画 (IntersectionObserver) ---------- */
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
      { threshold: 0.12, rootMargin: "0px 0px -60px 0px" }
    );
    revealEls.forEach((el) => io.observe(el));
  } else {
    // 降级：直接显示
    revealEls.forEach((el) => el.classList.add("is-visible"));
  }

  /* ---------- 4. 平滑滚动（兼容旧浏览器） ---------- */
  document.querySelectorAll('a[href^="#"]').forEach((anchor) => {
    anchor.addEventListener("click", (e) => {
      const href = anchor.getAttribute("href");
      if (href === "#" || href.length < 2) return;
      const target = document.querySelector(href);
      if (target) {
        e.preventDefault();
        const navHeight = nav ? nav.offsetHeight : 0;
        const top =
          target.getBoundingClientRect().top + window.scrollY - navHeight - 8;
        window.scrollTo({ top, behavior: "smooth" });
      }
    });
  });

  /* ---------- 5. 终端打字机效果 ---------- */
  const termBody = document.getElementById("term-body");
  if (termBody && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    const lines = Array.from(termBody.querySelectorAll("[data-typed]"));
    lines.forEach((line, i) => {
      line.style.opacity = "0";
      line.style.transform = "translateY(4px)";
      line.style.transition = "opacity 0.4s ease, transform 0.4s ease";
    });
    // 首屏延迟启动，让 Hero 先稳定
    setTimeout(() => {
      lines.forEach((line, i) => {
        setTimeout(() => {
          line.style.opacity = "1";
          line.style.transform = "translateY(0)";
        }, i * 280);
      });
    }, 600);
  }
})();
