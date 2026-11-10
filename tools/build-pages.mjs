#!/usr/bin/env node
// dangoai.org's answer pages: one page per question people ask AI (the launch plan's GEO
// section, "回答具体问题的页面"), and one page per ABTI type.
//
//   node tools/build-pages.mjs site/pages site/dist
//
// Run after tools/build-i18n.mjs (it adds these pages to the sitemap.xml that one writes).
// Reads site/pages/<slug>.en.html and <slug>.zh.html and assets/abti.json, and writes
//   <slug>/index.html, zh/<slug>/index.html      English at the root, Chinese under /zh/
//   abti/, abti/<type>/, zh/abti/, zh/abti/<type>/ the 16 ABTI types, from abti.json
// each with canonical, hreflang, og tags and JSON-LD (the page, its breadcrumbs, its FAQ).
// A page file starts with a comment holding `title:` and `description:`; its first <p> is the
// direct answer (the part AI quotes); <details><summary>Q</summary><p>A</p></details> become
// the FAQ. No dependencies (Node 18+).

import { readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ORIGIN = 'https://dangoai.org';
const LANGS = ['en', 'zh'];
const HTML_LANG = { en: 'en', zh: 'zh-CN' };
const OG_LOCALE = { en: 'en_US', zh: 'zh_CN' };
const UPDATED = '2026-11-10';
const V = '20261110'; // the site's cache version for shared images

const [srcDir = 'site/pages', dir = 'site/dist'] = process.argv.slice(2);
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const abti = JSON.parse(readFileSync(join(root, 'assets/abti.json'), 'utf8'));

const pre = (lang) => (lang === 'en' ? '' : `/${lang}`);
const url = (lang, path) => `${ORIGIN}${pre(lang)}/${path ? path + '/' : ''}`;
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const strip = (s) => s.replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/\s+/g, ' ').trim();

// The one-line introduction every channel uses (the launch plan's 统一口径 tab).
const INTRO = {
  en: "DANGO is a free Mac menu bar app that tallies how much work Claude Code, Codex and other AI tools did for you, what it cost and what it's worth.",
  zh: 'DANGO 是一个免费的 Mac 菜单栏应用，帮你统计 Claude Code、Codex 等 AI 工具替你干了多少活、花了多少钱、值多少钱。',
};

// The guides, in the order the footer lists them.
const GUIDES = ['claude-code-cost', 'claude-code-menu-bar', 'ai-work-value', 'abti', 'privacy'];
const NAV = {
  en: { 'claude-code-cost': 'Claude Code & Codex cost', 'claude-code-menu-bar': 'Mac menu bar tools', 'ai-work-value': 'What AI work is worth', abti: 'The 16 ABTI types', privacy: 'Privacy' },
  zh: { 'claude-code-cost': 'Claude Code 和 Codex 花了多少', 'claude-code-menu-bar': 'Mac 菜单栏工具', 'ai-work-value': 'AI 的活值多少钱', abti: '16 种 ABTI 人格', privacy: '隐私说明' },
};
const T = {
  en: { home: 'Home', download: 'Download', other: '中文', otherLang: 'zh', free: 'Free · macOS 13+ · Windows 10+ (preview) · Runs on your computer', get: 'Download DANGO', oneline: 'Or install from Terminal:', updated: 'Updated', guides: 'Guides', tagline: 'DANGO · Your AI team’s little office on your Mac', faq: 'Questions', allTypes: 'All 16 ABTI types', you: 'Best match' },
  zh: { home: '首页', download: '下载', other: 'English', otherLang: 'en', free: '免费 · macOS 13 起 · Windows 10 起（预览版）· 全在本机算', get: '下载 DANGO', oneline: '也可以在终端里一行装好：', updated: '更新于', guides: '说明', tagline: 'DANGO · 住在你 Mac 上的 AI 团队小办公室', faq: '常见问题', allTypes: '全部 16 种 ABTI 人格', you: '最佳搭档' },
};

