#!/usr/bin/env python3
"""
build_codesys_xml.py — Build PLCopenXML for CODESYS IDE import

Reads ST source files from:
  UDTs/*.st   — User Data Types (structs)
  GVLs/*.st   — Global Variable Lists
  POUs/**/*.st — FBs, FUNCTIONs, PLC_PRG (recursive, supports subfolders)

Produces:
  build/project.xml — PLCopenXML importable by CODESYS IDE

The CODESYS version differs from the OpenPLC build_plcxml.py:
  - No AT %QW bindings (Modbus)
  - No MODBUS OUTPUT/EXTERNALS sections in PLC_PRG
  - GVLs are separate objects (not merged into one globals.st)
  - VAR_EXTERNAL CONSTANT in PLC_PRG references GVL constants directly
  - Cleaner: no generate_modbus.py dependency

Usage:
  cd codesys/
  python3 build_codesys_xml.py
  # → build/project.xml  (import into CODESYS IDE)
"""

import argparse
import os
import re
import sys
import textwrap
from collections import defaultdict
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
UDT_DIR = SCRIPT_DIR / "UDTs"
GVL_DIR = SCRIPT_DIR / "GVLs"
SRC_DIR = SCRIPT_DIR / "POUs"
BUILD_DIR = SCRIPT_DIR / "build"

PLCOPEN_NS = "http://www.plcopen.org/xml/tc6_0201"
XHTML_NS = "http://www.w3.org/1999/xhtml"
XSD_NS = "http://www.w3.org/2001/XMLSchema"
CODESYS_NS = "http://www.3s-software.com/plcopenxml"

# IEC 61131-3 simple types recognized by CODESYS PLCopenXML import.
# LINT/ULINT included — CODESYS 3.5 supports them natively.
SIMPLE_TYPES = {
    "BOOL", "INT", "DINT", "LINT", "SINT", "USINT",
    "UINT", "UDINT", "ULINT", "REAL", "LREAL",
    "BYTE", "WORD", "DWORD", "LWORD",
    "TIME", "DATE", "TOD", "DT",
}

# Constants from GVL_JC_Constants — PLCopenXML array bounds must be numeric literals.
# CODESYS import cannot resolve symbolic names in <dimension lower="..." upper="..."/>.
CONST_VALUES = {
    "MAX_LINES":                 "1",
    "MAX_STATIONS_PER_LINE":     "30",
    "MAX_TRANSPORTERS_PER_LINE": "3",
    "MIN_STATION_INDEX":          "100",
    "MAX_STATION_INDEX":          "130",
    "MAX_TRANSPORTERS":          "3",
    "MAX_UNITS":                 "10",
    "MAX_STATIONS_PER_STEP":     "5",
    "MAX_STEPS_PER_PROGRAM":     "30",
    "MAX_TASK_QUEUE":            "30",
    "MAX_LOCKS":                 "50",
    "DEP_MAX_IDLE_SLOTS":        "20",
    "DEP_MAX_DELAY_ACTS":        "20",
    "DEP_MAX_WAITING":           "5",
}


def resolve_const(expr: str) -> str:
    """Replace symbolic constant names with numeric literals for XML array bounds."""
    expr = expr.strip()
    return CONST_VALUES.get(expr, expr)

# ── Helpers ────────────────────────────────────────────────────────────────

def strip_comments(text: str) -> str:
    """Remove (* … *) block comments (non-nested)."""
    return re.sub(r'\(\*.*?\*\)', '', text, flags=re.DOTALL)


def xml_esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def indent(xml: str, level: int) -> str:
    prefix = "  " * level
    return "\n".join(prefix + line if line.strip() else "" for line in xml.splitlines())


# ── Type XML ───────────────────────────────────────────────────────────────

