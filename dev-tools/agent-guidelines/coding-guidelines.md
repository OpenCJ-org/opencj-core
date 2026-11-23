# OpenCJ coding guidelines

**Status: ACTIVE.**

These agreed rules apply to first-party OpenCJ code. They complement
the repository's operational, privacy, licensing and test-maintenance rules.
Keep this file as the single canonical policy; other agent entry points link here.

## Scope

One policy for all first-party OpenCJ code: `client-mod`, `cod4x-server`,
`dev-tools`, `discord-integration`, `libcod`, `server-db`, `server-ext`,
`server-gsc`, and future OpenCJ repositories. It covers production code,
scripts, tests, build tools, SQL, and hand-authored menu definitions.

The principles apply across Python, C, C++, GSC, SQL, and other languages.
Syntax follows the language; readability expectations do not disappear in
test code or a different repository.

Generated output and vendored upstream code are not candidates for blanket
reformatting. Apply the principles to the generator and first-party changes.
Respect binary layouts, engine interfaces, macro semantics, and externally
defined names. Any exception should identify the actual constraint; "the
surrounding code is already compressed" is not a sufficient reason.

## Rules, in priority order

### R1. Give each executable step its own line

Every branch
and loop body must be expanded, including a single return, break, continue,
or call. There is no short-body or guard-clause exception in any first-party
language or repository.

- Put each statement on its own line. Do not join assignments, calls, returns,
  cleanup, or state transitions with semicolons on one line.
- Put every branch and loop body on separate, indented lines. In C, C++, and
  GSC, use braces even for a single-statement body. Put function bodies on
  separate lines too.
- Put independent variable declarations and struct fields on separate lines.
  Put Python imports of separate modules on separate lines.
- Use spaces around assignment and binary operators and after commas, following
  the language's syntax. Separate functions and distinct phases with blank lines.
- In SQL, expand procedural branches and transaction steps; in menu definitions,
  put distinct properties and action statements on separate lines.
- Wrap long calls and expressions at semantic boundaries. Embedded SQL should
  expose SELECT, JOIN, WHERE, ordering, and CASE branches; string literals do
  not exempt embedded code from readable layout.

A `for` header is one construct, not three statements to split. A short literal
tuple, vector, or homogeneous data-table row may stay together when it is clearer.
Required macro continuations preserve the same vertical structure.

**Layout review prompts, not automatic failures:** aim for about
100 columns and reconsider lines over 120 columns. Indivisible literals,
protocol data, and syntax constraints may justify exceptions. Never shrink
names or remove spaces merely to meet a line-length target.

### R2. Name the domain concept, role, and units

Use names such as `pendingJob`, `routeName`, `elapsedMs`, and
`frameIndex`, rather than `j`, `name`, `elapsed`, or `n` where those
names would require reconstruction from distant code.

A name passes review when the reader can tell:

1. What domain object or value it represents.
2. Its role: identifier, count, index, state, limit, or value.
3. Its units or representation when those could be confused.

Use verb phrases for functions that perform an action, and predicates for
Boolean questions. Avoid names such as `process`, `handle`, or `data`
when a more specific name would describe the responsibility.

Conventional mathematical names,
coordinates, and simple local loop indices are acceptable when their role is
already clear in context. Being mathematical, familiar to the author, or used
in a short function is not sufficient by itself. Prefer a descriptive name
when it makes the value's role appreciably clearer. In `smoothstep`, use
`interpolation_factor` rather than `t`: the descriptive name explains what the
parameter represents even though the function is short.

For example, `x` and `y` in a coordinate calculation or `i` in a simple local
loop may remain short. Assess the meaning conveyed at the use site, not merely
whether a symbol is conventional somewhere in mathematics. Do not rename an
external interface just to satisfy this rule; give it a meaningful local name
where useful.

### R3. Keep expression logic understandable

