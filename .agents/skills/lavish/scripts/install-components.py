#!/usr/bin/env python3
"""Install Lavish interaction components into a verified David-warm substrate."""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

REQUIRED_MARKERS = (
    "COPY VERBATIM: TOKENS",
    "COPY VERBATIM: BASE RESET + ELEMENTS",
    "COPY VERBATIM: YOUR-CALL BLOCK",
    "COPY VERBATIM: MERMAID LIGHT THEME",
    "/COPY VERBATIM: FOOTER EXECUTE",
)

COMPONENTS = {
    "DECISION ZONE": r'''<!-- ==================== COPY VERBATIM: DECISION ZONE ====================== -->
<style>
.dz{margin:24px 0 80px}.tabbar{position:sticky;top:0;z-index:4;display:flex;gap:6px;
  padding:8px;background:var(--bg);border:1px solid var(--line);border-radius:10px}
.tabbar button{border:1px solid var(--line);background:var(--card);color:var(--ink);
  border-radius:8px;padding:7px 10px;cursor:pointer}.tabbar button.on{background:var(--clay-soft)}
.tab{display:none}.tab.on{display:block}.dnote,.qtext{width:100%;border:1px solid var(--line);
  border-radius:8px;background:var(--card);color:var(--ink);padding:9px;margin-top:8px}
.replybar{position:fixed;z-index:6;left:20px;right:20px;bottom:12px;max-width:940px;
  margin:auto;display:flex;gap:10px;align-items:center;background:var(--card);
  border:1px solid var(--line);border-radius:12px;padding:10px 12px}
.replybar code{flex:1;overflow-wrap:anywhere}.replybar button{border:1px solid var(--line);
  background:var(--clay-soft);color:var(--ink);border-radius:8px;padding:7px 12px;cursor:pointer}
</style>
<div class="dz" data-david-warm-component="decision-zone">
  <div class="tabbar" id="decision-tabs">
    <button class="on" data-tab="d1">D1 <span id="b-d1">O1</span></button>
    <button data-tab="d2">D2 <span id="b-d2">O1</span></button>
    <button data-tab="decided">Decided log</button>
    <button data-tab="questions">Questions</button>
  </div>
  <section class="tab on" id="d1">
    <div class="yc"><div class="yc-h"><span>D1. Choose the path</span><span class="rk">rank 1</span></div>
      <div class="yc-b"><div class="pick-radio">
        <label class="rec"><input data-decision="D1" type="radio" name="D1" value="O1" checked>O1 recommended</label>
        <label><input data-decision="D1" type="radio" name="D1" value="O2">O2 alternative</label>
      </div><input class="dnote" data-note="D1" aria-label="D1 note" placeholder="Optional note"></div>
    </div>
  </section>
  <section class="tab" id="d2">
    <div class="yc"><div class="yc-h"><span>D2. Select compatible work</span><span class="rk">select any</span></div>
      <div class="yc-b"><div class="pick-radio">
        <label class="rec"><input data-decision="D2" type="checkbox" value="O1" checked>O1 recommended</label>
        <label><input data-decision="D2" type="checkbox" value="O2">O2 additional</label>
      </div><input class="dnote" data-note="D2" aria-label="D2 note" placeholder="Optional note"></div>
    </div>
  </section>
  <section class="tab" id="decided"><div class="card"><p class="ch">Decided log</p><p>Preserve retired decisions here.</p></div></section>
  <section class="tab" id="questions"><label for="q1">Q1. What should change?</label><textarea class="qtext" id="q1" data-question="Q1"></textarea></section>
  <div class="replybar"><code id="reply">D1: O1 | D2: O1</code><button id="copy-reply" type="button">Copy</button></div>
</div>
<script>
(() => {
  const compose = () => {
    const parts = [];
    for (const id of ['D1','D2']) {
      const picks = [...document.querySelectorAll(`[data-decision="${id}"]:checked`)].map(x => x.value);
      const note = document.querySelector(`[data-note="${id}"]`).value.trim();
      parts.push(`${id}: ${picks.join('+')}${note ? ` (${note})` : ''}`);
      document.getElementById(`b-${id.toLowerCase()}`).textContent = picks.join('+');
    }
    const answer = document.querySelector('[data-question="Q1"]').value.trim();
    if (answer) parts.push(`Q1: ${answer}`);
    document.getElementById('reply').textContent = parts.join(' | ');
  };
  document.querySelectorAll('[data-decision],[data-note],[data-question]').forEach(x => x.addEventListener('input', compose));
  document.querySelectorAll('[data-tab]').forEach(button => button.addEventListener('click', () => {
    document.querySelectorAll('[data-tab],.tab').forEach(x => x.classList.remove('on'));
    button.classList.add('on');
    document.getElementById(button.dataset.tab).classList.add('on');
  }));
  document.getElementById('copy-reply').addEventListener('click', async () => {
    const text = document.getElementById('reply').textContent;
    try {
      if (window.__forceClipboardFailure || !navigator.clipboard) throw new Error('clipboard unavailable');
      await navigator.clipboard.writeText(text);
      window.__copyPath = 'clipboard';
    } catch (_) {
      const area = document.createElement('textarea');
      area.value = text;
      document.body.appendChild(area);
      area.select();
      if (document.execCommand('copy')) window.__copyPath = 'execCommand';
      else { window.__copyPath = 'manual'; window.__manualCopyMessage = 'Press Command-C'; }
      area.remove();
    }
  });
  compose();
})();
</script>
<!-- =================== /COPY VERBATIM: DECISION ZONE ====================== -->''',
    "DYNAMIC SIDEBAR": r'''<!-- ==================== COPY VERBATIM: DYNAMIC SIDEBAR ==================== -->
<style>
.page-shell{max-width:1150px;margin:auto}.side{width:168px;max-height:calc(100vh - 24px);
  overflow-y:auto;overscroll-behavior:contain}.side a{display:block;color:var(--mut);padding:4px 6px}
.side a.on{color:var(--clay-deep);font-weight:700}.side .nav-title{font-size:10px;font-weight:700;
  text-transform:uppercase;margin-top:10px}.side-toggle{display:none}
@media(min-width:1150px){.page-shell{display:grid;grid-template-columns:196px minmax(0,1fr);gap:20px}.side{position:sticky;top:12px}}
@media(max-width:1149px){.side-toggle{display:block}.side{display:none;position:fixed;inset:60px 20px auto;
  width:auto;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px;z-index:7}.side.open{display:block}}
</style>
<button class="side-toggle" id="side-toggle" type="button">Sections</button>
<nav class="side" id="dynamic-side" aria-label="Page sections">
  <div class="nav-title">Main</div><div data-nav-group="main"></div>
  <div class="nav-title">Rounds</div><div data-nav-group="rounds"></div>
  <div class="nav-title">Decisions</div><div data-nav-group="decisions"></div>
</nav>
<script>
(() => {
  const rail = document.getElementById('dynamic-side');
  const groups = {main:'main',round:'rounds',decision:'decisions'};
  const sections = [...document.querySelectorAll('[data-nav]')];
  sections.forEach(section => {
    const [group,status,label] = section.dataset.nav.split('|');
    const link = document.createElement('a');
    link.href = `#${section.id}`;
    link.dataset.target = section.id;
    link.textContent = `${status} ${label}`;
    rail.querySelector(`[data-nav-group="${groups[group]}"]`).appendChild(link);
  });
  const observer = new IntersectionObserver(entries => entries.forEach(entry => {
    if (!entry.isIntersecting) return;
    rail.querySelectorAll('a').forEach(link => link.classList.toggle('on', link.dataset.target === entry.target.id));
  }), {rootMargin:'-20% 0px -60%'});
  sections.forEach(section => observer.observe(section));
  document.getElementById('side-toggle').addEventListener('click', () => rail.classList.toggle('open'));
})();
</script>
<!-- =================== /COPY VERBATIM: DYNAMIC SIDEBAR ==================== -->''',
    "EXECUTABLE MERMAID": r'''<!-- ==================== COPY VERBATIM: EXECUTABLE MERMAID ================= -->
<style>
.mermaid-frame{overflow-x:auto;background:var(--wash);border:1px solid var(--line);border-radius:12px;padding:14px}
.mermaid{min-width:0;text-align:center}.mermaid svg{max-width:100%;height:auto}
</style>
<div class="mermaid-frame"><pre class="mermaid">flowchart TD
  A[Evidence] --> B[Decision]
  B --> C[Execution]</pre></div>
<script>
window.renderDavidWarmMermaid = async api => {
  const css = getComputedStyle(document.documentElement);
  api.initialize({startOnLoad:false,theme:'base',themeVariables:{
    background:css.getPropertyValue('--bg').trim(),primaryColor:css.getPropertyValue('--card').trim(),
    primaryBorderColor:css.getPropertyValue('--line').trim(),primaryTextColor:css.getPropertyValue('--ink').trim(),
    secondaryColor:css.getPropertyValue('--wash').trim(),tertiaryColor:css.getPropertyValue('--clay-soft').trim(),
    lineColor:css.getPropertyValue('--mut').trim(),fontFamily:getComputedStyle(document.body).fontFamily
  },flowchart:{curve:'basis',htmlLabels:true}});
  await api.run({querySelector:'.mermaid'});
};
</script>
<!-- =================== /COPY VERBATIM: EXECUTABLE MERMAID ================= -->''',
}


