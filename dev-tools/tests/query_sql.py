"""SQL extracted from authoritative GSC concatenations; frozen before-query oracle."""

from pathlib import Path
import re
import json
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'server-db/tools'))
from mysql_session import MySQL


def gsc_expression(text, values):
    parts = []
    start = 0
    quoted = False
    escaped = False
    for i, c in enumerate(text):
        if escaped:
            escaped = False
            continue
        if c == chr(92) and quoted:
            escaped = True
            continue
        if c == '"':
            quoted = not quoted
        if c == '+' and not quoted:
            parts.append(text[start:i].strip())
            start = i + 1
    parts.append(text[start:].strip())
    return ''.join(json.loads(p) if p.startswith('"') else str(values[p]) for p in parts if p)


def query(
    kind,
    before=True,
    player=1,
    cp='(1)',
    sort='timePlayed ASC, timePlayed ASC, explosiveJumps ASC',
    fps="('125','mix','hax')",
    mode=(1, 1, 1, 1),
    offset=0,
    limit=10,
    mapid=1,
    current=0,
    script_root=None,
    stable_ties=True,
):
    rel = {
        'runs': 'menus/runsboard.gsc',
        'leaderboard': 'menus/leaderboard.gsc',
        'hud': 'showrecords.gsc',
        'sound': 'finishsounds.gsc',
        'notice': 'recordnotices.gsc',
    }[kind]
    s = ((script_root or ROOT / 'server-gsc') / 'opencj' / rel).read_text()
    baseline = json.loads(
        (ROOT / 'dev-tools/tests/fixtures/query-performance-before.json').read_text()
    )
    if kind in ('sound', 'notice'):
        expr = baseline[kind] if before else re.search(r'return ("WITH finished.*?);', s, re.S)[1]
        return gsc_expression(expr, {'runID': current})
    if kind in ('runs', 'leaderboard'):
        s = s.split('\nfetchUpdatedData()\n', 1)[1]
    expr = baseline[kind] if before else re.search(r'query = ("SELECT .*?);', s, re.S)[1]
    values = {
        'sortStr': sort,
        'playerID': player,
        'finishCPIds': cp,
        'checkpointString': cp,
        'openCJ\\mapID::getMapID()': mapid,
        'self getRunStr()': (' AND pr.runID != ' + str(current)) if current else '',
        'self.currentBoard["maxEntriesPerPage"]': limit,
        'level.nrRecords': limit,
        'openCJ\\menus\\board_base::getOffsetFromPage(self.currentBoard["page"]["cur"], self.currentBoard["maxEntriesPerPage"])': offset,
        'self openCJ\\playerRuns::getRunID()': current,
        'openCJ\\menus\\board_base::getFPSModeStr(self.currentBoard["filter"]["fps"])': fps,
        'openCJ\\menus\\board_base::getFPSModeStr(self openCJ\\fps::getCurrentFPSMode())': fps,
    }
    for label, value, call in zip(
        ('ele', 'any', 'hb', 'tas'),
        mode,
        (
            'elevate::hasUsedEle',
            'anyPct::hasAnyPct',
            'halfBeat::isHalfBeatAllowed',
            'tas::hasHardTAS',
        ),
    ):
        values['self.currentBoard["filter"]["' + label + '"]'] = value
        values['self openCJ\\' + call + '()'] = value
    fl = 'getFilterStr(self.currentBoard["filter"]["ele"], self.currentBoard["filter"]["any"], self.currentBoard["filter"]["hb"], self.currentBoard["filter"]["tas"])'
    values[fl] = ''.join(
        ' AND (a.flags & ' + str(bit) + ')<=' + str(bit * value)
        for bit, value in zip((32, 64, 128, 256), mode)
    )
    sql = gsc_expression(expr, values)
    if before and stable_ties and kind in ('leaderboard', 'hud'):
        sql = sql.replace('cs.runID, cs.saveCount, (', 'cs.runID, cs.cpID, cs.saveCount, (')
        sql = sql.replace(')) AS rn', ', cs.runID ASC, cs.cpID ASC)) AS rn')
        sql = sql.replace(' LIMIT ', ', a.runID ASC, a.cpID ASC LIMIT ', 1)
    return sql


def checkpoint_query(before=True, runid=10, cp=71, fps='mix', mode=(0, 0, 0, 0), metric='time'):
    source = (
        (ROOT / 'server-gsc/opencj/recordnotices.gsc').read_text().split('checkpointQuery(', 1)[1]
    )
    expression = (
        json.loads((ROOT / 'dev-tools/tests/fixtures/query-performance-before.json').read_text())[
            'checkpoint'
        ]
        if before
        else re.search(r'return ("SELECT cs.timePlayed.*?);', source, re.S)[1]
    )
    values = {
        'runID': runid,
        'cpID': cp,
        'dbStr(fps)': "'" + fps + "'",
        'sort': (
            'cs.explosiveJumps,cs.timePlayed'
            if metric == 'rpgs'
            else 'cs.timePlayed,cs.explosiveJumps'
        ),
    }
    values.update(dict(zip(('int(ele)', 'int(any)', 'int(hb)', 'int(tas)'), mode)))
    return gsc_expression(expression, values)
