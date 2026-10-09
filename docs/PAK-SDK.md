# Writing an Expansion Pak

<p align="center">
  <img src="images/expansion-paks.png" width="307" alt="The Expansion Paks window with the Demo Pak plugged in">
</p>

An Expansion Pak adds a music source to Bitamp: a server, a radio directory, an archive. Bitamp shows each Pak as a cartridge in its Expansion Paks window (⌥K). Its songs can be searched, added to the playlist and played like local files, with the equalizer, visualizer and Retro Sound all working.

A Pak is a program. Bitamp starts it, asks it questions over standard input and output, and plays the audio it points to. You can write one in Swift with the small SDK in this repository, or in any language that can read and write lines of JSON.

The demo Pak in `Sources/BitampDemoPak` is a complete example. It plays a few public-domain tunes as chiptunes and needs no server. Build it with `scripts/make-pak.sh`, then double-click `Demo.bitpak` to install it.

## What a Pak is

A folder whose name ends in `.bitpak`:

```
Radio.bitpak/
  pak.json      what the Pak is and which settings it needs
  radio-pak     the program (any name; pak.json says which)
```

`pak.json`:

```json
{
  "id": "radio",
  "name": "Radio",
  "version": "1.0",
  "executable": "radio-pak",
  "protocol": 1,
  "description": "Stations from my radio server.",
  "settings": [
    { "key": "server", "label": "Server", "type": "text" },
    { "key": "password", "label": "Password", "type": "password" },
    { "key": "quality", "label": "Quality", "type": "choice", "options": ["Low", "High"], "default": "High" }
  ]
}
```

- **id** is 1 to 32 lowercase letters, digits and hyphens, starting with a letter. It names the Pak's settings, and its tracks' URLs in playlists (`bitpak-radio://track/<your id>`). Keep it the same between versions.
- **name** is shown on the cartridge and in menus ("Radio Pak").
- **executable** is the program, relative to the folder. It must be inside the folder and executable.
- **protocol** is the version of the messages below. This is version 1.
- **settings** are optional. Bitamp shows a form for them (right-click the cartridge ▸ Settings…) and passes their values to the Pak. `text` is one line, `password` is kept in the macOS Keychain, `choice` is a pop-up of `options`.

## Messages

Bitamp writes one JSON request per line to the Pak's standard input. The Pak writes one JSON response per line to its standard output, with the same `id`. Anything printed to standard error goes to Bitamp's log (Console.app, process Bitamp). Don't print anything else to standard output.

```
→ {"id":1,"method":"search","params":{"term":"jazz"}}
← {"id":1,"result":{"tracks":[{"id":"42","title":"Take Five","artist":"Dave Brubeck","duration":324}]}}
← {"id":2,"error":{"message":"The server didn't answer."}}
```

An `error` message is shown to the listener, so write it for them.

| Method | Params | Result |
|---|---|---|
| `hello` | `protocol`, `settings` (key → value), `cacheDirectory` | `{"account": Account}` |
| `configure` | `settings` | `{"account": Account}` |
| `search` | `term` (may be empty: list what you'd show first) | `{"tracks": [Track]}` |
| `track` | `id` | `{"track": Track or null}` |
| `resolve` | `id` | `{"source": Source}` |
| `shutdown` | none | `{}`, then exit |

- **hello** comes first, every time the program starts. `cacheDirectory` is a folder for the Pak's own files; Bitamp creates it.
- **configure** comes when the user saves new settings.
- **Account** is `{"state": "connected" | "disconnected" | "limited", "message": "…"}`. `disconnected` lights the cartridge amber and asks the user to set the Pak up. `limited` means it works with a catch, which `message` explains.
- **Track** is `{"id", "title", "artist", "album", "duration"}`. Only `id` and `title` are required. `duration` is in seconds. `id` is yours: Bitamp stores it in playlists and gives it back to `track` and `resolve`, possibly after a relaunch.
- **Source** is where the audio is: `{"file": "/absolute/path.mp3"}` for a file the Pak made or downloaded, or `{"url": "https://…", "headers": {"Authorization": "…"}}` for one Bitamp should download. Bitamp downloads the whole file before playing it and keeps it in the Pak's cache. Any format macOS plays works: MP3, AAC, ALAC, FLAC, WAV, AIFF.

Bitamp starts the program when it's first needed and keeps it running. It sends `shutdown` when it quits or the Pak is removed, and the input closes too; exit when either happens. A Pak that takes more than 30 seconds to answer gets an error. One that crashes is started again, but not after three crashes in a minute.

## In Swift

Make a Swift package for your Pak that depends on `BitampPakSDK` from this repository. Only the SDK and the message types it uses get built, not Bitamp itself. Keep `pak.json` next to the code and leave it out of the target:

```
Radio/
  Package.swift
  Sources/RadioPak/main.swift
  Sources/RadioPak/pak.json
```

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RadioPak",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/ryanromanov/Bitamp.git", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "RadioPak",
            dependencies: [.product(name: "BitampPakSDK", package: "Bitamp")],
            exclude: ["pak.json"]),
    ]
)
```

Then implement four methods and hand the rest to `PakRunner`:

```swift
import BitampPakSDK

