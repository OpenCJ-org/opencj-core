"""Test shop transactions using a schema-only copy and synthetic players."""

from concurrent.futures import ThreadPoolExecutor
import json

from isolated_database import IsolatedDatabase

PLAYER_ID = 1
MAP_ID = 1
ITEM_PREFIX = "shop.test."
EARNED_POINTS = 100
EXPENSIVE_ITEM_PRICE = 60
CHEAP_ITEM_PRICE = 10


class ShopFixture:
    """Keep every query, including concurrent purchases, in this owned schema."""

    def __init__(self, database):
        self.database = database
        self.checks = 0

    def sql(self, statement):
        return self.database.query_database(statement, self.database.database)

    def expect(self, actual, expected, message):
        self.checks += 1
        if actual != expected:
            raise AssertionError(f"{message}: expected {expected!r}, got {actual!r}")

    def purchase(self, item, equip=False, quoted_price=None):
        if quoted_price is None:
            quoted_price = EXPENSIVE_ITEM_PRICE if item in ("a", "b") else CHEAP_ITEM_PRICE
        return self.sql(
            f"CALL shopBuyOrEquip({PLAYER_ID}, '{ITEM_PREFIX}{item}', "
            f"{int(equip)}, {quoted_price});"
        )

    def seed(self):
        """Give one synthetic player 100 earned points and five catalogue choices."""
        self.sql(f"""
            INSERT INTO mapids(mapID, mapname) VALUES({MAP_ID}, 'shop_fixture');
            INSERT INTO playerInformation(playerID, playerName)
                VALUES({PLAYER_ID}, 'Shop test');
            INSERT INTO challenges(challengeKey, tier, points, mapID, routeLabel)
                VALUES('{ITEM_PREFIX}earned', 1, {EARNED_POINTS}, {MAP_ID}, 'test');
            INSERT INTO challengeCompletions(playerID, challengeKey, pointsAwarded)
                VALUES({PLAYER_ID}, '{ITEM_PREFIX}earned', {EARNED_POINTS});
            """)
        items = (
            ("a", "deserteagle_mp", EXPENSIVE_ITEM_PRICE, 1),
            ("b", "rpg_mp", EXPENSIVE_ITEM_PRICE, 1),
            ("off", "rpg_mp", 1, 0),
            ("c", "deserteagle_mp", CHEAP_ITEM_PRICE, 1),
            ("d", "beretta_mp", CHEAP_ITEM_PRICE, 1),
        )
        for item, slot, price, available in items:
            self.sql(
                "INSERT INTO shopCatalog(itemKey, category, slot, price, available) "
                f"VALUES('{ITEM_PREFIX}{item}', 1, '{slot}', {price}, {available});"
            )

    def verify_rejections(self):
        self.expect(self.purchase("off"), "unavailable", "disabled catalogue item")
        self.expect(self.purchase("a", quoted_price=1), "price_changed", "forged price")
        self.expect(self.purchase("c", equip=True), "not_owned", "equip before purchase")
        self.expect(self.purchase("missing"), "unavailable", "missing catalogue item")

    def verify_concurrent_purchases(self):
        """Two affordable requests must not jointly spend more than the balance."""
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(self.purchase, ("a", "b")))
        self.expect(sorted(results), ["balance", "ok"], "concurrent overspend blocked")
        purchased_item = "a" if results[0] == "ok" else "b"

        with ThreadPoolExecutor(max_workers=4) as pool:
            repeated_results = list(pool.map(self.purchase, [purchased_item] * 4))
        self.expect(repeated_results, ["owned"] * 4, "replayed purchases never charge again")
        return purchased_item

    def verify_slots_and_ownership(self, purchased_item):
        self.expect(self.purchase("c"), "ok", "second item purchase")
        self.expect(self.purchase("d"), "ok", "third item purchase")
        # Each pistol has its own slot; buying one must not replace the other.
        for slot, item in (("deserteagle_mp", "c"), ("beretta_mp", "d")):
            selected = self.sql(
                f"SELECT itemKey FROM shopEquipped WHERE playerID={PLAYER_ID} AND slot='{slot}';"
            )
            self.expect(selected, ITEM_PREFIX + item, "independent equipped slot " + slot)
        spending_query = f"SELECT SUM(pointsSpent) FROM shopPurchases WHERE playerID={PLAYER_ID};"
        self.expect(self.sql(spending_query), "80", "only three purchases charged")

        self.sql(
            f"UPDATE shopCatalog SET price=9999 WHERE itemKey='{ITEM_PREFIX}{purchased_item}';"
        )
        self.expect(
            self.purchase(purchased_item, equip=True), "ok", "owned item survives repricing"
        )
        self.expect(self.sql(spending_query), "80", "equipping never charges")
        self.sql(f"UPDATE challenges SET active=0 WHERE challengeKey='{ITEM_PREFIX}earned';")
        self.expect(self.purchase("c", equip=True), "ok", "rank loss never revokes ownership")
        remaining_item = "a" if purchased_item == "b" else "b"
        self.expect(self.purchase(remaining_item), "balance", "remaining item exceeds balance")


def main():
    database = IsolatedDatabase("shop")
    database.home.mkdir(parents=True)
    try:
        database.prepare_database()
        fixture = ShopFixture(database)
        fixture.seed()
        fixture.verify_rejections()
        purchased_item = fixture.verify_concurrent_purchases()
        fixture.verify_slots_and_ownership(purchased_item)
        report = {
            "checks": fixture.checks,
            "passed": True,
            "databaseWrites": "owned disposable schema only",
        }
        (database.home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"SHOP_DB_PASS: {fixture.checks} transaction checks", flush=True)
        print("Evidence: " + str(database.home), flush=True)
    finally:
        database.cleanup()


if __name__ == "__main__":
    main()
