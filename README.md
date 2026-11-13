# raidroles

Job sign-up and party assignment for alliance and party events, in Vanacore-style windows (vcmenu).

- **Members** save the jobs they are willing to play, best first, once per character. When a leader runs a raid
  check they confirm (or auto-send) them, and their party and job pop up when assignments are posted.
- **Leaders** pick a fight (a saved composition of up to 3 parties x 6 slots), see who has and has not registered,
  let the addon auto-assign (or place people by hand), and post the result to chat and by tell.

    /addon load raidroles
    /roles            open the window      (/raid and /raidroles work too; /rr stays your Reraise alias)

## Members

1. **My Jobs**: click your main jobs; the order you click them in is your preference (Up/Down to change it).
   For each job in **Your Order**, rate your gear (**BIS**, **GOOD**, **TEMU**) and click its subjob button to pick
   up to **5 subjobs** you can use on that job (clicking the job's drop-down opens them too; **Clear all** empties them).
   **Job set** (top of the page): type a name and **Save** to keep this whole setup; load one back from the drop-down.
2. When a leader runs a raid check, a small window shows your saved jobs: **Send these** or **Edit my jobs**.
   Settings can make this automatic, or ignore checks.
3. When you join an alliance, the same window asks you to check your jobs are still right.
4. Your assignment pops up (Party 2 - WAR/SAM, Standby #2 or Outside Heal) and warns if you are on a different job
   or subjob. **My Assignment** lists every party, then Standby, Unassigned and Outside Heal. **Got it** tells the leader
   you are ready. **My Assignment** shows the whole raid.

## Leaders

1. **Fights**: saved compositions. Slots take a job and subjob (PLD/WAR), or a role (Tank, Healer, Support, Melee,
   Ranged, Nuker, Any) with or without a subjob. Four ship with the addon: Standard Melee, Magic MB, Ranged MB and
   Hybrid Ranged/MB Alliance (added once; delete or change them freely). The list scrolls, so keep as many as you like. Each fight has a **Comments** box (strategy, gear, who
   pulls) saved with it and shown on the Raid Board. Fights are shared by all your characters.
2. **Raid Board**: start a raid with a fight, then **Raid check ALL**. **Raid check: Not Received / Not Confirmed**
   asks only who is missing: before the post, alliance members who have not sent their jobs; after it, whoever did
   not get their assignment (offline or zoning) or has not confirmed it (tells it again). Auto assign refills the board as answers come in;
   Manual lets you place each member (click a member slot: people who can play it are listed first, by preference).
   Auto-fill prefers better gear (BIS, then GOOD, then TEMU), then the member's own preference, and only gives a
   slot to someone without its subjob when nobody else fits (that subjob is outlined in red). Click a slot's subjob
   to change it. Lock a slot so auto-fill leaves it. Each slot shows the member's current job/subjob
   and alliance party.
3. The board shows two sections per row: Party 1 | Party 2, Party 3 | **Outside Heal**, Standby 1-6 | Standby 7-12
   (standby holds 12, in order). Outside Heal is for healers
   outside the alliance: 2 Healer slots by default, filled after the parties). A member's name is green when they
   are in the alliance on the right job, red on the wrong one; hover it for details. The board always shows **3 parties**, then **Standby**: a party of 6 slots (Any job by default) filled after the
   parties, posted with the assignments, and each standby member is told their number and job. Under it,
   **Unassigned Role** lists everyone registered with no slot: send them **To standby** or **Sit out**.
4. **Roll Call**: everyone registered or in the alliance: who registered (addon, tell, by hand) and who has not.
   **Nudge** tells the ones who have not. Sit someone out, add someone by hand, or re-send an assignment.
5. **Post assignments**: one line per party in chat, plus a tell to each member (Settings: no-addon only,
   everyone, or off).

## Zerg (leader)

**Zerg** in the sidebar plans 3 bards and 3 corsairs who rotate through the parties:

- Pick who plays **BRD 1-3** and **COR 1-3** (people signed up with that job are listed first, or type a name).
- Each bard gets **2 songs** and each corsair **2 rolls** from drop-downs. The default is BRD 1 Minuet x2, BRD 2
  Madrigal x2, BRD 3 March x2; **Reset songs and rolls** puts those back.
- Bard n and corsair n are **team n**. Every team starts in party 1, sings / rolls, drops, joins party 2, then
  party 3, and then **stays** or **leaves** (a switch per person).
- **Rotation** shows who is in which party at each step; **Party leaders** shows the invite order: keep 2 spots
  open and invite team 1, then 2, then 3, each when the team before it drops.
- **Post zerg plan** puts it in chat and tells each bard and corsair their part (Settings); **Tell** re-sends one.
  Members with the addon see their part, and the whole plan, at the top of **My Assignment**.

## How the addon talks

Everything goes through ordinary chat, so it needs no server support and works for players without the addon.

| From | To | How |
|---|---|---|
| Leader | everyone | `[RR:ZRG]` zerg plan, `[RR:POLL:...]` raid check, `[RR:POST]` + `[RR:ASG]` per party + `[RR:SBY]` standby: in party/alliance chat, linkshell or linkshell 2 (Settings) |
| Member | leader | `[RR:REG]` jobs, `[RR:ACK]` ready: by tell (hidden from the chat log) |
| Leader | member | `[RR:YOU]` their assignment, `[RR:STB]` their standby number, and nudges: by tell |
| No-addon player | leader | `!rr WHM.B/SCH/RDM BLM.G/WHM` to sign up (.B .G .T = BIS GOOD TEMU, subjobs after slashes), `!rr` for their assignment, `!rr help` (the leader's addon answers: a chat bot) |

Party chat reaches the whole alliance once it is formed; before that, use a linkshell everyone shares. Lines are
sent one every 2.5 s (Settings, 1.5 s at least): the game refuses chat sent faster ("...A command error
occurred.") and the addon sends a refused line again. Posting a full raid with tells takes about 1-2 minutes.
Tells longer than 128 characters are cut off, so the addon's lines stay under 120.

Warnings for the leader: posting to party chat while not in a party (reaches nobody) or not yet in an alliance
(reaches only your party); and a member who was offline or zoning when told shows "Tell not received" on the
Raid Board.

## Commands

    /roles jobs WHM.B/SCH/RDM BLM/WHM   your jobs (best first), gear and subjobs
    /roles reply                 answer the last raid check
    /roles me                    your assignment
    /roles fight <name>          leader: start (or switch) the raid to a saved fight
    /roles check | auto | post | nudge | end
    /roles add <name> WHM.B/SCH ...   leader: register someone by hand
    /roles board | roll

Saved in `config/addons/raidroles/`: `fights.json` (shared) and `<Character>.json` (jobs, settings, raid).
