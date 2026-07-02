// secrets-vault-helper — mirrors the local vault into this app's own iCloud ubiquity
// container ("Secrets Vault" folder in iCloud Drive). Being scoped to its own container,
// it needs no TCC permission of any kind.
//
//   secrets-vault-helper sync   push local vault -> container (mirrors deletions); quiet on
//                               success; on iCloud-unavailable shows a throttled dialog
//   secrets-vault-helper pull   copy container files missing locally (new machine restore;
//                               never overwrites a local file)
//   secrets-vault-helper path   print the container's Documents path
//
// Exit codes: 0 ok, 1 failure.

import Foundation

let containerID = "iCloud.com.shamruk.secrets-vault-sync"
let fm = FileManager.default

let home = fm.homeDirectoryForCurrentUser
let vaultDir = ProcessInfo.processInfo.environment["SECRETS_VAULT_DIR"].map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent(".secrets-vault")
let stateDir = home.appendingPathComponent("Library/Application Support/secrets-vault")

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// A vault file worth mirroring: stage blobs, the public key, and the encrypted recovery key.
func isVaultFile(_ name: String) -> Bool {
    if name.hasPrefix(".") { return false }
    return name.hasSuffix(".age") || name == "recipient.txt"
}

func relativeVaultFiles(under root: URL) -> [String] {
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                 options: [.skipsHiddenFiles]) else { return [] }
    var out: [String] = []
    let rootPath = root.standardizedFileURL.path
    for case let url as URL in en {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        guard isVaultFile(url.lastPathComponent) else { continue }
        var rel = url.standardizedFileURL.path
        guard rel.hasPrefix(rootPath + "/") else { continue }
        rel.removeFirst(rootPath.count + 1)
        // skip iCloud conflict copies like "sandbox 2.age"
        if rel.range(of: #" [0-9]+\.age$"#, options: .regularExpression) != nil { continue }
        out.append(rel)
    }
    return out.sorted()
}

// Coordinated single-file copy (src is plain local or in-container; dst may be in-container).
func coordinatedCopy(from src: URL, to dst: URL) throws {
    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    var coordErr: NSError?
    var copyErr: Error?
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(readingItemAt: src, options: [],
                           writingItemAt: dst, options: .forReplacing,
                           error: &coordErr) { readURL, writeURL in
        do {
            let data = try Data(contentsOf: readURL)
            try data.write(to: writeURL, options: .atomic)
        } catch { copyErr = error }
    }
    if let e = coordErr { throw e }
    if let e = copyErr { throw e }
}

func coordinatedDelete(_ url: URL) throws {
    var coordErr: NSError?
    var delErr: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordErr) { u in
        do { try fm.removeItem(at: u) } catch { delErr = error }
    }
    if let e = coordErr { throw e }
    if let e = delErr { throw e }
}

func filesEqual(_ a: URL, _ b: URL) -> Bool {
    guard let da = try? Data(contentsOf: a), let db = try? Data(contentsOf: b) else { return false }
    return da == db
}

// Ask the system to download a dataless (evicted) container file and wait briefly.
// Only waits when an iCloud placeholder exists — a genuinely absent file returns at once.
func materialize(_ url: URL) {
    if fm.fileExists(atPath: url.path) { return }
    let ph = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    guard fm.fileExists(atPath: ph.path) else { return }
    try? fm.startDownloadingUbiquitousItem(at: url)
    for _ in 0..<40 {
        if fm.fileExists(atPath: url.path) { return }
        usleep(500_000)
    }
}

