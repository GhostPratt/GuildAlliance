# Acceptance criteria

Each criterion is verified in game on a 3.3.5a client against an AzerothCore server.
When one passes, mark it, note the date, and push.

Test setup: two characters in two different guilds (call them A and B), both with the
addon, both joining key `testkey` with password `secret` from the Alliance tab. A third
character in guild B without the addon (a playerbot works) covers the no-addon cases.

| # | Criterion | Status | Verified |
|---|-----------|--------|----------|
| 1 | Addon loads with no Lua errors. The Social frame (O) shows an **Alliance** tab after Raid; clicking it shows the alliance panel with the key/password boxes and buttons, and the other four tabs still work. `/ga` opens the tab. | pending | |
| 2 | Entering key and password and pressing **Join** connects: the status line reads "connected". Apart from the addon's one line naming the chat channel number, nothing appears in any chat frame: no join notice, no member list, no protocol text. | pending | |
| 3 | A and B see each other within 30 s: the other character is listed in the panel, under the correct guild, as Online with tooltip source "in alliance channel". | pending | |
| 4 | Full roster sync: within 60 s of both joining, A's panel lists every member of guild B (offline included) with level, class colour and rank in the tooltip. | pending | |
| 5 | Presence changes: B logs out, A shows B offline within 30 s with a "last seen" time. B logs back in, A shows B online within 30 s. | pending | |
| 6 | Persistence: after `/reload` and after a full relog, the key is still filled in, the channel is rejoined automatically, and known rosters are still listed before any new sync arrives. | pending | |
| 7 | No-addon presence: a member of guild B who does not run the addon shows Online in A's panel within one who-poll interval (90 s) while online, and drops to offline after they log out. The Social frame never opens on its own while polling runs. | pending | |
| 8 | Only one reporter per guild: with two addon users in guild B online, `/ga status` shows `reporter: true` on exactly one of them, and A receives one roster broadcast, not two. | pending | |
| 9 | Selection buttons: selecting a member enables Whisper, Invite and Add Friend. Whisper opens a tell, Invite sends a group invite, Add Friend adds them. With 50 friends, Add Friend refuses with a clear message instead of sending the request. | pending | |
| 10 | Leaving: **Leave** leaves the channel, clears the key, and the channel is not rejoined after `/reload`. | pending | |
| 11 | Wrong password: joining with a wrong password prints a clear message and stops retrying. | pending | |
| 12 | Guild key pickup: an officer (rank 0 or 1) of guild B joins `testkey`. A guild B member with the addon and no key, already online, receives it within 15 s and connects; another guild B member who logs in afterwards has it filled in and connected within 20 s of entering the world. Status line shows "guild, set by <officer>". | pending | |
| 13 | Rank enforcement: a guild B member of rank 2 or lower joins a different key. Other members keep the officer's key, and the member's own status line says "personal". | pending | |
| 14 | Officer leave: the officer presses Leave. Online members of guild B drop out of the alliance within 15 s with a chat message naming the officer. | pending | |
| 15 | Alliance chat: with A and B connected, A types `/N hello` (N from the status line) and B types `/gac hi`. Both messages appear in both players' main chat window as `[N. GA<key>] Name: ...`, while roster sync traffic and join/leave notices stay hidden. `/ga chat off` removes the channel from chat and rosters keep syncing; `/ga chat on` brings it back. After Leave the channel is gone from the chat window. | pending | |

## Verification log

(none yet)
