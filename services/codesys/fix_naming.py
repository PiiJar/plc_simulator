#!/usr/bin/env python3
"""
fix_naming.py — Apply PLC Guide naming fixes to all ST files in services/codesys.

Strategy:
  1. Collect all violations from all files (via same parser as check_naming.py).
  2. Build two rename maps:
       - interface_map : {old → new}  for VAR_INPUT / VAR_OUTPUT / VAR_IN_OUT
         Applied globally across all files (parameter names appear at call sites).
       - file_local_maps : {filepath → {old → new}}  for VAR (local variables)
         Applied only within the declaring file.
  3. Conflict detection: if the same old name maps to two different new names
     in the interface map, skip and report — requires manual intervention.
  4. Apply renames using \\b word-boundary regex so partial matches are safe.

Special case:
  - FC_DEP_FitTaskToSlot.st: oResult (VAR_IN_OUT) → ioResult
    This is handled as a normal VAR_IN_OUT rename.

Usage:
  cd /home/jarmo-piipponen/plc_simulator
  python3 services/codesys/fix_naming.py [--dry-run]
"""

import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
ST_DIRS = [
    SCRIPT_DIR / 'GVLs',
    SCRIPT_DIR / 'UDTs',
    SCRIPT_DIR / 'POUs',
]

LOOP_COUNTERS = frozenset({'i', 'j', 'k', 'l'})

ST_KEYWORDS = frozenset({
    'ARRAY', 'OF', 'STRUCT', 'END_STRUCT', 'END_VAR', 'CONSTANT',
    'RETAIN', 'PERSISTENT', 'AT', 'BOOL', 'INT', 'DINT', 'LINT',
    'UINT', 'UDINT', 'ULINT', 'SINT', 'USINT', 'REAL', 'LREAL',
    'BYTE', 'WORD', 'DWORD', 'LWORD', 'TIME', 'DATE', 'TOD', 'DT',
    'STRING', 'WSTRING', 'TYPE', 'END_TYPE',
})

INTERFACE_SECTIONS = frozenset({
    'VAR_INPUT', 'VAR_OUTPUT', 'VAR_IN_OUT', 'STRUCT_FIELD',
})


# ── Comment stripping ─────────────────────────────────────────────────────────

def strip_comments(text: str) -> str:
    text = re.sub(r'\(\*.*?\*\)', '', text, flags=re.DOTALL)
    text = re.sub(r'//[^\n]*', '', text)
    return text


# ── Name conversion (shared with check_naming.py) ────────────────────────────

def to_pascal_case(snake: str) -> str:
    parts = snake.split('_')
    return ''.join(p[0].upper() + p[1:] for p in parts if p)


def expected_name(name: str, section: str) -> str:
    s = section.upper().replace(' ', '_')

    if s == 'VAR':
        if name in LOOP_COUNTERS:
            return name
        if re.match(r'^v[A-Z]|^vFB_|^c[A-Z]', name):
            return name
        if name.lower().startswith('fb_'):
            rest = name[3:]
            pascal = to_pascal_case(rest) if '_' in rest else rest[0].upper() + rest[1:]
            return 'vFB_' + pascal
        if re.match(r'^[A-Z][A-Z0-9_]*$', name):
            if '_' in name:
                words = name.lower().split('_')
            else:
                words = [name.lower()]
            return 'c' + ''.join(w[0].upper() + w[1:] for w in words if w)
        if re.match(r'^[io][A-Z]', name):
            return 'v' + name[0].upper() + name[1:]
        if '_' in name:
            return 'v' + to_pascal_case(name)
        return 'v' + name[0].upper() + name[1:]

    elif s == 'VAR_INPUT':
        if re.match(r'^i[A-Z]', name):
            return name
        clean = re.sub(r'^i_', '', name)
        if '_' in clean:
            return 'i' + to_pascal_case(clean)
        return 'i' + clean[0].upper() + clean[1:]

    elif s == 'VAR_OUTPUT':
        if re.match(r'^o[A-Z]', name):
            return name
        clean = re.sub(r'^o_', '', name)
        if '_' in clean:
            return 'o' + to_pascal_case(clean)
        return 'o' + clean[0].upper() + clean[1:]

    elif s == 'VAR_IN_OUT':
        if re.match(r'^io[A-Z]', name):
            return name
        clean = name
        clean = re.sub(r'^io_', '', clean)
        if re.match(r'^o[A-Z]', clean):
            clean = clean[1:]
        elif re.match(r'^i[A-Z]', clean):
            clean = clean[1:]
        elif re.match(r'^o_', clean):
            clean = re.sub(r'^o_', '', clean)
        elif re.match(r'^i_', clean):
            clean = re.sub(r'^i_', '', clean)
        if not clean:
            return 'io' + name
        if '_' in clean:
            return 'io' + to_pascal_case(clean)
        return 'io' + clean[0].upper() + clean[1:]

    elif s in ('VAR_GLOBAL_CONSTANT', 'VAR_EXTERNAL_CONSTANT'):
        if re.match(r'^[A-Z][A-Z0-9_]*$', name):
            return name
        return name

    elif s == 'VAR_GLOBAL':
        if re.match(r'^g_', name) or re.match(r'^[A-Z]', name):
            return name
        if '_' in name:
            return 'g_' + name
        return name[0].upper() + name[1:]

    elif s == 'VAR_EXTERNAL':
        if (re.match(r'^g_', name) or
                re.match(r'^[A-Z][a-z]', name) or
                re.match(r'^[A-Z][A-Z0-9_]*$', name)):
            return name
        return name

    elif s == 'STRUCT_FIELD':
        if re.match(r'^[A-Z]', name):
            return name
        if '_' in name:
            return to_pascal_case(name)
        return name[0].upper() + name[1:]

    return name


