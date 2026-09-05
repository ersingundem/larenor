# README publication plan

Draft for the final publication pass. Research checked on **2026-09-05** against
the working tree and GitHub. The plan itself changes no release, host or image. About metadata was applied
on 2026-09-05 at 14:01 TRT and verified by reading the repository back. **Capture and publish final screenshots only after the
frontend is complete.** Larenor Client is an Android app, designed primarily for
tablets; Samsung DeX is a capability of the same app, not a separate application.
the final gallery must contain tablet and resizable desktop-window layouts only.

## Publication facts to preserve

| Item | Observed evidence | Consequence for the final README |
| --- | --- | --- |
| Repository | [ersingundem/larenor](https://github.com/ersingundem/larenor) is public; default branch `main`; About now describes a tablet-first Android app and retains 16 topics; homepage remains empty | DeX is a capability of the same Android app. Do not claim that public visibility proves a release is ready |
| Public releases | `gh release list` returned no releases | No working `/releases/latest/download/...` or `v1.0.0` download can be advertised yet |
| Android artifacts | An unexpired `app-signed-release-apk-63` exists for commit `668ac87b24887cca4c82e3d874460812e6d9a368`, [run 33938262799](https://github.com/ersingundem/larenor/actions/runs/33938262799), created 2026-09-05 02:36 UTC | This is evidence of an older CI artifact, not the completed product or a durable public release; do not make it the final download by default |
| Current published source snapshot | Local HEAD `295750ba27c3e0b48f87be2bb788a55f9fafa24b`; its [Android run](https://github.com/ersingundem/larenor/actions/runs/33959624724) and [Server run](https://github.com/ersingundem/larenor/actions/runs/33959624719) failed | Recheck the final commit and its required jobs after ongoing repairs; do not carry these dated results into a later release claim |
| Public Server image | Native amd64/arm64 checks and publication passed for `88c26fc`; its manifest was fetched anonymously at digest `sha256:3012dd35fdce1523c8abae26abb6b2f3e5a70c7efe592acaaa985c7de7e8fa31` | See the [container evidence](server-container.md); verify the final publication digest again before final install instructions |
| Source versions | [Client manifest](../pubspec.yaml): `1.0.0+1`; [Server manifest](../server/pyproject.toml): `0.1.0` | Source version fields are not proof that matching release tags, APKs or image tags exist |
| Android support | [Gradle configuration](../android/app/build.gradle.kts): `com.ersingundem.larenor`, minimum SDK 26, compile SDK 37 | Say Android app, Android 8.0/API 26 or later, designed primarily for tablets; include DeX under window/display capabilities. Qualify feature-specific Android requirements separately. iOS development is paused |
| Existing Compose deployment | [deploy/larenor-server/compose.yaml](../deploy/larenor-server/compose.yaml) currently defines Music Assistant `2.10.2` with a digest pin | This legacy MA-only package is a migration reference, not the unified Larenor installer. The [integrated stack](integrated-media-stack.md) remains in development |
| Server operation | [Server README](../server/README.md), [container guide](server-container.md), [runtime](../server/larenor_server/runtime.py) | API administration is in Client; no separate Server web admin UI. Private data and key mounts, initial password change, and a separate publisher credential are real requirements |

GitHub Actions artifacts require a signed-in account with repository read access
and expire. The repository explicitly retains signed APK artifacts for 30 days,
and selected debug artifacts for three days. Keep “CI artifact” distinct from
“GitHub Release.” [GitHub artifact download documentation](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)

## Applied About metadata

Description and all 16 topics below applied and read back on 2026-09-05. Recheck the final feature wording before publication:

> An Android app for Home Assistant, media and home infrastructure, designed for tablets, with a self-hosted Larenor Server. Built with Flutter; AGPL-3.0-only.

Use these **16** relevant topics, without filling unused slots for their own sake:

```text
home-assistant smart-home home-automation wall-panel dashboard android
android-tablet samsung-dex flutter dart self-hosted homelab jellyfin
music-assistant proxmox docker
```

GitHub permits at most 20 topics, each at most 50 characters using lowercase
letters, numbers and hyphens. Topics describe purpose, community or technology
and support discovery through topic pages/search. These recommendations do not
imply official affiliation with upstream projects.
[GitHub topic guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/classifying-your-repository-with-topics)

Keep the homepage empty until a maintained public documentation/landing URL
actually exists; the repository itself already provides a canonical project
address. Use a real final-product social preview later, with the existing brand,
one clear tablet view and a short product description. GitHub recommends
1280×640 pixels, with PNG/JPG/GIF below 1 MB. Do not create or upload that image
during this research pass.
[GitHub social preview guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/customizing-your-repositorys-social-media-preview)

## Final README outline

Keep the entry page focused; move the current long capability inventory into
linked, maintained feature documentation. GitHub describes a README as the first
place to explain purpose, usefulness, getting started, help and contribution;
headings provide a native outline and relative links work across branches and
clones. [GitHub README guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)

1. **Larenor** — existing icon, a two-sentence explanation of Client and Server,
   supported form factors, short release-status line, and navigation:
   `Install Server · Install Client · Screenshots · Documentation · Contribute`.
   Put current availability next to installation links. Use only truthful
   license/build/release badges; omit a release badge until that release exists.
2. **What it does** — four or five concise outcomes: Home Assistant dashboard and
   controls, media/music, home infrastructure, tablet/panel experience, and Server
   account/configuration/service administration. Each gets a documentation link.
   Do not turn all 17 configurable service kinds into a claim that every kind has
   a native Client screen, an authenticated adapter or automated installation.
3. **Client and Server** — compact component/requirements table. Explain existing
   upstream services, Client UI, and Server APIs. Explicitly distinguish saving a
   connection, reaching it, authenticating, and operating/installing it. Recheck
   the final onboarding flow before describing whether Server is required for a
   particular feature; current direct Home Assistant setup and Server account
   setup are distinct flows.
4. **Get started** — separately labeled Server and Client paths, with exact
   version/digest/run references and prerequisites. Link the detailed operational
   guides; the README should get a reader to the first successful account login
   and explicit service check without reproducing the entire API reference.
5. **Screenshots** — final tablet-only selection after frontend freeze; see the
   capture rules below. Show the product working before presenting the long list
   of integrations. It is reasonable to move one final hero image directly below
   the opening paragraph after this gate is met.
6. **Documentation and development** — a small navigation table and reproducible
   build/test commands. Link architecture, API coverage, Server setup, update
   signing, backup/recovery, kiosk recovery, and current implementation status.
7. **Status and help** — a short honest list of remaining hardware acceptance,
   platform limitations and planned features, plus repository Issues. Detailed
   ongoing work belongs in [PROGRESS.md](PROGRESS.md), not repeated throughout
   the feature pitch. Do not invent support email, response-time promises,
   Discussions availability or a published security policy.
8. **Contribute and license** — concrete ways to help (tablet acceptance reports,
   translations, fixes, reproducible issues), then [LICENSE](../LICENSE),
   [NOTICE](../NOTICE) and [third-party notices](../THIRD_PARTY_NOTICES.md). Add
   contribution/security guides only once their maintained contents and reporting
   channels exist; no empty compliance badges.

An optional single sentence near contribution information is sufficient:
“If Larenor is useful to you, star the repository to find it again and share
feedback from your setup.” GitHub documents stars as a way to save and discover
projects and show appreciation. Clear value, installable artifacts, screenshots
and honest support information are editorial recommendations, not a guarantee
of stars or placement in recommendations.
[GitHub stars documentation](https://docs.github.com/en/get-started/exploring-projects-on-github/saving-repositories-with-stars)

## Installation text and commands

The following are **draft instructions, not commands executed by this task**.
They are grounded in the current repository, but the final publication must
replace unresolved release identifiers with verified values. Finish frontend,
tests and release validation first. Installation on the user's CasaOS/Proxmox
Linux host, credentials, network/TLS routing and physical tablet are the final
manual setup step; software implementation does not establish that deployment.

### Server: published container path, gated on a verified digest

The intended image is `ghcr.io/ersingundem/larenor-server`, with native
`linux/amd64` and `linux/arm64` support. Its workflow creates
`:sha-<40-character-source-commit>` and may promote the same index to `:stable`.
There is currently no documented semantic-version tag such as `:0.1.0` and no
`:latest` publishing rule. Pin the tested multiarchitecture **digest**, recorded
with its source commit and successful workflow URL. GitHub supports exact
digest pulls; public registry access is distinct from repository visibility.
[GitHub Container registry guidance](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)

Only after the image is publicly pullable and host setup has been chosen, the
detailed Linux guide can use this runtime shape. The digest variable is
deliberately required; no fictitious digest is supplied:

```sh
: "${LARENOR_SERVER_DIGEST:?Set the verified published sha256 digest}"
docker pull "ghcr.io/ersingundem/larenor-server@$LARENOR_SERVER_DIGEST"

sudo install -d -m 0700 -o 10001 -g 10001 \
  /srv/larenor/data /srv/larenor/secrets

docker run --detach --name larenor-server --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --pids-limit 128 --memory 1g --cpus 2 \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,mode=1777,size=64m \
  --mount type=bind,src=/srv/larenor/data,dst=/data \
  --mount type=bind,src=/srv/larenor/secrets,dst=/secrets \
  --publish 127.0.0.1:8098:8098 \
  "ghcr.io/ersingundem/larenor-server@$LARENOR_SERVER_DIGEST"

curl --fail --silent --show-error http://127.0.0.1:8098/api/v1/health
curl --fail --silent --show-error http://127.0.0.1:8098/api/v1/source
```

This is a **new-install template**. Check existing paths/container names before
using it; an upgrade must preserve private data and the matching separate vault
key. The loopback bind is for a reverse proxy on the same host and is not a
tablet-reachable endpoint by itself. Document the actual HTTPS/private-network
route chosen at manual setup rather than advertising a universally working
CasaOS one-click flow. The Server does not require a Docker socket, privileged
mode or host networking. Resource flags mirror CI's smoke configuration, not
measured production sizing. See the [runtime contract](server-container.md).

Read `/srv/larenor/data/bootstrap-admin.txt` privately on the host, sign in as the
generated administrator through Client, and change the initial password. Never
place the credential values in the README, a screenshot or an issue. Preserve
`/secrets/vault.key` separately with the consistent database backup. The
`publisher.token` file is for release publishing, not account login. A healthy
API response proves Server reachability, not upstream service authentication.

### Server: available source-development path

The current source tree has a real Dockerfile and locked Python project. From a
clean reviewed checkout, this binds a local image tag to the actual commit; it
does not establish that it is a published or accepted production release:

```sh
git clone https://github.com/ersingundem/larenor.git
cd larenor
test -z "$(git status --porcelain)"
revision="$(git rev-parse HEAD)"
docker build --file server/Dockerfile \
  --build-arg "LARENOR_SOURCE_REVISION=$revision" \
  --build-arg LARENOR_REPOSITORY_URL=https://github.com/ersingundem/larenor \
  --tag "larenor-server:sha-$revision" .
```

For a versioned installation, check out the chosen reviewed full commit before
the clean-tree test; the clone's moving `main` tip is only a development starting
point. Keep corresponding-source links accurate for forks and modifications.

For Python development, current CI uses Python **3.12.14** and uv **0.12.10**;
the package permits Python 3.12–3.14. From the repository root, on a Unix host
with trusted private parent paths:

```sh
cd server
uv sync --locked --python 3.12.14
install -d -m 0700 "$HOME/.local/share/larenor-dev/data" \
  "$HOME/.local/share/larenor-dev/secrets"
export LARENOR_DATA_DIR="$HOME/.local/share/larenor-dev/data"
export LARENOR_KEY_FILE="$HOME/.local/share/larenor-dev/secrets/vault.key"
uv run --locked --no-sync larenor-server --host 127.0.0.1 --port 8098
```

The application validates ownership, parent trust and permissions rather than
repairing them automatically. Local Python startup does not prepare the APK
verifier: release publishing needs Java, the pinned APKsig JAR and compiled
verifier classes described in [server/README.md](../server/README.md). Prefer the
validated container for that complete runtime. No `pip install larenor-server`
from an unverified package registry should be offered.

### Client: CI artifact path until a durable release is created

Current [Android CI](../.github/workflows/android-build.yml) uses Flutter
**3.47.2**, Java **17**, SDK platform **37**, and Build Tools **37.0.0**. Its
signed APK is `app-release.apk` with `release-metadata.json`; artifact names are
`app-signed-release-apk-<run_number>`. The user-visible source version is currently
`1.0.0`, while CI's Android `versionCode` is `100000000 + GITHUB_RUN_NUMBER`.
Keep the full source commit, run ID/number and artifact metadata together.

For a **selected, successful, reviewed run whose artifact has not expired**:

```sh
: "${LARENOR_RUN_ID:?Set the verified successful Android run ID}"
: "${LARENOR_RUN_NUMBER:?Set its matching run number}"
gh run download "$LARENOR_RUN_ID" --repo ersingundem/larenor \
  --name "app-signed-release-apk-$LARENOR_RUN_NUMBER" \
  --dir "larenor-client-$LARENOR_RUN_NUMBER"
```

Explain the GitHub sign-in requirement next to this option. Before manual
installation, validate the APK hash against the accompanying metadata, verify
its actual signature/package/version against the trusted publication record,
and retain that record. The existing [signing guide](android-release-signing.md)
documents the exact tools and stable identity. Metadata bundled with a download
is not independent proof of its origin.

Open the verified APK on the selected tablet and approve Android's installer.
An optional developer route, after choosing the intended device, is:

```sh
: "${LARENOR_ANDROID_SERIAL:?Set the intended adb device serial}"
: "${LARENOR_RUN_NUMBER:?Set the downloaded run number}"
adb -s "$LARENOR_ANDROID_SERIAL" install -r \
  "larenor-client-$LARENOR_RUN_NUMBER/app-release.apk"
```

Do not recommend uninstalling an existing build to resolve an identity/version
error: compatible updates require the same package/signing identity and accepted
version, while uninstalling can remove local state. First-install permissions,
PIN setup, optional default-launcher selection and managed kiosk enrollment
should be separate instructions; installing an APK does not provision a device
owner. Once a matching release is published to the configured Larenor Server,
the Client's notice/updater path still requires explicit download and install.

If the project later creates a real GitHub Release, replace the CI-artifact
primary route with its verified versioned release/asset link. The convenience
`/releases/latest` link is appropriate only when a latest release exists, and
direct asset links must use the asset's real name. The current workflow does
not create a GitHub Release.
[GitHub release linking guidance](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)

### Client: source-development path

With the CI-matching Flutter/Java/Android SDK installed, from a clean checkout
of a recorded full commit:

```sh
flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs
flutter gen-l10n
flutter analyze
flutter test --coverage
flutter build apk --debug
```

This produces a development APK under
`build/app/outputs/flutter-apk/app-debug.apk`, not a production update for an
installation signed with the project's release identity. Generated Dart and
localization files are not tracked and must be regenerated after checkout.
Release signing needs private configuration; do not put key provisioning in
ordinary end-user installation steps. Use the dedicated signing guide for
maintainers/fork distributors.

## Clear documentation for humans and tools

Use stable Markdown headings, short paragraphs, semantic lists/tables, relative
links and explicit command prerequisites. Define “Larenor Client,” “Larenor
Server” and “service connection” once; keep feature names consistent with the UI.
Show source paths in the documentation navigation so readers and code tools can
locate the implementation without inferring it from screenshots. Useful entries:

| Question | Existing source of truth |
| --- | --- |
| What is implemented or still in progress? | [PROGRESS.md](PROGRESS.md), [architecture](server-client-architecture-2026-09-05.md) |
| How do I run Server and access its API? | [Server README](../server/README.md), [container guide](server-container.md) |
| How do Client releases work? | [Signing/update guide](android-release-signing.md), [publisher](../tool/publish_client_release.py) |
| How are Home Assistant capabilities exposed? | [API coverage](home-assistant-api-coverage.md) |
| What survives reinstalling? | [Configuration vault](configuration-vault.md) |
| How do I recover a managed panel? | [Kiosk setup/recovery](kiosk-managed-implementation-2026-09-05.md) |
| Where is the code? | [Client features](../lib/features/), [Server package](../server/larenor_server/), [tests](../test/), [Server tests](../server/tests/) |

Keep secrets out of examples. Document the real administrator-protected
`GET /api/v1/openapi.json` and public `/api/v1/source`; do not create an invented
static schema or imply that `/docs` is a web admin UI. Consider a small maintained
documentation index if the README navigation becomes crowded, but do not add
duplicate generated summaries without an owner/update rule.

GitHub repository search normally matches names, descriptions and topics;
`in:readme` explicitly includes README contents. Include meaningful product and
integration terms naturally in the introduction and feature descriptions.
[GitHub repository search documentation](https://docs.github.com/en/search-github/searching-on-github/searching-for-repositories)

The recommendation for clear text and navigation also benefits tools that read
the repository; this is an inference about usability, **not** a claim of improved
AI ranking, model training inclusion or guaranteed retrieval. No hidden keyword
blocks, fabricated JSON-LD, fake structured-data badges, `llms.txt` ranking
promises or duplicated “AI SEO” paragraphs are needed. Evaluate an additional
machine-consumer format only for a specific supported consumer and maintenance
need.

## Final tablet gallery gate

After every frontend owner declares their work complete, rerun the final design,
overflow, large-text and lifecycle checks, then capture current real widgets at
the exact final source revision. Retain capture command/test, viewport, theme,
locale, fixture provenance and revision in the evidence file. Do not reuse
earlier screenshots automatically: current preview files are development
evidence until recaptured against the final UI.

Select roughly four to six complementary images: Home dashboard, Media/music,
Server service connections/administration, tablet settings/panel, and one
resizable DeX layout. Use readable tablet proportions, light/dark examples and
one consistent locale per sequence. Include Turkish and English examples only
where localization itself is the point. No phone frames or separate phone
gallery. A fixture screenshot must be captioned as synthetic data; do not call
it a live home or a physical DeX acceptance result. Preserve text readability,
use meaningful alt text, and avoid screenshots as the sole feature explanation.

Do not generate, copy, replace or publish final gallery/social-preview images
before that gate. Existing image files remain untouched by this plan.

## Execution order for the final publication owner

1. Freeze the frontend and reconcile README claims against the final implemented
   service/UI contracts; remove stale “planned” and premature “available” wording.
2. Finish final automated checks and separate their evidence from physical
   Android/DeX and live-service acceptance still requiring manual setup.
3. Verify the exact successful source commit, signed Client artifact, certificate,
   package and version; verify both Server architectures, final index digest and
   anonymous image access. Decide explicitly whether durable GitHub Releases are
   being created or CI artifacts remain the current distribution mechanism.
4. Capture the final tablet gallery and prepare the concise README using this
   outline. Check rendered anchors, relative links, alt text, actual asset names,
   license links and copied installation commands. Use immutable references for
   reproducibility; keep any moving discovery link clearly labeled.
5. Apply the approved final About description/topics and, once prepared, the
   social preview. Re-read GitHub's rendered README and metadata, and verify
   downloads as an ordinary reader. This research pass applies none of them.
6. Perform the agreed final manual Server/Client installation on the chosen host
   and tablet, configure the real private/TLS route and credentials, then record
   actual acceptance separately. Configure optional CI-to-Server publishing only
   when `LARENOR_RELEASE_SERVER_URL` is reachable over HTTPS and the dedicated
   publisher credential is supplied; an unset URL intentionally disables it.

Recheck live availability at publication time. The dated inventory above is a
research snapshot, not a standing claim that current main or releases are ready.
