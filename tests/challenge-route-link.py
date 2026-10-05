from pathlib import Path
import ast,re,subprocess
root=Path(__file__).resolve().parents[2]
s=(root/'server-gsc/opencj/challenges.gsc').read_text()
body=s[s.index('routeLinkSQL()\n{'):s.index('onRoutesPublished()')]
published=re.search(r'published="([^\n]+)";',body).group(1)
expr=re.search(r'return (.+);',body).group(1)
def evaluate(n):
 if isinstance(n,ast.Constant) and isinstance(n.value,str):return n.value
 if isinstance(n,ast.Name) and n.id=='published':return published
 if isinstance(n,ast.BinOp) and isinstance(n.op,ast.Add):return evaluate(n.left)+evaluate(n.right)
 raise ValueError('Unexpected SQL expression')
link=evaluate(ast.parse(expr,mode='eval').body)
# MySQL cannot reopen temporary tables in a statement. Use isolated persistent
# fixtures inside a transaction, rolled back whether validation succeeds or fails.
sql="""START TRANSACTION;
INSERT INTO mapids(mapID,mapname) VALUES(-8101,'shop_route_test_one'),(-8102,'shop_route_test_two'),(-8103,'shop_route_test_hard'),(-8104,'shop_route_test_labels');
INSERT INTO checkpoints(cpID,mapID,ender) VALUES(-8101,-8101,'normal'),(-8102,-8102,'normal'),(-8103,-8102,'other'),(-8104,-8103,'easy'),(-8105,-8104,'normal');
INSERT INTO checkpointAreas(cpID,mapID,routeName,ordinal,vertices) VALUES(-8101,-8101,'normal',1,''),(-8102,-8102,'normal',1,''),(-8103,-8102,'other',1,''),(-8104,-8103,'easy',1,''),(-8105,-8104,'normal',1,'');
INSERT INTO challenges(challengeKey,tier,points,mapName,routeLabel) VALUES
('route.test.one',1,10,'shop_route_test_one','Main route'),
('route.test.timed',10,100,'shop_route_test_one','Main route'),
('route.test.two',1,10,'shop_route_test_two','Main route'),
('route.test.exact',1,10,'shop_route_test_two','Other'),
('route.test.hard',1,10,'shop_route_test_hard','Hard'),
('route.test.labels',1,10,'shop_route_test_labels','Main route'),
('route.test.labels2',1,10,'shop_route_test_labels','Hard');
"""+link+""";
SELECT challengeKey,COALESCE(routeName,'NULL') FROM challenges WHERE challengeKey LIKE 'route.test.%' ORDER BY challengeKey;
ROLLBACK;
"""
out=subprocess.check_output(['docker','exec','-i','opencj-dev-db-1','sh','-c','MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -N -u opencj opencj_test_cod4'],input=sql,text=True)
actual=dict(line.split('\t') for line in out.strip().splitlines())
expected={'route.test.one':'normal','route.test.timed':'normal','route.test.two':'NULL','route.test.exact':'other','route.test.hard':'NULL','route.test.labels':'NULL','route.test.labels2':'NULL'}
assert actual==expected,(actual,expected)
print('PASS: single generic route, timed variant, exact match, ambiguous routes and difficulty safeguards')
