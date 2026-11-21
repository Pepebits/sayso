# Changelog

All notable changes to SaySo are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.4.0] — 2026-11-21

### Added

- Automatic updates with Sparkle: SaySo checks the latest GitHub release once a day and asks before installing a new version, signed by Pepebits. Settings → «Updates» shows the installed version, a «Check now» button and the automatic-checks switch, and the menu bar has «Check for Updates…». If you have 0.3.0 or earlier, install 0.4.0 by hand once; from then on it updates itself
- Tasks → «Ideas to get started»: ready-made tasks (morning summary, unread chats, plan for the week, overdue reminders, Linux machine clean-up). «Use» fills in the new-task form so you can review it before scheduling
- Settings → «Error report»: saves a file with the version, status, the last week's warnings and errors and SaySo's unexpected quits (with the crashing thread), hiding names, numbers, addresses and secrets, so you can review it and attach it to an issue. After an unexpected quit, Logs says how to report it
- Homebrew: `brew install --cask pepebits/sayso/sayso`, with the repository as its own tap. The release script updates the cask's version and checksum
- Dictation dictionary (Dictation → Dictionary): names, brands and acronyms are given as a hint to Whisper and Apple's recognizer and to AI correction, and always come out with your capitalization; fixed replacements turn a dictated word or phrase into another («at sign» → «@»)
- Spending limit (Statistics → Spending limit): a daily and a monthly token cap for paid models (local ones don't count). At 80 % SaySo warns through the bot and on the Mac; when reached, the agent makes no more paid requests until the next day or month, or until you raise it
- Approve from the bot (Telegram → General switches, off by default): when an action asks for permission, your bot also sends «Allow once» and «Deny» buttons; the first answer, on the Mac or in Telegram, counts. Questions expire after 5 minutes, only your account can press the buttons, and «Always allow» stays on the Mac
- Bot commands in Telegram's «/» menu, answered at once without the model: /status (agent, model, Linux machine, today's tokens), /tasks, /pause and /resume (scheduled tasks and message alerts, also shown and resumable in Tasks), /new and /help

### Fixed

- Release script: notarization no longer fails with «No Keychain password item found» when the screen locks while Apple reviews the app

## [0.3.0] — 2026-11-20

### Added

- Telegram account: send albums, polls and quizzes (groups and channels), locations, contact cards and dice
- Telegram scheduled messages, sent by Telegram at their time even with the Mac off, with a list to review and cancel them
- Pin and unpin messages, mute and archive chats, read profiles, add contacts, block and unblock people
- Groups: create them, add or remove members, join through an invite link and leave
- Message links, voting in polls, notes in Saved Messages and active stories
- Stickers from your installed packs, picked by emoji, and chat folders: list them, see their chats, add or remove a chat and create new ones
- Polls, locations, contacts and dice now show their content when the agent reads a chat
- Six new permission rules in the Telegram screen for these actions
- Long conversations: what no longer fits in the request is summarized with the fast model instead of being dropped, and the history has a size budget as well as a turn limit
- Voice and your bot now share one conversation, so what you said on one side counts on the other
- Guest mode: a quoted message goes through the prompt-injection detector, and the reply to a mention is reviewed before it is posted in someone else's chat
- Mac reminders: the agent can list them and mark them done, pending again or delete them (it could only add them)
- Images: with a model that sees them (Claude, OpenAI, Grok, or one you mark in Model), the agent looks at photos you send to your bot, photos in your Telegram chats and images on the Linux machine
- Notes: the agent can search the Notes app and read a note (asks by default)
- Calendar: the agent can create, move and delete events, not only read them; the event list now carries the IDs it needs
- Backup in Settings: export memory, tasks, alerts, rules, accounts, plugins and settings to a JSON file and import it on another Mac. Keys, secrets, the Telegram session and conversations are never included; secrets come back as pending
- Settings → «Alerts on the Mac»: notification with sound, silent, or none (alerts still reach the bot and Logs)
- Alerts and finished jobs are also read aloud with the Mac's voice (Settings → «Read alerts aloud»), waiting while you dictate or SaySo is speaking
- Progress in the bot: while the agent works, a «⏳ Working…» message lists each step (searching, running on Linux, sending…) and disappears when the answer arrives
- Message alerts: «let me know when Anna writes» or «summarize what's new in this group»; new messages are batched for a minute and either forwarded to your bot or handled by the agent following your instruction. Listed in Tasks, with a permission rule (asks by default)
- Telegram widgets (Bot API 10.4): the agent sends small live HTML pages to your bot chat (dashboards, charts, tables, calculators) and can update their data later
- render_html: turns an HTML file into a full-page PNG (also very tall ones) or a PDF with WebKit, WebGL and 3D included
- Long jobs on the Linux machine: the agent starts a build, download or script in the background, keeps talking to you, and you get a message (bot) or a notification (Mac) when it ends; the machine stays awake meanwhile
- Statistics → Tokens: input and output tokens per day and per model (exact when the provider reports them, estimated otherwise), also as a chart metric
- Space deleted inside the Linux machine goes back to the Mac (fstrim) every time it starts, and with a «Free up space on the Mac» button in Resources
- Linux machine size in Computer: cores, memory (up to half of the Mac's) and disk (16 to 256 GB, grow only; the partition is extended on the next start)
- Resources also shows what takes space inside the Linux machine while it runs (each prompt-injection detector model, Python and PyTorch, agent files, caches, system), its real memory use, and a button to delete detector models that are not in use
- Statistics → Resources: disk space by part (Linux machine, dictation models, Telegram, database, logs) and memory used by SaySo and assigned to the Linux machine, with buttons to measure again, clean Telegram files and show the folder in Finder
- Memory stays small: near-duplicate notes are not saved, only the newest facts that fit a budget go in each request (instructions always do), and a new memory_search tool finds the rest. Logs of what the agent did go to a file on the Linux machine instead
- Secrets on the Linux machine: a command can ask for keys stored in Secrets and gets them as environment variables, after your OK, without the agent ever seeing their value
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

[Unreleased]: https://github.com/Pepebits/sayso/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/Pepebits/sayso/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Pepebits/sayso/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Pepebits/sayso/releases/tag/v0.2.0
