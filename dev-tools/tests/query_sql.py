"""SQL extracted from authoritative GSC concatenations; frozen before-query oracle."""

from pathlib import Path
import re
import json
import sys

TUTORIAL_SAVE_FLAG = 512  # Shared with saveposition.gsc's stored flag layout.
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server-db/tools"))
from mysql_session import MySQL

GSC_TOKEN = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[A-Za-z_]\w*|[^\s]')


def source_tokens(source):
    """Keep string literals intact and omit comments from source inspection."""
    return [
        match for match in GSC_TOKEN.finditer(source) if not match.group().startswith(("//", "/*"))
    ]


def normalize_expression(expression):
    """Ignore spacing and identifier case without changing quoted field names."""
    return " ".join(
        token.group() if token.group().startswith('"') else token.group().lower()
        for token in source_tokens(expression)
    )


def extract_sql_expression(source, sql_prefix):
    """Find one literal SQL assignment/return without depending on function layout."""
    tokens = source_tokens(source)
    candidates = []
    for index, token in enumerate(tokens):
        if token.group() == "return":
            value_index = index + 1
        elif (
            token.group() == "query"
            and index + 1 < len(tokens)
            and tokens[index + 1].group() == "="
        ):
            value_index = index + 2
        else:
            continue
        if value_index >= len(tokens):
            continue
        first_value = tokens[value_index]
        if not first_value.group().startswith('"'):
            continue
        # Adjacent literal terms may be wrapped differently without changing SQL.
        literal_prefix = json.loads(first_value.group())
        prefix_end = value_index + 1
        while prefix_end + 1 < len(tokens) and tokens[prefix_end].group() == "+":
            next_value = tokens[prefix_end + 1].group()
            if not next_value.startswith('"'):
                break
            literal_prefix += json.loads(next_value)
            prefix_end += 2
        if not " ".join(literal_prefix.split()).startswith(" ".join(sql_prefix.split())):
            continue
        for ending in tokens[value_index + 1 :]:
            if ending.group() == ";":
                candidates.append(source[first_value.start() : ending.start()])
                break
        else:
            raise ValueError("Unterminated SQL expression: " + sql_prefix)
    if len(candidates) != 1:
        raise ValueError(f"Expected one {sql_prefix!r} SQL expression, found {len(candidates)}")
    return candidates[0]


def gsc_expression(expression, values):
    """Evaluate string concatenation with explicit bindings, not arbitrary GSC."""
    bindings = {normalize_expression(name): value for name, value in values.items()}
    parts = []
    part_start = 0
    nesting = 0
    for token in source_tokens(expression):
        value = token.group()
        if value in ("(", "["):
            nesting += 1
        elif value in (")", "]"):
            nesting -= 1
        elif value == "+" and nesting == 0:
            parts.append(expression[part_start : token.start()].strip())
            part_start = token.end()
    parts.append(expression[part_start:].strip())

    result = []
    for part in parts:
        if not part:
            raise ValueError("Empty term in GSC SQL concatenation")
        tokens = source_tokens(part)
        if len(tokens) == 1 and tokens[0].group().startswith('"'):
            result.append(json.loads(tokens[0].group()))
            continue
        key = normalize_expression(part)
        if key not in bindings:
            raise ValueError("Missing fixture binding for GSC expression: " + part)
        result.append(str(bindings[key]))
    return "".join(result)


