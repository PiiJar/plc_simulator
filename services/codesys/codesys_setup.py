#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
codesys_setup.py -- CODESYS IDE automation script (full setup)

Run this INSIDE CODESYS IDE:
  Tools -> Scripting -> Execute Script File -> select this file

This script does EVERYTHING automatically:
  1) Imports PLCopenXML (build/project.xml)
  2) Creates Task Configuration (MainTask -> PLC_PRG)
  3) Creates named GVL objects from ST source files

Prerequisites:
  - CODESYS project open (even empty Standard project is fine)
  - Script run from Z:\codesys\ or similar mapped drive
"""
import os
import codecs

# -- Configuration ----------------------------------------------------------
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = _SCRIPT_DIR
BUILD_DIR = os.path.join(PROJECT_ROOT, "build")
GVL_DIR = os.path.join(PROJECT_ROOT, "GVLs")
XML_FILE = os.path.join(BUILD_DIR, "project.xml")

GVL_FILES = {
    "GVL_JC_Constants.st": "GVL_JC_Constants",
    "GVL_JC_Scheduler.st": "GVL_JC_Scheduler",
    "GVL_Parameters.st":   "GVL_Parameters",
}

TASK_NAME = "MainTask"
TASK_INTERVAL = "t#20ms"
TASK_PRIORITY = 0


# -- Helpers ----------------------------------------------------------------

def read_text_file(filepath):
    """Read text file - IronPython 2.7 compatible."""
    try:
        return codecs.open(filepath, 'r', 'utf-8').read()
    except Exception:
        f = open(filepath, 'r')
        text = f.read()
        f.close()
        return text


# -- Step 1: Import PLCopenXML ---------------------------------------------

def step1_import_xml():
    """Import PLCopenXML."""
    proj = projects.primary
    if proj is None:
        system.write_message(Severity.Error, "No project open!")
        return False

    if not os.path.exists(XML_FILE):
        system.write_message(Severity.Error,
            "XML file not found: %s" % XML_FILE)
        return False

    system.write_message(Severity.Information,
        "Step 1: Importing PLCopenXML from %s ..." % XML_FILE)

    # Try multiple API signatures - varies by CODESYS version
    methods = [
        ("import_xml(path)", lambda: proj.import_xml(XML_FILE)),
        ("import_plcopenxml(path)", lambda: proj.import_plcopenxml(XML_FILE)),
        ("import_xml(path, True)", lambda: proj.import_xml(XML_FILE, True)),
        ("import_native(path)", lambda: proj.import_native(XML_FILE)),
    ]

    for name, method in methods:
        try:
            method()
            system.write_message(Severity.Information,
                "PLCopenXML import complete! (via %s)" % name)
            return True
        except Exception as e:
            system.write_message(Severity.Warning,
                "%s: %s" % (name, str(e)))
            continue

    system.write_message(Severity.Error,
        "Automatic import failed. Please do manually:")
    system.write_message(Severity.Error,
        "  Project -> Import PLCopenXML -> %s" % XML_FILE)
    return False


# -- Step 2: Task Configuration ---------------------------------------------

def step2_task_config():
    """Create Task Configuration + MainTask + PLC_PRG call."""
    proj = projects.primary
    app = proj.active_application

    if app is None:
        system.write_message(Severity.Error, "No Application found!")
        return False

    system.write_message(Severity.Information,
        "Step 2: Creating Task Configuration...")

    # Debug: list all available methods on Application object
    app_methods = [m for m in dir(app) if not m.startswith('_')]
    system.write_message(Severity.Information,
        "App methods: %s" % ", ".join(app_methods[:30]))

    # Check if Task Configuration already exists
    task_cfg = None
    for child in app.get_children(False):
        name = ""
        try:
            name = child.get_name()
        except Exception:
            pass
        system.write_message(Severity.Information,
            "  App child: '%s' type=%s" % (name, type(child).__name__))
        if "Task" in name:
            task_cfg = child
            system.write_message(Severity.Information,
                "Task Configuration found: %s" % name)
            break

    # Create Task Configuration if not found
    if task_cfg is None:
        # Try various CODESYS scripting API methods
        attempts = [
            ("add('Task Configuration')", lambda: app.add("Task Configuration")),
            ("create_child('Task Configuration')", lambda: app.create_child("Task Configuration")),
            ("add_task_configuration()", lambda: app.add_task_configuration()),
            ("create_object(name, GUID-1)", lambda: app.create_object("Task Configuration", "{63784CBB-9BA0-45E6-8A91-19E533341F8B}")),
            ("create_object(name, GUID-2)", lambda: app.create_object("Task Configuration", "{AE1B7C34-E403-4A6E-B961-B15F5C3E8B6D}")),
        ]
        for aname, method in attempts:
            try:
                task_cfg = method()
                system.write_message(Severity.Information,
                    "Created Task Configuration via %s" % aname)
                break
            except Exception as e:
                system.write_message(Severity.Warning,
                    "%s: %s" % (aname, str(e)))

    if task_cfg is None:
        system.write_message(Severity.Error,
            "Could not create Task Configuration automatically.")
        system.write_message(Severity.Error,
            "MANUAL: Right-click PLCSimulator -> Add Object -> Task Configuration")
        system.write_message(Severity.Error,
            "Then add Task 'MainTask' (Cyclic, t#20ms) with PLC_PRG call")
        return False

    # Debug: list task_cfg methods
    tc_methods = [m for m in dir(task_cfg) if not m.startswith('_')]
    system.write_message(Severity.Information,
        "TaskCfg methods: %s" % ", ".join(tc_methods[:30]))

    # Now create MainTask inside Task Configuration
    main_task = None
    for child in task_cfg.get_children(False):
        name = ""
        try:
            name = child.get_name()
        except Exception:
            pass
        if name == TASK_NAME:
            main_task = child
            system.write_message(Severity.Information,
                "MainTask already exists")
            break

    if main_task is None:
        # Try multiple methods to create a task
        attempts = [
            ("create_task(3 args)", lambda: task_cfg.create_task(TASK_NAME, TASK_PRIORITY, TASK_INTERVAL)),
            ("create_task(1 arg)", lambda: task_cfg.create_task(TASK_NAME)),
            ("add(Task, name)", lambda: task_cfg.add("Task", TASK_NAME)),
            ("add(name)", lambda: task_cfg.add(TASK_NAME)),
            ("create_child(name)", lambda: task_cfg.create_child(TASK_NAME)),
            ("create_object(GUID)", lambda: task_cfg.create_object(TASK_NAME, "{0EFD780A-3535-4B59-BCBC-21D5B4C70E54}")),
        ]
        for aname, method in attempts:
            try:
                main_task = method()
                system.write_message(Severity.Information,
                    "Created MainTask via %s" % aname)
                break
            except Exception as e:
                system.write_message(Severity.Warning,
                    "%s: %s" % (aname, str(e)))

    if main_task is None:
        system.write_message(Severity.Error,
            "Could not create MainTask. Do manually:")
        system.write_message(Severity.Error,
            "  Right-click Task Configuration -> Add Task")
        system.write_message(Severity.Error,
            "  Name: MainTask, Type: Cyclic, Interval: t#20ms")
        system.write_message(Severity.Error,
            "  Then: Right-click MainTask -> Add Call -> PLC_PRG")
        return False

    # Add PLC_PRG call to MainTask
    try:
        main_task.add_call("PLC_PRG")
        system.write_message(Severity.Information,
            "Added PLC_PRG call to MainTask")
    except Exception as e:
        system.write_message(Severity.Warning,
            "add_call: %s (may already exist)" % str(e))

    system.write_message(Severity.Information,
        "Task Configuration complete!")
    return True


# -- Step 3: Create GVL objects ---------------------------------------------

def step3_create_gvls():
    """Create named GVL objects in the project tree."""
    proj = projects.primary
    app = proj.active_application

    if app is None:
        system.write_message(Severity.Error, "No Application found!")
        return

    system.write_message(Severity.Information,
        "Step 3: Creating GVL objects...")

    for filename, gvl_name in GVL_FILES.items():
        filepath = os.path.join(GVL_DIR, filename)

        try:
            st_text = read_text_file(filepath)
        except Exception as e:
            system.write_message(Severity.Error,
                "Cannot read %s: %s" % (filepath, str(e)))
            continue

        # Check if already exists
        existing = proj.find(gvl_name)
        if existing:
            system.write_message(Severity.Information,
                "GVL '%s' already exists -- skipping" % gvl_name)
            continue

        # Create GVL - try multiple methods
        created = False
        attempts = [
            ("create_gvl", lambda n=gvl_name: app.create_gvl(n)),
            ("add GlobalVarList", lambda n=gvl_name: app.add("GlobalVarList", n)),
            ("GUID", lambda n=gvl_name: app.create_object(n, "{FFB04C34-B84D-4A2E-B5C2-29D33F5F2A10}")),
        ]
        for aname, method in attempts:
            try:
                gvl = method()
                gvl.textual_declaration.replace(st_text)
                system.write_message(Severity.Information,
                    "Created GVL: %s (via %s)" % (gvl_name, aname))
                created = True
                break
            except Exception as e:
                system.write_message(Severity.Warning,
                    "GVL %s %s: %s" % (gvl_name, aname, str(e)))

        if not created:
            system.write_message(Severity.Error,
                "Failed to create GVL '%s'" % gvl_name)

    system.write_message(Severity.Information, "GVL setup complete!")


# -- Main -------------------------------------------------------------------

def main():
    system.write_message(Severity.Information,
        "=== CODESYS Project Setup ===")
    system.write_message(Severity.Information,
        "Script dir: %s" % _SCRIPT_DIR)
    system.write_message(Severity.Information,
        "XML file: %s (exists: %s)" % (XML_FILE, os.path.exists(XML_FILE)))

    # Step 1: Import XML
    step1_import_xml()

    # Step 2: Task configuration
    has_task = step2_task_config()

    # Step 3: GVLs
    step3_create_gvls()

    system.write_message(Severity.Information,
        "=== Setup complete! ===")

    if has_task:
        system.write_message(Severity.Information,
            "All done! Try Build -> Build (F11)")
    else:
        system.write_message(Severity.Warning,
            "Task Configuration needs manual setup (see errors above)")

main()
