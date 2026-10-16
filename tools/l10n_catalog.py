#!/usr/bin/env python3
"""Keep Sources/NtfyxCore/Resources/Localizable.xcstrings in step with the code.

The catalog is keyed by the Chinese source text, so `sync` harvests every `L("…")` /
`LF("…")` / `L10n.text("…")` literal in Sources/ and adds the missing keys. `check` fails
when a key has no English value, when an English value still holds Chinese, or when the
format specifiers of a translation do not match its key.

    python3 tools/l10n_catalog.py sync          # add missing keys (empty en value)
    python3 tools/l10n_catalog.py sync --prune   # also drop unreferenced keys
    python3 tools/l10n_catalog.py merge f.json   # fold {"中文": "English"} fragments in
    python3 tools/l10n_catalog.py check          # CI gate
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
CATALOG = SOURCES / "NtfyxCore" / "Resources" / "Localizable.xcstrings"
CALLS = ("L", "LF", "L10n.text", "L10n.format")

CJK = re.compile(r"[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff00-\uffef]")
SPEC_RE = re.compile(
    r"%(?:\d+\$)?[-+ #0]*[\d*]*(?:\.[\d*]+)?(?:hh|h|ll|l|q|z|j|t)?([diouxXeEfFgGaAcspn%@])"
)
STRING_LIT = r'"((?:[^"\\\n]|\\.)*)"'
CALL_RE = re.compile(
    r"(?<![A-Za-z0-9_.])(" + "|".join(re.escape(c) for c in CALLS) + r")\(\s*" + STRING_LIT
)
# A call whose first argument is not a literal hides its key from the catalog, so the
# completeness gate below cannot see it: `L(expanded ? "收起" : "展开")` is a bug.
INDIRECT_RE = re.compile(
    r"(?<![A-Za-z0-9_.])(?:" + "|".join(re.escape(c) for c in CALLS) + r")\([ \t\n\r]*(?=[^\s\"])"
)
ESCAPES = {"\\n": "\n", "\\t": "\t", '\\"': '"', "\\\\": "\\", "\\0": "\0"}


def unescape(text: str) -> str:
    out, i = [], 0
    while i < len(text):
        for esc, ch in ESCAPES.items():
            if text.startswith(esc, i):
                out.append(ch)
                i += len(esc)
                break
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))


def referenced_keys() -> set[str]:
    keys: set[str] = set()
    for path in sorted(SOURCES.rglob("*.swift")):
        body = strip_comments(path.read_text(encoding="utf-8"))
        for match in CALL_RE.finditer(body):
            key = unescape(match.group(2))
            if key:
                keys.add(key)
    return keys


def indirect_call_sites() -> list[str]:
    hits = []
    for path in sorted(SOURCES.rglob("*.swift")):
        if path.name == "Localization.swift":
            continue
        for lineno, line in enumerate(strip_comments(path.read_text(encoding="utf-8")).splitlines(), 1):
            if line.lstrip().startswith(("public func L", "public func LF")):
                continue
            if INDIRECT_RE.search(line):
                hits.append(f"{path.relative_to(ROOT)}:{lineno}: {line.strip()}")
    return hits


def entry(value: str) -> dict:
    return {
        "localizations": {
            "en": {"stringUnit": {"state": "translated" if value else "new", "value": value}}
        }
    }


def load() -> dict:
    if CATALOG.exists():
        return json.loads(CATALOG.read_text(encoding="utf-8"))
    return {"sourceLanguage": "zh-Hans", "strings": {}, "version": "1.0"}


def save(doc: dict) -> None:
    doc["strings"] = dict(sorted(doc["strings"].items()))
    CATALOG.write_text(
        json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def english_of(entry: dict) -> str | None:
    unit = entry.get("localizations", {}).get("en", {}).get("stringUnit", {})
    return unit.get("value")


def specs_of(text: str) -> list[str]:
    """Format specifiers in order, normalized: positional prefixes and integer widths dropped."""
    out = []
    for match in SPEC_RE.finditer(text.replace("%%", "\x00")):
        char = match.group(1)
        out.append("d" if char in "diuxXoO" else "@" if char in "@sp" else char)
    return out


def problems(doc: dict) -> list[str]:
    issues: list[str] = []
    for key, entry in doc["strings"].items():
        value = english_of(entry)
        chinese = bool(CJK.search(key))
        if value is None:
            if chinese:
                issues.append(f"missing en localization: {key}")
        elif not value.strip():
            if chinese:
                issues.append(f"empty en value: {key}")
            else:
                print(f"  note language-neutral key needs no en value: {key}")
        elif CJK.search(value):
            issues.append(f"en value still Chinese: {key!r} -> {value!r}")
        elif key.strip() == value.strip():
            if chinese:
                issues.append(f"en value identical to key: {key}")
            else:
                print(f"  note language-neutral key translated as-is: {key}")
        elif specs_of(key) != specs_of(value):
            issues.append(
                f"format specifiers differ: {key!r} {specs_of(key)} vs {value!r} {specs_of(value)}"
            )
    return issues


def merge(path: Path) -> int:
    """Fold a `{中文key: English}` JSON file into the catalog."""
    doc = load()
    strings = doc.setdefault("strings", {})
    pairs = json.loads(path.read_text(encoding="utf-8"))
    added = translated = 0
    for key, value in pairs.items():
        if not isinstance(value, str):
            print(f"FAIL {path}: value for {key!r} is not a string")
            return 2
        if key not in strings:
            strings[key] = entry(value)
            added += 1
        else:
            unit = strings[key].setdefault("localizations", {}).setdefault("en", {}).setdefault("stringUnit", {})
            unit["value"] = value
            unit["state"] = "translated" if value else "new"
            translated += 1
    save(doc)
    print(f"merged {path.name}: {added} new keys, {translated} updated")
    return 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in {"sync", "check", "merge"}:
        print(__doc__)
        return 2
    doc = load()
    strings = doc.setdefault("strings", {})
    keys = referenced_keys()

    if argv[0] == "merge":
        if len(argv) < 2:
            print("usage: l10n_catalog.py merge <translation.json> [...]")
            return 2
        for fragment in argv[1:]:
            status = merge(Path(fragment))
            if status:
                return status
        missing = sorted(keys - set(load()["strings"]))
        for key in missing:
            print(f"  WARN not in catalog: {key}")
        return 0

    if argv[0] == "sync":
        added = [key for key in sorted(keys) if key not in strings]
        for key in added:
            strings[key] = entry("")
        removed = []
        if "--prune" in argv:
            removed = [key for key in sorted(strings) if key not in keys]
            for key in removed:
                del strings[key]
        save(doc)
        print(f"catalog: {len(strings)} keys, +{len(added)} added, -{len(removed)} pruned")
        for key in added:
            print(f"  new  {key}")
        for key in removed:
            print(f"  gone {key}")
        missing = sorted(keys - set(strings))
        for key in missing:
            print(f"  WARN not in catalog: {key}")
        return 0

    issues = problems(doc)
    unused = sorted(set(strings) - keys)
    for key in unused:
        print(f"  note unreferenced key still in catalog: {key}")
    for key in sorted(keys - set(strings)):
        issues.append(f"call site missing from catalog, run: l10n_catalog.py sync — {key}")
    for hit in indirect_call_sites():
        issues.append(f"key hidden behind an expression, pass a literal instead — {hit}")
    for issue in issues:
        print(f"  FAIL {issue}")
    print(f"check: {len(strings)} keys, {len(issues)} problems")
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
