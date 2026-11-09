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
rsync -a --delete --exclude README.md --exclude dist site/ site/dist/
npx wrangler pages deploy site/dist --project-name dangoai --branch main --commit-dirty=true
```

`_redirects` 把旧网站的地址（/en/、/types/、/how/、/t/…）转到这一页对应的位置，别删。

## 上线前要改的地方

1. **下载链接**：`https://www.dangoai.org/download/Dango-0.1.0.dmg`，在 `index.html` 里出现 4 次。安装包还没上传（Cloudflare Pages 单个文件上限 25 MiB，dmg 现在约 31 MB，要放 R2 或缩小），上传后核对这个地址。
2. **分享图地址**：`og:image` 和 `og:url` 已经是完整网址 https://dangoai.org/。
3. **示例数字**：页面上的金额、小时数都是示例，并已标注「示例」。

## 中英文

- 右上角按钮切换语言。第一次访问时按浏览器语言自动选择，之后记住访客的选择。
- 链接后面加 `?lang=en` 或 `?lang=zh` 可以固定语言，适合分别发给中英文用户。
- 英文文案都在 `index.html` 脚本里的 `var EN = {...}` 中，格式是 `"中文原文": "English"`。改中文文案时，记得同步改这里的键，否则那一句会在英文版里保持中文。
- 16 种老板的英文名字、吐槽和绝配句在 `var TE = {...}` 里，来自产品的 abti.json。

## 字体

页面用系统字体显示中文（Mac 上是苹方），只从 Google Fonts 额外加载三种小字体：JetBrains Mono（数字）、Long Cang（手账手写体）、Caveat（英文手写体）。字体是不阻塞加载的：如果 Google Fonts 打不开（比如在中国大陆），页面照常显示，只是换成系统自带的等宽和楷体。

## 其他

- 访客系统开了「减少动态效果」时，开场动画和图鉴滚动会自动停下，直接显示最终画面。
- 深色模式跟随系统设置。
- 页面里的产品面板是按「DONGO · 面板设计」里的 v3 版本做的，品牌名已改成 dango，界面以实际版本为准。
