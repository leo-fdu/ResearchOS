# Research OS

A native macOS workspace for connecting research papers, notes, code, datasets,
projects and ideas — with a Codex-powered research assistant.

**Apple Silicon · macOS 14+ · Local workspace · Your own ChatGPT account**

## Download and install

Download the **DMG** from [Releases](https://github.com/leo-fdu/ResearchOS/releases/latest),
open it, and drag **Research OS** into **Applications**. Eject the disk image and
launch the app from Applications.

Python and PDF processing dependencies are included. No Python, Homebrew or Xcode
installation is needed to use the shared edition. The first-launch setup can
install Codex from OpenAI's official release, then guide you through signing in
and connecting your own folders. You can also use an existing Codex installation.

**This release is ad hoc signed and has not been notarized by Apple.** If macOS
blocks the first launch, read [Apple's instructions](https://support.apple.com/en-us/102445)
and only proceed if you trust the source. Do not disable system protections.

## What it does

- **Projects and ideas:** create them yourself or ask the assistant to create or
  update them. Keep summaries, progress, linked resources and detailed notes together.
- **Papers:** read PDFs inside the app, ask about selections or pages, and return
  to earlier conversations associated with the same paper.
- **Organize:** infer paper titles, rename PDFs in the connected library, and save
  Markdown reading copies. The default pass runs newest-modified first and stops
  at the first up-to-date paper. Choose a library containing a `pdf/` subfolder.
- **Connected resources:** browse papers, Markdown notes, repositories and datasets
  in place. Repository and dataset catalogs use top-level entries rather than
  indexing every file. Sort resources by name or modification time.
- **Research assistant:** choose model and reasoning effort, stream responses,
  steer a running discussion, and control web search, memory and analysis files.
- **Local history and memory:** conversations and structured research records stay
  in a local SQLite workspace. Memory can capture durable preferences and decisions.
- **Desktop research card:** keep a compact view of the workspace on the desktop.

## Data and permissions

The distribution contains **no private research files, account credentials,
conversation history, workspace database or preselected personal folders**.
Connect your own directories on first launch. Original files remain in place.

Workspace data is stored in `~/Library/Application Support/Research OS 2/`.
The assistant sends content it reads to the model service; this is not an offline
LLM. Models, access and usage limits depend on your own account. Analysis files
allow writes to the app's artifacts directory; additional file permissions are
handled by Codex approval prompts.

Organize changes filenames and creates Markdown files in your connected library.
It is an explicit operation, not an automatic action on every PDF you open.

## Current limitations

- Apple Silicon build only; no Windows, Linux or iOS application is provided.
- No Developer ID signature or Apple notarization in this release.
- Scanned-page OCR requires optional Tesseract; ordinary PDF reading does not.
- The WidgetKit extension is excluded from this shared build. The in-app desktop
  research card is included.
- The optional app-managed Codex install pins version **0.163.0**. It does not
  update itself. System/Homebrew Codex installations take precedence and use their
  normal update mechanism. New CLI versions may require integration updates.
- The newest-first Organize boundary can miss new PDFs whose modification times
  were preserved from an older download; a full pass is available in the service.
- This build has been compiled and packaged on the development Mac; a clean second
  Mac installation and end-to-end account setup have not yet been verified.

## Build from source

See [Distribution/BUILDING.md](Distribution/BUILDING.md) for the native build,
pinned portable Python runtime, packaging inputs and DMG command. Source archives
for the bundled AGPL PDF dependencies are included inside the release DMG.

The Swift package includes existing tests; this distribution update did not run
the full test suite.

## Credits and license

Built on native SwiftUI, AppKit, PDFKit and WebKit. Reuses PDFChat's reader/chat
components and PaperMind's document organization code. See [THIRD_PARTY.md](THIRD_PARTY.md)
and [Distribution/LICENSE-NOTICE.txt](Distribution/LICENSE-NOTICE.txt).

Research OS's shared edition is distributed under **GNU AGPL v3**, with original
third-party notices retained. See [LICENSE](LICENSE).
