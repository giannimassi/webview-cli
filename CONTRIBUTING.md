# Contributing

Thanks for considering a contribution. Keep it small and focused.

## Before you open a PR

- **Open an issue first** for anything bigger than a typo or one-line fix. The scope of this project is intentionally narrow (see below) — it's cheaper to align before you write code.
- **Match the existing style.** The Swift source is one file (`src/main.swift`), the renderer is one JS string literal inside it. Don't reach for SPM, a build system, or frameworks without a compelling reason.

## What's in scope

- Bug fixes and portability improvements to the existing components
- New A2UI components from the v0.8 standard catalog (in order of need: `RadioGroup`, `Image`, `List`, `Divider` variants)
- Performance improvements (startup time, binary size, memory)
- Better error messages on stderr
- Documentation clarifications, typo fixes

## What's out of scope

- Linux or Windows ports — this is macOS-native by design. A cross-platform fork is welcome but won't be merged here.
- Dependency additions — the tool must remain a zero-runtime-dependency single binary.
- A `--css` custom theme flag — opinionated defaults are a feature, not a bug. Fork if you disagree.
- AG-UI protocol support — the project explicitly uses stdio, not HTTP/SSE. See `docs/architecture.md`.
- Electron/Tauri/Wails replacement — if you want those, use those.

## Build and test

```bash
make build           # compiles src/main.swift → ./webview-cli
make test            # runs smoke tests
make install         # copies to ~/bin
```

CI runs `make build && make test` on `macos-latest`.

## Reporting bugs

Please include:
- macOS version (`sw_vers -productVersion`)
- Architecture (`uname -m`)
- webview-cli version (`webview-cli --help 2>&1 | head -1`)
- Minimal repro: the exact stdin + command line + what you expected vs what happened

## Security

Don't open public issues for security-relevant bugs. Email the owner directly (see GitHub profile).

webview-cli v0.1 assumes trusted local agents. Don't point it at untrusted remote URLs. CSP and sandboxing are planned for v1.1.

## Releases

Tagged on `main` as `vX.Y.Z`. Homebrew tap auto-updated via workflow.
