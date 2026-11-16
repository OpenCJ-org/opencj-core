"""Exercise the production finish-ranking SQL on MySQL using read-only CTE fixtures."""
from compose_environment import database_container
from pathlib import Path
import ast, copy, json, re, subprocess
root=Path(__file__).resolve().parents[2]
source=(root/'server-gsc/opencj/finishsounds.gsc').read_text()
expr=source.split('    return "WITH finished',1)[1].split(';',1)[0]
expr='"WITH finished'+expr
# The GSC builder consists only of SQL string literals and the saved run ID.
parts=re.findall(r'"(?:[^"\\]|\\.)*"|\brunID\b',expr)
query=''.join('100' if p=='runID' else ast.literal_eval(p) for p in parts)
assert query.startswith('WITH finished AS') and query.count('100')==2
cols=['runID','playerID','mapID','finishcpID','finishTimeStamp','FPSMode','ele','anyPct','hb','hardTAS']
def run(id,pid=None,time=1000,rpg=10,cp=1,map=1,fps='mix',ele=0,anyPct=0,hb=0,tas=0,finished=True,stats=True):
    return dict(values=[id,pid if pid is not None else id,map,cp,'2026-10-05 12:00:00' if finished else None,fps,ele,anyPct,hb,tas],time=time,rpg=rpg,stats=stats)
def lit(v):return 'NULL' if v is None else str(v) if isinstance(v,int) else "'"+v.replace("'","''")+"'"
def cte(name,columns,rows):
    return name+' AS ('+' UNION ALL '.join('SELECT '+','.join(lit(v)+(' AS '+c if n==0 else '') for c,v in zip(columns,row)) for n,row in enumerate(rows))+')'
cases=[]
def case(name,others=(),current=None,expected=1,cps=None):
    runs=[current or run(100,pid=10)]+list(others)
    stats=[[r['values'][0],r['values'][3],r['time'],r['rpg']] for r in runs if r['stats']]
    fixtures=[cte('playerRuns',cols,[r['values'] for r in runs]),cte('checkpoints',['cpID','finishRouteID'],cps or [[1,'easy'],[2,'easy'],[3,'hard']]),cte('checkpointStatistics',['runID','cpID','timePlayed','explosiveJumps'],stats or [[0,0,0,0]])]
    q='WITH '+','.join(fixtures)+','+query[5:]+';'
    cases.append((name,q,expected))
better=[run(i,time=i*100,rpg=i) for i in (1,2,3)]
case('first finish')
case('fourth on both boards',better,expected=0)
case('third on time only',[run(1,time=100,rpg=1),run(2,time=200,rpg=2),run(3,time=2000,rpg=3)])
case('third on low RPG only',[run(1,time=100,rpg=1),run(2,time=200,rpg=2),run(3,time=300,rpg=20)])
case('first time but fourth low RPG',[run(i,time=2000+i,rpg=i) for i in (1,2,3)])
case('first low RPG but fourth time',[run(i,time=i*100,rpg=20) for i in (1,2,3)])
case('slower repeat of own record',[run(1,pid=10,time=500,rpg=5)],expected=0)
case('exact repeat of own record',[run(1,pid=10)],expected=0)
case('new own time record',[run(1,pid=10,time=2000,rpg=5)])
case('new own low RPG record',[run(1,pid=10,time=500,rpg=20)])
case('one position per opponent',[run(i,pid=1,time=100+i,rpg=1) for i in range(1,8)])
case('equal times use fewer RPGs',better,current=run(100,pid=10,time=300,rpg=2))
case('equal RPGs use faster time',better,current=run(100,pid=10,time=250,rpg=3))
case('exact ties retain older places',[run(i) for i in (1,2,3)],expected=0)
case('same route alternative finish',[run(i,time=i*100,rpg=i,cp=2) for i in (1,2,3)],expected=0)
case('other routes excluded',[run(i,time=i*100,rpg=i,cp=3) for i in (1,2,3)])
case('other maps excluded',[run(i,time=i*100,rpg=i,map=2) for i in (1,2,3)])
case('unfinished excluded',[run(i,time=i*100,rpg=i,finished=False) for i in (1,2,3)])
case('missing finish stats excluded',[run(i,time=i*100,rpg=i,stats=False) for i in (1,2,3)])
case('current unfinished',current=run(100,pid=10,finished=False),expected=0)
case('current missing stats',current=run(100,pid=10,stats=False),expected=0)
case('hax excluded from mix',[run(i,time=i*100,rpg=i,fps='hax') for i in (1,2,3)])
case('125 included in mix',[run(i,time=i*100,rpg=i,fps='125') for i in (1,2,3)],expected=0)
case('mix excluded from 125',better,current=run(100,pid=10,fps='125'))
case('mix included in hax',better,current=run(100,pid=10,fps='hax'),expected=0)
case('125 included in hax',[run(i,time=i*100,rpg=i,fps='125') for i in (1,2,3)],current=run(100,pid=10,fps='hax'),expected=0)
for mode in ['ele','anyPct','hb','tas']:
    case(mode+' disallowed runs excluded',[run(i,time=i*100,rpg=i,**{mode:1}) for i in (1,2,3)])
    case(mode+' includes clean runs',better,current=run(100,pid=10,**{mode:1}),expected=0)


def main():
    """Run the prepared ranking cases only when explicitly invoked."""
    p=subprocess.run(['docker','exec','-i',database_container(),'sh','-c','MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -N -u opencj "$1"','test','openCJ_cod4'],input='\n'.join(q for _,q,_ in cases),text=True,capture_output=True)
    if p.returncode:raise RuntimeError(p.stderr)
    results=p.stdout.splitlines();assert len(results)==len(cases),(len(results),len(cases))
    for (name,_,expected),result in zip(cases,results):
        assert result==str(expected),(name,result,expected)
        print('PASS '+name)
    print('FINISH SOUND SQL PASS:',len(cases),'read-only MySQL cases')


if __name__ == "__main__":
    main()
