#!/usr/bin/env python3
"""Install reviewed Lavish components without changing untouched substrate bytes."""

from __future__ import annotations

import argparse
import os
import stat
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
.dz{margin:24px 0 80px}.tabbar{position:sticky;top:0;z-index:4;display:flex;gap:6px;padding:8px;background:var(--bg);border:1px solid var(--line);border-radius:10px}
.tabbar button{border:1px solid var(--line);background:var(--card);color:var(--ink);border-radius:8px;padding:7px 10px;cursor:pointer}.tabbar button.on{background:var(--clay-soft)}
.tab{display:none}.tab.on{display:block}.dnote,.qtext{width:100%;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--ink);padding:9px;margin-top:8px}
.replybar{position:fixed;z-index:6;left:20px;right:20px;bottom:12px;max-width:940px;margin:auto;display:flex;gap:10px;align-items:center;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 12px}
.replybar code{flex:1;overflow-wrap:anywhere}.replybar button{border:1px solid var(--line);background:var(--clay-soft);color:var(--ink);border-radius:8px;padding:7px 12px;cursor:pointer}.copy-manual{font-size:11px;color:var(--mut)}
</style>
<template id="david-warm-decision-template">
  <section class="tab" data-decision-pane="{{D_ID}}">
    <div class="tw"><table><tbody>
      <tr><th>What</th><td>{{WHAT}}</td></tr>
      <tr><th>Why now</th><td>{{WHY_NOW}}</td></tr>
      <tr><th>Why / why not</th><td>{{WHY_WHY_NOT}}</td></tr>
      <tr><th>Cost / risk</th><td>{{COST_RISK}}</td></tr>
    </tbody></table></div>
    <div class="opt pick" data-option-card="{{O_ID}}"><div class="oh">{{O_ID}} &middot; Recommended<span class="pill">recommended</span></div><div class="od">{{DESCRIPTION}}</div><div class="pro">+ {{BENEFIT}}</div><div class="con">- {{COST}}</div></div>
    <input data-decision="{{D_ID}}" type="radio" name="{{D_ID}}" value="{{O_ID}}" checked>
    <input class="dnote" data-note="{{D_ID}}" aria-label="{{D_ID}} note" placeholder="Optional note">
  </section>
  <textarea class="qtext" data-question="{{Q_ID}}" aria-label="{{Q_ID}} answer"></textarea>
  <details data-decided="{{D_ID}}"><summary>{{D_ID}} decided: {{PICK}}</summary><div>{{PRESERVED_DECISION_CONTENT}}</div></details>
</template>
<div class="replybar" data-replybar><code data-reply></code><button data-copy-reply type="button">Copy</button><span class="copy-manual" data-copy-manual>If Copy is blocked, select the reply and press Command-C.</span></div>
<script>
(() => {
  const compose = () => {
    const parts = [];
    const ids = [...new Set([...document.querySelectorAll('[data-decision]')].map(node => node.dataset.decision))];
    ids.forEach(id => {
      const picks = [...document.querySelectorAll('[data-decision]')].filter(node => node.dataset.decision === id && node.checked).map(node => node.value);
      const noteNode = [...document.querySelectorAll('[data-note]')].find(node => node.dataset.note === id);
      const note = noteNode ? noteNode.value.trim() : '';
      parts.push(`${id}: ${picks.join('+')}${note ? ` (${note})` : ''}`);
      const badge = [...document.querySelectorAll('[data-badge-for]')].find(node => node.dataset.badgeFor === id);
      if (badge) badge.textContent = picks.join('+');
    });
    document.querySelectorAll('[data-question]').forEach(node => { const value = node.value.trim(); if (value) parts.push(`${node.dataset.question}: ${value}`); });
    const reply = document.querySelector('[data-reply]');
    if (reply) reply.textContent = parts.join(' | ');
  };
  document.querySelectorAll('[data-decision],[data-note],[data-question]').forEach(node => node.addEventListener('input', compose));
  document.querySelectorAll('[data-tab]').forEach(button => button.addEventListener('click', () => {
    const tabbar = button.closest('.tabbar');
    document.querySelectorAll('[data-tab],.tab').forEach(node => node.classList.remove('on'));
    button.classList.add('on');
    const pane = document.getElementById(button.dataset.tab);
    if (pane) pane.classList.add('on');
    if (tabbar && window.scrollY > tabbar.offsetTop) window.scrollTo({top:tabbar.offsetTop,behavior:'instant'});
  }));
  const copy = document.querySelector('[data-copy-reply]');
  if (copy) copy.addEventListener('click', async () => {
    const reply = document.querySelector('[data-reply]');
    const text = reply ? reply.textContent : '';
    try {
      if (!navigator.clipboard) throw new Error('clipboard unavailable');
      await navigator.clipboard.writeText(text);
    } catch (_) {
      const area = document.createElement('textarea');
      area.value = text;
      document.body.appendChild(area);
      area.select();
      if (!document.execCommand('copy')) {
        const instruction = document.querySelector('[data-copy-manual]');
        if (instruction) instruction.hidden = false;
      }
      area.remove();
    }
  });
  compose();
})();
</script>
<!-- =================== /COPY VERBATIM: DECISION ZONE ====================== -->''',
    "DYNAMIC SIDEBAR": r'''<!-- ==================== COPY VERBATIM: DYNAMIC SIDEBAR ==================== -->
