// Shared by standalone scoreboard setup and the connection initializer.
// Binds are saved in the player's profile and apply on every server, so the
// idle TAB bind only runs saved dvars with fixed text. opencj_sb_tab first
// points opencj_sb_next at the stock fallback, then runs opencj_sb_mod. That
// dvar is not saved, so it exists only after OpenCJ set it up in this game
// session, and it points opencj_sb_next at the custom board. Without it, the
// fallback rebinds TAB to the stock +scores and shows the stock board for this
// press. An exec of a mod cfg would also detect the mod after leaving without a
// restart, but it prints a console line on every press.
// The saved dvars are created with seta and then copied, which keeps menu
// strings free of nested quotes.
#define OPENCJ_SETUP_SCOREBOARD(RUN) \
    setDvar opencj_sb_up "set opencj_sb_held 0; setu opencj_sb_active 0; bind TAB vstr opencj_sb_tab"; \
    setDvar opencj_sb_down "set opencj_sb_held 1; setu opencj_sb_active 1; bind TAB \\\"+scores; vstr opencj_sb_up; set opencj_sb_release\\\""; \
    setDvar opencj_sb_stock_text "bind TAB +scores; +scores"; \
    setDvar opencj_sb_tab_text "setfromdvar opencj_sb_next opencj_sb_stock; vstr opencj_sb_mod; vstr opencj_sb_next"; \
    setDvar opencj_sb_custom "vstr opencj_sb_down"; \
    setDvar opencj_sb_mod "setfromdvar opencj_sb_next opencj_sb_custom"; \
    RUN "seta opencj_sb_stock 0"; \
    RUN "setfromdvar opencj_sb_stock opencj_sb_stock_text"; \
    RUN "seta opencj_sb_tab 0"; \
    RUN "setfromdvar opencj_sb_tab opencj_sb_tab_text"; \
    RUN "set opencj_sb_held 0"; \
    RUN "setu opencj_sb_active 0"; \
    RUN "bind TAB vstr opencj_sb_tab"; \
    RUN "setu opencj_sb_ready 3";
