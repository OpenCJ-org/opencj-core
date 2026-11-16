"""Read-only MySQL fixtures for production #72 exact-category comparison SQL."""

from compose_environment import database_container
from pathlib import Path
import ast
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def cases():
    source = (ROOT / "server-gsc/opencj/recordnotices.gsc").read_text()
    expr = source.split('    return "WITH finished', 1)[1].split(';', 1)[0]
    query = ''.join(
        '100' if p == 'runID' else ast.literal_eval(p)
        for p in re.findall(r'"(?:[^"\\]|\\.)*"|\brunID\b', '"WITH finished' + expr)
    )
    cols = [
        'runID',
        'playerID',
        'mapID',
        'finishcpID',
        'finishTimeStamp',
        'FPSMode',
        'ele',
        'anyPct',
        'hb',
        'hardTAS',
    ]

    def run(
        id,
        pid=1,
        time=10000,
        rpg=10,
        cp=1,
        map=1,
        fps='mix',
        ele=0,
        anyPct=0,
        hb=0,
        tas=0,
        finished=True,
        stats=True,
    ):
        return {
            'values': [
                id,
                pid,
                map,
                cp,
                '2026-11-13 12:00:00' if finished else None,
                fps,
                ele,
                anyPct,
                hb,
                tas,
            ],
            'time': time,
            'rpg': rpg,
            'stats': stats,
        }

    def lit(v):
        return (
            'NULL'
            if v is None
            else str(v) if isinstance(v, int) else "'" + v.replace("'", "''") + "'"
        )

    def cte(name, columns, rows):
        return (
            name
            + ' AS ('
            + ' UNION ALL '.join(
                'SELECT '
                + ','.join(lit(v) + (' AS ' + c if n == 0 else '') for c, v in zip(columns, row))
                for n, row in enumerate(rows)
            )
            + ')'
        )

    result = []

    def add(name, others=(), current=None, server=None, personal=None, empty=False):
        runs = [current or run(100, pid=10, time=8000, rpg=8)] + list(others)
        fixtures = [
            cte('playerRuns', cols, [x['values'] for x in runs]),
            cte(
                'checkpoints',
                ['cpID', 'finishRouteID', 'retired'],
                [[1, 1, 0], [2, 1, 0], [3, 2, 0], [4, 1, 1]],
            ),
            cte('routes', ['routeID', 'routeName'], [[1, 'easy'], [2, 'hard']]),
            cte(
                'checkpointStatistics',
                ['runID', 'cpID', 'timePlayed', 'explosiveJumps'],
                [[x['values'][0], x['values'][3], x['time'], x['rpg']] for x in runs if x['stats']]
                or [[0, 0, 0, 0]],
            ),
            cte(
                'playerDisplayNames',
                ['playerID', 'playerName'],
                [[i, 'Fixture ' + str(i)] for i in sorted({x['values'][1] for x in runs})],
            ),
        ]
        result.append(
            (name, 'WITH ' + ','.join(fixtures) + ',' + query[5:] + ';', server, personal, empty)
        )

    add('first category finish has no prior record')
    add('ordinary comparable finish', [run(1)], server=[(10000, 10)] * 2)
    add('own previous best', [run(1, pid=10)], server=[(10000, 10)] * 2, personal=[(10000, 10)] * 2)
    add(
        'separate time and RPG leaders',
        [run(1, time=6000, rpg=12), run(2, time=12000, rpg=6)],
        server=[(6000, 12), (12000, 6)],
    )
    add(
        'personal baseline differs from server',
        [run(1, time=6000, rpg=6), run(2, pid=10, time=9000, rpg=9)],
        server=[(6000, 6)] * 2,
        personal=[(9000, 9)] * 2,
    )
    add(
        'time tie uses RPG tiebreak',
        [run(1, time=6000, rpg=12), run(2, time=6000, rpg=10)],
        server=[(6000, 10)] * 2,
    )
    add(
        'RPG tie uses time tiebreak',
        [run(1, time=9000, rpg=6), run(2, time=6000, rpg=6)],
        server=[(6000, 6)] * 2,
    )
    add('alternate end on same route', [run(1, cp=2)], server=[(10000, 10)] * 2)
    for name, other in [
        ('other route', run(1, cp=3)),
        ('other map', run(1, map=2)),
        ('retired finish', run(1, cp=4)),
        ('unfinished', run(1, finished=False)),
        ('missing stats', run(1, stats=False)),
    ]:
        add(name + ' excluded', [other])
    for mode in ['ele', 'anyPct', 'hb', 'tas']:
        add(
            mode + ' relaxed cannot beat strict baseline',
            [run(1)],
            current=run(100, pid=10, time=1, **{mode: 1}),
        )
        add(mode + ' strict does not compare to relaxed baseline', [run(1, **{mode: 1})])
        add(
            mode + ' matching mode compares',
            [run(1, **{mode: 1})],
            current=run(100, pid=10, **{mode: 1}),
            server=[(10000, 10)] * 2,
        )
    for a, b in [
        ('125', 'mix'),
        ('mix', '125'),
        ('125', 'hax'),
        ('hax', '125'),
        ('mix', 'hax'),
        ('hax', 'mix'),
    ]:
        add(
            a + ' vs ' + b + ' separate FPS categories',
            [run(1, fps=a)],
            current=run(100, pid=10, fps=b),
        )
    add(
        'combined mode exact match',
        [run(1, anyPct=1, hb=1)],
        current=run(100, pid=10, anyPct=1, hb=1),
        server=[(10000, 10)] * 2,
    )
    add(
        'combined mode partial overlap excluded',
        [run(1, anyPct=1)],
        current=run(100, pid=10, anyPct=1, hb=1),
    )
    add(
        'current unfinished gives no announcement',
        current=run(100, pid=10, finished=False),
        empty=True,
    )
    add(
        'current missing stats gives no announcement',
        current=run(100, pid=10, stats=False),
        empty=True,
    )
    add('current retired finish gives no announcement', current=run(100, pid=10, cp=4), empty=True)
    return result


def verify(sql):
    checks = 0
    for name, query, server, personal, empty in cases():
        text = sql(query)
        rows = [x.split('\t') for x in text.splitlines()] if text else []
        assert len(rows) == (0 if empty else 4), (name, rows)
        if not empty:
            expected = (server or [(None, None)] * 2) + (personal or [(None, None)] * 2)
            actual = [tuple(None if x == 'NULL' else int(x) for x in row[10:12]) for row in rows]
            assert actual == expected, (name, actual, expected)
        checks += 1
    return checks


if __name__ == '__main__':

    def sql(query):
        p = subprocess.run(
            [
                'docker',
                'exec',
                '-i',
                database_container(),
                'sh',
                '-c',
                'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -N -u opencj openCJ_cod4',
            ],
            input=query,
            text=True,
            capture_output=True,
        )
        assert p.returncode == 0, p.stderr
        return p.stdout.strip()

    print('NOTIFICATION SQL PASS', verify(sql))
