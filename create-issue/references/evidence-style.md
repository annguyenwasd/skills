# Evidence style — worked examples

The body is where verification turns into something a reader can act on. These
examples come from a real tracker and show what separates a body worth reading
from one that wastes the reader's afternoon.

## Good: the mechanism is named, and every claim says how it is known

```markdown
## What is wrong

`scripts/run-behavior-tests.sh:53` invokes `xcodebuild test` with no
`TEST_RUNNER_` environment variables. `xcodebuild` forwards a variable to a test
runner only when it carries that prefix, and both
`VehicleCare/Core/Data/EmulatorConfig.swift:25-27` and `AuthUITestHelper.firestorePort`
require it to see a port. So the iOS layer of the behaviour runner resolves
`8080/9099` whatever the environment says, even when the earlier `port_open`
probe correctly passed against a session emulator.

The runner therefore decides the session emulator is healthy, then runs the iOS
suite against the default ports — a peer session's database, or nothing.

## Evidence

**[read]** `scripts/run-behavior-tests.sh:53` — the invocation, with no
`TEST_RUNNER_` prefix anywhere in the script.

**[read]** `EmulatorConfig.swift:25-27` — reads `VEHICLECARE_FIRESTORE_PORT`,
defaulting to `8080`.

**[ran]** Not demonstrated cleanly: the simulator was shared with a concurrent
session. The code-level gap is plain from the script and the documented
contract.

## Not established

Whether the port mismatch is what produced the peer-session writes seen earlier,
or whether that had a different cause.
```

What makes it work:

- The first sentence names the file and line. A reader can be in the code in one
  click, before deciding whether to believe anything else.
- The mechanism is spelled out as a causal chain (no prefix → no port → default
  port), so the reader can check the reasoning without re-running anything.
- The `[ran]` claim is *negative*, and honest about why. That is worth more than
  a fabricated confirmation, and it tells the next person what would settle it.

## Bad: the symptom is real but the mechanism is invented

```markdown
## Bug

The tests are broken. run-behavior-tests.sh doesn't pass the port to the test
runner, so the tests fail.
```

Three problems, all of them common:

- "The tests are broken" — which tests, in which layer, under what invocation?
- The mechanism is asserted with no citation. If the reader checks and the file
  is at a different line, or the script *does* forward the variable, they now
  distrust everything else in the body.
- "so the tests fail" — but the report does not say they failed. In the real
  case they mostly passed, and the defect was a silent wrong-database run. The
  invented consequence is the exact opposite of the real one.

## Bad: the mechanism is right but nothing was verified

```markdown
## Problem

I think the delete path probably doesn't clean up records. It might be a race.
```

"I think", "probably", "might be" — a reader cannot act on any of it, and the
fan-out was skipped. If agents truly could not confirm the mechanism, that is
fine: file the *symptom*, cite what was read, and put the guess in the body
marked as a guess. What is not fine is presenting a guess in the register of a
finding.

## The two tags

`[ran]` — an agent executed something and this is what it saw. Include the
command (or the invocation that produced it) and the decisive output lines.
Quoting fifteen lines of setup to reach one decisive line buries the line.

`[read]` — an agent read code, docs, logs or history, and this is what is there.
Always `path:line`, or a commit hash, or an issue number.

A sentence with neither tag is usually a sentence that has not been checked. Use
them as a check on yourself: when you cannot tag a sentence, either go get the
evidence or move the sentence to "Not established".
