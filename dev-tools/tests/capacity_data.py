"""Synthetic catalogue rows and legacy demo bytes for the capacity workloads."""

import math
import struct
import zlib

FRAMES_PER_CHUNK = 64
FORWARD_LEFT_STANDING = 517
FORWARD_RIGHT_STANDING = 518
ON_GROUND = 8192
BOUNCE = 16384
VIEW_HEIGHT_UNITS = 60
VIEW_HEIGHT_SCALE = 256


def demo_chunks(frame_count, variation=0):
    """Encode the same legacy OCJ4 movement corpus used by both capacity profiles."""
    result = []
    for start in range(0, frame_count, FRAMES_PER_CHUNK):
        count = min(FRAMES_PER_CHUNK, frame_count - start)
        raw = bytearray(b"OCJ4" + struct.pack("<I", count))
        for j in range(count):
            frame_index = start + j
            x = frame_index * 0.6 + variation * 13
            y = math.sin(frame_index * 0.07 + variation) * 500
            z = 700 + math.sin(frame_index * 0.11 + variation) * 200
            flags = FORWARD_LEFT_STANDING if frame_index % 40 < 20 else FORWARD_RIGHT_STANDING
            if frame_index % 100 < 5:
                flags |= ON_GROUND
            if frame_index % 100 == 60:
                flags |= BOUNCE
            fps = 333 if frame_index % 30 < 15 else 250
            raw += struct.pack(
                "<fffHHHHHIB", x, y, z, 0, (frame_index * 137) % 65536, 0, flags, fps, 1, 8
            )
            # Valid native presentation, unarmed, with changing velocity/bob.
            raw += struct.pack(
                "<HHHBBHBhhhhhhHHHBB",
                0,
                0,
                0,
                0,
                frame_index % 256,
                VIEW_HEIGHT_UNITS * VIEW_HEIGHT_SCALE,
                0,
                400,
                200,
                int(math.cos(frame_index * 0.11) * 800),
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            )
            name = b"none" if j == 0 else b""
            raw += bytes([len(name)]) + name
        result.append(zlib.compress(bytes(raw), 6).hex())
    return result


def seed_players_and_routes(execute):
    """Create only synthetic identities; recording routes are separate from playback seeds."""
    execute("INSERT INTO mapids(mapID,mapname) VALUES(1,'mp_killhouse');")
    execute(
        "INSERT INTO checkpoints(cpID,mapID) VALUES"
        + ",".join(f"({i},1)" for i in range(1, 65))
        + ";"
    )
    execute(
        "INSERT INTO routes(routeID,mapID,cpID,routeName) VALUES"
        + ",".join(f"({i},1,{i},'capacity{i}')" for i in range(1, 65))
        + ";"
    )
    execute("UPDATE checkpoints SET finishRouteID=cpID WHERE cpID BETWEEN 1 AND 64;")
    execute(
        "INSERT INTO playerInformation(playerID,playerName) VALUES"
        + ",".join(f"({i},'Synthetic {i}')" for i in range(1, 513))
        + ";"
    )


def seed_live_runs(execute, frame_count):
    """Give each engine client a recording, a save target and an existing playback run."""
    execute(
        "INSERT INTO playerRuns(runID,playerID,mapID,finishcpID,finishTimeStamp,instanceNumber,FPSMode,hb) VALUES"
        + ",".join(
            f"({base+i},{i},1,{i if base!=2000 else 'NULL'},{'NOW()' if base!=2000 else 'NULL'},1,'mix',0)"
            for base in (1000, 2000, 3000)
            for i in range(1, 33)
        )
        + ";"
        + "INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives,FPSMode) VALUES"
        + ",".join(
            f"({base+i},{i},{frame_count*50+i},1,0,0,0,0,'mix')"
            for base in (1000, 3000)
            for i in range(1, 33)
        )
        + ";"
    )


def seed_catalogue(execute):
    """Add 10,000 finishes and 20,000 saves to exercise real menu joins."""
    for start in range(0, 10000, 500):
        execute(
            "INSERT INTO playerRuns(runID,playerID,mapID,finishcpID,finishTimeStamp,FPSMode) VALUES"
            + ",".join(f"({10000+i},{i%512+1},1,1,NOW(),'mix')" for i in range(start, start + 500))
            + ";"
            + "INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives,FPSMode) VALUES"
            + ",".join(
                f"({10000+i},1,{100000+i},20,2,{i%5},0,0,'mix')" for i in range(start, start + 500)
            )
            + ";"
        )
    for start in range(0, 1000, 100):
        execute(
            "INSERT INTO playerRuns(runID,playerID,mapID,FPSMode) VALUES"
            + ",".join(f"({20000+i},{i%32+1},1,'mix')" for i in range(start, start + 100))
            + ";"
            + "INSERT INTO playerSaves(runID,saveNumber,alpha,beta,gamma,explosiveJumps,doubleExplosives,flags,FPSMode) VALUES"
            + ",".join(
                f"({20000+i},{j},0,0,0,0,0,0,'mix')"
                for i in range(start, start + 100)
                for j in range(1, 21)
            )
            + ";"
        )


