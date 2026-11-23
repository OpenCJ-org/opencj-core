#include openCJ\util;

main(inflictor, attacker, damage, flags, meansOfDeath, weapon, vPoint, vDir, hitLoc, psOffsetTime)
{
    if(self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    if(!self isPlayerReady())
    {
        return;
    }
    if(self.sessionState != "playing")
    {
        return;
    }
    if(self openCJ\noclip::hasNoclip())
    {
        return;
    }

    noKnockbackFlag = 4;
    if(!isdefined(vDir))
    {
        flags |= 4;
    } // iDFLAGS_NO_KNOCKBACK;

    if(isDefined(attacker) && isPlayer(attacker) && self != attacker)
    {
        return;
    }

    if(damage < 1)
    {
        damage = 1;
    }

    if(self openCJ\weapons::isRPG(weapon))
    {
        return;
    }

    if(damage >= self.health)
    {
        if(self openCJ\checkpointCreation::isEditing())
        {
            editorPositionLoaded = self openCJ\checkpointCreation::loadPosition(0);
            if(editorPositionLoaded)
            {
                return;
            }
        }
        else
        {
            loadedSave = self openCJ\events\loadPosition::main(0);
            // Save number zero is valid; undefined means no position was loaded.
            if(isDefined(loadedSave))
            {
                if(getCodVersion() == 2)
                {
                    cod2DeathPenaltyMs = 5000;
                    self openCJ\playTime::addTimeUntil(getTime() + cod2DeathPenaltyMs);
                }
                return;
            }
        }
    }

    self finishPlayerDamage(inflictor, attacker, damage, flags, meansOfDeath, weapon, vPoint, vDir,
                            hitLoc, psOffsetTime);

    self openCJ\shellShock::onPlayerDamage(inflictor, attacker, damage, flags, meansOfDeath, weapon,
                                           vPoint, vDir, hitLoc, psOffsetTime);
    self openCJ\healthRegen::onPlayerDamage(inflictor, attacker, damage, flags, meansOfDeath,
                                            weapon, vPoint, vDir, hitLoc, psOffsetTime);
    self openCJ\statistics::onPlayerDamage(inflictor, attacker, damage, flags, meansOfDeath, weapon,
                                           vPoint, vDir, hitLoc, psOffsetTime);
}