const CSS = `
:root{--page:#F2F3F5;--panel:#FFFFFF;--tile:#F6F6F7;--ink:#1C1C1C;--sub:#5F6068;--faint:#8A8B93;--line:#E3E4E8;--mark:#2F7BF5;--good:#16A34A;--bad:#DC2626;
--sans:-apple-system,BlinkMacSystemFont,"PingFang SC","Noto Sans SC","Helvetica Neue","Hiragino Sans GB","Microsoft YaHei",sans-serif;--mono:"SF Mono",ui-monospace,Menlo,Consolas,monospace}
@media (prefers-color-scheme: dark){:root{--page:#0E0F12;--panel:#17181C;--tile:#1F2025;--ink:#F1F1EF;--sub:#A3A4AC;--faint:#74757D;--line:#2A2B31;--mark:#5C97F7;--good:#3CC07E;--bad:#F87171}}
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--ink);font-family:var(--sans);font-size:16px;line-height:1.75;-webkit-font-smoothing:antialiased}
a{color:var(--mark);text-decoration:none}a:hover{text-decoration:underline}
.wrap{max-width:760px;margin:0 auto;padding:0 16px}
header.top{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--page) 88%,transparent);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);border-bottom:1px solid var(--line)}
header.top .wrap{max-width:1040px;display:flex;align-items:center;justify-content:space-between;height:56px;gap:12px}
.brand{display:flex}.brand img{height:24px;width:auto}.lg-d{display:none}
@media (prefers-color-scheme: dark){.lg-l{display:none}.lg-d{display:block}}
header nav{display:flex;align-items:center;gap:16px;font-size:14px;white-space:nowrap}
header nav a{color:var(--sub)}
.btn{display:inline-flex;align-items:center;gap:6px;background:var(--ink);color:var(--page)!important;border-radius:999px;padding:7px 16px;font-weight:600;font-size:14px}
.btn:hover{text-decoration:none;opacity:.9}
main{padding:28px 0 56px}
.crumbs{font-size:13px;color:var(--faint);margin:0 0 18px}.crumbs a{color:var(--faint)}
h1{font-size:clamp(28px,5vw,40px);line-height:1.25;margin:0 0 18px;letter-spacing:-.01em}
h2{font-size:22px;line-height:1.35;margin:44px 0 12px}
h3{font-size:17px;margin:28px 0 8px}
p{margin:0 0 14px}
.answer{font-size:18px;line-height:1.7;background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--mark);border-radius:12px;padding:16px 20px;margin:0 0 24px}
ul,ol{padding-left:22px;margin:0 0 14px}li{margin:4px 0}
code{font-family:var(--mono);font-size:.88em;background:var(--tile);border:1px solid var(--line);border-radius:6px;padding:1px 6px;overflow-wrap:anywhere}
pre{background:var(--tile);border:1px solid var(--line);border-radius:10px;padding:12px 14px;overflow-x:auto;margin:0 0 14px}pre code{background:none;border:0;padding:0}
.tw{overflow-x:auto;margin:0 0 16px;border:1px solid var(--line);border-radius:12px;background:var(--panel)}
table{border-collapse:collapse;width:100%;font-size:14.5px}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:0}th{font-weight:600;color:var(--sub);background:var(--tile)}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.note{font-size:14px;color:var(--sub)}
details{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 16px;margin:0 0 10px}
summary{cursor:pointer;font-weight:600}details p{margin:10px 0 0;color:var(--sub)}
.cta{margin:48px 0 0;background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:22px}
.cta p{margin:0 0 12px}.cta .small{font-size:13px;color:var(--faint);margin:12px 0 0}
.type-hero{display:grid;grid-template-columns:200px 1fr;gap:20px;align-items:center;margin:0 0 20px}
.type-hero img{width:100%;height:auto;border-radius:16px;background:var(--panel);border:1px solid var(--line)}
.code{font-family:var(--mono);font-weight:600;letter-spacing:.06em;color:var(--sub)}
blockquote{margin:0 0 16px;padding:4px 0 4px 16px;border-left:3px solid var(--line);color:var(--sub);font-size:17px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:10px;margin:0 0 16px}
.grid a{display:block;background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:10px 12px;color:var(--ink)}
.grid a:hover{border-color:var(--mark);text-decoration:none}.grid a b{font-family:var(--mono);font-size:13px;color:var(--sub);display:block}
.grid a.on{border-color:var(--mark)}
footer{border-top:1px solid var(--line);padding:24px 0 40px;font-size:13px;color:var(--faint)}
footer nav{display:flex;flex-wrap:wrap;gap:6px 18px;margin:0 0 10px}footer nav a{color:var(--sub)}
@media (max-width:560px){.type-hero{grid-template-columns:1fr}.type-hero img{max-width:220px}header nav .hide-s{display:none}}
`;

