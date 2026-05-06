#!/usr/bin/env python3
"""Compute GHC -package flags for haskell_ghci_global with automatic thinning.

Reads .conf files from materialized package db paths to determine which modules
each package exposes (including re-exports), then emits -package flags with GHC
thinning syntax to resolve module conflicts.

Conflict resolution has two layers:

  1. Auto-detection from the Buck2 target graph: for each conflicting module,
     look at every library's direct toolchain deps. If every library that has
     access to the module sees only one of the conflicting packages in its
     direct deps, that package is the canonical owner and the others are
     thinned to hide the conflicting module. This mirrors what Cabal's
     per-component build-depends scoping does implicitly.

  2. Manual --thin-pairs overrides: applied only when auto-detection can't
     decide (e.g. two independent packages with no dep edge between them,
     like base64 and base64-bytestring).

Usage:
  compute_exposed_packages.py
    --pkgdbs-forced=<dir>          symlinked dir mapping pkg name -> nix output
    --exposed-packages=<json>      JSON array of package names to expose
    --library-toolchain-deps=<json> JSON array of [tc_dep_name, ...] lists, one
                                    per first-party library
    --thin-pairs=<json>            JSON array of [thin_pkg, preferred_pkg] pairs
                                    used only when auto-detection can't decide
    --output=<path>                output file for -package flags (one per line)
"""

import argparse
import glob
import json
import os
import sys
import re


def get_exposed_modules(conf_path):
    """Parse a .conf file's exposed-modules field into (visible, owned) sets.

    The field has entries in two forms:
      - `Mod` — owned module: this package defines it
      - `Mod from pkgid:OrigName` — re-export: just forwards to pkgid's OrigName

    GHC treats re-exports as pointing at the same module identity as the
    original, so a re-export and the original don't actually conflict at
    `import` time. Returning the two sets separately lets the caller treat
    re-export pairs as non-conflicts (the owner wins automatically).

    Returns:
      visible: set of all module names this package exposes (owned + re-exports)
      owned:   set of modules this package actually defines (no re-exports)
    """
    visible = set()
    owned = set()
    with open(conf_path) as f:
        lines = f.readlines()

    # Collect the full exposed-modules field as one string (continuation lines
    # are indented), then split on commas and parse each entry.
    field_chunks = []
    in_field = False
    for line in lines:
        if line.startswith("exposed-modules:"):
            in_field = True
            field_chunks.append(line[len("exposed-modules:"):])
        elif in_field and line[:1] in (" ", "\t"):
            field_chunks.append(line)
        else:
            in_field = False

    field = " ".join(c.strip() for c in field_chunks).strip()
    if not field:
        return visible, owned

    # Tokenize on whitespace + commas. Cabal accepts either as separator
    # between entries (base64's conf uses pure whitespace; aeson and most
    # others use commas).
    tokens = [t for t in re.split(r"[\s,]+", field) if t]

    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if not tok[:1].isupper():
            i += 1
            continue
        visible.add(tok)
        # A re-export entry is `Mod from <pkgid>:<OrigName>`, with the pkgid
        # token containing a colon. If the next two tokens match that shape,
        # this is a re-export and the current package does NOT own the module.
        if (i + 2 < len(tokens)
                and tokens[i + 1] == "from"
                and ":" in tokens[i + 2]):
            i += 3
        else:
            owned.add(tok)
            i += 1

    return visible, owned


_CONF_NAME_RE = re.compile(r"^(?P<name>.+?)-\d[\d.]*-[A-Za-z0-9]+\.conf$")


def _basename_matches_pkg(path, pkg_name):
    """Confirm a .conf path's basename is for `pkg_name` (i.e. <pkg_name>-<version>.conf).

    Avoids picking up sibling-package .confs (e.g. transitively-registered deps
    bundled in the same package.conf.d) that happen to live under <pkg_name>/.
    """
    base = os.path.basename(path)
    m = _CONF_NAME_RE.match(base)
    return m is not None and m.group("name") == pkg_name


def find_conf(pkgdbs_forced, pkg_name):
    """Find the .conf file for `pkg_name` in the forced pkgdbs directory.

    Returns None if no match is found; caller is expected to warn.
    """
    pattern = os.path.join(pkgdbs_forced, pkg_name, "**", "*.conf")
    matches = [
        m for m in glob.glob(pattern, recursive=True)
        if "package.conf.d" in m and _basename_matches_pkg(m, pkg_name)
    ]
    if matches:
        return matches[0]
    # Fallback: search all subdirs for a conf matching the package name prefix
    pattern2 = os.path.join(pkgdbs_forced, "**", "package.conf.d", pkg_name + "-*.conf")
    matches2 = [
        m for m in glob.glob(pattern2, recursive=True)
        if _basename_matches_pkg(m, pkg_name)
    ]
    return matches2[0] if matches2 else None


