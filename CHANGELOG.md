# Changelog

All notable changes to SaySo are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Telegram downloads are cleaned up daily: files unused for 14 days go, and the oldest ones when the cache passes 300 MB
- The timings log keeps its most recent half once it passes 256 KB

## [0.2.0] — 2026-11-20

First public version, signed and notarized.

### Added

- Local dictation with a configurable shortcut, a manual button and a continuous conversation with the agent
- AI agent with any provider: Claude, OpenAI, OpenRouter, Grok, Ollama or LM Studio
- Telegram bot, guest replies with photos, and voice notes answered by voice
- Telegram user account through TDLib: read, search, reply, forward, edit, react, mark as read, download media and transcribe voice notes
- Isolated Linux machine for commands, web browsing, add-ons and audio transcription
- Plugins over MCP
- Scheduled tasks with several recipients, profile photos, editing and an option to send without asking
- Calendar for any day, reminders and notes on the Mac
- Editable memory with notes typed as instructions or facts
- "Context in use" indicator, "New conversation" and an idle cutoff
- Guardrails: review of outward actions after reading third-party content, and an optional prompt-injection detector (fast model or a local Hugging Face classifier)
- Spanish, English, Galician, French and Portuguese

### Removed

- "Type at the cursor", so SaySo no longer needs the Accessibility permission

[Unreleased]: https://github.com/Pepebits/sayso/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Pepebits/sayso/releases/tag/v0.2.0
