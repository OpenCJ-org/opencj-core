"""Render approved stacked mode badges in logical HUD proportions.

Textures remain power-of-two squares; drawing is pre-scaled so rendering at
24x20 (FPS) or 16x20 (modifiers) restores normal-width type and glyphs.
Ele, split-route and bot geometry derives from Lucide 0.468.0 (ISC license).
"""
from pathlib import Path
import hashlib,json,math,struct
from PIL import Image,ImageDraw,ImageFont
ROOT=Path(__file__).resolve().parents[1]
S=32
FONT='/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
COLORS={'classic':'#80b8ff','standard':'#d9e2e7','expanded':'#efbb65','assisted':'#c7a3ff'}
def badge(name,label,kind):
    fps=name.startswith('fps_');w=24 if fps else 16
    im=Image.new('RGBA',(w*S,20*S));d=ImageDraw.Draw(im)
    color=COLORS[kind]
    d.rounded_rectangle((0,0,w*S-1,20*S-1),radius=int(.8*S),fill='#26313b')
    d.rectangle((0,0,w*S-1,int(.8*S)-1),fill=color)
    def text(value,x,y,size,fill):
        font=ImageFont.truetype(FONT,round(size*S))
        while d.textlength(value,font=font)>(w-1.7)*S:
            font=ImageFont.truetype(FONT,font.size-1)
        d.text((x*S,y*S),value,font=font,fill=fill,anchor='mm')
    if fps:
        text('FPS',w/2,6.3,5.3,color)
        text(label,w/2,15.6,4.6,'#edf2f5')
    else:
        text(label,w/2,15.9,4.5,'#edf2f5')
        scale=11.5/24;ox=(w-11.5)/2;oy=1.9
        def xy(x,y):return ((ox+x*scale)*S,(oy+y*scale)*S)
        stroke=round(2.2*scale*S)
        def line(points):
            pts=[xy(*p) for p in points];d.line(pts,fill=color,width=stroke,joint='curve')
            for x,y in pts:d.ellipse((x-stroke/2,y-stroke/2,x+stroke/2,y+stroke/2),fill=color)
        if name=='ele':
            line([(18,9),(12,3),(6,9)]);line([(12,3),(12,17)]);line([(5,21),(19,21)])
        elif name=='anypct':
            line([(16,3),(21,3),(21,8)]);line([(8,3),(3,3),(3,8)])
            arc=[(8+4*math.cos(-math.pi/4*i/12),13.7+4*math.sin(-math.pi/4*i/12)) for i in range(13)]
            line([(12,22),(12,13.7)]+arc+[(3,3)]);line([(15,9),(21,3)])
        elif name=='tas':
            line([(12,8),(12,4),(8,4)])
            a=xy(4,8);b=xy(20,20)
            d.rounded_rectangle((*a,*b),radius=2*scale*S,outline=color,width=stroke)
            for p in [[(2,14),(4,14)],[(20,14),(22,14)],[(15,13),(15,15)],[(9,13),(9,15)]]:line(p)
        elif name=='halfbeat':
            # Equal-height, side-by-side keys, with a clear gap at small sizes.
            for letter,x in [('A',1.2),('D',8.4)]:
                d.rounded_rectangle((x*S,4*S,(x+6.4)*S,11.5*S),radius=.65*S,outline=color,width=round(.6*S))
                text(letter,x+3.2,7.8,4.8,color)
    return im

def iwi(im):
    levels=[im]
    while levels[-1].width>1:
        p=levels[-1];levels.append(p.resize((p.width//2,p.height//2),Image.Resampling.LANCZOS))
    encoded=[p.tobytes('raw','BGRA') for p in levels]
    return b'IWi'+bytes([6,1,0])+struct.pack('<HHH',im.width,im.height,1)+struct.pack('<4I',*[28+sum(map(len,encoded[i:])) for i in range(4)])+b''.join(reversed(encoded))

def main():
    output=ROOT/'assets/mode-icons';output.mkdir(parents=True,exist_ok=True)
    manifest={'logical_dimensions':{'fps':[24,20],'modifier':[16,20]},'glyphs':'Lucide 0.468.0; Halfbeat original A/D keycaps','icons':{}}
    sheet=Image.new('RGBA',(960,240),'#171f26');d=ImageDraw.Draw(sheet)
    for i,(name,label,kind) in enumerate([('fps_classic','Classic','classic'),('fps_standard','Standard','standard'),('fps_any','Hax','expanded'),('ele','ELE','expanded'),('anypct','ANY%','expanded'),('halfbeat','HB','expanded'),('tas','TAS','assisted')]):
        logical=badge(name,label,kind);logical.save(output/(name+'.png'))
        texture=logical.resize((512,512),Image.Resampling.LANCZOS)
        texture.save(ROOT/'source/texture_source'/('opencj_icon_'+name+'.tga'))
        raw=iwi(texture);target=ROOT/'cod4/images'/('opencj_icon_'+name+'.iwi');target.write_bytes(raw)
        manifest['icons'][name]={'label':label,'role':kind,'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw)}
        width=24 if name.startswith('fps_') else 16
        large=logical.resize((width*4,80),Image.Resampling.LANCZOS);sheet.alpha_composite(large,(i*136+10,20))
        small=logical.resize((width*2,40),Image.Resampling.LANCZOS);sheet.alpha_composite(small,(i*136+10,120))
    sheet.save(output/'contact-sheet.png');(output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('Built seven mode badges; FPS 24x20, modifiers 16x20.')
if __name__=='__main__':main()
