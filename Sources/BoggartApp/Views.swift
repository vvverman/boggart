import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import BoggartCore

struct StatusLabelView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 4) {
            if model.busy || model.awaitingExpiryConfirmation || model.checkingStatus {
                ProgressView().controlSize(.mini).frame(width: 15, height: 15)
            } else {
                Image(systemName: model.attention ? "exclamationmark.triangle.fill" : "moon")
                    .foregroundStyle(model.attention ? Color.red : model.active ? Color.accentColor : Color.primary)
                    .overlay(alignment: .bottomTrailing) {
                        if model.active && !model.attention {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.accentColor, Color(nsColor: .windowBackgroundColor))
                                .font(.system(size: 8, weight: .bold)).offset(x: 3, y: 2)
                        }
                    }
            }
            if !model.menuText.isEmpty {
                Text(model.menuText).monospacedDigit().font(.system(size: 12))
                    .foregroundStyle(.primary).lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, 5)
        .accessibilityHidden(true)
    }
}

struct ControlPanelView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let dismiss: () -> Void
    let quit: () -> Void
    let hover: (Bool) -> Void
    let editing: (Bool) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var editingDuration: Bool
    private var durationBinding: Binding<Int> { .init(get: { model.selectedHours }, set: { model.selectHours($0) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Боггарт").font(.headline)
                Text(model.needsIntroduction ? "Работа с закрытой крышкой" : model.stateTitle)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if BoggartConstants.hardwareTesting {
                Label("Проверочная сборка. Нужна проверка на этом Mac.", systemImage: "wrench.and.screwdriver")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.attention {
                Text(model.connected ? model.status?.message ?? model.stateTitle : "Связь с помощником потеряна. Проверяю, снято ли удержание.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Повторить восстановление", action: model.stop)
                    .disabled(!model.connected || model.busy)
            } else if model.needsIntroduction {
                introduction
            } else if model.active {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.awaitingExpiryConfirmation ? "Завершаю удержание…" : "Осталось \(DurationText.expanded(model.remaining))")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                    Text(model.endingText).font(.callout).foregroundStyle(.secondary)
                }
                if let seconds = model.powerGraceSeconds {
                    Label(seconds > 0 ? "Питание отключено. Удержание завершится через \(seconds) с." : "Питание отключено. Ожидается снятие удержания.", systemImage: "bolt.slash")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Продлить на час", action: model.extend).disabled(!model.canExtend)
                    Spacer(minLength: 8)
                    Button("Остановить", action: model.stop).disabled(model.busy)
                }
            } else {
                HStack {
                    Text("Длительность")
                    Spacer()
                    TextField("Часы", value: durationBinding, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 48).multilineTextAlignment(.trailing)
                        .focused($editingDuration).disabled(model.busy)
                        .accessibilityLabel("Начальная длительность в часах, от одного до двадцати четырёх")
                        .onSubmit { editingDuration = false }
                    Text("ч").foregroundStyle(.secondary)
                    Stepper("Длительность", value: durationBinding, in: 1...24, step: 1)
                        .labelsHidden().fixedSize().disabled(model.busy)
                        .accessibilityLabel("Изменить начальную длительность")
                }
                Text(model.endingText).font(.callout).foregroundStyle(.secondary)
                if let reason = model.blockedReason {
                    Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button("Не спать", action: model.toggle)
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.blockedReason != nil)
                if let summary = model.lastAbnormalSummary {
                    Label(summary, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.helperState == .notRegistered || model.helperState == .notFound {
                    Button("Подготовить Боггарт…", action: model.configureHelper).disabled(model.busy)
                } else if model.helperState == .requiresApproval {
                    Button("Разрешить работу в macOS…", action: model.openSystemSettings)
                }
            }
            if let error = model.errorMessage, !model.attention {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.needsIntroduction {
                Divider()
                Button {
                    editingDuration = false
                    dismiss()
                    model.sleepDisplaysAfterClosingPanel()
                } label: { Label("Погасить экраны", systemImage: "display") }
                .disabled(!model.canSleepDisplays)
                .help("Гасит дисплеи, но не блокирует Mac. Для блокировки: Control + Command + Q.")
                Label(model.localPower.label, systemImage: model.localPower.external ? "powerplug" : "battery.50percent")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Button("Настройки…", action: openSettings)
            Divider()
            Button("Завершить Боггарт", action: quit).disabled(model.busy)
        }
        .padding(16).frame(width: 350).fixedSize(horizontal: false, vertical: true)
        .background {
            if reduceTransparency || contrast == .increased { Color(nsColor: .windowBackgroundColor) }
            else { Rectangle().fill(.regularMaterial) }
        }
        .onHover(perform: hover)
        .onChange(of: editingDuration, perform: editing)
        .onDisappear { editing(false) }
        .onExitCommand(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Управление Боггартом")
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Оставьте задачу работать, подключите питание и включите удержание. После этого крышку можно закрыть.")
            VStack(alignment: .leading, spacing: 6) {
                Label("Нажатие — включить или остановить.", systemImage: "cursorarrow.click")
                Label("Наведение или правый клик — панель.", systemImage: "menubar.rectangle")
            }.font(.callout)
            Text("«Погасить экраны» не блокирует Mac. Перед уходом используйте Control + Command + Q. Не оставляйте работающий ноутбук в сумке.")
                .font(.caption).foregroundStyle(.secondary)
            if model.setupReady {
                Label("Готов к работе. Удержание выключено.", systemImage: "checkmark.circle")
                Button("Начать пользоваться", action: model.completeIntroduction).buttonStyle(.borderedProminent)
            } else if let blocker = model.setupBlocker {
                Text(blocker).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } else if model.helperState == .requiresApproval {
                Text("Разрешите системный помощник. После настройки удержание само не включится.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Открыть настройки macOS…", action: model.openSystemSettings)
            } else if model.helperState == .enabled {
                Text(model.helperDescription).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Боггарту нужен системный помощник. macOS запросит разрешение один раз при настройке.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Подготовить Боггарт…", action: model.configureHelper)
                    .buttonStyle(.borderedProminent).disabled(model.busy)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var historyExpanded = false
    @State private var diagnosticsExpanded = false
    @State private var selectingUpdate = false
    @State private var copied = false
    var body: some View {
        Form {
            Section {
                Toggle("Показывать оставшееся время", isOn: $model.showRemaining)
                Toggle("Запускать при входе в систему", isOn: .init(get: { model.loginEnabled }, set: model.setLoginEnabled))
                    .disabled(model.busy)
                Text("Автозапуск открывает Боггарт без включения удержания.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.loginApprovalRequired {
                    Button("Разрешить автозапуск в macOS…", action: model.openSystemSettings)
                }
            }
            Section {
                DisclosureGroup("Последние сессии", isExpanded: $historyExpanded) {
                    if model.history.isEmpty {
                        Text("Завершённых сессий пока нет.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.history) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(RecentSessionText.moment(entry.endedAt, now: Date(), calendar: .current))
                                    .font(.callout.weight(.medium))
                                Text(entry.reason.description.capitalized + ".").font(.callout)
                                Text("Начало: \(entry.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                    Text("Последние пять сессий хранятся только на этом Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let warning = model.status?.historyWarning {
                        Text(warning).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("Диагностика", isExpanded: $diagnosticsExpanded) {
                    LabeledContent("Помощник", value: model.helperDescription)
                    LabeledContent("Версия", value: BoggartConstants.version)
                    if let capability = model.status?.capability {
                        Text(capability.message).font(.caption).foregroundStyle(.secondary)
                    } else if let blocker = model.setupBlocker {
                        Text(blocker).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.helperState == .notRegistered || model.helperState == .notFound {
                        Button("Подготовить Боггарт…", action: model.configureHelper).disabled(model.busy)
                    } else {
                        Button("Открыть настройки macOS…", action: model.openSystemSettings)
                    }
                    if model.attention {
                        Text(model.status?.message ?? model.stateTitle).foregroundStyle(.red)
                        Button("Повторить восстановление", action: model.stop).disabled(!model.connected || model.busy)
                    }
                    Button(copied ? "Диагностика скопирована" : "Скопировать диагностику") {
                        model.copyDiagnostics(); copied = true
                    }
                    Text("Без имён, файлов, задач и сетевых настроек. Ничего не отправляется автоматически.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Button("Обновить из файла…") { selectingUpdate = true }.disabled(model.busy)
                    Button("Удалить Боггарт…", role: .destructive, action: model.offerRemoval).disabled(model.busy)
                }
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped).frame(width: 500, height: 510)
        .onAppear(perform: model.refreshSystemSettings)
        .fileImporter(isPresented: $selectingUpdate, allowedContentTypes: [.applicationBundle]) { result in
            model.offerUpdate(result)
        }
        .sheet(item: $model.maintenanceOffer) { offer in
            MaintenanceView(model: model, offer: offer)
        }
    }
}

struct MaintenanceView: View {
    @ObservedObject var model: AppModel
    let offer: MaintenanceOffer
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(offer.title).font(.title3.weight(.semibold))
            Text(offer.explanation).fixedSize(horizontal: false, vertical: true)
            if model.maintenanceBusy {
                HStack { ProgressView().controlSize(.small); Text(model.maintenanceMessage ?? "Подготовка…") }
            } else if let message = model.maintenanceMessage {
                Text(message).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Отмена") { model.maintenanceOffer = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(offer.actionTitle, action: model.runMaintenance)
                    .buttonStyle(.borderedProminent)
            }.disabled(model.maintenanceBusy)
        }
        .padding(24).frame(width: 440)
        .interactiveDismissDisabled(model.maintenanceBusy)
    }
}