# ── Parser ────────────────────────────────────────────────────────────────────

VAR_SECTION_RE = re.compile(
    r'\b(VAR_INPUT|VAR_OUTPUT|VAR_IN_OUT'
    r'|VAR_EXTERNAL\s+CONSTANT|VAR_EXTERNAL'
    r'|VAR_GLOBAL\s+CONSTANT|VAR_GLOBAL'
    r'|VAR)\b'
    r'(.*?)END_VAR',
    re.DOTALL | re.IGNORECASE,
)

STRUCT_RE = re.compile(r'STRUCT\b(.*?)END_STRUCT', re.DOTALL | re.IGNORECASE)
VAR_DECL_RE = re.compile(r'^\s*(\w+)\s*:', re.MULTILINE)


def _parse_var_decls(body: str) -> list[str]:
    names = []
    for m in VAR_DECL_RE.finditer(body):
        n = m.group(1)
        if n.upper() not in ST_KEYWORDS:
            names.append(n)
    return names


def collect_violations(path: Path) -> list[tuple[str, str, str]]:
    """Return [(old_name, section, new_name)] for all violations in path."""
    text = path.read_text(encoding='utf-8')
    clean = strip_comments(text)
    violations = []

    for sm in STRUCT_RE.finditer(clean):
        for name in _parse_var_decls(sm.group(1)):
            exp = expected_name(name, 'STRUCT_FIELD')
            if exp != name:
                violations.append((name, 'STRUCT_FIELD', exp))

    for vm in VAR_SECTION_RE.finditer(clean):
        raw_sec = re.sub(r'\s+', '_', vm.group(1).strip().upper())
        body = vm.group(2)
        for name in _parse_var_decls(body):
            exp = expected_name(name, raw_sec)
            if exp != name:
                violations.append((name, raw_sec, exp))

    return violations


# ── Rename application ────────────────────────────────────────────────────────

def apply_renames_free(text: str, rename_map: dict[str, str]) -> str:
    """Replace all occurrences using plain word-boundary regex (longest first)."""
    for old, new in sorted(rename_map.items(), key=lambda x: -len(x[0])):
        text = re.sub(r'\b' + re.escape(old) + r'\b', new, text)
    return text


