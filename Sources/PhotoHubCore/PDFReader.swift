import SwiftUI
import PDFKit

public enum PDFLimits {
    public static let maximumBytes: Int64 = 250 * 1024 * 1024
}

/// Both viewers own the document only while presented; no decrypted file is written.
public struct MediaPDFReader: View {
    @State private var document: PDFDocument?
    @State private var password = ""
    @State private var locked: Bool
    @State private var failure = ""

    public init(data: Data) {
        let document = PDFDocument(data: data)
        _document = State(initialValue: document)
        _locked = State(initialValue: document?.isLocked ?? false)
    }

    public var body: some View {
        Group {
            if let document {
                if locked {
                    VStack(spacing: 16) {
                        Text("PDFのパスワード")
                        SecureField("パスワード", text: $password).onSubmit { unlock(document) }
                        Button("開く") { unlock(document) }.disabled(password.isEmpty)
                        if !failure.isEmpty { Text(failure).foregroundStyle(.red) }
                    }.padding().frame(maxWidth: 360)
                } else if document.pageCount > 0 {
                    PDFSurface(document: document)
                } else { Text("ページのないPDFです。") }
            } else { Text("PDFを読み取れません。ファイルが破損している可能性があります。") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onDisappear { password = ""; document = nil }
    }

    private func unlock(_ document: PDFDocument) {
        if document.unlock(withPassword: password) { locked = false; failure = "" }
        else { failure = "パスワードが一致しません。" }
        password = ""
    }
}

#if os(macOS)
private struct PDFSurface: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView { configuredPDFView(document) }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: ()) { view.document = nil }
}
#elseif os(iOS)
private struct PDFSurface: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView { configuredPDFView(document) }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
    static func dismantleUIView(_ view: PDFView, coordinator: ()) { view.document = nil }
}
#endif

private func configuredPDFView(_ document: PDFDocument) -> PDFView {
    let view = PDFView()
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.document = document
    view.autoScales = true
    return view
}
