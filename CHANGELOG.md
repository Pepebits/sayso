# Changelog

All notable changes to SaySo are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Telegram account: send albums, polls and quizzes (groups and channels), locations, contact cards and dice
- Telegram scheduled messages, sent by Telegram at their time even with the Mac off, with a list to review and cancel them
- Pin and unpin messages, mute and archive chats, read profiles, add contacts, block and unblock people
- Groups: create them, add or remove members, join through an invite link and leave
- Message links, voting in polls, notes in Saved Messages and active stories
- Polls, locations, contacts and dice now show their content when the agent reads a chat
- Six new permission rules in the Telegram screen for these actions
- Long conversations: what no longer fits in the request is summarized with the fast model instead of being dropped, and the history has a size budget as well as a turn limit
- Voice and your bot now share one conversation, so what you said on one side counts on the other
- Guest mode: a quoted message goes through the prompt-injection detector, and the reply to a mention is reviewed before it is posted in someone else's chat
- Mac reminders: the agent can list them and mark them done, pending again or delete them (it could only add them)
- A fixed cap on stored activity and conversations, even with retention set to "Forever"

### Fixed

- Message IDs above 10^15 (Telegram's scheduled messages) were dropped when read

### Changed

- The welcome and permission guides show your own dictation shortcut instead of assuming ⌥
- SaySo now requires macOS 15. The bundled TDLib build already needed it on Apple Silicon, so Telegram could fail on macOS 14
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