def type_to_xml(type_str: str) -> str:
    """Convert ST type string → PLCopenXML type fragment."""
    type_str = type_str.strip()
    upper = type_str.upper()

    # Array?
    arr_m = re.match(
        r'ARRAY\s*\[\s*(.+?)\s*\.\.\s*(.+?)\s*\]\s+OF\s+(.+)',
        type_str, re.IGNORECASE)
    if arr_m:
        lo, hi, base = arr_m.group(1), arr_m.group(2), arr_m.group(3).strip()
        lo = resolve_const(lo)
        hi = resolve_const(hi)
        inner = type_to_xml(base)
        return (f'<array>\n'
                f'  <dimension lower="{lo}" upper="{hi}"/>\n'
                f'  <baseType>{inner}</baseType>\n'
                f'</array>')

    # STRING / WSTRING need special format: <string length="80"/> not <STRING/>
    # PLCopenXML TC6 uses lowercase with mandatory length attribute.
    # STRING(N) → <string length="N"/>   STRING → <string length="80"/> (CODESYS default)
    str_m = re.match(r'(W?STRING)\s*(?:\(\s*(\d+)\s*\))?$', type_str, re.IGNORECASE)
    if str_m:
        tag = 'wstring' if str_m.group(1).upper() == 'WSTRING' else 'string'
        length = str_m.group(2) if str_m.group(2) else '80'
        return f'<{tag} length="{length}"/>'

    # Simple?
    for st in SIMPLE_TYPES:
        if upper == st:
            return f'<{st}/>'

    # Derived (UDT / FB)
    return f'<derived name="{type_str}"/>'


# ── UDT Parser ─────────────────────────────────────────────────────────────

def parse_udt_file(path: Path):
    """Return (type_name, [(field_name, type_str, initial_value_or_None)]) or None."""
    text = path.read_text(encoding='utf-8')
    clean = strip_comments(text)
    m = re.search(
        r'TYPE\s+(\w+)\s*:\s*STRUCT\b(.*?)END_STRUCT\s*;\s*END_TYPE',
        clean, re.DOTALL | re.IGNORECASE)
    if not m:
        return None
    name = m.group(1)
    body = m.group(2)
    fields = []
    for fld in re.finditer(r'(\w+)\s*:\s*([^;:]+?)(?::=\s*([^;]+?))?\s*;', body):
        fields.append((fld.group(1).strip(), fld.group(2).strip(),
                        fld.group(3).strip() if fld.group(3) else None))
    return name, fields, text


def resolve_udt_order(udt_dir: Path):
    """Parse all UDTs and return them in dependency order (topological sort)."""
    udts = {}  # name → (path, fields, raw_text)
    deps = {}  # name → set of referenced type names

    for p in sorted(udt_dir.glob('*.st')):
        result = parse_udt_file(p)
        if result:
            name, fields, raw_text = result
            udts[name] = (p, fields, raw_text)
            refs = set()
            for _, ftype, _ in fields:
                for ref_m in re.finditer(r'(UDT_\w+)', ftype):
                    ref = ref_m.group(1)
                    if ref != name:
                        refs.add(ref)
            deps[name] = refs

    # Kahn's algorithm
    all_names = set(udts.keys())
    in_degree = {n: 0 for n in all_names}
    reverse = defaultdict(list)
    for n, d in deps.items():
        for dep in d & all_names:
            in_degree[n] += 1
            reverse[dep].append(n)

    queue = [n for n in all_names if in_degree[n] == 0]
    queue.sort()
    ordered = []
    while queue:
        n = queue.pop(0)
        ordered.append(n)
        for dependent in sorted(reverse[n]):
            in_degree[dependent] -= 1
            if in_degree[dependent] == 0:
                queue.append(dependent)

    return [(name, udts[name][1], udts[name][2]) for name in ordered]


# ── GVL Parser ─────────────────────────────────────────────────────────────

