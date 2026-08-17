# Delegated-diff review checklist — full detail

Companion to SKILL.md §3.

Beyond ordinary code review, these are the failure modes that recur with delegated implementation:

- **Silent behavior regressions from changed defaults.** If a default became weaker (empty, off, permissive), trace the *production* call paths — not just the changed function — and confirm nothing real depended on the old default. This is the single highest-value check when a change touches configuration or defaults.
- **Tests "fixed" by weakening intent.** A test that used to assert a behavior should still assert it, with the setup made explicit — not deleted, and not softened into a tautology.
- **New code paths with no coverage.** A new branch, step, or state that no test exercises.
- **Gitignored files.** Changes to ignored files are local-only and will never reach another user. If the change matters to the product, it belongs in a committed file (an example/template), with the ignored file being just this machine's instance. Tests that read an ignored file need to skip gracefully when it's absent, or they'll fail on a fresh checkout.
- **Order- or snapshot-dependent tests** when serialization order changed.
- **Anything security-adjacent that got softened** — a hard check turned advisory, a validation loosened, a boundary made bypassable. If the diff touches an enforcement point, confirm the enforcement is still enforcement.
- **New dependencies, network calls, or external services.** A delegated diff that quietly adds a package, reaches a new endpoint, or pulls in a new service is a decision, not an implementation detail — surface it to the user rather than absorbing it. Check the manifest/lockfile even if the summary didn't mention one.