Rule 1 governs layout: statements, bodies, declarations, and line wrapping.
Rule 3 governs the logic inside an expression. An expression can obey every
layout rule while still combining several decisions or transformations that
should be exposed separately. Do not justify a rule 3 rewrite solely by showing
that compressed statements could be placed on separate lines.

Both a short, simple conditional expression
and an expanded if/else are acceptable for a choice between two values. Neither
form is mandatory, and an existing readable form need not be converted to the
other.

- Separate calculations, validation, and mutations. Do not hide unrelated side
  effects in conditions, arguments, conditional expressions, or comma expressions.
- Use a conditional expression only for a short, side-effect-free choice
  between two values. Do not nest conditional expressions.
- Give complicated conditions meaningful intermediate names or named predicates.
  Do not replace a readable two-term condition with a helper solely to add a name.
- Prefer an ordinary loop to a comprehension or chained expression that combines
  nested iteration, filtering, branching, and conversion.

**Review prompt, not an automatic failure:** explain or simplify
conditions with more than three Boolean terms. The purpose is to expose the
meaning of a decision, not merely to reduce its line length.

### R4. Keep functions cohesive and control flow shallow

A function should describe one responsibility at one level of abstraction.
Separate orchestration from substantial parsing, policy decisions, or resource
management when those are independently understandable operations.

Prefer guard clauses for invalid inputs or terminal cases when they make the
normal path clearer. Preserve cleanup and existing error semantics.

**Review prompts:** beyond roughly 50 nonblank, noncomment lines in a
function, or three nested control-flow levels, check for separable responsibilities.
Count nested local function definitions when assessing how much a reader must
navigate. These numbers trigger review, not compulsory fragmentation.

Extract a helper when it names a meaningful operation, centralizes a shared
domain rule, or makes a difficult boundary understandable. Do not scatter a
straightforward sequence among trivial forwarding helpers, introduce a generic
framework for one case, or split code merely to satisfy a size metric. Prefer
existing project facilities when they fit.

Extracting a meaningful operation is appropriate even when it is short and
has only one caller. For example, a
`register_material` helper can own manifest reading, duplicate prevention,
and writing while `build` coordinates asset creation. Reuse is not a
prerequisite. Avoid helpers that merely rename an obvious assignment or
forward a call without adding useful domain meaning. The existing `succeeds`
helper is useful because it names the publication-result convention.

### R5. Explain non-obvious reasons and constraints near the code

Add a comment when a future maintainer would otherwise need to rediscover:

- Why operation A must precede B, including locking and asynchronous lifetimes.
- Why an apparent simplification would break behavior or an engine constraint.
- Why a limit, tolerance, bit encoding, fallback, or workaround has that value
  or behavior.
- What invariant is preserved across callbacks, retries, cancellation, or cleanup.
- What an algorithm assumes when its purpose is not evident from its name.

Explain the reason and consequence, not a translation of the next statement.
For example: "Read metadata after taking the map lock so a concurrent route
rename cannot publish stale ownership."

Strongly encourage a brief purpose summary for nontrivial functions. Explain
what the function does and any important effects beyond its return value, so
a reader can understand its scope before reading the body. This is an urged
practice, not merely permission to add a comment. Small, obvious helpers do
not need a compulsory summary.

A function contract may explain inputs, outputs, side effects, and failures;
a local comment should explain a local decision. Issue numbers are supporting
references, not substitutes for the explanation. Update comments with behavior.
Remove stale explanations and commented-out implementations when deliberately
cleaning that area; keep historical code in Git.

Prefer simple language in comments: familiar words, direct sentences, and
concrete explanations of what can happen and why it matters. Avoid unnecessary
jargon and abstract wording. Use technical terms when they help accuracy,
explaining unfamiliar ones where needed. Do not invent a reason for a limit or
workaround; investigate when the reason is unknown.

There is no comment quota and no requirement to narrate obvious code. Improve
names and structure before using comments to compensate for them.

### R6. Make interfaces, state transitions, and failure meanings explicit