def apply_renames_call_site(text: str, rename_map: dict[str, str]) -> str:
    """
    Replace parameter names only at FB/FC call sites.

    Matches  name :=  or  name =>  that is NOT preceded by '.' so that
    struct-field accesses like  config.ZPosUp  are left untouched, while
    named-parameter usage like  fbZMotion(ZPosUp := ...)  is correctly renamed.
    """
    for old, new in sorted(rename_map.items(), key=lambda x: -len(x[0])):
        text = re.sub(
            r'(?<!\.)' + r'\b' + re.escape(old) + r'\b' + r'(?=\s*(?::=|=>))',
            new,
            text,
        )
    return text


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    dry_run = '--dry-run' in sys.argv

    all_files = []
    for d in ST_DIRS:
        all_files.extend(sorted(d.rglob('*.st')))

    # ── Step 1: collect all violations ────────────────────────────────────────
    #
    # Three rename categories:
    #   struct_renames  — STRUCT_FIELD violations; applied globally with free regex
    #                     (e.g. ts0 → Ts0 everywhere)
    #   param_by_file   — VAR_INPUT/OUTPUT/IN_OUT violations; keyed by declaring file.
    #                     In the declaring file: free regex.
    #                     In other files: call-site regex (name := or name =>) with
    #                     negative lookbehind for '.' to avoid renaming struct-field
    #                     accesses that share the same name as the parameter.
    #   local_renames   — VAR / VAR_GLOBAL / VAR_EXTERNAL variants; per-file only.

    struct_renames: dict[str, str] = {}
    param_by_file: dict[Path, dict[str, str]] = {}
    local_renames: dict[Path, dict[str, str]] = {}
    conflicts: list[str] = []

    for path in all_files:
        violations = collect_violations(path)
        for old, section, new in violations:
            sec = section.upper().replace(' ', '_')

            if sec in ('VAR', 'VAR_GLOBAL', 'VAR_GLOBAL_CONSTANT',
                       'VAR_EXTERNAL', 'VAR_EXTERNAL_CONSTANT'):
                local_renames.setdefault(path, {})[old] = new

            elif sec == 'STRUCT_FIELD':
                if old in struct_renames and struct_renames[old] != new:
                    conflicts.append(
                        f'STRUCT CONFLICT: {old!r} → {struct_renames[old]!r} '
                        f'vs {new!r} — skipping'
                    )
                else:
                    struct_renames[old] = new

            else:  # VAR_INPUT, VAR_OUTPUT, VAR_IN_OUT
                param_by_file.setdefault(path, {})[old] = new

    # Build a flat "all params" map for call-site application in non-declaring files,
    # checking for cross-file name conflicts.
    all_params_call_site: dict[str, str] = {}
    for path, params in param_by_file.items():
        for old, new in params.items():
            if old in all_params_call_site and all_params_call_site[old] != new:
                conflicts.append(
                    f'PARAM CONFLICT: {old!r} → {all_params_call_site[old]!r} '
                    f'vs {new!r} — skipping, manual fix required'
                )
            else:
                all_params_call_site[old] = new

    if conflicts:
        print('\n'.join(conflicts))
        print()

    # ── Step 2: apply renames ─────────────────────────────────────────────────
    total_files_changed = 0

    for path in all_files:
        original = path.read_text(encoding='utf-8')
        modified = original

        # 1. Struct-field renames: free regex, global
        if struct_renames:
            modified = apply_renames_free(modified, struct_renames)

        # 2. Local renames for this file: free regex, this file only
        file_local = local_renames.get(path, {})
        if file_local:
            modified = apply_renames_free(modified, file_local)

        # 3. Parameter renames declared in THIS file: free regex
        #    (renames the declaration + all body-level usages inside the FB/FC)
        file_params = param_by_file.get(path, {})
        if file_params:
            modified = apply_renames_free(modified, file_params)

        # 4. Parameter renames declared in OTHER files: call-site regex
        #    (renames  name :=  /  name =>  but NOT  struct.name  accesses)
        other_params = {
            old: new
            for old, new in all_params_call_site.items()
            if old not in file_params
        }
        if other_params:
            modified = apply_renames_call_site(modified, other_params)

        if modified != original:
            total_files_changed += 1
            rel = path.relative_to(SCRIPT_DIR)
            if dry_run:
                print(f'[DRY RUN] would update: {rel}')
            else:
                path.write_text(modified, encoding='utf-8')
                print(f'updated: {rel}')

    print()
    if dry_run:
        print(f'Dry run complete — {total_files_changed} files would be changed.')
    else:
        print(f'Done — {total_files_changed} files updated.')

    return 0


if __name__ == '__main__':
    sys.exit(main())
