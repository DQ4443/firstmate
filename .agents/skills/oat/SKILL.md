---
name: oat
description: The single style-owner boundary for every David-facing Lavish plan, report, checkpoint, comparison, reference, and dashboard page. Load before creating any such HTML. Copy visual tokens and components verbatim from data/operating-model/components/david-warm.html, then apply this skill's diagram, layout, and screenshot-QA duties without creating a second palette or component system.
---

# oat, the house style boundary

Every David-facing HTML page uses the path in `DAVID_WARM_COMPONENT_FILE` as its only source of visual tokens and components.

When the variable is unset, resolve `data/operating-model/components/david-warm.html` relative to the repository root.

If the resolved file is absent, stop because page creation is blocked.

Read that file completely before writing the page.

Copy each required component from its `COPY VERBATIM` marker through its matching close marker.

Change only human text inside the copied structure.

Decision pages copy `COPY VERBATIM: DECISION ZONE` verbatim.

Checkpoint pages copy `COPY VERBATIM: DYNAMIC SIDEBAR` verbatim.

Pages with directed graphs copy `COPY VERBATIM: MERMAID LIGHT THEME` verbatim.

Do not restyle a copied component and do not add a second palette.

If a component is missing, run `.agents/skills/lavish/scripts/install-components.py "${DAVID_WARM_COMPONENT_FILE:-data/operating-model/components/david-warm.html}"` against a reviewable copy or the authorized canonical file, review that source change, then copy it into the page.

The installer must never target an unverified substrate.

## Canonical component source

David-warm owns the warm-light tokens, base reset, page header, cards, wash sections, Your-call blocks, status chips, evidence badges, Mermaid theme, and footer.

Oat does not duplicate their CSS.

The page stays warm light in every viewer.

Do not add dark-mode branches.

Do not use dark chrome, emoji, em dashes, or colored edge accents on cards.

## Diagram interaction

Every diagram must be readable at page width and available at a larger readable size when the content needs it.

Use a zoom interaction only when its visible structure and style already exist in David-warm.

If that component is absent, add it to David-warm before relying on it.

A diagram whose labels cannot be read without browser zoom fails QA.

## Hard rules

| Rule                       | Required behavior                                                                                   |
| -------------------------- | --------------------------------------------------------------------------------------------------- |
| No accent-edge cards       | Emphasis uses a David-warm wash, full soft border, status chip, or heavier text.                    |
| Diagrams before text walls | A pipeline, architecture, or flow section starts with a rendered figure and a compact anchor table. |
| Tables for repeated fields | Repeated structured content uses the canonical table treatment rather than prose repetition.        |
| Color means status         | Good, brick, clay, and muted colors follow the semantics already defined in David-warm.             |
| No truncation              | Text wraps and wide tables scroll inside their own container.                                       |
| Short summary              | Use at most four standalone lines with one clause each.                                             |
| Light traces               | Logs and commands use the canonical warm-light preformatted block.                                  |
| Self-contained             | Inline local assets into the final HTML and do not rely on remote fonts or scripts.                 |

## Directed acyclic graphs use Mermaid

Copy the `COPY VERBATIM: MERMAID LIGHT THEME` component from the configured canonical file verbatim.

Do not claim browser execution until a real browser renders the diagram and the screenshot is read.

Use a vertical flow when it keeps the path compact and readable.

Use wide, low nodes with one concise line when the diagram would otherwise become tall and narrow.

Use one soft-clay status treatment for the emphasized step and warm neutral treatments for structure.

Use a full soft border around groups rather than a sharp default cluster box.

Keep the logical width within the page and split a large graph into several smaller diagrams when the funnel would be hard to read.

Use the canonical component's basis curve, measured font, and theme values without local overrides.

Pad labels or render a local image only when browser QA proves the executable component cannot present the graph readably.

Read the rendered image and fix clipped labels, wrong fonts, overlap, stray edges, and unreadable scaling.

Embed the final local image into the self-contained page.

## Cycles use circles

Do not force a process loop into a top-to-bottom Mermaid graph with a back edge.

Draw the cycle as an inline SVG with stations distributed around the full circle.

Place the entry at the left and the emphasized decision or exit at the right.

Show the return condition on the lower arc and keep arrows tangent to the cycle.

For five stations, start from `viewBox="0 0 1150 520"`, center `(500,260)`, radius `165`, and station angles `126`, `198`, `270`, `342`, and `54` degrees in the downward-positive SVG frame.

The first and last stations, entry, and exit share one lower horizontal baseline while the cycle rises above it.

Use David-warm tokens for fills, strokes, status, and text.

For a detailed loop, add an exploded-lanes figure with one horizontal lane per station.

Use dashed treatment only for conditional steps.

Keep the inline SVG crisp and themeable rather than converting the cycle to a PNG.

## Charts

Use warm neutral structure and reserve David-warm good and brick colors for positive and negative status.

Use tabular numerals for numeric comparisons.

State the scale, unit, and source next to every chart.

## QA and delivery

1. Write the self-contained page at its stable `.lavish/<workstream>.html` path.
2. Render it in a real browser at a representative desktop viewport and take a full-page screenshot when useful.
3. Read the screenshot and inspect overflow, overlap, clipping, typography, diagram labels, table width, and fixed controls.
4. Exercise every interactive control, including decision selection, typed replies, tabs, overlays, and Copy fallbacks.
5. Fix each error-severity issue and render again.
6. Open the stable page with `lavish-axi <html-file>` and record real session identity before claiming resume.
7. Use `lavish-axi poll <html-file>` only for the active local review loop.
8. Do not share, export to a public host, or send externally without David's explicit word.

## Division of labor

- Oat owns the style source, diagram language, layout rules, and QA recipe.
- Lavish owns plan, report, and checkpoint anatomy plus decision interaction.
- David-warm owns every visible token and component.
- A product mockup uses that product's design system only inside its framed mockup area.
