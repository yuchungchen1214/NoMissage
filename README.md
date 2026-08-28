# NoMissage

A small native macOS menu bar app for recording Messenger conversations to a local JSON file.

NoMissage was made because Meta's official data export can be incomplete, difficult to use, and not suitable for continuously collecting recent conversations. This app provides a simple local record for AI-assisted summaries, review, and work support.

![NoMissage recording Messenger conversations](demo-v1.2.0.png)

---

## Main functionality

- Reads the active Messenger conversation in Google Chrome
- Reads only when Chrome is in the foreground and the active tab is on `messenger.com`
- Supports personal and group conversations
- Records `sent_at`, `sender`, `type`, and `text`
- Removes duplicate messages
- Keeps a configurable record window from 1 to 999 days
- Lets users choose the JSON folder and filename
- Starts and stops from the app or menu bar
- Optional launch and recording at login
- No hidden LaunchAgent; quitting the app stops recording

## Supported Messenger languages

The parser currently supports:

- English
- Español
- 繁體中文 (Traditional Chinese)

The app interface is English. Conversation names and message content remain in their original language.

---

## Download

For regular use, [download the latest release](https://github.com/yuchungchen1214/nomissage/releases), open `NoMissage-macos-arm.dmg`, and drag NoMissage to Applications.

### macOS

- Apple Silicon: [NoMissage-macos-arm.dmg](https://github.com/yuchungchen1214/nomissage/releases/latest/download/NoMissage-macos-arm.dmg)

Developers can build the app from source with the instructions below.

---

## Requirements

- macOS 13 or later
- Xcode 15 or later
- Google Chrome with an active Messenger session

---

## Build

```bash
./scripts/build_app.sh
open dist/NoMissage.app
```

To create a distributable DMG:

```bash
./scripts/build_dmg.sh
```

Or build the executable directly:

```bash
swift build -c release
```

## Permissions

macOS may ask NoMissage for permission to control Google Chrome. Allow it in:

**System Settings → Privacy & Security → Automation**

Chrome may also ask to allow JavaScript from Apple Events. This is required to read the visible Messenger page.

---

## Data and privacy

Records stay on your Mac as unencrypted JSON. NoMissage does not upload messages or send them to a server.

Please protect the record file and consider the privacy of everyone included in the conversations. NoMissage only reads content available in the active Messenger page; it does not retrieve every historical conversation automatically.

---

## License

MIT License. See [LICENSE](LICENSE).

NoMissage © 2026 WhARTS Ltd.
