#!/usr/bin/env python3
"""
check_naming.py — Audit all ST source files in services/codesys for PLC Guide naming compliance.

Covers:
  GVLs/    VAR_GLOBAL, VAR_GLOBAL CONSTANT
  UDTs/    STRUCT fields
  POUs/    FUNCTION / FUNCTION_BLOCK / PROGRAM — all VAR section types

Usage:
  cd /home/jarmo-piipponen/plc_simulator
  python3 services/codesys/check_naming.py [--summary]
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

# Keywords that appear after ':' and are not variable names
ST_KEYWORDS = frozenset({
    'ARRAY', 'OF', 'STRUCT', 'END_STRUCT', 'END_VAR', 'CONSTANT',
    'RETAIN', 'PERSISTENT', 'AT', 'BOOL', 'INT', 'DINT', 'LINT',
    'UINT', 'UDINT', 'ULINT', 'SINT', 'USINT', 'REAL', 'LREAL',
    'BYTE', 'WORD', 'DWORD', 'LWORD', 'TIME', 'DATE', 'TOD', 'DT',
    'STRING', 'WSTRING', 'TYPE', 'END_TYPE',
})


# ── Comment stripping ─────────────────────────────────────────────────────────

def strip_comments(text: str) -> str:
    """Remove (* … *) block comments and // line comments."""
    text = re.sub(r'\(\*.*?\*\)', '', text, flags=re.DOTALL)
    text = re.sub(r'//[^\n]*', '', text)
    return text


# ── Name conversion helpers ───────────────────────────────────────────────────

def to_pascal_case(snake: str) -> str:
    """Convert snake_case to PascalCase preserving number segments.

    Examples:
      current_x       → CurrentX
      x1_min          → X1Min
      from_dropping_x10 → FromDroppingX10
      delta_t         → DeltaT
    """
    parts = snake.split('_')
    return ''.join(p[0].upper() + p[1:] for p in parts if p)


def expected_name(name: str, section: str) -> str:
    """Return the PLC-Guide-compliant form of *name* in *section*.

    Returns *name* unchanged if already compliant.
    """
    s = section.upper().replace(' ', '_')

    # ── VAR (local) ──────────────────────────────────────────────
    if s == 'VAR':
        if name in LOOP_COUNTERS:
            return name
        # Already correct
        if re.match(r'^v[A-Z]|^vFB_|^c[A-Z]', name):
            return name
        # FB instance heuristic: starts with fb_ → vFB_Name
        if name.lower().startswith('fb_'):
            rest = name[3:]
            pascal = to_pascal_case(rest) if '_' in rest else rest[0].upper() + rest[1:]
            return 'vFB_' + pascal
        # ALL_CAPS local constant (HORIZON, DEFICIT_TOL, MAX_ITER …)
        if re.match(r'^[A-Z][A-Z0-9_]*$', name):
            if '_' in name:
                words = name.lower().split('_')
            else:
                words = [name.lower()]
            return 'c' + ''.join(w[0].upper() + w[1:] for w in words if w)
        # Wrong prefix in VAR (iXxx / oXxx) → vIXxx / vOXxx
        if re.match(r'^[io][A-Z]', name):
            return 'v' + name[0].upper() + name[1:]
        # snake_case → vPascalCase
        if '_' in name:
            return 'v' + to_pascal_case(name)
        # bare short name (ti, qi, deficit …)
        return 'v' + name[0].upper() + name[1:]

    # ── VAR_INPUT ─────────────────────────────────────────────────
    elif s == 'VAR_INPUT':
        if re.match(r'^i[A-Z]', name):
            return name
        clean = re.sub(r'^i_', '', name)      # strip leading i_
        if '_' in clean:
            return 'i' + to_pascal_case(clean)
        return 'i' + clean[0].upper() + clean[1:]

    # ── VAR_OUTPUT ────────────────────────────────────────────────
    elif s == 'VAR_OUTPUT':
        if re.match(r'^o[A-Z]', name):
            return name
        clean = re.sub(r'^o_', '', name)
        if '_' in clean:
            return 'o' + to_pascal_case(clean)
        return 'o' + clean[0].upper() + clean[1:]

    # ── VAR_IN_OUT ────────────────────────────────────────────────
    elif s == 'VAR_IN_OUT':
        if re.match(r'^io[A-Z]', name):
            return name
        # Strip any existing wrong prefix (o, i, io_)
        clean = name
        clean = re.sub(r'^io_', '', clean)
        if re.match(r'^o[A-Z]', clean):
            clean = clean[1:]            # strip 'o'
        elif re.match(r'^i[A-Z]', clean):
            clean = clean[1:]            # strip 'i'
        elif re.match(r'^o_', clean):
            clean = re.sub(r'^o_', '', clean)
        elif re.match(r'^i_', clean):
            clean = re.sub(r'^i_', '', clean)
        if not clean:
            return 'io' + name
        if '_' in clean:
            return 'io' + to_pascal_case(clean)
        return 'io' + clean[0].upper() + clean[1:]

    # ── VAR_GLOBAL CONSTANT / VAR_EXTERNAL CONSTANT ──────────────
    elif s in ('VAR_GLOBAL_CONSTANT', 'VAR_EXTERNAL_CONSTANT'):
        if re.match(r'^[A-Z][A-Z0-9_]*$', name):
            return name
        # Should not happen if GVLs are correct; return as-is
        return name

    # ── VAR_GLOBAL ────────────────────────────────────────────────
    elif s == 'VAR_GLOBAL':
        # gPascalCase (e.g. gBatch, gTimeS) or plain PascalCase (e.g. Stations)
        if re.match(r'^g[A-Z]', name) or re.match(r'^[A-Z]', name):
            return name
        if re.match(r'^g_', name):  # old g_ style
            pascal = to_pascal_case(name[2:])
            return 'g' + pascal
        return 'g' + name[0].upper() + name[1:]

    # ── VAR_EXTERNAL ─────────────────────────────────────────────
    elif s == 'VAR_EXTERNAL':
        # Must match GVL variable names: gPascalCase or plain PascalCase
        # ALL_CAPS names are constants and belong in VAR_EXTERNAL CONSTANT, not here
        if re.match(r'^g[A-Z]', name):                      # gPascalCase
            return name
        if re.match(r'^[A-Z][a-zA-Z0-9]*$', name):         # PascalCase (no underscores)
            return name
        if re.match(r'^[A-Z][A-Z0-9_]*$', name):
            # ALL_CAPS in plain VAR_EXTERNAL → should be VAR_EXTERNAL CONSTANT
            return '→ VAR_EXTERNAL_CONSTANT: ' + name
        # anything else is a violation
        if re.match(r'^g_', name):
            pascal = to_pascal_case(name[2:])
            return 'g' + pascal
        return 'g' + name[0].upper() + name[1:]

    # ── STRUCT fields ─────────────────────────────────────────────
    elif s == 'STRUCT_FIELD':
        if re.match(r'^[A-Z]', name):
            return name
        if '_' in name:
            return to_pascal_case(name)
        return name[0].upper() + name[1:]

    return name


