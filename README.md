# Hello Versioning Demo

Spring Boot application demonstrating **Semantic Versioning** automation using Maven plugins, with a production-grade GitLab CI/CD pipeline that auto-bumps versions, builds Docker images, zero-downtime deploys, and health-check verifies every release.

> Based on the article: [Spring Boot Semantic Versioning](https://medium.com/daemon-engineering/spring-boot-semantic-versioning-8c178d32a38a)

## Architecture

```
Git Push / MR
      │
      ▼
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────────────┐
│    build    │────▶│ version-bump │────▶│ docker-build │────▶│  deploy-dev  (auto)  │
│ mvn package │     │ pom.xml + tag│     │ push to reg. │     │  deploy-prod (manual) │
└─────────────┘     └──────────────┘     └──────────────┘     └──────────────────────┘
```

## Tech Stack

- Java 21
- Spring Boot 4.1.0
- Maven 3.9+
- `versions-maven-plugin 2.18.0` — sets the new bumped version in `pom.xml`
- Docker `eclipse-temurin:21-jre-alpine`
- GitLab CI/CD

## Project Structure

```
hello-versioning-demo/
├── src/main/java/com/semantic/versioning/example/
│   ├── controller/
│   │   └── HelloSemanticVersionController.java   # GET /hello endpoint
│   └── HelloVersioningDemoApplication.java
├── src/main/resources/
│   └── application.properties
├── .gitlab-ci.yml                                # CI/CD pipeline
├── .dockerignore                                 # Excludes .git, target/, IDE files from build context
├── Dockerfile                                    # Container image definition
├── bump-version.sh                               # Version bump script (patch/minor/major)
├── pom.xml                                       # Maven build config
└── README.md
```

---

## Semantic Versioning

Versioning follows the `MAJOR.MINOR.PATCH` standard:

| Segment | When to bump | Example |
|---------|-------------|---------|
| `PATCH` | Bug fixes, minor tweaks | `2.0.0` → `2.0.1` |
| `MINOR` | New backward-compatible features | `2.0.0` → `2.1.0` |
| `MAJOR` | Breaking changes | `2.0.0` → `3.0.0` |

### How It Works

`bump-version.sh` uses `mvn help:evaluate` to reliably read the project version (not `grep`, which would pick up the Spring Boot parent version), does the arithmetic in shell, then calls `versions-maven-plugin` with the computed value.

```sh
#!/bin/sh
set -e

CURRENT=$(mvn help:evaluate -Dexpression=project.version -q -DforceStdout)

MAJOR=$(echo "$CURRENT" | cut -d. -f1)
MINOR=$(echo "$CURRENT" | cut -d. -f2)
PATCH=$(echo "$CURRENT" | cut -d. -f3)

case "$1" in
  major) MAJOR=$((MAJOR+1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR+1)); PATCH=0 ;;
  patch) PATCH=$((PATCH+1)) ;;
  *)
    echo "ERROR: argument must be patch | minor | major (got: '$1')" >&2
    exit 1
    ;;
esac

NEW="$MAJOR.$MINOR.$PATCH"
mvn versions:set -DnewVersion="$NEW" -DgenerateBackupPoms=false -q
echo "$NEW"
```

Key decisions:
- `set -e` — script exits immediately on any error, no silent failures
- `mvn help:evaluate` — reads the actual Maven project version, immune to `pom.xml` structure changes
- Invalid argument causes a clear error and non-zero exit — pipeline fails fast with a useful message
- `-DgenerateBackupPoms=false` — no `pom.xml.versionsBackup` file left behind

### Running Version Bump Locally

```bash
# Patch: 2.0.0 → 2.0.1
sh bump-version.sh patch

# Minor: 2.0.0 → 2.1.0
sh bump-version.sh minor

# Major: 2.0.0 → 3.0.0
sh bump-version.sh major
```

---

## Prerequisites

- Java 21+
- Maven 3.9+
- Docker (for containerized runs)

## Build & Run

### Local Development

```bash
mvn clean package
java -jar target/hello-versioning-demo-*.jar
```

Application starts on port **8080**.

### Docker

```bash
mvn clean package -DskipTests
docker build -t hello-versioning-demo .
docker run -p 8080:8080 hello-versioning-demo
```

---

## API

### GET /hello

```bash
curl http://localhost:8080/hello
```

**Response (200 OK):**
```
Hello Spring Boot!
```

---

## Dockerfile

```dockerfile
FROM eclipse-temurin:21-jre-alpine AS runtime
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY target/hello-versioning-demo-*.jar app.jar
RUN chown -R appuser:appgroup /app
USER appuser
EXPOSE 8080
ENTRYPOINT ["java", "-XX:+UseG1GC", "-XX:MaxRAMPercentage=75.0", "-jar", "app.jar"]
```

| Decision | Reason |
|----------|--------|
| `eclipse-temurin:21-jre-alpine` | Minimal JRE-only image, reduces attack surface |
| Non-root user (`appuser`) | Security best practice — container cannot write to host as root |
| `-XX:+UseG1GC` | Low-latency garbage collector |
| `-XX:MaxRAMPercentage=75.0` | Respects container memory limits, prevents OOM kills |

### .dockerignore

Prevents `.git`, `target/`, IDE files, and markdown from being sent as Docker build context — faster builds and no accidental secret leakage from git history.

---

## GitLab CI/CD Pipeline

### Pipeline Overview

```
Trigger: push to main / release/* / merge_request_event

Stages:
  build         → Compile & package the JAR
  version-bump  → Bump pom.xml, tag collision guard, commit, push git tag
  docker        → Build & push Docker image (pinned docker:26.1.4)
  deploy        → Zero-downtime swap + health check verification
                    ├── deploy-dev  (automatic, main only)
                    └── deploy-prod (manual gate, release/* only)
```

### Stage Details

#### `build`
- Image: `maven:3.9-eclipse-temurin-21-alpine`
- Runs: `mvn clean package -DskipTests`
- Saves `target/*.jar` as pipeline artifact (1 hour TTL)
- Uses `rules:` (modern GitLab syntax) instead of deprecated `only:`
- Triggers on: `main`, `release/*`, `merge_request_event`

#### `version-bump`
- `needs: [build]` — only runs if build succeeds, never tags a broken build
- Runs `sh bump-version.sh $VERSION_BUMP` — reliable version read via `mvn help:evaluate`
- Tag collision guard — checks remote tags before creating; exits with clear error if tag exists
- Uses `$GITLAB_KNOWN_HOSTS` CI variable instead of `ssh-keyscan` (TOFU vulnerability)
- Commits `pom.xml` with `[skip ci]` to prevent pipeline loop
- Pushes `vX.Y.Z` git tag
- Exports `NEW_VERSION` via dotenv artifact
- Triggers on: `main`, `release/*` only

#### `docker-build`
- Image: `docker:26.1.4-alpine` — pinned patch version, no silent upgrades
- Builds image tagged as both `$IMAGE_NAME:X.Y.Z` and `$IMAGE_NAME:latest`
- Pushes both tags to GitLab Container Registry

#### `deploy-dev` / `deploy-prod`
- Both extend `.deploy-template` — zero duplicated logic
- Uses `$DEPLOY_KNOWN_HOSTS` CI variable per environment — no `ssh-keyscan` TOFU
- Zero-downtime swap strategy (see below)
- Health check verification before and after swap — auto-rollback on failure
- Old image cleanup — keeps last 3 images on the server

### Zero-Downtime Deploy Strategy

```
1. Pull new image on server
2. Start new container on staging port 8081  (named: hello-versioning-demo-next)
3. Poll /actuator/health on port 8081 — up to 60s (12 × 5s)
      ├── Healthy → proceed to swap
      └── Unhealthy → stop & remove new container, exit 1 (pipeline fails, old version still running)
4. Stop & remove old container
5. Stop & remove -next container
6. Start new container on production port 8080
7. Poll /actuator/health on port 8080 — up to 30s (6 × 5s)
      ├── Healthy → pipeline green ✅
      └── Unhealthy → pipeline fails ❌ (manual intervention required)
8. Cleanup old images — keep last 3 tags
```

### Branch & Pipeline Strategy

A `workflow:rules` block at the top of `.gitlab-ci.yml` controls which pipeline type GitLab creates. Without it, pushing a branch with an open MR triggers **two pipelines** for the same commit — a branch pipeline and an MR pipeline — causing `build` to run twice.

| Event | Pipeline created | Stages run |
|-------|-----------------|------------|
| MR opened / new commit pushed to MR branch | MR pipeline | `build` only |
| Push to `main` | Branch pipeline | `build` → `version-bump` → `docker` → `deploy-dev` |
| Push to `release/*` | Branch pipeline | `build` → `version-bump` → `docker` → `deploy-prod` (manual) |
| Push to any other branch | None | — |

---

## CI/CD Variables Setup

Go to **GitLab → Project → Settings → CI/CD → Variables** and add:

### Required Variables

| Variable | Type | Description |
|----------|------|-------------|
| `GIT_PUSH_TOKEN` | Masked | GitLab project access token with `write_repository` scope |
| `GITLAB_KNOWN_HOSTS` | Masked | GitLab server SSH fingerprint (used by `version-bump`) |
| `DEV_SSH_PRIVATE_KEY` | Masked | SSH private key for dev server |
| `DEV_HOST` | Plain | Dev server IP or hostname |
| `DEV_USER` | Plain | SSH username on dev server |
| `DEV_KNOWN_HOSTS` | Masked | Dev server SSH fingerprint |
| `PROD_SSH_PRIVATE_KEY` | Masked | SSH private key for prod server |
| `PROD_HOST` | Plain | Prod server IP or hostname |
| `PROD_USER` | Plain | SSH username on prod server |
| `PROD_KNOWN_HOSTS` | Masked | Prod server SSH fingerprint |

### Auto-Provided by GitLab (no setup needed)

| Variable | Description |
|----------|-------------|
| `CI_REGISTRY` | GitLab Container Registry URL |
| `CI_REGISTRY_USER` | Registry login user |
| `CI_REGISTRY_PASSWORD` | Registry login password |
| `CI_REGISTRY_IMAGE` | Full image path for this project |
| `CI_SERVER_HOST` | GitLab server hostname |
| `CI_PROJECT_PATH` | `namespace/project-name` |
| `CI_COMMIT_REF_NAME` | Current branch name |

### Optional Override Variable

| Variable | Default | Description |
|----------|---------|-------------|
| `VERSION_BUMP` | `patch` | Controls which segment to bump: `patch`, `minor`, or `major` |

---

## How to Get SSH Known Host Fingerprints

### GitLab server fingerprint (`GITLAB_KNOWN_HOSTS`)
```bash
ssh-keyscan gitlab.com
# Copy the output and store as GITLAB_KNOWN_HOSTS CI variable
```

### Dev / Prod server fingerprint (`DEV_KNOWN_HOSTS` / `PROD_KNOWN_HOSTS`)
```bash
ssh-keyscan <your-server-ip>
# Copy the output and store as DEV_KNOWN_HOSTS / PROD_KNOWN_HOSTS CI variable
```

> Storing fingerprints as CI variables means the pipeline verifies the server identity on every run. `ssh-keyscan` at pipeline runtime blindly trusts whatever host responds — a man-in-the-middle could intercept it.

---

## How to Create the GitLab Project Access Token

1. Go to **GitLab → Project → Settings → Access Tokens**
2. Click **Add new token**
3. Name: `CI Version Bump`
4. Role: `Developer`
5. Scopes: ✅ `write_repository`
6. Copy the token value
7. Add it as `GIT_PUSH_TOKEN` in CI/CD Variables (masked)

---

## Controlling the Version Bump

### Option 1 — Pipeline-level default (`.gitlab-ci.yml`)
```yaml
variables:
  VERSION_BUMP: "patch"
```

### Option 2 — Per-run override (GitLab UI)
1. Go to **CI/CD → Pipelines → Run pipeline**
2. Add variable: `VERSION_BUMP` = `minor` (or `major`)
3. Click **Run pipeline**

### Option 3 — Per-run override (GitLab API)
```bash
curl -X POST \
  --form "ref=main" \
  --form "variables[VERSION_BUMP]=minor" \
  --header "PRIVATE-TOKEN: <your_token>" \
  "https://gitlab.com/api/v4/projects/<project_id>/pipeline"
```

---

## Version Bump Examples

Starting version: `2.0.0`

| `VERSION_BUMP` | New Version |
|----------------|-------------|
| `patch` (default) | `2.0.1` |
| `minor` | `2.1.0` |
| `major` | `3.0.0` |

---

## Maven Caching

The pipeline caches `.m2/repository` between jobs:

```yaml
cache:
  paths:
    - .m2/repository
```

Controlled by `MAVEN_OPTS`:
```yaml
MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository"
```

---

## Production Checklist

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | `build` must pass before `version-bump` | ✅ | `needs: [build]` in version-bump |
| 2 | Tag collision guard | ✅ | Checks remote tags before creating |
| 3 | Reliable version reading | ✅ | `mvn help:evaluate`, not `grep` |
| 4 | Invalid bump argument fails fast | ✅ | `set -e` + explicit error message |
| 5 | No backup pom files | ✅ | `-DgenerateBackupPoms=false` |
| 6 | No `ssh-keyscan` TOFU | ✅ | Known hosts stored as CI variables |
| 7 | Pinned Docker image version | ✅ | `docker:26.1.4-alpine` |
| 8 | `.dockerignore` present | ✅ | Excludes `.git`, `target/`, IDE files |
| 9 | Zero-downtime deploy | ✅ | Start new → verify → swap → verify |
| 10 | Health check before swap | ✅ | 12 × 5s polls on staging port |
| 11 | Auto-rollback on failed health check | ✅ | Removes new container, old stays live |
| 12 | Health check after swap | ✅ | 6 × 5s polls on production port |
| 13 | Old image cleanup on server | ✅ | Keeps last 3 tags |
| 14 | Non-root Docker user | ✅ | `appuser` in Dockerfile |
| 15 | JVM tuned for containers | ✅ | G1GC + MaxRAMPercentage=75 |
| 16 | Modern `rules:` syntax | ✅ | Replaces deprecated `only:` |
| 17 | DRY deploy jobs | ✅ | `extends: .deploy-template` |
| 18 | Manual gate for production | ✅ | `when: manual` on deploy-prod |

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| `version-bump` fails with 403 | `GIT_PUSH_TOKEN` missing or expired | Regenerate token, update CI variable |
| `version-bump` fails with 401 | Token lacks `write_repository` scope | Recreate token with correct scope |
| `ERROR: tag vX.Y.Z already exists` | Pipeline re-run or duplicate bump | Delete the tag or bump a higher segment |
| `docker-build` fails: `manifest unknown` | `version-bump` dotenv artifact missing | Check `needs` + `artifacts: reports: dotenv` |
| `Permission denied (publickey)` | SSH key not on server | Add public key to `~/.ssh/authorized_keys` on server |
| `Host key verification failed` | `KNOWN_HOSTS` variable stale or wrong | Re-run `ssh-keyscan` and update the CI variable |
| Health check fails after deploy | App crashed on startup | Check `docker logs hello-versioning-demo-next` on server |
| `deploy-prod` job not visible | Not on a `release/*` branch | Create branch named `release/x.y.z` |
| `[skip ci]` not working | GitLab version < 12.7 | Upgrade GitLab |
| Maven cache stale | Cached failed download | Clear `.m2` cache key in GitLab or run `mvn clean install -U` locally |
