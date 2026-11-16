"""Test GeoIP schema/import in an isolated schema; remove its temporary account."""
from pathlib import Path
import importlib.util,os,subprocess,sys,uuid
R=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(R/'server-db/tools'))
from mysql_session import MySQL
spec=importlib.util.spec_from_file_location('geoip_provision',R/'server-db/tools/geoip/provision.py')
provision=importlib.util.module_from_spec(spec);spec.loader.exec_module(provision)
tag=uuid.uuid4().hex[:8];schema='opencj_geoip_test_'+tag;account='geoip_test_'+tag
w=R/'dev-tools/local/geoip-integration-20261114';secret=w/('test-password-'+tag)
created=False
try:
    with MySQL('opencj-dev-db-1','openCJ_cod4') as admin:
        admin.query('CREATE DATABASE '+schema+';');created=True
    with MySQL('opencj-dev-db-1',schema) as db:
        db.query('CREATE TABLE longCountry(country CHAR(2) PRIMARY KEY,longCountry VARCHAR(128)); INSERT INTO longCountry VALUES("GB","United Kingdom");')
        db.query((R/'server-db/migrations/025-geoip-country.sql').read_text())
    provision.provision('opencj-dev-db-1',schema,secret,account=account)
    with MySQL('opencj-dev-db-1',schema) as admin:
        for name in ['getCountry','geoIPLookupCode']:admin.query("GRANT EXECUTE ON FUNCTION "+schema+"."+name+" TO '"+account+"'@'%';")
    command=['docker','run','--rm','--network','opencj-dev_default','--user',str(os.getuid())+':'+str(os.getgid()),'--read-only','--tmpfs','/tmp:size=128m',
        '-e','GEOIP_DB_HOST=db','-e','GEOIP_DB_NAME='+schema,'-e','GEOIP_DB_USER='+account,'-e','GEOIP_DB_PASSWORD_FILE=/run/secret',
        '-v',str(secret)+':/run/secret:ro','-v',str(R/'server-db/tools/geoip')+':/source:ro',
        '--entrypoint','python','opencj-geoip-updater','/source/test_database.py']
    result=subprocess.run(command,capture_output=True,text=True,timeout=90)
    if result.returncode:
        print(result.stdout);print(result.stderr[-3500:]);raise RuntimeError('Isolated GeoIP database test failed')
    print(result.stdout)
    (w/'database-test-result.json').write_text(result.stdout)
finally:
    if created:
        with MySQL('opencj-dev-db-1','openCJ_cod4') as admin:
            admin.query("DROP DATABASE "+schema+"; DROP USER IF EXISTS '"+account+"'@'%';")
    if secret.exists():secret.unlink()
