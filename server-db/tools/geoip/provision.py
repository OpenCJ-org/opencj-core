"""Provision a GeoIP-only SQL account. The generated password is never printed."""
from pathlib import Path
import argparse,os,re,secrets,subprocess,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from mysql_session import MySQL
TABLES=("geoIPReleases","geoIPRanges","geoIPState")

def provision(container,database,secret_file,account="geoip_updater",gameplay_account=None):
    if not re.fullmatch(r"[A-Za-z0-9_]+",database) or not re.fullmatch(r"geoip_[A-Za-z0-9_]+",account):
        raise ValueError("Invalid database/updater identifier")
    path=Path(secret_file).resolve()
    for parent in path.parents:
        if (parent/".git").exists():
            result=subprocess.run(["git","-C",str(parent),"check-ignore","-q",str(path)],capture_output=True)
            if result.returncode:raise ValueError("Secret path is inside a repository and is not ignored")
            break
    with MySQL(container,database) as db:
        exists=db.query("SELECT COUNT(*) FROM mysql.user WHERE User='"+account+"' AND Host='%';")=="1"
        if exists and not path.exists():raise ValueError("Existing account has no local secret; refusing a silent password reset")
        path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        if path.exists():
            if path.stat().st_mode&0o077:raise ValueError("Secret file must have mode 0600")
            password=path.read_text().strip()
        else:
            password=secrets.token_urlsafe(36)
            fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            with os.fdopen(fd,"w") as stream:stream.write(password+"\n")
        if not re.fullmatch(r"[A-Za-z0-9_-]{32,128}",password):raise ValueError("Unexpected updater secret format")
        principal="'"+account+"'@'%'"
        if not exists:db.query("CREATE USER "+principal+" IDENTIFIED BY '"+password+"';")
        grantee="'"+principal.replace("'","''")+"'"
        if db.query("SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES WHERE GRANTEE="+grantee+" AND PRIVILEGE_TYPE<>'USAGE';")!="0":
            raise ValueError("Updater account has unexpected global privileges")
        if db.query("SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES WHERE GRANTEE="+grantee+";")!="0":
            raise ValueError("Updater account has unexpected schema-wide privileges")
        other=db.query("SELECT COUNT(*) FROM information_schema.TABLE_PRIVILEGES WHERE GRANTEE="+grantee+" AND (TABLE_SCHEMA<>'"+database+"' OR TABLE_NAME NOT IN ('geoIPReleases','geoIPRanges','geoIPState'));")
        if other!="0":raise ValueError("Updater account has unrelated table privileges")
        for table in TABLES:db.query("GRANT SELECT,INSERT,UPDATE,DELETE ON "+database+"."+table+" TO "+principal+";")
        if gameplay_account:
            if not re.fullmatch("[A-Za-z0-9_]+",gameplay_account):raise ValueError("Invalid gameplay account")
            for function in ["geoIPLookupCode","getCountry"]:
                db.query("GRANT EXECUTE ON FUNCTION "+database+"."+function+" TO '"+gameplay_account+"'@'%';")
    return path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--container",default="opencj-dev-db-1")
    p.add_argument("--database",default="openCJ_cod4")
    p.add_argument("--confirm-database",required=True)
    p.add_argument("--secret-file",type=Path,required=True)
    p.add_argument("--gameplay-account",default="opencj")
    args=p.parse_args()
    if args.confirm_database!=args.database:p.error("Confirmation must match database")
    try:path=provision(args.container,args.database,args.secret_file,gameplay_account=args.gameplay_account)
    except Exception:
        print("GeoIP credential provisioning failed; no credential values logged.",file=sys.stderr)
        raise SystemExit(1)
    print("GeoIP-only account configured; secret file (mode 0600): "+str(path))
if __name__=="__main__":main()
