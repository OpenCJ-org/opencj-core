"""Frozen-before versus current finish-query comparisons, including exact ties."""
from pathlib import Path
import ast,random,json,sys,importlib.util,re
from query_sql import ROOT,MySQL,query
def verify(db):
 checks=0
 # Existing hand-authored sound expectations, updated only for stable route IDs.
 source=(ROOT/'dev-tools/tests/finish-sounds.py').read_text()
 source=source[:source.index("p=subprocess.run(")]
 namespace={'__file__':str(ROOT/'dev-tools/tests/finish-sounds.py')}
 exec(compile(source,'finish-sound-fixtures','exec'),namespace)
 for name,sql,expected in namespace['cases']:
  actual=db.query(sql)
  assert actual==str(expected),(name,actual,expected)
  prefix=sql[:sql.index(',finished AS')]
  old=prefix+','+query('sound',True,current=100)[5:]+';'
  assert db.query(old)==actual,(name,'old versus new')
  checks+=1
 spec=importlib.util.spec_from_file_location('records72',ROOT/'dev-tools/tests/record-notices-72.py')
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
 checks+=module.verify(db.query)
 for name,sql,*_ in module.cases():
  prefix=sql[:sql.index(',finished AS')]
  assert db.query(prefix+','+query('notice',True,current=100)[5:]+';')==db.query(sql),(name,'notice old/new')
  checks+=1
 rng=random.Random(160626)
 cols=['runID','playerID','mapID','finishcpID','finishTimeStamp','FPSMode','ele','anyPct','hb','hardTAS']
 def lit(v):
  if v is None:return 'NULL'
  return str(v) if isinstance(v,int) else "'"+v.replace("'","''")+"'"
 def cte(name,columns,rows):
  return name+' AS ('+' UNION ALL '.join('SELECT '+','.join(lit(v)+(' AS '+c if n==0 else '') for c,v in zip(columns,row)) for n,row in enumerate(rows))+')'
 for iteration in range(300):
  runs=[];stats=[]
  for id in range(1,41):
   current=id==40;pid=10 if current else rng.randrange(1,13)
   mapid=1 if current or rng.random()<.9 else 2
   cp=rng.choice([1,1,1,2,3,4])
   timestamp='2026-01-01 00:00:00' if current or rng.random()<.9 else None
   fps=rng.choice(['125','mix','hax'])
   modes=[rng.randrange(2) for _ in range(4)]
   if iteration%3==0:modes=[1]*4 if current else [0]*4;fps='hax' if current else 'mix';cp=1
   runs.append([id,pid,mapid,cp,timestamp,fps,*modes])
   if rng.random()<.97:stats.append([id,cp,rng.choice([100,100,200,300]),rng.randrange(3)])
  fixtures=[cte('playerRuns',cols,runs),
   cte('checkpoints',['cpID','finishRouteID','retired'],[[1,1,0],[2,1,0],[3,2,0],[4,1,1]]),
   cte('routes',['routeID','routeName'],[[1,'easy'],[2,'hard']]),
   cte('checkpointStatistics',['runID','cpID','timePlayed','explosiveJumps'],stats),
   cte('playerDisplayNames',['playerID','playerName'],[[i,'Synthetic '+str(i)] for i in range(1,13)])]
  prefix='WITH '+','.join(fixtures)+','
  for kind in ('sound','notice'):
   old=db.query(prefix+query(kind,True,current=40)[5:]+';')
   new=db.query(prefix+query(kind,False,current=40)[5:]+';')
   assert old==new,(kind,iteration,old,new)
   checks+=1
 return {'checks':checks,'passed':True,'randomSeed':160626,'coverage':'existing expected categories plus randomized exact ties, own repeats, distinct-opponent podium ranks, multiple/retired finishes, missing statistics, incomplete runs, FPS/mode inclusion versus exact categories'}
if __name__=='__main__':
 import argparse
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--container',required=True);p.add_argument('--database',required=True);a=p.parse_args()
 assert a.container.startswith(('opencj-capacity-db-','opencj-query-')) and a.database.startswith(('opencj_verify_190_','opencj_query_'))
 with MySQL(a.container,a.database) as db:print(json.dumps(verify(db)),flush=True)
