# dango 官网

纯静态网站，不需要构建，也没有依赖。上传整个文件夹就能用。

```
dango-website/
├── index.html            整个页面（样式、脚本、中英文文案都在这一个文件里）
├── favicon.svg           浏览器标签图标
├── apple-touch-icon.png  iPhone 添加到主屏幕时的图标
├── og.png                分享到微信、X 等平台时的预览图（1200×630）
└── img/                  插画和团子动作图
    ├── office/           办公室三层（白天、黄昏、夜晚的背景，家具后层和前层）
    ├── a/                团子动作（跳、落地、挥手、工作、睡觉……）
    ├── j/                这一周的 6 张手账照片
    ├── t/                16 种老板的场景图
    ├── p/                首屏趴在窗口上的那只
    └── R*.png H1.png     团子排队时的站姿
```

## 本地预览

```bash
cd dango-website
python3 -m http.server 8000
# 打开 http://localhost:8000
```

直接双击 `index.html` 也能看，但建议用上面的方式，和线上环境一致。

## 部署

线上是 Cloudflare Pages 的 `dangoai` 项目（https://dangoai.org，www 也指过来）。在仓库根目录：

```bash
rsync -a --delete --exclude README.md --exclude dist --exclude render_app.py --exclude pages site/ site/dist/
node tools/build-i18n.mjs site/index.html site/dist
node tools/build-pages.mjs site/pages site/dist
npx wrangler pages deploy site/dist --project-name dangoai --branch main --commit-dirty=true
tools/indexnow.sh
```

第三步（2026-11-10，按上线文档的 GEO 一节「回答具体问题的页面」）生成回答具体问题的页面，英文在根目录、中文在 `/zh/` 下：`/claude-code-cost/`（怎么看 Claude Code、Codex 花了多少）、`/claude-code-menu-bar/`（Mac 菜单栏工具对比）、`/ai-work-value/`（值多少钱的算法、20 个职业时薪表、局限）、`/privacy/`（读哪些文件、记哪些字段）、`/abti/` 和 16 个 `/abti/<类型小写>/`（从 assets/abti.json 生成，也是分享卡的落地页）。正文在 `site/pages/<名字>.en.html` / `.zh.html`，开头注释写 title 和 description，第一个 `<p class="answer">` 是直接回答（AI 引用的就是这段），`<details>` 是 FAQ。首页底部有一排链接指向它们。最后一步把站点地图里的网址用 IndexNow 报给 Bing 等搜索引擎（钥匙是 site 里那个 32 位十六进制名字的 txt）。

中间那步（2026-11-10，按「DANGO 上线准备」文档）从 `site/index.html` 生成每种语言一个网址：英文是首页 `/`，其他在 `/zh/`、`/ko/`、`/ja/`、`/fr/`、`/es/`，正文都已经翻好（不执行 JS 的爬虫也看得到），再加上 canonical、hreflang、og、JSON-LD（SoftwareApplication + FAQ）和 `sitemap.xml`。不跑这步，线上就只有一个没翻译的源页面。

`_redirects` 把旧网站的地址（/types/、/how/、/t/…）转到这一页对应的位置，旧的 /en/ 转到首页，/install.sh、/install.ps1 转到 GitHub 最新版的安装脚本，别删。`robots.txt`、`llms.txt`、`404.html` 也在这里（有了 404.html，不存在的地址才返回真正的 404）。

## 上线前要改的地方

1. **下载链接**：都指向 GitHub Releases 的 latest（`Dango-macOS.dmg`、`Dango-Windows-x64-setup.exe`），发新版不用改网站。
2. **分享图地址**：`og:image` 和 `og:url` 已经是完整网址 https://dangoai.org/。
3. **示例数字**：页面上的金额、小时数都是示例，并已标注「示例」。

## 中英文

- 每种语言一个网址：英文 `/`，中文 `/zh/`，韩日法西 `/ko/`、`/ja/`、`/fr/`、`/es/`。右上角下拉框跳到对应网址。
- 浏览器是另外五种语言的访客打开英文首页，底部会出现一个「查看中文版 →」这样的链接，不自动跳转（搜索引擎才能收录英文首页）。
- 旧链接 `?lang=xx` 会跳到那种语言的网址。本地直接打开 `site/index.html`（没经过构建）时是英文，`?lang=` 在原地切换。
- 英文文案都在 `index.html` 脚本里的 `var EN = {...}` 中，格式是 `"中文原文": "English"`。改中文文案时，记得同步改这里的键，否则那一句会在英文版里保持中文。
- 16 种老板的英文名字、吐槽和绝配句在 `var TE = {...}` 里，来自产品的 abti.json。

## 字体

页面用系统字体显示中文（Mac 上是苹方），只从 Google Fonts 额外加载三种小字体：JetBrains Mono（数字）、Long Cang（手账手写体）、Caveat（英文手写体）。字体是不阻塞加载的：如果 Google Fonts 打不开（比如在中国大陆），页面照常显示，只是换成系统自带的等宽和楷体。

## 其他

- 访客系统开了「减少动态效果」时，开场动画和图鉴滚动会自动停下，直接显示最终画面。
- 深色模式跟随系统设置。
- 页面里的产品面板是按「DONGO · 面板设计」里的 v3 版本做的，品牌名已改成 dango，界面以实际版本为准。
