# forge-infra

> This text is LLM generated.

The catch-all home for how the cgwalters-forge organization's repositories
are set up and kept consistent: conventions, checklists and the
organization-wide notes that don't belong to any one project. Code that a
project runs belongs in that project, and shared GitHub Actions in
[actions](https://github.com/cgwalters-forge/actions).

- [Repository checklist](docs/repository-checklist.md): what every new
  repository gets, and what to check on an existing one.

All of it applies only to first-party repositories, those whose `origin`
custom property is `first-party`; forks and mirrors follow their upstream
(see the checklist's "Scope").

Changes here are reviewed by an agent
([review.yml](.github/workflows/review.yml)), as in the organization's other
onboarded repositories; that review is the merge approval.

## Preview Renovate locally

To see what the forge preset detects, install Renovate and run it from a
first-party checkout without a Renovate configuration. Use a shell without
inherited `RENOVATE_*` settings or hosted Renovate credentials.

```sh
LOG_LEVEL=debug RENOVATE_CONFIG_FILE= renovate \
  --platform=local --dry-run=lookup --onboarding=false --clone-submodules=false \
  --global-extends='github>cgwalters-forge/actions//renovate/forge'
```

Look for `packageFiles with updates` in the debug output. Renovate reads
tracked and staged files without fetching submodules. An existing Renovate
configuration can change or disable the preview. GitHub tag and release
lookups can require `GITHUB_COM_TOKEN`; use read access only. The preview does
not onboard the repository or open pull requests. There is no scheduled
updater; keep existing update automation in place.
