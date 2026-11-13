#!/usr/bin/env python3
"""Inline reviewed local provider modules; deployment remains one PS5.1 payload."""
from pathlib import Path
import re
import sys


def bundle(source: Path) -> bytes:
    text = source.read_bytes().decode("utf-8-sig")
    pattern = r"(?ms)^# <SoftwarekatalogModules>\r?\n.*?^# </SoftwarekatalogModules>\r?\n"
    matches = list(re.finditer(pattern, text))
    if len(matches) != 1:
        raise ValueError("Expected exactly one source module loader")
    modules = []
    for name in ("ArtCraft.Catalog.ps1", "ArtCraft.Provider.ps1"):
        modules.append((source.parent / "modules" / name).read_bytes().decode("utf-8-sig").rstrip("\r\n"))
    match = matches[0]
    return (text[:match.start()] + "\n\n".join(modules) + "\n" + text[match.end():]).encode("utf-8")


if __name__ == "__main__":
    sys.stdout.buffer.write(bundle(Path(sys.argv[1])))
