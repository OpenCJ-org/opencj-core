"""Build the approved continuous-ring ranks from editable SVG and palette sources.

Run with the project's image-venv Python. --render-only preserves manual SVG edits.
Only the ten rank images are replaced; materials, menu sizes and game logic stay intact.
"""
from pathlib import Path
import argparse, hashlib, io, json, math, struct
import cairosvg
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'assets/ranks/rings'

def spectrum(stops, t):
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if t <= b:
            u = (t-a)/(b-a)
            rgb = [round(int(ca[j:j+2],16)*(1-u)+int(cb[j:j+2],16)*u) for j in (1,3,5)]
            return '#' + ''.join(f'{v:02x}' for v in rgb)
    return stops[-1][1]

def svg_source(rank, c):
    r, w = c['radius'], c['stroke_width']
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 100 100">',
             f'<title>OpenCJ rank {rank}: {c["names"][rank-1]}</title>',
             f'<circle id="backing" cx="50" cy="50" r="{r}" fill="{c["backing_color"]}"/>',
             f'<circle id="center" cx="50" cy="50" r="{c["center_radius"]}" fill="{c["center_color"]}"/>',
             f'<circle id="track" cx="50" cy="50" r="{r}" fill="none" stroke="{c["track_color"]}" stroke-width="{w}"/>']
    if rank == 10:
        # One smooth circular alpha mask owns both boundaries. Color sectors
        # overlap inside the mask, preventing seams and polygonal outer edges.
        parts += [f'<defs><mask id="ring-mask" maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100"><circle cx="50" cy="50" r="{r}" fill="none" stroke="white" stroke-width="{w}"/></mask></defs>',
                  '<g id="spectrum" mask="url(#ring-mask)">']
        count = 720
        for i in range(count):
            t = (i+.5)/count
            a = (i/count)*2*math.pi-math.pi/2
            b = ((i+1)/count)*2*math.pi-math.pi/2+.0005
            x1,y1 = 50+60*math.cos(a),50+60*math.sin(a)
            x2,y2 = 50+60*math.cos(b),50+60*math.sin(b)
            parts.append(f'<path d="M50 50 L{x1:.5f} {y1:.5f} A60 60 0 0 1 {x2:.5f} {y2:.5f} Z" fill="{spectrum(c["spectrum_stops"],t)}"/>')
        parts.append('</g>')
    else:
        cap = w/(2*r)
        start, end = -math.pi/2+cap, -math.pi/2+rank/10*2*math.pi-cap
        x1,y1 = 50+r*math.cos(start),50+r*math.sin(start)
        x2,y2 = 50+r*math.cos(end),50+r*math.sin(end)
        large = int(end-start > math.pi)
        parts.append(f'<path id="progress" d="M{x1:.5f} {y1:.5f} A{r} {r} 0 {large} 1 {x2:.5f} {y2:.5f}" fill="none" stroke="{c["colors"][rank-1]}" stroke-width="{w}" stroke-linecap="round"/>')
    # Center by visible glyph bounds. Same font size and baseline rule for 1-10.
    font = ImageFont.truetype(c['font_file'],c['number_size']*10)
    bounds = font.getbbox(str(rank),anchor='ls'); baseline = 50-(bounds[1]+bounds[3])/20
    parts.append(f'<text id="number" x="50" y="{baseline:.3f}" text-anchor="middle" font-family="{c["font_family"]}" font-weight="700" font-size="{c["number_size"]}" fill="{c["number_color"]}">{rank}</text>')
    parts.append('</svg>')
    return '\n'.join(parts)+'\n'

def mipmaps(image):
    result=[image]
    while result[-1].width>1:
        prev=result[-1]
        # Pillow resamples RGBA through premultiplied alpha to avoid dark fringes.
        result.append(prev.resize((max(1,prev.width//2),max(1,prev.height//2)),Image.Resampling.LANCZOS))
    return result

def iwi(levels):
    data=[im.tobytes('raw','BGRA') for im in levels]
    header=b'IWi'+bytes([6,1,0])+struct.pack('<HHH',levels[0].width,levels[0].height,1)
    return header+struct.pack('<4I',*[28+sum(map(len,data[i:])) for i in range(4)])+b''.join(reversed(data))

def main():
    args=argparse.ArgumentParser(description=__doc__)
    args.add_argument('--render-only',action='store_true',help='Render manually edited SVGs without regenerating them from palette.json')
    opts=args.parse_args(); c=json.loads((ART/'palette.json').read_text())
    images=[]; manifest={'config':'palette.json','sources':{},'outputs':{},'consumers':{'challenge_tabs':28,'challenge_own_rank':26,'escape_menu':15,'scoreboard':'75% of row height, centered in its slot'}}
    for rank in range(1,11):
        source=ART/f'rank-{rank}.svg'
        if not opts.render_only:source.write_text(svg_source(rank,c))
        side=c['texture_size']; high=side*c['supersample']
        raster=cairosvg.svg2png(url=str(source),output_width=high,output_height=high)
        image=Image.open(io.BytesIO(raster)).convert('RGBA').resize((side,side),Image.Resampling.LANCZOS)
        image.save(ART/f'rank-{rank}.png'); images.append(image)
        tga=ROOT/'source/texture_source'/f'opencj_rank_{rank}.tga';image.save(tga)
        target=ROOT/'cod4/images'/f'opencj_rank_{rank}.iwi';target.write_bytes(iwi(mipmaps(image)))
        for f,group in [(source,'sources'),(ART/f'rank-{rank}.png','outputs'),(tga,'outputs'),(target,'outputs')]:
            manifest[group][str(f.relative_to(ROOT))]={'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'bytes':f.stat().st_size}
    # Actual pixel samples plus enlarged samples, without game capture.
    sheet=Image.new('RGBA',(800,340),'#171f26'); draw=ImageDraw.Draw(sheet)
    font=ImageFont.truetype(c['font_file'],14)
    for row,(size,y) in enumerate([(64,28),(28,124),(26,206),(15,272)]):
        for i,im in enumerate(images):sheet.alpha_composite(im.resize((size,size),Image.Resampling.LANCZOS),(i*78+(78-size)//2,y))
        draw.text((12,y+size+8),f'{size} px',font=font,fill='#a5b7c2')
    sheet.save(ART/'size-preview.png')
    (ART/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('Built ten rank rings: editable SVG, PNG, TGA, RGBA IWI with full mipmaps.')

if __name__=='__main__':main()
