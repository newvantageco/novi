# Novi Linux — Branch Strategy

## Branch Layout

```
main                    ← stable, always releasable, protected
develop                 ← integration branch, PRs merge here first
stable/0.1              ← stable track maintenance
stable/0.2              ← (future)
advanced/rolling        ← advanced/rolling track
feature/*               ← short-lived feature branches
fix/*                   ← bugfixes
security/*              ← security patches (may be private until patched)
```

## Rules

| Branch | Protected | Requires PR | Min reviews | CI required |
|---|---|---|---|---|
| `main` | ✅ | ✅ | 1 | ✅ |
| `develop` | ✅ | ✅ | 1 | ✅ |
| `stable/*` | ✅ | ✅ | 2 | ✅ |
| `feature/*` | ❌ | ❌ | — | recommended |
| `fix/*` | ❌ | ❌ | — | recommended |
| `security/*` | ✅ | ✅ | 2 | ✅ |

## Commit Message Format (Conventional Commits)

```
<type>(<scope>): <short description>

[optional body]

[optional footer]
```

**Types:**
- `feat` — new feature
- `fix` — bug fix
- `build` — build system changes
- `kernel` — kernel config changes
- `pkg` — package manager changes
- `ci` — CI/CD changes
- `docs` — documentation
- `security` — security fix (use `security/*` branch)
- `chore` — maintenance

**Examples:**
```
feat(pkg): add dependency cycle detection

build(kernel): add CONFIG_ZRAM for compressed swap

security(signing): rotate package signing key

fix(init): stage2 fails if /run/s6-rc doesn't exist
```

## Release Tags

```
v0.1.0          ← release
v0.1.0-rc.1     ← release candidate
v0.1.0-beta.1   ← beta
```

Tags must be GPG-signed:
```bash
git tag -s v0.1.0 -m "Novi Linux 0.1.0 (Axiom)"
git push origin v0.1.0
```

## PR Flow

```
1. Fork or branch from develop
2. Write code + tests
3. shellcheck passes locally
4. Push branch
5. Open PR → develop (not main)
6. CI runs automatically
7. 1 reviewer approves
8. Squash merge into develop
9. Periodically: develop → main (release)
```

## Security Fix Flow

```
1. Report received at security@novilinux.org
2. Core team opens private security/* branch
3. Fix developed privately
4. CVE assigned if applicable
5. Fix merged to main under embargo
6. Public disclosure + patch release simultaneously
```
