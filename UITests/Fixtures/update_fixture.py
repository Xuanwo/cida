"""A real Sparkle update served only inside the disposable Tart guest.

Copies the manifest-bound app into two isolated, ad-hoc-signed fixture bundles. The
executable is unchanged; only identity, versions and the signed loopback feed differ.
The test never replaces the release artifact or contacts the public update service.
"""
import pathlib
import plistlib
import subprocess
import threading
import uuid


class UpdateFixture:
    def __init__(self, artifact, root, base_url):
        self.root = pathlib.Path(root) / ("update-" + uuid.uuid4().hex)
        self.root.mkdir(parents=True)
        self.identifier = "com.xuanwo.Cida.Automation.Update." + uuid.uuid4().hex
        self.release = threading.Event()
        self.download_started = False
        self.completed_downloads = 0
        self.app = self.root / "installed" / "Cida.app"
        target = self.root / "target" / "Cida.app"
        signer = self.root / "sign.swift"
        signer.write_text('''import CryptoKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let keyURL = root.appendingPathComponent("test-key")
let key: Curve25519.Signing.PrivateKey
if FileManager.default.fileExists(atPath: keyURL.path) {
  key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
} else {
  key = Curve25519.Signing.PrivateKey()
  try key.rawRepresentation.write(to: keyURL)
}
if CommandLine.arguments.count == 2 {
  print(key.publicKey.rawRepresentation.base64EncodedString())
} else {
  print(try key.signature(for: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))).base64EncodedString())
}
''')
        def sign(path=None):
            args = ["/usr/bin/swift", str(signer), str(self.root)]
            if path:
                args.append(str(path))
            return subprocess.check_output(args, text=True).strip()
        public_key = sign()
        for app, version in ((self.app, "1"), (target, "2")):
            subprocess.run(["/usr/bin/ditto", str(artifact), str(app)], check=True)
            info_path = app / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info.update(CFBundleIdentifier=self.identifier, CFBundleVersion=version,
                        CFBundleShortVersionString=version + ".0", SUPublicEDKey=public_key,
                        SUFeedURL=base_url + "/update/appcast.xml", SURequireSignedFeed=True)
            info.pop("CidaUpdateChannel", None)
            info_path.write_bytes(plistlib.dumps(info))
            subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-",
                            "--options", "0", str(app)], check=True, capture_output=True)
        self.archive = self.root / "update.zip"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                        str(target), str(self.archive)], check=True)
        signature = sign(self.archive)
        feed = (f'<?xml version="1.0" encoding="utf-8"?>\n'
                f'<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                f'<channel><title>Cida local update test</title><item><title>Cida 2.0</title>'
                f'<description>更新操作只需确认一次。</description><sparkle:version>2</sparkle:version>'
                f'<sparkle:shortVersionString>2.0</sparkle:shortVersionString>'
                f'<enclosure url="{base_url}/update/app.zip" length="{self.archive.stat().st_size}" '
                f'type="application/octet-stream" sparkle:edSignature="{signature}"/>'
                f'</item></channel></rss>\n').encode()
        feed_path = self.root / "unsigned.xml"
        feed_path.write_bytes(feed)
        self.feed = feed + (f'<!-- sparkle-signatures:\nedSignature: {sign(feed_path)}\n'
                            f'length: {len(feed)}\n-->\n').encode()
        # An ephemeral test key, never a user's update signing identity.
        (self.root / "test-key").unlink()

    def status(self):
        info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        executable = str(self.app / "Contents/MacOS/Cida")
        processes = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True)
        pids = [int(line.strip().split(None, 1)[0]) for line in processes.splitlines()
                if len(line.strip().split(None, 1)) == 2
                and line.strip().split(None, 1)[1].split(" -", 1)[0] == executable]
        return {"appPath": str(self.app), "identifier": self.identifier, "pids": pids,
                "version": info["CFBundleVersion"], "downloadStarted": self.download_started,
                "completedDownloads": self.completed_downloads}

    def serve(self, handler, path):
        if path == "/update/appcast.xml":
            data = self.feed
        elif path == "/update/app.zip":
            self.download_started = True
            # Hold the payload until the journey has inspected or dismissed the progress UI.
            if not self.release.wait(timeout=120):
                handler.send_error(504)
                return
            data = self.archive.read_bytes()
        else:
            handler.send_error(404)
            return
        handler.send_response(200)
        handler.send_header("Content-Length", str(len(data)))
        handler.send_header("Content-Type", "application/xml" if path.endswith("xml") else "application/zip")
        handler.end_headers()
        try:
            handler.wfile.write(data)
            if path.endswith("zip"):
                self.completed_downloads += 1
        except (BrokenPipeError, ConnectionResetError):
            pass
