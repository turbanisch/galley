# Test PDFs for link detection

The PDFs themselves are not in git (copyright); only this file is. `./test.sh` reads every PDF
in this folder, writes one report per PDF to `reports/` and compares it with `expected/`.
`./test.sh --accept` makes the current reports the new baseline – only after the changes were
checked in the app.

## In the corpus

| PDF | Kind | What it tests |
|---|---|---|
| Alesina and Dollar 2000 | Old Springer journal, no links | Endnotes in a "Notes" section, organizations as authors in table notes |
| Braggion et al. 2018 | Word export (SSRN), no links | Captions without punctuation ("Table 4 P2P lending …"), Roman sections, "specification (4)" = column, "Di Maggio" vs. "DiMaggio" |
| Campante et al. 2019 | NBER working paper (LaTeX, no hyperref) | Sections, equations "(3)", appendix citations and tables "B.2", footnotes |
| Cavallo et al. 2021 | AER, no links | Author–year citations, footnotes, captions below figures with notes |
| Chen and Roth 2024 | QJE, hyperref bookmarks | Bookmarks number subsections "I.i" where the page prints "I.A."; a bookmark at the bottom of a page whose heading starts the next |
| Chen et al. 2025 | PLOS ONE | Numbered citations [12], PDF links with imprecise targets |
| Dell 2010 | Econometrica (Wiley), natbib links | Retargeting vague PDF links, small caps names, pre-1900 years, organizations, "(1988)" for repeated authors |
| Dreher et al. 2018 | International Studies Quarterly (Oxford), two columns | Unnumbered section headings only 5% larger than the text, bold not reported by PDFKit; italic subsections not detectable |
| Dreher et al. 2019 | Journal of Development Economics (Elsevier), two columns, links | Bookmarks from the conclusion on all point at one spot and appendix bookmarks lack their letters (looked up in the text); text without space characters ("Summarystatistics", a known limit) |
| Fajgelbaum et al. 2020 | QJE (Oxford), links | Roman table numbers, online appendix "Figure A.1", rotated tables |
| Fuchs and Turbanisch 2026 | Felix's own LaTeX draft (hyperref, biblatex) | `\appendix` with lettered sections and bookmarks without numbers (outline groups the appendix), "tables." before a page number is no mention |
| Hyde and Marinov 2012 | JSTOR scan with recognized text | JSTOR bookmarks (one per page, the issue's other articles) dropped; no headings guessed from noisy type sizes |
| austin-strange-presentation | Slides without an outline | Opens with thumbnails, no headings guessed |
| tracking-chinese-aid-presentation | Beamer slides with an outline | Section outline, appendix collapsed |
| Greiner et al. 2011 | LaTeX, no links | Footnotes, caption above figure |
| Heilmann 2016 | Elsevier, two columns, links | Group links, significance-star links, small print |
| Helble 2012 | Word export | "V. REFERENCES", "&" between authors, "A. Appendix 1:", "Graph 1" |
| Jaya Y. Wen 2020 | Job market paper (LaTeX, hyperref) | Long two-line table titles in the text's full width ("… — Robustness to Initial / County …"), "SOE vs." in a title, appendix tables "A.21" |

## Still to add (one per kind is enough; aim for about 12–15 PDFs in total)

1. **An older scanned paper with poor recognized text** (Hyde is a clean JSTOR scan) – Galley must not invent links where the text is poor.
2. **A long document** (dissertation or book, 200+ pages) – load time (detection runs on every open; equation detection measures character positions), footnote numbering that restarts per chapter.
3. **A German paper** – "Abbildung", "Tabelle", "Literaturverzeichnis", "Anmerkungen" are in the code but untested.
4. **Many footnotes** (law or political science) – footnote detection beyond economics papers.
5. **arXiv with numbered citations [12]** – probably works like PLOS; a quick check.
6. **Superscript citations** (Nature, Science, medical journals) – not supported yet; would be a new feature.
