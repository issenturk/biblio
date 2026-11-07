# Biblio

Biblio is a small macOS app that renames the article PDFs you download to **`Surname - Year.pdf`** and keeps a formatted reference list (APA 7 by default) as a Word file next to them. It is built for researchers who collect a lot of papers and want a tidy literature folder without typing anything.

## Features

- **Automatic renaming.** Drop PDFs or folders on the window, or add *watched folders*: new PDFs that appear there are renamed on their own, with no confirmation step. Every rename can be undone.
- **Accurate metadata.** Biblio reads the first pages (with OCR for scanned PDFs), finds the DOI or the title, and looks the work up in Crossref, OpenAlex, DataCite/doi.org and Open Library. A match is accepted only if the title and an author surname really appear on the page, so look-alike records are rejected rather than guessed.
- **Naming rules.** One author: `Becker - 1965`. Two: `Becker & Murphy - 1988`. Three or more: `Becker et al - 1988`. Names are plain ASCII, duplicates get a letter (`2013a`, `2013b`), and a missing year becomes `xxxx`. Several presets and a custom template (`{Author} {FirstAuthor} {Year} {Title} {Journal} {DOI}`) are available, with a live preview.
- **Reference list as `.docx`.** For every renamed file the reference is added to `References.docx` in the same folder: alphabetical, hanging indent, double spaced, journal and book titles in real italics. Styles: APA 7, Harvard, MLA 9, Chicago (author-date), IEEE. Changing the style rewrites the list.
- **Problem files are easy to spot.** A PDF that cannot be resolved is renamed with a `!! ` prefix so it sorts to the top of the folder, and its row explains why. References that are incomplete (no year, no title, no journal) are written in **bold red** in the Word file.
- **Manual entry.** For an unresolved file, press *Enter details…* and type the authors, year and so on. You can also paste a ready-made reference such as `Becker, G. S. (1965). A theory of the allocation of time. The Economic Journal, 75(299), 493-517.` and press *Fill the fields from this reference*: authors, year, title, journal, volume, issue, pages, DOI and type are parsed offline.
- **References tab.** Drop a bibliography (`.docx` or `.txt`): each line is looked up, all versions of the work (article, working paper, preprint) are listed, and open-access PDFs can be downloaded and named automatically. For paywalled articles Biblio only opens the DOI page in your browser; it never bypasses a paywall.
- **History control.** Each tab can clear its history, and each row can be dismissed. This only changes what is shown; files and the reference list are not touched.
- **English and Turkish interface.**

## Install

Biblio needs macOS 13 or later and the Xcode Command Line Tools (full Xcode is not required).

```bash
git clone https://github.com/issenturk/biblio.git
cd biblio
./build.sh --install     # builds build/Biblio.app and copies it to /Applications
```

`./build.sh` alone builds `build/Biblio.app` without installing. The app is signed ad hoc, so on first launch macOS may ask you to confirm: right-click the app and choose *Open*. Folder access is requested the first time you add a folder.

## Privacy

- PDFs are never uploaded. Only a DOI or a few lines of the title are sent to the metadata services, and only when *online lookup* is on.
- Online lookup can be switched off in Settings. Accuracy is then much lower (the first-page text and file name are all Biblio has), and unresolved files are flagged.
- No analytics and no account. Settings and history live in `~/Library/Application Support/Biblio/`.
- An optional free [OpenAlex](https://openalex.org) API key in Settings raises the rate limits, which helps when you process hundreds of files at once.

## How it works

1. The first two pages are read with PDFKit; if there is almost no text, Vision OCR (English and Turkish) is used.
2. A DOI on the page is resolved directly. Otherwise title phrases and author lines are searched in Crossref and OpenAlex, with extra handling for arXiv, SSRN, NBER, JSTOR, EconStor and MPRA cover pages, ISBNs and file names.
3. A candidate is verified against the page (title words, author surname, plausible year) before it is trusted; journal versions are preferred over working-paper records.
4. The file is renamed, the full reference is stored in a hidden `.References.json` beside the PDFs, and `References.docx` is regenerated from it.

Four files are processed at a time, and rate-limited or offline files are retried after a few minutes instead of being given a wrong name.

## Project layout

| Path | Purpose |
|---|---|
| `Sources/Engine.swift` | reading, OCR, lookups, verification, renaming |
| `Sources/Namer.swift` | file name patterns |
| `Sources/Cite.swift` | citation styles |
| `Sources/RefParse.swift` | parser for pasted references |
| `Sources/Docx.swift` | minimal `.docx` writer |
| `Sources/Biblio.swift` | References tab (bibliography lookup and downloads) |
| `Sources/Model.swift`, `Sources/App.swift` | state and SwiftUI interface |
| `Sources/Loc.swift` | English/Turkish strings |
| `cli/` | command-line evaluation tool (`--dry-run`, `--evaluate`) |
| `icon/` | app icon and the script that draws it |

## Limitations

- Automatic matching is very good but not perfect. Check the names and the reference list, especially the red entries.
- Books and unusual documents may only be matched from the file name or cover; those references are marked for checking.
- Edits you make by hand in `References.docx` are overwritten the next time the list changes; copy the file elsewhere before editing.

## License

[MIT](LICENSE). Provided as is, without warranty.
