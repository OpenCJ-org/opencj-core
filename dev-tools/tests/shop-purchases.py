"""Transaction regression tests, isolated database only; all fixtures removed."""

from compose_environment import database_container
import concurrent.futures
import subprocess

DB = 'openCJ_cod4'
PID = -2147483000
PREFIX = 'shop.test.'


def sql(q):
    p = subprocess.run(
        [
            'docker',
            'exec',
            '-i',
            database_container(),
            'sh',
            '-c',
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root "$1"',
            'test',
            DB,
        ],
        input=q,
        text=True,
        capture_output=True,
        check=True,
    )
    return p.stdout.strip()


def call(key, equip=0):
    return sql(
        f"CALL shopBuyOrEquip({PID},'{PREFIX}{key}',{equip},{60 if key in ['a','b'] else 10});"
    )


def cleanup():
    sql(
        f"DELETE FROM shopEquipped WHERE playerID={PID}; DELETE FROM shopPurchases WHERE playerID={PID}; DELETE FROM shopAccounts WHERE playerID={PID}; DELETE FROM challengeCompletions WHERE playerID={PID}; DELETE FROM playerInformation WHERE playerID={PID}; DELETE FROM challenges WHERE challengeKey='{PREFIX}earned'; DELETE FROM shopCatalog WHERE itemKey LIKE '{PREFIX}%'; DELETE FROM mapids WHERE mapID={PID};"
    )


assert sql(f'SELECT COUNT(*) FROM playerInformation WHERE playerID={PID};') == '0'
assert sql(f"SELECT COUNT(*) FROM mapids WHERE mapID={PID} OR mapname='shop_fixture';") == '0'
assert sql(f"SELECT COUNT(*) FROM challenges WHERE challengeKey='{PREFIX}earned';") == '0'
assert sql(f"SELECT COUNT(*) FROM shopCatalog WHERE itemKey LIKE '{PREFIX}%';") == '0'
try:
    sql(
        f"INSERT INTO mapids(mapID,mapname) VALUES({PID},'shop_fixture'); INSERT INTO playerInformation(playerID,playerName) VALUES({PID},'Shop test'); INSERT INTO challenges(challengeKey,tier,points,mapID,routeLabel) VALUES('{PREFIX}earned',1,100,{PID},'test'); INSERT INTO challengeCompletions(playerID,challengeKey,pointsAwarded) VALUES({PID},'{PREFIX}earned',100);"
    )
    for key, slot, price, available in [
        ('a', 'deserteagle_mp', 60, 1),
        ('b', 'rpg_mp', 60, 1),
        ('off', 'rpg_mp', 1, 0),
        ('c', 'deserteagle_mp', 10, 1),
        ('d', 'beretta_mp', 10, 1),
    ]:
        sql(
            f"INSERT INTO shopCatalog(itemKey,category,slot,price,available) VALUES('{PREFIX}{key}',1,'{slot}',{price},{available});"
        )
    assert call('off') == 'unavailable'
    assert sql(f"CALL shopBuyOrEquip({PID},'{PREFIX}a',0,1);") == 'price_changed'
    assert call('c', 1) == 'not_owned'
    assert call('missing') == 'unavailable'
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        results = list(pool.map(call, ['a', 'b']))
    assert sorted(results) == ['balance', 'ok'], results
    winner = 'a' if results[0] == 'ok' else 'b'
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        results = list(pool.map(call, [winner] * 4))
    assert results == ['owned'] * 4, results
    assert call('c') == 'ok' and call('d') == 'ok'
    # Different pistols keep independent selections, replacement within one slot only.
    assert (
        sql(f"SELECT itemKey FROM shopEquipped WHERE playerID={PID} AND slot='deserteagle_mp';")
        == PREFIX + 'c'
    )
    assert (
        sql(f"SELECT itemKey FROM shopEquipped WHERE playerID={PID} AND slot='beretta_mp';")
        == PREFIX + 'd'
    )
    assert sql(f'SELECT SUM(pointsSpent) FROM shopPurchases WHERE playerID={PID};') == '80'
    sql(f"UPDATE shopCatalog SET price=9999 WHERE itemKey='{PREFIX}{winner}';")
    assert call(winner, 1) == 'ok'
    assert sql(f'SELECT SUM(pointsSpent) FROM shopPurchases WHERE playerID={PID};') == '80'
    sql(f"UPDATE challenges SET active=0 WHERE challengeKey='{PREFIX}earned';")
    assert call('c', 1) == 'ok'  # Losing rank never revokes ownership.
    assert call('a' if winner == 'b' else 'b') == 'balance'
    print(
        'SHOP_DB_PASS: unavailable/forged equip, concurrent overspend, duplicate replay, independent slots, equip, repricing and rank changes'
    )
finally:
    cleanup()
