#if canImport(SwiftUI)
import SwiftUI

/// The texts of `.appControlGate(_:)`. `{version}` and `{date}` are replaced at display time.
public struct AppControlGateTexts: Sendable, Equatable {
    public var updateRequiredTitle: String
    /// Shown with the minimum (or latest) version as `{version}`.
    public var updateRequiredMessage: String
    public var updateAvailableTitle: String
    public var updateAvailableMessage: String
    public var updateButton: String
    public var maintenanceTitle: String
    /// Used when the maintenance window has no message.
    public var maintenanceMessage: String
    /// Shown with the end of the window as `{date}`.
    public var maintenanceUntil: String
    public var maintenanceBannerTitle: String
    public var retryButton: String
    public var dismissButton: String

    public init(updateRequiredTitle: String, updateRequiredMessage: String, updateAvailableTitle: String, updateAvailableMessage: String,
                updateButton: String, maintenanceTitle: String, maintenanceMessage: String, maintenanceUntil: String,
                maintenanceBannerTitle: String, retryButton: String, dismissButton: String) {
        self.updateRequiredTitle = updateRequiredTitle
        self.updateRequiredMessage = updateRequiredMessage
        self.updateAvailableTitle = updateAvailableTitle
        self.updateAvailableMessage = updateAvailableMessage
        self.updateButton = updateButton
        self.maintenanceTitle = maintenanceTitle
        self.maintenanceMessage = maintenanceMessage
        self.maintenanceUntil = maintenanceUntil
        self.maintenanceBannerTitle = maintenanceBannerTitle
        self.retryButton = retryButton
        self.dismissButton = dismissButton
    }

    public static let english = AppControlGateTexts(
        updateRequiredTitle: "Update required",
        updateRequiredMessage: "This version is no longer supported. Update to version {version} or later to keep using the app.",
        updateAvailableTitle: "Update available",
        updateAvailableMessage: "Version {version} is available.",
        updateButton: "Update",
        maintenanceTitle: "Under maintenance",
        maintenanceMessage: "We're doing some maintenance. Please try again later.",
        maintenanceUntil: "Expected back by {date}.",
        maintenanceBannerTitle: "Maintenance in progress",
        retryButton: "Try again",
        dismissButton: "Dismiss"
    )

    public static let italian = AppControlGateTexts(
        updateRequiredTitle: "Aggiornamento necessario",
        updateRequiredMessage: "Questa versione non è più supportata. Aggiorna alla versione {version} o successiva per continuare a usare l'app.",
        updateAvailableTitle: "Aggiornamento disponibile",
        updateAvailableMessage: "È disponibile la versione {version}.",
        updateButton: "Aggiorna",
        maintenanceTitle: "Manutenzione in corso",
        maintenanceMessage: "Stiamo facendo manutenzione. Riprova più tardi.",
        maintenanceUntil: "Torniamo entro {date}.",
        maintenanceBannerTitle: "Manutenzione in corso",
        retryButton: "Riprova",
        dismissButton: "Chiudi"
    )

    /// Italian when the user's preferred language is Italian, else English.
    public static var automatic: AppControlGateTexts {
        let language = Locale.preferredLanguages.first?.lowercased() ?? ""
        return language.hasPrefix("it") ? .italian : .english
    }

    func fill(_ template: String, version: String? = nil, date: Date? = nil) -> String {
        var result = template
        if let version { result = result.replacingOccurrences(of: "{version}", with: version) }
        if let date { result = result.replacingOccurrences(of: "{date}", with: date.formatted(date: .abbreviated, time: .shortened)) }
        return result
    }
}

extension View {
    /// Blocks the app for a required update or a blocking maintenance (full screen), and shows a
    /// dismissible banner for an available update or a non-blocking maintenance.
    /// Checks while the scene is active and again whenever it becomes active.
    public func appControlGate(_ client: AppControl, texts: AppControlGateTexts = .automatic) -> some View {
        modifier(AppControlGateModifier(client: client, texts: texts))
    }
}

