# Scoreboard input and silent aliases

The scoreboard uses the menu/input path described below. Prototype chronology
and client-session acceptance notes are archived privately.

## Verified silent alias encoding
Use unquoted dvar identifiers and preserve escaped quotes through both parsers.
The installed client's String_Parse (0x54b510) calls the general parser; its quoted
string handling at 0x571128 recognizes escaped quote and backslash. The linker
consumes one escape layer, so the source binding quotes need another layer.
Decompressed fastfile checks now assert separate setDvar name/value tokens and the
exact escaped binding. Hold/release continues to use the previously tested rebinding
mechanism, with vstr replacing exec. No stock +scores call on key-down.
