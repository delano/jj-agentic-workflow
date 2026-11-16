# jj-agentic-workflow, trimmed to its findings

A fork of [CodeAlive-AI/jj-agentic-workflow](https://github.com/CodeAlive-AI/jj-agentic-workflow),
cut down on 2026-11-15 from upstream commit `4bd64e1` to what it measured about Jujutsu (jj) with
several writers in one repository.

Upstream is an installable workflow: two agent skills of about 2,000 tokens each that load together,
hooks, wrapper commands, and an installer that edits your global jj config and agent-host settings.
The skills trigger on nearly every task in a jj repository and on commits in plain Git
repositories. This fork keeps the findings and drops that machinery.

- [`HAZARDS.md`](HAZARDS.md): each finding with the jj version it was reproduced on, plus a short
  block to paste into a project `AGENTS.md`.
- [`tests/hazards.sh`](tests/hazards.sh): re-checks most findings against your installed jj, in
  throwaway repositories with an isolated config. Run it after a jj upgrade. A `DRIFT` line means
  a finding in `HAZARDS.md` needs updating; the script exits non-zero when there is one.

To add a finding: give it a reproduction (in `tests/hazards.sh`, or a cited one) and the jj version
it was observed on.

The findings are the work of Rodion Mostovoi and CodeAlive-AI, under the MIT license in
[`LICENSE`](LICENSE). The removed files are in upstream's history at `4bd64e1`.
