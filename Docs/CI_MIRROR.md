# NextStep public CI mirror

The authoritative repository is the private `TrueAlpha0902/Notes` repository. `TrueAlpha0902/NextStep-CI` is a public, build-only mirror so GitHub-hosted macOS CI can validate iPhone and iPad builds without relying on paid private-repository runner minutes.

## Security and history boundary

The mirror is not a normal Git remote and must not receive the private branch or its history. `scripts/Publish-CIMirror.ps1` creates a new parentless commit that references the exact reviewed `HEAD` tree, then force-updates only the mirror `main` branch. Publication fails unless:

- the private source worktree is clean;
- `HEAD` is attached to a branch and is exactly present at that branch's `origin` upstream;
- `origin` is the configured private repository;
- GitHub CLI is authenticated as `TrueAlpha0902`;
- the destination is the configured standalone public repository and already exists;
- no blocked credential, provisioning file, local database, source document, or archive is tracked;
- no symlink, Git submodule, or unexpected remote Git reference is present;
- the generated commit has no parent;
- the generated and remote Git tree IDs exactly match the private source tree.

The first publication requires an empty repository whose default branch is `main`, created without a README, `.gitignore`, or license. Later publications may replace only a recognized parentless NextStep snapshot. The update uses an exact force-with-lease, so a concurrent remote change fails instead of being overwritten. The script bypasses local pre-push hooks and explicitly disables tag and submodule publication.

GitHub's server-managed `refs/pull/*` references are ignored because outside contributors can cause them to exist and they do not change the mirror branch. Any additional branch, tag, notes reference, or other user-controlled reference still blocks publication.

Because the public repository has no license, viewing and CI use do not grant a general open-source license. Never add user notes, Apple credentials, GitHub tokens, signing certificates, provisioning profiles, model payloads, local databases, or local configuration to the tracked tree. The automated path and token checks are defense in depth, not a guarantee: every file reachable from the reviewed `HEAD` tree becomes public and must be manually reviewed before publication.

If private history or a credential is ever pushed to the public repository, force-pushing a clean snapshot is not sufficient remediation: assume clones, caches, or forks retained it, rotate affected credentials immediately, and delete/recreate the mirror before publishing again.

## Publish a reviewed snapshot

Create `TrueAlpha0902/NextStep-CI` as an empty public repository, push the reviewed source branch to its `origin` upstream, and ensure Git uses the active GitHub CLI account for the later push:

```powershell
gh auth setup-git --hostname github.com
```

Then inspect the proposed mapping without writing to GitHub:

```powershell
.\scripts\Publish-CIMirror.ps1
```

After the private source commit is reviewed and pushed, publish it:

```powershell
.\scripts\Publish-CIMirror.ps1 -Publish
```

The public workflow builds an unsigned IPA only. Apple signing remains local on the user's Windows computer; neither repository stores Apple Account credentials.
