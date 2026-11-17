<p align="center">
  <img src="Icon/macOS/AppIcon.appiconset/icon_128x128@2x.png" width="112" alt="Galley's icon: a red Fraktur G on paper">
</p>

<h1 align="center">Galley</h1>

You are on page 14. The text says "see Table 4". Table 4 is on page 38, the footnote you just
passed is at the bottom of the page, and "(Dell 2010)" is somewhere in the reference list. Reading
a paper as a PDF means leaving your place every few sentences and then finding it again.

Galley is a PDF reader for macOS that takes this one problem seriously. Hover over a reference
to a table, figure, equation, section, footnote or citation, and its target appears in a
preview while the page stays where it is. This also works in PDFs that contain no links at all –
old journal scans, Word exports, working papers – because Galley reads the text and finds the
references itself.

I wrote it for my own reading as an economist and can no longer do without it. It is free, and
I'm sharing it in the hope that it is useful to others who read a lot of papers, or other long
documents.

<!-- shot: hero.png – a paper open with the outline sidebar and a link preview showing a table -->

## Installing

There is no download yet, so for now you build it yourself, which takes about a minute. You need
macOS 14 or later and Apple's command line tools (`xcode-select --install`, if you don't have
them). Then run these three lines in Terminal:

```bash
git clone https://github.com/turbanisch/galley.git
cd galley
./build.sh
```

This compiles Galley and puts it into your Applications folder. Open a PDF with File → Open, or
with right-click → Open With → Galley in the Finder.

## The first five minutes

Open a paper you know and try these, in this order:

1. Press ⌥↓ a few times to move from heading to heading. ⌥⇧↓ skips to the next main section.
2. Hover over a reference to a table, a citation or a footnote number. The target shows up in a
   preview.
3. Click it to go there, then press ⌘⌥← to return to where you were.
4. Hover over another reference and press S. Its target opens beside your text and stays there
   while you read on. S closes it again.
5. Press G, then F, then 2, then Return: you are at Figure 2. G is "go to"; the letter says what
   kind of thing (T table, E equation, N note, R reference, S section), and a plain number is a
   page.
6. Select a sentence and press M to highlight it, then A to write a comment on it. Both are
   saved in the PDF, where Zotero picks them up.

Most of Galley works like this: single keys, no modifier. Press ? for the full list.

<!-- shot: tour.gif – the six steps above in one take, on one paper -->

## What it does

### Table of contents

The sidebar (B) shows the paper's sections. If the PDF has no table of contents, Galley builds
one from the headings; if it has a messy one, Galley tidies it. Appendices are folded into a
single entry so that the paper itself fits on one screen. The sidebar can show page thumbnails
instead (View menu). ⌥↑ and ⌥↓ move from heading to heading, ⌥⇧↑ and ⌥⇧↓ between main sections.

<!-- shot: outline.png – sidebar with grey section numbers and a collapsed Appendix -->

### Previews and links

Hovering over a link shows its target: the whole figure, the table, the equation, the footnote,
the entry in the reference list. Clicking jumps there, and ⌘-click opens the target in the split
view.

Where a PDF comes without links, Galley adds them for figures, tables, sections, equations,
footnotes and endnotes, and for citations, both numbered ("[12]") and author–year
("Acemoglu et al. (2001)"). Where a PDF has links that only point roughly at the right page,
Galley tries to find the exact line for the preview to start at.

Don't expect wonders, though. All of this rests on rules of thumb about how papers are laid out,
and layouts vary. Where Galley is unsure, it would rather miss a link than invent a wrong one.

<!-- shot: preview-figure.gif – hovering over "Figure 3" in the text, the figure pops up -->

### Split view (S)

S shows the same document a second time, side by side; with a preview showing, it opens the
preview's target there. S or Esc closes it again.

Holding ⌘ sends anything you would otherwise jump to – a link, a sidebar entry, a search result,
a match in Go to – to the other side and leaves your reading position alone.

<!-- shot: split-view.png – text on the left, regression table on the right -->

### Go to (G)

G opens a small palette. Type a page number, or first a letter for the kind of object and then
its number or a few words:

