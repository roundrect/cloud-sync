# cloud-sync

cloud-sync keeps one document in step across a person's Macs: a Swift client and the Cloudflare server
it talks to. It handles linking, pairing, device tokens, revision history, conflict retries and the live
connection. Each app decides what its document means.

macOS only: the client uses Security and CryptoKit.

## Products

| Product | What it is |
|---|---|
| `CloudSync` | The client: `SyncClient`, `CloudSession`, `SyncHost`, `KeyedMerge`, the token stores |
| `server/` | The Worker, a Durable Object per account and D1. See [`server/README.md`](server/README.md) |

## Consuming

```swift
dependencies: [
    .package(url: "https://github.com/roundrect/cloud-sync.git", from: "0.1.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "CloudSync", package: "cloud-sync"),
    ]),
]
```

The package identity SwiftPM derives is the lowercased last URL component, which must stay `cloud-sync`.

> **Prelaunch note.** Until this repo is unveiled publicly, the URL above is not yet reachable.
> Consumers keep the public URL in their manifest and redirect it to `cloud-sync-prelaunch` with a
> SwiftPM mirror, supplied only in remote mode:
>
> ```bash
> swift build --config-path Scripts/swiftpm-remote-config
> ```

## Adopting it in an app

Implement `SyncHost`, then give a `SyncClient` your host, a transport, a token store and a folder:

```swift
struct ExampleHost: SyncHost {
    let format = "example-yaml"     // the server's DOCUMENT_FORMAT
    let maxSchema = 1
    let wording = SyncWording(appName: "Example", documentName: "settings", fileName: "settings file", commandName: "example")
    // documentURL, emptyDocument, and the methods below
}

let client = SyncClient(
    host: ExampleHost(),
    transport: URLSessionCloudTransport(),
    tokens: KeychainTokenStore(
        service: "com.example.app.sync", label: "Example sync token",
        trustedApplicationPaths: KeychainTokenStore.trustedPaths(inBundle: ["Contents/MacOS/Example", "Contents/Resources/example"])),
    link: SyncLink(directory: applicationSupport.appending(path: "sync")),
    clientVersion: "1.2.3")
```

`client` does one-shot work (`link`, `approve`, `pull`, `push`, `revert`, `history`, `devices`). A
`CloudSession` holds the live connection: call `localFileChanged()` when the file changes, and `suspend()`,
`wake()` and `pathSatisfied()` when the Mac sleeps or the network changes.

| The host supplies | Why it is the app's call |
|---|---|
| `text(of:)`, `parse(_:)` | The text that travels. A host that keeps comments returns the file as it stands |
| `loadLocal()`, `save(_:backup:)` | The app's own reader and writer, backups and file location |
| `validationErrors(in:)` | What must never be uploaded |
| `merge(base:local:remote:)` | What a conflict means. `KeyedMerge` covers keyed documents; a document whose meaning depends on order needs its own merge |
| `changes(from:to:)`, `summary(of:maxLength:)` | How a difference reads in history |
| `apply(mayPrompt:)`, `previewApply(of:)`, `hasEffect(_:)` | What the document does to the Mac |

Everything the library says to a person uses `SyncWording`: `error.message(wording)` rather than
`error.description`.
