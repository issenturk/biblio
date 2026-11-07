#!/usr/bin/env python3
"""PDF makaleleri 'Soyad - Yil.pdf' seklinde yeniden adlandirir.

Kullanim:
  pdfadi.py KLASOR_veya_DOSYA ...        gercekten yeniden adlandirir
  pdfadi.py --dry-run KLASOR             sadece ne yapacagini yazar
  pdfadi.py --undo KLASOR                son calistirmayi geri alir

Kaynak sirasi: PDF icindeki DOI -> Crossref, bulunamazsa basliktan Crossref aramasi.
Emin olunamayan dosyalara dokunulmaz.
"""
import argparse, json, re, sys, time, unicodedata, urllib.parse, urllib.request
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import logging
from pypdf import PdfReader

logging.disable(logging.CRITICAL)

LOG_NAME = ".pdfadi_log.json"
DOI_RE = re.compile(r"10\.\d{4,9}/[^\s\"<>]+", re.I)
UA = {"User-Agent": "pdfadi/1.0"}


def ascii_fold(s):
    s = s.replace("ı", "i").replace("İ", "I").replace("ß", "ss")
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[^A-Za-z0-9 \-']", "", s)
    return re.sub(r"\s+", " ", s).strip()


def read_text(path, pages=2):
    try:
        r = PdfReader(str(path))
        if r.is_encrypted:
            r.decrypt("")
        text = "\n".join((r.pages[i].extract_text() or "") for i in range(min(pages, len(r.pages))))
        return text, r.metadata
    except Exception:
        return "", None


def crossref(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def tokens(s):
    return {t for t in re.findall(r"[a-z0-9]+", ascii_fold(s).lower()) if len(t) > 3}


def title_in_text(title, text):
    tt = tokens(title)
    if not tt:
        return False
    return len(tt & tokens(text)) / len(tt) >= 0.6


def parse_work(msg):
    authors = [a.get("family") or a.get("name") for a in msg.get("author", []) if a.get("family") or a.get("name")]
    year = None
    for k in ("published-print", "published-online", "issued", "published"):
        dp = (msg.get(k) or {}).get("date-parts") or [[None]]
        if dp[0] and dp[0][0]:
            year = dp[0][0]
            break
    title = (msg.get("title") or [""])[0]
    return authors, year, title


def lookup(path):
    text, meta = read_text(path)
    # 1) DOI
    cands = []
    for m in DOI_RE.finditer(text):
        d = m.group(0).rstrip(".,;)]}")
        if d not in cands:
            cands.append(d)
    stem_doi = re.match(r"(10\.\d{4,9})[-_](.+?)(?:-\d+)*$", path.stem)
    for d in cands[:3]:
        try:
            authors, year, title = parse_work(crossref("https://api.crossref.org/works/" + urllib.parse.quote(d))["message"])
        except Exception:
            continue
        if authors and year and title_in_text(title, text):
            return authors, year, "doi"
    # 2) baslik aramasi
    q = ""
    if meta and meta.title and len(meta.title) > 15:
        q = meta.title
    else:
        lines = [l.strip() for l in text.splitlines() if len(l.strip()) > 25]
        q = " ".join(lines[:3])
    if q:
        try:
            items = crossref("https://api.crossref.org/works?rows=8&select=author,issued,published-print,published-online,title,type&query.bibliographic="
                             + urllib.parse.quote(q[:300]))["message"]["items"]
        except Exception:
            items = []
        items.sort(key=lambda it: it.get("type") != "journal-article")
        for it in items:
            authors, year, title = parse_work(it)
            if authors and year and title and len(tokens(title)) >= 3 and title_in_text(title, text) \
                    and len(tokens(title) & tokens(q)) / len(tokens(title)) >= 0.7:
                return authors, year, "baslik"
    return None


def make_base(authors, year):
    fam = [ascii_fold(a) for a in authors]
    fam = [f.title() if f.isupper() else f for f in fam]
    fam = [f for f in fam if f]
    if not fam:
        return None
    if len(fam) == 1:
        a = fam[0]
    elif len(fam) == 2:
        a = f"{fam[0]} & {fam[1]}"
    else:
        a = f"{fam[0]} et al"
    return f"{a} - {year}"


def collect(paths):
    out = []
    for p in map(Path, paths):
        if p.is_dir():
            out += sorted(x for x in p.iterdir() if x.suffix.lower() == ".pdf" and not x.name.startswith((".", "~$")))
        elif p.suffix.lower() == ".pdf":
            out.append(p)
    return out


def undo(folder):
    log = Path(folder) / LOG_NAME
    if not log.exists():
        sys.exit("Geri alinacak kayit yok.")
    data = json.loads(log.read_text())
    for new, old in reversed(list(data["renames"].items())):
        n, o = Path(folder) / new, Path(folder) / old
        if n.exists() and not o.exists():
            n.rename(o)
            print(f"geri alindi: {new} -> {old}")
    log.unlink()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--undo", action="store_true")
    a = ap.parse_args()
    if a.undo:
        return undo(a.paths[0])

    files = collect(a.paths)
    planned = defaultdict(list)  # (klasor, base) -> [dosyalar]
    skipped = []
    for f in files:
        res = lookup(f)
        time.sleep(0.2)
        if not res:
            skipped.append(f)
            continue
        authors, year, how = res
        base = make_base(authors, year)
        if not base:
            skipped.append(f)
            continue
        planned[(f.parent, base)].append((f, how))

    renames = {}
    for (folder, base), items in planned.items():
        existing = {p.name.lower() for p in folder.iterdir()}
        multi = len(items) > 1
        for i, (f, how) in enumerate(items):
            if f.name == f"{base}.pdf":
                continue
            if multi:
                name = f"{base}{chr(ord('a') + i)}.pdf"
            else:
                name = f"{base}.pdf"
            n = 0
            while name.lower() in existing and name != f.name:
                n += 1
                name = f"{base}{chr(ord('a') + n - 1)}.pdf" if not multi else f"{base}{chr(ord('a') + len(items) + n - 1)}.pdf"
            existing.add(name.lower())
            renames[f] = (name, how)

    for f, (name, how) in renames.items():
        print(f"{f.name}\n   -> {name}   [{how}]")
        if not a.dry_run:
            f.rename(f.with_name(name))
    if skipped:
        print("\nDokunulmadi (bilgi bulunamadi/emin olunamadi):")
        for f in skipped:
            print("  ", f.name)
    if not a.dry_run and renames:
        folder = next(iter(renames)).parent
        log = folder / LOG_NAME
        prev = json.loads(log.read_text())["renames"] if log.exists() else {}
        prev.update({n: f.name for f, (n, _) in renames.items()})
        log.write_text(json.dumps({"time": datetime.now().isoformat(), "renames": prev}, ensure_ascii=False, indent=1))
    print(f"\n{len(renames)} yeniden adlandirildi{' (deneme)' if a.dry_run else ''}, {len(skipped)} atlandi.")


if __name__ == "__main__":
    main()
