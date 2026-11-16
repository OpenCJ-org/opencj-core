"""Compare exact before/after GSC SQL on varied synthetic tables in one session."""

from pathlib import Path
import sys
import json
import itertools
import time
import random
import re

sys.path.insert(0, str(Path(__file__).parent))
from query_sql import *


def sql_lit(v):
    if v is None:
        return 'NULL'
    if isinstance(v, int):
        return str(v)
    return "'" + v.replace("'", "''") + "'"


def verify(d):
    checks = 0
    began = time.monotonic()
    schemas = {
        'playerRuns': "runID INT PRIMARY KEY,playerID INT,mapID INT,finishcpID INT,finishTimeStamp DATETIME,archived INT,timePlayed INT,loadCount INT,saveCount INT,startTimeStamp DATETIME,FPSMode VARCHAR(3),ele INT,anyPct INT,hb INT,hardTAS INT",
        'playerSaves': "runID INT,saveNumber INT,explosiveJumps INT,FPSMode VARCHAR(3),flags INT, UNIQUE(runID,saveNumber)",
        'runLabels': "runID INT PRIMARY KEY,runLabel VARCHAR(100)",
        'checkpointStatistics': "runID INT,cpID INT,timePlayed INT,explosiveJumps INT,loadCount INT,saveCount INT,UNIQUE(runID,cpID),INDEX checkpoint_time(cpID,timePlayed,explosiveJumps,runID,loadCount,saveCount)",
        'playerDisplayNames': "playerID INT PRIMARY KEY,playerName VARCHAR(100)",
    }
    data = {k: [] for k in schemas}
    fpsvals = ['125', 'mix', 'hax']
    modes = list(itertools.product((0, 1), repeat=4))
    for i in range(240):
        owner = i % 3 + 1
        mask = modes[i % 16]
        fps = fpsvals[i % 3]
        finished = i >= 120
        stamp = '2026-01-%02d 00:%02d:%02d' % (i % 28 + 1, i // 60, i % 60)
        run = [
            i + 1,
            owner,
            7 if i % 17 else 8,
            None if not finished else 71,
            stamp if finished else None,
            int(i % 29 == 0),
            i * 41 + 100,
            i % 13,
            i % 19,
            stamp,
            fps,
            *mask,
        ]
        # Independent invalid finish fields, archived runs, no save, other map/owner.
        if i in (5, 6):
            run[3] = 71 if i == 5 else None
            run[4] = None if i == 5 else stamp
        data['playerRuns'].append(run)
        if i % 11:
            for num, oldfps, oldmask in [
                (0, '125', 0),
                (4, 'hax', 480),
                (19, fps, sum(b * x for b, x in zip((32, 64, 128, 256), mask))),
            ]:
                data['playerSaves'].append([i + 1, num, i % 7, oldfps, oldmask])
        if i % 2:
            data['runLabels'].append([i + 1, 'label ' + str(i)])
        data['checkpointStatistics'].append([i + 1, 71, i * 41 + 123, i % 7, i % 13, i % 19])
        if i % 5 == 0:
            data['checkpointStatistics'].append([i + 1, 72, i * 41 + 124, i % 7, i % 13, i % 19])
    data['playerDisplayNames'] = [[1, 'Preferred name'], [2, 'Account name'], [3, 'Third']]
    for name, ddl in schemas.items():
        d.query('DROP TABLE IF EXISTS qa_' + name + ';')
        d.query('CREATE TABLE qa_' + name + ' (' + ddl + ');')
        d.query(
            'INSERT INTO qa_'
            + name
            + ' VALUES '
            + ','.join('(' + ','.join(map(sql_lit, row)) + ')' for row in data[name])
            + ';'
        )

    def run(q):
        for name in schemas:
            q = re.sub(r'\b' + name + r'\b', 'qa_' + name, q)
        return d.query(q + ';')

    for kind in ('runs', 'leaderboard', 'hud'):
        cols = [
            'timePlayed',
            'explosiveJumps',
            'loadCount',
            'saveCount',
            'startTimeStamp' if kind == 'runs' else 'finishTimeStamp',
        ]
        for mode, fps, col, direction, offset in itertools.product(
            modes,
            ("('125')", "('125','mix')", "('125','mix','hax')"),
            cols,
            ('ASC', 'DESC'),
            (0, 2),
        ):
            fields = [col, 'timePlayed', 'explosiveJumps'] + (
                ['loadCount', 'saveCount', 'startTimeStamp'] if kind == 'runs' else []
            )
            sort = ', '.join(c + ' ' + direction for c in fields)
            opts = dict(
                player=1,
                mapid=7,
                current=10,
                cp='(71,72)',
                sort=sort,
                fps=fps,
                mode=mode,
                offset=offset,
                limit=2,
            )
            old = run(query(kind, True, **opts))
            new = run(query(kind, False, **opts))
            assert old == new, (kind, opts, old, new)
            checks += 1
        for player, mapid, cp, current in [
            (99, 7, '(71)', 0),
            (1, 99, '(NULL)', 0),
            (2, 7, '(72)', 125),
            (3, 8, '(71,72)', 10),
        ]:
            opts = dict(player=player, mapid=mapid, cp=cp, current=current)
            assert run(query(kind, True, **opts)) == run(query(kind, False, **opts)), (kind, opts)
            checks += 1
        print('EQUIVALENCE', kind, checks, flush=True)
    for mode, fps, metric, cp in itertools.product(
        modes, ('125', 'mix', 'hax'), ('time', 'rpgs'), (71, 72)
    ):
        opts = dict(runid=10, cp=cp, fps=fps, mode=mode, metric=metric)
        assert run(checkpoint_query(True, **opts)) == run(checkpoint_query(False, **opts)), opts
        checks += 1
    # Equal time/RPG records can still display different loads/dates/run IDs.
    # Keep this explicit, even though leaderboard/HUD SQL was retained after audit.
    d.query('UPDATE qa_checkpointStatistics SET timePlayed=100,explosiveJumps=2 WHERE runID>=121;')
    d.query('UPDATE qa_checkpointStatistics SET loadCount=99 WHERE cpID=72;')
    for kind in ('leaderboard', 'hud'):
        for sort in ('timePlayed ASC, explosiveJumps ASC', 'explosiveJumps DESC, timePlayed DESC'):
            for cp in ('(71)', '(71,72)'):
                opts = dict(cp=cp, current=130, sort=sort, limit=999)
                assert run(query(kind, True, **opts)) == run(query(kind, False, **opts)), (
                    kind,
                    'equal-ranking differing display fields',
                    sort,
                    cp,
                )
                checks += 1
                chosen = [row.split('\t') for row in run(query(kind, False, **opts)).splitlines()]
                if kind == 'leaderboard':
                    assert [int(row[11]) for row in chosen] == [121, 122, 123], (
                        'oldest tied run',
                        chosen,
                    )
                else:
                    assert [int(row[5]) for row in chosen] == [1, 2, 3] and [
                        int(row[4]) for row in chosen
                    ] == [3, 4, 5], ('oldest run and lowest tied checkpoint', chosen)
                assert all(int(row[0]) == 3 for row in chosen)
                checks += 1
    # Latest save fails mode/FPS: must not fall back to the older allowed save.
    # Run 3 (owner 3, hax) has an older 125 save and latest hax save.
    out = run(query('runs', False, player=3, mapid=7, fps="('125')", limit=999))
    assert all(row.split('\t')[1] != '3' for row in out.splitlines())
    checks += 1
    result = {
        'checks': checks,
        'passed': True,
        'seconds': round(time.monotonic() - began, 2),
        'coverage': 'exact GSC SQL; all 16 mode masks; all FPS inclusion sets; five sorts both ways; pages; multi-checkpoint; owners/maps; missing/archived/finished runs; latest-save filter order',
    }
    return result


if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', required=True)
    parser.add_argument('--database', required=True)
    args = parser.parse_args()
    assert args.container.startswith(('opencj-capacity-db-', 'opencj-query-'))
    assert args.database.startswith(('opencj_verify_190_', 'opencj_query_'))
    with MySQL(args.container, args.database) as db:
        print(json.dumps(verify(db)), flush=True)
