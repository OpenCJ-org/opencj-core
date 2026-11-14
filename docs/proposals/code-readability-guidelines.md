# Draft: OpenCJ code readability guidelines

**Status: DRAFT v0.9 — INACTIVE — awaiting explicit user approval.**

Prepared on 2026-11-14. This document proposes rules; it does not establish
current instructions. Do not apply or enforce it, use it to authorize cleanup,
or wire it into agent instructions, skills, formatters, or CI until the user
explicitly confirms that it is ready. Saving, committing, reviewing, or revising
this draft is not approval. Existing instructions remain in effect.

The supporting historical review is retained privately. The draft rules and
illustrative examples below remain inactive.

## Intended scope after approval

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

## Proposed rules, in priority order

### R1. Give each executable step its own line

Discussion decision, 2026-11-14: the user chose B everywhere. Every branch
and loop body must be expanded, including a single return, break, continue,
or call. There is no short-body or guard-clause exception in any first-party
language or repository. This records agreement on the wording only; rule 1
and the complete guidelines remain inactive pending explicit activation.

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

**Proposed layout review prompts, not automatic failures:** aim for about
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

Discussion clarification, 2026-11-14: conventional mathematical names,
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
where useful. This clarification does not activate any guideline.

### R3. Keep expression logic understandable

Rule 1 governs layout: statements, bodies, declarations, and line wrapping.
Rule 3 governs the logic inside an expression. An expression can obey every
layout rule while still combining several decisions or transformations that
should be exposed separately. Do not justify a rule 3 rewrite solely by showing
that compressed statements could be placed on separate lines.

Discussion decision, 2026-11-14: both a short, simple conditional expression
and an expanded if/else are acceptable for a choice between two values. Neither
form is mandatory, and an existing readable form need not be converted to the
other. This records a drafting decision only; all guidelines remain inactive.

- Separate calculations, validation, and mutations. Do not hide unrelated side
  effects in conditions, arguments, conditional expressions, or comma expressions.
- Use a conditional expression only for a short, side-effect-free choice
  between two values. Do not nest conditional expressions.
- Give complicated conditions meaningful intermediate names or named predicates.
  Do not replace a readable two-term condition with a helper solely to add a name.
- Prefer an ordinary loop to a comprehension or chained expression that combines
  nested iteration, filtering, branching, and conversion.

**Proposed review prompt, not an automatic failure:** explain or simplify
conditions with more than three Boolean terms. The purpose is to expose the
meaning of a decision, not merely to reduce its line length.

### R4. Keep functions cohesive and control flow shallow

A function should describe one responsibility at one level of abstraction.
Separate orchestration from substantial parsing, policy decisions, or resource
management when those are independently understandable operations.

Prefer guard clauses for invalid inputs or terminal cases when they make the
normal path clearer. Preserve cleanup and existing error semantics.

**Proposed review prompts:** beyond roughly 50 nonblank, noncomment lines in a
function, or three nested control-flow levels, check for separable responsibilities.
Count nested local function definitions when assessing how much a reader must
navigate. These numbers trigger review, not compulsory fragmentation.

Extract a helper when it names a meaningful operation, centralizes a shared
domain rule, or makes a difficult boundary understandable. Do not scatter a
straightforward sequence among trivial forwarding helpers, introduce a generic
framework for one case, or split code merely to satisfy a size metric. Prefer
existing project facilities when they fit.

Discussion decision, 2026-11-14: the user approved extracting a meaningful
operation even when it is short and has only one caller. For example, a
`register_material` helper can own manifest reading, duplicate prevention,
and writing while `build` coordinates asset creation. Reuse is not a
prerequisite. Avoid helpers that merely rename an obvious assignment or
forward a call without adding useful domain meaning. The existing `succeeds`
helper is useful because it names the publication-result convention. This
records agreement on the draft only; all guidelines remain inactive.

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

Discussion decision, 2026-11-14: the user agreed to reason/constraint comments
and urged brief purpose summaries for nontrivial functions, rather than merely
allowing them. The user also explicitly requested simple language in comments.
All guidelines remain inactive.

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

