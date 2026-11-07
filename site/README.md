# DANGO 官网 · https://dangoai.org

DANGO 的静态官网：首页按发布片的顺序讲 DANGO 是什么，再接老板人格（ABTI）的图鉴和说明——看到别人分享卡的人扫码进来，了解 16 型、怎么算，然后下载 App。中文在根目录，英文在 `/en/`，每页都有中文 / English 切换。

## 页面

| 路径 | 内容 |
| --- | --- |
| `/`、`/en/` | 首页（`site/home.py`）：标语和办公室、账单 vs 值多少、每一步该请谁、20 种职业的时薪、角落里的团子和面板、四个 AI 工具、老板人格（四个字母、总卡、16 型）、分享图、隐私、结尾下载 |
| `/types/`、`/en/types/` | 16 型图鉴：左边放权派、右边微操派，同一行是绝配 |
| `/t/XXXX/`、`/en/t/XXXX/` | 每型一页（分享卡上的二维码指向这里）：场景大图、吐槽、画像、四个字母、绝配、下载入口，带 Open Graph / Twitter 分享信息 |
| `/how/`、`/en/how/` | 怎么算：四个字母的规则、公司规模档、压榨率档、8 个角色和 6 个隐藏款 |
| `/download/Dango-<版本>.dmg` | 安装包（版本取 Cargo.toml）。**现在还没上传**：只有 `DANGO_SHIP_DMG=1` 构建时才从 `target/dist/` 拷进来 |

## 构建

在仓库根目录运行：

```bash
python3 -I site/build.py
```

- 读 `assets/abti.json`（全部文案和门槛）、`assets/occupations.toml`（职业和时薪）、`apps/widget/assets/abti/` 里的图和 `site/media/` 里 App 自己渲染的图，整站写到 `site/dist/`（每次先清空再写）。改了 abti.json 的文案或门槛，重新构建就会更新。
- `site/media/` 由 `python3 -I site/render_media.py` 生成（要先 `cargo build --release` 和 `apps/widget/build.sh`）：每个职业和角色的团子、办公室、面板、分享图、总卡和角落宠物，用的是本机数据 ×0.6、去掉了所有会话标题和项目名的示例数据。截图一律加 `--light --hour 12`（不跟本机的深色模式和钟点走），办公室再加 `--scale 2.5` 出 1960×890，给首页 980 css px 宽的 Retina 显示。改了团子或界面再跑它；面板上「今天」的数字跟跑的时刻有关，半夜刚过时很小。
- 宣传片：`site/video/promo-<语言>.mp4`、`.vtt` 字幕和 `-poster.webp` 海报，构建时拷到 `dist/video/`；有哪个语言的片子，那个语言的首页 hero 下面才有「认识一下团子们」一段（`preload="none"`，点了才下载）。现在只有英文版，来自 `~/dango-promo-video/dango_promo_en_16x9.mp4`（中文版还是旧的 DONGO 品牌，没放）。片子更新后重新转：`ffmpeg -i <成片> -c:v libx264 -preset slow -crf 24 -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 128k site/video/promo-en.mp4`（本机 `~/bin/ffmpeg` 是 x86 的，用 `~/dango-promo-video/.venv` 里 imageio_ffmpeg 带的），SRT 换成 VTT（逗号改点、加 `WEBVTT` 头），封面用 `cover_en_horizontal_16x9.png`。片子里是真实累计数字，和站上其他地方的示例数据不同。
- 安装包默认不放进站点（2026-11-07 用户：先不上传，以后要传）。要上传时 `DANGO_SHIP_DMG=1 python3 -I site/build.py`，要先有 `target/dist/Dango-<版本>.dmg`（`apps/widget/package.sh`）。没上传时下载按钮仍指向 `/download/…`，站点没有 404 页，Pages 会回首页。Cloudflare Pages 单个文件上限 25 MiB，现在的 dmg 是 23.3 MiB。
- 需要 Pillow（`-I` 模式下脚本会自己找用户目录里的 Pillow）。
- 页面用 WebP 图；`img/og/` 里的 PNG 只给 og:image 用。
- 样式只有一个文件 `site/site.css`，构建时拷到 `dist/assets/site.css`。首页学苹果官网的简洁（2026-11-08 用户：「像苹果官网一样」，随后「我想要的是那种简洁的风格，而不是完全抄」），但用 DANGO 自己的样子：墨黑胶囊按钮、办公室插画的暖米色分段、钱数字用绿色、等宽字体的章节编号（01 / 账单 … 按宣传片的叙事顺序）、细边白卡片、嵌在页面里的深色圆角面板；宣传片从「看宣传片」弹全屏播放；首页样式都在 `main.home` 下，子页面不受影响，只共用顶部毛玻璃导航、按钮和页脚。
- CSS、图片和视频的地址带内容指纹（`?v=` + md5 前 10 位，build.py `ver()`）：Pages 给这些文件 4 小时浏览器缓存，不带指纹的话改了要等缓存过期才看得到。
- `build.py` 顶部：`SITE_URL`（拼 og:image 等绝对地址，默认 `https://dangoai.org`，可用环境变量 `DANGO_SITE_URL` 改；dango.app 不是我们的）和 `DOWNLOAD_URL`（`/download/Dango-<版本>.dmg`，站内地址）。

本地预览：

```bash
cd site/dist && python3 -m http.server 8765
```

## 部署

Cloudflare Pages 项目 `dangoai`（账号 40abedc1905275c7fc6911fa5e1925cf，和 awesomestock.xyz 同一个），直接上传 `site/dist`，不连 Git：

```bash
python3 -I site/build.py
wrangler pages deploy site/dist --project-name dangoai --branch main --commit-dirty=true
```

- `wrangler whoami` 说没登录就先 `wrangler login`（浏览器里点 Allow）。
- 地址：https://dangoai.org、https://www.dangoai.org（项目的自定义域名），备用 https://dangoai.pages.dev。域名在 Cloudflare Registrar 注册（2026-11-07），DNS 也在 Cloudflare：`@` 和 `www` 各一条 CNAME → `dangoai.pages.dev`（代理开着）。wrangler 的登录没有 DNS 权限，这两条记录是在后台手动加的；之后 Pages 自定义域名约 5 分钟变成 active。本机开着 Clash 时，如果它在加记录前查过这个域名，会缓存旧结果，打不开就清 Clash 的 DNS 缓存或重启内核（直连和手机流量能打开就说明站点没问题）。
- 分享卡的二维码：中文版指向 `/t/XXXX/`，英文版指向 `/en/t/XXXX/`。