function head({ lang, path, title, description, image, jsonld }) {
  const alt = (l) => `<link rel="alternate" hreflang="${HTML_LANG[l]}" href="${url(l, path)}">`;
  return `<!doctype html>
<html lang="${HTML_LANG[lang]}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<link rel="canonical" href="${url(lang, path)}">
${LANGS.map(alt).join('\n')}
<link rel="alternate" hreflang="x-default" href="${url('en', path)}">
<meta property="og:type" content="article">
<meta property="og:site_name" content="DANGO">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${url(lang, path)}">
<meta property="og:image" content="${image || `${ORIGIN}/og.png`}">
<meta property="og:locale" content="${OG_LOCALE[lang]}">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="/favicon.png?v=${V}" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png?v=${V}">
<style>${CSS.trim()}</style>
<script type="application/ld+json">
${JSON.stringify({ '@context': 'https://schema.org', '@graph': jsonld }, null, 1).replace(/</g, '\\u003c')}
</script>
</head>`;
}

function shell({ lang, path, crumbs, body }) {
  const t = T[lang];
  const home = `${pre(lang)}/`;
  const other = t.otherLang;
  const crumbHtml = crumbs.map(([name, p], i) => (i < crumbs.length - 1 ? `<a href="${pre(lang)}/${p ? p + '/' : ''}">${esc(name)}</a> / ` : esc(name))).join('');
  return `<body>
<header class="top"><div class="wrap">
  <a class="brand" href="${home}" aria-label="DANGO"><img class="lg-l" src="/img/logo-light.webp?v=${V}" width="147" height="28" alt="DANGO"><img class="lg-d" src="/img/logo-dark.webp?v=${V}" width="144" height="28" alt="DANGO"></a>
  <nav><a class="hide-s" href="${pre(lang)}/abti/">ABTI</a><a href="${pre(other)}/${path ? path + '/' : ''}" hreflang="${HTML_LANG[other]}" lang="${HTML_LANG[other]}">${t.other}</a><a class="btn" href="${home}#install">${t.download}</a></nav>
</div></header>
<main><div class="wrap">
<p class="crumbs">${crumbHtml}</p>
${body}
<div class="cta">
  <p>${esc(INTRO[lang])}</p>
  <p><a class="btn" href="${home}#install">${t.get}</a></p>
  <p class="note">${t.oneline} <code>curl -fsSL https://dangoai.org/install.sh | sh</code></p>
  <p class="small">${t.free} · <a href="https://github.com/justinz183/dango">GitHub</a></p>
</div>
</div></main>
<footer><div class="wrap">
  <nav aria-label="${t.guides}"><a href="${home}">${t.home}</a>${GUIDES.map((g) => `<a href="${pre(lang)}/${g}/">${esc(NAV[lang][g])}</a>`).join('')}<a href="https://github.com/justinz183/dango">GitHub</a></nav>
  <div>${esc(t.tagline)} · ${t.updated} ${UPDATED}</div>
</div></footer>
</body>
</html>
`;
}

const app = { '@type': 'SoftwareApplication', '@id': `${ORIGIN}/#app`, name: 'DANGO', url: `${ORIGIN}/`, applicationCategory: 'DeveloperApplication', operatingSystem: 'macOS 13+, Windows 10+', offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' } };

function graph({ lang, path, title, description, crumbs, faq, type = 'Article' }) {
  const g = [
    {
      '@type': type,
      headline: title,
      name: title,
      description,
      url: url(lang, path),
      inLanguage: HTML_LANG[lang],
      dateModified: UPDATED,
      author: { '@type': 'Organization', name: 'DANGO', url: `${ORIGIN}/` },
      publisher: { '@type': 'Organization', name: 'DANGO', url: `${ORIGIN}/`, logo: `${ORIGIN}/apple-touch-icon.png` },
      isPartOf: { '@type': 'WebSite', name: 'DANGO', url: `${ORIGIN}/` },
      about: app,
    },
    {
      '@type': 'BreadcrumbList',
      itemListElement: crumbs.map(([name, p], i) => ({ '@type': 'ListItem', position: i + 1, name, item: url(lang, p) })),
    },
  ];
  if (faq.length)
    g.push({ '@type': 'FAQPage', inLanguage: HTML_LANG[lang], mainEntity: faq.map(({ q, a }) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })) });
  return g;
}

