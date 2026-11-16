"""Render the approved editable Competitive trophy podium; never overwrite the SVG."""
from pathlib import Path
import io,json,hashlib,struct
import cairosvg
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
ART=ROOT/'assets/ranks/competitive'
def main():
    svg=ART/'competitive.svg'
    raw=cairosvg.svg2png(url=str(svg),output_width=2048,output_height=1024)
    image=Image.open(io.BytesIO(raw)).convert('RGBA').resize((512,256),Image.Resampling.LANCZOS)
    png=ART/'competitive.png';image.save(png)
    tga=ROOT/'source/texture_source/opencj_competitive.tga';image.save(tga)
    levels=[image]
    while max(levels[-1].size)>1:
        prev=levels[-1];levels.append(prev.resize((max(1,prev.width//2),max(1,prev.height//2)),Image.Resampling.LANCZOS))
    data=[im.tobytes('raw','BGRA') for im in levels]
    header=b'IWi'+bytes([6,1,0])+struct.pack('<HHH',image.width,image.height,1)
    header+=struct.pack('<4I',*[28+sum(map(len,data[i:])) for i in range(4)])
    iwi=ROOT/'cod4/images/opencj_competitive.iwi';iwi.write_bytes(header+b''.join(reversed(data)))
    assert image.getpixel((0,0))[3]==0 and image.getpixel((511,255))[3]==0
    files=[svg,Path(__file__),png,tga,iwi]
    manifest={'texture_size':list(image.size),'mip_levels':len(levels),'supersample':4,'menu_icon_size':[64,32],'transparent_background':True,'files':{str(p.relative_to(ROOT)):{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in files}}
    (ART/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('Built final Competitive trophies: SVG master, PNG, TGA and RGBA IWI.')
if __name__=='__main__':main()
