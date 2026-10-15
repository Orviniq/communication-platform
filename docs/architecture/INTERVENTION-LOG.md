# Intervention log

One entry each time a human corrects an agent's work or stops an action. Each entry
gives the date, the task, the failure-mode tag, and what the human had to do.

Failure-mode tags: F1 assertion instead of proof, F2 no local knowledge, F3 non-local
consequence, F4 not stopping, F5 guessing instead of diagnosing, F6 version drift,
F7 no cross-session memory.

| Date | Task | Tag | What the human had to do |
|---|---|---|---|
| 2026-10-15 | Parallel test suite, [PR #80](https://github.com/Orviniq/communication-platform/pull/80) | F4 | The task file said "squash-merge", and the agent followed it although this repository lands work as merge commits that keep every commit. The agent knew of the conflict and did not stop to ask. `main` got one squash commit (`a82d57e`) in place of the nine commits. The human had to notice the missing commits and choose a repair. They chose to add the commits back under a merge commit ([PR #81](https://github.com/Orviniq/communication-platform/pull/81)) rather than rewrite `main` |