- Name parameters in declarations, particularly when adjacent parameters have
  the same type. Make Boolean arguments understandable with keyword arguments,
  named values, or a small meaningful type where the language permits it.
- State the important contract at a boundary: what is returned, which state
  changes, who owns or releases resources, and how failure is represented.
- Distinguish empty results, unavailable results, cancellation, and uncertain
  outcomes when callers need different behavior. Do not silently turn errors
  into successful-looking defaults.
- Keep resource acquisition, ownership transfer, and release visible. Document
  required locks and callback/thread restrictions where a caller can find them.
- Give semantic states names instead of scattering numeric codes.

Use the simplest representation compatible with the existing language, ABI,
and project. This is not a mandate to migrate C++ libraries or replace working
resource-management conventions. If a low-level pattern is required, explain it.

For shared interfaces with multiple easily confused choices, prefer distinct
named option types where the language supports them. For example, `ScopeMatch::Prefix` and `CompletionHandling::Discard`
make the two cancellation choices clear at a call site. Named Boolean variables
remain acceptable for simpler local code. Use appropriate language features,
such as keyword arguments, when they provide equivalent clarity. Do not add a
class or framework around every function.

### R7. Give numbers and positional data meaning

Name domain limits, durations, flags, states, and conversion factors whose
meaning is not evident at the use site. Include units in names and explain
the source of non-obvious values.

Decode database columns, packet fields, and positional tuples at a clear
boundary into named variables or an existing suitable structure. Avoid carrying
unexplained `row[10]` or `state == 2` expressions through domain logic.

For readability-only changes, preserve behavior and the meaning of existing
data. Changes to numeric values or data layouts must be deliberate, with
affected readers, writers, and stored data handled together where necessary.

Do not replace every 0, 1, coordinate component, or ordinary arithmetic constant
with a name. A constant is useful when its name communicates domain meaning;
`VALUE_16777215` does not improve understanding.

### R8. Preserve a coherent local style without copying its weaknesses

Follow established naming, indentation, brace placement, and file organization
where they remain compatible with the approved common rules. Different languages
may retain different naming and formatting conventions; for example, Python
`compile_asset` and C++ `findDemoById` may coexist. Do not impose one naming
convention or one formatter across every language.

Keep formatting consistent within a function. For example, spaces inside
`if ( condition )` are acceptable when they follow that function's convention;
do not add them when its other conditions use `if (condition)`. A convention
found elsewhere in a file or repository is not sufficient reason to introduce
a different style into the function being edited. For new functions, follow
the established surrounding conventions. If existing code is already mixed,
use its predominant established style for the changed block and do not add
another variation. The shared readability rules still take precedence.

Apply these rules to new or deliberately edited logical blocks. Editing an initialization block, function, or other small part of a
file does not automatically authorize reformatting the entire file or
repository. Keep unrelated formatting and naming cleanup out of the change.
Broader cleanup should be planned and agreed separately, including cleanup of
existing inconsistencies outside the affected block. Keep generated and
upstream sections recognizable.

### R9. Make tests readable descriptions of behavior

Tests and diagnostic tools deserve the same clarity as production code.

Give scenarios meaningful names. Separate setup, action, and verification, and
make failure messages identify what failed and provide useful expected and
actual results. Prefer assertions about observable behavior over assertions
about implementation text.

Avoid dependence on private helper names, exact source formatting, fragile
string splitting, or internal statement order unless those are themselves
part of the requirement. These checks must not replace executing the behavior
being tested. Narrow source or compiled-asset checks are appropriate when they
verify a real requirement, such as a required key binding in a compiled menu.
State what each check proves and what it does not prove, and tolerate harmless
formatting differences where feasible.

Exercise real production behavior through an appropriate function, test input,
or generated output. Choose expected results independently; do not copy the
production algorithm into the test as the expected answer. Keep intentional
fixture values, timing assumptions, and cleanup understandable. Use tests
appropriate to the change; this rule does not require every test to launch
the whole game or justify an elaborate new test framework.

