import re, shlex, subprocess, time, xml.etree.ElementTree as ET
from pathlib import Path
ADB='/Users/tiensonqin/Library/Android/sdk/platform-tools/adb'
DEVICE='emulator-5556'
OUT=Path('/tmp/logseq-r8-blackbox'); OUT.mkdir(exist_ok=True)
def adb(*args): return subprocess.check_output([ADB,'-s',DEVICE,*args],text=True)
def shell(*args): return adb('shell',shlex.join(args))
def hierarchy():
    raw=adb('exec-out','uiautomator','dump','/dev/tty')
    OUT.joinpath('latest.xml').write_text(raw)
    start,end=raw.find('<hierarchy'),raw.rfind('</hierarchy>')
    assert start>=0 and end>=0,raw
    return ET.fromstring(raw[start:end+len('</hierarchy>')])
def node(match, timeout=15):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        root=hierarchy()
        for n in root.iter('node'):
            if match(n): return n
    raise AssertionError('Control not found; see latest.xml')
def by_id(value): return node(lambda n:n.get('resource-id')==value)
def bounds(n): return list(map(int,re.findall(r'\d+',n.get('bounds'))))
def tap(n):
    x1,y1,x2,y2=bounds(n); shell('input','tap',str((x1+x2)//2),str((y1+y2)//2))
def click(value): tap(by_id(value))
def editor(): return node(lambda n:n.get('resource-id','').startswith('field.outliner.block.'))
def replace(text):
    shell('input','keycombination','KEYCODE_CTRL_LEFT','KEYCODE_A')
    shell('input','text',text.replace(' ','%s'))
    assert editor().get('text')==text,editor().attrib
    click('button.outliner.editor.hideKeyboard')
def capture(name):
    data=subprocess.check_output([ADB,'-s',DEVICE,'exec-out','screencap','-p'])
    OUT.joinpath(name+'.png').write_bytes(data)
prefs=ET.fromstring(adb('exec-out','cat','/data/user/0/com.logseq.app/shared_prefs/logseq.xml'))
assert next(n.text for n in prefs if n.get('name')=='logseq.selectedGraphId')=='uiregression'
root=hierarchy()
for _ in range(5):
    back=next((n for n in root.iter('node') if n.get('resource-id')=='button.navigation.back'),None)
    if back is None: break
    tap(back); root=hierarchy()
by_id('pane.journals')
node(lambda n:n.get('text','').startswith('Performance row 001-01'))
# Select-all replaces text without backspacing across block boundaries.
math=node(lambda n:n.get('resource-id')=='block.rich.math.rendered')
simple_height=bounds(math)[3]-bounds(math)[1]
tap(math)
original=editor().get('text')
current=None
try:
    for name, formula in [('fraction',r'\frac{1}{\sqrt{x^2+1}}'),('summation',r'\sum_{i=1}^{n}i^2'),('invalid',r'\unknowncommand{')]:
        if current is not None:
            tap(node(lambda n:n.get('content-desc')==current or n.get('text')==current))
            editor()
        replace('$$'+formula+'$$'); current=formula
        if name=='invalid':
            node(lambda n:n.get('text')==formula)
        else:
            image=node(lambda n:n.get('resource-id')=='block.rich.math.rendered' and n.get('content-desc')==formula)
            if name=='fraction': assert bounds(image)[3]-bounds(image)[1]>simple_height*1.5
        capture(name)
        print('PASS rendered '+name,flush=True)
finally:
    if current is not None:
        tap(node(lambda n:n.get('content-desc')==current or n.get('text')==current))
        editor(); replace(original)
node(lambda n:n.get('resource-id')=='block.rich.math.rendered' and n.get('content-desc')=='x_0 + y_2 = z_2')
node(lambda n:n.get('text','').startswith('Performance row 001-01'))
node(lambda n:n.get('text','').startswith('Performance quote 001-02'))
print('PASS original formula and neighboring blocks retained',flush=True)
