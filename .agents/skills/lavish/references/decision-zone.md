# Decision-zone implementation spec

Read this file at the write-the-page step before building any decision zone.

The behavioral rules for when a decision exists, D-numbering, Recommended-first ordering, multi-select use, and retirement of decided tabs live in `../SKILL.md`.

This file owns the structure and JavaScript behavior.

Resolve the canonical source from `DAVID_WARM_COMPONENT_FILE`, defaulting to `data/operating-model/components/david-warm.html` relative to the repository root.

All visual classes must use components and tokens copied verbatim from that resolved file.

## Structure

Use a `.dz` wrapper.

Inside it, use a sticky `.tabbar` with one button per open decision, plus Decided log and Questions or Standing tabs.

Each open-decision button uses a page-scoped `data-tab` value and contains the decision ID, title, and a current-selection badge using `data-badge-for`.

Each `.tab` pane contains the four-row context table, `.opt` cards, and one `.dnote` input.

The Questions pane contains real `.qtext` textareas.

The fixed `.replybar` contains `<code id="reply">` and a Copy button.

Copy the matching David-warm card, Your-call, status-chip, and footer components verbatim.

Do not reimplement their CSS in the page.

## JavaScript behavior

Use the canonical generic behavior, which discovers arbitrary page-scoped `Dn`, `On`, and `Qn` values from data attributes.

Do not hardcode D1, D2, O1, O2, or Q1 into the behavior.

The `compose()` function builds a live string such as `D1: O1 (note) | D2: O1+O3 | Q1: text`.

Tab clicks change the active pane.

If the reader is already below the tab bar, a tab click may scroll to `tabbar.offsetTop`.

It must never scroll above that point.

Option clicks update the decision badge and recompose the reply.

The Copy button first tries `navigator.clipboard.writeText`.

On rejection or unavailability, it tries `document.execCommand('copy')` on a temporary textarea.

If that also fails, it selects the reply text and exposes the visible instruction to press Command-C.

A bare promise success handler without rejection handling fails this contract.

## Multi-select blocks

Use multi-select only when options can be combined into one coherent move.

Show a `select any` hint in the context area and use checkbox-style option cards.

Store each decision as a map such as `{O1:true,O2:true}`.

Compose selected options with `+`, as in `D1: O1+O2`.

A mutually exclusive `none` option clears the other selections.

## Zero open decisions

Keep the tab bar when no open decision remains.

Render a Decided log tab and a Standing tab with mode or stop controls and free text.

Do not collapse the zone into unstructured blocks.

## Decided log

Each decided decision becomes one row containing its ID, title, pick, decision time, and replacement when superseded.

Keep the old block content inside a `details` fold.

Do not keep decided decisions in the live tab bar.

## Required classes

Keep the structural class names `.dz`, `.tabbar`, `.tab`, `.opt`, `.dnote`, `.qtext`, and `.replybar`.

Use the canonical David-warm components for all visible styling.

If a required visible component does not exist in David-warm, add it to that source first in a separately reviewed change.
