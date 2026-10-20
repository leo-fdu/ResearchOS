# Reused components

- **PDFChat**, upstream native reader source: native PDFKit reader, API profiles and transports, transcript, history, equation rendering, tests. Its MIT license is included as `PDFChat-LICENSE`. Research OS uses separate application data and API-key entries.
- **PaperMind**, document organization modules: selected document-title, extraction, OCR and organization modules. The original project is retained untouched. The copied configuration was replaced by a paths-only adapter; no original account configuration or service credential is included.
- **Research OS 1**: experiment storage, validation, seed comparison, CSV import and browser interface, adapted for the new native host. Preserved independently for migration and rollback.
- **Marked**, **DOMPurify**, **KaTeX**: bundled local web assets from PDFChat, including their license files in `Sources/PDFChat/Resources/Web/`.
- **PyMuPDF** and **pymupdf4llm**: Python dependencies bundled in the shared edition. See their upstream licensing (AGPL/commercial options for PyMuPDF). They are not silently replaced by network parsing services.
- **Apple** SwiftUI, AppKit, PDFKit, WebKit, WidgetKit frameworks: system runtime.
- **Codex CLI / app-server**: existing separately installed executable, using the user's own login. No browser scraping or ChatGPT-cookie extraction.

`Design/MakeIcon.swift` draws the new Research OS icon. It is independent of PDFChat's original icon.
