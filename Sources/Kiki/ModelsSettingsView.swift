import SwiftUI
import KikiStore

/// Sección "Modelos" de Ajustes (F3 Task 3): dos listas curadas (STT y
/// refinado) donde cada fila ofrece descargar-y-activar una variante con
/// progreso en vivo. Toda la lógica vive en `SettingsViewModel.activateModel`
/// — esta vista solo pinta `sttRows`/`refineRows` y reenvía taps.
///
/// Spec-note (YAGNI v1, ver también `ModelRowState`): no hay estado
/// "Descargado ✓" para modelos cacheados pero inactivos — detectar el cache
/// local es frágil entre motores (WhisperKit y MLX no exponen un API estable
/// de "¿ya está en disco?"). La fila muestra solo "● Activo", el progreso de
/// una conmutación en vuelo, o el botón "Usar" (que descarga si hace falta;
/// si el modelo ya estaba cacheado la fase de descarga simplemente termina
/// al instante y el progreso salta a la carga).
struct ModelsSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                ForEach(viewModel.sttRows) { row in
                    ModelRow(
                        row: row,
                        switchInFlight: viewModel.isSwitchInFlight(kind: .stt),
                        onActivate: { viewModel.activateModel(row.option, kind: .stt) })
                }
            } header: {
                Text("Transcripción")
            } footer: {
                Text("El modelo que convierte tu voz en texto (dictado por hotkey y manos libres).")
            }

            Section {
                ForEach(viewModel.refineRows) { row in
                    ModelRow(
                        row: row,
                        switchInFlight: viewModel.isSwitchInFlight(kind: .refine),
                        onActivate: { viewModel.activateModel(row.option, kind: .refine) })
                }
            } header: {
                Text("Refinado con IA")
            } footer: {
                footerText
            }
        }
        .formStyle(.grouped)
    }

    /// Footer general de la sección + (si existe) el error de la última
    /// activación fallida. La ventana de Ajustes no tenía ningún patrón de
    /// presentación de errores previo — se estrena aquí el más simple que
    /// cumple: un `Text` en rojo dentro del footer, siempre visible mientras
    /// el error siga vigente (un alert se descartaría y perdería el contexto
    /// de qué fila falló).
    @ViewBuilder private var footerText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Los cambios aplican al instante — no hace falta reiniciar kiki. El modelo recomendado (★) siempre queda como respaldo si otro falla al cargar.")
            if let message = viewModel.modelsErrorMessage {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// Una fila de modelo: nombre + tamaño + descripción, y a la derecha el
/// estado — "● Activo" | progreso de descarga | botón "Usar".
private struct ModelRow: View {
    let row: ModelRowState
    /// `true` si CUALQUIER fila de esta familia tiene una conmutación en
    /// vuelo — deshabilita el "Usar" de las demás (guard de doble activación;
    /// el view model lo re-verifica igualmente, esto es solo affordance).
    let switchInFlight: Bool
    let onActivate: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.option.displayName)
                    Text(row.option.sizeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(row.option.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailingStatus
        }
    }

    @ViewBuilder private var trailingStatus: some View {
        if row.isActive {
            Text("● Activo")
                .font(.callout)
                .foregroundStyle(.tint)
        } else if row.isDownloading {
            ProgressView(value: row.progress)
                .frame(width: 120)
                .help("Descargando y cargando el modelo…")
        } else {
            Button("Usar", action: onActivate)
                .disabled(switchInFlight)
        }
    }
}
