#!/usr/bin/env node
// dangoai.org: one address per language, and the tags search engines and AI crawlers read.
//
//   node tools/build-i18n.mjs site/index.html site/dist
//
// From the page as written (site/index.html: its text is Chinese, the script's EN / LOCAL tables
// translate it) this writes, into the output folder:
//   index.html                   English, the home page (2026-11-10, user: 「官网首页应该是英文的」)
//   zh/ ko/ ja/ fr/ es/index.html the other five, their text already translated, so a crawler that
//                                 runs no JavaScript reads each page in its own language
// each with canonical, hreflang, og tags and JSON-LD (SoftwareApplication + the FAQ), relative
// paths made absolute so the pages in folders find their pictures, and sitemap.xml.
// It always starts from the source page, so it can run again. No dependencies (Node 18+).
//
// From the launch plan's build-i18n.mjs (the "DANGO 上线准备" doc), with English at / instead of
// Chinese.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import vm from 'node:vm';

// ───────── settings ─────────
const ORIGIN = 'https://dangoai.org'; // no www: www.dangoai.org 301s here (a Cloudflare redirect rule)
const LANGS = ['en', 'zh', 'ko', 'ja', 'fr', 'es'];
const HOME = 'en'; // the language at /, and hreflang x-default
const HTML_LANG = { zh: 'zh-CN', en: 'en', ko: 'ko', ja: 'ja', fr: 'fr', es: 'es' };
const OG_LOCALE = { zh: 'zh_CN', en: 'en_US', ko: 'ko_KR', ja: 'ja_JP', fr: 'fr_FR', es: 'es_ES' };

// The same as document.title in the page's setLang().
const TITLES = {
  zh: 'DANGO 小办公室 · 把你的 AI，变成看得见的团队',
  en: 'DANGO · Turn your AI into a team you can see',
  ko: 'DANGO · 당신의 AI를 눈에 보이는 팀으로',
  ja: 'DANGO · あなたの AI を、見えるチームに',
  fr: 'DANGO · Votre IA devient une équipe visible',
  es: 'DANGO · Tu IA, convertida en un equipo visible',
};

// The description: the first screen's paragraph, translated through the page's own tables.
const DESC_KEY = 'DANGO 是住在你 Mac 上的小办公室。写代码、查资料、做图表，你交给 AI 的工作，都有忙碌的团子来呈现。谁在干活、做了什么、完成了多少，抬眼就能看见。';

// Alt text the page's tables do not hold: the key is the Chinese alt written in the page.
const ALT = {
  'DANGO 的面板：办公室、今天的产出、员工名册、工具和日报': {
    en: "DANGO's panel: the office, today's output, the roster, tools and reports",
    ko: 'DANGO 패널: 사무실, 오늘의 산출, 직원 명부, 도구와 리포트',
    ja: 'DANGO のパネル：オフィス、今日の成果、スタッフ名簿、ツールとレポート',
    fr: 'Le panneau DANGO : le bureau, la production du jour, l’équipe, outils et rapports',
    es: 'El panel de DANGO: la oficina, la producción de hoy, el equipo, herramientas e informes',
  },
  'DANGO 的屏幕角落小组件': {
    en: "DANGO's corner widget",
    ko: 'DANGO 화면 구석 위젯',
    ja: 'DANGO の隅っこウィジェット',
    fr: 'Le widget en coin de DANGO',
    es: 'Widget de esquina de DANGO',
  },
};

// The one-line introduction every channel uses (the launch plan's 统一口径 tab), for the
// structured data; the other four languages keep the page's own description.
const INTRO = {
  en: "DANGO is a free Mac menu bar app that tallies how much work Claude Code, Codex and other AI tools did for you, what it cost and what it's worth.",
  zh: 'DANGO 是一个免费的 Mac 菜单栏应用，帮你统计 Claude Code、Codex 等 AI 工具替你干了多少活、花了多少钱、值多少钱。',
};

// The project's other homes.
const SAME_AS = ['https://github.com/justinz183/dango'];
// ────────────────────────────

