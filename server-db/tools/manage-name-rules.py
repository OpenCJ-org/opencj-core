"""Manage private name rules without committing or echoing blocked text.

Run on the authoritative host. Terms are read privately, normalized in memory,
then stored only as hashes. The matching algorithm and table schema are public.
"""

from pathlib import Path
import argparse
import getpass
import hashlib
import json
import re
import subprocess
import sys
import urllib.request

MAX_INPUT_CHARACTERS = 128
MAX_SEED_LETTERS = 15
MIN_CONTAINED_LETTERS = 4
SEED_SEVERITY = 4

SOURCE_COMMIT = "c27924319aa9bd6f917e3782b4f4b6604a50b652"
SOURCE_BASE = "https://raw.githubusercontent.com/dsojevic/profanity-list/" + SOURCE_COMMIT + "/"


def normalize(value):
    """Match the engine and SQL normalization without retaining the submitted text."""
    value = re.sub(r"\^.", "", value.lower())
    substitutions = {
        "0": "o",
        "1": "i",
        "3": "e",
        "4": "a",
        "5": "s",
        "7": "t",
        "@": "a",
        "$": "s",
        "!": "i",
    }
    letters = []
    for character in value[:MAX_INPUT_CHARACTERS]:
        character = substitutions.get(character, character)
        if "a" <= character <= "z" and (not letters or letters[-1] != character):
            letters.append(character)
    return "".join(letters)


def digest(value):
    return hashlib.sha256(value.encode("ascii")).hexdigest()


def seed_rules(entries):
    """Collect hashed seed rules and merge exceptions across duplicate variants."""
    rules = {}
    # Most upstream level-3 values are defaults rather than reviewed severity.
    # Start with explicitly severe entries; operators can add local policy.
    for entry in entries:
        if entry.get("severity") != SEED_SEVERITY:
            continue
        for variant in entry["match"].split("|"):
            literal = variant.replace("*", "")
            term = normalize(literal)
            if not term or len(term) > MAX_SEED_LETTERS:
                continue
            mode = (
                "contains"
                if len(term) >= MIN_CONTAINED_LETTERS and entry.get("allow_partial", True)
                else "whole"
            )
            key = (digest(term), mode)
            exceptions = set()
            for exception_pattern in entry.get("exceptions", []):
                full_name = exception_pattern.replace("*", literal)
                normalized_exception = normalize(full_name)
                if normalized_exception:
                    exceptions.add(digest(normalized_exception))
            if key not in rules:
                rules[key] = {"length": len(term), "exceptions": set()}
            rules[key]["exceptions"].update(exceptions)
    return rules


