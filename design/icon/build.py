"""Regenerate Mailpipe icon rasters from the SVGs in this directory.

Requires cairosvg. Writes PNGs, AppIcon.icns, and the design appiconset here,
then copies the Xcode catalog into Mailpipe/Assets.xcassets.
"""
import math, json, os, struct, shutil
from pathlib import Path
import cairosvg
OUT = Path(__file__).resolve().parent
REPO = OUT.parents[1]
# ---------- glyph geometry (centerline, 1024 space, pre-translation) ----------
def qpts(p0,c,p1,n=200):
    return [((1-t)**2*p0[0]+2*(1-t)*t*c[0]+t*t*p1[0],(1-t)**2*p0[1]+2*(1-t)*t*c[1]+t*t*p1[1]) for t in [i/n for i in range(n+1)]]
def rounded(points, radii):
    """points: list; radii: per-vertex d (0 for endpoints). returns (svg path commands, sampled pts)"""
    cmds=[];samp=[]
    def unit(a,b):
        dx,dy=b[0]-a[0],b[1]-a[1];l=math.hypot(dx,dy);return dx/l,dy/l
    for i,p in enumerate(points):
        d=radii[i]
        if d==0:
            cmds.append(('M' if i==0 else 'L',[p])); samp.append(p); continue
        u1=unit(p,points[i-1]);u2=unit(p,points[i+1])
        a=(p[0]+u1[0]*d,p[1]+u1[1]*d);b=(p[0]+u2[0]*d,p[1]+u2[1]*d)
        cmds.append(('L',[a]));cmds.append(('Q',[p,b]))
        samp+=qpts(a,p,b)
    return cmds,samp
def fmt(v): return ('%.2f'%v).rstrip('0').rstrip('.')
def build_glyph(w, W=480,H=320,a=76,rc=60,dv=30,dl=26):
    L,R,T,B=0.0,float(W),0.0,float(H)
    cx=(L+R)/2; V=T+0.60*H
    cq=qpts((R-rc,T),(R,T),(R,T+rc),400)
    st=None
    for i in range(0,1001):
        t=i/1000; px=cx+(R-cx)*t; py=V+(T-V)*t
        if min(math.hypot(px-qx,py-qy) for qx,qy in cq)<1.0: st=(px,py);break
    pts=[st,(cx,V),(L,T),(R,T),(R,B),(L,B)]
    rad=[0,dv,dl,rc,rc,0]
    cmds,samp=rounded(pts,rad)
    # leftmost centerline of the envelope (top-left rounded corner) -> arrow tip x
    Lm=min(x for x,y in samp[:-1]) 
    # fix tip to Lm: replace last point
    pts[-1]=(Lm,B)
    cmds,samp=rounded(pts,rad)
    tip=(Lm,B)
    arrow=[(Lm+a,B-a),tip]
    asamp=arrow
    allp=samp+asamp
    minx=min(p[0] for p in allp);maxx=max(p[0] for p in allp)
    miny=min(p[1] for p in allp);maxy=max(p[1] for p in allp)
    return dict(cmds=cmds,arrow=arrow,bbox=(minx,miny,maxx,maxy),tip=tip,Lm=Lm,w=w)
def path_d(g,dx,dy):
    s=''
    for c,ps in g['cmds']:
        s+=c+' '+' '.join('%s %s'%(fmt(x+dx),fmt(y+dy)) for x,y in ps)+' '
    a=g['arrow']
    s+='M '+'L '.join('%s %s '%(fmt(x+dx),fmt(y+dy)) for x,y in a)
    return s.strip()
def glyph_svg_path(g, cx, cy, color, scale=1.0):
    minx,miny,maxx,maxy=g['bbox']
    gx=(minx+maxx)/2; gy=(miny+maxy)/2
    return '<path d="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linecap="round" stroke-linejoin="round"/>'%(path_d(g,cx-gx,cy-gy),color,fmt(g['w']))
# ---------- squircle (continuous corner, smoothing 0.6, r=185) ----------
def squircle(x0,y0,size,r=185.0,sm=0.6):
    p=(1+sm)*r
    arcMeasure=90*(1-sm)
    arcLen=math.sin(math.radians(arcMeasure/2))*r*math.sqrt(2)
    alpha=(90-arcMeasure)/2
    p3p4=r*math.tan(math.radians(alpha/2))
    beta=45*sm
    c=p3p4*math.cos(math.radians(beta)); d=c*math.tan(math.radians(beta))
    b=(p-arcLen-c-d)/3; a=2*b
    # corner relative segments, heading +x then turning to +y (top-right corner)
    seg=[('c',[(a,0),(a+b,0),(a+b+c,d)]),('a',[(arcLen,arcLen)]),('c',[(d,c),(d,b+c),(d,a+b+c)])]
    # NOTE: second cubic in figma: c d c d b+c d a+b+c -> controls (d,c),(d,b+c) end (d,a+b+c)
    x1=x0+size;y1=y0+size
    def rot(v,k):
        for _ in range(k): v=(-v[1],v[0])
        return v
    out='M %s %s '%(fmt(x0+p),fmt(y0))
    out+='L %s %s '%(fmt(x1-p),fmt(y0))
    for k in range(4):
        for t,vs in seg:
            if t=='c':
                out+='c '+' '.join('%s %s'%tuple(fmt(q) for q in rot(v,k)) for v in vs)+' '
            else:
                v=rot(vs[0],k)
                out+='a %s %s 0 0 1 %s %s '%(fmt(r),fmt(r),fmt(v[0]),fmt(v[1]))
        # straight edge after corner k
        L_=size-2*p
        e=rot((0,L_),k)  # direction after corner: +y for k=0, -x for 1, -y for 2, +x for 3
        if k<3: out+='l %s %s '%(fmt(e[0]),fmt(e[1]))
    return out+'Z'
