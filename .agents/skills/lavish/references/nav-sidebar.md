# Checkpoint nav-sidebar spec

Read this file before building a checkpoint rail.

The group order and status semantics live in `../SKILL.md`.

This file owns the rail geometry and dynamic behavior.

Resolve the canonical source from `DAVID_WARM_COMPONENT_FILE`, defaulting to `data/operating-model/components/david-warm.html` relative to the repository root.

Visible styling must come from components and tokens copied verbatim from that resolved file.

## Rail geometry

Use a `nav.side` rail 168 pixels wide inside a reserved column around 196 pixels wide.

At widths of 1150 pixels and above, pin the rail and reserve its column in the page layout at the same breakpoint.

A pinned rail without paired content spacing is a defect.

Below 1150 pixels, use a toggle button and a bordered overlay card.

Do not leave a naked fixed rail and do not hide navigation entirely.

Section subtitles are not links.

## Groups

The rail contains exactly `Main`, `Rounds`, and `Decisions` in that order.

Main has one link to the informational content.

Rounds has one link per round.

Decisions has one link to the decision zone.

Each round label uses a CSS status glyph, the round number, `&middot;`, and a terse summary.

## Status glyphs

Use text glyphs with CSS classes whose shape and color both communicate state.

The canonical text glyphs are `&#10003;` for done, `&#9679;` for in progress, `&#9675;` for waiting, `&#10007;` for failed, and `&#9680;` for superseded.

Use David-warm good, clay, muted, and brick tokens for those states.

Do not use emoji graphics or platform-dependent emoji presentation.

Use the same convention for the round tag in each round heading.

## Dynamic and scrollable behavior

The rail spans the viewport and scrolls independently when its entries exceed the available height.

Use `overflow-y:auto` and `overscroll-behavior:contain`.

Keep entries above the reply bar.

Build round links at load time from a `data-nav="<status-class>|<label>"` attribute on each round section.

Do not maintain a second hand-written round list.

Use `IntersectionObserver` to apply an `.on` class to the entry for the section currently in view.

If the required rail or overlay component is missing from David-warm, add it there first in a separately reviewed change rather than inventing a local style.