class GVL:
    """A single Global Variable List."""
    def __init__(self, name: str, is_constant: bool, variables: list, raw_text: str = ''):
        self.name = name
        self.is_constant = is_constant
        self.variables = variables  # list of (var_name, type_str, initial)
        self.raw_text = raw_text    # original ST source text for CODESYS addData


def parse_gvl_file(path: Path) -> list[GVL]:
    """Parse a GVL file, return list of GVL objects."""
    raw_text = path.read_text(encoding='utf-8')
    clean = strip_comments(raw_text)
    stem = path.stem  # e.g. "GVL_JC_Constants"

    results = []
    for m in re.finditer(
        r'VAR_GLOBAL\b(\s+CONSTANT)?(.*?)END_VAR',
        clean, re.DOTALL | re.IGNORECASE
    ):
        is_const = m.group(1) is not None
        body = m.group(2)
        variables = []
        for vm in re.finditer(
            r'(\w+)\s*:\s*([^;:]+?)(?::=\s*([^;]+?))?\s*;',
            body
        ):
            variables.append((
                vm.group(1).strip(),
                vm.group(2).strip(),
                vm.group(3).strip() if vm.group(3) else None
            ))
        if variables:
            results.append(GVL(stem, is_const, variables, raw_text=raw_text))

    return results


# ── POU Parser ─────────────────────────────────────────────────────────────

class VarDecl:
    __slots__ = ('name', 'type_str', 'initial', 'is_constant')

    def __init__(self, name, type_str, initial=None, is_constant=False):
        self.name = name
        self.type_str = type_str
        self.initial = initial
        self.is_constant = is_constant


class POU:
    __slots__ = ('name', 'pou_type', 'return_type',
                 'input_vars', 'output_vars', 'inout_vars',
                 'local_vars', 'external_vars', 'external_const_vars',
                 'body', 'raw_declaration')

    def __init__(self):
        self.name = ''
        self.pou_type = ''
        self.return_type = None
        self.input_vars = []
        self.output_vars = []
        self.inout_vars = []
        self.local_vars = []
        self.external_vars = []        # VAR_EXTERNAL (non-constant)
        self.external_const_vars = []  # VAR_EXTERNAL CONSTANT
        self.body = ''
        self.raw_declaration = ''  # raw ST header + VAR sections for CODESYS addData


def _parse_var_section(body: str) -> list[VarDecl]:
    results = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        vm = re.match(
            r'(\w+)\s*:\s*([^;:]+?)(?::=\s*([^;]+?))?\s*;',
            line, re.IGNORECASE)
        if vm:
            results.append(VarDecl(
                name=vm.group(1),
                type_str=vm.group(2).strip(),
                initial=vm.group(3).strip() if vm.group(3) else None,
            ))
    return results


