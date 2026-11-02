// The More screen and the share sheet.
import SwiftUI
import Foundation
import UIKit

struct MoreScreen: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @AppStorage("logbookPilotName") private var pilotName = ""
    @State private var csvImport = false
    @State private var scanning = false
    @State private var importSettings = false
    @State private var share: ShareFile?
    @State private var message: String?
    @State private var completedImport = false
    var onImportFinished: () -> Void = {}
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // The header already says More. Do not repeat the heading here.
                HStack(spacing: 14) {
                    settingsTitle("Appearance", "Choose how \(AppBrand.name) looks")
                    Spacer()
                    Button { theme.toggle() } label: {
                        Text(theme.dark ? "Dark" : "Light").font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(hex: 0x15202A)).padding(.horizontal, 20).padding(.vertical, 12)
                            .background(theme.accent).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }.logbookCard()
                HStack(spacing: 14) {
                    settingsTitle("Import paper logbook", "Scan pages and review draft flights")
                    Spacer()
                    Button("Scan") { completedImport = false; scanning = true }.padding(12).overlay(Capsule().stroke(theme.line))
                }.logbookCard()
                HStack(spacing: 14) {
                    settingsTitle("Import CSV logbook", "Bring flights from another logbook")
                    Spacer()
                    Button("Import") { completedImport = false; csvImport = true }.padding(12).overlay(Capsule().stroke(theme.line))
                }.logbookCard()
                HStack(spacing: 14) {
                    settingsTitle("AI image imports", "Read schedules and handwritten logbooks")
                    Spacer()
                    Button("Connect") { importSettings = true }.padding(12).overlay(Capsule().stroke(theme.line))
                }.logbookCard()
                VStack(alignment: .leading, spacing: 16) {
                    settingsTitle("Export data", "Download a backup or printable logbook")
                    LogField(title: "Pilot name (optional)", value: $pilotName, hint: "Name on printed logbook")
                    HStack(spacing: 14) {
                        Button("CSV") { export(pdf: false) }.padding(12).overlay(Capsule().stroke(theme.line))
                        Button("PDF") { export(pdf: true) }.padding(12).overlay(Capsule().stroke(theme.line))
                    }
                }.logbookCard()
            }.padding(20).padding(.top, 12)
        }.sheet(isPresented: $scanning, onDismiss: finishDismissedImport) {
                ScanReview(schedule: false, onCompletionChanged: { completedImport = $0 })
            }
            .sheet(isPresented: $csvImport, onDismiss: finishDismissedImport) {
                CSVImportView(onCompletionChanged: { completedImport = $0 })
            }
            .sheet(isPresented: $importSettings) { AIImportSettings() }
            .sheet(item: $share) { ShareSheet(items: [$0.url]) }
            .alert("Export", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
    }
    private func settingsTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 19, weight: .heavy, design: .rounded))
            Text(subtitle).font(.subheadline).foregroundStyle(theme.muted)
        }
    }
    private func finishDismissedImport() {
        if completedImport { completedImport = false; onImportFinished() }
    }
    private func export(pdf: Bool) {
        do { share = ShareFile(url: try LogbookExport.make(store.sorted, pdf: pdf, pilotName: pilotName)) }
        catch { message = error.localizedDescription }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // Saving to Photos requires a purpose string in the app target. Other share destinations remain available.
        let canSavePhotos = ["NSPhotoLibraryAddUsageDescription", "NSPhotoLibraryUsageDescription"].contains { key in
            guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !canSavePhotos { controller.excludedActivityTypes = [.saveToCameraRoll] }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
