import SwiftUI
import UIKit

/// M1: remote FAQ content, browsable and searchable, grouped by category.
@Observable
@MainActor
final class HelpCenterViewModel {
    var articles: [HelpArticle] = []
    var searchText: String = ""
    var errorMessage: String?

    private let getHelpArticlesUseCase = DependencyContainer.shared.getHelpArticlesUseCase()

    func load() async {
        do {
            articles = try await getHelpArticlesUseCase.execute()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var filtered: [HelpArticle] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return articles }
        let query = searchText.lowercased()
        return articles.filter { $0.question.lowercased().contains(query) || $0.answer.lowercased().contains(query) }
    }

    var grouped: [(category: HelpArticle.Category, articles: [HelpArticle])] {
        HelpArticle.Category.allCases.compactMap { category in
            let matches = filtered.filter { $0.category == category }
            return matches.isEmpty ? nil : (category, matches)
        }
    }
}

struct HelpCenterView: View {
    @State private var viewModel = HelpCenterViewModel()
    @State private var showingOutsideHoursAlert = false

    private let callSupportUseCase = DependencyContainer.shared.contactSupportByCallUseCase()

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }

            Section {
                Button {
                    callSupport()
                } label: {
                    Label("Call support", systemImage: "phone.fill")
                }
                .accessibilityHint("Available 9 AM to 9 PM IST")
                Text("Available 9 AM – 9 PM IST. Outside these hours, use chat or email below.")
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
                NavigationLink("Contact support") {
                    ContactSupportView()
                }
            } header: {
                Text("Talk to us")
            }

            ForEach(viewModel.grouped, id: \.category) { group in
                Section(group.category.displayName) {
                    ForEach(group.articles) { article in
                        DisclosureGroup(article.question) {
                            Text(article.answer)
                                .font(.brandBody)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 4)
                        }
                    }
                }
            }
            if viewModel.grouped.isEmpty && viewModel.errorMessage == nil {
                Text("No matching articles.").foregroundStyle(Theme.textSecondary)
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search help articles")
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .navigationTitle("Help centre")
        .task { await viewModel.load() }
        .alert("Support is closed right now", isPresented: $showingOutsideHoursAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Phone support is available 9 AM – 9 PM IST. Please use Contact support (chat/email) instead and we'll get back to you.")
        }
    }

    /// M5: gated by BusinessHoursPolicy — only opens the dialer inside
    /// 9am-9pm IST, otherwise points the user at chat/email instead.
    private func callSupport() {
        switch callSupportUseCase.execute() {
        case .callURL(let url):
            Task { await UIApplication.shared.open(url) }
        case .outsideBusinessHours:
            showingOutsideHoursAlert = true
        }
    }
}

#Preview {
    NavigationStack { HelpCenterView() }
}
