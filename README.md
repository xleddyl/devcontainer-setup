# devcontainer-setup

One dev container that runs Claude Code and Codex isolated from the Mac, with the working folder mounted and the agent settings shared.

## Installation

1. Clone the repository into `~/.devcontainer`.

```sh
git clone git@github.com:xleddyl/devcontainer-setup.git ~/.devcontainer
```

2. Source the functions from your `~/.zshrc`.

```sh
echo 'source ~/.devcontainer/shell-functions.zsh' >> ~/.zshrc
```

3. Open a new terminal and run `dc claude` inside a project. The first image build takes about 3 minutes.

You need Docker Desktop, the `devcontainer` CLI (`npm install -g @devcontainers/cli`), and Claude Code or Codex installed on the Mac.

## Commands

One command, `dc`. Run it with no arguments to see the usage.

```
dc [-t] [-r] [-i] [-a <rule>]... <agent> [args...]
```

| Agent | Tool |
| --- | --- |
| `claude` | Claude Code |
| `codex` | Codex |

| Flag | Effect |
| --- | --- |
| `-t`, `--tmux` | Run the session inside tmux |
| `-r`, `--remote` | Remote control mode |
| `-i`, `--isolated` | Mount only the current project, not the whole `Developer` folder |
| `-a`, `--allow <rule>` | Turn one firewall rule off for this session; repeat it for more rules |

Flags go before the agent name. Everything after the agent name goes to the agent unchanged.

| Example | Effect |
| --- | --- |
| `dc claude` | Claude Code in the dev container |
| `dc codex` | Codex in the dev container |
| `dc -r claude` | `claude rc --spawn=same-dir` |
| `dc -r codex` | `codex remote-control start` |
| `dc -t codex` | Codex inside tmux |
| `dc -t -r claude` | Claude Code remote control inside tmux |
| `dc -i claude` | Claude Code with only the current project visible |
| `dc -a git claude` | Claude Code with git remotes open for this session |

`claude` and `codex` on the Mac keep their normal behaviour. The `dc` function adds nothing and overrides nothing.

### Isolated mode

By default the container mounts the whole `Developer` folder, so sibling projects can reach each other.

With `-i` the container mounts only the project you run the command from: the Git repository root, or the current folder outside a repository. Sibling projects stay invisible.

| Mode | Mounted | Container path |
| --- | --- | --- |
| default | `~/Developer` | the same path as on the Mac |
| `-i` | the project only | the same path as on the Mac |

Both modes share the same `node_modules` volumes, because the volume name comes from the absolute path of the folder on the Mac. You install once and both modes use it.

An isolated session gets its own tmux session name, with an `iso` suffix.

### tmux sessions

The session name comes from the current folder, plus a suffix for the agent and the mode.

| Command | Session name |
| --- | --- |
| `dc -t claude` | `<folder>` |
| `dc -t -r claude` | `<folder>-rc` |
| `dc -t codex` | `<folder>-cdx` |
| `dc -t -r codex` | `<folder>-cdxr` |

When a session with that name already exists, the command attaches to it instead of starting a second one. Inside tmux it switches the client; outside tmux it attaches.

## How it works

1. The runner walks up from the current folder and looks for a folder named `Developer`.
2. If it finds none, it prints `Not in Developer` and stops.
3. It reads the firewall rules and prints their state.
4. It compares the hash of the resolved configuration with `.build-hash`. If they differ, it rebuilds the `devcontainer:latest` image.
5. It creates a new container from that image and mounts all of `Developer` at the same path it has on the Mac.
6. Inside, `entrypoint.sh` runs as root: it writes the firewall rules, then drops to the `vscode` user for good.
7. It opens the agent in the folder you ran the command from.
8. On exit it deletes the container.

Start time: about 1 second.

All sibling folders are visible, so projects can reach each other.

## What goes into the container

| Item | Path in the container |
| --- | --- |
| The whole `Developer` folder | the same path as on the Mac |
| Host `~/.claude`, read-write | `/home/vscode/.claude` |
| Host `~/.codex`, read-write | `/home/vscode/.codex` |
| Copy of host `~/.claude.json` | `/home/vscode/.claude/.claude.json` |
| `~/.gitconfig`, read-only | `/home/vscode/.gitconfig` |
| npm cache | volume `devcontainer-npm` |
| General cache | volume `devcontainer-cache` |
| pnpm store | volume `devcontainer-pnpm-store` |
| `node_modules` of the current project | volumes `devcontainer-nm-<hash>` |

The rest of the Mac stays outside.

### Paths match the Mac

The container mounts every folder at the same absolute path it has on the Mac. A project at `/Users/you/Developer/app` is at `/Users/you/Developer/app` inside the container too.

This keeps one session history per project. Claude Code indexes its history by absolute path, so a different path inside the container would split the same project into two separate histories.

### The Docker socket stays outside

The container cannot reach the Docker daemon of the Mac.

