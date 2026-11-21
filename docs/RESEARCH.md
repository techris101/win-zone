# Format research: what top competitions do, and what WIN ZONE should copy

Researched 2026-11-20 from current sources (listed at the end). Proposals are marked **Proposal** and need the owner's approval before they are built.

## 1. What the top competitions do

| Competition | Format | Who goes through | Tie-breaks (in order) |
|---|---|---|---|
| UEFA Champions League (since 2024/25) | One table of 36 clubs; each plays 8 matches against 8 different opponents | 1-8 straight to round of 16; 9-24 to a two-leg play-off round (9-16 seeded); 25-36 out | goal difference, goals scored, away goals, wins, away wins, then **total points of the opponents faced** (strength of schedule) |
| FIFA World Cup 2026 | 48 teams, 12 groups of 4 | Top 2 of each group + **8 best third-placed** teams make a round of 32 | points, goal difference, goals scored, conduct (cards), ranking; third-placed teams compared on the same criteria |
| Africa Cup of Nations | 24 teams, 6 groups of 4 | Top 2 + **4 best third-placed** teams make a round of 16; single-match knockouts with extra time and penalties | points, goal difference, goals scored |
| Premier League | 20 clubs, everyone plays everyone twice | Table | goal difference, goals scored, then head-to-head points, then head-to-head away goals |
| La Liga | 20 clubs, double round robin | Table | **head-to-head points first**, head-to-head goal difference, then overall goal difference, goals scored |
| Swiss system (chess, many esports) | Fixed number of rounds; each round pairs players with similar scores, never the same opponent twice | Table after the last round | Minimum rounds for a clear winner = log2(players), rounded up |

Two patterns stand out:
- **Goal difference first** is the most common rule (Premier League, Champions League, World Cup, AFCON). Head-to-head first (La Liga) is the exception.
- **Big fields avoid "everyone plays everyone."** Groups (World Cup, AFCON) or a fixed number of matches per club (Champions League) keep the number of matchdays small.

## 2. Proposals for WIN ZONE (1v1 mobile, about 15 minutes of real time per match)

### Proposal A: four formats, recommended automatically by player count
| Players | Recommended format | Matchdays | Modelled on |
|---|---|---|---|
| 2-6 | **League**: everyone plays everyone once | players - 1 | Premier League (single round) |
| 7-16 | **League + knockout** (exists today) or **Knockout** | about 6-10 | AFCON knockouts |
| 12-48 | **Groups of 4 + knockout**, top 2 + best third-placed fill the bracket | 3 group days + knockout | World Cup 2026, AFCON |
| 32-128 | **League phase** (Swiss pairing): everyone plays 5-6 matches against different opponents of similar strength; top 8 to the round of 16, 9-24 to a play-off round, rest out | about 9 | Champions League |

The admin can always override the recommendation.

### Proposal B: one tie-break order for every table
points, goal difference, goals scored, head-to-head points among the tied players, wins, **strength of opponents** (total points of the opponents faced; important in the league phase where schedules differ), fewer forfeits or no-shows (our version of "conduct"), earlier registration.
A forfeit or no-show win counts as 3-0, as UEFA awards it (already implemented).
Best third-placed players are compared on points, goal difference, goals scored, wins, fewer forfeits.

### Proposal C: three schedule speeds
Real leagues play one matchday a week, which is too slow for mobile. Players are in different time zones, so every slot is in the evening of the zone most players are in (already implemented).
- **Standard:** one matchday every 48 hours at 18:00 (the current default).
- **Fast:** one matchday every 24 hours at 18:00.
- **One-day event:** rounds every 45 minutes starting at the chosen time (small knockouts only).

## 3. What players will see (statistics, next step)
For each player: position, points, goal difference, matches left, form (last 5), and plainly stated status: **qualified**, **still in the race** (with the points they still need in the best case) or **eliminated**, computed from the remaining fixtures. The same "qualification race" view goes on the public tournament page.

## Sources
- UEFA, league phase tie-break criteria: https://uefa.com/uefachampionsleague/news/0291-1bd88ae04870-e1e038c319e3-1000--champions-league-league-phase-standings-how-teams-level-on-
- ESPN, how teams qualify for the Champions League knockouts: https://global.espn.com/football/story/_/id/47622287/how-teams-qualify-2025-26-champions-league-knockouts
- MLS / ESPN, World Cup 2026 format and tie-breaks: https://www.mlssoccer.com/news/fifa-world-cup-2026-format-explained , https://www.espn.co.uk/football/story/_/id/48703925/world-cup-group-stage-explained-tiebreakers-third-place-teams
- Al Jazeera / beIN, AFCON format: https://aljazeera.com/sports/2025/12/15/africa-cup-of-nations-2025-full-match-schedule-teams-groups-and-format , https://prod.beinsports.com/en-us/soccer/africa-cup-of-nations/articles/who-qualifies-for-the-last-16-of-the-2025-africa-cup-of-nations-2025-12-27
- NBC Sports / Premier League, Premier League tie-breaks: https://nbcsports.com/soccer/news/premier-league-tiebreaker-rules-2026-goal-difference-head-to-head-record-how-it-works , https://www.premierleague.com/en/news/4183163
- CBS Sports / Sky Sports, La Liga and other leagues' tie-breaks: https://www.cbssports.com/soccer/news/premier-league-la-liga-bundesliga-serie-a-ligue-1-tiebreakers-and-table-including-promotion-relegation , https://www.skysports.com/football/news/11827/10239614/barcelona-have-head-to-head-advantage-over-la-liga-rivals-if
- Wikipedia / FIDE, Swiss system: https://en.wikipedia.org/wiki/Swiss-system_tournament , https://handbook.fide.com/chapter/C0401202507

Note: these are mostly reputable media explainers plus UEFA and FIDE pages; the official rulebooks remain the final authority for the competitions themselves. WIN ZONE only borrows the ideas.
