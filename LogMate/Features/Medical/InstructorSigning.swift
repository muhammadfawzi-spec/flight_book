// Instructor signing flow: the signature canvas, the signing sheet, the
// signature card, and the approach picker.
import SwiftUI
import Foundation
import UIKit
import PencilKit

struct SignatureCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    @MainActor final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: SignatureCanvas
        var isApplyingDrawing = false

        init(_ parent: SignatureCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingDrawing else { return }

            let newDrawing = canvasView.drawing
            guard newDrawing.dataRepresentation() != parent.drawing.dataRepresentation() else {
                return
            }

            parent.drawing = newDrawing
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.accessibilityLabel = "Instructor signature. Draw with a finger or Apple Pencil."

        // Set the initial drawing before enabling drawing callbacks.
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        guard canvas.drawing.dataRepresentation() != drawing.dataRepresentation() else {
            return
        }

        // A SwiftUI update must not write back into the SwiftUI binding.
        coordinator.isApplyingDrawing = true
        defer { coordinator.isApplyingDrawing = false }
        canvas.drawing = drawing
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        canvas.delegate = nil
    }
}

struct InstructorSigningView: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    let flight: Flight
    let onSigned: (InstructorSignature) -> Void
    @State private var agreed = false
    @State private var agreedAt: Date?
    @State private var next = false
    @State private var profile = InstructorProfile()
    @State private var expiration = Date()
    @State private var hasExpiration = false
    @State private var recentEnd = Date()
    @State private var hasRecentEnd = false
    @State private var comments = ""
    @State private var drawing = PKDrawing()
    @State private var instructorAffirmed = false
    @State private var problem: String?
    var body: some View {
        SheetFrame(title: next ? "Instructor signature" : "Before signing") {
            VStack(alignment: .leading, spacing: 18) {
                if !next {
                    Text(InstructorSignature.agreement).foregroundStyle(theme.text).logbookCard()
                    Toggle("I agree and affirm the instructor will sign personally", isOn: $agreed)
                    AccentButton(title: "Next") { agreedAt = Date(); next = true }.disabled(!agreed)
                } else {
                    Text("Hand the device to your instructor to review this entry and sign.")
                        .font(.subheadline).foregroundStyle(theme.muted)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(flight.shortDate + " · " + flight.registration + " · " + flight.aircraftModel).font(.headline)
                        Text(flight.route)
                        let hoursSummary = "Total " + hours(flight.total) + " h · Dual " + hours(flight.dual) + " h · PIC " + hours(flight.pic) + " h"
                        Text(hoursSummary)
                        DisclosureGroup("Review all recorded times and comments") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Cross-country \(hours(flight.crossCountry)) · Night \(hours(flight.night)) · IMC \(hours(flight.imc)) · Simulated instrument \(hours(flight.simulatedInstrument)) · Instructor \(hours(flight.instructor)) h")
                                Text("Day / night landings \(flight.dayLandings) / \(flight.nightLandings) · Approaches \(flight.approachCount) · Holds \(flight.holds)")
                                Text("Class: \(flight.category) · Complex: \(flight.complex ? "Yes" : "No") · HP: \(flight.highPerformance ? "Yes" : "No") · TAA: \(flight.taa ? "Yes" : "No")")
                                if flight.facts.has("flightReview") { Text("Flight review · Ground \(hours(flight.facts.amounts["reviewGround", default: 0])) h · Endorsement \(flight.facts.has("reviewEndorsed") ? "recorded" : "not recorded")") }
                                if flight.facts.has("checkride") { Text("Checkride · \(flight.facts.has("checkridePassed") ? "Passed qualifying practical test" : "Passing result not confirmed")") }
                                if !flight.approaches.isEmpty { Text(flight.approaches) }
                                if !flight.notes.isEmpty { Text(flight.notes) }
                            }.font(.caption).padding(.top, 10)
                        }.font(.subheadline)
                    }.logbookCard()
                    if !store.instructors.isEmpty {
                        Menu("Choose a previous CFI") {
                            ForEach(store.instructors) { instructor in
                                Button(instructor.name + " · " + instructor.certificate) { select(instructor) }
                            }
                        }.foregroundStyle(theme.accent)
                    }
                    LogField(title: "Instructor name", value: $profile.name, hint: "Full name")
                    LogField(title: "Instructor email", value: $profile.email, hint: "name@example.com", keyboard: .emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    LogField(title: "Certificate #", value: $profile.certificate, hint: "Instructor certificate number")
                    Toggle("No expiration", isOn: $profile.noExpiration)
                        .onChange(of: profile.noExpiration) { _, value in if value { hasExpiration = false; profile.expiration = nil } }
                    if !profile.noExpiration {
                        Toggle("Enter expiration date", isOn: $hasExpiration)
                        if hasExpiration { DatePicker("Expiration", selection: $expiration, displayedComponents: .date) }
                    } else {
                        Toggle("Include recent-experience end date", isOn: $hasRecentEnd)
                        if hasRecentEnd { DatePicker("Recent experience ends", selection: $recentEnd, displayedComponents: .date) }
                        Text("A certificate without an expiration date does not by itself establish current instructor privileges.")
                            .font(.caption).foregroundStyle(theme.muted)
                    }
                    Text("Instructor comments / training given").font(.subheadline).foregroundStyle(theme.muted)
                    TextEditor(text: $comments).frame(minHeight: 105).padding(10).scrollContentBackground(.hidden)
                        .background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 14))
                    HStack { Text("Draw signature").font(.headline); Spacer(); Button("Clear") { drawing = PKDrawing(); instructorAffirmed = false } }
                    SignatureCanvas(drawing: $drawing).frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line))
                    Toggle("I am the named instructor. I reviewed this flight and training description, and am authorized to sign this entry.", isOn: $instructorAffirmed)
                        .font(.subheadline)
                    AccentButton(title: "Attach signature to this flight", action: attach)
                    Text("Comments and the signature are entered fresh for every flight.")
                        .font(.caption).foregroundStyle(theme.muted)
                }
            }
        }.alert("Check signature", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }
    private func select(_ instructor: InstructorProfile) {
        profile = instructor
        hasExpiration = instructor.expiration != nil && !instructor.noExpiration
        expiration = instructor.expiration ?? Date()
        hasRecentEnd = instructor.recentExperienceEnd != nil
        recentEnd = instructor.recentExperienceEnd ?? Date()
        comments = ""; drawing = PKDrawing(); instructorAffirmed = false
    }
    private func attach() {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.email = profile.email.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.certificate = profile.certificate.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailParts = profile.email.split(separator: "@", omittingEmptySubsequences: false)
        guard !profile.name.isEmpty, !profile.certificate.isEmpty, emailParts.count == 2,
              !emailParts[0].isEmpty, emailParts[1].contains("."), !profile.email.contains(where: { $0.isWhitespace }) else {
            problem = "Enter the instructor's name, email, and certificate number."; return
        }
        guard profile.noExpiration || hasExpiration else { problem = "Enter an expiration date or select No expiration."; return }
        guard !comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "The instructor must describe the training or endorsement in the comments."; return
        }
        guard agreed, let agreedAt, instructorAffirmed, !drawing.strokes.isEmpty,
              drawing.bounds.width > 2, drawing.bounds.height > 2 else {
            problem = "The instructor must draw a signature and affirm the entry."; return
        }
        profile.expiration = profile.noExpiration ? nil : expiration
        profile.recentExperienceEnd = profile.noExpiration && hasRecentEnd ? recentEnd : nil
        let rect = drawing.bounds.insetBy(dx: -10, dy: -10)
        let ink = drawing.image(from: rect, scale: 2)
        let image = UIGraphicsImageRenderer(size: rect.size).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: rect.size))
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }
        guard let png = image.pngData() else { problem = "The signature image could not be saved. Please try again."; return }
        onSigned(InstructorSignature(instructor: profile, comments: comments, inkPNG: png, signedAt: Date(),
            agreedAt: agreedAt, flightDigest: flight.recordDigest, flightSnapshot: flight.recordSnapshot))
        dismiss()
    }
}