A mounted Docker socket is the full daemon API. Any process that reaches it can start a second container with any bind mount, including the root of the Mac, as root. That would cancel every other measure on this page.

No filter fixes this: the bind mount is a field inside the request body, not a separate endpoint, so a socket proxy cannot deny it reliably.

The cost is real: `docker compose` and tools that drive Docker do not work inside the container. Run those on the Mac.

The copy of `~/.claude.json` happens once, until the file in the container contains `oauthAccount`.

## Codex

Codex keeps its settings and credentials in `~/.codex`, in plain files. Unlike Claude Code on macOS, it does not use the Keychain. The folder is mounted, so the container is already signed in without `codex login`.

## Versions follow the Mac

The container always uses the versions installed on the Mac. You align nothing by hand.

On every start the runner:

1. Reads `claude --version` and `codex --version` on the Mac.
2. Replaces the `__CLAUDE_VERSION__` and `__CODEX_VERSION__` placeholders in `devcontainer.json` and writes `.resolved.json`.
3. Compares the hash of that file with `.build-hash`.
4. Rebuilds the image with the new versions if they differ.

When you update an agent on the Mac, the next `dc` run rebuilds the image on its own. The rebuild takes about 3 minutes.

Both agents install through npm inside the image, with the `bash-command` feature.

## Lifecycle

### When the session ends

The container is deleted, because `docker run` uses `--rm`.

| Item | Survives |
| --- | --- |
| Project files | yes, they live on the Mac |
| `~/.claude` and the login | yes, it is a mount |
| `node_modules` in the volumes | yes |
| npm cache, general cache, pnpm store | yes |
| The `devcontainer:latest` image | yes |
| Packages installed with `apt` in the container | no |
| Files written outside the mounted folders | no |
| Processes started inside, such as a dev server | no |

### From another folder

A new container starts and mounts all of `Developer` again. Only the opening folder changes.

Two sessions can run together. The container name holds the PID of the runner, so the names never collide.

Ports go to the first session that takes them. The second session gets only the free ones.

## pnpm and node_modules

The image includes pnpm.

The Mac and the container keep two separate `node_modules`. Packages with native binaries, such as `esbuild`, `rollup` and `sharp`, install different files for macOS and for Linux. A single folder would break on one side or the other.

The runner finds the Git repository root you ran the command from, looks for every `package.json` down to 3 levels, and mounts a Docker volume over each `node_modules`. This covers monorepos too.

The volume name is `devcontainer-nm-<hash>`, stable for each folder.

`pnpm install` does **not** run on its own. If `node_modules` is empty, the runner asks a question before it opens the agent:

```
  ⬢  node_modules is empty

  Project  Developer/xleddyl/altea-villa-cipriani
  The container keeps a node_modules separate from the Mac one.

  Run pnpm install now? [Y/n]
```

The default answer is yes. Press Enter to accept. Answer `n` to skip.

Outside an interactive terminal the question does not appear: the runner prints a warning instead.

### The pnpm store

pnpm always puts the store on the same drive as the project, so that it can use hard links. The projects live on the macOS bind mount, so pnpm wants the store at `Developer/.pnpm-store`. No variable changes this: pnpm ignores `store-dir` when the path is on another drive.

The runner mounts the `devcontainer-pnpm-store` volume at exactly that point. The store therefore lives inside Docker and takes no space on the Mac.

| Location | Size |
| --- | --- |
| `~/Developer/.pnpm-store` on the Mac | 0 bytes, empty folder |
| Volume `devcontainer-pnpm-store` | 586 MB |

The empty `~/Developer/.pnpm-store` folder stays on the Mac. It is the mount point of the volume, and it holds nothing.

All projects share the store. A package already downloaded is never downloaded again.

To delete every `node_modules` volume:

```sh
docker volume ls -q --filter name=devcontainer-nm- | xargs docker volume rm
```

## What the container cannot change

`~/.claude` and `~/.codex` are mounted read-write, because the agents write their history, credentials and caches there. A few paths inside them are mounted read-only on top, because the **Mac** executes them:

| Read-only path | Why |
| --- | --- |
| `~/.claude/settings.json`, `settings.local.json` | They define hooks, which run on the Mac |
| `~/.claude/statusline-command.sh`, `fetch-usage.sh` | Claude Code runs them on the Mac |
| `~/.claude/plugins`, `skills`, `output-styles` | They can carry commands and hooks |
| `~/.codex/config.toml` | It defines MCP servers, which start processes |
| `~/.codex/plugins`, `skills` | Same reason |

Without this, an agent in the container could write a hook that the next session on the Mac would run.

Everything else in those folders stays writable, so history, login and caches keep working.

## Firewall

The container runs an outbound firewall. Rules block destinations by name, by address or by port. Every rule is **on** by default, and you turn a rule off for one session with `-a`.

```
dc claude              every rule on
dc -a prod claude      the prod rule off for this session
dc -a git -a prod ...  two rules off
dc -a all claude       every rule off
```

