# Codex runtime reference

Detail companion to the codex-implementation-loop skill: runtime resolution, the companion contract, and job monitoring. The workflow itself lives in SKILL.md; this file is the part you consult at dispatch time.

### Choosing model and effort

**These are the user's call, not yours to silently assume.** At each loop kickoff — each time this skill is invoked to start or resume working through units — ask **one compact question** covering thinking level (effort) and speed (service tier), with the user's current config values presented as the inherit option (read them from `~/.codex/config.toml` first so the question shows real values, e.g. "inherit: gpt-5.6-sol / xhigh / priority"). The answer holds for the **entire invocation** — never re-ask per unit. These knobs sit at kickoff rather than in per-repo calibration because the right setting tracks the day's work: a heavy correctness-critical unit wants high effort; a batch of mechanical edits doesn't.

Two boundaries on the kickoff question:
- If the user has recorded a standing preference ("stop asking, always inherit my config"), respect it — the question exists to give control, not friction.
- Effort and model are overridable per-dispatch via flags; **tier is config-only** — if the user picks a different tier at kickoff, they change it themselves (`/fast` in the codex TUI) or explicitly ask you to edit their config. Don't edit their global config on your own initiative.

The dispatch summary printing model/effort/tier on each run is disclosure, not a question.

How resolution works, which shapes the choice:

- **Omit both flags** and the Codex CLI resolves from the user's `~/.codex/config.toml`. This is the default the script uses, because it honors the setup the user already chose for themselves.
- **Pass a flag** to override for this task only. Never edit their global config to force a setting — that changes their own Codex use outside this loop.
- **`ultra` and `max` efforts are real but flag-rejected.** The wrapper accepts only `none|minimal|low|medium|high|xhigh`; the higher two exist only as `model_reasoning_effort` in config.toml. So the way to run at max is to *omit* `--effort` and let config supply it. If the user asks for max, don't pass it — explain this and inherit.
- **Model names are passed through to the CLI as-is** — nothing here maintains a model list, so new Codex models work the day they ship; availability depends on the user's account. Aliases may exist in the companion (as of 1.0.6, `spark` → `gpt-5.3-codex-spark`). **Model names age fast; never recommend one from memory.** When unsure what the user has or what's current, read `~/.codex/config.toml` first, then ask.
- **Service tier is a third speed lever, separate from model and effort.** Codex supports priority routing (**Fast**) and cheaper-but-slower **flex**; support varies by model. Same model, same reasoning — different queue: model trades capability, effort trades thinking depth, tier trades routing speed/cost. The user picks it with the **`/fast` slash command in the codex TUI**, which persists to `service_tier` in `~/.codex/config.toml`; editing the config key directly works too. Canonical values per the official schema are `priority` / `flex` / `default`, with legacy `fast` still accepted — and `fast` is what the TUI currently writes, so expect either spelling when reading a config. The companion has no per-task tier flag, so every dispatch inherits whatever the config says — the dispatch script prints the inherited tier so it's visible. It belongs to the kickoff question like effort does; a mid-loop tier change is a conditions change worth noting, not something to do silently.
- **A "missing" model usually means a stale CLI, not a wrong name.** New models require a recent `codex` CLI. Before concluding a model or flag is unavailable, check `codex --version` (the dispatch script prints it on every run). The safe update path is **`codex update`** — the CLI's own updater works regardless of how it was installed. Don't reinstall through a different channel (e.g. npm on top of a standalone install): two skewed copies of `codex` on one machine is a real failure mode, where a model "doesn't exist" until the copy actually being used gets updated. The CLI is the user's environment — get their OK before updating, and update between units rather than mid-unit so a version change doesn't muddy attribution.

Reasonable way to pick, if the user wants a recommendation: raise effort for work where a subtle mistake is expensive to catch downstream — anything touching correctness boundaries, concurrency, or migrations — and lower it for mechanical, well-specified edits where the spec leaves little room for judgment. Model choice usually follows whatever they're already running; the interesting dial is effort.

To give one project a standing preference without touching the user's global config or this script, set `CODEX_LOOP_MODEL` / `CODEX_LOOP_EFFORT` in that project's environment, and record the choice (see calibration below) so later sessions don't re-litigate it.

### Monitoring, stuck jobs, and cleanup

The same companion script has `status` and `cancel` subcommands (the dispatch script prints the companion path on every run):

```bash
node <companion> status --all      # list known jobs
node <companion> cancel <job-id>   # stop one
```

Judge progress by the event stream, not the clock. Codex being quiet for a couple of minutes is normal; a job that has produced no new events for 15–20 minutes, or is visibly re-running the same failing command, is stuck. Cancel it, read what it was attempting, and fix the cause — usually an ambiguous spec or a missing environment constraint — or split the unit. Don't just re-dispatch the same prompt at the same problem.

After killing a job, **also kill the test processes it spawned** — orphaned runners keep eating the machine long after the parent dies, and they're easy to miss because the job looks gone. Find them by repo path:

```bash
pgrep -fl 'unittest|pytest' | grep <repo-dir>    # then kill those PIDs
```
