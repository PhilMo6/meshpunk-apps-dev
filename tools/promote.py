"""promote.py - copy finished catalog entries from meshpunk-apps-dev (this
repo) into the stable meshpunk-apps clone.

    python tools/promote.py status
        Every entry whose version or files differ between the two catalogs,
        and whether it can be promoted.
    python tools/promote.py <entry> [<entry> ...]
        What promoting those entries would change (nothing is written).
    python tools/promote.py <entry> [<entry> ...] --apply
        Promote them, then show the stable clone's git status.
    python tools/promote.py --all [--apply]
        The same for every entry `status` lists as ready.

An <entry> is `kind/id` (apps/Dos, protocols/meshcore, themes/meshcore,
drivers/gamepad) or a bare id when only one kind has it.

Promoting an entry makes the stable copy of it equal to this repo's: its
folder (<kind>/<id>/, mirrored: files the dev folder lacks are deleted), the
module source folder of each ELF module it ships (module-src/<module>/, the
name before the first dot of the .elf), and its catalog.toml block (replaced,
or inserted next to the entry before or after it in this repo's order); the
[meta] updated date becomes today. The stable clone is only changed; commit
and push it yourself after reading its diff.

An entry is refused when:
  - its stable version is newer than this repo's (apps-dev is never behind);
  - its min_fw is above the stable firmware's MESHPUNK_FW_API
    (src/version.h of the stable firmware tree);
  - a file its catalog block lists is missing from its folder here;
  - it exists only in the stable catalog (remove it there by hand).

Options:
  --stable PATH  the stable clone (default: meshpunk-apps beside this repo)
  --fw PATH      the stable firmware tree (default: meshpunk beside this repo)
"""

import argparse
import datetime
import filecmp
import os
import re
import shutil
import subprocess
import sys
import tomllib

KINDS = ("apps", "themes", "drivers", "protocols")
HEADER_RE = re.compile(r"^\[\[(apps|themes|drivers|protocols)\]\]\s*$")
ID_RE = re.compile(r'^id\s*=\s*"([^"]*)"')
UPDATED_RE = re.compile(r'^(updated\s*=\s*)"[^"]*"')

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ── Catalog text ─────────────────────────────────────────────────────────────

class Catalog:
    """catalog.toml as data (tomllib) and as lines, with each entry's block."""

    def __init__(self, repo):
        self.repo = repo
        self.path = os.path.join(repo, "catalog.toml")
        with open(self.path, "rb") as f:
            raw = f.read()
        self.data = tomllib.loads(raw.decode("utf-8"))
        self.eol = "\r\n" if b"\r\n" in raw else "\n"
        self.lines = raw.decode("utf-8").splitlines(keepends=True)
        self.entries = {}   # (kind, id) -> entry table
        self.order = {k: [] for k in KINDS}
        for kind in KINDS:
            for e in self.data.get(kind, []):
                self.entries[(kind, e["id"])] = e
                self.order[kind].append(e["id"])

    def blocks(self):
        """(kind, id, first, last) for every entry: lines[first:last] hold
        the header through the last key line (trailing blank and comment
        lines belong to the gap before the next header)."""
        out = []
        starts = [i for i, ln in enumerate(self.lines)
                  if ln.lstrip().startswith("[")]
        for n, i in enumerate(starts):
            m = HEADER_RE.match(self.lines[i].strip())
            if not m:
                continue
            end = starts[n + 1] if n + 1 < len(starts) else len(self.lines)
            while end > i + 1 and (not self.lines[end - 1].strip()
                                   or self.lines[end - 1].lstrip().startswith("#")):
                end -= 1
            eid = None
            for ln in self.lines[i:end]:
                mm = ID_RE.match(ln.strip())
                if mm:
                    eid = mm.group(1)
                    break
            out.append((m.group(1), eid, i, end))
        return out

    def block(self, kind, eid):
        for k, i, first, last in self.blocks():
            if k == kind and i == eid:
                return first, last
        return None

    def block_text(self, kind, eid):
        where = self.block(kind, eid)
        if not where:
            sys.exit(f"{self.path}: no [[{kind}]] block with id = \"{eid}\"")
        first, last = where
        return [ln.rstrip("\r\n") for ln in self.lines[first:last]]

    def save(self):
        text = "".join(self.lines)
        tomllib.loads(text)   # the edited catalog still parses, or nothing is written
        with open(self.path, "w", encoding="utf-8", newline="") as f:
            f.write(text)