BG='#111111';FG='#FFFFFF'
g=build_glyph(46)
sq=squircle(100,100,824)
minx,miny,maxx,maxy=g['bbox']
OPT_DY=0  # vertical optical offset
icon=f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <title>Mailpipe app icon</title>
  <path d="{sq}" fill="{BG}"/>
  {glyph_svg_path(g,512,512+OPT_DY,FG)}
</svg>
'''
open(f'{OUT}/icon.svg','w').write(icon)
print('glyph bbox (centerline)',g['bbox'],'Lm',g['Lm'],'w',g['w'])
# ---------- menu bar ----------
gm=build_glyph(60)
mx0,my0,mx1,my1=gm['bbox']
gw=(mx1-mx0)+gm['w'];gh=(my1-my0)+gm['w']
S=gw*18/16  # 1px padding each side at 18pt
mb=f'''<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 {fmt(S)} {fmt(S)}">
  <title>Mailpipe menu bar template icon</title>
  {glyph_svg_path(gm,S/2,S/2,'#000000')}
</svg>
'''
open(f'{OUT}/MenuBarIcon.svg','w').write(mb)
# ---------- renders ----------
def render(svg,px,path):
    cairosvg.svg2png(bytestring=svg.encode(),write_to=path,output_width=px,output_height=px)
ais=f'{OUT}/AppIcon.appiconset';os.makedirs(ais,exist_ok=True)
gs=build_glyph(60)
icon_small=icon.replace(glyph_svg_path(g,512,512+OPT_DY,FG),glyph_svg_path(gs,512,512+OPT_DY,FG))
assert icon_small!=icon
os.makedirs(OUT / 'png', exist_ok=True)
for px in (16,32,64,128,256,512,1024): render(icon_small if px<=32 else icon,px,f'{OUT}/png/icon_{px}.png')
spec=[(16,1,16),(16,2,32),(32,1,32),(32,2,64),(128,1,128),(128,2,256),(256,1,256),(256,2,512),(512,1,512),(512,2,1024)]
images=[];
for pt,sc,px in spec:
    fn=f'icon_{pt}x{pt}'+('@2x' if sc==2 else '')+'.png'
    shutil.copy(f'{OUT}/png/icon_{px}.png',f'{ais}/{fn}')
    images.append({"filename":fn,"idiom":"mac","scale":f"{sc}x","size":f"{pt}x{pt}"})
(OUT / 'AppIcon.appiconset' / 'Contents.json').write_text(json.dumps({"images":images,"info":{"author":"xcode","version":1}}, indent=2))
# icns
types={16:b'icp4',32:b'icp5',64:b'icp6',128:b'ic07',256:b'ic08',512:b'ic09',1024:b'ic10'}
extra={32:b'ic11',64:b'ic12',256:b'ic13',512:b'ic14'}  # @2x variants (16@2x,32@2x,128@2x,256@2x)
ents=[]
for px,t in types.items(): ents.append((t,open(f'{OUT}/png/icon_{px}.png','rb').read()))
for px,t in extra.items(): ents.append((t,open(f'{OUT}/png/icon_{px}.png','rb').read()))
body=b''.join(t+struct.pack('>I',len(d)+8)+d for t,d in ents)
(OUT / 'AppIcon.icns').write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
# menu bar imageset
mis=OUT / 'MenuBarIcon.imageset'
mis.mkdir(exist_ok=True)
for px,name in ((16,'MenuBarIcon_16.png'),(18,'MenuBarIcon.png'),(32,'MenuBarIcon_32.png'),(36,'MenuBarIcon@2x.png')):
    render(mb,px,str(mis / name))
    shutil.copy(mis / name, OUT / name)
menu_doc={"images":[{"filename":"MenuBarIcon.png","idiom":"universal","scale":"1x"},{"filename":"MenuBarIcon@2x.png","idiom":"universal","scale":"2x"}],
 "info":{"author":"xcode","version":1},"properties":{"template-rendering-intent":"template"}}
(mis / 'Contents.json').write_text(json.dumps(menu_doc, indent=2))
catalog = REPO / 'Mailpipe' / 'Assets.xcassets'
catalog.mkdir(parents=True, exist_ok=True)
(catalog / 'Contents.json').write_text('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
dest_icon = catalog / 'AppIcon.appiconset'
if dest_icon.exists():
    shutil.rmtree(dest_icon)
shutil.copytree(OUT / 'AppIcon.appiconset', dest_icon)
dest_menu = catalog / 'MenuBarIcon.imageset'
if dest_menu.exists():
    shutil.rmtree(dest_menu)
dest_menu.mkdir()
menu_manifest = json.loads((OUT / 'MenuBarIcon.imageset' / 'Contents.json').read_text())
(dest_menu / 'Contents.json').write_text(json.dumps(menu_manifest, indent=2))
for image in menu_manifest['images']:
    name = image.get('filename')
    if name:
        shutil.copy(OUT / 'MenuBarIcon.imageset' / name, dest_menu / name)
print('synced', catalog)