### R10. Make the purpose and effects of every change reviewable

This rule concerns the scope and explanation of a change, not statement
formatting or runtime safety. Check the actual diff
against these concrete criteria before handing it over:

1. Every changed logical block must have a current purpose: implement the
   requested outcome, support a necessary dependency, verify or document that
   outcome, or improve readability within the deliberately edited block. Defer
   unrelated cleanup to separately planned work. A change spanning several
   files or repositories can still have one coherent purpose.
2. Identify each change to behavior or data handling, including defaults,
   limits, validation, failure responses, state updates, initialization,
   ownership, and stored data. Describe the relevant trigger and result. A
   title such as "cleanup" or "refactor" is not enough when those things change.
3. Each added option, fallback, compatibility path, or abstraction must serve
   an identifiable current requirement. Do not add one only because a future
   caller might need it. Keep necessary integration and regression checks with
   the feature they support.
4. Keep mechanical cleanup separate from functional changes where practical.
   When they need to stay together, identify the functional changes explicitly
   and explain the connection. Do not split tightly connected fixes merely to
   meet a commit, file, or line-count target.
5. Report the relevant verification actually performed and its result. Make
   unverified behavior and material limits explicit. Inspection of a diff is
   not a runtime test; a test command that was not run must not be reported as
   passing. Use appropriate existing checks rather than requiring a new test
   for every small edit.

The practical review questions are: Can each edited block be tied to the
current task? Are all meaningful changes to behavior/data handling disclosed?
Does each new mechanism have a present use? Are verification claims supported?
An unexplained extra change or unsupported claim means the handoff is not ready.

Keep commit messages concise. A short, descriptive one-line subject is normally
enough; add only brief essential context when needed. Do not turn commit
messages into paragraphs of review notes. Detailed explanations of behavior
changes and validation belong in the PR/review description, task handoff, or
relevant documentation. The criteria above do not require all that detail in
the commit message itself.

### R11. Validate before use and leave predictable results on failure

This rule covers invalid memory access, uninitialized or unintended results,
and partially applied state changes. Numeric limits must also follow rule 7.

For introduced or modified operations, check these concrete requirements:

- Before dereferencing a pointer, indexing a collection, or using parsed input,
  establish that the value is valid for that operation. Check both lower and
  upper bounds where relevant. Use the actual collection or engine limits,
  preferably an existing named limit as required by rule 7. A literal such as
  the entity bound `1024` in an illustration is not an exemption from rule 7.
- When an operation can fail, check its result before using outputs that are
  only valid on success. Every value read or returned must have been assigned
  a valid value for that path. Zero-initialization alone does not prove that
  input parsing succeeded or that zero is a meaningful result.
- Keep resources valid until their last use. After a resource is released,
  prevent callers, stored references, or asynchronous work from using it.
- Validate a complete input before replacing valid shared state where a rejected
  input must leave that state intact. If partial changes are necessary, make
  cleanup, rollback, or partial-success behavior explicit.
- Define what happens when data is missing, invalid, or unavailable. Use the
  established error, exception, or missing-result contract. Do not silently
  turn failure into invented successful data or return an unrelated old value.
- For relevant failure paths, identify an existing check or perform appropriate
  validation, including bounds and missing/invalid data where applicable.
  State what was actually verified and what remains unverified.

Validate at the appropriate boundary or rely on an established, visible caller
or type guarantee. Do not add repeated checks at every layer when that guarantee
already exists. Do not add speculative fallback behavior or catch-all error
handling simply to hide an invalid state.

### R12. Handle delayed, repeated, and concurrent work deliberately

Cancel work that is no longer relevant, rather than spending resources only
to discard its result. Valid data or a valid object can still belong to an
obsolete operation, and repeated requests can apply an effect twice. Rule 11's
access checks alone do not establish that work still belongs to the current
player session, map, menu, recording, or editor operation.

For work that waits, runs asynchronously, or can be repeated:

- Identify the owner and the operation it belongs to. Before applying a delayed
  result, verify that the relevant session, map, request version, or operation
  is still current. Do not rely solely on a reusable player/entity slot.
- Actively cancel work when it is no longer relevant. Prevent queued work from
  starting. For running work, use a safe supported cancellation mechanism;
  long-running code under our control should check for cancellation between
  bounded pieces of work and before starting another expensive step.
- Keep the current-request checks even when cancellation is requested: work
  can finish just before cancellation takes effect. Old results must not be
  applied to a newer session or operation. Requesting cancellation does not
  prove that the work has stopped; retain resources until it has stopped or
  completed the required cleanup.
- If an operation cannot be interrupted safely, explain that constraint, bound
  the remaining work or wait, and discard obsolete results. Do not use this as
  a default excuse to keep cancellable work running. Verify actual stopping
  where supported, not merely that the caller stopped waiting.
- Cancel only work that has actually become unnecessary. Closing a menu may
  cancel its reads while a requested save still needs to finish or roll back
  safely. Do not abort shared work still needed by another owner. Cancellation
  of a caller does not prove that an already-started write stopped or undid its
  effects; settle that write before treating it as safely retryable.
- When operations can overlap on shared data, make their ordering or update
  protection explicit. Validate the relevant current state as part of the
  protected update, rather than assuming an earlier read still holds.
- Before retrying an operation that can change persistent state, establish
  whether repeating it is safe. A lost response does not prove the first write
  failed. Use an appropriate request identity, completion receipt, or a state
  check when needed, rather than blindly repeating uncertain writes.
- Cover relevant cases with focused verification: obsolete queued work never
  starts, cancellable running work stops and releases resources, a late result
  cannot overwrite newer state, an owner/session changes, or a request repeats
  after its response is lost. Choose cases that apply to the change, not every
  case for every function.

Reuse existing request tokens, scopes, locks, and publication receipts where
suitable. Do not build a general scheduling or transaction framework for a
simple operation. Existing examples include menu epochs/versions, the route
refresh request number, and durable demo-publication receipts.

### R13. Bound resource growth and waiting

Code may be safe for each individual request yet still exhaust memory or stall
the server when requests accumulate or an external dependency stops responding.

For queues, caches, recordings, retained results, retries, background jobs,
and repeated work that can grow with players, traffic, or time:

- Identify what can accumulate and its bound. Reuse an appropriate existing
  limit; name new limits and explain their purpose. Count retained results as
  well as queued and running work where all consume the resource.
- Define the response at capacity: reject new work, delay it within a bound,
  replace obsolete work, or discard only data that the feature may safely lose.
  Do not silently discard player progress or authoritative records to meet a cap.
- Bound waits and retries where the operation can otherwise remain pending
  indefinitely. Define the result at the deadline and how owned resources are
  eventually released. A caller timeout alone does not stop background work.
- Keep blocking I/O and growing amounts of work out of frame-sensitive paths,
  or provide a justified work budget. Moving work to a thread does not remove
  the need to bound its queue, memory, and lifetime.
- Verify relevant limit and failure behavior at an appropriate scale: for
  example, reaching capacity, an unavailable database, cancellation, and cleanup.
  Report measurements for performance claims rather than assuming a change
  is faster because it is shorter or more complicated.

This does not require arbitrary caps on every small local collection or
premature optimization. Apply it where growth or waiting can affect the server,
other players, or persistence. The bounded native save history and SQL worker
pool are existing examples to preserve and learn from.

### R14. Protect competitive integrity against deliberate misuse

When changing features that affect records, rankings, rewards, progression or
movement advantages, consider how a player could deliberately misuse their
inputs, timing or interactions. Enforce eligibility and scoring rules on the
server.

- Treat client commands, submitted values and UI restrictions as untrusted.
  Check permissions, ownership and eligibility on the server before applying
  effects. A hidden button or a normal client flow is not an access check.