def parse_options(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", default="openCJ_cod4")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--seed",
        action="store_true",
        help="import the pinned source's severe entries, without overriding existing rule settings",
    )
    group.add_argument("--add", action="store_true", help="read a new blocked term privately")
    group.add_argument(
        "--exception",
        type=int,
        metavar="RULE_ID",
        help="privately read a permitted full name for this rule",
    )
    group.add_argument("--disable", type=int, metavar="RULE_ID")
    group.add_argument("--list", action="store_true", help="show rule metadata only")
    parser.add_argument("--mode", choices=["whole", "contains"], default="whole")
    parser.add_argument(
        "--stdin",
        action="store_true",
        help="read hidden text from stdin instead of a terminal prompt",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--receipt", type=Path)
    options = parser.parse_args(arguments)
    if not re.fullmatch(r"(?:openCJ_cod4|opencj_verify_names_[0-9a-f]{8}_cod4)", options.database):
        parser.error("Unexpected target database.")
    for rule_id in (options.exception, options.disable):
        if rule_id is not None and rule_id <= 0:
            parser.error("Rule ID must be positive.")
    return options


def query_database(database, query):
    """Keep submitted SQL and database error output out of public diagnostics."""
    result = subprocess.run(
        [
            "docker",
            "exec",
            "-i",
            "opencj-dev-db-1",
            "sh",
            "-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root "$@"',
            "name-rules",
            database,
        ],
        input=query,
        text=True,
        capture_output=True,
    )
    if result.returncode:
        raise RuntimeError("Rule operation failed; no submitted text was logged.")
    return result.stdout.strip()


def read_private_text(from_stdin):
    value = (
        sys.stdin.readline().rstrip("\r\n")
        if from_stdin
        else getpass.getpass("Name/term (hidden): ")
    )
    if len(value) > MAX_INPUT_CHARACTERS:
        raise ValueError("Input exceeds the supported length.")
    normalized = normalize(value)
    if not normalized:
        raise ValueError("Input has no normalized letters.")
    return normalized


def prepare_seed(payload):
    """Build a repeatable import while preserving existing enabled/disabled choices."""
    statements = []
    receipt = {}
    entries = json.loads(payload)
    rules = seed_rules(entries)
    source = "upstream:" + SOURCE_COMMIT[:12]
    for (hash_value, mode), rule in rules.items():
        statements.append(
            """INSERT INTO nameModerationRules(nameHash, normalizedLength, matchMode, source)
            VALUES ('%s', %d, '%s', '%s')
            ON DUPLICATE KEY UPDATE ruleID=LAST_INSERT_ID(ruleID);"""
            % (hash_value, rule["length"], mode, source)
        )
        for exception in sorted(rule["exceptions"]):
            statements.append("""INSERT IGNORE INTO nameModerationExceptions(ruleID, nameHash)
                SELECT ruleID, '%s'
                FROM nameModerationRules
                WHERE nameHash='%s' AND matchMode='%s';""" % (exception, hash_value, mode))
    receipt.update(
        sourceCommit=SOURCE_COMMIT,
        sourceSha256=hashlib.sha256(payload).hexdigest(),
        rules=len(rules),
        exceptions=sum(len(rule["exceptions"]) for rule in rules.values()),
    )
    return statements, receipt


def prepare_change(options):
    """Prepare one private policy change; dry runs never open the database."""
    statements = []
    receipt = {"database": options.database, "dryRun": options.dry_run}
    if options.seed:
        with urllib.request.urlopen(SOURCE_BASE + "en.json", timeout=20) as response:
            payload = response.read()
        statements, seed_receipt = prepare_seed(payload)
        receipt.update(seed_receipt)
    elif options.add:
        value = read_private_text(options.stdin)
        hash_value = digest(value)
        statements.append(
            """INSERT INTO nameModerationRules(nameHash, normalizedLength, matchMode, source)
            VALUES ('%s', %d, '%s', 'local')
            ON DUPLICATE KEY UPDATE enabled=1, ruleID=LAST_INSERT_ID(ruleID);"""
            % (hash_value, len(value), options.mode)
        )
        statements.append("SELECT LAST_INSERT_ID();")
        receipt["operation"] = "add"
    elif options.exception is not None:
        value = read_private_text(options.stdin)
        statements.append("""INSERT IGNORE INTO nameModerationExceptions(ruleID, nameHash)
            VALUES (%d, '%s');""" % (options.exception, digest(value)))
        receipt.update(operation="exception", ruleID=options.exception)
    elif options.disable is not None:
        statements.append(
            "UPDATE nameModerationRules SET enabled=0 WHERE ruleID=%d;" % options.disable
        )
        receipt.update(operation="disable", ruleID=options.disable)
    return statements, receipt


def write_receipt(path, receipt):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    path.chmod(0o600)


def main(arguments=None):
    options = parse_options(arguments)
    if options.list:
        result = query_database(
            options.database,
            """SELECT ruleID, matchMode, normalizedLength, enabled, source
            FROM nameModerationRules
            ORDER BY ruleID;""",
        )
        print("ruleID\tmode\tlength\tenabled\tsource\n" + result)
        return

    statements, receipt = prepare_change(options)
    if not options.dry_run:
        result = query_database(
            options.database, "START TRANSACTION;\n" + "\n".join(statements) + "\nCOMMIT;"
        )
        if options.add and result.isdigit():
            receipt["ruleID"] = int(result)
    if options.receipt:
        write_receipt(options.receipt, receipt)
    print(json.dumps(receipt, indent=2))
    if not options.dry_run:
        print("Reload rules with !reloadnamerules or at the next map initialization.")


if __name__ == "__main__":
    main()
