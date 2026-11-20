# Rewrite zgpu wgpu.zig so every enum has an Emscripten (4.0.x webgpu.h) variant with the right values.
import re,sys
zp,hp=sys.argv[1],sys.argv[2]; write = len(sys.argv)>3 and sys.argv[3]=='--write'
zig=open(zp).read(); h=open(hp).read()
cen={}
for m in re.finditer(r'typedef enum WGPU(\w+) \{(.*?)\} WGPU\1', h, re.S):
    cen[m.group(1)]={n.lower().replace('_',''):int(v,0) for n,v in re.findall(r'WGPU'+m.group(1)+r'_(\w+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)', m.group(2))}
alias={'undef':'undefined','err':'error','incrementlamp':'incrementclamp'}
def key(n):
    k=n.lower().replace('_','')
    k=re.sub(r'^t(v)?dim','',k)
    return alias.get(k,k)
def em_body(name, body):
    c=cen[name]; out=[]; bad=[]; sentinel=0x7FFF0000
    for n,v in re.findall(r'\n(\s*@?"?\w+"?)\s*=\s*(0x[0-9A-Fa-f]+|\d+),', body):
        cv=c.get(key(n.strip().strip('@"')))
        if cv is None: cv=sentinel; sentinel+=1  # Dawn-only: not in Emscripten's API
        if cv!=int(v,0): bad.append(n.strip())
        out.append(f"\n{n} = 0x{cv:08X},")
    return bad, "".join(out)
report=[]
def plain(m):
    name,body=m.group(1),m.group(2)
    if name not in cen: return m.group(0)
    bad,eb=em_body(name,body)
    if not bad: return m.group(0)
    report.append(f"patched {name}: {', '.join(bad)}")
    ind=lambda s: s.replace('\n','\n    ')
    return f"pub const {name} = switch (emscripten) {{\n    true => enum(u32) {{{ind(eb)}\n    }},\n    false => enum(u32) {{{ind(body)}\n    }},\n}};"
zig2=re.sub(r'pub const (\w+) = enum\(u32\) \{(.*?)\n\};', plain, zig, flags=re.S)
# check existing switch(emscripten) true branches
for m in re.finditer(r'pub const (\w+) = switch \(emscripten\) \{\n    true => enum\(u32\) \{(.*?)\n    \},', zig, re.S):
    name=m.group(1)
    if name not in cen: report.append(f"switched {name}: no C enum"); continue
    bad,_=em_body(name,m.group(2))
    report.append(f"switched {name}: {'OK' if not bad else 'WRONG '+', '.join(bad)}")
print("\n".join(report))
if write: open(zp,'w').write(zig2)
