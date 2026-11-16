// Historical ten-map acceptance fixture. Production membership comes only from SQL.
rows()
{
    result = [];
    names = strTok("mp_dark mp_cj_sky_bounce mp_all_in mp_bouncer_training mp_futile_fixed mp_blue2 mp_descent_v2 mp_to_the_moon mp_galaxy mp_mystic_v3", " ");
    for (i = 0; i < names.size; i++)
        result[i] = row(names[i], "2010-01-01", "1", "Fixture mapper");
    result[0][3] = "kie, Second mapper";
    result[4][1] = "2013-01-24";
    result[4][3] = "pcbouncer";
    return result;
}

row(name, date, membership, authors)
{
    result = [];
    result[0] = name;
    result[1] = date;
    result[2] = membership;
    result[3] = authors;
    return result;
}
