# Acceptance criteria

Each criterion is verified in game on a 3.3.5a client against an AzerothCore server.
When one passes, mark it, note the date, and push.

Test setup: two characters in two different guilds (call them A and B), both with the
addon, both running `/ga join testkey secret`. A third character in guild B without the
addon (a playerbot works) covers the no-addon cases.

| # | Criterion | Status | Verified |
|---|-----------|--------|----------|
| 1 | Addon loads with no Lua errors. `/ga` prints help, `/ga` with no args toggles the window. | pending | |
| 2 | `/ga join testkey secret` joins the channel. Nothing appears in any chat frame: no join notice, no member list, no protocol text. `/ga status` shows state `joined`. | pending | |
| 3 | A and B see each other within 30 s: the other character is listed in the window, under the correct guild, as Online with source "in alliance channel". | pending | |
| 4 | Full roster sync: within 60 s of both joining, A's window lists every member of guild B (offline included) with level, class colour and rank in the tooltip. | pending | |
| 5 | Presence changes: B logs out, A shows B offline within 30 s with a "last seen" time. B logs back in, A shows B online within 30 s. | pending | |
| 6 | Persistence: after `/reload` and after a full relog, the alliance key is kept, the channel is rejoined automatically, and known rosters are still listed before any new sync arrives. | pending | |
| 7 | No-addon presence: a member of guild B who does not run the addon shows Online in A's window within one who-poll interval (90 s) while online, and drops to offline after they log out. | pending | |
| 8 | Only one reporter per guild: with two addon users in guild B online, `/ga status` shows `reporter: true` on exactly one of them, and A receives one roster broadcast, not two. | pending | |
| 9 | Friends list helper: `/ga friend <name>` adds the player; with 50 friends it refuses with a clear message instead of sending the request. | pending | |
| 10 | Leaving: `/ga leave` leaves the channel, clears the key, and the channel is not rejoined after `/reload`. | pending | |
| 11 | Wrong password: joining with a wrong password prints a clear message and stops retrying. | pending | |

## Verification log

(none yet)