def parse_pou(text: str) -> POU | None:
    """Parse a FUNCTION / FUNCTION_BLOCK / PROGRAM."""
    raw = text  # keep original for body extraction
    clean = strip_comments(text)
    pou = POU()

    # Detect POU kind
    fm = re.match(r'\s*FUNCTION_BLOCK\s+(\w+)', clean, re.IGNORECASE)
    if fm:
        pou.name = fm.group(1)
        pou.pou_type = 'functionBlock'
        end_kw = 'END_FUNCTION_BLOCK'
    else:
        fm = re.match(r'\s*FUNCTION\s+(\w+)\s*:\s*(\w+)', clean, re.IGNORECASE)
        if fm:
            pou.name = fm.group(1)
            pou.pou_type = 'function'
            pou.return_type = fm.group(2)
            end_kw = 'END_FUNCTION'
        else:
            fm = re.match(r'\s*PROGRAM\s+(\w+)', clean, re.IGNORECASE)
            if fm:
                pou.name = fm.group(1)
                pou.pou_type = 'program'
                end_kw = 'END_PROGRAM'
            else:
                return None

    rest_clean = clean[fm.end():]
    rest_clean = re.sub(re.escape(end_kw) + r'\s*$', '', rest_clean, flags=re.IGNORECASE)

    # Parse VAR sections
    var_section_map = {
        'VAR_INPUT':  'input_vars',
        'VAR_OUTPUT': 'output_vars',
        'VAR_IN_OUT': 'inout_vars',
        'VAR':        'local_vars',
    }

    for kw, attr in var_section_map.items():
        if kw == 'VAR':
            pat = re.compile(r'\bVAR\b(?!_)(.*?)END_VAR', re.DOTALL | re.IGNORECASE)
        else:
            pat = re.compile(re.escape(kw) + r'\b(.*?)END_VAR', re.DOTALL | re.IGNORECASE)
        for vm in pat.finditer(rest_clean):
            if attr:
                parsed = _parse_var_section(vm.group(1))
                existing = getattr(pou, attr, [])
                setattr(pou, attr, existing + parsed)

    # VAR_EXTERNAL and VAR_EXTERNAL CONSTANT — separate lists
    for vm in re.finditer(r'VAR_EXTERNAL\b(\s+CONSTANT)?(.*?)END_VAR', rest_clean, re.DOTALL | re.IGNORECASE):
        is_const = vm.group(1) is not None
        parsed = _parse_var_section(vm.group(2))
        if is_const:
            pou.external_const_vars += parsed
        else:
            pou.external_vars += parsed

    # Extract body from raw text
    raw_header_m = re.match(
        r'\s*(?:FUNCTION_BLOCK\s+\w+|FUNCTION\s+\w+\s*:\s*\w+|PROGRAM\s+\w+)',
        raw, re.IGNORECASE)
    rest_raw = raw[raw_header_m.end():] if raw_header_m else raw

    end_var_positions = [m.end() for m in re.finditer(r'END_VAR', rest_raw, re.IGNORECASE)]
    if end_var_positions:
        body_raw = rest_raw[max(end_var_positions):]
    else:
        body_raw = rest_raw

    body_raw = re.sub(re.escape(end_kw) + r'\s*$', '', body_raw, flags=re.IGNORECASE)

    # Strip leading/trailing blank lines
    body_lines = body_raw.split('\n')
    while body_lines and not body_lines[0].strip():
        body_lines.pop(0)
    while body_lines and not body_lines[-1].strip():
        body_lines.pop()

    pou.body = textwrap.dedent('\n'.join(body_lines))

    # Extract raw declaration (header + VAR sections, no body) for CODESYS addData
    if end_var_positions:
        if raw_header_m:
            raw_decl = raw[:raw_header_m.end()] + rest_raw[:max(end_var_positions)]
        else:
            raw_decl = rest_raw[:max(end_var_positions)]
    else:
        raw_decl = raw[:raw_header_m.end()] if raw_header_m else ''
    pou.raw_declaration = raw_decl.strip()

    return pou


# ── XML Generation ─────────────────────────────────────────────────────────

def _var_xml(name: str, type_str: str, initial=None, lvl: int = 0) -> str:
    pad = "  " * lvl
    lines = [f'{pad}<variable name="{name}">']
    type_xml = type_to_xml(type_str)
    if '\n' in type_xml:
        lines.append(f'{pad}  <type>')
        lines.append(indent(type_xml, lvl + 2))
        lines.append(f'{pad}  </type>')
    else:
        lines.append(f'{pad}  <type>{type_xml}</type>')
    if initial is not None:
        lines.append(f'{pad}  <initialValue><simpleValue value="{xml_esc(initial)}"/></initialValue>')
    lines.append(f'{pad}</variable>')
    return '\n'.join(lines)


def _var_section_xml(tag: str, vars_list, lvl: int) -> str:
    if not vars_list:
        return ''
    pad = "  " * lvl
    lines = [f'{pad}<{tag}>']
    for v in vars_list:
        if isinstance(v, VarDecl):
            lines.append(_var_xml(v.name, v.type_str, v.initial, lvl + 1))
        else:
            # tuple (name, type_str, initial)
            lines.append(_var_xml(v[0], v[1], v[2] if len(v) > 2 else None, lvl + 1))
    lines.append(f'{pad}</{tag}>')
    return '\n'.join(lines)


