"""Verify current challenge-route binding with synthetic rows rolled back at exit."""

import ast
from pathlib import Path
import re
import subprocess

from compose_environment import database_container

ROOT = Path(__file__).resolve().parents[2]
SQL_BUILDERS = {"routeKeySQL", "routeLinkSQL"}
STATEMENT = re.compile(
    r"\s*(?:(?P<assignment>[A-Za-z_]\w*)\s*=|(?P<return>return)\b)\s*"
    r'(?P<expression>(?:"(?:[^"\\]|\\.)*"|[^;])+);',
    re.S,
)


def evaluate_expression(node, values, source):
    """Support only the strings, names, concatenation and SQL-builder calls in this source."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.Name):
        return values[node.id]
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return evaluate_expression(node.left, values, source) + evaluate_expression(
            node.right, values, source
        )
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        if node.func.id in SQL_BUILDERS and not node.keywords:
            arguments = [evaluate_expression(argument, values, source) for argument in node.args]
            return build_sql(source, node.func.id, arguments)
    raise ValueError("Unsupported expression in the route SQL builder")


def build_sql(source, function_name, arguments=()):
    """Read the two string-only GSC builders without depending on their local variable names."""
    function = re.search(
        r"(?ms)^" + re.escape(function_name) + r"\s*\(([^)]*)\)\s*\{(.*?)^\}", source
    )
    if not function:
        raise ValueError("SQL builder was not found: " + function_name)
    parameters = [name.strip() for name in function[1].split(",") if name.strip()]
    if len(parameters) != len(arguments):
        raise ValueError("SQL builder argument count differs: " + function_name)
    values = dict(zip(parameters, arguments))

    # Comments are ignored only outside quoted GSC strings, which contain the actual SQL.
    body = re.sub(
        r'"(?:[^"\\]|\\.)*"|//[^\n]*|/\*.*?\*/',
        lambda match: match[0] if match[0].startswith('"') else "",
        function[2],
        flags=re.S,
    )
    position = 0
    while body[position:].strip():
        statement = STATEMENT.match(body, position)
        if not statement:
            raise ValueError("Unsupported statement in SQL builder: " + function_name)
        expression = ast.parse("(" + statement["expression"] + ")", mode="eval").body
        value = evaluate_expression(expression, values, source)
        position = statement.end()
        if statement["return"]:
            if body[position:].strip():
                raise ValueError("Unexpected statements after SQL return: " + function_name)
            return value
        values[statement["assignment"]] = value
    raise ValueError("SQL builder has no return: " + function_name)


# MySQL cannot reopen temporary tables in one statement. These unique fixture
# rows stay inside one transaction; normal completion and connection loss roll it back.
FIXTURE_SETUP = """
START TRANSACTION;
INSERT INTO mapids(mapID,mapname) VALUES
(-8106,'shop_route_test_moon'),
(-8107,'shop_route_test_blue'),
(-8110,'shop_route_test_ambiguous'),
(-8101,'shop_route_test_one'),
(-8102,'shop_route_test_two'),
(-8103,'shop_route_test_hard'),
(-8104,'shop_route_test_labels');
INSERT INTO checkpoints(cpID,mapID) VALUES
(-8106,-8106),
(-8107,-8106),
(-8108,-8106),
(-8109,-8107),
(-8110,
 -8110),
(-8111,
 -8110),
(-8112,
 -8110),
(-8101,
 -8101),
(-8102,-8102),
(-8103,-8102),
(-8104,-8103),
(-8105,-8104);
INSERT INTO routes(routeID,mapID,cpID,routeName) VALUES
(-8106,-8106,-8106,'basic'),
(-8107,-8106,-8107,'INTERMEDIATE'),
(-8108,-8106,-8108,'advanced'),
(-8109,-8107,-8109,'inter'),
(-8110,
 -8110,
 -8110,'inter'),
(-8111,
 -8110,-8111,'intermediate'),