<style>
.page-shell{max-width:1150px;margin:auto}.side{width:168px;max-height:calc(100vh - 24px);overflow-y:auto;overscroll-behavior:contain}.side a{display:block;color:var(--mut);padding:4px 6px}.side a.on{color:var(--clay-deep);font-weight:700}.side .nav-title{font-size:10px;font-weight:700;text-transform:uppercase;margin-top:10px}.side-toggle{display:none}
@media(min-width:1150px){.page-shell{display:grid;grid-template-columns:196px minmax(0,1fr);gap:20px}.side{position:sticky;top:12px}}
@media(max-width:1149px){.side-toggle{display:block}.side{display:none;position:fixed;inset:60px 20px auto;width:auto;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px;z-index:7}.side.open{display:block}}
</style>
<button class="side-toggle" data-side-toggle type="button">Sections</button>
<nav class="side" data-dynamic-side aria-label="Page sections"><div class="nav-title">Main</div><div data-nav-group="main"></div><div class="nav-title">Rounds</div><div data-nav-group="rounds"></div><div class="nav-title">Decisions</div><div data-nav-group="decisions"></div></nav>
<script>
(() => {
  const rail = document.querySelector('[data-dynamic-side]');
  if (!rail) return;
  const groups = {main:'main',round:'rounds',decision:'decisions'};
  const sections = [...document.querySelectorAll('[data-nav]')];
  sections.forEach(section => {
    const [group,status,label] = section.dataset.nav.split('|');
    const target = rail.querySelector(`[data-nav-group="${groups[group]}"]`);
    if (!target) return;
    const link = document.createElement('a');
    link.href = `#${section.id}`;
    link.dataset.target = section.id;
    link.textContent = `${status} ${label}`;
    target.appendChild(link);
  });
  const observer = new IntersectionObserver(entries => entries.forEach(entry => { if (entry.isIntersecting) rail.querySelectorAll('a').forEach(link => link.classList.toggle('on', link.dataset.target === entry.target.id)); }), {rootMargin:'-20% 0px -60%'});
  sections.forEach(section => observer.observe(section));
  const toggle = document.querySelector('[data-side-toggle]');
  if (toggle) toggle.addEventListener('click', () => rail.classList.toggle('open'));
})();
</script>
<!-- =================== /COPY VERBATIM: DYNAMIC SIDEBAR ==================== -->''',
}


def verify_substrate(text: str) -> None:
    if "DAVID-WARM" not in text or any(marker not in text for marker in REQUIRED_MARKERS):
        raise ValueError("unknown or unsafe substrate: canonical David-warm markers are missing")
    if "border-left:" in text or "prefers-color-scheme:dark" in text.replace(" ", ""):
        raise ValueError("unknown or unsafe substrate: banned style found")


def component_block(name: str, newline: str) -> str:
    return COMPONENTS[name].replace("\n", newline)


def install(source: Path, output: Path) -> None:
    if source.is_symlink() or not source.is_file():
        raise ValueError("unknown or unsafe substrate: source must be a regular file")
    if output.is_symlink():
        raise ValueError("unknown or unsafe substrate: output must not be a symlink")
    if output.exists() and output.resolve() != source.resolve():
        raise ValueError("unknown or unsafe substrate: refusing to replace a different existing file")
    source_bytes = source.read_bytes()
    text = source_bytes.decode("utf-8")
    verify_substrate(text)
    newline = "\r\n" if b"\r\n" in source_bytes else "\n"
    additions: list[str] = []
    for name in COMPONENTS:
        open_marker = f"COPY VERBATIM: {name}"
        close_marker = f"/COPY VERBATIM: {name}"
        opened = open_marker in text
        closed = close_marker in text
        if opened != closed:
            raise ValueError(f"unknown or unsafe substrate: partial {name} component")
        component = component_block(name, newline)
        if opened:
            start = text.rfind("<!--", 0, text.index(open_marker) + 1)
            end = text.index("-->", text.index(close_marker)) + 3
            if text[start:end] != component:
                raise ValueError(f"unknown or unsafe substrate: drifted {name} component")
        else:
            additions.append(component)
    if additions:
        close = text.rfind("</div>")
        if close < 0:
            raise ValueError("unknown or unsafe substrate: page wrapper close is missing")
        separator = newline + newline
        text = text[:close] + separator + separator.join(additions) + separator + text[close:]
    mode = stat.S_IMODE(source.stat().st_mode)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="david-warm-", suffix=".html", dir=output.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(text.encode("utf-8"))
        os.chmod(temporary, mode)
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("component_file", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        install(args.component_file, args.output or args.component_file)
    except (OSError, UnicodeDecodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(f"installed={args.output or args.component_file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
