# Roster template: name normalization + Linear-id schema (meeting-sync owner resolution)

This is the TRACKED, PII-free substrate for the meeting-sync owner-resolution
pipeline (leaf L3, consumed by `bin/fm-meeting-sync.sh` `load_roster`). It ships
in the repo so a fresh clone has the load-bearing name-normalization logic (the
garble/alias table) and the resolution rules.

## Where the RUNTIME roster lives, and why this file is a template

The pipeline reads `data/roster-linear.md` at run time (override with
`FM_MSYNC_ROSTER_FILE`). That runtime file carries the REAL Linear user ids and
email addresses of the team, so it is deliberately kept OUT of git:

- `data/` is gitignored (fleet-level and David-private knowledge, AGENTS.md
  section 10). Real Linear UUIDs and personal email addresses are PII and this
  repo (`DQ4443/firstmate`) is PUBLIC, so the real roster must never be committed.
- This template holds only the non-PII substrate: the garble/alias
  normalization table, the resolution rules, and the table SCHEMA with the
  id/email columns REDACTED to placeholders.

Bootstrap the runtime file on a new machine:

```
cp docs/roster-linear.example.md data/roster-linear.md
# then fill the redacted id/email cells with real values:
bin/fm-linear.sh list_users --limit 100      # full workspace dump (id + email)
bin/fm-linear.sh get_user <name|email|id>    # single lookup
```

`load_roster` parses whichever file it is pointed at tolerantly, so the runtime
`data/roster-linear.md` uses the exact section headings and table shape below.
If the runtime file is absent, owner resolution degrades safely: every owned
item is flagged for David, never a silent wrong assignee.

## How resolution uses these tables (Decision 2b)

The pipeline never invents an owner. A stated name resolves through the
garble/alias table to a canonical name, the canonical name resolves through the
roster table to a real id, and only a truly unstated owner triggers the
default-David rule. Steps:

1. Stated + garbled -> normalize via the alias table, then look up the roster id.
2. Stated + resolves to a roster id -> use that id as `assigneeId`.
3. Stated + resolves to a non-eng-assignee -> do NOT default to David silently;
   assign David as driver and record the true owner, or gate.
4. Stated + a canonical name with NO Linear account -> UNRESOLVED: gate or
   ticket outside the epic with the true owner named; never invent an id.
5. Truly unstated owner -> default to David (the only default).
6. Multi-owner ("A and B will pair") -> Linear holds one assignee: assign the
   primary/driver, name the pair in the description, or gate. Never drop the
   second owner silently.

## Roster table (canonical name -> Linear user id) [REDACTED - fill at bootstrap]

Canonical names are the tokens the alias table maps to and the pipeline resolves
by. Fill the `Linear user id` and `email` columns from `bin/fm-linear.sh`. A
canonical name with no Linear account stays UNRESOLVED (rule 4).

| Canonical | Linear user id (assigneeId)                  | email    | eng assignee?          |
| --------- | -------------------------------------------- | -------- | ---------------------- |
| David     | `<fill: get_user david>`                     | `<fill>` | yes (default assignee) |
| Eddie     | `<fill>`                                     | `<fill>` | yes                    |
| Nate      | `<fill>`                                     | `<fill>` | yes                    |
| Eric      | `<fill>`                                     | `<fill>` | yes                    |
| Rixi      | `<fill>`                                     | `<fill>` | yes                    |
| Francis   | `<fill>`                                     | `<fill>` | yes                    |
| Yang      | UNRESOLVED (no Linear account at last check) | -        | no (gate)              |

## Non-eng-assignee table (Decision 2b step 3)

A stated owner who resolves here is NOT silently defaulted to David. Assign David
as driver AND record the true owner, or gate when it is genuinely someone else's
work.

| Person | Linear user id | email    | why non-assignee                                                      |
| ------ | -------------- | -------- | --------------------------------------------------------------------- |
| Yujie  | `<fill>`       | `<fill>` | PM/manager, not clearly an eng assignee. Do not auto-assign eng work. |

## Garble / alias table (Gemini mis-hearing -> canonical name)

This is the load-bearing, PII-free normalization logic. Gemini garbles spoken
names; normalize a stated (garbled-but-present) owner to a canonical name BEFORE
the roster lookup, so a garbled owner is not treated as "unstated" and the run
neither invents nor refuses an owner. Match case-insensitively;
longest/most-specific alias wins. Correct this table reality-wins as new
mis-hearings show up in transcripts.

This template ships FIRST-NAME variants only. Surname-bearing aliases (a Gemini
"FirstName LastName" full utterance) are real teammate surnames and are PII, so
they live ONLY in the gitignored runtime `data/roster-linear.md`, never in this
public template. At bootstrap, append each teammate's full-name utterance to the
runtime file's alias row so "FirstName LastName" also normalizes.

| Alias / mis-hearing (any case)         | Canonical                |
| -------------------------------------- | ------------------------ |
| David, Dave, Davey, DQ, D.Q.           | David                    |
| Eddie, Eddy, Eddi, Ed, E               | Eddie                    |
| Nate, Nathan, Nathaniel, Nat           | Nate                     |
| Eric, Erik, Erick                      | Eric                     |
| Rixi, Rishi, Ricky, Rixie, Rexi, Ricci | Rixi                     |
| Francis, Frances, Ziyi                 | Francis                  |
| Yang, Yeng                             | Yang (UNRESOLVED)        |
| Yujie, Yuji                            | Yujie (non-eng-assignee) |

"Rishi" is a common Gemini mis-hearing of "Rixi" and must resolve to Rixi, never
create a phantom "Rishi" owner. Nate/Nathan/Nathaniel all collapse to Nate.

## Recorded author-handle map (commit/PR handle -> canonical)

Code-authorship handles, used when a change is attributed by handle rather than
by spoken name.

| Handle      | Canonical |
| ----------- | --------- |
| prxthu      | Rixi      |
| noodleslove | Eddie     |
| DQ4443      | David     |
