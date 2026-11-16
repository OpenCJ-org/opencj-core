"""Manage private name rules without committing or echoing blocked text.

Run on the authoritative host. Terms are read privately, normalized in memory,
then stored only as hashes. The matching algorithm and table schema are public.
"""
from pathlib import Path
import argparse,getpass,hashlib,json,re,subprocess,sys,urllib.request
SOURCE_COMMIT="c27924319aa9bd6f917e3782b4f4b6604a50b652"
SOURCE_BASE="https://raw.githubusercontent.com/dsojevic/profanity-list/"+SOURCE_COMMIT+"/"
def normalize(value):
    value=re.sub(r"\^.","",value.lower())
    substitutions={"0":"o","1":"i","3":"e","4":"a","5":"s","7":"t","@":"a","$":"s","!":"i"}
    out=[]
    for ch in value[:128]:
        ch=substitutions.get(ch,ch)
        if "a"<=ch<="z" and (not out or out[-1]!=ch):out.append(ch)
    return "".join(out)
def digest(value):return hashlib.sha256(value.encode("ascii")).hexdigest()
def seed_rules(data):
    rules={}
    # Most upstream level-3 values are defaults rather than reviewed severity.
    # Start with explicitly severe entries; operators can add local policy.
    for entry in data:
        if entry.get("severity")!=4:continue
        for variant in entry["match"].split("|"):
            literal=variant.replace("*","")
            term=normalize(literal)
            if not term or len(term)>15:continue
            mode="contains" if len(term)>=4 and entry.get("allow_partial",True) else "whole"
            key=(digest(term),mode)
            exceptions={digest(normalize(x.replace("*",literal))) for x in entry.get("exceptions",[]) if normalize(x.replace("*",literal))}
            if key not in rules:rules[key]={"length":len(term),"exceptions":set()}
            rules[key]["exceptions"].update(exceptions)
    return rules
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database",default="openCJ_cod4")
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--seed",action="store_true",help="import the pinned source's severe entries, without overriding existing rule settings")
    group.add_argument("--add",action="store_true",help="read a new blocked term privately")
    group.add_argument("--exception",type=int,metavar="RULE_ID",help="privately read a permitted full name for this rule")
    group.add_argument("--disable",type=int,metavar="RULE_ID")
    group.add_argument("--list",action="store_true",help="show rule metadata only")
    parser.add_argument("--mode",choices=["whole","contains"],default="whole")
    parser.add_argument("--stdin",action="store_true",help="read hidden text from stdin instead of a terminal prompt")
    parser.add_argument("--dry-run",action="store_true")
    parser.add_argument("--receipt",type=Path)
    args=parser.parse_args()
    if not re.fullmatch(r"(?:openCJ_cod4|opencj_verify_names_[0-9a-f]{8}_cod4)",args.database):parser.error("Unexpected target database.")
    def db(query):
        p=subprocess.run(["docker","exec","-i","opencj-dev-db-1","sh","-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root "$@"',"name-rules",args.database],
            input=query,text=True,capture_output=True)
        if p.returncode:raise RuntimeError("Rule operation failed; no submitted text was logged.")
        return p.stdout.strip()
    def private_text():
        value=sys.stdin.readline().rstrip("\r\n") if args.stdin else getpass.getpass("Name/term (hidden): ")
        if len(value)>128:raise ValueError("Input exceeds the supported length.")
        normal=normalize(value)
        if not normal:raise ValueError("Input has no normalized letters.")
        return normal
    statements=[];receipt={"database":args.database,"dryRun":args.dry_run}
    if args.seed:
        payload=urllib.request.urlopen(SOURCE_BASE+"en.json",timeout=20).read()
        data=json.loads(payload)
        rules=seed_rules(data)
        source="upstream:"+SOURCE_COMMIT[:12]
        for (hash_value,mode),rule in rules.items():
            statements.append("INSERT INTO nameModerationRules(nameHash,normalizedLength,matchMode,source) VALUES('%s',%d,'%s','%s') ON DUPLICATE KEY UPDATE ruleID=LAST_INSERT_ID(ruleID);"%(hash_value,rule["length"],mode,source))
            for exception in sorted(rule["exceptions"]):
                statements.append("INSERT IGNORE INTO nameModerationExceptions(ruleID,nameHash) SELECT ruleID,'%s' FROM nameModerationRules WHERE nameHash='%s' AND matchMode='%s';"%(exception,hash_value,mode))
        receipt.update(sourceCommit=SOURCE_COMMIT,sourceSha256=hashlib.sha256(payload).hexdigest(),rules=len(rules),exceptions=sum(len(v["exceptions"]) for v in rules.values()))
        del payload,data,rules
    elif args.add:
        value=private_text();hash_value=digest(value)
        statements.append("INSERT INTO nameModerationRules(nameHash,normalizedLength,matchMode,source) VALUES('%s',%d,'%s','local') ON DUPLICATE KEY UPDATE enabled=1,ruleID=LAST_INSERT_ID(ruleID);"%(hash_value,len(value),args.mode))
        statements.append("SELECT LAST_INSERT_ID();");receipt["operation"]="add"
    elif args.exception is not None:
        if args.exception<=0:parser.error("Rule ID must be positive.")
        value=private_text()
        statements.append("INSERT IGNORE INTO nameModerationExceptions(ruleID,nameHash) VALUES(%d,'%s');"%(args.exception,digest(value)))
        receipt.update(operation="exception",ruleID=args.exception)
    elif args.disable is not None:
        if args.disable<=0:parser.error("Rule ID must be positive.")
        statements.append("UPDATE nameModerationRules SET enabled=0 WHERE ruleID=%d;"%args.disable)
        receipt.update(operation="disable",ruleID=args.disable)
    else:
        result=db("SELECT ruleID,matchMode,normalizedLength,enabled,source FROM nameModerationRules ORDER BY ruleID;")
        print("ruleID\tmode\tlength\tenabled\tsource\n"+result)
        return
    if not args.dry_run:
        result=db("START TRANSACTION;\n"+"\n".join(statements)+"\nCOMMIT;")
        if args.add and result.isdigit():receipt["ruleID"]=int(result)
    if args.receipt:
        args.receipt.parent.mkdir(parents=True,exist_ok=True)
        args.receipt.write_text(json.dumps(receipt,indent=2)+"\n");args.receipt.chmod(0o600)
    print(json.dumps(receipt,indent=2))
    if not args.dry_run:print("Reload rules with !reloadnamerules or at the next map initialization.")
if __name__=="__main__":main()
