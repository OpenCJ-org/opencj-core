"""Build the quieter, finer repeating minimap grid (authoritative source host)."""
from pathlib import Path
import struct
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
def build():
    image=Image.new("RGBA",(256,256),(0,0,0,0))
    # Three cells per tile instead of four: 33% larger squares.
    # A periodic soft-edged 14px line remains about a pixel wide after minimap
    # scaling. Sample across tile edges too, avoiding clipped strokes/seams.
    def line_alpha(position):
        fraction=((position+0.5)*3/256.0)%1
        distance=min(fraction,1-fraction)*256/3
        edge=max(0.0,min(1.0,(7-distance)/3))
        return round(88*edge*edge*(3-2*edge))
    for y in range(256):
        for x in range(256):
            image.putpixel((x,y),(166,181,175,max(line_alpha(x),line_alpha(y))))
    image.save(ROOT/"source/texture_source/opencj_minimapbg.tga")
    levels=[image]
    while levels[-1].width>1:
        q=levels[-1];levels.append(q.resize((q.width//2,q.height//2),Image.Resampling.LANCZOS))
    sizes=[len(q.tobytes()) for q in levels]
    header=b"IWi"+bytes([6,1,193])+struct.pack("<HHH",256,256,1)
    header+=struct.pack("<4I",*[28+sum(sizes[min(i,len(sizes)-1):]) for i in range(4)])
    (ROOT/"cod4/images/opencj_minimapbg.iwi").write_bytes(header+b"".join(q.tobytes("raw","BGRA") for q in reversed(levels)))
    print("Quiet grid: 3x3 cells; 14px feathered periodic lines; alpha 88, original material preserved.")
if __name__=="__main__":build()
