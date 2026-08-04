# Bonk 官网

开源免费的 macOS 原生 SSH 终端 [Bonk](https://github.com/iamJoyLiam/Bonk) 的官方网站。
纯 HTML / CSS / JS，零构建、零依赖，可直接部署到 Cloudflare Pages。

## 技术栈

- **HTML** — 单页 `index.html`
- **CSS** — 设计令牌 + base + 组件 + 响应式（4 个文件，移动优先）
- **JS** — 原生，无框架：i18n 双语切换 / 滚动动画 / 下载架构识别
- **字体** — Google Fonts：Inter（UI）+ JetBrains Mono（终端/代码）
- **图标** — 全部内联 SVG（无 emoji）

## 目录结构

```
website/
├── index.html              # 单页（8 个 section）
├── assets/
│   ├── css/
│   │   ├── tokens.css      # 设计令牌（颜色/字体/间距/动效）
│   │   ├── base.css        # reset + 排版
│   │   ├── components.css   # 导航/按钮/卡片/终端 mockup
│   │   └── responsive.css  # 375 / 768 / 1024 / 1440 断点
│   └── js/
│       ├── i18n.js         # 中英双语数据 + 切换（localStorage 记忆）
│       ├── main.js         # 导航/滚动动画/平滑滚动/GitHub Star
│       └── download.js     # 自动判断 Apple Silicon / Intel
└── README.md
```

## 本地预览

```bash
cd website
# 任选其一：
python3 -m http.server 8000
# 或
npx serve .
```

浏览器打开 `http://localhost:8000`。

## 部署到 Cloudflare Pages

### 方式 A：直传（最快，零配置）

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/) → Workers & Pages → Create
2. 选 **Upload assets**（直接上传）
3. 把整个 `website/` 目录的内容拖进去（注意：是 `website/` 里面的内容，不是 `website/` 文件夹本身，要让 `index.html` 在根目录）
4. 设置项目名（如 `bonk`）→ Deploy
5. 几秒后拿到 `https://bonk.pages.dev` 链接

### 方式 B：Git 连接（推荐，自动部署）

1. 把 `website/` 目录推到 GitHub 仓库（可放进 Bonk 主仓库，或独立仓库）
2. Cloudflare Pages → Create a project → Connect to Git
3. 配置：
   - **Build command**：留空（无需构建）
   - **Build output directory**：`website`（如果 website 在仓库根；否则填对应路径）
   - **Root directory**：按你的仓库结构调整
4. Save and Deploy → 之后每次 push 自动部署

### 自定义域名

Pages 项目 → Custom domains → Add → 按提示加 CNAME。Cloudflare 自动配 HTTPS。

## 发布新版本时改什么

只需改 **2 处**：

1. **`assets/js/download.js`** 顶部的版本号：
   ```js
    const VERSION = "2026.1.0";  // ← 改成新版本
   ```
2. **`index.html`** 中两处 `v2026.1.0` / `2026.1.0` 文案（Hero meta 和下载区版本号）

下载链接会自动按 `VERSION` 生成，指向对应的 GitHub Release URL。

## 国际化

- 默认中文，顶部 `中 / EN` 切换器
- 语言记忆在 `localStorage`（key: `bonk-lang`）
- 所有文案在 `assets/js/i18n.js` 的 `zh` / `en` 对象里，新增/修改文案在那里改

## 设计令牌

所有颜色、字号、间距、动效都是 CSS 变量，集中在 `tokens.css`。
改一个变量，全站联动。例如换主色调：

```css
:root {
  --accent-violet: #你的颜色;
  --accent-cyan: #你的颜色;
}
```

## 浏览器支持

- 现代浏览器（Chrome / Edge / Firefox / Safari 最新两个大版本）
- `backdrop-filter`（毛玻璃）在不支持的浏览器上会优雅降级为半透明背景
- 完整支持 `prefers-reduced-motion`（减少动效）和键盘导航

## License

与 Bonk 主项目一致（见主仓库 LICENSE）。
