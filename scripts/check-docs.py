#!/usr/bin/env python3
"""Check repository Markdown links and images without accessing the network."""

import html
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent


def prose(text):
    """Exclude fenced examples, whose links are not part of the rendered page."""
    lines = []
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if marker:
            value = marker.group(1)
            if fence is None:
                fence = value
            elif value[0] == fence[0] and len(value) >= len(fence):
                fence = None
            lines.append("")
        else:
            lines.append(line if fence is None else "")
    return "\n".join(lines)


def anchors(text):
    result = set(re.findall(r'<(?:a|h[1-6])\b[^>]*\b(?:id|name)=[\'"]([^\'"]+)', text))
    counts = {}
    for line in text.splitlines():
        match = re.match(r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$", line)
        if not match:
            continue
        title = re.sub(r"!?\[([^\]]+)\]\([^)]+\)", r"\1", match.group(1))
        title = html.unescape(re.sub(r"<[^>]+>", "", title)).lower()
        slug = "".join(c for c in title if c.isalnum() or c in "_ -").replace(" ", "-")
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        result.add(f"{slug}-{count}" if count else slug)
    return result


def destinations(text):
    # Support inline links/images, reference definitions and HTML image/link tags.
    patterns = [
        r'''!?\[[^\]\n]*\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+['"][^'"]*['"])?\s*\)''',
        r"^ {0,3}\[[^\]\n]+\]:\s*(<[^>]+>|\S+)",
        r'''<(?:a|img)\b[^>]*\b(?:href|src)=['"]([^'"]+)['"]''',
    ]
    for pattern in patterns:
        for match in re.finditer(pattern, text, re.MULTILINE):
            yield text.count("\n", 0, match.start()) + 1, match.group(1).strip("<>")


def main():
    if len(sys.argv) > 1:
        if sys.argv[1:] == ["--help"]:
            print("Usage: scripts/check-docs.py\nCheck local Markdown links, images and heading anchors; no network access.")
            return 0
        print("Usage: scripts/check-docs.py", file=sys.stderr)
        return 2
    tracked = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.md"], cwd=ROOT
    ).decode().split("\0")
    pages = {ROOT / name: prose((ROOT / name).read_text()) for name in set(tracked) if name and (ROOT / name).is_file()}
    known_anchors = {path: anchors(text) for path, text in pages.items()}
    failures = []
    checked = 0
    for path, text in sorted(pages.items()):
        for line, destination in destinations(text):
            url = urlsplit(html.unescape(destination))
            if url.scheme or url.netloc:
                continue
            if url.path:
                decoded_path = unquote(url.path)
                target = (ROOT / decoded_path.lstrip("/") if decoded_path.startswith("/") else path.parent / decoded_path).resolve()
            else:
                target = path
            checked += 1
            problem = None
            if not target.exists():
                problem = "missing file"
            elif url.fragment and target.suffix.lower() == ".md":
                if target not in known_anchors:
                    known_anchors[target] = anchors(prose(target.read_text()))
                if unquote(url.fragment) not in known_anchors[target]:
                    problem = "missing heading anchor"
            if problem:
                failures.append(f"{path.relative_to(ROOT)}:{line}: {problem}: {destination}")
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        print(f"FAIL: {len(failures)} broken documentation reference(s).", file=sys.stderr)
        return 1
    print(f"Documentation checks passed ({len(pages)} Markdown files, {checked} local references).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
