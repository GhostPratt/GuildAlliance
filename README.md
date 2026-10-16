# Guild Alliance

A World of Warcraft 3.3.5a (WotLK) addon that lets guilds form alliances. Members of
allied guilds can see each other's rosters and who is online, without touching the
50 slot friends list.

Built for AzerothCore based servers. Pure addon, no server module required.

## How it works

Every alliance shares a **key**. The addon turns the key into a hidden custom chat
channel that is never attached to a chat frame, so nothing from it ever appears in
chat. Over that channel each guild broadcasts its roster (names, levels, classes,
ranks, last online) and, every few minutes, the list of members currently online.

Presence comes from four sources, strongest first:

1. **Channel membership.** Anyone in the alliance channel is running the addon and is online.
2. **Reports.** One addon user per guild (the "reporter") announces who in their guild is online.
3. **`/who` polling.** For allied members who do not run the addon, the addon quietly runs
   `/who g-"Guild"` in the background (one guild every 90 seconds by default).
4. **Roster sync.** Members flagged online in a recent roster broadcast.

Only one client per guild broadcasts, so an alliance of large guilds does not flood the
channel. The reporter is the alphabetically first addon user from that guild who is online.

### Why not SendAddonMessage?

AzerothCore only accepts addon messages on PARTY, RAID, GUILD, BATTLEGROUND and WHISPER
(see `ChatHandler.cpp`). There is no cross-guild addon channel, so plain text on a custom
channel is the only transport available to a pure addon.

### Why not just the friends list?

AzerothCore caps the friends list at 50 (`SOCIALMGR_FRIEND_LIMIT`). A two guild alliance
already exceeds that. The addon keeps its own alliance roster instead, and offers
`/ga friend <name>` for pinning a few allies into the real friends list.

## Install

Copy the `GuildAlliance` folder into `Interface\AddOns\`. Interface version 30300.

## Use

Open the Social frame (default key **O**) and pick the **Alliance** tab next to Raid.

- Type the key your allies agreed on, optionally a password, and press **Join**. The
  setting is saved per character and the channel is rejoined automatically on login.
- **Refresh** asks allied guilds to resend rosters. **Sync** broadcasts your own guild
  roster now. **Leave** drops out of the alliance.
- Click a member to select them, then **Whisper**, **Invite** or **Add Friend**.
  Double click whispers, right click invites.
- **Online only** hides offline members.

A key binding "Toggle alliance tab" is available under Guild Alliance in Key Bindings.

The same actions exist as slash commands:

```
/ga                      open the Alliance tab
/ga join <key> [pw]      join (or create) an alliance by shared key, optional password
/ga leave                leave the alliance
/ga status               channel and sync status
/ga guilds               known guilds and member counts
/ga sync                 broadcast your guild roster now
/ga request              ask allied guilds to resend their rosters
/ga friend <name>        add a player to your real friends list (50 slot cap)
/ga forget <guild>       drop a guild's saved roster
/ga who on|off           toggle /who polling
/ga debug on|off         debug output
```

Guild leaders agree on a key (and ideally a password) out of game, then each member joins
once from the Alliance tab.

## Limits

- Anyone who learns the key and password can join the channel. Use a password.
- Chat messages are capped at 255 bytes, so a 300 member roster takes about 30 messages
  (roughly 20 seconds at the addon's send rate).
- `/who` returns at most 49 results (`MaxWhoListReturns`), so very large allied guilds with
  no addon users may show a partial online list.
- Servers with a chat level requirement (`ChatLevelReq.Channel`) block low level characters
  from sending on the channel; they still receive.
- Cross faction alliances depend on the server's `AllowTwoSide.Interaction.Channel` setting.

## Acceptance criteria

See [ACCEPTANCE.md](ACCEPTANCE.md). The repository is pushed after each criterion is
verified in game.
