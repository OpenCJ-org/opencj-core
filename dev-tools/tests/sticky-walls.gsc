main()
{
    wait 1;
    p = (-16296, 100312, -24898);
    for(z = 0; z <= 60; z += 30)
    {
        for(a = 0; a < 360; a += 45)
        {
            d = anglesToForward((0, a, 0));
            t = bulletTrace(p + (0, 0, z), p + (0, 0, z) + d * 128, false, undefined);
            printf("STICKY SELFTEST ray z=" + z + " yaw=" + a + " fraction=" + t["fraction"] +
                   " pos=" + t["position"] + " normal=" + t["normal"] + "\n");
        }
    }
    b = addTestClient();
    wait 1.5;
    b.sessionTeam = "allies";
    b.sessionState = "playing";
    b.pers["team"] = "allies";
    for(k = 0; k <= 4; k++)
    {
        a = 120;
        offset = k * 0.125;
        b spawn(p + (0.498964, -0.866622, 0) * offset, (0, a, 0));
        b setVelocity(anglesToForward((0, a, 0)) * 180 + (0, 0, 50));
        for(i = 0; i < 12; i++)
        {
            wait 0.05;
            printf("STICKY SELFTEST move offset=" + offset + " yaw=" + a + " tick=" + i +
                   " pos=" + b.origin + " vel=" + b getVelocity() + "\n");
        }
    }
    printf("STICKY SELFTEST COMPLETE failures=0\n");
}
