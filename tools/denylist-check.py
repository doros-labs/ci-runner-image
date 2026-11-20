#!/usr/bin/env python3
"""Generic content check for this public repository: exits 1 when a tracked or untracked
(not ignored) file contains something that looks internal or secret: private-looking
filesystem paths, IP addresses, local host names, e-mail addresses, issue keys, accented
words, or common credential shapes. A short allowlist covers standard names that share the
issue-key shape (SHA-256, UTF-8, ISO-8601, TLS-1).

Lines that define the patterns below carry the marker `pattern-def` and are the only lines
this file skips, so the check covers the rest of this file too.

Usage: python3 -B tools/denylist-check.py [root]   (default: current directory)
"""
import os
import re
import subprocess
import sys

MARKER = "pattern-def"
PATTERNS = [
    ("private path", re.compile(r"/root/|/Users/|/mnt/|\bstore/|\bagents/|/home/(?!runner\b)[A-Za-z]")),  # pattern-def
    ("IPv4 address", re.compile(r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b")),  # pattern-def
    ("IPv6 address", re.compile(r"\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}\b|\b[0-9A-Fa-f]{1,4}::[0-9A-Fa-f]{0,4}\b")),  # pattern-def
    ("local host name", re.compile(r"\b[A-Za-z0-9-]+\.(?:local|lan|internal|home\.arpa)\b")),  # pattern-def
    ("e-mail address", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")),  # pattern-def
    ("issue key", re.compile(r"\b[A-Za-z]{2,6}-[0-9]{1,5}\b")),  # pattern-def
    ("accented word", re.compile(r"[À-ɏ]")),  # pattern-def
    ("GitHub token", re.compile(r"\bghp_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bgh[ousr]_[A-Za-z0-9]{20,}")),  # pattern-def
    ("private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),  # pattern-def
    ("bot token shape", re.compile(r"\b[0-9]{8,10}:[A-Za-z0-9_-]{35}\b")),  # pattern-def
]
ALLOW = re.compile(r"\b(?:SHA-(?:1|224|256|384|512)|UTF-(?:8|16|32)|ISO-[0-9]{3,5}|TLS-1|x86-64)\b", re.IGNORECASE)  # pattern-def


def files(root):
    out = subprocess.run(
        ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=True, capture_output=True,
    ).stdout
    return [f for f in out.decode().split("\0") if f]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    findings = []
    for rel in files(root):
        try:
            with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError as err:
            findings.append(f"{rel}: unreadable ({err})")
            continue
        for n, line in enumerate(lines, 1):
            if MARKER in line and rel == "tools/denylist-check.py":
                continue
            checked = ALLOW.sub("", line)
            for label, rx in PATTERNS:
                if rx.search(checked):
                    findings.append(f"{rel}:{n}: {label}")
    for f in findings:
        print(f"denylist: {f}")
    print(f"denylist: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
