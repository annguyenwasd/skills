---
name: create-issue
description: >-
  File a GitHub issue on the repository the agent is standing in, after
  verifying the user's claim against the code. Use this skill whenever the user
  asks to file, open, log, raise or report a bug, defect, ticket or issue — or
  says things like "this should be an issue", "add it to the backlog", "note
  this down as a defect", "track this", "file it", or pastes a failure/stack
  trace and asks for it to be recorded. Also use it when the user invokes
  /create-issue. It fans out verification subagents before filing, refuses
  duplicates and already-fixed reports, routes feature requests away to the
  repository's own feature path, applies only labels that already exist, and
  files nothing when the claim does not hold up.
argument-hint: "[--dry-run] [--repo <owner/name>] <what to file>"
---

# /create-issue

File a GitHub issue on the repository the agent is standing in.

A filed issue is a claim someone else will act on. The reader was not in this
conversation, cannot re-run what you ran, and will spend real time on the
strength of what the body asserts. That is what shapes every step below.

## The rule that shapes everything

**Never file from the user's description alone.** A user's report is a
hypothesis about their own system. Sometimes it is exactly right, sometimes the
mechanism they name is wrong while the symptom is real, sometimes it was fixed
last week, sometimes the code already does the thing they think is missing.

An issue that asserts a mechanism the code does not have is worse than no
issue: it sends someone to the wrong file, and it teaches the tracker to be
distrusted. So every factual sentence in the body must trace to something a
subagent read or ran, and anything you could not establish gets said out loud
rather than smoothed over.

This is also why an issue is cheap to *prepare* and expensive to *unfile* — you
cannot unring a notification.

## Steps

### 0. Resolve the repository

The default target is the repository containing the working directory: run
`gh repo view --json nameWithOwner -q .nameWithOwner`. If the user named a
different repository, or the invocation carried `--repo`, use that instead.

Stop and ask when the two disagree in a way you cannot resolve — filing into the
wrong tracker is a public, notification-generating mistake.

### 1. Recon

Run the bundled script:

```sh
bash <skill-dir>/scripts/gather-conventions.sh
```

It prints the repository identity, every existing label, the issue templates,
the recent issue titles, a sample recent issue body, and any feature-vs-defect
routing rule it finds in the repository's `AGENTS.md` or `CLAUDE.md`.

Read that output before writing anything. It is what makes the issue look like
it belongs in this tracker rather than in the abstract — the labels it can
legitimately wear, and the shape a reader of *this* repository expects.

### 2. Classify: defect, feature, or neither

Many repositories split these. A common rule is "requirements and features go to
a spec directory; defects go to the tracker" — recon prints it if the repository
states one.

- **Defect** — something the code does that it should not, or does not do that
  it should. Proceed.
- **Feature or requirement** — a capability that does not exist yet. Do not file.
  Tell the user where the repository puts those and offer to write it there.
  Filing a feature as a defect pollutes both the tracker and the roadmap.
- **Question, task or chore** — a tracker can hold these, but they need a
  different body. Ask which the user wants before filing.

### 3. Fan out the verification agents

This is the part that makes the issue worth reading. Spawn **three subagents in
one message** so they run in parallel, each on a different angle. Three because
each answers a question the others cannot:

1. **Reproduction** — *does the symptom actually happen?*
   Ask for the repository's own way to run things (its test command, its run
   script, the documented repro). What it ran, what it saw, the exact output.
   This is the only agent that can produce `[ran]` evidence, and it is the
   agent that turns a plausible story into a demonstrated one.
2. **Code truth** — *does the code do what the user says it does?*
   Read the named files, their callers, and any shared helper in the path. Ask
   for `path:line` citations and for the mechanism, not a summary. This agent
   is what stops a wrong-mechanism issue, and the thing it is most useful for is
   finding that the guard, retry, or validation the user believes is missing
   does exist somewhere else.
3. **History and duplicates** — *is this already known?*
   Search open **and closed** issues, and the git log for the named files and
   the user's wording. A closed-as-fixed issue or a commit that touched exactly
   this code changes the whole report.

Tell each agent to say plainly when it could not establish something. Silence
from an agent is not confirmation — it is a gap, and gaps go in the body (see
"Not established" below). If a repository's own `AGENTS.md` routes decisions
through a decision model, this is where its verdict would be consulted; if
there is none, judge the evidence yourself in the next step.

Give the agents the user's exact words, plus every concrete detail the user
supplied — error strings, file paths, times, device names. Those details are
what make a search land.

### 4. Judge

File only when the evidence supports the claim:

- Code truth confirmed the mechanism with citations, **or** reproduction
  demonstrated the symptom.
