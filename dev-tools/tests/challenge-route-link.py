from compose_environment import database_container
from pathlib import Path
import ast
import re
import subprocess

root = Path(__file__).resolve().parents[2]
s = (root / 'server-gsc/opencj/challenges.gsc').read_text()
body = s[s.index('routeLinkSQL()\n{') : s.index('onRoutesPublished()')]
normalizer = s[s.index('routeKeySQL(value)\n{') : s.index('// Ambiguous normalized')]


def evaluate(n, env):
    if isinstance(n, ast.Constant) and isinstance(n.value, str):
        return n.value
    if isinstance(n, ast.Name):
        return env[n.id]
    if isinstance(n, ast.BinOp) and isinstance(n.op, ast.Add):
        return evaluate(n.left, env) + evaluate(n.right, env)
    if isinstance(n, ast.Call) and n.func.id == 'routeKeySQL':
        local = {'value': evaluate(n.args[0], env)}
        local['key'] = expression(re.search(r'key=(.+);', normalizer).group(1), local)
        return expression(re.search(r'return (.+);', normalizer).group(1), local)
    raise ValueError('Unexpected SQL expression')


def expression(text, env):
    return evaluate(ast.parse(text, mode='eval').body, env)


published = expression(re.search(r'published=(.+);', body).group(1), {})
link = expression(re.search(r'return (.+);', body).group(1), {'published': published})
# MySQL cannot reopen temporary tables in a statement. Use isolated persistent
# fixtures inside a transaction, rolled back whether validation succeeds or fails.
sql = (
    """START TRANSACTION;
INSERT INTO mapids(mapID,mapname) VALUES(-8106,'shop_route_test_moon'),(-8107,'shop_route_test_blue'),(-8110,'shop_route_test_ambiguous'),(-8101,'shop_route_test_one'),(-8102,'shop_route_test_two'),(-8103,'shop_route_test_hard'),(-8104,'shop_route_test_labels');
INSERT INTO checkpoints(cpID,mapID) VALUES(-8106,-8106),(-8107,-8106),(-8108,-8106),(-8109,-8107),(-8110,-8110),(-8111,-8110),(-8112,-8110),(-8101,-8101),(-8102,-8102),(-8103,-8102),(-8104,-8103),(-8105,-8104);
INSERT INTO routes(routeID,mapID,cpID,routeName) VALUES(-8106,-8106,-8106,'basic'),(-8107,-8106,-8107,'INTERMEDIATE'),(-8108,-8106,-8108,'advanced'),(-8109,-8107,-8109,'inter'),(-8110,-8110,-8110,'inter'),(-8111,-8110,-8111,'intermediate'),(-8112,-8110,-8112,'normal'),(-8101,-8101,-8101,'normal'),(-8102,-8102,-8102,'normal'),(-8103,-8102,-8103,'other'),(-8104,-8103,-8104,'easy'),(-8105,-8104,-8105,'fungal_hazards');
UPDATE checkpoints SET finishRouteID=cpID WHERE cpID IN (-8106,-8107,-8108,-8109,-8110,-8111,-8112,-8101,-8102,-8103,-8104,-8105);
INSERT INTO checkpointAreas(cpID,mapID,draftName,ordinal,vertices) VALUES(-8106,-8106,'basic',1,''),(-8107,-8106,'INTERMEDIATE',1,''),(-8108,-8106,'advanced',1,''),(-8109,-8107,'inter',1,''),(-8110,-8110,'inter',1,''),(-8111,-8110,'intermediate',1,''),(-8112,-8110,'normal',1,''),(-8101,-8101,'normal',1,''),(-8102,-8102,'normal',1,''),(-8103,-8102,'other',1,''),(-8104,-8103,'easy',1,''),(-8105,-8104,'normal',1,'');
INSERT INTO challenges(challengeKey,tier,points,mapID,routeLabel) VALUES
('route.test.ambiguous',1,10,-8110,'Intermediate'),
('route.test.ambiguousmain',1,10,-8110,'Main route'),
('route.test.basic',1,10,-8106,'Basic'),
('route.test.intermediate',2,20,-8106,'Intermediate'),
('route.test.advanced',3,30,-8106,'Advanced'),
('route.test.blueinter',2,20,-8107,'Intermediate'),
('route.test.one',1,10,-8101,'Main route'),
('route.test.timed',10,100,-8101,'Main route'),
('route.test.two',1,10,-8102,'Main route'),
('route.test.exact',1,10,-8102,'Other'),
('route.test.hard',1,10,-8103,'Hard'),
('route.test.labels',1,10,-8104,'Main route'),
('route.test.spaces',1,10,-8104,'Fungal Hazards'),
('route.test.labels2',1,10,-8104,'Hard');
"""
    + link
    + """;
SELECT c.challengeKey,COALESCE(r.routeName,'NULL') FROM challenges c LEFT JOIN routes r USING(routeID) WHERE c.challengeKey LIKE 'route.test.%' ORDER BY c.challengeKey;
ROLLBACK;
"""
)
out = subprocess.check_output(
    [
        'docker',
        'exec',
        '-i',
        database_container(),
        'sh',
        '-c',
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root openCJ_cod4',
    ],
    input=sql,
    text=True,
)
actual = dict(line.split('\t') for line in out.strip().splitlines())
expected = {
    'route.test.ambiguous': 'NULL',
    'route.test.ambiguousmain': 'NULL',
    'route.test.basic': 'basic',
    'route.test.intermediate': 'INTERMEDIATE',
    'route.test.advanced': 'advanced',
    'route.test.blueinter': 'inter',
    'route.test.one': 'normal',
    'route.test.timed': 'normal',
    'route.test.two': 'NULL',
    'route.test.exact': 'other',
    'route.test.hard': 'NULL',
    'route.test.labels': 'NULL',
    'route.test.labels2': 'NULL',
    'route.test.spaces': 'fungal_hazards',
}
assert actual == expected, (actual, expected)
print(
    'PASS: single generic route, timed variant, exact match, ambiguous routes and difficulty safeguards'
)

# Stable keys retain earned completions when menu labels change.
for key, label in [
    ("to_the_moon.easy", "Basic"),
    ("to_the_moon.inter", "Intermediate"),
    ("to_the_moon.advanced", "Advanced"),
    ("blue2.inter", "Intermediate"),
]:
    assert re.search(
        r'add\("' + re.escape(key) + r'",\d+,"[^" ]+","' + label + r'"\)',
        (root / "server-gsc/opencj/challenges.gsc").read_text(),
    ), key
print("PASS: corrected route labels retain permanent challenge keys")