def version_key(v):
    nums = re.findall(r"\d+", str(v))
    return tuple(int(n) for n in nums) if nums else None


def newer(a, b):
    """True when version a is strictly newer than version b."""
    ka, kb = version_key(a), version_key(b)
    if ka is None or kb is None:
        return str(a) != str(b)
    width = max(len(ka), len(kb))
    return ka + (0,) * (width - len(ka)) > kb + (0,) * (width - len(kb))


# ── Entry contents ───────────────────────────────────────────────────────────

def listed_files(entry):
    out = list(entry.get("files", []))
    for key, val in entry.items():
        if key.startswith("files_") and isinstance(val, list):
            out.extend(val)
    return out


def entry_dirs(repo, kind, entry):
    """The folders an entry owns in `repo`, relative to it."""
    dirs = [f"{kind}/{entry['id']}"]
    for f in listed_files(entry):
        base = os.path.basename(f)
        if base.endswith(".elf"):
            mod = base.split(".", 1)[0]
            rel = f"module-src/{mod}"
            if rel not in dirs and os.path.isdir(os.path.join(repo, rel)):
                dirs.append(rel)
    return dirs


def same_file(a, b):
    """Equal content; text files compared with CRLF taken as LF (the clones
    run core.autocrlf, so a checkout and a tool-written copy differ only in
    line ends)."""
    if os.path.getsize(a) == os.path.getsize(b) and filecmp.cmp(a, b, shallow=False):
        return True
    with open(a, "rb") as fa, open(b, "rb") as fb:
        da, db = fa.read(), fb.read()
    if b"\0" in da[:8192] or b"\0" in db[:8192]:
        return False
    return da.replace(b"\r\n", b"\n") == db.replace(b"\r\n", b"\n")


def tree_files(root):
    out = set()
    if not os.path.isdir(root):
        return out
    for d, _, files in os.walk(root):
        for f in files:
            out.add(os.path.relpath(os.path.join(d, f), root).replace("\\", "/"))
    return out


def dir_changes(src, dst):
    """(changed, new, removed) relative paths that make dst equal to src."""
    s, d = tree_files(src), tree_files(dst)
    new = sorted(s - d)
    removed = sorted(d - s)
    changed = sorted(p for p in s & d
                     if not same_file(os.path.join(src, p), os.path.join(dst, p)))
    return changed, new, removed


def mirror(src, dst, changed, new, removed):
    for p in changed + new:
        target = os.path.join(dst, p)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(os.path.join(src, p), target)
    for p in removed:
        os.remove(os.path.join(dst, p))
    for d, _, _ in os.walk(dst, topdown=False):   # bottom-up: children first
        if not os.listdir(d):
            os.rmdir(d)


# ── Checks ───────────────────────────────────────────────────────────────────

def stable_fw_api(fw):
    path = os.path.join(fw, "src", "version.h")
    with open(path, encoding="utf-8", errors="replace") as f:
        m = re.search(r"#define\s+MESHPUNK_FW_API\s+(\d+)", f.read())
    if not m:
        sys.exit(f"no MESHPUNK_FW_API in {path}")
    return int(m.group(1))


def refusal(dev, stable, fw_api, kind, eid):
    """Why (kind, eid) cannot be promoted, or None."""
    de = dev.entries.get((kind, eid))
    se = stable.entries.get((kind, eid))
    if de is None:
        return "only in the stable catalog (remove it there by hand)"
    if se is not None and newer(se["version"], de["version"]):
        return f"stable {se['version']} is newer than dev {de['version']}"
    need = de.get("min_fw")
    if need is not None and int(need) > fw_api:
        return f"min_fw {need} is above the stable firmware's API level {fw_api}"
    missing = [f for f in listed_files(de)
               if not os.path.isfile(os.path.join(dev.repo, kind, eid, f))]
    if missing:
        return f"listed but missing here: {', '.join(missing)}"
    return None


