# Bookalog design system

Bookalog is a working tool for a small publisher: every edition reads as a
labelled stock item on a shelf. The visual system lives in
`app/lib/design.dart` (`buildBookalogTheme`, `ShelfPalette`) and is aligned with
The 3 Little Sisters storefront brand.

## Palette

| Role | Light | Dark | Use |
| --- | --- | --- | --- |
| canvas | `#F7F6F4` | `#1B1A1B` | Window background |
| rail | `#F0EEEB` | `#161516` | Sidebar |
| paper | `#FFFFFF` | `#222022` | Cards, tables, detail pane |
| ink | `#1F1B1C` | `#ECE7E8` | Primary text |
| inkMuted | `#6A6365` | `#A39C9E` | Secondary text, counts |
| hairline | `#E3DFDC` | `#343032` | 1px dividers and borders |
| accent | `#65172D` (brand burgundy) | `#7E2A41` (lifted burgundy) | Primary button fill and the brand mark only |
| onAccent | `#FFFFFF` | `#FFFFFF` | Text on accent |
| accentInk | `#65172D` | `#DDA3AF` (dusty rose) | Selected text and icons, text buttons, focus rings |
| selection | `#F3E7EA` | `#362229` | Wash behind the current selection |
| blankBoard | `#E8E4E0` | `#2C292B` | Cover placeholder, muted marks |

Burgundy from The 3 Little Sisters storefront is the only hue in the chrome.
Neutrals are warm graphite and off-white, so covers carry the colour. In dark
mode, burgundy is lifted just enough to hold a white button label. The
storefront's navy, gold and pink are deliberately not used.

Rules:

- Solid accent fills are reserved for the one primary button per view and the
  brand mark. Selection (sidebar item, gallery plate, calendar row, table row,
  chip, segment) uses the `selection` wash with `accentInk` or ink text, never a
  solid fill.
- Text on accent, selection and every surface must stay at WCAG AA (4.5:1) or
  better; `app/test/design_test.dart` checks this.
- Publication status uses `StatusTag` text and shape, not colour alone.

## Type

- Figtree (OFL, bundled in `app/assets/fonts/`) for all UI text. Weights are
  400, 500, 600 and 700.
- Monospace is reserved for data: ISBNs, dates, counts and identifiers. Don't
  use it decoratively.

## Components

- **Sidebar** (≥1100px): views, publication-status filters with counts, tools,
  and a footer with the appearance switch, connection, role and sign out.
- **Appearance**: Match system / Light / Dark. The choice is saved per device
  and defaults to following the OS. On narrower windows it lives in the
  Catalog tools menu.
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