const faqOf = (html) => [...html.matchAll(/<details>\s*<summary>([\s\S]*?)<\/summary>([\s\S]*?)<\/details>/g)].map((m) => ({ q: strip(m[1]), a: strip(m[2]) }));

function write(lang, path, html) {
  const out = join(dir, lang === 'en' ? '' : lang, path);
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, 'index.html'), html);
}

const built = []; // [path] — every page exists in both languages

// ───────── the guides, from site/pages ─────────
for (const slug of GUIDES.filter((g) => g !== 'abti')) {
  for (const lang of LANGS) {
    const src = readFileSync(join(srcDir, `${slug}.${lang}.html`), 'utf8');
    const meta = Object.fromEntries([...(src.match(/^<!--([\s\S]*?)-->/) || ['', ''])[1].matchAll(/^\s*(\w+):\s*(.+)$/gm)].map((m) => [m[1], m[2].trim()]));
    if (!meta.title || !meta.description) throw new Error(`${slug}.${lang}.html: no title or description in its first comment`);
    const body = src.replace(/^<!--[\s\S]*?-->\s*/, '').trim();
    const crumbs = [[T[lang].home, ''], [NAV[lang][slug], slug]];
    const jsonld = graph({ lang, path: slug, title: meta.title, description: meta.description, crumbs, faq: faqOf(body) });
    write(lang, slug, head({ lang, path: slug, title: `${meta.title} · DANGO`, description: meta.description, jsonld }) + '\n' + shell({ lang, path: slug, crumbs, body }));
  }
  built.push(slug);
}

// ───────── ABTI: the index and the 16 types, from assets/abti.json ─────────
const D = abti.dimensions;
const dimOrder = D.order; // hands_off, build, range, hours
const typeKeys = Object.keys(abti.types).sort();
const nm = (lang, o) => (lang === 'en' ? o.name_en : o.name_zh);
const line = (lang, o, k) => (lang === 'en' ? o[`${k}_en`] : o[`${k}_zh`]);
const pct = (x) => `${Math.round(x * 100)}%`;