final class RadioPak: PakProvider {
    private var server: URL?

    func configure(_ context: PakContext) async throws -> PakAccountState {
        guard let text = context.settings["server"], let url = URL(string: text) else {
            return PakAccountState(.disconnected, message: "Enter your server's address.")
        }
        server = url
        return .connected
    }

    func search(_ term: String) async throws -> [PakTrackInfo] {
        // Ask the server; turn what it says into PakTrackInfo.
    }

    func track(id: String) async throws -> PakTrackInfo? { … }

    func resolve(id: String) async throws -> PakSource {
        guard let server else { throw PakFailure("Set up the Radio Pak first.") }
        return .url(server.appendingPathComponent("stream/\(id)"))
    }
}

PakRunner.run(RadioPak())
```

Throw `PakFailure("…")` for a message the listener should see. `PakRunner.log(_:)` writes to Bitamp's log.

To package it, copy [`scripts/make-pak.sh`](../scripts/make-pak.sh) into your package and run it there. It builds the program in release mode, puts it and `pak.json` in `Radio.bitpak` (named after the manifest's `name`), and ad-hoc signs it, which Apple Silicon requires. Add `--universal` for a program that also runs on Intel Macs. When a package has more than one Pak, name the target: `./make-pak.sh RadioPak`.

## In another language

Read lines, answer them. A whole Pak in Python:

```python
#!/usr/bin/env python3
import json, sys

TRACKS = [{"id": "gymnopedie", "title": "Gymnopédie No. 1", "artist": "Erik Satie",
           "url": "https://example.com/music/gymnopedie.mp3"}]

def info(track):
    return {k: track[k] for k in ("id", "title", "artist")}

def answer(method, params):
    if method in ("hello", "configure"):
        return {"account": {"state": "connected"}}
    if method == "search":
        term = params["term"].lower()
        return {"tracks": [info(t) for t in TRACKS if term in t["title"].lower() or term in t["artist"].lower()]}
    if method == "track":
        return {"track": next((info(t) for t in TRACKS if t["id"] == params["id"]), None)}
    if method == "resolve":
        track = next(t for t in TRACKS if t["id"] == params["id"])
        return {"source": {"url": track["url"]}}
    if method == "shutdown":
        return {}
    raise ValueError("Unknown method " + method)

for line in sys.stdin:
    request = json.loads(line)
    try:
        reply = {"id": request["id"], "result": answer(request["method"], request["params"])}
    except Exception as error:
        reply = {"id": request["id"], "error": {"message": str(error)}}
    print(json.dumps(reply), flush=True)
    if request["method"] == "shutdown":
        break
```

Save it as `hello.py` in `Hello.bitpak`, `chmod +x` it, and point `pak.json`'s `executable` at it. Remember `flush=True`, or the equivalent in your language: Bitamp waits for each whole line. There's nothing to build; check it with `--check-pak` (below) and install it.

## Trying it

- Talk to the program by hand first: `printf '%s\n' '{"id":1,"method":"search","params":{"term":""}}' | ./radio-pak`.
- Then let Bitamp 0.6.0 or later check it, without installing it. (An older Bitamp ignores `--check-pak` and just opens; `brew upgrade --cask bitamp` updates it.)

  ```
  $ /Applications/Bitamp.app/Contents/MacOS/Bitamp --check-pak Radio.bitpak --setting server=http://nas.local:4533
  ✓ pak.json: Radio Pak 1.0, id “radio”, runs radio-pak
  ✓ hello: connected
  ✓ search "": 25 tracks, first “Take Five”
  ✓ track “42”: “Take Five”
  ✓ resolve “42”: http://nas.local:4533/stream/42 (not downloaded)
  ✓ shutdown: exited
  The Radio Pak looks good. Double-click it to install it.
  ```

  It reads `pak.json` as installing does, then starts the program and has the same conversation Bitamp has, using the first track it finds. It catches what usually goes wrong: answers that aren't flushed, other output on standard output, a `track` that forgets an id `search` gave, a file that isn't there, and a program that doesn't exit. Settings take their defaults unless you give `--setting key=value`, once per setting. What the program writes to standard error is shown as it runs. It exits with status 0 when there's nothing to fix.
- Install by double-clicking the `.bitpak`, dropping it on Bitamp, or File ▸ Install Expansion Pak…. Installing a Pak with the same id replaces the old one.
- Installed Paks live in `~/Library/Application Support/Bitamp/Paks`; their caches in `~/Library/Caches/com.ryanromanov.Bitamp/Paks`.
- Right-click the cartridge to search, change settings, eject or remove it.

## Trust

A Pak runs with the same permissions as the person who installed it, so Bitamp asks before installing one and says so. It removes the download quarantine from a Pak after the user agrees, so macOS doesn't block the program. If you distribute a Pak, sign it (`codesign`), and say where its source is.

## Not yet

- **Streaming.** Bitamp downloads the whole file before it starts playing. Fine for songs on a home server, not for endless radio streams.
- **Paks that play audio themselves**, as a streaming service's own player would, can't be third-party yet; a third-party Pak always hands Bitamp audio to play.
- **Album art and browsing** beyond search.