def seed_recordings(execute, frame_count, report):
    """Use distinct routes so publishing the live runs cannot retire playback seeds."""
    payloads = demo_chunks(frame_count)
    report["payloadBytesPerDemo"] = sum(len(x) // 2 for x in payloads)
    execute(
        "INSERT INTO demoRuns(runID,mapID,routeID,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount,ready) VALUES"
        + ",".join(
            f"({3000+i},1,{32+i},'mix',0,{frame_count*50},0,{frame_count},1)" for i in range(1, 33)
        )
        + ";"
        + "INSERT INTO demoWinners(mapID,routeID,FPSMode,modeMask,kind,runID) SELECT mapID,routeID,FPSMode,modeMask,'walkthrough',runID FROM demoRuns;"
    )
    for i in range(1, 33):
        payloads = demo_chunks(frame_count, i)
        execute(
            "INSERT INTO demoChunks(runID,chunkNum,payload) VALUES"
            + ",".join(f"({3000+i},{j},UNHEX('{payload}'))" for j, payload in enumerate(payloads))
            + ";"
        )
    report["syntheticRows"] = {
        "finishedRuns": 10064,
        "unfinishedRuns": 1032,
        "saves": 20000,
        "players": 512,
    }


def seed_growth(execute, report):
    """Model older maps and long-lived history without copying gameplay rows."""
    print(
        "HOSTING seeding 250000 historical finishes and 2000000 saves across 100 older maps",
        flush=True,
    )
    execute(
        "CREATE TABLE hostingDigits(n INT PRIMARY KEY); INSERT INTO hostingDigits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);"
        + "CREATE TABLE hostingNums(n INT PRIMARY KEY); INSERT INTO hostingNums SELECT a.n+10*b.n+100*c.n+1000*d.n FROM hostingDigits a CROSS JOIN hostingDigits b CROSS JOIN hostingDigits c CROSS JOIN hostingDigits d;"
    )
    execute(
        "INSERT INTO playerInformation(playerID,playerName) SELECT 513+n,CONCAT('Synthetic ',513+n) FROM hostingNums WHERE n<9488;"
        + "INSERT INTO mapids(mapID,mapname) SELECT 101+n,CONCAT('hosting_map_',n) FROM hostingNums WHERE n<100;"
        + "INSERT INTO checkpoints(cpID,mapID) SELECT 100001+n,101+n FROM hostingNums WHERE n<100;"
    )
    for start in range(0, 250000, 10000):
        execute(
            f"INSERT INTO playerRuns(runID,playerID,mapID,finishcpID,finishTimeStamp,timePlayed,FPSMode) SELECT 100000+n+{start},1+MOD(n+{start},10000),IF(n+{start}<50000,1,101+MOD(n+{start},100)),IF(n+{start}<50000,1,100001+MOD(n+{start},100)),NOW(),100000+n,'mix' FROM hostingNums;"
            + f"INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives,FPSMode) SELECT 100000+n+{start},IF(n+{start}<50000,1,100001+MOD(n+{start},100)),100000+n,100,10,2,2,0,'mix' FROM hostingNums;"
        )
        if start % 50000 == 0:
            print("HOSTING seeded finishes", start + 10000, flush=True)
    for start in range(0, 20000, 10000):
        execute(
            f"INSERT INTO playerRuns(runID,playerID,mapID,timePlayed,FPSMode) SELECT 1000000+n+{start},1+MOD(n+{start},10000),IF(n+{start}<2000,1,101+MOD(n+{start},100)),100000+n,'mix' FROM hostingNums;"
        )
    for start in range(0, 2000000, 10000):
        execute(
            f"INSERT INTO playerSaves(runID,saveNumber,x,y,z,alpha,beta,gamma,explosiveJumps,doubleExplosives,flags,FPSMode) SELECT 1000000+FLOOR((n+{start})/100),MOD(n+{start},100),n*0.1234,n*0.2345,n*0.3456,1,90,1,2,0,0,'mix' FROM hostingNums;"
        )
        if start % 250000 == 0:
            print("HOSTING seeded saves", start + 10000, flush=True)
    report["syntheticRows"].update(
        {
            "extraFinishedRuns": 250000,
            "extraUnfinishedRuns": 20000,
            "extraSaves": 2000000,
            "totalPlayers": 10000,
            "extraMaps": 100,
        }
    )
    execute("ANALYZE TABLE playerSaves,playerRuns,checkpointStatistics,demoChunks;")


def seed_capacity_data(database, frame_count, mature=False):
    """Populate the owned database and report the intended workload sizes."""
    execute = database.sql
    report = {}
    seed_players_and_routes(execute)
    seed_live_runs(execute, frame_count)
    seed_catalogue(execute)
    seed_recordings(execute, frame_count, report)
    if mature:
        seed_growth(execute, report)
    report["storageAfterSeed"] = execute(
        "SELECT TABLE_NAME,TABLE_ROWS,DATA_LENGTH,INDEX_LENGTH FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('playerRuns','playerSaves','checkpointStatistics','demoChunks','demoRuns');"
    )
    report["dbMemorySettings"] = execute(
        "SHOW VARIABLES WHERE Variable_name IN ('innodb_buffer_pool_size','max_connections','temptable_max_ram','tmp_table_size');"
    )
    return report