(-8112,
 -8110,-8112,'normal'),
(-8101,
 -8101,
 -8101,'normal'),
(-8102,-8102,-8102,'normal'),
(-8103,-8102,-8103,'other'),
(-8104,-8103,-8104,'easy'),
(-8105,-8104,-8105,'fungal_hazards');
UPDATE checkpoints SET finishRouteID=cpID WHERE cpID IN (
 -8106,-8107,-8108,-8109,
 -8110,-8111,-8112,
 -8101,-8102,-8103,-8104,-8105);
INSERT INTO checkpointAreas(cpID,mapID,draftName,ordinal,vertices) VALUES
(-8106,-8106,'basic',1,''),
(-8107,-8106,'INTERMEDIATE',1,''),
(-8108,-8106,'advanced',1,''),
(-8109,-8107,'inter',1,''),
(-8110,
 -8110,'inter',1,''),
(-8111,
 -8110,'intermediate',1,''),
(-8112,
 -8110,'normal',1,''),
(-8101,
 -8101,'normal',1,''),
(-8102,-8102,'normal',1,''),
(-8103,-8102,'other',1,''),
(-8104,-8103,'easy',1,''),
(-8105,-8104,'normal',1,'');
INSERT INTO challenges(challengeKey,tier,points,mapID,routeLabel) VALUES
('route.test.ambiguous',1,10,
 -8110,'Intermediate'),
('route.test.ambiguousmain',1,10,
 -8110,'Main route'),
('route.test.basic',1,10,-8106,'Basic'),
('route.test.intermediate',2,20,-8106,'Intermediate'),
('route.test.advanced',3,30,-8106,'Advanced'),
('route.test.blueinter',2,20,-8107,'Intermediate'),
('route.test.one',1,10,
 -8101,'Main route'),
('route.test.timed',10,100,
 -8101,'Main route'),
('route.test.two',1,10,-8102,'Main route'),
('route.test.exact',1,10,-8102,'Other'),
('route.test.hard',1,10,-8103,'Hard'),
('route.test.labels',1,10,-8104,'Main route'),
('route.test.spaces',1,10,-8104,'Fungal Hazards'),
('route.test.labels2',1,10,-8104,'Hard');
"""

FIXTURE_RESULT = """;
SELECT c.challengeKey,COALESCE(r.routeName,'NULL')
FROM challenges c
LEFT JOIN routes r USING(routeID)
WHERE c.challengeKey LIKE 'route.test.%'
ORDER BY c.challengeKey;
ROLLBACK;
"""

EXPECTED_ROUTES = {
    "route.test.ambiguous": "NULL",
    "route.test.ambiguousmain": "NULL",
    "route.test.basic": "basic",
    "route.test.intermediate": "INTERMEDIATE",
    "route.test.advanced": "advanced",
    "route.test.blueinter": "inter",
    "route.test.one": "normal",
    "route.test.timed": "normal",
    "route.test.two": "NULL",
    "route.test.exact": "other",
    "route.test.hard": "NULL",
    "route.test.labels": "NULL",
    "route.test.labels2": "NULL",
    "route.test.spaces": "fungal_hazards",
}


def fixture_sql():
    source = (ROOT / "server-gsc/opencj/challenges.gsc").read_text()
    return FIXTURE_SETUP + build_sql(source, "routeLinkSQL") + FIXTURE_RESULT


def main():
    result = subprocess.run(
        [
            "docker",
            "exec",
            "-i",
            database_container(),
            "sh",
            "-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root openCJ_cod4',
        ],
        input=fixture_sql(),
        text=True,
        capture_output=True,
        timeout=60,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)
    actual = dict(line.split("\t") for line in result.stdout.strip().splitlines())
    assert actual == EXPECTED_ROUTES, (actual, EXPECTED_ROUTES)
    print("CHALLENGE ROUTE SQL PASS:", len(EXPECTED_ROUTES), "rolled-back route scenarios")


if __name__ == "__main__":
    main()