struct AppControlGateModifier: ViewModifier {
    let client: AppControl
    let texts: AppControlGateTexts

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var status: AppStatus?
    /// The available version the user dismissed: its banner stays hidden until a newer one comes.
    @AppStorage("appcontrol.gate.dismissedUpdate") private var dismissedUpdate = ""
    /// The non-blocking maintenance the user dismissed (by start), for this session.
    @State private var dismissedMaintenance: Date?

    private var blockingMaintenance: Maintenance? {
        guard let maintenance = status?.maintenance, maintenance.blocking else { return nil }
        return maintenance
    }

    private var isRequired: Bool { status?.update == .required }
    private var isBlocked: Bool { blockingMaintenance != nil || isRequired }

    private var bannerMaintenance: Maintenance? {
        guard let maintenance = status?.maintenance, !maintenance.blocking, maintenance.startsAt != dismissedMaintenance else { return nil }
        return maintenance
    }

    private var bannerUpdate: Release? {
        guard status?.update == .available, let latest = status?.latest, latest.version != dismissedUpdate else { return nil }
        return latest
    }

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(isBlocked)
            .overlay(alignment: .top) {
                if !isBlocked {
                    VStack(spacing: 8) {
                        if let maintenance = bannerMaintenance {
                            Banner(
                                icon: "wrench.and.screwdriver",
                                title: texts.maintenanceBannerTitle,
                                message: maintenanceLines(maintenance),
                                actionTitle: nil,
                                action: nil,
                                dismissTitle: texts.dismissButton,
                                dismiss: { dismissedMaintenance = maintenance.startsAt }
                            )
                        }
                        if let latest = bannerUpdate {
                            Banner(
                                icon: "arrow.down.circle",
                                title: texts.updateAvailableTitle,
                                message: texts.fill(texts.updateAvailableMessage, version: latest.version),
                                actionTitle: latest.storeURL == nil ? nil : texts.updateButton,
                                action: latest.storeURL.map { url in { openURL(url) } },
                                dismissTitle: texts.dismissButton,
                                dismiss: { dismissedUpdate = latest.version }
                            )
                        }
                    }
                    .padding(.horizontal)
                    .animation(.default, value: status)
                }
            }
            .overlay {
                if let maintenance = blockingMaintenance {
                    Cover(
                        icon: "wrench.and.screwdriver",
                        title: texts.maintenanceTitle,
                        message: maintenanceLines(maintenance),
                        buttonTitle: texts.retryButton,
                        action: { Task { status = await client.status(force: true) } }
                    )
                } else if isRequired, let status {
                    let url = status.latest?.storeURL
                    Cover(
                        icon: "arrow.down.app",
                        title: texts.updateRequiredTitle,
                        message: texts.fill(texts.updateRequiredMessage, version: status.minimum ?? status.latest?.version ?? ""),
                        buttonTitle: url == nil ? nil : texts.updateButton,
                        action: { if let url { openURL(url) } }
                    )
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                for await next in client.statusUpdates() {
                    status = next
                }
            }
    }

    private func maintenanceLines(_ maintenance: Maintenance) -> String {
        var lines = [maintenance.message ?? texts.maintenanceMessage]
        if let end = maintenance.endsAt { lines.append(texts.fill(texts.maintenanceUntil, date: end)) }
        return lines.joined(separator: "\n")
    }
}

/// A full-screen cover the user cannot dismiss.
private struct Cover: View {
    let icon: String
    let title: String
    let message: String
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: icon)
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if let buttonTitle {
                        Button(buttonTitle, action: action)
                            .gateProminentButton()
                            .padding(.top, 8)
                    }
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
        .transition(.opacity)
    }
}

/// A dismissible banner shown above the content.
private struct Banner: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
    let dismissTitle: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.subheadline.bold())
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissTitle)
        }
        .padding(12)
        .gateBannerBackground()
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    @ViewBuilder
    func gateProminentButton() -> some View {
        #if os(watchOS)
        buttonStyle(.bordered)
        #else
        buttonStyle(.borderedProminent)
        #endif
    }

    @ViewBuilder
    func gateBannerBackground() -> some View {
        #if os(watchOS)
        background(Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        #else
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        #endif
    }
}
#endif