- No duplicate, and no commit or closed issue that already fixed it.
- It is a defect (step 2), and the repository is the right tracker (step 0).

Otherwise, do not file, and say why — which agent found what. A refusal that
cites `Engine.swift:88` and the commit that fixed it is a useful answer. If the
symptom is real but the mechanism is not, file it describing the symptom and
put the user's proposed mechanism in the body as a hypothesis explicitly marked
as unconfirmed.

### 5. Write the body

Match the pull-request template to what recon showed; when recon shows nothing
distinctive, use this structure, which has held up across trackers:

```markdown
## What is wrong
The defect in two or three sentences: what happens, and what should happen
instead. Write the mechanism you verified, with `path:line` citations.

## Evidence
Each claim tagged with how you know it:
- **[ran]** the command, when it ran, and the exact output (trimmed to the
  decisive lines).
- **[read]** `path/to/File.ext:120-134` — what the code does there.

## Not established
What no agent could confirm, and the specific things worth ruling out next.
Omit this section only when everything was established.

## Related
Issue numbers, commits, or prior art, with one clause each on the relationship.
```

The `[ran]` / `[read]` tags carry their weight: they let a reader weigh a claim
without re-deriving it, and they force you to notice when a sentence you were
about to write has no evidence behind it.

Keep the title declarative and specific — it should name the defect and its
mechanism, not the emotion or the requestor. "Emulator-port seam residuals:
run-behavior-tests.sh never forwards TEST_RUNNER_ ports" tells a reader what is
broken before they open it; "Problem with tests" does not.

See `references/evidence-style.md` for a worked example of a good body and of
the two ways these go wrong.

**Write the body in normal prose.** It is read by other humans (and their
agents), not by this conversation. No local shorthand, no caveman compression,
no restating the conversation the reader cannot see.

### 6. Labels

**This step applies only to an issue you are actually filing.** If the run ended
at step 2 or step 4 — a feature routed to the spec path, a duplicate, a claim
that did not hold — there is no label to choose, and picking one anyway is a
step towards filing something you already decided not to file.

**When you are filing, apply the best-fitting label yourself — do not wait to
be asked.** An unlabelled issue is unfindable: nobody triaging by label will
ever see it, and the user filing it in a hurry is exactly the person least
likely to remember to add one. Choosing is cheap and reversible; leaving it
blank is not.

If the user named a label, that wins — they know their tracker. Otherwise pick
the closest match from recon's label list: a defect is `bug`, a docs gap is
`documentation`, a new capability that slipped through as an issue is
`enhancement`. Reach for the label the tracker already uses for that kind of
issue rather than the one whose description reads best in the abstract.

Use **only** labels that already exist — recon printed the list, and
`file-issue.sh` drops anything else with a warning. Minting a new label splits
the tracker's taxonomy and nobody agreed to it. Only when nothing existing fits
is an unlabelled issue the right answer, and then say so in your report so the
user can decide whether to add one.

### 7. File

Write the body to a file, then:

```sh
bash <skill-dir>/scripts/file-issue.sh \
  --title "<declarative title>" \
  --body-file /tmp/issue-body.md \
  --label bug
```

`--dry-run` there is the **script's** flag, not `gh`'s — `gh issue create` has no
dry-run mode at all, and reaching for one wastes a step. The script prints the
invocation and the body and exits without filing. Use it whenever the user is
still shaping what they want to say, and whenever you want the body in front of
the user before it becomes public.

### 8. Report

Give the user: the issue URL, the labels applied, and **one line per claim they
will be surprised by** — the mechanism that turned out different, the duplicate
found, the thing an agent could not confirm. Report what the agents found even
when it contradicts what the user said; their report was a hypothesis and they
need to know which part of it survived.

## Never

- File without having spawned the verification agents.
- Write an absolute you have not checked. "Only", "never", "always", "the sole",
  "nothing else", "the first" are claims, and readers weigh them more heavily
  than the hedged sentences around them — which is why an unverified one does
  more damage than an unverified ordinary sentence. Both times an agent in
  testing got a mechanism right and then overstated it, the absolute was
  load-bearing for the recommendation: "only the documented release command
  deploys this" was false because a second, less guarded command did. When the
  evidence covers the common case but not every case, write the weaker true
  sentence ("the documented release path does X") and let the reader generalise,
  or say plainly what you did not enumerate.
- Claim `[ran]` for anything you did not run.
- Apply a label that does not exist.
- File a duplicate, or one that a commit already fixed — report the existing
  issue or commit instead.
- File a feature request where the repository tracks features elsewhere.
- Paste an entire log or stack trace; quote the decisive lines.
