// Shared board controls. Floating offsets belong in rect, not integer origin.
#define BOARD_PANEL_COLOR       .055 .075 .095 .96
#define BOARD_ROW_COLOR         .13 .17 .21 .52
#define BOARD_HEADER_COLOR      .18 .24 .28 .82
#define BOARD_ALLOWED_COLOR     .07 .18 .21 1
#define BOARD_EXCLUDED_COLOR    .09 .115 .14 1
#define BOARD_MUTED_COLOR       .59 .68 .73 1
#define BOARD_ACCENT_COLOR      .37 .82 .86 1

#define BOARD_LABEL(_name, _text, _x, _y, _w, _h, _scale, _color) \
    itemDef \
    { \
        name _name \
        rect DEFAULT_RECT(_x _y _w _h) \
        type ITEM_TYPE_TEXT \
        text _text \
        textfont UI_FONT_NORMAL \
        textscale _scale \
        textalign ITEM_ALIGN_MIDDLE_LEFT \
        forecolor _color \
        visible 1 \
        decoration \
    }

#define BOARD_DVAR_LABEL(_name, _dvar, _x, _y, _w, _h, _scale, _color) \
    itemDef \
    { \
        name _name \
        rect DEFAULT_RECT(_x _y _w _h) \
        type ITEM_TYPE_TEXT \
        dvar _dvar \
        textfont UI_FONT_NORMAL \
        textscale _scale \
        textalign ITEM_ALIGN_MIDDLE_LEFT \
        forecolor _color \
        visible 1 \
        decoration \
    }

#define BOARD_MODE_STATE(_name, _response, _label, _shader, _status, _when, _bg, _tint, _statusColor, _x) \
    itemDef \
    { \
        name _name \
        rect DEFAULT_RECT(_x 132 58 30) \
        type ITEM_TYPE_BUTTON \
        style WINDOW_STYLE_FILLED \
        backcolor _bg \
        visible when (_when) \
        mouseEnter \
        { \
            setitemcolor _name backcolor .14 .25 .29 1; \
            play "mouse_over"; \
        } \
        mouseExit \
        { \
            setitemcolor _name backcolor _bg; \
        } \
        action \
        { \
            play "mouse_click"; \
            scriptMenuResponse _response; \
        } \
    } \
 \
    itemDef \
    { \
        rect DEFAULT_RECT((_x + 5) 139 12 15) \
        style WINDOW_STYLE_SHADER \
        background _shader \
        forecolor _tint \
        visible when (_when) \
        decoration \
    } \
 \
    itemDef \
    { \
        rect DEFAULT_RECT((_x + 21) 135 36 12) \
        type ITEM_TYPE_TEXT \
        text _label \
        textfont UI_FONT_NORMAL \
        textscale .16 \
        textalign ITEM_ALIGN_MIDDLE_LEFT \
        forecolor .91 .95 .97 1 \
        visible when (_when) \
        decoration \
    } \
 \
    itemDef \
    { \
        rect DEFAULT_RECT((_x + 21) 147 36 10) \
        type ITEM_TYPE_TEXT \
        text _status \
        textfont UI_FONT_NORMAL \
        textscale .12 \
        textalign ITEM_ALIGN_MIDDLE_LEFT \
        forecolor _statusColor \
        visible when (_when) \
        decoration \
    }

#define BOARD_MODE_TOGGLE(_onName, _offName, _response, _label, _shader, _dvar, _x) \
    BOARD_MODE_STATE(_onName, _response, \
        _label, _shader, "Allowed", (dvarInt(_dvar) != 0), \
        BOARD_ALLOWED_COLOR, WHITE_COLOR, BOARD_ACCENT_COLOR, _x) \
    BOARD_MODE_STATE(_offName, _response, \
        _label, _shader, "Excluded", (dvarInt(_dvar) == 0), \
        BOARD_EXCLUDED_COLOR, 1 1 1 .42, BOARD_MUTED_COLOR, _x)