def is_violation(name: str, section: str) -> bool:
    return expected_name(name, section) != name


# ── Parser ────────────────────────────────────────────────────────────────────

# Matches: FUNCTION name, FUNCTION_BLOCK name, PROGRAM name
BLOCK_HEADER_RE = re.compile(
    r'^\s*(FUNCTION_BLOCK|FUNCTION|PROGRAM)\s+(\w+)',
    re.MULTILINE | re.IGNORECASE,
)

# Matches all VAR section types (longest first to avoid partial matches)
VAR_SECTION_RE = re.compile(
    r'\b(VAR_INPUT|VAR_OUTPUT|VAR_IN_OUT'
    r'|VAR_EXTERNAL\s+CONSTANT|VAR_EXTERNAL'
    r'|VAR_GLOBAL\s+CONSTANT|VAR_GLOBAL'
    r'|VAR)\b'
    r'(.*?)END_VAR',
    re.DOTALL | re.IGNORECASE,
)

# Matches STRUCT body
STRUCT_RE = re.compile(r'STRUCT\b(.*?)END_STRUCT', re.DOTALL | re.IGNORECASE)

# Matches variable declaration: name : ...
VAR_DECL_RE = re.compile(r'^\s*(\w+)\s*:', re.MULTILINE)


def _parse_var_decls(body: str) -> list[str]:
    names = []
    for m in VAR_DECL_RE.finditer(body):
        n = m.group(1)
        if n.upper() not in ST_KEYWORDS:
            names.append(n)
    return names


def parse_file_violations(path: Path) -> list[tuple[str, str, str]]:
    """Return list of (varname, section, expected) for violations in *path*."""
    text = path.read_text(encoding='utf-8')
    clean = strip_comments(text)
    violations = []

    # STRUCT fields
    for sm in STRUCT_RE.finditer(clean):
        for name in _parse_var_decls(sm.group(1)):
            exp = expected_name(name, 'STRUCT_FIELD')
            if exp != name:
                violations.append((name, 'STRUCT_FIELD', exp))

    # VAR sections
    for vm in VAR_SECTION_RE.finditer(clean):
        raw_sec = re.sub(r'\s+', '_', vm.group(1).strip().upper())
        body = vm.group(2)
        for name in _parse_var_decls(body):
            exp = expected_name(name, raw_sec)
            if exp != name:
                violations.append((name, raw_sec, exp))

    return violations


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    summary_only = '--summary' in sys.argv

    all_files = []
    for d in ST_DIRS:
        all_files.extend(sorted(d.rglob('*.st')))

    total_violations = 0
    files_with_violations = 0

    for path in all_files:
        rel = path.relative_to(SCRIPT_DIR)
        violations = parse_file_violations(path)
        if not violations:
            continue
        files_with_violations += 1
        total_violations += len(violations)
        if not summary_only:
            print(f'\n{rel}  ({len(violations)} violations)')
            for name, section, exp in sorted(violations, key=lambda x: x[1]):
                print(f'  [{section}]  {name}  →  {exp}')

    print()
    if total_violations == 0:
        print('✅  0 violations — all names comply with PLC Guide.')
        return 0
    else:
        print(f'❌  {total_violations} violations in {files_with_violations} files.')
        return 1


if __name__ == '__main__':
    sys.exit(main())
