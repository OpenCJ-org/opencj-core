// Whole entity checkpoints. Store a stable map reference, never an entity slot.
// Brush model numbers belong to the map; script models require a unique targetname.
reference(platform)
{
    if (!isDefined(platform) || getCodVersion() != 4)
    {
        return undefined;
    }
    if (platform.classname != "script_brushmodel" && platform.classname != "script_model")
    {
        return undefined;
    }
    entityInfo = platformEntityInfo(platform getEntityNumber());
    if (!isDefined(entityInfo))
    {
        return undefined;
    }
    // Native entity info is [brush model index, local mins, local maxs].
    brushModelIndex = entityInfo[0];
    if (brushModelIndex > 0)
    {
        key = "b" + brushModelIndex;
    }
    else
    {
        maximumTargetNameLength = 100;
        if (!isDefined(platform.targetname) || platform.targetname.size == 0 ||
           platform.targetname.size > maximumTargetNameLength)
        {
            return undefined;
        }
        // Draft delimiters must never become part of an entity reference.
        for (i = 0; i < platform.targetname.size; i++)
        {
            if (!isSubStr("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
                         platform.targetname[i]))
            {
                return undefined;
            }
        }
        matches = getEntArray(platform.targetname, "targetname");
        if (matches.size != 1)
        {
            return undefined;
        }
        key = "n" + platform.targetname;
    }
    resolved = resolve(key);
    if (!isDefined(resolved) || resolved != platform)
    {
        return undefined;
    }
    return key;
}

// A deleted GSC entity reference becomes undefined; retry missing references once a second.
resolve(key)
{
    missingReferenceRetryMs = 1000;
    if (!isDefined(key) || key == "" || getCodVersion() != 4)
    {
        return undefined;
    }
    if (!isDefined(level.checkpointMovingCache))
    {
        level.checkpointMovingCache = [];
        level.checkpointMovingCacheKeys = [];
        level.checkpointMovingCacheNext = 0;
    }
    cached = level.checkpointMovingCache[key];
    if (isDefined(cached))
    {
        if (isDefined(cached.platform))
        {
            return cached.platform;
        }
        if (getTime() - cached.checked < missingReferenceRetryMs)
        {
            return undefined;
        }
    }
    cached = spawnStruct();
    cached.checked = getTime();
    rememberReference(key, cached);
    if (key[0] == "n")
    {
        platforms = getEntArray(getSubStr(key, 1), "targetname");
        if (platforms.size == 1 && platforms[0].classname == "script_model")
        {
            cached.platform = platforms[0];
        }
    }
    else if (key[0] == "b" && isValidInt(getSubStr(key, 1)))
    {
        brushModelIndex = int(getSubStr(key, 1));
        if (brushModelIndex <= 0)
        {
            return undefined;
        }
        platforms = getEntArray("script_brushmodel", "classname");
        for (i = 0; i < platforms.size; i++)
        {
            entityInfo = platformEntityInfo(platforms[i] getEntityNumber());
            if (!isDefined(entityInfo))
            {
                continue;
            }
            candidateBrushModelIndex = entityInfo[0];
            if (candidateBrushModelIndex != brushModelIndex)
            {
                continue;
            }
            // A cloned brush is ambiguous: do not bind to an arbitrary instance.
            if (isDefined(cached.platform))
            {
                cached.platform = undefined;
                return undefined;
            }
            cached.platform = platforms[i];
        }
    }
    return cached.platform;
}

// The engine has 1024 entity slots. Extra stale draft keys must not grow this
// per-map cache without limit. Eviction only forgets a lookup: it never changes
// a saved checkpoint, and the next use resolves the reference again.
rememberReference(key, cached)
{
    maximumCachedReferences = 1024;
    if (!isDefined(level.checkpointMovingCache[key]))
    {
        slot = level.checkpointMovingCacheNext;
        if (isDefined(level.checkpointMovingCacheKeys[slot]))
        {
            oldestKey = level.checkpointMovingCacheKeys[slot];
            level.checkpointMovingCache[oldestKey] = undefined;
        }
        level.checkpointMovingCacheKeys[slot] = key;
        level.checkpointMovingCacheNext = (slot + 1) % maximumCachedReferences;
    }
    level.checkpointMovingCache[key] = cached;
}

isMoving(checkpoint)
{
    return isDefined(checkpoint.platformRef) && checkpoint.platformRef != "";
}

// The outline denotes the whole object's bounds; it is not used for collision.
points(checkpoint)
{
    if (!isMoving(checkpoint))
    {
        return checkpoint.points;
    }
    platform = resolve(checkpoint.platformRef);
    if (!isDefined(platform))
    {
        return [];
    }
    entityInfo = platformEntityInfo(platform getEntityNumber());
    if (!isDefined(entityInfo))
    {
        return [];
    }
    // Native bounds are local to the entity; its current transform supplies world corners.
    localMins = entityInfo[1];
    localMaxs = entityInfo[2];
    localCorners = [];
    localCorners[0] = (localMins[0], localMins[1], localMaxs[2]);
    localCorners[1] = (localMaxs[0], localMins[1], localMaxs[2]);
    localCorners[2] = (localMaxs[0], localMaxs[1], localMaxs[2]);
    localCorners[3] = (localMins[0], localMaxs[1], localMaxs[2]);
    worldCorners = [];
    forward = anglesToForward(platform.angles);
    right = anglesToRight(platform.angles);
    up = anglesToUp(platform.angles);
    for (i = 0; i < localCorners.size; i++)
    {
        worldCorners[i] = platform.origin + vectorScale(forward, localCorners[i][0]) -
                          vectorScale(right, localCorners[i][1]) +
                          vectorScale(up, localCorners[i][2]);
    }
    return worldCorners;
}

// Callers use moving checkpoints, whose visual bounds contain exactly four corners.
center(checkpoint)
{
    corners = points(checkpoint);
    if (!corners.size)
    {
        return undefined;
    }
    return vectorScale(corners[0] + corners[1] + corners[2] + corners[3], 0.25);
}

// Called on a player. No geometry traces or polygon transforms during contact.
touches(checkpoint, grounded, groundEntity)
{
    platform = resolve(checkpoint.platformRef);
    if (!isDefined(platform))
    {
        return false;
    }
    if (checkpoint.onGround)
    {
        return grounded && isDefined(groundEntity) && groundEntity == platform;
    }
    return self isTouching(platform);
}

valid(checkpoint)
{
    if (!isMoving(checkpoint))
    {
        return openCJ\checkpointArea::validate(checkpoint.points);
    }
    if (checkpoint.alternatives.size)
    {
        return "A whole moving platform cannot have alternative areas yet";
    }
    if (!isDefined(resolve(checkpoint.platformRef)))
    {
        return "Moving platform cannot be found uniquely in this map";
    }
    return "";
}