#define BOARD_FILTER_TOOLBAR \
    itemDef \
    { \
        name board_fps \
        rect DEFAULT_RECT(201 132 104 30) \
        type ITEM_TYPE_BUTTON \
        style WINDOW_STYLE_FILLED \
        backcolor .09 .15 .19 1 \
        visible 1 \
        mouseEnter \
        { \
            setitemcolor board_fps backcolor .14 .25 .29 1; \
            play "mouse_over"; \
        } \
        mouseExit \
        { \
            setitemcolor board_fps backcolor .09 .15 .19 1; \
        } \
        action \
        { \
            play "mouse_click"; \
            open opencj_lb_fps; \
        } \
    } \
 \
    BOARD_LABEL(board_fps_label, "FPS filter", 209, 134, 78, 11, .13, BOARD_MUTED_COLOR) \
    itemDef \
    { \
        name board_fps_value \
        rect DEFAULT_RECT(209 146 78 12) \
        type ITEM_TYPE_TEXT \
        dvar "opencj_ui_board_fpsselected" \
        textfont UI_FONT_NORMAL \
        textscale .18 \
        textalign ITEM_ALIGN_MIDDLE_LEFT \
        forecolor WHITE_COLOR \
        visible 1 \
        decoration \
    } \
 \
    itemDef \
    { \
        rect DEFAULT_RECT(291 144 7 7) \
        style WINDOW_STYLE_SHADER \
        background "opencj_icon_downarrow" \
        forecolor BOARD_MUTED_COLOR \
        visible 1 \
        decoration \
    } \
 \
    BOARD_MODE_TOGGLE(ele_on, ele_off, "click_ele", "Ele", "opencj_icon_ele", "opencj_ui_board_ele_allow", 317) \
    BOARD_MODE_TOGGLE(any_on, any_off, "click_any", "Any%", "opencj_icon_anypct", "opencj_ui_board_any_allow", 379) \
    BOARD_MODE_TOGGLE(hb_on, hb_off, "click_hb", "Halfbeat", "opencj_icon_halfbeat", "opencj_ui_board_hb_allow", 441) \
    BOARD_MODE_TOGGLE(tas_on, tas_off, "click_tas", "TAS", "opencj_icon_tas", "opencj_ui_board_tas_allow", 503)

#define BOARD_MODE_HEADER(_shader, _x) \
    itemDef \
    { \
        rect DEFAULT_RECT(1.5 0 12 15) \
        origin _x COLUMN_HEADER_ORG_Y \
        style WINDOW_STYLE_SHADER \
        background _shader \
        forecolor 1 1 1 .55 \
        visible 1 \
        decoration \
    }

// Passive badges use the same 6:5 proportions as the HUD and scoreboard.
#define BOARD_FPS_ENTRY(_name, _dvar, _idx) \
    itemDef \
    { \
        name _name \
        rect DEFAULT_RECT(21.5 0 12 10) \
        origin CAT_FPS_ORG_X_IDX(_idx) CAT_FPS_ORG_Y_IDX(_idx) \
        style WINDOW_STYLE_DVAR_SHADER \
        dvar _dvar \
        forecolor 1 1 1 .8 \
        visible when (WHEN_ENTRIES_GTE(_idx)) \
        decoration \
    }

// Both boards highlight the entire row, behind its text and passive badges.
#define BOARD_ENTRY_BUTTON(_name, _response, _idx) \
    itemDef \
    { \
        name _name \
        rect DEFAULT_RECT(0 0 (CAT_TAS_ORG_X + CAT_TAS_CELL_SIZE_X - NR_ORG_X) NR_CELL_SIZE_Y) \
        origin NR_ORG_X NR_ORG_Y_IDX(_idx) \
        type ITEM_TYPE_BUTTON \
        style WINDOW_STYLE_FILLED \
        backcolor 0 0 0 0 \
        visible when (WHEN_ENTRIES_GTE(_idx)) \
        mouseEnter \
        { \
            setitemcolor _name backcolor .30 .37 .42 .85; \
            play "mouse_over"; \
        } \
        mouseExit \
        { \
            setitemcolor _name backcolor 0 0 0 0; \
        } \
        action \
        { \
            play "mouse_click"; \
            scriptMenuResponse _response; \
        } \
    }