def _datatype_xml(name: str, fields: list, lvl: int, raw_text: str = '') -> str:
    pad = "  " * lvl
    lines = [f'{pad}<dataType name="{name}">']
    lines.append(f'{pad}  <baseType>')
    lines.append(f'{pad}    <struct>')
    for field in fields:
        fname, ftype = field[0], field[1]
        finit = field[2] if len(field) > 2 else None
        lines.append(_var_xml(fname, ftype, finit, lvl + 3))
    lines.append(f'{pad}    </struct>')
    lines.append(f'{pad}  </baseType>')
    lines.append(f'{pad}</dataType>')
    return '\n'.join(lines)


def _pou_xml(pou: POU, lvl: int) -> str:
    pad = "  " * lvl
    lines = [f'{pad}<pou name="{pou.name}" pouType="{pou.pou_type}">']

    lines.append(f'{pad}  <interface>')
    if pou.return_type:
        rt = type_to_xml(pou.return_type)
        lines.append(f'{pad}    <returnType>')
        lines.append(f'{pad}      {rt}')
        lines.append(f'{pad}    </returnType>')

    # PLCopenXML interface sections — ORDER MATTERS for CODESYS import:
    # returnType, inputVars, outputVars, inOutVars,
    # externalVars (constant), externalVars (non-const), localVars
    section_map = [
        ('inputVars',  pou.input_vars),
        ('outputVars', pou.output_vars),
        ('inOutVars',  pou.inout_vars),
    ]
    for tag, vlist in section_map:
        xml = _var_section_xml(tag, vlist, lvl + 2)
        if xml:
            lines.append(xml)

    # VAR_EXTERNAL CONSTANT → <externalVars constant="true">
    if pou.external_const_vars:
        pad2 = "  " * (lvl + 2)
        lines.append(f'{pad2}<externalVars constant="true">')
        for v in pou.external_const_vars:
            lines.append(_var_xml(v.name, v.type_str, v.initial, lvl + 3))
        lines.append(f'{pad2}</externalVars>')

    # VAR_EXTERNAL → <externalVars>
    if pou.external_vars:
        xml = _var_section_xml('externalVars', pou.external_vars, lvl + 2)
        if xml:
            lines.append(xml)

    # VAR → <localVars>  (must come AFTER externalVars)
    if pou.local_vars:
        xml = _var_section_xml('localVars', pou.local_vars, lvl + 2)
        if xml:
            lines.append(xml)

    lines.append(f'{pad}  </interface>')

    lines.append(f'{pad}  <body>')
    lines.append(f'{pad}    <ST>')
    lines.append(f'{pad}      <xhtml:p><![CDATA[{pou.body}]]></xhtml:p>')
    lines.append(f'{pad}    </ST>')
    lines.append(f'{pad}  </body>')

    # CODESYS addData — raw declaration for proper import
    if pou.raw_declaration:
        lines.append(f'{pad}  <addData>')
        lines.append(f'{pad}    <data name="{CODESYS_NS}/pou" handleUnknown="implementation">')
        lines.append(f'{pad}      <pou>')
        lines.append(f'{pad}        <Declaration><![CDATA[{pou.raw_declaration}]]></Declaration>')
        lines.append(f'{pad}      </pou>')
        lines.append(f'{pad}    </data>')
        lines.append(f'{pad}  </addData>')

    lines.append(f'{pad}</pou>')
    return '\n'.join(lines)


