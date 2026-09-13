import SwiftUI

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

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }
            ForEach(viewModel.grouped, id: \.category) { group in
                Section(group.category.displayName) {
                    ForEach(group.articles) { article in
                        DisclosureGroup(article.question) {
                            Text(article.answer)
                                .font(.brandBody)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                }
            }
            if viewModel.grouped.isEmpty && viewModel.errorMessage == nil {
                Text("No matching articles.").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search help articles")
        .navigationTitle("Help centre")
        .task { await viewModel.load() }
    }
}

#Preview {
    NavigationStack { HelpCenterView() }
}
