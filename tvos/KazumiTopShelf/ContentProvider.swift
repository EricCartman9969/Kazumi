import TVServices

/// Shows recently watched shows in the Apple TV Top Shelf. Selecting one opens
/// the show; pressing Play resumes it.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        let items = TopShelfShared.read()
        guard !items.isEmpty else {
            completionHandler(nil)
            return
        }
        let shelfItems: [TVTopShelfSectionedItem] = items.map { item in
            let shelf = TVTopShelfSectionedItem(identifier: String(item.subjectID))
            shelf.title = item.subtitle.isEmpty ? item.title : "\(item.title) · \(item.subtitle)"
            shelf.imageShape = .poster
            if let url = URL(string: item.image) {
                shelf.setImageURL(url, for: .screenScale1x)
                shelf.setImageURL(url, for: .screenScale2x)
            }
            shelf.displayAction = TVTopShelfAction(url: TopShelfShared.url(subjectID: item.subjectID, resume: false))
            shelf.playAction = TVTopShelfAction(url: TopShelfShared.url(subjectID: item.subjectID, resume: true))
            return shelf
        }
        let section = TVTopShelfItemCollection(items: shelfItems)
        section.title = "继续观看"
        completionHandler(TVTopShelfSectionedContent(sections: [section]))
    }
}
