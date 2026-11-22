// All three commands execute within onOpen, before another menu or input frame.
// Restoring after setu also marks the newly registered userinfo field as changed.
#define OPENCJ_REGISTER_FPS(RUN) \
    RUN "setfromdvar opencj_fps_saved com_maxfps"; \
    RUN "setu com_maxfps 999"; \
    RUN "setfromdvar com_maxfps opencj_fps_saved";

// Tutorial mode raises cl_maxpackets while the server sets the FPS, so FPS changes
// reach the server sooner, and gives the player's own value back afterwards. Same
// steps as for com_maxfps; any temporary value works, the restore sets the real one.
#define OPENCJ_REGISTER_MAXPACKETS(RUN) \
    RUN "setfromdvar opencj_maxpackets_saved cl_maxpackets"; \
    RUN "setu cl_maxpackets 15"; \
    RUN "setfromdvar cl_maxpackets opencj_maxpackets_saved";