Discussion decision, 2026-11-14: for shared interfaces with multiple easily
confused choices, prefer distinct named option types where the language supports
them. For example, `ScopeMatch::Prefix` and `CompletionHandling::Discard`
make the two cancellation choices clear at a call site. Named Boolean variables
remain acceptable for simpler local code. Use appropriate language features,
such as keyword arguments, when they provide equivalent clarity. Do not add a
class or framework around every function. All guidelines remain inactive.

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

Discussion decision, 2026-11-14: the user approved this rule with the revised
wording above. Preserving existing data meaning applies to readability-only
cleanup; deliberate functional or data-format changes remain possible when
part of the requested work, with the necessary updates and compatibility
handling. All guidelines remain inactive.

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

After activation, apply these rules to new or deliberately edited logical
blocks. Editing an initialization block, function, or other small part of a
file does not automatically authorize reformatting the entire file or
repository. Keep unrelated formatting and naming cleanup out of the change.
Broader cleanup should be planned and agreed separately, including cleanup of
existing inconsistencies outside the affected block. Keep generated and
upstream sections recognizable.

Discussion decision, 2026-11-14: the user approved different conventions between
languages, required consistency within the edited function, and requested the
block/file/repository scope limit to be explicit. All guidelines remain inactive.

### R9. Make tests readable descriptions of behavior

Tests and diagnostic tools deserve the same clarity as production code.

Give scenarios meaningful names. Separate setup, action, and verification, and
make failure messages identify the scenario and expected result. Prefer
assertions about observable behavior over assertions about implementation text.

Avoid exact whitespace matching, fragile string splitting, or searches for
particular function bodies as a substitute for executing behavior. If an engine
or asset boundary makes a source-level check necessary, state its limited purpose
and make it insensitive to harmless formatting where feasible.

Reuse real production behavior through a suitable seam; do not copy its
algorithm into the test as the expected answer. Keep intentional fixture
values, timing assumptions, and cleanup understandable. Do not build an
elaborate test framework just to satisfy the guideline.

### R10. Keep changes understandable in review

Keep formatting-only cleanup separate from behavior changes where practical.
Explain any necessary mixed change. Show the behavioral reason for changes and
the relevant verification, including limitations.

Do not add speculative fallback paths, compatibility layers, configuration,
or abstractions without an actual requirement. Do not remove useful validation
or comments in pursuit of fewer lines. Prefer the smallest coherent change a
human can inspect and explain.

Future cleanup of existing AI-added code remains a separate, user-directed
activity. This proposal does not authorize it.

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

## Illustrative changes, not patches

These fragments illustrate proposed style only. They are not permission to
change current code.

GSC, from the route-loader pattern:

```c
// Before
maps=[];seen=[];
map=toLower(rows[i][0]);name=rows[i][1];key=map+":"+toLower(name);
if(name=="" || isDefined(seen[key]))continue;

// Proposed shape
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

// Proposed shape; JOB_RUNNING would be a named equivalent of the existing value.
job->state = JOB_RUNNING;
job->started = nowMs();
stats.queued--;
stats.running++;
```

Python, from the publication-test pattern:

```python
# Before
marker("pub_rename");pending=pool.submit(call,renamed);time.sleep(.05)

# Proposed shape; timing behavior is preserved for this illustration.
# Wait until the rename holds the lock before submitting publication.
marker("pub_rename")
pending_publication = pool.submit(call, renamed)
time.sleep(0.05)
```

## Decisions reserved for approval

The proposed firm defaults are separate statements, expanded bodies, braces
where supported, meaningful names, and explicit non-obvious contracts.
The 100/120-column, 50-line, three-level, and three-term thresholds are review
prompts offered for discussion, not claims that those numbers prove quality.

After explicit approval, keep the canonical policy in `dev-tools` and arrange
minimal instruction pointers that cover every sibling repository and future
repositories. Preserve existing operational instructions. Do not duplicate the
policy text across repositories. Agree on any formatter/linter adoption
separately after checking support for the actual languages and macro syntax.

Until that approval, do not create those pointers or activate tooling.
