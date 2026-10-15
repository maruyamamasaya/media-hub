import SwiftUI
import Charts
import AssetLibraryContract

public struct UsageDashboard: View {
    private let report: UsageReport?
    private let activity: [UsageActivity]
    private let device: String
    public init(report: UsageReport?, activity: [UsageActivity], device: String) {
        self.report = report; self.activity = activity; self.device = device
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) }
    private func yen(_ value: Double) -> String { value.formatted(.currency(code: "JPY").precision(.fractionLength(0))) }
    private func day(_ value: String) -> Date {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value) ?? .distantPast
    }
    private var month: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Tokyo"); f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let report {
                VStack(alignment: .leading, spacing: 8) {
                    Text("S3保存量").font(.headline)
                    Text(bytes(report.storageBytes)).font(.largeTitle).monospacedDigit()
                    Text("更新：\(report.updatedAt) · Macで更新した集計").font(.caption).foregroundStyle(.secondary)
                    Text("鍵付き・暗号化フォルダを含む総量です。素材名や内容は表示しません。").font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("保存量の推移 · GiB") {
                    Chart(report.history, id: \.date) { point in
                        LineMark(x: .value("記録日", day(point.date)), y: .value("保存量 GiB", Double(point.storageBytes) / 1_073_741_824))
                        PointMark(x: .value("記録日", day(point.date)), y: .value("保存量 GiB", Double(point.storageBytes) / 1_073_741_824))
                            .accessibilityLabel(point.date).accessibilityValue(bytes(point.storageBytes))
                    }.frame(height: 180).chartYAxisLabel("GiB")
                    Text("更新した日の記録だけを表示 · 最大90日分").font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("保存量の内訳") {
                    VStack(spacing: 8) {
                        breakdown("通常原本", report.normalBytes, total: report.storageBytes)
                        breakdown("暗号化データ（小画像を含む）", report.encryptedBytes, total: report.storageBytes)
                        breakdown("通常の小画像", report.thumbnailBytes, total: report.storageBytes)
                        breakdown("管理情報・その他", report.metadataBytes, total: report.storageBytes)
                        breakdown("過去バージョン", report.previousBytes, total: report.storageBytes)
                    }.padding(.vertical, 8)
                }
                GroupBox("月額の目安") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let estimate = report.storageEstimateYen {
                            HStack { Text("保存費のみ"); Spacer(); Text(yen(estimate)).font(.title2).monospacedDigit() }
                            ProgressView(value: min(estimate, report.targetYen), total: max(1, report.targetYen))
                            Text("全体の運用目標 \(yen(report.targetYen))／月 · 強制上限ではありません")
                            Text("\(report.region) · $\(report.rateUSDPerGiB.formatted())/GiB · 1ドル\(report.exchangeRate.formatted())円 · 税倍率\(report.taxMultiplier.formatted())")
                        } else { Text("このリージョン・保存クラスの保存費は未試算です。") }
                        Text("転送・API等を含む月額合計と確定請求は未取得です。").foregroundStyle(.secondary)
                    }.font(.caption).padding(.vertical, 8)
                }
                if report.history.contains(where: { $0.storageEstimateYen != nil }) {
                    GroupBox("保存費の目安の推移 · 円／月") {
                        Chart(report.history.filter { $0.storageEstimateYen != nil }, id: \.date) { point in
                            LineMark(x: .value("記録日", day(point.date)), y: .value("保存費 円／月", point.storageEstimateYen ?? 0))
                            PointMark(x: .value("記録日", day(point.date)), y: .value("保存費 円／月", point.storageEstimateYen ?? 0))
                                .accessibilityLabel(point.date).accessibilityValue(yen(point.storageEstimateYen ?? 0))
                        }.frame(height: 150).chartYAxisLabel("円／月")
                        Text("各記録日の保存量を1か月保持した場合の試算です。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let budget = report.budget {
                    GroupBox("AWSアカウント全体の既存予算") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("反映済み $\(budget.actualUSD.formatted(.number.precision(.fractionLength(2)))) ／ $\(budget.limitUSD.formatted())").monospacedDigit()
                            ProgressView(value: min(budget.actualUSD, budget.limitUSD), total: max(1, budget.limitUSD))
                            if let forecast = budget.forecastUSD { Text("AWS予測 $\(forecast.formatted(.number.precision(.fractionLength(2))))") }
                            Text("通知設定 \(budget.notificationCount)件 · 登録宛先 \(budget.recipientCount)件 · 受信は未確認")
                            Text("このアプリ以外の費用も含みます。請求の反映には遅れがあります。").foregroundStyle(.secondary)
                        }.font(.caption).padding(.vertical, 8)
                    }
                }
                ForEach(report.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("S3保存量はMacで「AWSから更新」を押すと表示されます。").foregroundStyle(.secondary)
            }
            activityPanel
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func breakdown(_ label: String, _ amount: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label); Spacer(); Text(bytes(amount)).monospacedDigit() }.font(.caption)
            ProgressView(value: Double(amount), total: Double(max(1, total)))
        }
    }
    private var activityPanel: some View {
        let current = activity.filter { $0.date.hasPrefix(month) }
        let amount = current.reduce(Int64(0)) { $0 + $1.receivedBytes }
        let requests = current.reduce(Int64(0)) { $0 + $1.requests }
        let starts = current.reduce(Int64(0)) { $0 + $1.videoStarts }
        return GroupBox("\(device)の通信記録 · 今月") {
            VStack(alignment: .leading, spacing: 12) {
                Text("記録済み受信 \(bytes(amount)) · 通信 \(requests)回 · 再生開始 \(starts)回").monospacedDigit()
                if !current.isEmpty {
                    Text("日別の通信回数").font(.caption)
                    Chart(current) { point in
                        BarMark(x: .value("日付", day(point.date)), y: .value("通信 回", point.requests))
                            .accessibilityLabel(point.date).accessibilityValue("\(point.requests)回")
                    }.frame(height: 120).chartYAxisLabel("回")
                    Text("日別の記録済み受信量").font(.caption)
                    Chart(current) { point in
                        BarMark(x: .value("日付", day(point.date)), y: .value("受信 MiB", Double(point.receivedBytes) / 1_048_576))
                            .accessibilityLabel(point.date).accessibilityValue("\(bytes(point.receivedBytes))、\(point.requests)回")
                    }.frame(height: 150).chartYAxisLabel("MiB")
                } else { Text("記録はこの機能の導入後から始まります。").foregroundStyle(.secondary) }
                Text(device == "このMac" ? "このMacのS3 CLI呼出回数と取得完了した原本・小画像の容量、暗号化の直接受信を記録します。CLI内部の再試行・途中失敗の受信量は含みません。軽量版のローカル再生も再生開始に含みます。" : "このiPhoneの写真・管理情報・暗号化の受信を記録します。通常動画はプレーヤーが報告した受信量のみ追加し、動画の通信回数・未報告分・認証通信は含みません。キャッシュ表示は通信に数えません。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("端末ごとの導入後の記録で、他端末とは合算しません。AWSの請求転送量とは異なります。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 8)
        }
    }
}
