#!/usr/bin/env python3
"""Capture identical theme fixtures and real cold-start windows (no Git media)."""
import argparse
import os
from pathlib import Path
import selectors
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('phase', choices=['before', 'after'])
parser.add_argument('--native-only', action='store_true', help='Keep existing fixture screenshots and recapture native windows only')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = root / '_build/qa-dark-theme-pr' / args.phase
output.mkdir(parents=True, exist_ok=True)

def adb(*arguments):
    return subprocess.run(['adb', *arguments], check=True, capture_output=True)

def scenario(name):
    adb('shell', 'am', 'force-stop', 'com.logseq.logseq')
    command = ['adb', 'shell', 'am', 'instrument', '-w', '-r', '-e', 'class',
        'com.logseq.logseq.AndroidDarkThemeScreenshotTest', '-e', 'themeScenario', name,
        'com.logseq.logseq.test/androidx.test.runner.AndroidJUnitRunner']
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    chunks = []
    started = time.monotonic()
    complete = False
    while time.monotonic() - started < 60:
        if not selector.select(timeout=1):
            continue
        chunk = os.read(process.stdout.fileno(), 65536)
        if not chunk:
            break
        chunks.append(chunk)
        if b'theme-capture-complete=' + name.encode() in b''.join(chunks):
            complete = True
            break
    (output / (name + '.log')).write_bytes(b''.join(chunks))
    adb('shell', 'am', 'force-stop', 'com.logseq.logseq')
    process.wait(timeout=10)
    selector.close()
    if not complete:
        raise RuntimeError('Scenario failed: ' + name)
    print(args.phase, name, 'captured', flush=True)

def screen(name):
    (output / (name + '.png')).write_bytes(adb('exec-out', 'screencap', '-p').stdout)

def ready(name):
    for _ in range(10):
        time.sleep(1)
        result = subprocess.run(['adb', 'shell', 'uiautomator', 'dump', '/sdcard/theme-capture.xml'], capture_output=True)
        if result.returncode == 0 and b'dumped to:' in result.stdout:
            hierarchy = adb('shell', 'cat', '/sdcard/theme-capture.xml').stdout
            if b'button.sign-in' in hierarchy:
                (output / (name + '.xml')).write_bytes(hierarchy)
                screen(name)
                return
    raise RuntimeError('App did not reach the signed-out screen: ' + name)

try:
    adb('shell', 'cmd', 'uimode', 'night', 'no')
    scenario('prepare-system')
    for name in ([] if args.native_only else ['html', 'flashcards', 'task-statuses']):
        scenario(name)
        adb('pull', '/sdcard/Android/data/com.logseq.logseq/files/dark-theme-' + name + '.png', str(output / (name + '.png')))
    scenario('prepare-dark')
    adb('shell', 'am', 'start', '-n', 'com.logseq.logseq/.MainActivity')
    time.sleep(2)
    screen('startup')
    ready('native-dark')
    adb('shell', 'cmd', 'uimode', 'night', 'yes')
    scenario('prepare-light')
    adb('shell', 'am', 'start', '-n', 'com.logseq.logseq/.MainActivity')
    ready('system-bars')
    scenario('prepare-system')
    adb('shell', 'am', 'start', '-n', 'com.logseq.logseq/.MainActivity')
    ready('follow-system-dark')
    adb('shell', 'cmd', 'uimode', 'night', 'no')
    time.sleep(2)
    ready('follow-system-light')
finally:
    adb('shell', 'am', 'force-stop', 'com.logseq.logseq')
    adb('shell', 'cmd', 'uimode', 'night', 'no')
