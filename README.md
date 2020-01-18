# RushDuel-amxx
Rush Duel for knife

# SQL Doesn't work yet.
# Unfinished yet. Use at own risk.
 
 
Version 2.0.
- Rewritten completely and added rounds. 
- added rush_health_slash, rush_health_stab, rush_health_both cvars to control HP during these modes
- added rush_save_health, rush_save_pos: return after a duel with same hp as you had before it and in the same place?
- added rush_rounds cvar to choose how many rounds to play
- rush_alive cvar:
  - if 0, revives who made most kills. In case of draw, both revive.
  - if 1, revives who made most kills. In case of draw, both dead.
  - if 2, revives who killed the player on last round. 
  - if 3, revives both.
  
 A Rush Duel for knife that allows admins to create MAX_ZONES zones where to play ( default 4, can be changed by editing the #define ).
 This uses orpheu, and needs PM_Move, PM_Jump, PM_Duck: https://drive.google.com/open?id=1z6BYq6qIYOqxXnSveh9XMUj5U7Ox9_wD
 
 Plugin allows 2 users to challenge theirselves in a duel where they're automatically moving forward ( rushing agaisnt each other ).
 Once one of them dies, he will respawn in case rush rounds aren't over.
 