def changes_for(dev, stable, kind, eid):
    """[(rel_dir, changed, new, removed)] for the entry's folders."""
    out = []
    for rel in entry_dirs(dev.repo, kind, dev.entries[(kind, eid)]):
        c, n, r = dir_changes(os.path.join(dev.repo, rel), os.path.join(stable.repo, rel))
        out.append((rel, c, n, r))
    return out


def catalog_differs(dev, stable, kind, eid):
    if (kind, eid) not in stable.entries:
        return True
    return dev.block_text(kind, eid) != stable.block_text(kind, eid)


# ── Promotion ────────────────────────────────────────────────────────────────

def place_block(dev, stable, kind, eid):
    """Replace or insert the entry's block in stable.lines; returns what
    happened, for the report."""
    eol = stable.eol
    new_lines = [ln + eol for ln in dev.block_text(kind, eid)]
    where = stable.block(kind, eid)
    if where:
        first, last = where
        stable.lines[first:last] = new_lines
        return "replaced"
    order = dev.order[kind]
    i = order.index(eid)
    for prev in reversed(order[:i]):
        loc = stable.block(kind, prev)
        if loc:
            stable.lines[loc[1]:loc[1]] = [eol] + new_lines
            return f"inserted after {prev}"
    for nxt in order[i + 1:]:
        loc = stable.block(kind, nxt)
        if loc:
            stable.lines[loc[0]:loc[0]] = new_lines + [eol]
            return f"inserted before {nxt}"
    if stable.lines and not stable.lines[-1].endswith("\n"):
        stable.lines[-1] += eol
    stable.lines.extend([eol] + new_lines)
    return "appended"


def stamp_updated(stable):
    today = datetime.date.today().isoformat()
    in_meta = False
    for n, ln in enumerate(stable.lines):
        s = ln.strip()
        if s.startswith("["):
            in_meta = (s == "[meta]")
            continue
        if in_meta and UPDATED_RE.match(s):
            eol = ln[len(ln.rstrip("\r\n")):]
            stable.lines[n] = UPDATED_RE.sub(lambda m: m.group(1) + f'"{today}"', s) + eol
            return


def resolve_name(dev, stable, name):
    if "/" in name:
        kind, eid = name.split("/", 1)
        if kind not in KINDS:
            sys.exit(f"{name}: kind must be one of {', '.join(KINDS)}")
        return kind, eid
    kinds = [k for k in KINDS if (k, name) in dev.entries or (k, name) in stable.entries]
    if not kinds:
        sys.exit(f"{name}: in neither catalog")
    if len(kinds) > 1:
        sys.exit(f"{name}: in {' and '.join(kinds)}; write it as kind/{name}")
    return kinds[0], name


def all_keys(dev, stable):
    keys = list(dev.entries)
    keys += [k for k in stable.entries if k not in dev.entries]
    return keys


def ready_keys(dev, stable, fw_api):
    out = []
    for kind, eid in all_keys(dev, stable):
        if refusal(dev, stable, fw_api, kind, eid):
            continue
        if needs_promotion(dev, stable, kind, eid):
            out.append((kind, eid))
    return out


def needs_promotion(dev, stable, kind, eid):
    if catalog_differs(dev, stable, kind, eid):
        return True
    return any(c or n or r for _, c, n, r in changes_for(dev, stable, kind, eid))


def cmd_status(dev, stable, fw_api):
    print(f"dev:    {dev.repo}\nstable: {stable.repo}  (stable firmware API level {fw_api})\n")
    rows, same = [], 0
    for kind, eid in all_keys(dev, stable):
        de = dev.entries.get((kind, eid))
        se = stable.entries.get((kind, eid))
        dv = de["version"] if de else "-"
        sv = se["version"] if se else "-"
        mf = str(de.get("min_fw", "")) if de else ""
        why = refusal(dev, stable, fw_api, kind, eid)
        if why:
            state = why
        elif not needs_promotion(dev, stable, kind, eid):
            same += 1
            continue
        elif se is not None and dv == sv:
            changed = {rel for rel, c, n, r in changes_for(dev, stable, kind, eid) if c or n or r}
            if f"{kind}/{eid}" in changed:
                state = "ready; same version but its files differ (bump the version)"
            elif catalog_differs(dev, stable, kind, eid):
                state = "ready; same version, its catalog block differs"
            else:
                state = "ready; only its module-src mirror differs (devices see no change)"
        else:
            state = "ready"
        rows.append((f"{kind}/{eid}", dv, sv, mf, state))
    if rows:
        w = max(len(r[0]) for r in rows)
        print(f"{'entry':<{w}}  {'dev':<9} {'stable':<9} {'min_fw':<6}  state")
        for name, dv, sv, mf, state in rows:
            print(f"{name:<{w}}  {dv:<9} {sv:<9} {mf:<6}  {state}")
    print(f"\n{len(rows)} differ, {same} identical")


