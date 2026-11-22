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

## Base-image mirrors

[Mirror base images](.github/workflows/mirror.yml) runs daily and can be
dispatched on `main`. To enable publishing, set the repository Actions variable
`MIRROR_BASE_IMAGES` to `true`. After the first push, a package admin must set
`fedora-bootc`, `fedora-bootc-ostree` and `os-minimal` to **Public** in their
GHCR package settings. GitHub creates new packages as private; verify that
anonymous pulls work before switching consumers to the mirrors.
Only grant repository write access to trusted publishers: GHCR grants package
write access to the repository, not just to this workflow on `main`.

Use `<tag>.<UTC YYYYMMDD>.<run number>.<attempt>` to pin a snapshot. Runs
never delete these tags, and the moving tag is updated only after its dated
copy and attachment archive succeed. Mirrored signatures still identify the
upstream image; the mirror does not verify them.

For a dated snapshot, attachments are in the same package under
`<dated>.attachment.<sha256 of the original attachment tag, without a newline>`.
For example, with `repo` set to the mirror package reference (no tag) and
`dated` set to the snapshot tag, retrieve Hummingbird's `.att` as follows:

```sh
digest=$(regctl image digest "$repo:$dated")
subject_tag=$(printf '%s' "$digest" | tr : -)
key=$(printf '%s.att' "$subject_tag" | sha256sum)
regctl artifact get "$repo:$dated.attachment.${key%% *}"
```

For a platform attachment, use the platform manifest's digest instead of the
image index digest. Upstream digest tags without a suffix are archived the same
way. The snapshot's OCI referrers are kept apart under
`<dated>.referrers.<sha256 of subject_tag>`: read that tag with
`regctl manifest get`; the index lists the artifact digests, which can be
fetched from the same package. A missing archive tag means the snapshot did not
contain that attachment or referrer index. Standard OCI referrer discovery is package-wide, not snapshot-specific;
legacy digest tags such as `.att` and `.sig` are only published in the archive.

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
