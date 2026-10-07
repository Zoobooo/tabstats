# Tab Stats

# Tab Stats

Beta. Tab list stats for Bed Wars, SkyWars, Murder Mystery and Duels: overlay tab list, respawn timers, configurable columns. Needs your own Hypixel API key.

## Nicks

A nicked player has no Hypixel profile under the name you see, so Tab Stats shows ? for their stats.

Tab Stats doesn't find out who is behind a nick by itself. Another plugin does that, for example the denicker plugin, and tells Tab Stats the real name. Tab Stats then shows that player's stats on the nick's row. If the plugin also sends the player's current name or UUID, Tab Stats uses those.

### How accurate a real name is

- A denick result is the name the player had **when** they were seen using that nick. Players can rename, so an old result can be a name that now belongs to nobody, or to someone else.
- The UUID never changes. It is the reliable part: a UUID always points to the same account, whatever it is called today.
- Newer results are more trustworthy. A sighting from this game is close to certain, one from months ago may be outdated. The same nick can also be used by different players at different times.

### Looking a player up yourself

Search the UUID (or the name) on NameMC. A UUID search shows the account's current name, even after renames.

### Replays

In replays every player has a replay UUID instead of their real one, so nicks are found as the players without a Hypixel profile.

### When something fails

If a lookup can't be done (no API key, a rejected key, Hypixel or Mojang not answering), Tab Stats says so in chat. In that case a missing stat or a missing nick mark can mean "couldn't check", not "not a nick".