def cmd_promote(dev, stable, fw_api, keys, apply):
    todo = []
    for kind, eid in keys:
        why = refusal(dev, stable, fw_api, kind, eid)
        de, se = dev.entries.get((kind, eid)), stable.entries.get((kind, eid))
        label = f"{kind}/{eid}"
        if why:
            print(f"{label}: refused - {why}")
            continue
        changes = changes_for(dev, stable, kind, eid)
        cat = catalog_differs(dev, stable, kind, eid)
        if not cat and not any(c or n or r for _, c, n, r in changes):
            print(f"{label}: already identical")
            continue
        sv = se["version"] if se else "new"
        mf = de.get("min_fw")
        print(f"{label}  {sv} -> {de['version']}"
              + (f"  (min_fw {mf}, stable API {fw_api})" if mf is not None else ""))
        for rel, c, n, r in changes:
            if c or n or r:
                print(f"  {rel + '/':<28} {len(c)} changed, {len(n)} new, {len(r)} removed")
                for p in c:
                    print(f"      ~ {p}")
                for p in n:
                    print(f"      + {p}")
                for p in r:
                    print(f"      - {p}")
        if cat:
            print(f"  catalog.toml                 "
                  + ("replace its block" if se else "insert its block"))
        todo.append((kind, eid, changes, cat))
    if not todo:
        return
    if not apply:
        print("\ndry run: nothing written (add --apply)")
        return
    for kind, eid, changes, cat in todo:
        for rel, c, n, r in changes:
            mirror(os.path.join(dev.repo, rel), os.path.join(stable.repo, rel), c, n, r)
        if cat:
            how = place_block(dev, stable, kind, eid)
            print(f"{kind}/{eid}: catalog block {how}")
    stamp_updated(stable)
    stable.save()
    print("\nstable clone, git status:", flush=True)
    subprocess.run(["git", "-C", stable.repo, "status", "--short"], check=False)
    subprocess.run(["git", "-C", stable.repo, "diff", "--stat"], check=False)


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description="Promote catalog entries from apps-dev to stable.",
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__)
    ap.add_argument("entries", nargs="*", help="status, or kind/id entries to promote")
    ap.add_argument("--all", action="store_true", help="every entry status lists as ready")
    ap.add_argument("--apply", action="store_true", help="write the changes (default: dry run)")
    ap.add_argument("--stable", default=os.path.join(os.path.dirname(HERE), "meshpunk-apps"))
    ap.add_argument("--fw", default=os.path.join(os.path.dirname(HERE), "meshpunk"))
    args = ap.parse_args()

    stable_repo = os.path.abspath(args.stable)
    if not os.path.isfile(os.path.join(stable_repo, "catalog.toml")):
        sys.exit(f"no catalog.toml in {stable_repo} (--stable names the stable clone)")
    if os.path.samefile(stable_repo, HERE):
        sys.exit("--stable points at this repo")
    dev, stable = Catalog(HERE), Catalog(stable_repo)
    fw_api = stable_fw_api(os.path.abspath(args.fw))

    if args.entries == ["status"] and not args.all:
        cmd_status(dev, stable, fw_api)
        return
    if args.all:
        if args.entries:
            sys.exit("--all takes no entries")
        keys = ready_keys(dev, stable, fw_api)
        if not keys:
            print("nothing is ready to promote")
            return
    else:
        if not args.entries:
            ap.print_help()
            return
        keys = [resolve_name(dev, stable, n) for n in args.entries]
    cmd_promote(dev, stable, fw_api, keys, args.apply)


if __name__ == "__main__":
    main()
