# Biblio for Windows

A Windows version of Biblio: it renames article PDFs to `Surname - Year.pdf` and keeps a formatted reference list (`References.docx`) beside them. The C# engine is a port of the macOS (Swift) one and uses the same naming rules, reference styles (APA 7, Harvard, MLA 9, Chicago, IEEE), `!! ` flag for unresolved files, red/bold marking of incomplete references and manual entry. The reference list sidecar (`.References.json`) is compatible with the Mac version, so a folder can be shared between both.

## Download

Get `Biblio-windows-x64.zip` from the [Releases](../../releases) page (or from the latest *Windows build* run under Actions → Artifacts), unzip it and run `Biblio.exe`. Nothing needs to be installed.

The app is not code-signed, so Windows SmartScreen may say "Windows protected your PC" the first time: click *More info* → *Run anyway*.

## Build from source

Requires the .NET 10 SDK and Windows 10 (1809) or later.

```powershell
dotnet publish windows/Biblio.App -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o out
```

Projects: `Biblio.Core` (engine, cross-platform), `Biblio.Cli` (command-line test tool), `Biblio.App` (WPF interface).

## Differences from the Mac version

- OCR for scanned PDFs uses Windows' built-in OCR. English is available by default; add the Turkish language pack in *Settings → Time & language* for Turkish scans.
- Sentence-casing of titles in references has no name recognizer on Windows: author surnames and a list of common proper nouns are kept capitalised, other words are lowercased. Check titles that contain names or places.
- Settings and history are stored in `%APPDATA%\Biblio\state.json`.

## Status

The engine was checked against the Mac engine on a folder of ~150 PDFs (matching file names for 133 of 148, the rest being older mis-named files, flagged or rate-limited). The Windows interface and OCR have been compiled but not yet exercised on a real Windows machine.