def resolve_module_owners(pkg_owned, top_level_toolchain_deps, thin_pairs):
    """For every exposed module, decide which package canonically owns it.

    Resolution proceeds in three steps:

      1. Build a map module -> set(packages that own it). Re-exports do NOT
         create ownership — by separating owned vs re-exported in the conf
         parser, re-export pairs (amazonka/amazonka-core, singletons/
         singletons-th, etc.) have exactly one owner each and resolve
         automatically.

      2. For modules with more than one owner (genuine conflicts — two
         independent implementations of the same name, like base64 vs
         base64-bytestring), prefer whichever owner is in the top-level
         target's direct toolchain deps. That matches how the regular
         buck2 build would resolve the import for sources in that target:
         per-component build-depends scoping picks the directly-declared
         package.

      3. If neither owner is in top-level deps (or both are), fall back to
         the manual --thin-pairs config. Otherwise the conflict is left
         unresolved and both owners stay exposed (GHC will error if a
         module is actually imported).

    Returns dict module_name -> winning_pkg.
    """
    module_owners = {}
    for pkg, mods in pkg_owned.items():
        for mod in mods:
            module_owners.setdefault(mod, set()).add(pkg)

    top_level_set = set(top_level_toolchain_deps)
    canonical = {}
    for mod, owners in module_owners.items():
        if len(owners) == 1:
            canonical[mod] = next(iter(owners))
            continue

        # Real conflict: prefer the owner in the top-level target's deps.
        in_top_level = owners & top_level_set
        if len(in_top_level) == 1:
            canonical[mod] = next(iter(in_top_level))
            continue

        # Last resort: consult manual thin_pairs. Each (thin, preferred) pair
        # says "if both are in owners, prefer `preferred`".
        for thin, preferred in thin_pairs.items():
            if thin in owners and preferred in owners:
                canonical[mod] = preferred
                break

    return canonical


def main():
    p = argparse.ArgumentParser(fromfile_prefix_chars="@")
    p.add_argument("--pkgdbs-forced", required=True)
    p.add_argument("--exposed-packages", required=True)
    p.add_argument("--top-level-toolchain-deps", default="[]",
                   help="JSON list of the top-level dep target's direct toolchain "
                        "deps, used as a tiebreaker for genuine conflicts.")
    p.add_argument("--thin-pairs", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()

    exposed = json.loads(args.exposed_packages)
    top_level_toolchain_deps = json.loads(args.top_level_toolchain_deps)
    thin_pairs = {thin: preferred for thin, preferred in json.loads(args.thin_pairs)}

    # Per package, parse the .conf into (visible, owned) sets. Re-exports are
    # in `visible` but not `owned`; their modules are credited only to the
    # original-defining package.
    pkg_visible = {}
    pkg_owned = {}
    for pkg in exposed:
        conf = find_conf(args.pkgdbs_forced, pkg)
        if conf:
            v, o = get_exposed_modules(conf)
        else:
            v, o = set(), set()
            print(
                "compute_exposed_packages: warning: could not locate .conf for "
                "{pkg} under {pkgdbs}; emitting plain -package."
                .format(pkg=pkg, pkgdbs=args.pkgdbs_forced),
                file=sys.stderr,
            )
        pkg_visible[pkg] = v
        pkg_owned[pkg] = o

    canonical = resolve_module_owners(pkg_owned, top_level_toolchain_deps, thin_pairs)

    lines = []
    for pkg in exposed:
        visible = pkg_visible[pkg]
        owned = pkg_owned[pkg]

        # If the .conf was missing, fall back to unthinned -package.
        if not visible and not owned:
            lines.append("-package")
            lines.append(pkg)
            continue

        # Keep:
        #   - owned modules where this package is the canonical owner
        #   - re-exports (visible - owned) for modules whose canonical owner
        #     isn't in `exposed` at all (rare; would leave the module
        #     unreachable otherwise). When the owner IS exposed, hide the
        #     re-export to keep one definitive source per module.
        keep = set()
        for mod in owned:
            if canonical.get(mod) == pkg:
                keep.add(mod)
        for mod in visible - owned:
            owner = canonical.get(mod)
            if owner is None or owner not in pkg_owned:
                keep.add(mod)

        if not keep:
            # Package contributes nothing visible; omit it entirely.
            continue
        if keep == visible:
            lines.append("-package")
            lines.append(pkg)
        else:
            pkg_spec = "{} ({})".format(pkg, ", ".join(sorted(keep)))
            lines.append("-package")
            lines.append('"{}"'.format(pkg_spec))

    with open(args.output, "w") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    main()