// What each letter means and how it is worked out, in words (thresholds from abti.json).
function rules(lang) {
  const h = D.hands_off, b = D.build, r = D.range, o = D.hours;
  return lang === 'en'
    ? {
        hands_off: `A turn is hands-off when the AI makes ${h.min_tool_calls} or more tool calls in a row or sends out a subagent. More than ${pct(h.threshold)} of your turns hands-off → <b>H</b>, otherwise <b>M</b>.`,
        build: `Lines written into new files ÷ all lines changed (added + removed). Over ${pct(b.threshold)} → <b>B</b>, otherwise <b>F</b>.`,
        range: `Of the 8 roles (a hidden role counts as one more), how many take at least ${pct(r.role_share_min)} of the value. ${r.min_roles} or more → <b>G</b>, otherwise <b>S</b>.`,
        hours: `Minutes worked between ${o.night_start}:00 and ${o.night_end}:00 local time ÷ all minutes worked. Over ${pct(o.threshold)} → <b>O</b>, otherwise <b>L</b>.`,
      }
    : {
        hands_off: `一个回合里 AI 连续调用工具 ${h.min_tool_calls} 次以上，或者派出了子 agent，算放手回合。放手回合超过全部回合的 ${pct(h.threshold)} → <b>H</b>，否则 <b>M</b>。`,
        build: `新建文件里写的行数 ÷ 全部改动行数（新增 + 删除）。超过 ${pct(b.threshold)} → <b>B</b>，否则 <b>F</b>。`,
        range: `8 个角色里（隐藏款各算一个），占产出金额 ${pct(r.role_share_min)} 以上的有几个。${r.min_roles} 个及以上 → <b>G</b>，否则 <b>S</b>。`,
        hours: `本地时间晚上 ${o.night_start} 点到早上 ${o.night_end} 点之间的工作分钟 ÷ 全部工作分钟。超过 ${pct(o.threshold)} → <b>O</b>，否则 <b>L</b>。`,
      };
}
const dimName = (lang, k) => {
  const d = D[k], names = lang === 'en' ? d.name_en : d.name_zh;
  return `${d.letters[0]} ${names[0]} / ${d.letters[1]} ${names[1]}`;
};
function rulesTable(lang, code) {
  const R = rules(lang);
  const hd = lang === 'en' ? ['Dimension', 'How it is worked out'] : ['维度', '怎么算'];
  const rows = dimOrder.map((k, i) => {
    const d = D[k];
    const pick = code ? d.letters.indexOf(code[i]) : -1;
    const names = lang === 'en' ? d.name_en : d.name_zh;
    const label = pick >= 0 ? `<b>${d.letters[pick]}</b> · ${names[pick]}` : dimName(lang, k);
    return `<tr><td>${label}</td><td>${R[k]}</td></tr>`;
  });
  return `<div class="tw"><table><thead><tr><th>${hd[0]}</th><th>${hd[1]}</th></tr></thead><tbody>${rows.join('')}</tbody></table></div>`;
}
const typeGrid = (lang, current) =>
  `<div class="grid">${typeKeys.map((c) => `<a href="${pre(lang)}/abti/${c.toLowerCase()}/"${c === current ? ' class="on" aria-current="page"' : ''}><b>${c}</b>${esc(nm(lang, abti.types[c]))}</a>`).join('')}</div>`;
const tiers = (lang) =>
  abti.scale_tiers.map((t) => `<tr><td>${esc(nm(lang, t))}</td><td class="n">${t.min_usd ? '$' + t.min_usd.toLocaleString('en-US') + '+' : '$0+'}</td><td>${esc(line(lang, t, 'line'))}</td></tr>`).join('');

