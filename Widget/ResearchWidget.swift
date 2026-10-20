import AppIntents
import SwiftUI
import WidgetKit

struct Snapshot: Decodable {
  struct Item: Decodable, Identifiable {
    let id: String
    let title: String
  }
  let updatedAt: String
  let projects: [Item]
  let tasks: [Item]
  let ideas: [Item]
  static let empty = Snapshot(updatedAt: "", projects: [], tasks: [], ideas: [])
}
struct ResearchEntry: TimelineEntry {
  let date: Date
  let snapshot: Snapshot
}
struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> ResearchEntry {
    ResearchEntry(date: Date(), snapshot: .empty)
  }
  func getSnapshot(in context: Context, completion: @escaping (ResearchEntry) -> Void) {
    completion(entry())
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<ResearchEntry>) -> Void) {
    completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(1800))))
  }
  private func entry() -> ResearchEntry {
    let url = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.com.niqi.researchos")?.appendingPathComponent(
        "widget.json")
    let snapshot =
      url.flatMap { try? Data(contentsOf: $0) }.flatMap {
        try? JSONDecoder().decode(Snapshot.self, from: $0)
      } ?? .empty
    return ResearchEntry(date: Date(), snapshot: snapshot)
  }
}
struct ResearchWidgetView: View {
  let entry: ResearchEntry
  @Environment(\.widgetFamily) private var family
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "sparkle.magnifyingglass")
        Text("Research OS").fontWeight(.semibold)
        Spacer()
        Link(destination: URL(string: "researchos://quick")!) { Image(systemName: "plus.circle") }
      }.font(.caption).foregroundStyle(Color(red: 0.13, green: 0.4, blue: 0.36))
      if let project = entry.snapshot.projects.first {
        Link(destination: URL(string: "researchos://object/" + project.id)!) {
          Text(project.title).font(.headline).lineLimit(2)
        }
      } else {
        Text("从一个问题开始").font(.headline)
        Text("Open 应用，ConnectionProjects与Resources").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(entry.snapshot.tasks.prefix(family == .systemSmall ? 1 : 3)) { task in
        Link(destination: URL(string: "researchos://object/" + task.id)!) {
          Label(task.title, systemImage: "circle").font(.caption).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      Text(entry.snapshot.updatedAt.isEmpty ? "Waiting for workspace snapshot" : "Open workspace继续研究").font(.caption2)
        .foregroundStyle(.secondary)
    }.containerBackground(for: .widget) { Color(red: 0.96, green: 0.97, blue: 0.94) }.widgetURL(
      URL(string: "researchos://home"))
  }
}
@main struct ResearchWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "ResearchOSFocus", provider: Provider()) {
      ResearchWidgetView(entry: $0)
    }.configurationDisplayName("Research workspace").description("Projects、Next steps行动与Quick capture入口。").supportedFamilies([
      .systemSmall, .systemMedium, .systemLarge,
    ])
  }
}
