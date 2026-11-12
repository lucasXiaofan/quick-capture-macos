# Tickets

Capture anything with one shortcut — a todo, a question, an idea, a habit check-in, a bug, a
meeting note, a link worth keeping. An agent (Claude Code, Codex or Pi) classifies it and takes
the first turn; you answer like email until it is closed.

Tickets are flat and independent. **Structure** (kinds, projects, tags, the views below) is a
layer on top that organizes and draws them; changing it never changes a ticket.

The idea: you capture scattered progress as fast as you can type it, the agent does nine tenths
of the organizing with a fixed set of [tools](#the-agents-tools), and you read the result as
structure — projects, plans, and [designs](#designs) (flowcharts you and the agent both edit).

The plugin is off by default: switch it on in Settings → Tickets.

## Shortcuts

| Action | Default | What it does |
|---|---|---|
| New Ticket | ⌃⌥E | A small window: type, attach, then ⌘↩ **Send** (agent classifies a new ticket), ⇧⌘↩ **Append** (agent adds it to the most relevant existing ticket, e.g. a check-in to its tracking ticket), or ⌃↩ **Save** (no agent; your #hashtags set kind, project and tags). Esc hides it and keeps the draft. |
| Open Tickets | ⌃⌥⇧E | The main window. |

In the new-ticket window: **Screenshot** lets you select part of the screen (needs Screen
Recording permission), **File** picks files, and pasting or dropping an image attaches it. Type
`#` to tag a kind (`#habit`, `#todo`) or a project (`#cs646`); Tab accepts the suggestion. Tags
are only hints — the agent classifies untagged tickets too.

## What a ticket is

| Property | Values |
|---|---|
| Status | **New** (`unprocessed`), **Agent's turn** (`needs_agent`), **Your turn** (`waiting_human`), **Closed** |
| Kind | One of the kinds below; `misc` (Uncategorized) holds what fits nowhere |
| Project | Optional. Each project has a category (research, class, personal, or your own word); none is nested |
| Conversation | Your messages, the agent's replies (with the steps it took), attachments |
| Tags | Any number, from a layered vocabulary; each has a meaning and an action (see [Tags](#tags)) |
| Also | Title, one-line summary, start / due dates and an optional due time, takeaways, dated log entries (habits), history |

### Kinds

The starting list. It grows: the agent proposes a kind when nothing fits, and you can add, edit
or remove kinds in the window under **Agent → Kinds & rules**. Each kind has a description (how
the agent recognizes it), a rule (what the agent does) and a *view* (where it shows up).

| Kind | For | View |
|---|---|---|
| Habit | A check-in for something recurring | Habits heatmap |
| Todo | Doable in hours; at most a deadline | Plan → Todos |
| Plan | Spans days ("Nov 12–15 finish hw2") | Plan → Gantt |
| Question | Something to understand; open until you say you get it | — |
| Exam review | Practice questions for a course; needs a takeaway before closing | — |
| Idea, Experiment, Feature, Bug, Complaint, Meeting note, Shipping | Project work | Project page |
| Resource | A link, video, subscription or account note | Library |
| Principle | A personal rule; becomes part of the agent's instructions | Library |
| Uncategorized | Nothing fits | — |

## The window

| View | Shows |
|---|---|
| **Inbox** | Like mail: *Your turn*, *Agent's turn*, *All open*, *Closed*; search and kind filters; the conversation on the right. Reply with ⌘↩; **Add as note** (⌃↩) adds a message without asking the agent. |
| **Projects** | Cards grouped by category. Each shows the three open tickets most worth a look (due soonest, then waiting for you, then most recent) — click one to open it — plus **used days** (any day it got attention — one minute or ten hours count the same), activity strip, open / closed. A project page opens with three cards — where it stands (the first section of its context), what needs attention (open tickets, most urgent first), and what happened recently — then the plan, the rest of the context as one card per `##` heading (long ones fold), designs, takeaways and the full history, each linked to its ticket. Star a project as important; important or much-used projects with nothing shipped get a "make it visible" nudge. |
| **Habits** | A heatmap per habit, streak, this week, recent entries. **Check in today** sends the ticket for you. |
| **Plan** | A Gantt chart of tickets with a start and due date, and todos by deadline (Overdue, Today, Next 7 days, Later, No date). |
| **Library** | Designs, principles, answered questions, resources. |
| **Tags** | Every tag with its meaning, action and ticket count; define, merge and delete. |
| **Agent** | Everything about the agent in one place (below). |

Drag the edge of the sidebar or of the ticket list to resize it (double-click resets); the widths are remembered.

On a ticket you can rename it, change kind, project, dates and tags, close or reopen, run or
stop the agent, **Merge** it with others, and delete it (the file moves to `trash/`).

**Merging** makes one new ticket holding every message in time order. The originals are kept
untouched, marked "merged into #N", and come back with **Unmerge**. The agent merges tickets
about the same thing on its own (several tickets about shipping one video, say) and logs it.

## Tags

A ticket has exactly one **kind**, at most one **project**, and any number of **tags**. Kinds and
projects have their own lists; tags are a vocabulary that only grows, so it is kept as plain
files in a `tags/` folder inside the ticket folder, laid out to keep the top small:

```
tags/SKILL.md                      the rules, for you and for agents (yours to edit)
tags/references/index.md           depth 1–2 tags only, at most 30
tags/references/<l1>/<l2>.md       depth 3+ tags; past 15, what hangs below a topic moves to <l1>/<l2>/<l3>.md
tags/references/map.md             optional: how to classify; sent to the agent with every ticket
```

A tag is a path, `purpose/field/concept`, written one per line with its full path:

```
- `career/build`: make something that solves a real problem. Action: done = someone else can use it.
```

The text before `Action:` is the tag's **meaning** (what tickets with it have in common); the
text after is its **action** (what is done differently because of it). Other lines in these
files — headings, notes — are kept when the app rewrites the tag lines. A definition that starts
with `LEGACY` marks a tag that is no longer used for new tickets. Type `#career/build` in a
capture to tag it; the suggestion list also matches the last word (`#build`).

The rules the app enforces on the agent:

- Only tags from the vocabulary go on a ticket; anything else it lists is dropped and noted in the decision log.
- `define_tag` needs a full path under an existing parent, a meaning and an action; a project or kind name is not a tag.
- A new depth 1–2 tag is refused once the index holds 30: detail goes deeper.
- With a `map.md`, the agent gives every ticket exactly one top-level purpose.

Tags you type yourself are always kept. One that is not in the vocabulary shows as **loose**.

**Tags** in the sidebar is the manager: the vocabulary as a tree with ticket counts (a count
includes sub-tags; click it to see the tickets), meanings and actions editable in place, and the
loose tags on top. **Merge into** replaces a tag with another on every ticket — this is how a
loose tag is filed — and sub-tags move with their parent; **×** deletes a tag and what hangs
below it everywhere. **Ask the agent to tidy up** sends a ticket asking it to file the loose
tags and merge duplicates with the same tools.

The files are read when the app starts. Edit them by hand while it is closed, or use the Tags page.
Tags an earlier version kept in `structure.json` move into the folder on first launch.

## Notifications

Settings → Tickets → **Notifications** (both on by default; macOS asks once for permission).
Clicking a notification opens that ticket in the Tickets window.

| When | What you get |
|---|---|
| The agent answered and the ticket waits for you (or its run failed) | The ticket's title, *Your turn*, and the start of the reply. Not shown while the Tickets window is in front. |
| An open ticket is due today, no time set | A reminder at 7:00 that morning (`tickets.due_notify_hour`). |
| An open ticket is due at a time | A reminder 5 hours before (`tickets.due_lead_hours`). |

A ticket's deadline is its **Due** date; a time of day can be set next to it once there is a
date, and the agent sets both when a capture says "by Friday 3pm" (`due`, `due_time`). Reminders
are re-planned whenever tickets change, cover any open ticket with a due date (todos and plans
alike), and one whose moment has already passed is not sent late. They are delivered by macOS,
so they arrive even if Quick Capture was quit in between.

## Designs

A design is a canvas: cards, groups, images and labelled arrows. They are how you and the agent
agree on how something works. **Library → Designs** lists them by project.

- **Edit like an Obsidian canvas**: double-click empty space for a card, double-click a card,
  group label or arrow to edit it (cards are Markdown), drag a dot on a card's edge to another
  card to connect them, drag to move (a group carries what is inside it), drag the corner to
  resize, pick a colour, ⌫ deletes, ⌘Z undoes. Drag the background to pan; pinch or ⌘-scroll to zoom.
- **Files**: `designs/<name>.canvas` in the ticket folder, in the open
  [JSON Canvas](https://jsoncanvas.org) format, so they also open in Obsidian. `designs/index.json`
  holds each one's title, project and one-line description (which the agent sees).
- **Import a folder…** copies the `.canvas` files of any folder (an Obsidian vault folder, say)
  and the images they show into the ticket folder. The originals are only read, never changed;
  a design that already exists is skipped. The project is guessed from the file name.
- **The agent** sees the list of designs, reads the files, and draws or redraws one with
  `save_design` (it gives boxes and arrows; the app lays them out). A design open in the window
  reloads when the agent redraws it.

Two designs under **This system** are not files: they are drawn from the current rules each
time you open them, so they cannot go stale.

- **How the ticket system works** — your input → what the agent is told → its action space and
  tools → the files → the views.
- **How a capture is categorized** — kind → project → tags → status, with every current kind,
  its rule and the view it lands in, the projects by category, and the tag registry.

**Save a copy to edit** turns either into a design of your own.

## The agent

Each time you send or reply, the chosen CLI runs once with: your instructions, the kinds and
their rules, the tags, the projects, the designs, your principles, your corrections, its tools,
a list of other tickets, and the ticket. It replies and ends with a small block saying what it
decided for this ticket (kind, project, tags, status, dates, log entries) and which tools to run;
the app applies that and records it.

Under **Agent** in the window:

- **Instructions** — the standing instructions (short on purpose). Editable; stored in `agent/instructions.md`.
- **Tools** — what it may do beyond the ticket it is answering (below).
- **Kinds & rules** — one row per kind.
- **Corrections** — what you told it that it got wrong. Every correction is in every prompt from then on.
  Press **Correct agent** on a ticket to add one; changing a ticket's kind or project by hand adds one automatically.
- **Decision log** — every change it made to a ticket, with its reasons.
- **Full prompt** — exactly what it is told.

A failed or stopped run leaves a note on the ticket; press **Run agent** to retry.

### The agent's tools

The agent's action space, apart from reading, searching and running code within its
[access](#what-the-agent-may-do). Tools go in the `actions` list of its reply; each use is one
line in the decision log, and a refused one says why.

| Tool | Does |
|---|---|
| `create_ticket` | Adds a ticket: splits a capture that holds several things, turns a meeting's action items into todos. At most 10 per turn. |
| `update_ticket` | Changes another ticket: moves a plan's dates, closes a todo, re-files it, adds or removes tags. Leaves a note on that ticket. |
| `merge_tickets` | Makes one ticket out of several about the same thing (the originals are kept). |
| `set_principle` | Records a personal rule, or rewords an existing one. |
| `update_project` | Keeps a project current: name, category, note, maintained context, context tickets, importance. |
| `define_tag`, `merge_tags`, `delete_tag` | Maintain the tag vocabulary in `tags/` (see [Tags](#tags)). |
| `add_kind` | Proposes a new kind when nothing fits and two or more tickets share a shape. |
| `save_design` | Draws or redraws a design (see [Designs](#designs)). |

Older reply fields (`merge_with`, `new_kind`, `project_updates`) still work.

### Which agent, and how hard it thinks

Settings → Tickets sets the **default agent** and, for each of Claude Code, Codex and Pi, its
**model** (a drop-down of what that CLI offers: Claude's aliases, Codex's list for your sign-in, Pi's `--list-models`) and **effort** (Claude Code `--effort`: low … max; Codex reasoning effort: minimal …
xhigh; Pi thinking level: off … xhigh). Empty means the CLI's own default.

For a single answer, pick another agent, model or effort in the new-ticket window (top right) or next
to **Send** in a ticket's reply box; **Run agent** uses the same picker. The choice is frozen when sent and applies to
that run only (a reply during a run keeps its choice for the next turn), and the ticket records which agent and effort answered.

### Letting the agent update Quick Capture itself

Settings → Tickets → **Self-update** (off by default). The agent may then edit this app's own
source — to build a feature you ticketed, fix a bug, change the ticket system — and order a
**rebuild and restart** by setting `restart_app` in its reply. It never restarts the app itself
(that would stop it mid-run). The source folder is the one the app was built from, or the one
you choose; it must be a git checkout with `Package.swift` and `scripts/build.sh`, and the app
must be the installed `/Applications/Quick Capture.app` (`scripts/build.sh --install`). The
folder is added to what the agent may change. Needs Workspace or Full access; runs go one at a
time while it is on. Every rebuild requires confirmation and an empty running/queued workload. A busy update remains pending for a manual retry.

How you get back if something goes wrong:

1. **Git snapshots.** Before every run the whole project folder is saved as a git commit under
   `refs/quick-capture/snapshots/` — uncommitted and new files included, without touching your
   branch, index or working tree. After the run, what changed is listed under **Agent → App updates**
   (and noted on the ticket), each with its rollback point.
2. **Safe build.** `scripts/build.sh --install` runs from a helper script that outlives the app.
   If the build fails the running app is untouched; the compiler errors go onto the ticket for the
   agent to fix, or you discard the changes.
3. **Backup and health check.** Before restarting, the installed app is copied to
   `self-update/backups/` in the ticket folder. The new version must report healthy after ten
   seconds. If it doesn't within a minute, the helper puts the old app back, and the old app
   restores the source from the snapshot. Nothing is lost: the failed attempt stays in git.
4. **Roll back any time.** **Roll back…** on an update puts those files back to how they were
   (what you changed since is snapshotted first, so even a rollback can be undone) and, if the update
   was already running, rebuilds the app to match.
5. **If the window itself is broken:** run `self-update/rollback.sh` from the ticket folder; it
   restores the previous app. The source is in git: `git for-each-ref refs/quick-capture/snapshots/`.

Changes you make to the project while a run is going are counted as the agent's.

### What the agent may do

Settings → Tickets → *What the agent may do*. The agent never asks per step; it works inside
the scope you pick.

| Access | Claude Code | Codex | Pi |
|---|---|---|---|
| Read only | Read files, search the web | Read-only sandbox, web search | Read files |
| Workspace (default) | Edit files and run sandboxed commands in the working folder and extra folders; web search | Same (`workspace-write`); network for commands if enabled | Read and edit files, no commands (Pi has no sandbox) |
| Full access | No sandbox: any command, installs, any file | Same | Same |

The working folder defaults to `workspace/` in the ticket folder. Add project checkouts under
**Add a Folder the Agent May Change** so it can fix bugs there. Installing software
system-wide, or anything else outside those folders, needs **Full access**. Whatever the scope,
the default instructions tell it not to spend money, send messages as you, or delete your files.

## Files

Settings → Tickets → **Ticket folder** (default: the app's data folder). Everything is plain text:

```
tickets/0012.md          one Markdown file per ticket
attachments/12/…         its screenshots and files
structure.json           kinds (with rules) and projects
tags/                    the tag vocabulary: SKILL.md, references/index.md and deeper files
designs/<name>.canvas    designs (JSON Canvas); index.json has titles and projects
designs/assets/…         images shown on designs
agent/instructions.md
agent/decisions.jsonl
agent/corrections.jsonl
workspace/               the agent's default working folder
trash/                   deleted tickets
```

A ticket file has front matter (id, title, status, kind, project, tags, dates, takeaways, log,
history) and the conversation; it reads fine in Obsidian. Each message starts with a
`<!-- msg {…} -->` line — keep those when editing by hand. Files are read when the app starts.

## Settings (`config.json`)

See [configuration.md](configuration.md#tickets).

### Maintained project context and workspace plans

Each project page has an editable Markdown **Project context** section and linked context
 tickets. Context is saved in `structure.json` (`context`, `context_ticket_ids`) and included
in agent prompts. A ticket keeps its primary project and may also have `related_projects`
(existing IDs); project pages include shared tickets once. Agents can maintain context
through optional `project_updates` entries in their ticket response.

On the first load of an existing project's `workspace/<project-id>/CONTEXT.md` and `PLAN.md`,
the app imports context, links source tickets referenced as `tickets/NNNN.md`, and creates
a dated plan ticket for each stage heading such as `## 1. Prepare — Nov 10–12` or
`## 2. Analyze — Nov 20–Dec 1`. The plan must contain an ISO date supplying the year.
Dates are provisional; checklists remain pending. The `workspace_imported` marker and
per-stage tags prevent duplicate imports and preserve later edits. Plans appear on the
project page and the global Plan chart; loose Markdown checklists alone do not feed that chart.

For workflow diagrams, code ownership, concurrency limits and known gaps, see
[工作流与代码架构（中文）](tickets-workflow.zh-CN.md).
