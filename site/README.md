# DANGO · AI 老板人格（ABTI）官网

给 DANGO 老板人格做的静态推广站：看到别人分享卡的人扫码进来，了解 16 型是什么意思、怎么算出来的，然后去下载 App。中文在根目录，英文在 `/en/`，每页都有中文 / English 切换。

## 页面

| 路径 | 内容 |
| --- | --- |
| `/`、`/en/` | 首页：标语、一句话介绍、下载按钮、四个维度、16 型小图、隐私说明 |
| `/types/`、`/en/types/` | 16 型图鉴：左边放权派、右边微操派，同一行是绝配 |
| `/t/XXXX/`、`/en/t/XXXX/` | 每型一页（分享卡上的二维码指向这里）：场景大图、吐槽、画像、四个字母、绝配、下载入口，带 Open Graph / Twitter 分享信息 |
| `/how/`、`/en/how/` | 怎么算：四个字母的规则、公司规模档、压榨率档、8 个角色和 6 个隐藏款 |

## 构建

在仓库根目录运行：

```bash
python3 -I site/build.py
```

- 读 `assets/abti.json`（全部文案和门槛）和 `apps/widget/assets/abti/` 里的图，整站写到 `site/dist/`（每次先清空再写）。改了 abti.json 的文案或门槛，重新构建就会更新。
- 需要 Pillow（`-I` 模式下脚本会自己找用户目录里的 Pillow）。
- 页面用 WebP 图；`img/og/` 里的 PNG 只给 og:image 用。
- 样式只有一个文件 `site/site.css`，构建时拷到 `dist/assets/site.css`。
- `build.py` 顶部两个常量：`SITE_URL`（拼 og:image 等绝对地址，现在是 `https://dango.app`）和 `DOWNLOAD_URL`（下载按钮，现在是占位的 `#download`）。

本地预览：

```bash
cd site/dist && python3 -m http.server 8765
```

## 状态

**还没有部署**。上线前要做：把 `DOWNLOAD_URL` 换成真实下载地址；确认 `SITE_URL` 是最终域名；分享卡的二维码中文版指向 `/t/XXXX/`、英文版指向 `/en/t/XXXX/`。