const ABTI_TXT = {
  en: {
    title: 'ABTI: the 16 AI boss types, and how DANGO works out yours',
    desc: 'ABTI is DANGO’s 16 AI boss types. No quiz: four letters worked out from your Claude Code and Codex work logs (hands-off or micro, build or fix, specialist or generalist, lark or owl).',
    answer: `<b>ABTI is a four-letter “boss type” that DANGO works out from what your AI agents actually did</b>, not from a quiz. It looks at your Claude Code, Codex, DeepSeek and WorkBuddy work logs on your Mac and asks four questions: do you let the AI run (H) or step in (M), do you build new things (B) or fix existing ones (F), do you stick to one kind of work (S) or spread across many (G), and do you work by day (L) or by night (O). 2 × 2 × 2 × 2 = 16 types.`,
    how: 'How each letter is worked out',
    howNote: 'Exactly half goes to the second letter (M, F, L): the rule says “more than half”. Between 45% and 55% the card shows the number as “≈” in grey, but the letter is still decided by the threshold. Only numbers are used: tool-call counts, line counts, minutes and value per role, never your prompts or code.',
    when: 'Which period it covers',
    whenP: 'Your main ABTI, on the card in the panel, comes from all your history. Every day, week, month and year report also carries that period’s own ABTI, so you can see a week where you were an owl.',
    size: 'Company size',
    sizeP: 'Next to the four letters, the card shows how big your “company” is, from the value of the work your dangos did:',
    sizeHd: ['Size', 'Work value', 'On the card'],
    all: 'The 16 types',
    faq: [
      ['Is ABTI a personality test?', 'No. There are no questions to answer. DANGO calculates it from your AI work logs, the way a pedometer counts steps.'],
      ['Does ABTI read my prompts or code?', 'No. It uses counts only: how many tool calls a turn made, how many lines were written in new files, how many minutes fell at night, and how much value went to each role.'],
      ['Can my type change?', 'Yes. Each report has that period’s own ABTI, and your overall type moves as your history grows.'],
    ],
  },
  zh: {
    title: 'ABTI：16 种 AI 老板人格，DANGO 怎么算出你是哪一种',
    desc: 'ABTI 是 DANGO 的 16 种 AI 老板人格。不用答题：从你 Claude Code、Codex 的工作记录算出四个字母（放权还是微操、开荒还是修缮、专精还是跨界、早鸟还是夜猫）。',
    answer: `<b>ABTI 是 DANGO 根据 AI 实际干的活算出来的四个字母的「老板人格」</b>，不用答题。它在你的 Mac 上看 Claude Code、Codex、DeepSeek、WorkBuddy 的工作记录，回答四个问题：你是放手让 AI 干（H）还是步步插手（M），在做新东西（B）还是修旧东西（F），专攻一种活（S）还是什么都干（G），白天干活（L）还是夜里干活（O）。2 × 2 × 2 × 2 = 16 种。`,
    how: '每个字母怎么算',
    howNote: '正好一半时判第二个字母（M、F、L），因为规则写的是「过半」。比例在 45% 到 55% 之间时，卡片上的数字前加「≈」并显示成灰色，字母仍按门槛判。只用数字：工具调用次数、行数、分钟数、各角色的金额，不看 prompt 和代码。',
    when: '算的是哪段时间',
    whenP: '面板上那张总人格卡用的是全部历史。日报、周报、月报、年报上，还各有这段时间自己的 ABTI，所以能看到「这周我是夜猫」。',
    size: '公司规模',
    sizeP: '四个字母旁边，卡片还会按团子干的活值多少钱，给你的「公司」定一个规模：',
    sizeHd: ['规模', '产出金额', '卡片上的话'],
    all: '16 种人格',
    faq: [
      ['ABTI 是性格测试吗？', '不是，没有题要答。DANGO 从你和 AI 的工作记录里算出来，像计步器数步数一样。'],
      ['算 ABTI 会读我的 prompt 或代码吗？', '不会。只用计数：一个回合调了几次工具、新文件里写了多少行、多少分钟落在夜里、每个角色分到多少金额。'],
      ['我的类型会变吗？', '会。每份报告有那段时间自己的 ABTI，总人格也会随着历史变长而变化。'],
    ],
  },
};
const faqHtml = (lang, items) => `<h2>${T[lang].faq}</h2>\n` + items.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n');

for (const lang of LANGS) {
  const X = ABTI_TXT[lang];
  const crumbs = [[T[lang].home, ''], ['ABTI', 'abti']];
  const body = `<h1>${esc(X.title)}</h1>
<p class="answer">${X.answer}</p>
<h2>${X.how}</h2>
${rulesTable(lang)}
<p class="note">${X.howNote}</p>
<h2>${X.all}</h2>
${typeGrid(lang)}
<h2>${X.when}</h2>
<p>${X.whenP}</p>
<h2>${X.size}</h2>
<p>${X.sizeP}</p>
<div class="tw"><table><thead><tr><th>${X.sizeHd[0]}</th><th class="n">${X.sizeHd[1]}</th><th>${X.sizeHd[2]}</th></tr></thead><tbody>${tiers(lang)}</tbody></table></div>
${faqHtml(lang, X.faq)}`;
  const faq = X.faq.map(([q, a]) => ({ q, a }));
  write(lang, 'abti', head({ lang, path: 'abti', title: `${X.title} · DANGO`, description: X.desc, jsonld: graph({ lang, path: 'abti', title: X.title, description: X.desc, crumbs, faq }) }) + '\n' + shell({ lang, path: 'abti', crumbs, body }));
}
built.push('abti');