- `G 12` – page 12
- `G T 3` – Table 3
- `G F A.1` – Figure A.1
- `G E 9` – equation (9)
- `G N 14` – footnote 14
- `G R acemoglu` – Acemoglu's entries in the reference list
- `G S robust` – the section on robustness
- `G A` – your annotations, found by their text or your comment

↑ and ↓ show each match in the paper while the palette stays open. Return goes there; Esc takes
you back to where you were.

<!-- shot: jump-palette.gif – G T, stepping through tables, Return -->

### Search (F)

Results are listed in the sidebar under the sections they occur in, so you see where in the
paper a term comes up and not only how often. Accents are ignored ("Garcia" finds "García"), and
whole-word and regular-expression search are available from the search field. ↑ and ↓ step
through the matches, Return stays at one, and Esc takes you back to where you were.

<!-- shot: search.png – searching "instrument", results under their sections -->

### Highlights and comments (M, U, A)

M highlights the selected text, U underlines it, A adds a comment, and 1–8 change the colour.
⌫ or the same key on a highlight or underline removes it again.

Highlights are saved into the PDF in the standard format, so other programs see them too. In
particular, Zotero imports them with their colours and comments. Galley keeps a copy of the
untouched file, and File → Revert to Original brings it back.

<!-- shot: highlights.png – highlights in two colours, a comment marker, the palette listing them -->

### Link hints (R)

For those who prefer not to reach for the mouse: R puts a short label on every link in view.
Typing a label opens its target in the split view; keeping its last key held down shows the
preview instead, and ⇧ jumps there.

<!-- shot: link-hints.png -->

### Reading and scrolling

- Papers open in Reading Size, a zoom level that brings the body text to a comfortable size
  whatever the journal's layout. The other modes are Fit Page, Fit Width, Fit Text Width and
  Actual Size. One tap on Z returns to the mode you used before; more taps step through the
  rest.
- D switches the page colour between light, sepia and dark in the same way. This only affects
  the screen, not the file.
- Holding ↓ or ↑ (or J, K) scrolls smoothly; ← and → turn pages. Space starts a slow automatic
  scroll, and + and − set its speed.
- Slide decks open one slide per screen with thumbnails in the sidebar, and ⇧⌘F starts a
  full-screen slide show of any document.
- When the file changes on disk – say, because you recompiled your LaTeX – Galley reloads it and
  stays at the same spot.

## Keys

These are the keys you will use most. Press ? in the app for the full list.

| Key | |
|---|---|
| S | Split view |
| G | Go to a page, figure, table … |
| F | Search |
| B | Show / hide the sidebar |
| R | Link hints |
| D | Page colour |
| Z | Zoom mode |
| + / − | Zoom in / out |
| Space | Start / stop auto-scroll |
| ↑ ↓ ← → or H J K L | Scroll, turn pages |
| ⌥↑ ⌥↓ | Previous / next heading |
| ⌘⌥← ⌘⌥→ | Jump back / forward between positions |
| M / U | Highlight / underline the selection |
| A | Comment on a highlight |
| 1–8 | Highlight colour |
| ⇧⌘F | Slide show |

## What it doesn't do

Galley is for reading. It does not rearrange or edit pages, it has no drawing tools, and
annotation stops at highlights, underlines and comments.

The detection has been tested mostly on economics and neighbouring social sciences: the big
journals, NBER and SSRN working papers, a JSTOR scan, Word exports, Beamer and PowerPoint slides.
Conventions from other fields may not be recognized yet.

## Reporting problems

This is an early version that I use every day and that a small group of people is now trying
out. If a paper comes out wrong – a link to the wrong table, a missing section in the sidebar, a
preview that cuts a figure in half – please open an issue and say which paper it was. Such
reports are the most useful thing you can give back: every fix is checked against a collection
of real papers, so that repairing one journal's layout doesn't quietly break another's.

## Licence

Copyright © 2026 Felix Turbanisch. Galley is free software under the
[GNU General Public License v3.0](LICENSE): you may use, change and share it, and versions you
pass on must remain open source under the same licence. It was built with Claude Code.
