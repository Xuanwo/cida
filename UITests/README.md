# Isolated macOS UI regression

The critical XCUI flow runs in a disposable macOS VM so it cannot take focus,
clipboard contents, credentials, or desktop space from the host session.

## Golden VM contract

The default local image is `cida-ui-golden` and contains:

- macOS 26.4 on Apple silicon
- Xcode 26.5 with command-line tools selected
- the Tart Guest Agent and an auto-login test administrator
- a working WindowServer and XCTest automation authorization
- passwordless guest administration so the runner can disable Ethernet before testing
- display sleep, Setup Assistant, and saved application windows disabled
- the one-time Xcode extension notification cleared for deterministic unattended
  runs

Install Tart with the official tap:

```sh
brew install openai/tools/tart
```

The image name can be overridden with `CIDA_TART_GOLDEN_VM`. Keep the macOS
serial stable when cloning the golden image; a randomized serial makes macOS
treat the clone as a new Mac and reopens Setup Assistant.

## Run

```sh
scripts/test-ui-in-tart.sh
```

The runner makes a new clone, randomizes only its MAC address, and starts Tart
with `--no-graphics --no-audio --no-clipboard`. Once the Guest Agent is ready,
the runner disables the clone's Ethernet service before copying test data or
starting any test. Source is mounted read-only and copied inside the guest; only the
artifact directory is writable from the VM.
The disposable root disk uses cached, unsynchronized I/O; all retained test
artifacts remain on the separately shared host directory.
The guest verifies that a public egress probe fails before any test and
the clone is stopped and deleted on success, failure, or interruption.
If Tart cannot create its control socket or the disposable guest never reaches
a ready GUI session, the runner discards that clone and retries once with a new
clone. Test-build failures and application assertion failures are never retried.

The run covers the complete Swift suite, a Release input/responder-chain gate,
and the XCUI critical flow. Native interaction tests run in bounded shards; the
runner enumerates the suite first and fails if any test is not selected by a
shard, preventing new regressions from being silently omitted. The XCUI flow configures an isolated local endpoint,
model, and API Key; closes Settings with the native window control; verifies
multiline growth and shrinkage; submits from detached history; consumes delayed,
uneven SSE chunks; follows the result to completion; and validates the exact
request body. It also asserts that the history Accessibility tree contains no
result-owned nested scroll area. After an active swipe and scrollbar hover, a
pixel regression measures the trailing thumb and rejects anything wider than
6 pt or outside the fixed 80–100 pt tolerance around Pencil's 4 × 90 pt source.

Artifacts are written to `TestResults/vm-ui`:

- `CidaUITests.xcresult` contains the XCTest report, video, screenshots, and UI
  hierarchy diagnostics.
- `xcresult-summary.json` is regenerated from that exact result bundle after a
  successful run and contains the authoritative pass/fail/test counts.
- `release-input-interaction.json` records the Release responder-chain result.
- `openai-request.json` records the request received by the isolated mock.
- `vm-progress.log` records clone, VM, Guest Agent, GUI session, build, and test
  stages with the infrastructure attempt number; the build logs preserve the
  corresponding command output.

If `UITests/project.yml` changes, regenerate the checked-in project with:

```sh
xcodegen generate --spec UITests/project.yml
```

The virtual display is an interaction and layout test target, not proof of
visible 120 Hz presentation. The separate non-activating performance gates keep
the 120 Hz workload contract and must still run on 120 Hz-capable hardware.
