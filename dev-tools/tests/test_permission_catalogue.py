"""The permission table, GSC catalogue, command registrations and SQL bits must agree.

This reads source text on purpose: the requirement is that four hand-maintained
places name the same permissions with the same permanent bit numbers. It does not
prove the permissions behave correctly in game; the command-menu, voting and
player-name engine fixtures cover that.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
CATALOGUE_FILE = ROOT / "server-gsc/opencj/permissions.gsc"
DOCUMENT_FILE = ROOT / "docs/reference/permissions.md"
GSC_ROOT = ROOT / "server-gsc"
MIGRATIONS = ROOT / "server-db/migrations"

HIGHEST_USABLE_BIT = 30  # Bit 31 would make the value negative in GSC.
CATALOGUE_ENTRY = re.compile(r'addPermission\("([a-z]+)",\s*(\d+),')
DOCUMENT_ROW = re.compile(r"^\| (\d+) \| `([a-z]+)` \|", re.MULTILINE)
# registerCommand(name, help, callback, minArgs, maxArgs, "permission"...), local
# wrappers such as registerModerationCommand, and hasPermission("permission") are
# the only ways code names a permission.
REGISTERED_PERMISSION = re.compile(
    r'register\w*Command\((?:[^()"]|"(?:[^"\\]|\\.)*"|\([^()]*\))*?,\s*"([a-z]+)"\s*[,)]'
)
CHECKED_PERMISSION = re.compile(r'(?:hasPermission|maskHasPermission)\([^")]*"([a-z]+)"\)')
SQL_BIT_VARIABLE = re.compile(r"DECLARE _([A-Za-z]+)Bit INT DEFAULT (\d+);")
GROUP_DEFINITION = re.compile(r'addGroup\("([a-z]+)",\s*"[^"]*",\s*(\w+)\)')
GROUP_ALIAS = re.compile(r'permissionGroupAliases\["([a-z]+)"\]\s*=\s*"([a-z]+)";')
DOCUMENT_GROUP_ROW = re.compile(r"^\| `([a-z]+)` \| ([^|]*) \| ([^|]*) \|$", re.MULTILINE)
GROUP_PERMISSIONS = {"uber", "perms"}  # Never grantable through a group.


def catalogue_bits():
    return {name: int(bit) for name, bit in CATALOGUE_ENTRY.findall(CATALOGUE_FILE.read_text())}


def catalogue_groups():
    """{group: (members, aliases)} read from the addGroup calls and their member arrays."""
    text = CATALOGUE_FILE.read_text()
    groups = {}
    for group_name, members_variable in GROUP_DEFINITION.findall(text):
        member_pattern = re.compile(re.escape(members_variable) + r'\[\d+\]\s*=\s*"([a-z]+)";')
        groups[group_name] = (member_pattern.findall(text), set())
    for alias, group_name in GROUP_ALIAS.findall(text):
        groups[group_name][1].add(alias)
    return groups


def document_groups():
    after_heading = DOCUMENT_FILE.read_text().split("## Permission groups", 1)[1]
    section = after_heading.split("\n## ", 1)[0]
    groups = {}
    for group_name, aliases, members in DOCUMENT_GROUP_ROW.findall(section):
        groups[group_name] = (re.findall(r"`([a-z]+)`", members),
                              set(re.findall(r"`([a-z]+)`", aliases)))
    return groups


def gsc_sources():
    return sorted(GSC_ROOT.rglob("*.gsc"))


class PermissionCatalogueTests(unittest.TestCase):
    def test_catalogue_names_and_bits_are_unique_and_usable(self):
        entries = CATALOGUE_ENTRY.findall(CATALOGUE_FILE.read_text())
        names = [name for name, _ in entries]
        bits = [int(bit) for _, bit in entries]
        self.assertTrue(entries, "no addPermission entries found")
        self.assertEqual(len(names), len(set(names)), "duplicate permission name")
        self.assertEqual(len(bits), len(set(bits)), "duplicate permission bit")
        self.assertEqual(catalogue_bits().get("uber"), 0, "uber must stay bit 0")
        for bit in bits:
            self.assertTrue(0 <= bit <= HIGHEST_USABLE_BIT, f"bit {bit} is outside 0-30")

    def test_document_table_matches_catalogue(self):
        documented = {name: int(bit) for bit, name in DOCUMENT_ROW.findall(DOCUMENT_FILE.read_text())}
        self.assertEqual(documented, catalogue_bits(),
                         "docs/reference/permissions.md and permissions.gsc disagree")

    def test_code_only_names_catalogued_permissions(self):
        known = set(catalogue_bits())
        for source in gsc_sources():
            text = source.read_text(errors="replace")
            used = set(REGISTERED_PERMISSION.findall(text)) | set(CHECKED_PERMISSION.findall(text))
            unknown = used - known
            self.assertFalse(unknown, f"{source.relative_to(ROOT)} uses unknown permissions {unknown}")

    def test_sql_bit_variables_match_catalogue(self):
        catalogue = catalogue_bits()
        latest_bits = {}
        for migration in sorted(MIGRATIONS.glob("*.sql")):
            for variable, bit in SQL_BIT_VARIABLE.findall(migration.read_text()):
                latest_bits[variable.lower()] = (int(bit), migration.name)
        self.assertIn("uber", latest_bits, "no SQL _uberBit variable found")
        for name, (bit, migration_name) in latest_bits.items():
            self.assertIn(name, catalogue, f"{migration_name} declares unknown _{name}Bit")
            self.assertEqual(bit, catalogue[name],
                             f"{migration_name}: _{name}Bit is {bit}, catalogue says {catalogue[name]}")

    def test_groups_hold_only_grantable_catalogued_permissions(self):
        catalogue = catalogue_bits()
        groups = catalogue_groups()
        self.assertTrue(groups, "no addGroup entries found")
        for group_name, (members, aliases) in groups.items():
            self.assertTrue(members, f"group {group_name} has no members")
            self.assertEqual(len(members), len(set(members)), f"group {group_name} repeats a member")
            self.assertFalse(set(members) - set(catalogue), f"group {group_name} has unknown members")
            self.assertFalse(set(members) & GROUP_PERMISSIONS,
                             f"group {group_name} must not contain uber or perms")
            for name in {group_name} | aliases:
                self.assertNotIn(name, catalogue, f"group name {name} collides with a permission")

    def test_document_group_table_matches_catalogue(self):
        documented = {name: (sorted(members), aliases)
                      for name, (members, aliases) in document_groups().items()}
        catalogued = {name: (sorted(members), aliases)
                      for name, (members, aliases) in catalogue_groups().items()}
        self.assertEqual(documented, catalogued,
                         "docs/reference/permissions.md groups and permissions.gsc disagree")

    def test_scanner_finds_known_registrations(self):
        # Guards the regular expressions above: if they stopped matching, the
        # unknown-permission test would pass without checking anything.
        moderation = (GSC_ROOT / "opencj/moderation.gsc").read_text()
        self.assertIn("tempban", REGISTERED_PERMISSION.findall(moderation))
        checkpoints = (GSC_ROOT / "opencj/checkpointcreation.gsc").read_text()
        self.assertIn("cpedit", CHECKED_PERMISSION.findall(checkpoints))


if __name__ == "__main__":
    unittest.main()