struct InstructorSignatureCard: View {
    @EnvironmentObject var theme: AppTheme
    let signature: InstructorSignature
    var valid = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Instructor signature").font(.headline)
            Text(signature.instructor.name + " · Certificate " + signature.instructor.certificate).font(.subheadline.bold())
            Text(signature.instructor.email).font(.caption).foregroundStyle(theme.muted)
            Text(signature.instructor.noExpiration ? "No certificate expiration" : "Expiration: " + (signature.instructor.expiration.map { FlightDates.string($0) } ?? "Not recorded"))
                .font(.caption).foregroundStyle(theme.muted)
            if let end = signature.instructor.recentExperienceEnd { Text("Recent experience ends: " + FlightDates.string(end)).font(.caption) }
            Text(signature.comments).font(.subheadline)
            if let image = UIImage(data: signature.inkPNG) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 100)
                    .padding(12).frame(maxWidth: .infinity).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Text("Signed " + FlightDates.string(signature.signedAt, format: "MMM d, yyyy h:mm a") + " · Identity not verified by the app")
                .font(.caption2).foregroundStyle(theme.muted)
            if !valid { Text("The flight changed after signing. Re-sign the entry before using this signature.").font(.caption).foregroundStyle(.red) }
        }.logbookCard()
    }
}