def _gvl_xml(gvl: GVL, lvl: int) -> str:
    """Generate standard PLCopen <globalVars> element.

    Placed inside <resource> per PLCopen TC6 standard.
    CODESYS creates the variables (accessible from POUs) even though
    it does NOT create named GVL objects in the project tree.
    Use codesys_setup.py script to create named GVL objects.
    """
    pad = "  " * lvl
    const_attr = ' constant="true"' if gvl.is_constant else ''
    lines = [f'{pad}<globalVars name="{gvl.name}"{const_attr}>']
    for var_name, var_type, var_init in gvl.variables:
        lines.append(_var_xml(var_name, var_type, var_init, lvl + 1))
    lines.append(f'{pad}</globalVars>')
    return '\n'.join(lines)


def build_project_xml(
    data_types: list,
    gvls: list[GVL],
    pous: list[POU],
    task_interval: str = "T#20ms",
    task_priority: str = "0",
) -> str:
    """Assemble full PLCopenXML."""
    now = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")

    lines = [
        "<?xml version='1.0' encoding='utf-8'?>",
        f'<project xmlns:ns1="{PLCOPEN_NS}" xmlns:xhtml="{XHTML_NS}" '
        f'xmlns:xsd="{XSD_NS}" xmlns="{PLCOPEN_NS}">',
        f'  <fileHeader companyName="Galvatek" productName="PlantSimulator" '
        f'productVersion="1.0" creationDateTime="{now}"/>',
        f'  <contentHeader name="PlantSimulator" modificationDateTime="{now}">',
        '    <coordinateInfo>',
        '      <fbd><scaling x="0" y="0"/></fbd>',
        '      <ld><scaling x="0" y="0"/></ld>',
        '      <sfc><scaling x="0" y="0"/></sfc>',
        '    </coordinateInfo>',
        '  </contentHeader>',
        '  <types>',
        '    <dataTypes>',
    ]

    # Data types (UDTs)
    for dt_item in data_types:
        dt_name, dt_fields = dt_item[0], dt_item[1]
        dt_raw = dt_item[2] if len(dt_item) > 2 else ''
        lines.append(_datatype_xml(dt_name, dt_fields, 3, raw_text=dt_raw))

    lines.append('    </dataTypes>')
    lines.append('    <pous>')

    # POUs
    for pou in pous:
        lines.append(_pou_xml(pou, 3))

    lines.append('    </pous>')
    lines.append('  </types>')

    # Instances / configuration
    lines.append('  <instances>')
    lines.append('    <configurations>')
    lines.append('      <configuration name="Config0">')
    lines.append('        <resource name="Res0">')
    lines.append(f'          <task name="MainTask" priority="{task_priority}" interval="{task_interval}">')
    lines.append('            <pouInstance name="instance0" typeName="PLC_PRG"/>')
    lines.append('          </task>')

    # Global Variable Lists — standard PLCopen <globalVars> inside <resource>
    # This creates actual global variables accessible from all POUs.
    for gvl in gvls:
        lines.append(_gvl_xml(gvl, 5))

    # CODESYS addData INSIDE <resource> — TaskConfiguration must be here,
    # not at the project level. Without this CODESYS reports:
    #   C0009: Unexpected token '}' found
    #   C0189: ';' expected instead of 'iotaskmap'
    #   "There is no task defined in the application"
    lines.append('          <addData>')
    lines.append(f'            <data name="{CODESYS_NS}/taskconfiguration" handleUnknown="implementation">')
    lines.append('              <TaskConfiguration>')
    lines.append(f'                <Task Name="MainTask" Priority="{task_priority}" CycleTime="{task_interval}" KindOfTask="Cyclic">')
    lines.append('                  <Pou Name="PLC_PRG"/>')
    lines.append('                </Task>')
    lines.append('              </TaskConfiguration>')
    lines.append('            </data>')
    lines.append('          </addData>')

    lines.append('        </resource>')
    lines.append('      </configuration>')
    lines.append('    </configurations>')
    lines.append('  </instances>')

    # CODESYS addData at <project> level — GVLs as named objects.
    # Two GVL formats for maximum compatibility:
    #   1) "globalvars" (lowercase) — official 3S library format with structured <variable> XML
    #   2) "globalvarlist" — CODESYS extended format with raw ST Declaration CDATA
    lines.append('  <addData>')

    if gvls:
        # Format 1: structured variables (official 3S format, e.g. IoDrvGPIO library)
        # URL: .../globalvars  element: <globalVars name="..." [constant="true"]>
        for gvl in gvls:
            lines.append(f'    <data name="{CODESYS_NS}/globalvars" handleUnknown="implementation">')
            lines.append(_gvl_xml(gvl, 3))
            lines.append(f'    </data>')

        # Format 2: CDATA declaration (CODESYS "export declarations as plain text")
        # URL: .../globalvarlist  element: <GlobalVarList Name="...">
        # Replace symbolic constants with numeric literals in CDATA text
        # because CODESYS cannot resolve cross-GVL constants in array bounds.
        for gvl in gvls:
            raw = gvl.raw_text.strip()
            for const_name, const_val in CONST_VALUES.items():
                # Replace e.g. "1..MAX_Transporters" -> "1..3"
                raw = raw.replace(const_name, const_val)
            lines.append(f'    <data name="{CODESYS_NS}/globalvarlist" handleUnknown="implementation">')
            lines.append(f'      <GlobalVarList Name="{gvl.name}">')
            lines.append(f'        <Declaration><![CDATA[{raw}]]></Declaration>')
            lines.append(f'      </GlobalVarList>')
            lines.append(f'    </data>')

    lines.append('  </addData>')

    lines.append('</project>')

    return '\n'.join(lines) + '\n'