const [srcPath = 'site/index.html', dir = 'site/dist'] = process.argv.slice(2);
const pageUrl = (l) => (l === HOME ? `${ORIGIN}/` : `${ORIGIN}/${l}/`);
const src = readFileSync(srcPath, 'utf8');

// The tables (EN, LOCAL) from the page's script, without running the rest of it.
const DICT = (() => {
  const script = (src.match(/<script>\s*\(function[\s\S]*?<\/script>/) || [])[0] || '';
  const a = script.indexOf('var EN =');
  const b = script.search(/\n\s*(\/\* One address per language|var BUILT\b|var LANG\b)/);
  if (a < 0 || b < 0) throw new Error('no "var EN =" or the language block after it in the page script: did the tables move?');
  const ctx = {};
  vm.runInNewContext(script.slice(a, b), ctx);
  if (!ctx.EN || !ctx.LOCAL) throw new Error('could not read the EN / LOCAL tables');
  return ctx;
})();
const tr = (lang, k) => (lang === 'zh' ? k : (DICT.LOCAL[lang] && DICT.LOCAL[lang][k]) || DICT.EN[k]);

const decode = (s) =>
  s.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|#39|nbsp);/gi, (m, e) => {
    const k = e.toLowerCase();
    if (k[0] === '#') return String.fromCodePoint(k[1] === 'x' ? parseInt(k.slice(2), 16) : parseInt(k.slice(1), 10));
    return { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' }[k];
  });
const escText = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const escAttr = (s) => escText(s).replace(/"/g, '&quot;');
const stripTags = (s) => decode(s.replace(/<[^>]+>/g, '')).replace(/\s+/g, ' ').trim();

// The page cut into what may change and what may not (scripts, styles, comments).
const PROTECTED = /(<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>|<!--[\s\S]*?-->)/;
const mapOutside = (html, fn) => html.split(PROTECTED).map((p, i) => (i % 2 ? p : fn(p))).join('');
const mapScripts = (html, fn) => html.split(/(<script>[\s\S]*?<\/script>)/).map((p, i) => (i % 2 ? fn(p) : p)).join('');

// The page's own tr() rule: a text node whose trimmed text is a key is replaced; alt and aria-label too.
function translateBody(html, lang) {
  const bs = html.indexOf('<body');
  const be = html.lastIndexOf('</body>');
  const body = mapOutside(html.slice(bs, be), (part) =>
    part
      .replace(/>([^<]+)</g, (m, raw) => {
        const text = decode(raw);
        const k = text.trim();
        if (!k || !(k in DICT.EN)) return m;
        return '>' + escText(text.replace(k, () => tr(lang, k))) + '<';
      })
      .replace(/(\s)(alt|aria-label)="([^"]*)"/g, (m, sp, attr, raw) => {
        const v = decode(raw);
        const t = v in DICT.EN ? tr(lang, v) : ALT[v] && ALT[v][lang];
        return t ? `${sp}${attr}="${escAttr(t)}"` : m;
      })
      .replace(/<option value="(\w+)"( selected)?>/g, (m, v) => `<option value="${v}"${v === lang ? ' selected' : ''}>`)
  );
  return html.slice(0, bs) + body + html.slice(be);
}

