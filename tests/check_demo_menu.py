from pathlib import Path

root = Path(__file__).resolve().parents[2]
script = (root / "server-gsc/opencj/demos.gsc").read_text()
start = script.split("startDemo(demoID)\n{", 1)[1].split("\nisPlayingDemo()", 1)[0]
assert 'menu="opencj_demo";' in start and 'self openMenu(menu)' in start
assert 'setClientCvar("g_scriptMainMenu",menu)' in start
assert 'self demoUpdateOverlay();' in start
assert 'opencj_demo.menu' in (root / "client-mod/cod4/ui_mp/ingame.txt").read_text()
assert 'opencj_demo.menu' in (root / "client-mod/cod4/mod.csv").read_text()
assert 'scriptMenuResponse "opened"' in (root / "client-mod/cod4/ui_mp/scriptmenus/opencj_demo.menu").read_text()
print("Demo menu startup and asset registration checks passed")

import re
menu = (root / "client-mod/cod4/ui_mp/scriptmenus/opencj_demo.menu").read_text()
for response in re.findall(r'scriptMenuResponse "([^"]+)"', menu):
    assert not any(c.isspace() for c in response), response
print("All menu responses fit the engine single-token protocol")

assert 'scriptMenuResponse "stop"; close self;' in menu
stop = script.split("stopDemo(loadClipSave)\n{", 1)[1].split("\nonDisconnect()", 1)[0]
assert "self closeInGameMenu();" in stop
print("Exit closes both the client toolbar and the in-game menu path")

# Direction and speed form independent controls with explicit selected states.
responses=re.findall(r'scriptMenuResponse "([^"]+)"',menu)
assert sorted(set(r for r in responses if r.startswith("speed_")))==[
    "speed_0.25","speed_0.5","speed_1","speed_2","speed_4"]
assert responses.count("direction")==2
assert all(text in menu for text in ['text "Slowest"','text "Slow"','text "Normal"','text "Fast"','text "Fastest"','Normal: 1x (default)'])
assert menu.count('visible when (dvarFloat("opencj_demo_speed") ==')==5
assert '<4x' not in menu and '4x>' not in menu
print("Independent direction, five named speeds, Normal default and selected-state checks passed")


def items(source):
    result={}
    for match in re.finditer(r'\bitemDef\s*\{',source):
        i=match.end();start=i;depth=1;quoted=False
        while depth:
            c=source[i]
            if c=='"':quoted=not quoted
            elif not quoted:
                if c=="{":depth+=1
                elif c=="}":depth-=1
            i+=1
        block=source[start:i-1]
        name=re.search(r'\bname\s+"?([^\s"]+)',block).group(1)
        rect=tuple(map(float,re.search(r'\brect\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)',block).groups()))
        origin=re.search(r'\borigin\s+([-\d.]+)\s+([-\d.]+)',block)
        if origin:rect=(rect[0]+float(origin[1]),rect[1]+float(origin[2]),rect[2],rect[3])
        text=re.search(r'\btext\s+"([^"]*)"',block)
        result[name]={"rect":rect,"text":text[1] if text else None,"block":block}
    return result

def check_layout(source):
    controls=items(source)
    assert controls["toolbar"]["rect"]==(0,443,640,37),"Restore the original bar height"
    names=["previous","pause","resume","next","direction_forward","direction_reverse","exit"]
    speeds=[n for n in controls if n.startswith("speed_")]
    assert len(speeds)==10,"Five speed choices, each with selected/unselected states"
    names+=speeds
    # The stock linker parses origin offsets as integers (449.5 -> 449).
    row_y=controls["pause"]["rect"][1]
    assert row_y in (449,449.5)
    for name in names:
        control=controls[name];x,y,w,h=control["rect"]
        assert y+h/2==461.5 and 8<=x and x+w<=632,(name,control["rect"])
        if name not in ("previous","pause","resume","next"):assert control["text"],name+" must own its visible label"
        assert re.search(r'\btype\s+(?:ITEM_TYPE_BUTTON|1)\b',control["block"]),name
    pairs={frozenset(["pause","resume"]),frozenset(["direction_forward","direction_reverse"])}
    pairs.update(frozenset([name,name+"_selected"]) for name in speeds if not name.endswith("_selected"))
    assert controls["exit"]["text"]=="X" and controls["exit"]["rect"]==(606,450.5,26,22)
    # Visual bounds were calibrated from a supplied 3x in-game screenshot.
    # Raw texture rectangles are deliberately offset: they include padding.
    glyphs={"previous_bar":(15.5,458.5,2,8),"previous_arrow":(17.5,456.5,12,12),
        "next_bar":(80.5,458.5,2,8),"next_arrow":(68.5,456.5,12,12),
        "pause_bar_left":(45,458.5,3,8),"pause_bar_right":(50,458.5,3,8),
        "resume_arrow":(43,456.5,12,12)}
    for name,rect in glyphs.items():
        assert controls[name]["rect"]==rect and "decoration" in controls[name]["block"],name
        if name.startswith(("previous_","next_")):
            assert controls[name+"_disabled"]["rect"]==rect
    for name in speeds+["direction_forward","direction_reverse"]:
        block=controls[name]["block"]
        assert re.search(r"textalignx\s+-1(?:\s|$)",block),name
        assert re.search(r"textaligny\s+-1.5(?:\s|$)",block),name
    assert re.search(r"textaligny\s+17.5",controls["status"]["block"])
    assert re.search(r"textalignx\s+-0.5",controls["exit"]["block"])
    # Status must retain its own space; invisible counterparts are the only overlap.
    names+=["status"]
    for i,a in enumerate(names):
        ax,ay,aw,ah=controls[a]["rect"]
        for b in names[i+1:]:
            bx,by,bw,bh=controls[b]["rect"]
            if max(ax,bx)<min(ax+aw,bx+bw) and max(ay,by)<min(ay+ah,by+bh):
                assert frozenset([a,b]) in pairs and controls[a]["rect"]==controls[b]["rect"],(a,b)
    assert not any(name.startswith(("label_","multiplier_","selected_")) for name in controls),"No detached speed labels or overlay cards"
    print("37-unit single-row geometry: transport, time, direction, speeds and Exit fit without overlap; screenshot-calibrated glyph offsets, time baseline and red X preserved")

check_layout(menu)
if __name__=="__main__":
    import sys
    if len(sys.argv)>1:
        check_layout(Path(sys.argv[1]).read_text())
        print("Compiled menu geometry checked")
