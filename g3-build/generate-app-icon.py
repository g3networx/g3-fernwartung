"""Generate approved monitor/pointer app icon using the unmodified company mark."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import hashlib, json, shutil

root = Path(__file__).resolve().parent.parent
brand = root/'res/g3-brand-original.png'
if not brand.exists():
    shutil.copyfile(root/'res/icon.png', brand)
original = Image.open(brand).convert('RGBA')
sizes = [16,20,24,32,40,48,64,128,256,512,1024]

def render(size):
    n = 1024
    image = Image.new('RGBA', (n,n))
    d = ImageDraw.Draw(image)
    d.rounded_rectangle((32,32,992,992),radius=180,fill='#0A2633')
    # Bold monitor silhouette and generous pointer survive taskbar downsampling.
    d.rounded_rectangle((140,180,850,708),radius=54,fill='white')
    d.rounded_rectangle((194,234,796,650),radius=14,fill='#0A2633')
    d.rectangle((444,690,546,804),fill='white')
    d.rounded_rectangle((340,790,650,848),radius=25,fill='white')
    mark = original.crop(original.getbbox()).resize((365,365),Image.Resampling.LANCZOS)
    image.alpha_composite(mark,((990-mark.width)//2,(880-mark.height)//2))
    d = ImageDraw.Draw(image)
    pointer=[(672,538),(680,900),(756,828),(820,938),(898,893),(834,784),(940,772)]
    d.polygon(pointer,fill='white')
    d.polygon([(702,590),(708,832),(761,777),(831,899),(858,882),(786,756),(878,749)],fill='#00B9DE')
    return image.resize((size,size),Image.Resampling.LANCZOS)

master=render(1024)
master.save(root/'res/g3-remote-app.png')
for path in ['res/icon.ico','flutter/windows/runner/resources/app_icon.ico']:
    master.save(root/path,format='ICO',sizes=[(s,s) for s in sizes if s<=256])
for path,size in [('res/icon.png',256),('res/32x32.png',32),('res/64x64.png',64),('res/128x128.png',128),('res/128x128@2x.png',256),('res/mac-icon.png',1024)]:
    render(size).save(root/path)
master.save(root/'flutter/macos/Runner/AppIcon.icns',format='ICNS')

out=root/'outputs/icon-review'
out.mkdir(parents=True,exist_ok=True)
sheet=Image.new('RGB',(1100,450),'#EDF1F5')
d=ImageDraw.Draw(sheet)
font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',22)
d.text((24,14),'D – Original-Firmenzeichen + Monitor + Mauszeiger',font=font,fill='#0A2633')
sheet.paste(render(256),(24,80),render(256))
for row,bg in [(0,'#121B24'),(1,'#F8F9FA')]:
    y=90+row*160
    d.rounded_rectangle((320,y,1070,y+125),radius=12,fill=bg)
    x=350
    for s in [16,20,24,32,48,64]:
        icon=render(s)
        sheet.paste(icon,(x,y+25+(64-s)//2),icon)
        d.text((x,y+91),str(s)+' px',font=font,fill='white' if row==0 else '#0A2633')
        x+=115
sheet.save(out/'Taskleisten-Groessen.png')
(out/'icon-provenance.json').write_text(json.dumps({'original_logo_sha256':hashlib.sha256(brand.read_bytes()).hexdigest(),'sizes':sizes,'logo_redrawn':False,'preview':'actual generated icon at native pixel sizes on light and dark backgrounds; not an OS taskbar screenshot'},indent=2))
print(out)
