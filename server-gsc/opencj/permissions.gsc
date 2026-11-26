#include openCJ\util;

// Account permissions are independent bits stored in playerInformation.permissions.
// Before changing this file, read docs/reference/permissions.md and its maintenance
// rule: every permission change must also update that document, the SQL bit checks
// and the tests in the same change.
//
// Keep this file free of references to other script files (apart from the command
// menu refresh). commands_base loads it early, and the engine caps the cross-file
// references it collects while loading a chain of scripts (MAX_PRECACHE_ENTRIES).
// The !permissions command lives in moderation.gsc.

// Build the catalogue once. Commands may be registered before anything else runs, so
// every lookup loads it on demand.
// A bit number is permanent: stored accounts keep it, so never renumber or reuse one.
// Bits 0-30 are usable; bit 31 would make the value negative in GSC.
loadCatalogue()
{
    if (isDefined(level.permissionCatalogue))
    {
        return;
    }
    level.permissionCatalogue = [];
    level.permissionNames = [];
    addPermission("uber", 0, "Everything, incl. permbans and name rules. Database only.");
    addPermission("perms", 1, "View others' permissions; grant/revoke ones you hold.");
    addPermission("cpedit", 2, "Create and edit checkpoint routes (!checkpoint).");
    addPermission("mute", 3, "Mute and unmute players (!mute, !unmute).");
    addPermission("names", 4, "Force names, reset preferred names (!frename, !resetprefname).");
    addPermission("maprestart", 5, "Restart the current map (!maprestart).");
    addPermission("mapdebug", 6, "Map debugging tools (!ent, !setorigin, !detectplat).");
    addPermission("kick", 7, "Kick online players (!kick).");
    addPermission("tempban", 8, "Ban up to 7 days, lift temp bans (!tempban, !untempban, !bans).");

    // Groups are named sets of the permissions above, not stored bits: granting a
    // group sets all its bits, revoking it clears them.
    level.permissionGroups = [];
    level.permissionGroupNames = [];
    level.permissionGroupAliases = [];
    moderationMembers = [];
    moderationMembers[0] = "mute";
    moderationMembers[1] = "names";
    moderationMembers[2] = "kick";
    moderationMembers[3] = "tempban";
    addGroup("mod", "Moderation: mute, names, kick and tempban.", moderationMembers);
    level.permissionGroupAliases["moderation"] = "mod";
}

// Members must be catalogued, non-uber permissions listed once each.
addGroup(groupName, description, memberNames)
{
    group = spawnStruct();
    group.name = groupName;
    group.description = description;
    group.memberNames = memberNames;
    group.mask = 0;
    for (i = 0; i < memberNames.size; i++)
    {
        member = level.permissionCatalogue[memberNames[i]];
        // Adding distinct powers of two builds the same value as OR-ing the bits.
        group.mask += member.flag;
    }
    level.permissionGroups[groupName] = group;
    level.permissionGroupNames[level.permissionGroupNames.size] = groupName;
}

addPermission(permissionName, bitIndex, description)
{
    permission = spawnStruct();
    permission.name = permissionName;
    permission.bitIndex = bitIndex;
    permission.description = description;
    // Build the bit value by doubling rather than relying on a shift operator.
    permission.flag = 1;
    for (i = 0; i < bitIndex; i++)
    {
        permission.flag *= 2;
    }
    level.permissionCatalogue[permissionName] = permission;
    level.permissionNames[level.permissionNames.size] = permissionName;
}

// Return the catalogue entry for a short name, ignoring case, or undefined.
permissionNamed(permissionName)
{
    loadCatalogue();
    if (!isDefined(permissionName))
    {
        return undefined;
    }
    return level.permissionCatalogue[toLower(permissionName)];
}

// A permission or group that !permissions can grant, as one shape: its canonical
// name, combined bit mask and member permission names. Undefined for unknown names.
grantableNamed(grantName)
{
    loadCatalogue();
    if (!isDefined(grantName))
    {
        return undefined;
    }
    grantName = toLower(grantName);
    if (isDefined(level.permissionGroupAliases[grantName]))
    {
        grantName = level.permissionGroupAliases[grantName];
    }
    grantable = spawnStruct();
    group = level.permissionGroups[grantName];
    if (isDefined(group))
    {
        grantable.name = group.name;
        grantable.isGroup = true;
        grantable.mask = group.mask;
        grantable.memberNames = group.memberNames;
        return grantable;
    }
    permission = level.permissionCatalogue[grantName];
    if (!isDefined(permission))
    {
        return undefined;
    }
    grantable.name = permission.name;
    grantable.isGroup = false;
    grantable.mask = permission.flag;
    grantable.memberNames = [];
    grantable.memberNames[0] = permission.name;
    return grantable;
}

// Group names in catalogue order.
groupNames()
{
    loadCatalogue();
    return level.permissionGroupNames;
}

groupNamed(groupName)
{
    loadCatalogue();
    return level.permissionGroups[groupName];
}

// The uber bit implies every permission. Unknown names are never granted.
maskHasPermission(permissionMask, permissionName)
{
    if (!isDefined(permissionMask))
    {
        return false;
    }
    loadCatalogue();
    if (permissionMask & level.permissionCatalogue["uber"].flag)
    {
        return true;
    }
    permission = permissionNamed(permissionName);
    if (!isDefined(permission))
    {
        return false;
    }
    return (permissionMask & permission.flag) != 0;
}

isUberMask(permissionMask)
{
    return maskHasPermission(permissionMask, "uber");
}

hasPermission(permissionName)
{
    return maskHasPermission(self.permissions, permissionName);
}

isUberAdmin()
{
    return isUberMask(self.permissions);
}

// Apply a newly loaded or changed mask. An open command browser is refreshed so it
// never keeps showing commands the player just lost.
setPermissions(permissionMask)
{
    self.permissions = permissionMask;
    if (isDefined(self.currentMenu) && self.currentMenu == "opencj_commands")
    {
        self openCJ\menus\commands::refresh(false);
    }
}

describeMask(permissionMask)
{
    if (!isDefined(permissionMask))
    {
        return "none";
    }
    loadCatalogue();
    if (isUberMask(permissionMask))
    {
        return "uber (all permissions)";
    }
    // Fully held groups are named once instead of listing their members.
    heldNames = "";
    describedMask = 0;
    for (i = 0; i < level.permissionGroupNames.size; i++)
    {
        group = level.permissionGroups[level.permissionGroupNames[i]];
        if ((permissionMask & group.mask) != group.mask)
        {
            continue;
        }
        if (heldNames != "")
        {
            heldNames += ", ";
        }
        heldNames += group.name;
        describedMask = describedMask | group.mask;
    }
    for (i = 0; i < level.permissionNames.size; i++)
    {
        permission = level.permissionCatalogue[level.permissionNames[i]];
        if (!(permissionMask & permission.flag) || (describedMask & permission.flag))
        {
            continue;
        }
        if (heldNames != "")
        {
            heldNames += ", ";
        }
        heldNames += permission.name;
    }
    if (heldNames == "")
    {
        return "none";
    }
    return heldNames;
}

// Short names in catalogue order.
permissionNames()
{
    loadCatalogue();
    return level.permissionNames;
}