struct ApproachPickerView: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var catalog = ApproachCatalog.shared
    let airports: [String]
    let add: (String) -> Void
    @State private var airport = ""
    @State private var selected = ""
    @State private var type = "RNAV (GPS)"
    @State private var runway = "01"
    @State private var variant = ""
    @State private var manual = false
    @State private var manualText = ""
    private let types = ["RNAV (GPS)", "RNAV (RNP)", "ILS", "LOC", "VOR", "VOR/DME", "NDB", "LDA", "SDF", "Visual"]
    private var choices: [LoggedProcedure] { catalog.choices(airport) }
    var body: some View {
        SheetFrame(title: "Log an approach") {
            VStack(alignment: .leading, spacing: 16) {
                if !airports.isEmpty {
                    Picker("Airport", selection: Binding(get: { airports.contains(AirportRoute.canonical(airport)) ? AirportRoute.canonical(airport) : "" }, set: { airport = $0 })) { ForEach(Array(Set(airports)).sorted(), id: \.self) { Text($0).tag($0) }; Text("Other airport").tag("") }
                }
                LogField(title: "Airport code", value: $airport, hint: "KRHV").textInputAutocapitalization(.characters)
                if !choices.isEmpty {
                    Picker("Approach", selection: Binding(get: { selected == "other" ? "other" : choices.first { $0.name == selected }?.family ?? "" }, set: { family in
                        selected = family == "other" ? "other" : choices.first { $0.family == family }?.name ?? ""
                    })) {
                        Text("Choose a procedure").tag("")
                        ForEach(Array(Set(choices.map(\.family))).sorted(), id: \.self) { Text($0).tag($0) }
                        Text("Other / historical procedure").tag("other")
                    }.pickerStyle(.menu)
                }
                if choices.isEmpty || selected == "other" {
                    Text("Select the procedure you flew. Available FAA procedures appear automatically when found.")
                        .font(.caption).foregroundStyle(theme.muted)
                    Picker("Approach type", selection: $type) { ForEach(types, id: \.self) { Text($0).tag($0) } }
                    Picker("Variant (optional)", selection: $variant) { Text("None").tag(""); ForEach(["X", "Y", "Z", "A", "B", "C"], id: \.self) { Text($0).tag($0) } }
                }
                let procedure = choices.first { $0.name == selected }
                if let procedure {
                    Picker("Runway", selection: Binding(get: { choices.first { $0.name == selected }?.runway ?? "" }, set: { runway in
                        if let match = choices.first(where: { $0.family == procedure.family && $0.runway == runway }) { selected = match.name }
                    })) {
                        ForEach(Array(Set(choices.filter { $0.family == procedure.family }.map(\.runway))).sorted(), id: \.self) { Text($0.isEmpty ? "Circling / no runway" : $0).tag($0) }
                    }.pickerStyle(.menu)
                } else {
                    Picker("Runway", selection: $runway) {
                        Text("Circling / no runway").tag("")
                        ForEach((1...36).flatMap { number in ["", "L", "C", "R"].map { String(format: "%02d", number) + $0 } }, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.menu)
                }
                Button("Don’t see your approach?") { withAnimation(.easeInOut(duration: 0.2)) { manual.toggle() } }
                    .foregroundStyle(theme.cyan)
                if manual {
                    LogField(title: "Approach flown", value: $manualText, hint: "RNAV-Z 31R")
                    Text("Use the airport above and enter the procedure and runway.").font(.caption).foregroundStyle(theme.muted)
                }
                if !catalog.message.isEmpty { Text(catalog.message).font(.caption).foregroundStyle(theme.muted) }
                AccentButton(title: "Add approach") {
                    let code = AirportRoute.canonical(airport)
                    let name = manual ? manualText.trimmingCharacters(in: .whitespacesAndNewlines) : procedure?.name ?? type + (variant.isEmpty ? "" : " " + variant) + (runway.isEmpty ? "" : " RWY " + runway)
                    add(code + " · " + name); dismiss()
                }.disabled(AirportRoute.codes(airport).count != 1 || (manual ? manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : (!choices.isEmpty && selected.isEmpty)))
            }
        }.onAppear { if airport.isEmpty { airport = airports.first ?? "" } }
            .onChange(of: airport) { _, _ in selected = "" }
            .task { await catalog.refresh() }
    }
}
