import AppKit
import BitampAppleMusicPak
import BitampPakSDK

// Apple Music as a Pak. MusicKit wants a real app: an NSApplication running its run loop (not
// shown anywhere), with the request loop on a thread of its own.
let provider = MainActor.assumeIsolated { AppleMusicProvider(pak: AppleMusicPak()) }
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task.detached {
    await PakRunner.serve(provider, input: FileHandle.standardInput.bytes.lines) { line in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
    exit(0)
}
app.run()
