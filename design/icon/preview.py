from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import cairosvg, io
D = Path(__file__).resolve().parent
def load(p, px=None): return Image.open(D / p).convert('RGBA')
def svg_image(path, px):
    png = cairosvg.svg2png(url=str(path), output_width=px, output_height=px)
    return Image.open(io.BytesIO(png)).convert('RGBA')
W,H=2100,1500
sheet=Image.new('RGBA',(W,H),(255,255,255,255))
d=ImageDraw.Draw(sheet)
try: f=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',26)
except: f=ImageFont.load_default()
# light and dark panels
for i,(c,tc) in enumerate([((242,242,245),(0,0,0)),((28,28,32),(255,255,255))]):
    x=i*1050;d.rectangle([x,0,x+1050,1000],fill=c)
    ic=svg_image(D / 'icon.svg', 900)
    sheet.alpha_composite(ic,(x+75,50))
    d.text((x+20,960),'1024 icon on '+('light' if i==0 else 'dark'),fill=tc,font=f)
    # small sizes
    d.rectangle([x,1000,x+1050,1500],fill=c)
    xx=x+40
    for px in (16,32,64,128):
        im=load(f'png/icon_{px}.png');sheet.alpha_composite(im,(xx,1040));d.text((xx,1040+px+8),f'{px}px',fill=tc,font=f);xx+=px+60
    # zoomed 16 and 32 (nearest x8)
    z=load('png/icon_16.png').resize((128,128),Image.NEAREST);sheet.alpha_composite(z,(x+40,1280));d.text((x+40,1415),'16px x8',fill=tc,font=f)
    z=load('png/icon_32.png').resize((128,128),Image.NEAREST);sheet.alpha_composite(z,(x+220,1280));d.text((x+220,1415),'32px x4',fill=tc,font=f)
    # menu bar strips: actual size (@1x 18 and @2x 36), template tinted
    bar=(235,235,238) if i==0 else (40,40,44);glyph=(0,0,0) if i==0 else (255,255,255)
    for j,(name,px) in enumerate((('MenuBarIcon.png',18),('MenuBarIcon@2x.png',36))):
        g=load(name);a=g.split()[3];t=Image.new('RGBA',g.size,glyph+(255,));t.putalpha(a)
        bx=x+450+j*270;d.rectangle([bx,1060,bx+240,1060+px+20],fill=bar)
        sheet.alpha_composite(t,(bx+20,1070));d.text((bx,1060+px+30),f'menu bar {px}px',fill=tc,font=f)
    # enlarged menu bar glyph
    g=load('MenuBarIcon@2x.png').resize((144,144),Image.NEAREST);a=g.split()[3];t=Image.new('RGBA',g.size,glyph+(255,));t.putalpha(a)
    sheet.alpha_composite(t,(x+450,1280));d.text((x+450,1425),'menu bar x4',fill=tc,font=f)
sheet.convert('RGB').save(D / 'preview.png')
