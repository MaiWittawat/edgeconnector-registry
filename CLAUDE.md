# CLAUDE.md

This file guides Claude Code (claude.ai/code) when working in this repository.

## What this is

The static release registry of edgeconnector, the lab rewrite (not production): signed `manager` and plugin builds, served by `raw.githubusercontent.com`. This repo is **public** because managers download without logging in. Managers read it through `CC_RELEASE_URL=https://raw.githubusercontent.com/MaiWittawat/edgeconnector-registry/<branch>`.

The code, `cc-release` and the Makefile targets live in the private repo `~/wittawat/lab/edgeconnector` (`github.com/MaiWittawat/edgeconnector`). There is nothing to build here. This repo only holds output. `README.md` and `PLAN.md` are in Thai; the user writes Thai, so answer in Thai.

`PLAN.md` is the test plan: which releases exist and why, what each one should do on the manager, and a results table (section 7). Record test results there and nowhere else.

## Layout (written by `cc-release`)

```text
index.json                                          every release (cc-release rewrites it; unsigned, only a list)
install-manager.sh                                  written by make manager-release (carries RELEASE_URL and TRUSTED_KEYS)
<name>/<version>/<os>_<arch>/manifest.json          signed manifest
<name>/<version>/<os>_<arch>/<name>_<version>_<os>_<arch>.tar.gz
<name>/channels/<channel>.json                      {"version": "..."}  (a label that can move, unlike a release)
```

## Branches

| Branch | Content | `cc-release verify` |
|---|---|---|
| `main` | good releases and fixtures that misbehave at run time (broken plugin, slow start, crash) | must always pass |
| `negative` | releases that are broken on purpose (bad sha, bad signature, hostile tar, ...) | fails, on purpose |
| `negative-bigindex` | `index.json` above the 1 MB limit | not meaningful |

Never merge `negative*` into `main`: one bad release in `main` makes `verify` fail for good.

## Rules (these are hard)

- **Never edit registry files by hand** (manifest, archive, `index.json`, channels). Use `cc-release`. The only exception is the deliberately broken fixtures on `negative*`.
- **A release is immutable.** `cc-release package` refuses to replace one, and a pushed release is in git history for good. A mistake means a new version. Before a push, you may delete the folder and rebuild.
- **Ask before every `git push`.** The repo is public and releases cannot be taken back.
- **Build from a clean commit**, never from a dirty tree: use a worktree of `origin/main` of the code repo (`git worktree add --detach <scratch>/wt-rel origin/main`), so the release can be rebuilt from its commit.
- **Never promote a bad release to a channel.** `install-manager.sh` installs `manager/channels/stable.json`, so `stable` must always point at a good manager. `manager 1.2.x`, `hello 1.2.0` and every `t-*` fixture stay out of `stable` (except where `PLAN.md` says so).
- **Keys** live in `~/cc-keys` (outside every repo). Never read, print, copy or commit a `.key` file; hand the path to `cc-release` or `make`.
  - `lab-2026` signs everything. Public: `lab-2026=gK3QtGj9wHs/Vm07udIW31CySE3MVP5e/3dUj0aIXV8=`
  - `lab-2027` signs only `hello 1.3.0` (key rotation and untrusted-key tests). Public: `lab-2027=dwI8XQefhpJVcwBxgENp//zZaqNuLSBz2hVpdbd6YxI=`
  - `release-2026` belongs to the retired original system. Never use it.
- `raw.githubusercontent.com` caches for about 5 minutes (`index.json`, channels, `install-manager.sh`). Wait before judging a fresh push, or test against a local registry (`python3 -m http.server 8000 --bind 127.0.0.1 -d <registry>`).
- Commit messages follow Conventional Commits with the plugin name as scope, one release per commit: `feat(hello): release 1.1.0, channel beta`, `docs: ...`, `test(negative): ...`.

## How to publish a release

Run from the worktree of the code repo. `REG` is this repo's path; `KEY` is `$HOME/cc-keys/lab-2026.key`.

```bash
# plugin built from examples/hello-plugin (Linux only: the VPS is x86_64)
make plugin-release NAME=hello PLUGIN_PKG=./examples/hello-plugin PLUGIN_VERSION=1.4.0 \
     REGISTRY=$REG KEY=$KEY PLATFORMS="linux/amd64"
# manager + install-manager.sh (amd64 and arm64)
make manager-release MANAGER_VERSION=1.2.0 REGISTRY=$REG KEY=$KEY \
     RELEASE_URL=https://raw.githubusercontent.com/MaiWittawat/edgeconnector-registry/main \
     TRUSTED_KEYS=lab-2026=gK3QtGj9wHs/Vm07udIW31CySE3MVP5e/3dUj0aIXV8=
go run ./cmd/cc-release promote -dir $REG -name hello -version 1.4.0 [-channel beta]
go run ./cmd/cc-release verify  -dir $REG -pubkey lab-2026=<b64>,lab-2027=<b64>   # all "ok", then commit
```

- The Makefile has no hook for extra ldflags. For the build options of hello-plugin (`-X main.broken=true`, `-X main.startDelay=8s`, `-X main.crashAfter=5s`) run `go build -trimpath -ldflags "-s -w -X main.version=<v> <extra>" -o <bin> ./examples/hello-plugin` and then `go run ./cmd/cc-release package -dir $REG -name <name> -version <v> -os linux -arch amd64 -binary <bin> -key $KEY`.
- A shell script works as a plugin binary (`package -binary <script>`): `sleep 3600` never opens the health socket, `exit 1` dies at once, `trap '' TERM` ignores SIGTERM.
- Platforms are Linux only. `manager-release` builds amd64 and arm64 by itself.
- A plugin name becomes a folder and a socket name: lowercase letters, digits and `-`, at most 63 characters. A version may use letters, digits and `. + - _`.

## Where it is tested

An Ubuntu VPS (`x86_64`, systemd, user `root`) runs the mock CRM `examples/center` from the code repo **on the same machine as the manager**, bound to `127.0.0.1` (gRPC `:7443`, admin `:8080`). The UI is reached with `ssh -L 8080:127.0.0.1:8080`. The admin HTTP API has no login, so never open it to the network. The manager is installed with the `curl ... install-manager.sh` command from the UI's Add manager page plus `--ca-cert-file`. Full steps: `PLAN.md` section 4.1 and the code repo README ("ทดสอบกับ registry บน GitHub").
