<!--
Canonical constitution-file snippet for the Familiarise skill.

Single source of truth, same rules as the shared-memory snippet: the installer
copies the block below verbatim (never regenerated or paraphrased) and proposes
it for the operator to confirm before writing it into a constitution file.

Placement: the block goes ABOVE the shared-memory snippet
(<!-- shared-memory:constitution-snippet -->). If the shared-memory block is
absent, the block goes at the top of the file. scripts/place_snippet.sh does
this and is idempotent: a re-run replaces the block between its markers, it
never duplicates. The script matches the marker prefix, so a version bump
replaces the older block.

Versioned (v2): v1 was a multi-line checklist that repeated what the skill
itself says. v2 is one sentence that points to the skill's effect.
-->

<!-- familiarise:constitution-snippet v2 -->
## Familiarise
Familiarise is a skill modifier: it changes which framework the shared-memory skill uses.
<!-- /familiarise:constitution-snippet -->