# ── Main ───────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Build PLCopenXML for CODESYS import from UDTs/ + GVLs/ + POUs/')
    parser.add_argument('-o', '--output', default=str(BUILD_DIR / 'project.xml'),
                        help='Output XML (default: build/project.xml)')
    parser.add_argument('--interval', default='T#20ms',
                        help='Task cycle interval (default: T#20ms)')
    args = parser.parse_args()

    print("═══ CODESYS PLCopenXML Builder ═══\n")

    # 1. Parse UDTs in dependency order
    print("── UDTs ──")
    data_types = resolve_udt_order(UDT_DIR)
    for dt_item in data_types:
        print(f"  {dt_item[0]} ({len(dt_item[1])} fields)")
    print(f"  Total: {len(data_types)} types\n")

    # 2. Parse GVLs
    print("── GVLs ──")
    gvls = []
    for p in sorted(GVL_DIR.glob('*.st')):
        parsed = parse_gvl_file(p)
        for gvl in parsed:
            gvls.append(gvl)
            const_tag = " CONSTANT" if gvl.is_constant else ""
            print(f"  {gvl.name}{const_tag} ({len(gvl.variables)} vars)")
    print(f"  Total: {len(gvls)} GVL blocks\n")

    # 3. Parse POUs
    print("── POUs ──")
    pou_order = {'function': 0, 'functionBlock': 1, 'program': 2}
    pous = []
    for p in sorted(SRC_DIR.rglob('*.st')):
        text = p.read_text(encoding='utf-8')
        pou = parse_pou(text)
        if pou:
            pous.append(pou)
            print(f"  {pou.name} ({pou.pou_type})")
        else:
            print(f"  WARNING: Could not parse {p.name}", file=sys.stderr)

    pous.sort(key=lambda p: pou_order.get(p.pou_type, 9))
    print(f"  Total: {len(pous)} POUs\n")

    # 4. Build XML
    xml = build_project_xml(data_types, gvls, pous, task_interval=args.interval)

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(xml, encoding='utf-8')

    print(f"── Output ──")
    print(f"  ✓ {out}  ({len(xml):,} bytes)")
    print(f"  Import in CODESYS IDE: Project → Import PLCopenXML")


if __name__ == '__main__':
    main()
