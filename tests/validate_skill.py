#!/usr/bin/env python3
"""Validate SKILL.md frontmatter and size against the Agent Skills rules. Stdlib only.

Exit 0 if valid, 1 with a list of problems otherwise.
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SKILL_DIR = os.path.join(ROOT, "skills", "obs-settings-advisor")
SKILL_MD = os.path.join(SKILL_DIR, "SKILL.md")
MAX_BODY_LINES = 500


def main():
    errors = []
    with open(SKILL_MD, encoding="utf-8") as fh:
        text = fh.read()
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
    if not m:
        print("SKILL.md: missing YAML frontmatter delimited by --- lines")
        return 1
    front, body = m.group(1), m.group(2)

    fields = {}
    for line in front.splitlines():
        km = re.match(r"^([A-Za-z_-]+):\s?(.*)$", line)
        if km:
            fields[km.group(1)] = km.group(2).strip()
        elif line.strip():
            errors.append(f"unexpected frontmatter line (multi-line values not supported here): {line[:60]}")

    name = fields.get("name", "")
    desc = fields.get("description", "")
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name) or len(name) > 64:
        errors.append(f"name must be lowercase letters, digits and single hyphens, max 64 chars: {name!r}")
    if name != os.path.basename(SKILL_DIR):
        errors.append(f"name {name!r} must match the directory name {os.path.basename(SKILL_DIR)!r}")
    if re.search(r"anthropic|claude", name):
        errors.append("name must not contain reserved words 'anthropic' or 'claude'")
    if not desc:
        errors.append("description is missing")
    if len(desc) > 1024:
        errors.append(f"description is {len(desc)} chars, max 1024")
    if re.search(r"<[^>]+>", desc):
        errors.append("description must not contain XML tags")
    if re.search(r":\s", desc) or re.search(r"\s#", desc) or desc[:1] in "\"'&*!|>%@`[{":
        errors.append("description contains YAML-special characters; quote it")
    extra = set(fields) - {"name", "description", "license", "allowed-tools", "metadata", "compatibility"}
    if extra:
        errors.append(f"unknown frontmatter keys: {sorted(extra)}")

    try:  # use a real YAML parser when one happens to be installed
        import yaml  # type: ignore
        parsed = yaml.safe_load(front)
        if parsed.get("name") != name or parsed.get("description") != desc:
            errors.append("YAML parser reads different values than expected; quote the description")
    except ImportError:
        pass

    body_lines = body.count("\n") + 1
    if body_lines >= MAX_BODY_LINES:
        errors.append(f"SKILL.md body has {body_lines} lines, keep it under {MAX_BODY_LINES}")

    for ref in re.findall(r"`((?:references|scripts)/[\w./-]+)`", body):
        if not os.path.exists(os.path.join(SKILL_DIR, ref)):
            errors.append(f"SKILL.md references a missing file: {ref}")

    if errors:
        print("SKILL.md validation failed:")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"SKILL.md OK: name={name}, description={len(desc)} chars, body={body_lines} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
