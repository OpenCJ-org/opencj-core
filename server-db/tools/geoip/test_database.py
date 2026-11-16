"""Run inside the updater image against an isolated, disposable GeoIP schema."""
from pathlib import Path
import importlib.util,ipaddress,json,sqlite3
spec=importlib.util.spec_from_file_location("geoip",Path("/source/update.py"))
geo=importlib.util.module_from_spec(spec);spec.loader.exec_module(geo)
db=geo.connect()
def value(sql):
    with db.cursor() as c:c.execute(sql);row=c.fetchone()
    db.rollback();return row[0]
def lookup(ip):return value("SELECT geoIPLookupCode(INET_ATON('"+ip+"'))")
def fixture(offset=0):
    cache=sqlite3.connect(":memory:");cache.execute("CREATE TABLE ranges(start INTEGER PRIMARY KEY,end INTEGER,country TEXT)")
    for start,end,code in [('8.8.8.0','8.8.8.7','US'),('8.8.8.16','8.8.8.31','GB')]:
        cache.execute("INSERT INTO ranges VALUES(?,?,?)",(int(ipaddress.ip_address(start)),int(ipaddress.ip_address(end)),code))
    meta={'ranges':2,'addresses':24,'sha256':str(offset)*64}
    return cache,meta
assert lookup('8.8.8.0')=='database_unavailable'
assert lookup('127.0.0.1')=='non_public_ip'
cache,meta=fixture(1)
first=geo.publish(db,cache,meta,'fixture','2026-01');assert first['changed']
for ip,expected in [('8.8.8.0','US'),('8.8.8.7','US'),('8.8.8.8','range_not_found'),('8.8.8.15','range_not_found'),('8.8.8.16','GB'),('8.8.8.31','GB'),('8.8.8.32','range_not_found'),('1.0.0.1','range_not_found')]:assert lookup(ip)==expected,(ip,lookup(ip))
for ip in ['0.1.2.3','10.2.3.4','100.64.0.1','127.0.0.1','169.254.2.3','172.16.1.2','192.0.0.1','192.0.2.3','192.168.0.1','198.18.0.1','198.51.100.3','203.0.113.7','224.0.0.1','255.255.255.255']:
    assert lookup(ip)=='non_public_ip',ip
assert lookup('192.0.0.9')=='range_not_found'
assert value("SELECT geoIPLookupCode(NULL)")=='invalid_ip'
assert value("SELECT getCountry(INET_ATON('8.8.8.8'))") is None
assert value("SELECT getCountry(INET_ATON('8.8.8.16'))")=='GBUnited Kingdom'
assert not geo.publish(db,cache,meta,'fixture','2026-01')['changed']
second_cache,second_meta=fixture(2)
class BrokenCursor:
    def __init__(self,cursor):self.cursor=cursor
    def __enter__(self):self.cursor.__enter__();return self
    def __exit__(self,*args):return self.cursor.__exit__(*args)
    def execute(self,sql,*args):
        if sql.startswith('UPDATE geoIPState'):raise RuntimeError("injected publication failure")
        return self.cursor.execute(sql,*args)
    def __getattr__(self,name):return getattr(self.cursor,name)
class BrokenConnection:
    def cursor(self):return BrokenCursor(db.cursor())
    def rollback(self):return db.rollback()
    def commit(self):return db.commit()
try:geo.publish(BrokenConnection(),second_cache,second_meta,'fixture','2026-02')
except RuntimeError:pass
else:raise AssertionError("injected failure did not fail")
assert value("SELECT activeReleaseID FROM geoIPState")==first['release']
assert value("SELECT COUNT(*) FROM geoIPReleases")==1
assert lookup('8.8.8.16')=='GB'
second=geo.publish(db,second_cache,second_meta,'fixture','2026-02')
assert second['changed'] and value("SELECT COUNT(*) FROM geoIPReleases")==2
third_cache,third_meta=fixture(3)
geo.publish(db,third_cache,third_meta,'fixture','2026-03')
assert value("SELECT COUNT(*) FROM geoIPReleases")==2
try:geo.publish(db,cache,meta,'fixture','2026-01')
except ValueError:pass
else:raise AssertionError("older release accepted")
try:geo.publish(db,cache,{**meta,'ranges':0},'fixture','2026-04')
except ValueError:pass
else:raise AssertionError("truncated release accepted")
import pymysql
for sql in ["SELECT 1 FROM openCJ_cod4.playerInformation LIMIT 0","CREATE TABLE must_not_exist(id INT)"]:
    try:
        with db.cursor() as c:c.execute(sql)
    except pymysql.MySQLError as error:assert error.args[0] in [1044,1142]
    else:raise AssertionError("updater identity has excessive privileges")
cache.close();second_cache.close();third_cache.close();db.close()
print(json.dumps({'sql_boundaries':'pass','non_public_ranges':'pass','atomic_failure_rollback':'pass','idempotent_publication':'pass','last_two_releases':'pass','downgrade_and_shrink_rejection':'pass','least_privilege':'pass'}))