for (const code of typeKeys) {
  const t = abti.types[code];
  const mate = abti.types[t.match];
  const slug = `abti/${code.toLowerCase()}`;
  for (const lang of LANGS) {
    const letters = dimOrder.map((k, i) => {
      const d = D[k], j = d.letters.indexOf(code[i]);
      return (lang === 'en' ? d.name_en : d.name_zh)[j];
    });
    const name = nm(lang, t);
    const title = lang === 'en' ? `${code} · ${name}: an ABTI type` : `${code} ${name}：ABTI 人格`;
    const desc =
      lang === 'en'
        ? `${code} (${letters.join(', ')}) is one of DANGO’s 16 ABTI AI boss types: ${t.portrait_en} Worked out from your Claude Code and Codex work logs, no quiz.`
        : `${code}（${letters.join('、')}）是 DANGO 的 16 种 ABTI 老板人格之一：${t.portrait_zh}。从你 Claude Code、Codex 的工作记录算出来，不用答题。`;
    const answer =
      lang === 'en'
        ? `<b>${code} is ${/^The /.test(name) ? '' : 'the '}“${esc(name)}”</b>, one of the 16 ABTI types in DANGO: ${letters.map((w, i) => `${w} (${code[i]})`).join(', ')}. ${esc(t.portrait_en)}`
        : `<b>${code} 是「${esc(name)}」</b>，DANGO 16 种 ABTI 人格之一：${letters.map((w, i) => `${w}（${code[i]}）`).join('、')}。${esc(t.portrait_zh)}。`;
    const img = `/img/t/${code}.webp`;
    const crumbs = [[T[lang].home, ''], ['ABTI', 'abti'], [code, slug]];
    const body = `<div class="type-hero"><img src="${img}" width="560" height="436" alt="${esc(`${code} · ${name}`)}"><div>
<p class="code">ABTI · ${code}</p>
<h1>${esc(name)}</h1>
<blockquote>${esc(line(lang, t, 'roast'))}</blockquote>
</div></div>
<p class="answer">${answer}</p>
<h2>${lang === 'en' ? `${code}, letter by letter` : `${code} 的四个字母`}</h2>
${rulesTable(lang, code)}
<h2>${T[lang].you}: <a href="${pre(lang)}/abti/${t.match.toLowerCase()}/">${t.match} · ${esc(nm(lang, mate))}</a></h2>
<p>${esc(line(lang, t, 'match_line'))}</p>
<h2>${lang === 'en' ? 'How do I find out my type?' : '怎么知道自己是哪一型？'}</h2>
<p>${
      lang === 'en'
        ? `Install DANGO and keep using Claude Code or Codex as usual. It reads the work logs those tools already keep on your Mac, works out your four letters in a few seconds, and tells your ABTI story. <a href="${pre(lang)}/abti/">How ABTI is worked out →</a>`
        : `装上 DANGO，照常用 Claude Code 或 Codex。它读这些工具本来就存在你 Mac 上的工作记录，几秒钟算出你的四个字母，再讲一遍你的 ABTI 故事。<a href="${pre(lang)}/abti/">ABTI 怎么算 →</a>`
    }</p>
<h2>${T[lang].allTypes}</h2>
${typeGrid(lang, code)}`;
    const jsonld = graph({ lang, path: slug, title, description: desc, crumbs, faq: [], type: 'WebPage' });
    write(lang, slug, head({ lang, path: slug, title: `${title} · DANGO`, description: desc, image: `${ORIGIN}${img}`, jsonld }) + '\n' + shell({ lang, path: slug, crumbs, body }));
  }
  built.push(slug);
}

// ───────── sitemap: add every page (both languages, with their alternates) ─────────
const sm = join(dir, 'sitemap.xml');
const map = readFileSync(sm, 'utf8');
if (!map.includes('</urlset>')) throw new Error(`${sm}: no </urlset>; run tools/build-i18n.mjs first`);
const entries = built
  .flatMap((p) =>
    LANGS.map(
      (l) => `  <url>
    <loc>${url(l, p)}</loc>
    <lastmod>${UPDATED}</lastmod>
${LANGS.map((a) => `    <xhtml:link rel="alternate" hreflang="${HTML_LANG[a]}" href="${url(a, p)}"/>`).join('\n')}
    <xhtml:link rel="alternate" hreflang="x-default" href="${url('en', p)}"/>
  </url>`
    )
  )
  .join('\n');
writeFileSync(sm, map.replace(/\n?<\/urlset>/, `\n${entries}\n</urlset>`));

const pages = readdirSync(srcDir).filter((f) => f.endsWith('.html')).length;
console.log(`build-pages: ${built.length} pages × ${LANGS.length} languages (${pages} source files, 16 ABTI types) added to ${dir} and its sitemap.xml`);
