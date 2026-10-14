import SwiftUI
import PhotoHubCore
import AssetLibraryContract

struct MacUsageScreen: View {
    @EnvironmentObject private var model: MacModel
    @State private var report: UsageReport?
    @State private var activity: [UsageActivity] = []
    @State private var loading = false
    @State private var error = ""
    private var destination: String { model.bucket + "|" + model.profile + "|" + model.region }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button("AWSから更新", systemImage: "arrow.clockwise") { Task { await load(refresh: true) } }.disabled(loading || model.awsLoginRequired)
                    if loading { ProgressView().controlSize(.small) }
                }
                Text("更新時に保存量と既存予算を読み取り、集計だけを非公開S3へ保存してiPhoneと共有します。")
                    .font(.caption).foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).foregroundStyle(.secondary) }
                UsageDashboard(report: report, activity: activity, device: "このMac")
            }.padding(24).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
        }.task(id: destination) { report = nil; activity = []; await load(refresh: false) }
    }
    private func load(refresh: Bool) async {
        guard !loading else { return }
        loading = true; error = ""
        let identity = model.privacyID, selected = destination
        let body: [String: Any] = ["bucket": model.bucket, "profile": model.profile, "region": model.region]
        defer { loading = false }
        do {
            let value: UsageReport = try await model.runtime.request(refresh ? "/usage/refresh" : "/usage", method: "POST", body: body)
            guard identity == model.privacyID, selected == destination, !Task.isCancelled else { return }
            report = value
        } catch is CancellationError { }
        catch { if identity == model.privacyID, selected == destination { self.error = error.localizedDescription; if refresh { model.handle(error) } } }
        do {
            let value: [UsageActivity] = try await model.runtime.request("/usage/activity", method: "POST", body: body)
            if identity == model.privacyID, selected == destination, !Task.isCancelled {
                var combined = Dictionary(uniqueKeysWithValues: value.map { ($0.date, $0) })
                for point in UsageActivityStore.shared.history(scope: model.usageScope) {
                    var day = combined[point.date] ?? UsageActivity(date: point.date)
                    day.requests += point.requests; day.receivedBytes += point.receivedBytes; day.videoStarts += point.videoStarts
                    combined[point.date] = day
                }
                activity = combined.values.sorted { $0.date < $1.date }
            }
        } catch { }
    }
}