At start the runner prints the state of each rule:

```
  ⬢  firewall

    git      blocked   port 22, github.com, gitlab.com, bitbucket.org, ...
    prod     allowed   this session
```

### Where the rules live

| File | Scope |
| --- | --- |
| `~/.devcontainer/firewall.rules` | every session |
| `<project>/.dc-firewall` | sessions that can see that project |

In the default mode the container sees the whole `Developer` folder, so the runner loads the `.dc-firewall` of **every** project in it. Without this, you could start the agent from another folder and reach the production of a project next door. In isolated mode it loads only the file of the current project.

The container mounts every `.dc-firewall` read-only, so the agent cannot relax a rule for the next session.

### Rule format

One rule per line: `<name> <kind> <value>`. Lines that share a name form one rule, which `-a <name>` turns off as a unit.

| Kind | Blocks | Use it for |
| --- | --- | --- |
| `host` | any TCP connection that carries this name in clear text: the TLS server name, or the HTTP `Host` header | hosts behind a CDN, such as Supabase and Cloudflare |
| `addr` | the IP addresses of a name, resolved at start, or a literal IP or CIDR | dedicated addresses |
| `port` | every outbound TCP connection to this port | whole protocols, such as SSH on port 22 |

A `host` value also matches every name that contains it, so `github.com` covers `api.github.com`. A bare Supabase project ref covers the API, the direct database and a pooler connection without TLS.

Example, `spotfish/.dc-firewall`:

```
prod host mxurdwiorcfbovxezquy
prod host api.spotfish.app
prod host mcp.supabase.com
prod host api.supabase.com
prod addr db.mxurdwiorcfbovxezquy.supabase.co
```

The runner refuses to start when a line is invalid. A typo never turns a block off silently.

### Why names and not addresses

Supabase and most modern APIs sit behind Cloudflare. Their IP addresses are anycast, shared by millions of sites, including the npm registry. Blocking the address of a production API would block unrelated sites at random. A `host` rule reads the name inside the connection instead, so it blocks exactly that service.

### Why the agent cannot remove the firewall

The container starts as root, writes the rules, then drops to the `vscode` user with `setpriv`:

| Measure | Effect |
| --- | --- |
| `--no-new-privs` | `sudo` stops working, and no setuid program can raise privileges |
| `--bounding-set=-net_admin,-net_raw` | even a root process could no longer change the rules |

A rule is enforced by the kernel. An agent that writes its own script, in any language, meets the same rule. The rules stay fixed until the session ends.

The cost: the agent has no `sudo`. It cannot install system packages. Add them to `devcontainer.json` instead.

### Extra measures when a host rule is on

| Measure | Reason |
| --- | --- |
| Outbound UDP port 443 blocked | HTTP/3 over QUIC hides the server name from the rule; clients fall back to TCP |
| `cloudflare-ech.com` blocked | Encrypted Client Hello on Cloudflare hides the real server name behind this one |

### Git

The `git` rule blocks SSH on port 22, the three big Git hosts by name, and their SSH-over-443 endpoints by address.

When the rule is on, `git fetch`, `pull`, `push` and `clone` fail. Local commits keep working. The agent also cannot reach the GitHub API, which can write to a repository as well.

With `-a git`, public repositories are readable. Pushing still needs credentials, and the container holds none: the SSH agent and `~/.config/gh` stay on the Mac.

A side effect: while the rule is on, `pnpm install` fails for dependencies that come from a GitHub URL.

### Known limits

| Case | State |
| --- | --- |
| A client that sends Encrypted Client Hello to a host outside Cloudflare | not covered |
| The shared Supabase pooler over TLS, which carries the project ref only inside the encrypted stream | not covered; it also needs the database password, which the container does not hold |
| Names that do not resolve inside the container | skipped; the container cannot reach them by name either |
| IPv6 | the container has no IPv6 route today; rules are also written to `ip6tables` |

### Testing a rule

`run.sh` accepts a hidden agent, `shell`, which opens `bash` inside a normal session with the same firewall:

```sh
~/.devcontainer/run.sh shell -c 'curl -s -o /dev/null -w "%{http_code}\n" https://api.example.com/'
```

`000` means the firewall closed the connection. Any other code means the request reached the server.

## Mouse, scroll and copy

The mouse goes to the agent. The wheel scrolls the chat.

In Apple Terminal, with the mouse active, hold **Fn** while you drag to select text. Then copy with **Cmd + C**. The **Shift** key has no such effect in Apple Terminal.

## Ports

The runner publishes ports 3000, 4173, 5173, 8000 and 8080 on `127.0.0.1`, when they are free on the host.

To change the list, edit the `ports` variable in `run.sh`.

## Adding tools

1. Edit `devcontainer.json` in this folder.
2. Run `dc claude` or `dc codex`. The runner sees the change and rebuilds the image.

Tools installed by hand inside a container are lost on exit. Always add them to the file.
