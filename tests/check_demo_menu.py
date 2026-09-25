from pathlib import Path

root = Path(__file__).resolve().parents[2]
script = (root / "server-gsc/opencj/demos.gsc").read_text()
start = script.split("startDemo(demoID)\n{", 1)[1].split("\nisPlayingDemo()", 1)[0]
assert 'self openMenu("opencj_demo")' in start
assert 'setClientCvar("g_scriptMainMenu","opencj_demo")' in start
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
stop = script.split("stopDemo()\n{", 1)[1].split("\nonDisconnect()", 1)[0]
assert "self closeInGameMenu();" in stop
print("Exit closes both the client toolbar and the in-game menu path")
