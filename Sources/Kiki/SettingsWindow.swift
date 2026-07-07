import AppKit
import SwiftUI
import KikiStore

/// Ventana normal (no HUD) de Ajustes: `NSWindow` con `NSHostingView`,
/// singleton reutilizado entre aperturas (patrón similar a `HUDController`
/// pero con ventana titulada/cerrable en vez de panel flotante borderless).
///
/// `isReleasedWhenClosed = false` es la clave de la reutilización: cerrar la
/// ventana (botón rojo o Cmd+W) solo la oculta, no la destruye — `window`
/// sigue apuntando a la misma instancia, así que `show()` puede reordenarla
/// al frente en vez de reconstruir toda la jerarquía SwiftUI cada vez.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let viewModel: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        viewModel.refreshAll()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        newWindow.title = "kiki — Ajustes"
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.contentView = NSHostingView(rootView: SettingsRootView(viewModel: viewModel))
        window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsRootView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        TabView {
            DictionaryTabView(viewModel: viewModel)
                .tabItem { Label("Diccionario", systemImage: "text.book.closed") }
            SnippetsTabView(viewModel: viewModel)
                .tabItem { Label("Snippets", systemImage: "text.insert") }
            HistoryTabView(viewModel: viewModel)
                .tabItem { Label("Historial", systemImage: "clock.arrow.circlepath") }
            GeneralTabView(viewModel: viewModel)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding()
        .frame(minWidth: 520, idealWidth: 560, minHeight: 400, idealHeight: 440)
    }
}

// MARK: - Diccionario

private struct DictionaryTabView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.terms.isEmpty {
                emptyState("Sin términos todavía.")
            } else {
                List {
                    ForEach(viewModel.terms, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button(role: .destructive) {
                                viewModel.removeTerm(term)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack {
                TextField("Nuevo término (p. ej. un nombre propio)", text: $newTerm)
                    .onSubmit(addTerm)
                Button("Añadir", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 8)
    }

    private func addTerm() {
        viewModel.addTerm(newTerm)
        newTerm = ""
    }
}

// MARK: - Snippets

private struct SnippetsTabView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var trigger = ""
    @State private var template = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.snippets.isEmpty {
                emptyState("Sin snippets todavía.")
            } else {
                List {
                    ForEach(viewModel.snippets, id: \.trigger) { snippet in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(snippet.trigger).bold()
                                Text(snippet.template)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                viewModel.removeSnippet(trigger: snippet.trigger)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack {
                TextField("Trigger (lo que dictas)", text: $trigger)
                TextField("Plantilla (lo que se inserta)", text: $template)
                Button("Añadir", action: addSnippet)
                    .disabled(
                        trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 8)
    }

    private func addSnippet() {
        viewModel.addSnippet(trigger: trigger, template: template)
        trigger = ""
        template = ""
    }
}

// MARK: - Historial

private struct HistoryTabView: View {
    @ObservedObject var viewModel: SettingsViewModel

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.historyEntries.isEmpty {
                emptyState("Sin dictados registrados todavía.")
            } else {
                List {
                    ForEach(Array(viewModel.historyEntries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.dateFormatter.string(from: entry.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(Self.truncated(entry.finalText))
                                    .help(entry.rawText) // tooltip con el texto crudo completo
                            }
                            Spacer()
                            Button("Copiar") {
                                viewModel.copyToClipboard(entry.finalText)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Button("Borrar historial", role: .destructive) {
                viewModel.clearHistory()
            }
            .disabled(viewModel.historyEntries.isEmpty)
        }
        .padding(.top, 8)
    }

    private static func truncated(_ text: String, limit: Int = 90) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

// MARK: - General

private struct GeneralTabView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Dictado") {
                LabeledContent("Atajo", value: viewModel.hotkeyDescription)
                LabeledContent("Frases de activación", value: viewModel.wakePhrasesDescription)
            }
            Section("Modelos") {
                LabeledContent("Transcripción", value: viewModel.sttModelDescription)
                LabeledContent("Refinado", value: viewModel.refineModelDescription)
            }
            Section("Manos libres") {
                Toggle(
                    "Manos libres: \"escúchame kiki\"",
                    isOn: Binding(
                        get: { viewModel.wakeEnabled },
                        set: { _ in viewModel.requestToggleWake() }
                    ))
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Shared

@ViewBuilder
private func emptyState(_ text: String) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
}
