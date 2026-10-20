import SwiftUI

struct MessageListView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var contextStore: PDFContextStore
    var body: some View {
        TranscriptView(viewModel: viewModel, onPage: contextStore.goToPage,
                       onRetry: { viewModel.retry(contextStore: contextStore) })
    }
}