def query(
    kind,
    before=True,
    player=1,
    cp="(1)",
    sort="timePlayed ASC, timePlayed ASC, explosiveJumps ASC",
    fps="('125','mix','hax')",
    mode=(1, 1, 1, 1),
    offset=0,
    limit=10,
    mapid=1,
    current=0,
    script_root=None,
    stable_ties=True,
):
    """Bind a fixture to the historical/current production query.

    mode follows elevate, any%, halfbeat and hard TAS. cp is a parenthesized
    fixture checkpoint list; current is the excluded or just-finished run ID.
    """
    relative_script = {
        "runs": "menus/runsboard.gsc",
        "leaderboard": "menus/leaderboard.gsc",
        "hud": "showrecords.gsc",
        "sound": "finishsounds.gsc",
        "notice": "recordnotices.gsc",
    }[kind]
    source = ((script_root or ROOT / "server-gsc") / "opencj" / relative_script).read_text()
    baseline = json.loads(
        (ROOT / "dev-tools/tests/fixtures/query-performance-before.json").read_text()
    )
    if kind in ("sound", "notice"):
        expression = baseline[kind] if before else extract_sql_expression(source, "WITH finished")
        return gsc_expression(expression, {"runID": current})
    sql_prefix = "SELECT COUNT(" if kind == "runs" else "SELECT a.totalNr"
    expression = baseline[kind] if before else extract_sql_expression(source, sql_prefix)
    values = {
        "sortStr": sort,
        "sortClause": sort,
        "playerID": player,
        "finishCPIds": cp,
        "finishCheckpointIDs": cp,
        "pageSize": limit,
        "pageOffset": offset,
        "fpsModes": fps,
        "checkpointString": cp,
        "checkpointIDs": cp,
        "openCJ\\mapID::getMapID()": mapid,
        "self getRunStr()": (" AND pr.runID != " + str(current)) if current else "",
        'self.currentBoard["maxEntriesPerPage"]': limit,
        "level.nrRecords": limit,
        'openCJ\\menus\\board_base::getOffsetFromPage(self.currentBoard["page"]["cur"], self.currentBoard["maxEntriesPerPage"])': offset,
        "self openCJ\\playerRuns::getRunID()": current,
        'openCJ\\menus\\board_base::getFPSModeStr(self.currentBoard["filter"]["fps"])': fps,
        "openCJ\\menus\\board_base::getFPSModeStr(self openCJ\\fps::getCurrentFPSMode())": fps,
    }
    for label, value, call in zip(
        ("ele", "any", "hb", "tas"),
        mode,
        (
            "elevate::hasUsedEle",
            "anyPct::hasAnyPct",
            "halfBeat::isHalfBeatAllowed",
            "tas::hasHardTAS",
        ),
    ):
        values['self.currentBoard["filter"]["' + label + '"]'] = value
        values["self openCJ\\" + call + "()"] = value
    flag_filter_expression = 'getFilterStr(self.currentBoard["filter"]["ele"], self.currentBoard["filter"]["any"], self.currentBoard["filter"]["hb"], self.currentBoard["filter"]["tas"])'
    values[flag_filter_expression] = "".join(
        " AND (a.flags & " + str(bit) + ")<=" + str(bit * value)
        for bit, value in zip((32, 64, 128, 256), mode)
    )
    # Classic/Standard exclude tutorial saves; the Any category includes them.
    tutorial_filter = ""
    if "'hax'" not in fps:
        tutorial_filter = " AND (a.flags & " + str(TUTORIAL_SAVE_FLAG) + ") = 0"
    values['getTutorialFilterStr(self.currentBoard["filter"]["fps"])'] = tutorial_filter
    sql = gsc_expression(expression, values)
    if before and stable_ties and kind in ("leaderboard", "hud"):
        sql = sql.replace("cs.runID, cs.saveCount, (", "cs.runID, cs.cpID, cs.saveCount, (")
        sql = sql.replace(")) AS rn", ", cs.runID ASC, cs.cpID ASC)) AS rn")
        sql = sql.replace(" LIMIT ", ", a.runID ASC, a.cpID ASC LIMIT ", 1)
    return sql


def checkpoint_query(before=True, runid=10, cp=71, fps="mix", mode=(0, 0, 0, 0), metric="time"):
    source = (ROOT / "server-gsc/opencj/recordnotices.gsc").read_text()
    expression = (
        json.loads((ROOT / "dev-tools/tests/fixtures/query-performance-before.json").read_text())[
            "checkpoint"
        ]
        if before
        else extract_sql_expression(source, "SELECT cs.timePlayed")
    )
    values = {
        "runID": runid,
        "cpID": cp,
        "dbStr(fps)": "'" + fps + "'",
        "sort": (
            "cs.explosiveJumps,cs.timePlayed"
            if metric == "rpgs"
            else "cs.timePlayed,cs.explosiveJumps"
        ),
    }
    values.update(dict(zip(("int(ele)", "int(any)", "int(hb)", "int(tas)"), mode)))
    return gsc_expression(expression, values)
