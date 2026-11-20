import re,sys
zig=open(sys.argv[1]).read(); h=open(sys.argv[2]).read()
# C enums: typedef enum WGPUX { WGPUX_Name = 0x..., } WGPUX
cen={}
for m in re.finditer(r'typedef enum WGPU(\w+) \{(.*?)\} WGPU\1', h, re.S):
    d={}
    for n,v in re.findall(r'WGPU'+m.group(1)+r'_(\w+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)', m.group(2)):
        d[n.lower().replace('_','')]=int(v,0)
    cen[m.group(1)]=d
# zig enums (only plain `pub const X = enum(u32) {` - skip switch(emscripten) ones)
for m in re.finditer(r'pub const (\w+) = enum\(u32\) \{(.*?)\n\};', zig, re.S):
    name=m.group(1); body=m.group(2)
    if name not in cen: print("NO C ENUM:",name); continue
    c=cen[name]; bad=[]
    for n,v in re.findall(r'\n\s*@?"?(\w+)"?\s*=\s*(0x[0-9A-Fa-f]+|\d+)', body):
        key=n.lower().replace('_','')
        alias={'undef':'undefined','tdim1d':'1d','tdim2d':'2d','tdim3d':'3d','tvdim1d':'1d','tvdim2d':'2d','tvdim3d':'3d','tvdimcube':'cube','tvdimcubearray':'cubearray','tvdim2darray':'2darray'}
        k=alias.get(key,key)
        cv=c.get(k)
        if cv is None: cv=c.get(key)
        if cv is None: bad.append(f"{n}=missing")
        elif cv!=int(v,0): bad.append(f"{n}: zig {v} != em {hex(cv)}")
    print(("OK  " if not bad else "BAD ")+name, "; ".join(bad[:12]) + (" ..." if len(bad)>12 else ""))