// Relative paths start with / (pages in folders need it); www becomes the bare domain.
function fixUrls(html) {
  html = mapOutside(html, (part) =>
    part.replace(/(\s(?:src|href|poster))="(?!https?:|\/|#|data:|mailto:|tel:|javascript:)([^"]+)"/g, '$1="/$2"')
  );
  html = mapScripts(html, (s) => s.replace(/(['"])img\//g, '$1/img/'));
  return html.split('https://www.dangoai.org').join(ORIGIN);
}

function setMeta(html, attr, key, value) {
  const re = new RegExp(`(<meta\\s+${attr}="${key}"\\s+content=")[^"]*(")`);
  if (!re.test(html)) throw new Error(`no <meta ${attr}="${key}"> in the page`);
  return html.replace(re, (m, a, b) => a + escAttr(value) + b);
}

function faqFrom(html) {
  const out = [];
  const re = /<details>\s*<summary>([\s\S]*?)<\/summary>\s*<p>([\s\S]*?)<\/p>\s*<\/details>/g;
  for (let m; (m = re.exec(html)); ) out.push({ q: stripTags(m[1]), a: stripTags(m[2]) });
  return out;
}

function headBlock(html, lang, desc) {
  const downloads = [...new Set([...html.matchAll(/href="([^"]+\.(?:dmg|exe))"/g)].map((m) => m[1]))];
  const app = {
    '@type': 'SoftwareApplication',
    '@id': `${ORIGIN}/#app`, // the answer pages' JSON-LD points here (tools/build-pages.mjs)
    name: 'DANGO',
    alternateName: ['DANGO 小办公室', 'Dango AI'],
    url: pageUrl(lang),
    description: INTRO[lang] || desc,
    applicationCategory: 'DeveloperApplication',
    operatingSystem: 'macOS 13+, Windows 10+',
    isAccessibleForFree: true,
    offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
    image: `${ORIGIN}/og.png`,
    inLanguage: HTML_LANG[lang],
    sameAs: SAME_AS,
  };
  if (downloads.length) app.downloadUrl = downloads;
  const graph = [app];
  const faq = faqFrom(html);
  if (faq.length)
    graph.push({
      '@type': 'FAQPage',
      inLanguage: HTML_LANG[lang],
      mainEntity: faq.map(({ q, a }) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })),
    });
  const json = JSON.stringify({ '@context': 'https://schema.org', '@graph': graph }, null, 2).replace(/</g, '\\u003c');
  return [
    `<link rel="canonical" href="${pageUrl(lang)}">`,
    ...LANGS.map((l) => `<link rel="alternate" hreflang="${HTML_LANG[l]}" href="${pageUrl(l)}">`),
    `<link rel="alternate" hreflang="x-default" href="${pageUrl(HOME)}">`,
    `<meta property="og:locale" content="${OG_LOCALE[lang]}">`,
    `<script type="application/ld+json">\n${json}\n</script>`,
  ].join('\n');
}

function build(lang) {
  let html = lang === 'zh' ? src : translateBody(src, lang);
  html = fixUrls(html);
  // The answer pages (tools/build-pages.mjs) exist in English and Chinese: the Chinese home links
  // to the Chinese ones, the other languages to the English ones.
  if (lang === 'zh') html = html.replace(/href="\/((?:claude-code-cost|claude-code-menu-bar|ai-work-value|abti|privacy)\/)"/g, 'href="/zh/$1"');
  html = html.replace(/<html([^>]*)>/, (m, attrs) => {
    attrs = attrs.replace(/\s(lang|data-lang)="[^"]*"/g, '');
    return `<html lang="${HTML_LANG[lang]}" data-lang="${lang}"${attrs}>`;
  });
  const desc = tr(lang, DESC_KEY);
  html = html.replace(/<title>[\s\S]*?<\/title>/, () => `<title>${escText(TITLES[lang])}</title>`);
  html = setMeta(html, 'name', 'description', desc);
  html = setMeta(html, 'property', 'og:title', TITLES[lang]);
  html = setMeta(html, 'property', 'og:description', desc);
  html = setMeta(html, 'property', 'og:url', pageUrl(lang));
  html = html.replace('</head>', () => `${headBlock(html, lang, desc)}\n</head>`);
  const outDir = lang === HOME ? dir : join(dir, lang);
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'index.html'), html);
}

for (const l of LANGS) build(l);

const today = new Date().toISOString().slice(0, 10);
const alts = LANGS.map((l) => `    <xhtml:link rel="alternate" hreflang="${HTML_LANG[l]}" href="${pageUrl(l)}"/>`)
  .concat(`    <xhtml:link rel="alternate" hreflang="x-default" href="${pageUrl(HOME)}"/>`)
  .join('\n');
const sitemap = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${LANGS.map((l) => `  <url>\n    <loc>${pageUrl(l)}</loc>\n    <lastmod>${today}</lastmod>\n${alts}\n  </url>`).join('\n')}
</urlset>
`;
writeFileSync(join(dir, 'sitemap.xml'), sitemap);
console.log(`build-i18n: ${LANGS.length} pages (English at /) and sitemap.xml in ${dir}`);