func nagIfDue(_ message: String) {
    let nagFile = stateDir.appendingPathComponent("last-nag")
    let now = Int(Date().timeIntervalSince1970)
    let last = (try? String(contentsOf: nagFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    guard now - last > 21600 else { return }
    try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try? "\(now)".write(to: nagFile, atomically: true, encoding: .utf8)
    let script = """
    display dialog "\(message)" with title "secrets-vault" buttons {"OK"} default button "OK" with icon caution giving up after 600
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
}

func containerDocuments() -> URL? {
    guard let base = fm.url(forUbiquityContainerIdentifier: containerID) else { return nil }
    return base.appendingPathComponent("Documents")
}

// ---- commands -------------------------------------------------------------------

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sync"

guard ["sync", "pull", "path"].contains(mode) else {
    log("usage: secrets-vault-helper sync|pull|path")
    exit(2)
}

guard let docs = containerDocuments() else {
    log("iCloud container unavailable — is this Mac signed in to iCloud with iCloud Drive on?")
    if mode == "sync" {
        nagIfDue("iCloud backup of your secrets vault is not running: this Mac appears to be signed out of iCloud (or iCloud Drive is off). Your secrets are safe locally in ~/.secrets-vault.")
    }
    exit(1)
}
let mirrorRoot = docs.appendingPathComponent("vault")

if mode == "path" {
    print(docs.path)
    exit(0)
}

if mode == "pull" {
    guard fm.fileExists(atPath: mirrorRoot.path) else {
        log("nothing to pull: container has no vault data yet")
        exit(0)
    }
    var pulled = 0, kept = 0, failed = 0
    for rel in relativeVaultFiles(under: mirrorRoot) {
        let dst = vaultDir.appendingPathComponent(rel)
        if fm.fileExists(atPath: dst.path) { kept += 1; continue }
        let src = mirrorRoot.appendingPathComponent(rel)
        materialize(src)
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: src)
            try data.write(to: dst, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
            print("  pulled \(rel)")
            pulled += 1
        } catch {
            log("  pull failed for \(rel): \(error.localizedDescription)")
            failed += 1
        }
    }
    print("pull: pulled=\(pulled) kept-local=\(kept) failed=\(failed)")
    exit(failed == 0 ? 0 : 1)
}

// sync (push): local vault is the source of truth; mirror additions, changes and deletions.
guard fm.fileExists(atPath: vaultDir.path) else { exit(0) }   // nothing to back up yet

var failures = 0

// A marker file so the Finder folder materializes and a stranger knows what this is.
let readme = docs.appendingPathComponent("README.txt")
if !fm.fileExists(atPath: readme.path) {
    try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
    try? """
    Encrypted backup of a secrets-vault (https://github.com/shamruk/skills-secrets-vault).
    Files are age-encrypted; useless without the vault identity or its recovery passphrase.
    """.write(to: readme, atomically: true, encoding: .utf8)
}

let localFiles = relativeVaultFiles(under: vaultDir)
for rel in localFiles {
    let src = vaultDir.appendingPathComponent(rel)
    let dst = mirrorRoot.appendingPathComponent(rel)
    materialize(dst)
    if fm.fileExists(atPath: dst.path) && filesEqual(src, dst) { continue }
    do {
        try coordinatedCopy(from: src, to: dst)
    } catch {
        log("mirror failed for \(rel): \(error.localizedDescription)")
        failures += 1
    }
}

// mirror deletions (primary wins)
if fm.fileExists(atPath: mirrorRoot.path) {
    let localSet = Set(localFiles)
    for rel in relativeVaultFiles(under: mirrorRoot) where !localSet.contains(rel) {
        do { try coordinatedDelete(mirrorRoot.appendingPathComponent(rel)) }
        catch {
            log("mirror delete failed for \(rel): \(error.localizedDescription)")
            failures += 1
        }
    }
}

if failures == 0 {
    try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try? "\(Int(Date().timeIntervalSince1970))".write(to: stateDir.appendingPathComponent("last-sync"),
                                                      atomically: true, encoding: .utf8)
    exit(0)
} else {
    nagIfDue("iCloud backup of your secrets vault hit \(failures) error(s) while copying. Your secrets are safe locally in ~/.secrets-vault; the backup copy may be stale.")
    exit(1)
}