- Check repeated requests, overlapping actions, reconnects and mode changes
  where they could bypass restrictions or duplicate rewards. Consider how the
  changed feature interacts with saving, restoring and finishing runs.
- Keep practice, tutorial, assisted and competitive results correctly classified
  throughout their lifetime, including persistence and delayed callbacks.
  A mode change must not make an ineligible result eligible.
- On failure or uncertain completion, preserve legitimate progress without
  granting unearned credit. Use the existing ownership and completion checks;
  do not invent a successful outcome or blindly replay an uncertain award.
- Verify plausible abuse cases for the changed feature with focused checks.
  Describe the competitive rule being protected and the attempted bypass,
  rather than relying only on the normal successful path.

Intended CoDJumper movement and accepted techniques remain legitimate gameplay.
This rule targets violations of the project's agreed competitive rules; it does
not authorize redefining those rules or adding a blanket anti-cheat system.
Keep the review proportionate to the feature and its realistic interactions,
rather than expanding every edit into an unlimited search for exploits.

## What "self-explanatory" would mean in review

For each changed logical unit, a reviewer familiar with the project should be
able to answer these questions from the code and its nearby contracts/comments:

| Question | Evidence expected |
| --- | --- |
| What does this accomplish? | A specific function/scenario name and a cohesive sequence. |
| What do these values represent? | Domain names, units, named states, or decoding at the boundary. |
| What happens on success and failure? | Visible branches and distinct results where they matter. |
| What changes, and who owns it? | Explicit state mutations, resource lifetime, and side effects. |
| Why this unusual ordering or workaround? | A nearby explanation of the constraint and consequence. |

If a question is unanswered, improve the relevant name, structure, contract, or
comment. Do not add prose merely to tick a box. This rubric is more meaningful
than requiring a comment on every function or a fixed percentage of comments.

## Examples

These fragments illustrate the intended readability. Preserve the surrounding
behavior and verify the relevant contracts when applying a change.

GSC, from the route-loader pattern:

```c
// Before
maps=[];seen=[];
map=toLower(rows[i][0]);name=rows[i][1];key=map+":"+toLower(name);
if(name=="" || isDefined(seen[key]))continue;

// After
routesByMap = [];
seenRoutes = [];

mapName = toLower(rows[i][0]);
routeName = rows[i][1];
routeKey = mapName + ":" + toLower(routeName);

if (routeName == "" || isDefined(seenRoutes[routeKey]))
{
    continue;
}
```

C++, from the worker-start pattern:

```cpp
// Before
j->state=1;j->started=nowMs();stats.queued--;stats.running++;

// After; JOB_RUNNING would be a named equivalent of the existing value.
job->state = JOB_RUNNING;
job->started = nowMs();
stats.queued--;
stats.running++;
```

Python, from the publication-test pattern:

```python
# Before
marker("pub_rename");pending=pool.submit(call,renamed);time.sleep(.05)

# After; timing behavior is preserved for this illustration.
# Wait until the rename holds the lock before submitting publication.
marker("pub_rename")
pending_publication = pool.submit(call, renamed)
time.sleep(0.05)
```

## Applying and maintaining the policy

Use minimal instruction pointers for each OpenCJ repository and future
repositories. Preserve existing operational instructions and keep the policy
text here rather than duplicating it.

The review thresholds above prompt judgment; they are not automatic quality
scores or a reason to fragment straightforward code. Agree on permanent
formatter/linter adoption separately after checking support for the actual
languages, embedded code and macro syntax.

For the approved 2026 cleanup, use focused new commits rather than rewriting
published feature history. The 2026 line history identifies the main scope;
nearby human-written code may be cleaned when that makes the same function or
feature coherent. Preserve unrelated upstream and generated code.

Separate mechanical layout changes, meaningful naming/structure changes and
behavior fixes where practical. Record only verified mechanical commits in
`.git-blame-ignore-revs`; do not hide functional fixes or substantive refactors
from blame. Keep commit subjects concise and detailed verification in review
records.
