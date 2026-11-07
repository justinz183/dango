"""The home page: the product's story in the order the launch film tells it
(a bill says what the AI cost, not what its work is worth; who would you
hire for each step; real US median wages; the 团子 on your screen and its
office; four agents side by side; what kind of boss you are; the cards;
all on your Mac). Built by build.py; pictures from site/media
(render_media.py, sample data)."""
import html
import re

e = html.escape

# Sample numbers on the page (the same sample data as the pictures).
SAMPLE_WORK, SAMPLE_BILL = 18588, 998


def jobs(repo):
    """Every job in the app's table: id, names and BLS hourly median."""
    text = (repo / "assets" / "occupations.toml").read_text(encoding="utf-8")
    out = []
    for blk in text.split("[[occupation]]")[1:]:
        g = lambda k: re.search(rf'^{k} = "?([^"\n]*)"?$', blk, re.M).group(1)
        out.append({"id": g("id"), "name": g("name"), "name_en": g("name_en"), "rate": float(g("rate"))})
    return out


def home(c, ctx):
    """`ctx` carries what build.py knows: download link, check mark, types,
    dimensions and their copy, the repository."""
    t, link, img = c.t, c.link, c.img
    dl = ctx["download"]
    table = jobs(ctx["repo"])
    rate = {j["id"]: j["rate"] for j in table}
    name = {j["id"]: c.t(j["name"], j["name_en"]) for j in table}

    def job_card(j):
        return (f'<li class="job">{img(f"img/job/{j}.webp", name[j])}<span class="jn">{e(name[j])}</span>'
                f'<span class="jr">${rate[j]:.2f}<small>/{t("时", "h")}</small></span></li>')

    examples = [
        ("swe", t("改了 120 行代码", "Changed 120 lines of code"), t("约 23 分钟", "about 23 min")),
        ("data", t("跑了一个出图表的脚本", "Ran a script that draws a chart"), t("4 分钟", "4 min")),
        ("doctor", t("问：猫为什么拉肚子？", "Asked why the cat has an upset stomach"), t("一次问诊 15 分钟", "a 15-min consult")),
    ]
    steps = "\n".join(
        f'<li class="tile step reveal"><p class="step-task">{e(what)}</p><span class="step-arrow" aria-hidden="true">↓</span>'
        f'{img(f"img/job/{j}.webp", name[j])}<p class="step-job">{e(name[j])}</p>'
        f'<p class="step-math">{mins} · ${rate[j]:.2f}/{t("时", "h")}</p></li>'
        for j, what, mins in examples
    )
    grid = "\n".join(job_card(j["id"]) for j in sorted(table, key=lambda j: -j["rate"]))
    states = [(t("在干", "Working"), "#16A34A"), (t("等你批准", "Needs you"), "#F59E0B"), (t("摸鱼", "Slacking"), "#8E8E93"), (t("睡着了", "Asleep"), "#5B6B8C")]
    chips = "".join(f'<span class="state"><i style="background:{col}"></i>{e(s)}</span>' for s, col in states)
    tools = ["Claude Code", "Codex", "DeepSeek", "WorkBuddy"]
    dims = "\n".join(
        f'<li class="dim reveal"><p class="dim-pair">{ctx["letter_pair"](c, key)}</p><p>{e(c.say(ctx["copy"][key]["home"]))}</p></li>'
        for key in ctx["dims"]["order"]
    )
    icons = "\n".join(
        f'<a class="mini" href="{link(f"t/{code}/")}" title="{e(c.f(ty, "name"))}">{img(f"img/icon/{code}.webp", c.f(ty, "name"))}'
        f'<span class="code mono">{code}</span></a>'
        for code, ty in ctx["types"].items()
    )
    privacy = [
        (t("只记数字", "Numbers only"),
         t("每个回合归给哪些职业、多少分钟、值多少钱、模型花了多少。", "Which jobs each turn went to, how many minutes, what it's worth and what the models cost.")),
        (t("内容不落地", "No content kept"),
         t("prompt 只在内存里看一眼，判断你在聊哪一行，读完就丢。代码、路径、仓库名都不存。", "A prompt is read once in memory to tell what it's about, then dropped. Code, paths and repo names are never stored.")),
        (t("什么都不上传", "Nothing uploaded"),
         t("全在你的 Mac 上算。分享卡上没有项目名、会话标题和代码，发不发由你。", "It all runs on your Mac. Share cards carry no project names, session titles or code, and sharing is up to you.")),
    ]
    priv = "\n".join(f'<li class="priv reveal"><h3>{ctx["check"]}{e(h)}</h3><p>{e(p)}</p></li>' for h, p in privacy)
    lev = SAMPLE_WORK / SAMPLE_BILL
    lang = c.lang
    ver = ctx["ver"]

    # The launch film plays in a full-screen dialog from a "Watch the film"
    # link, as on Apple's product pages; a language without a film has none.
    play, film = "", ""
    if ctx["film"]:
        v = f"video/promo-{lang}"
        play = (f'<button class="play-link" type="button" data-film>{t("看宣传片", "Watch the film")}'
                f'<svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="none" stroke="currentColor" stroke-width="1.4"/>'
                f'<path d="M8.2 6.6v6.8l5.6-3.4z" fill="currentColor"/></svg></button>')
        film = f"""
<dialog class="film-modal" id="film" aria-label="{t("宣传片", "The film")}">
  <button class="film-close" type="button" aria-label="{t("关闭", "Close")}">×</button>
  <video controls preload="none" playsinline poster="{c.up}{ver(v + '-poster.webp')}" width="1920" height="1080">
    <source src="{c.up}{ver(v + '.mp4')}" type="video/mp4">
    <track kind="captions" src="{c.up}{ver(v + '.vtt')}" srclang="{lang}" label="{t("中文", "English")}">
  </video>
</dialog>"""
    cta = f"""<div class="h-cta">
      <a class="btn btn-lg" href="{dl}">{ctx["apple"]}{t("下载 Mac 版", "Download for Mac")}</a>
      {play}
    </div>"""
    tool_tiles = "".join(f'<li class="tool reveal">{e(x)}</li>' for x in tools)

    return f"""<section class="h-hero">
  <div class="w">
    <p class="h-kicker">{t("住在你 Mac 屏幕角落的打工团子", "A little office of dangos on your Mac")}</p>
    <h1 class="h-title">{t('你的 AI，<br>在替你打工。', 'Your AI is working <br class="br">for you.')}</h1>
    <p class="h-sub">{t("把 AI 干的每一步，换算成一个真人要拿的工钱。", "Every step your AI takes, priced at what a person would be paid.")}</p>
    {cta}
    <p class="h-meta">{t("免费 · macOS 13 起 · Apple 芯片和 Intel", "Free · macOS 13+ · Apple silicon and Intel")}</p>
  </div>
  <figure class="h-office">{img("img/office.webp", t("团子办公室：有的在工位上干活，有的在沙发上摸鱼", "The dango office: some at their desks, some on the sofa"), lazy=False)}</figure>
</section>

<section class="band cream" id="worth">
  <div class="w center">
    <p class="eyebrow reveal">01 / {t("账单", "The bill")}</p>
    <h2 class="hl reveal">{t('账单只告诉你花了多少，<br>没告诉你值多少。', 'Your bill says what it cost.<br>Not what it’s worth.')}</h2>
    <div class="stats">
      <div class="tile stat reveal">
        <p class="stat-cap">{t("模型账单", "Model bill")}</p>
        <p class="stat-num was">${SAMPLE_BILL:,}</p>
        <p class="stat-note">{t("token 用了多少，就扣多少钱。", "Tokens in, money out.")}</p>
      </div>
      <div class="tile stat reveal">
        <p class="stat-cap">{t("团子替你打的工", "Work your dangos did")}</p>
        <p class="stat-num money">${SAMPLE_WORK:,}</p>
        <p class="stat-note">{t("同样的活，请人来干要付的工钱。", "What you’d pay people to do the same work.")}</p>
      </div>
      <div class="tile stat reveal">
        <p class="stat-cap">{t("杠杆", "Leverage")}</p>
        <p class="stat-num money">{lev:.1f}×</p>
        <p class="stat-note">{t("每花 1 美元模型钱，换回的活值多少。", "What each dollar of model spend buys in work.")}</p>
      </div>
    </div>
    <p class="fine">{t("示例数据。装上就是你自己的数字。", "Sample numbers. Yours show up once it’s installed.")}</p>
  </div>
</section>

<section class="band" id="hire">
  <div class="w">
    <p class="eyebrow reveal">02 / {t("每一步", "Every step")}</p>
    <h2 class="hl reveal">{t("这活，该请谁来干？", "Who would you hire for this?")}</h2>
    <p class="lead reveal">{t("改代码归<b>软件工程师</b>，跑图表归<b>数据分析师</b>，问猫的病归<b>医生</b>。再估一个真人干这一步要多久。",
                               "Code goes to a <b>software engineer</b>, charts to a <b>data analyst</b>, the cat’s stomach to a <b>doctor</b>. Then it estimates how long a person would take.")}</p>
    <ol class="bento three">
{steps}
    </ol>
  </div>
</section>

<section class="band cream" id="wages">
  <div class="w">
    <p class="eyebrow reveal">03 / {t(f"{len(table)} 种职业", f"{len(table)} jobs")}</p>
    <h2 class="hl reveal">{t("按美国真实中位时薪算。", "Paid at real U.S. median wages.")}</h2>
    <p class="lead reveal">{t("时薪来自<b>美国劳工统计局</b>（BLS OEWS，2025 年 5 月）。不封顶，也不打折。",
                               "Hourly wages from the <b>U.S. Bureau of Labor Statistics</b> (OEWS, May 2025). No caps, no discounts.")}</p>
    <ul class="jobs reveal">
{grid}
    </ul>
  </div>
</section>

<section class="band" id="desk">
  <div class="w"><div class="night center">
    <p class="eyebrow reveal">04 / {t("屏幕角落", "On your screen")}</p>
    <h2 class="hl reveal">{t("它住在你屏幕的角落，<br>按手上的活换装。", 'It lives in the corner of your screen, <br class="br">dressed for the job.')}</h2>
    <p class="lead reveal">{t("写代码时戴毛线帽，剪视频时戴耳机。干完一个回合，头顶冒一句这回合挣了多少。<b>点一下，整间办公室就打开了。</b>",
                               "A beanie for code, headphones for video. When a turn ends, a little note says what it earned. <b>Click it, and the whole office opens.</b>")}</p>
    <div class="desk-art reveal">
      <div class="screen">
        <div class="screen-bar"><i></i><i></i><i></i></div>
        {img(f"img/pet-{lang}.webp", t("屏幕角落的团子和它头顶的结算", "The dango in the corner with its note"), cls="pet")}
      </div>
      <div class="panel-shot">{img(f"img/panel-{lang}.webp", t("点开团子后的面板", "The panel the dango opens"))}</div>
    </div>
    <div class="states reveal">{chips}</div>
  </div></div>
</section>

<section class="band cream" id="tools">
  <div class="w center">
    <p class="eyebrow reveal">05 / {t("并排算", "Side by side")}</p>
    <h2 class="hl reveal">{t("四个 AI，一起算。", "Four agents. One office.")}</h2>
    <p class="lead reveal">{t("<b>不用装插件，不用改设置。</b>它直接读这些工具自己写在你电脑上的会话记录，装上就把以前的活也算一遍。",
                               "<b>No plugins, no setup.</b> It reads the session logs these tools already keep on your Mac, and counts your past work the moment it’s installed.")}</p>
    <ul class="tool-row">{tool_tiles}</ul>
  </div>
</section>

<section class="band" id="boss">
  <div class="w">
    <p class="eyebrow reveal">06 / {t("老板人格", "Boss type")}</p>
    <h2 class="hl reveal">{t("现在你是老板了。<br>你是哪种老板？", "Now you’re the boss.<br>What kind of boss are you?")}</h2>
    <p class="lead reveal">{t("不用答题。按你的 AI 真干了什么，算出<b>四个字母、公司规模和压榨率</b>，再讲一遍你的故事：最晚的一夜、最拼的一天、你的工资单。",
                               "No quiz. From what your agents actually did, it works out <b>four letters, a company size and a margin</b>, then tells your story: your latest night, your biggest day, your payslip.")}</p>
    <div class="boss-bento">
      <figure class="tile card-tile reveal">{img(f"img/card-{lang}.webp", t("老板人格总卡", "The boss card"))}</figure>
      <ul class="dims">
{dims}
      </ul>
    </div>
    <div class="tile grid16 reveal">
{icons}
    </div>
    <p class="links"><a href="{link("types/")}">{t("看全部 16 型", "See all 16 types")} →</a><a href="{link("how/")}">{t("怎么算的", "How it’s worked out")} →</a></p>
  </div>
</section>

<section class="band cream" id="share">
  <div class="w split">
    <div>
      <p class="eyebrow reveal">07 / {t("分享", "Share")}</p>
      <h2 class="hl reveal">{t("每一份报告，<br>都是一张能晒的卡。", 'Every report is a card you can share.')}</h2>
      <p class="lead reveal">{t("日报、周报、月报、年报和总报，<b>各带那段时间你自己的老板人格</b>。点「分享」就弹出系统分享菜单。",
                                 "Day, week, month, year and all-time, <b>each with that period’s own boss type</b>. Hit share and pick where it goes.")}</p>
    </div>
    <figure class="share-shot reveal">{img(f"img/share-week-{lang}.webp", t("一张周报分享图", "A week's share card"))}</figure>
  </div>
</section>

<section class="band" id="privacy">
  <div class="w">
    <p class="eyebrow reveal">08 / {t("隐私", "Privacy")}</p>
    <h2 class="hl reveal">{t("全在你的 Mac 上算。<br>什么都不上传。", "It all runs on your Mac.<br>Nothing is uploaded.")}</h2>
    <ul class="privacy">
{priv}
    </ul>
  </div>
</section>

<section class="finale">
  <div class="w center reveal">
    {img("img/dango-working.webp", "", cls="finale-dango")}
    <h2>{t('你的 AI 在替你打工。<br><span class="soft">现在，你看得见了。</span>', 'Your AI works for you.<br><span class="soft">Now you can see it.</span>')}</h2>
    {cta}
    <p class="h-meta">{t("免费 · macOS 13 起 · Apple 芯片和 Intel · 第一次打开要在「隐私与安全性」里点「仍要打开」",
                         "Free · macOS 13+ · Apple silicon and Intel · the first time, allow it in Privacy & Security")}</p>
  </div>
</section>
{film}
<script>
(() => {{
  const els = document.querySelectorAll('.reveal');
  if (!('IntersectionObserver' in window) || matchMedia('(prefers-reduced-motion: reduce)').matches) {{
    els.forEach(el => el.classList.add('in'));
  }} else {{
    document.documentElement.classList.add('anim');
    const io = new IntersectionObserver(es => es.forEach(x => {{ if (x.isIntersecting) {{ x.target.classList.add('in'); io.unobserve(x.target); }} }}), {{ rootMargin: '0px 0px -8% 0px' }});
    els.forEach(el => io.observe(el));
  }}
  const d = document.getElementById('film');
  if (!d || !d.showModal) return;
  const v = d.querySelector('video');
  document.querySelectorAll('[data-film]').forEach(b => b.addEventListener('click', () => {{ d.showModal(); v.play().catch(() => {{}}); }}));
  d.querySelector('.film-close').addEventListener('click', () => d.close());
  d.addEventListener('click', ev => {{ if (ev.target === d) d.close(); }});
  d.addEventListener('close', () => v.pause());
}})();
</script>"""
