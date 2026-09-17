# iTag Mac Lock

A macOS menu-bar app that locks your Mac when you walk away with a cheap Bluetooth tag.

## The problem

In the office and other public places, it is easy to leave a desk for a moment — toilet, kitchen, meeting — and forget to lock the Mac. Anyone nearby can then see the screen.

That is why this project exists: pair a very cheap Bluetooth tag (or module) with the Mac, keep the tag with you, and when you go far enough away the Mac locks itself automatically.

## What it does

- Connects to a generic BLE finder tag (iTAG / iTracing-style keyfinders)
- Watches signal strength (RSSI) and connection status
- Locks the Mac when you walk away or the tag disconnects
- Optional countdown so you can cancel a lock if the signal drops briefly
- Optional: click the tag to lock, double-click to unlock
- Runs from the menu bar

## Who this is for

Anyone who works around other people and wants a simple, low-cost “walk away → lock” setup without buying expensive smart-lock hardware.

## What you need

1. A Mac (macOS 14+)
2. A cheap Bluetooth Low Energy tag or module — for example:
   - Amazon search: “iTAG Bluetooth tracker”, “iTracing tag”, “BLE keyfinder”
   - Alibaba / AliExpress: same kind of generic BLE anti-lost tags
   - Local electronics shops (many sell CR2032-powered iTAG clones)

You do **not** need a special branded device. Most generic iTAG / iTracing tags that work with phone finder apps will work with this project.

Typical cost is only a few dollars. Insert a **CR2032** battery if the tag ships without one.

## How to use it

1. **Install the app**  
   Download the latest build from [Releases](https://github.com/2ta/iTag-mac-lock/releases), unzip, and move `iTagMacLock.app` to Applications. Or build from source in Xcode / with the project in this repo.

2. **Open iTag Mac Lock**  
   It appears in the menu bar (lock / antenna icon). Allow Bluetooth when macOS asks.

3. **Turn on the tag**  
   Long-press the center button until it beeps. Disconnect it from your phone first if it is already paired there — these tags usually talk to one device at a time.

4. **Pair**  
   In the menu, click **Scan for Devices**, hold the tag near the Mac, and choose your tag (often labeled **iTAG**, or unnamed with a strong RSSI).

5. **Walk away**  
   Keep the tag with you. When you leave range (or the tag disconnects), the Mac locks. Adjust **Lock when weaker than** and **Debounce** if it locks too early or too late.

6. **Optional extras**  
   - **Warn before locking** — short countdown with cancel  
   - **Click tag to lock** / **Double-click tag to unlock** — button actions (unlock needs your Mac password in Keychain and Accessibility permission)  
   - **Check for updates weekly** — uses GitHub Releases (no separate server)

## Contributing

Contributions are very welcome.

If you want to help:

- Open an [issue](https://github.com/2ta/iTag-mac-lock/issues) for bugs or ideas
- Send a [pull request](https://github.com/2ta/iTag-mac-lock/pulls) with fixes or improvements
- Test with different cheap BLE tags and report what works

Useful areas: more tag compatibility, quieter disconnect behavior, packaging, localization, and polish.

## Privacy & security notes

- Unlock-by-double-click stores your Mac login password in the Keychain on this machine so it can be typed on the lock screen. Leave that feature off if you do not want that.
- The app talks to GitHub only for optional update checks.
- Locking uses normal macOS lock mechanisms; it does not replace FileVault or your account password.

## License

See the repository for license details. If none is listed yet, open an issue and we can add one.

---

Built for people who forget to lock — so the Mac does it for you when you walk away.
