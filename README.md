# Pers

A macOS app that wraps the `claude` CLI in a game-style interface: tabs per repo and worktree, a chat with a portrait that reacts to what Claude is doing, a built-in diff and git log, a terminal, saved actions and an API tester.

## Build and run

Requirements: macOS 15 or later, a Swift 5.9+ toolchain (Xcode or the command line tools), and the [`claude` CLI](https://docs.claude.com/en/docs/claude-code) installed and logged in.

```sh
./build.sh
open "Pers.app"
```

`build.sh` runs `swift build -c release` and assembles `Pers.app` in the repo root. To run without packaging, use `swift run`.

## Sprites

The portrait beside the chat shows a pixel-art party member for each model: a wizard penguin for Opus, a blue jay bard for Sonnet and a sparrow ranger for Haiku. Each has idle, thinking, talking and worried faces, blinks, and wears a random outfit colour per session. Toggle the portrait with ⌘P or in Settings.

### Using your own sprites

1. Open the map (⌃M), go to **Settings** and choose **Open sprites folder**. This opens `~/Library/Application Support/Pers/Sprites/`.
2. Add one folder per sprite set. The folder name is the set's name in Settings.
3. Back in Settings, pick the set for each model. The preview cycles through its moods.

A set folder looks like this:

```
Sprites/
  My Wizard/
    idle.png            required
    thinking.png        optional
    talking.png         optional
    worried.png         optional
    idle-blink.png      optional, eyes closed; any mood can have a -blink frame
    talking-open.png    optional, mouth open, alternated with talking.png while Claude talks
```

- A missing mood shows `idle.png`, and a missing frame shows its mood's still image.
- Images are scaled to fit the portrait (about 210×248 points) and anchored to the bottom, so a head-and-shoulders crop with a transparent background works best.
- Images narrower than 210 px are treated as pixel art and scaled up without smoothing.
- Folders added or changed while the app runs are picked up when you open Settings or switch back to the app.

### Layered sets

A set can instead hold several outfits that share face overlays. Each Claude session then wears a random outfit. Put a `manifest.json` in the folder:

```json
{
  "outfits": [{ "file": "outfit1.png", "set": "general" }],
  "eyes": { "general": ["eyes_F00_E1.png", "eyes_F00_E2.png", "eyes_F00_E3.png"] },
  "mouths": { "general": ["mouth_F00_M1.png", "mouth_F00_M2.png", "mouth_F00_M3.png"] },
  "eyesOffset": { "x": 0, "y": 0 },
  "mouthsOffset": { "x": 0, "y": 0 }
}
```

- Images sit on a 2048×2048 canvas. The portrait shows the head-and-shoulders region (x 420–1580, y 680–2048). The offsets place the eye and mouth overlays, in canvas pixels.
- Each outfit uses the overlays listed under its `set`, or under `general`.
- Overlay names contain an expression code between underscores: `_F01_` idle, `_F02_` thinking, `_F00_` talking, `_F06_` worried. They end in `_E1`–`_E3` (eyes open, half, closed) or `_M1`–`_M3` (mouth closed, half, open). Missing expressions fall back to `F00`.

## Pers actions

Actions are saved shell commands (build, run a server, deploy) shown in the ACTIONS panel (⌘⇧A with the Vim preset, ⌘I with the video game preset). They live in `~/Library/Application Support/Pers/actions.json`, which the app watches, so edits appear in a running app.

The repo ships a Claude Code skill, `pers-action`, in `.claude/skills/pers-action/`. Ask Claude in any repo to "add a pers action to run this" and it reads the repo, drafts the action, shows it for your approval and writes it to `actions.json`.

To use the skill from other repos, copy the folder to `~/.claude/skills/pers-action/`.

Action fields:

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Uppercase UUID. |
| `repo` | no | Absolute path of the repo's main checkout, shared by its worktrees. Omit for a global action. |
| `command` | yes | Shell script, run with the session's directory as cwd. |
| `nickname` | no | Display name. |
| `environment` | no | `KEY=value` lines exported before the command. |
| `readyMarker` | no | Output text that means a long-running command has started. |
| `choices` | no | One option per line. Running asks which one and exports it as `$CHOICE`. |

Don't put literal secrets in `environment`: the file is plain text. Look them up instead, for example `TOKEN=$(security find-generic-password -s name -w)`. The app warns when a credential-like variable has a typed-in value.

## API tester requests

Saved requests live in `~/Library/Application Support/Pers/requests.json`, grouped into folders by `repo`, the absolute path of a repo's main checkout. The app reloads the file when it is replaced and opens the newly added request.

The repo ships a Claude Code skill, `pers-create-api-request`, in `.claude/skills/pers-create-api-request/`. Ask Claude in any repo to "make a pers request for /search" and it reads the repo's routes and config, names the request in the style of that folder's existing ones and writes it to `requests.json`.

To use the skill from other repos, copy the folder to `~/.claude/skills/pers-create-api-request/`.

## Features

**Claude sessions**
- Tabs grouped by repo, each running its own `claude` session; sessions and chat history are saved and restored.
- Choose the model (Opus, Sonnet, Haiku), permission mode (manual, accept edits, plan, auto, don't ask, bypass) and effort (low to max) per tab, with shortcuts to cycle them.
- Streaming chat with markdown, syntax-highlighted code and inline diffs for Edit and Write tool calls.
- Permission prompts answered from the keyboard (allow, allow always, deny), including multiple-choice questions from Claude.
- Paste or attach images, and long pastes collapse into `[Pasted text #1 +42 lines]`.
- Input history, drafts kept per tab, and zsh-style suggestions from your shell history.
- Load a saved session, including ones started from the terminal, and fork a conversation from any message.
- Optional advisor: a second, read-only Claude reviews each turn and flags notes, concerns or blockers.
- Status line with model, mode, git state and how full the context window is, plus token counts.
- Interrupt a running turn and reset a session.

**Git and worktrees**
- New worktree tabs created in `<repo>/.claude/worktrees/` on a new branch.
- Worktree cleanup popup when closing a tab, to delete the worktree and branch.
- Diff view of your changes against main or against unstaged edits, with word-level highlights and file and folder navigation.
- Git log of commits that no remote has, with each commit's diff.
- Open the diff's file in IntelliJ.

**Terminal**
- A shell per tab that keeps its state, with Claude and terminal input switchable from one box.
- Terminal output keeps its colours and shows in the chat; open a finished command's terminal from its message.

**Actions and API tester**
- Saved shell commands per repo or global, with environment, ready markers, choices, live output, and stop, edit and delete.
- Per-repo HTTP request collection with method, URL, headers and body, and response status, time, size, headers and body.
- Header values can use `$(…)` so tokens stay out of the save file.
- A chat bar on the page to ask Claude about requests or run a shell command.

**Interface**
- A map page to move between Claude sessions, the API tester, keybindings and settings.
- Settings page to toggle the portrait and choose a sprite set per model, with a live preview.
- Animated pixel-art portraits that react to what Claude is doing, with support for your own sprite sets.
- Four themes (neutral, quest, terminal, phantom), a date and moon-phase panel, and a session overview.
- Keybindings page with Vim and video game presets, rebindable keys with conflict detection, and on-screen hints that follow your bindings.
- Keyboard navigation of messages, diffs, lists and panels in a Vim-like navigate mode.