def marker(name: str, close: bool = False) -> str:
    slash = "/" if close else ""
    return f"{slash}COPY VERBATIM: {name}"


def verify_substrate(text: str) -> None:
    if "DAVID-WARM" not in text or any(required not in text for required in REQUIRED_MARKERS):
        raise ValueError("unknown or unsafe substrate: canonical David-warm markers are missing")
    if "border-left:" in text or "prefers-color-scheme:dark" in text.replace(" ", ""):
        raise ValueError("unknown or unsafe substrate: banned style found")


def install(source: Path, output: Path) -> None:
    if source.is_symlink() or not source.is_file():
        raise ValueError("unknown or unsafe substrate: source must be a regular file")
    if output.is_symlink():
        raise ValueError("unknown or unsafe substrate: output must not be a symlink")
    if output.exists() and output.resolve() != source.resolve():
        raise ValueError("unknown or unsafe substrate: refusing to replace a different existing file")
    text = source.read_text(encoding="utf-8")
    verify_substrate(text)
    additions: list[str] = []
    for name, component in COMPONENTS.items():
        opened = marker(name) in text
        closed = marker(name, close=True) in text
        if opened != closed:
            raise ValueError(f"unknown or unsafe substrate: partial {name} component")
        if opened:
            start = text.index("<!--", text.index(marker(name)) - 80)
            end_marker = marker(name, close=True)
            end = text.index("-->", text.index(end_marker)) + 3
            if text[start:end] != component:
                raise ValueError(f"unknown or unsafe substrate: drifted {name} component")
        else:
            additions.append(component)
    if additions:
        close = text.rfind("</div>")
        if close < 0:
            raise ValueError("unknown or unsafe substrate: page wrapper close is missing")
        text = text[:close] + "\n\n" + "\n\n".join(additions) + "\n\n" + text[close:]
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="david-warm-", suffix=".html", dir=output.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("component_file", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = args.output or args.component_file
    try:
        install(args.component_file, output)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(f"installed={output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
