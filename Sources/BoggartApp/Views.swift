import SwiftUI
import ServiceManagement
import BoggartCore
import BoggartPlatform

struct StatusLabelView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 5) {
            if model.busy || model.awaitingExpiryConfirmation || model.checkingStatus {
                ProgressView().controlSize(.mini).frame(width: 17, height: 17)
            } else if model.attention {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if model.active {
                Image(systemName: "moon.fill")
                    .overlay {
                        Rectangle().frame(width: 1.7, height: 21).rotationEffect(.degrees(-45))
                    }
                    .foregroundStyle(Color.accentColor).frame(width: 18, height: 18)
            } else {
                SkatingSpider(monochrome: true).frame(width: 22, height: 22)
            }
            if !model.menuText.isEmpty {
                Text(model.menuText).font(.system(size: 12)).monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
        }.padding(.horizontal, 5).accessibilityHidden(true)
    }
}

/// Быстрый отсчёт существует только в видимом SwiftUI-представлении.
/// Он читает монотонный дедлайн, не посылает XPC и не обновляет модель/строку меню.
struct RemainingTimeView: View {
    @ObservedObject var model: AppModel
    var large = true
    @State private var visible = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible || !model.active || !model.preciseClockVisible)) { _ in
            let seconds = model.status?.session?.remaining(at: MacClock.continuous)
            VStack(alignment: .leading, spacing: 4) {
                Text("Осталось").font(.subheadline).foregroundStyle(.secondary)
                Text(DurationText.precise(seconds))
                    .font(.system(size: large ? 30 : 25, weight: .medium, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                    .accessibilityHidden(true)
                Text(model.endingText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Оставшееся время")
        .accessibilityValue(DurationText.expanded(model.remaining))
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}

struct ControlPanelView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let openSetup: () -> Void
    let dismiss: () -> Void
    let quit: () -> Void
    let hover: (Bool) -> Void
    let editing: (Bool) -> Void
    @FocusState private var editingDuration: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var durationBinding: Binding<Int> { .init(get: { model.selectedHours }, set: { model.selectHours($0) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Боггарт").font(.headline)
                Spacer()
                Text(model.active ? "Не спит" : model.attention ? "Ошибка" : "Выключен")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.attention {
                Text(model.connected ? model.status?.message ?? model.stateTitle : "Нет связи с помощником. Снятие удержания пока не подтверждено.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Повторить восстановление", action: model.stop).disabled(!model.connected || model.busy)
            } else if model.needsIntroduction || model.helperState != .enabled {
                Text("Завершите настройку, чтобы оставить Mac работать с закрытой крышкой.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Продолжить настройку…", action: openSetup).buttonStyle(.borderedProminent)
            } else if model.active {
                RemainingTimeView(model: model)
                if let seconds = model.powerGraceSeconds {
                    Text("Питание отключено. Остановка через \(seconds) с.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button("Продлить на час", action: model.extend).disabled(!model.canExtend)
                    Spacer(minLength: 0)
                    Button("Остановить", action: model.stop).disabled(model.busy)
                }
                Button {
                    editingDuration = false; dismiss(); model.sleepDisplaysAfterClosingPanel()
                } label: { Label("Погасить экраны", systemImage: "display") }
                    .disabled(!model.canSleepDisplays)
                    .help("Гасит дисплеи без блокировки. Заблокировать Mac: Control + Command + Q.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Не спать")
                        Spacer()
                        TextField("Часы", value: durationBinding, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.trailing)
                            .focused($editingDuration).disabled(model.busy)
                            .accessibilityLabel("Часы, от 1 до 24")
                            .onSubmit { editingDuration = false }
                        Text("ч").foregroundStyle(.secondary)
                        Stepper("Часы", value: durationBinding, in: 1...24)
                            .labelsHidden().fixedSize().disabled(model.busy)
                    }
                    Text(model.endingText).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = model.blockedReason {
                    Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button("Не спать", action: model.toggle).buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.blockedReason != nil)
                if let summary = model.lastAbnormalSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.errorMessage, !model.attention {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Настройки…", action: openSettings)
                Spacer()
                Button("Выйти", action: quit).disabled(model.busy)
            }.controlSize(.small)
        }
        .padding(18).frame(width: 320).fixedSize(horizontal: false, vertical: true)
        .background {
            if reduceTransparency || contrast == .increased { Color(nsColor: .windowBackgroundColor) }
        }
        .onHover(perform: hover)
        .onChange(of: editingDuration, perform: editing)
        .onDisappear { editing(false) }
        .onExitCommand(perform: dismiss)
        .accessibilityElement(children: .contain).accessibilityLabel("Управление Боггартом")
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.active { RemainingTimeView(model: model, large: false) }
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Показывать оставшееся время", isOn: $model.showRemaining)
                Toggle("Запускать при входе в систему", isOn: .init(get: { model.loginEnabled }, set: model.setLoginEnabled))
                    .disabled(model.busy)
                if model.loginApprovalRequired {
                    Button("Разрешить автозапуск…", action: model.openSystemSettings)
                }
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            Text("Версия \(BoggartConstants.version)").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 380).fixedSize(horizontal: false, vertical: true)
            .onAppear(perform: model.refreshSystemSettings)
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    let done: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            BoggartAppIcon().frame(width: 110, height: 110)
            VStack(spacing: 8) {
                Text(model.setupReady ? "Боггарт готов" : "Настройка Боггарта")
                    .font(.title2.weight(.semibold))
                Text("Mac работает. Экраны отдыхают.")
                    .font(.body).foregroundStyle(.secondary)
            }
            if model.setupReady {
                Text("Нажатие на значок включает или останавливает удержание. Наведение открывает управление.")
                Text("Подключите зарядку. Перед закрытием крышки заблокируйте Mac: ⌃⌘Q.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Готово", action: done).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else if let blocker = model.setupBlocker {
                Text(blocker).foregroundStyle(.secondary).textSelection(.enabled)
            } else if model.helperState == .requiresApproval {
                Image(systemName: "lock.shield").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Разрешите Боггарту работать в фоне в открывшихся настройках macOS. Это нужно для работы с закрытой крышкой.")
                Button("Открыть настройки macOS…", action: model.openSystemSettings)
            } else if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Button("Повторить", action: model.configureHelper)
            } else {
                ProgressView().controlSize(.small)
                Text("Подключаем системный помощник…").foregroundStyle(.secondary)
            }
            if BoggartConstants.hardwareTesting {
                Text("Предварительная версия. Сначала проверьте работу с закрытой крышкой на этом Mac. Не оставляйте работающий ноутбук в сумке.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .padding(32).frame(width: 440)
        .onAppear { model.beginInitialSetupOnce() }
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
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Отмена") { model.maintenanceOffer = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(offer.actionTitle, action: model.runMaintenance).buttonStyle(.borderedProminent)
            }.disabled(model.maintenanceBusy)
        }.padding(24).frame(width: 440)
            .interactiveDismissDisabled(model.maintenanceBusy)
    }
}
