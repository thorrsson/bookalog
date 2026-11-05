# Bookalog design system

Bookalog is a working tool for a small publisher: every edition reads as a
labelled stock item on a shelf. The visual system lives in
`app/lib/design.dart` (`buildBookalogTheme`, `ShelfPalette`) and is aligned with
The 3 Little Sisters storefront brand.

## Palette

| Role | Light | Dark | Use |
| --- | --- | --- | --- |
| canvas | `#F5F5F5` | `#0F2B36` (brand navy) | Window background |
| rail | `#ECEBE6` | `#0A2029` | Sidebar |
| paper | `#FFFFFF` | `#143541` | Cards, tables, detail pane |
| ink | `#1C2022` | `#F2F0EA` | Primary text |
| inkMuted | `#585C55` | `#A8B6B9` | Secondary text, counts |
| hairline | `#D2D5D0` (brand stone) | `#25495A` | 1px dividers and borders |
| accent | `#65172D` (brand burgundy) | `#DAA428` (brand gold) | Primary action, selection, focus |
| onAccent | `#FFFFFF` | `#19181D` | Text on accent |
| blankBoard | `#E3E1DA` | `#1C4251` | Cover placeholder |

Rules:

- Use accent only for the primary action, the current selection (sidebar item,
  gallery plate, calendar row) and focus rings. Table rows and chips use a
  translucent accent tint so ink text keeps its contrast.
- Never put burgundy on navy or gold on off-white. Each mode has exactly one
  accent.
- Publication status uses `StatusTag` text and shape, not colour alone.

## Type

- Figtree (OFL, bundled in `app/assets/fonts/`) for all UI text. Weights are
  400, 500, 600 and 700.
- Monospace is reserved for data: ISBNs, dates, counts and identifiers. Don't
  use it decoratively.

## Components

- **Sidebar** (≥1100px): views, publication-status filters with counts, tools,
  and a connection, role and sign-out footer.
- **Toolbar**: search, Filters, reload and one filled "New edition" action.
- **Covers**: full-bleed 2:3 with a soft shadow. Missing covers show a blank
  board with the title.
- **Stock card** (detail pane, 388px at ≥1100px; dialog otherwise): cover,
  title, byline, `StatusTag`, `IsbnLabel` (an EAN-13 barcode drawn from the
  ISBN), a fact grid and actions.
- **Release calendar**: month manifest grouped by heading, with a mono day
  column.

## Bans

No eyebrows or kickers, no gradient text, no glass effects, and no coloured
side borders thicker than 1px.
