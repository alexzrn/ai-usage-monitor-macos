# Platform and collector strategy

**Decision date:** 2026-11-10  
**Release scope:** macOS v0.1  
**Repository:** `ai-usage-monitor-macos`

## Decision

Keep the current release macOS-only and name the repository accordingly. The shipped desktop shell uses AppKit and SwiftUI, and its current collectors read macOS-local Codex, Hermes, and OpenCode stores. This keeps the first release honest and testable on its target OS.

Keep the data model independent of the view:

```text
Installed app / agent
  ├── provider A
  │    ├── provider-reported usage snapshot
  │    └── recent sessions from local source
  └── provider B
       ├── provider-reported usage snapshot
       └── recent sessions from local source
```

An app collector discovers sessions and their provider/model metadata. A provider collector reads usage from an official API or a supported local provider interface. The monitor does not infer quotas from token totals and keeps provider-reported figures distinct from local session aggregates.

## Cross-platform path

Windows and Linux are a separate milestone, not part of v0.1. Do not port the current AppKit window directly. First define a versioned, OS-neutral collector contract and fixtures for each adapter. Then build a shared desktop shell with platform-specific adapters for process discovery, state paths, secure credential resolution, and session launching.

Linux desktop surfaces are DE-specific. Start with one supported target selected from measured demand; KDE Plasma can use a Plasma widget, GNOME can use a Shell extension, and Conky remains an optional lightweight surface. Wayland/X11 differences and DE packaging need their own validation. Windows can use a compact always-on-top Tauri/WebView utility window, with a native Windows shell only if desktop-widget placement requires it.

## Current coverage

| Agent/provider | macOS | Windows | Linux |
| --- | --- | --- | --- |
| Codex | Local CLI and `~/.codex` SQLite/rollout reader | Not implemented | Not implemented |
| Hermes | CLI and `~/.hermes/state.db` reader | Not implemented | Not implemented |
| OpenCode | CLI and local API reader | Not implemented | Not implemented |
| OpenClaw | CLI JSON sessions, provider usage JSON, TUI session target | Not implemented | Not implemented |
| DeepSeek | Hermes-resolved credentials; official balance API | Not implemented | Not implemented |

OpenClaw collector contract is based on its official [`sessions --json`](https://docs.openclaw.ai/cli/sessions), [`status --usage --json`](https://docs.openclaw.ai/cli/status), and [`tui <session-target>`](https://docs.openclaw.ai/cli/tui) interfaces. Its parser is implemented but cannot be live-verified on the current Mac because the CLI is not installed.
