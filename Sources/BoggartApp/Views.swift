import SwiftUI
import ServiceManagement
import BoggartCore
import BoggartPlatform

struct StatusLabelView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 5) {
            if model.busy || model.awaitingExpiryConfirmation || model.checkingStatus {
                ProgressView().controlSize(.mini).frame(width: 18, height: 18)
            } else if model.attention {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if model.active {
                NoSleepSymbol().foregroundStyle(Color.accentColor).frame(width: 19, height: 19)
            } else {
                SkatingSpider(monochrome: true).frame(width: 22, height: 22)
            }
            if !model.menuText.isEmpty {
                Text(model.menuText).font(.system(size: 12)).monospacedDigit().lineLimit(1).fixedSize()
            }
        }.padding(.horizontal, 5).accessibilityHidden(true)
    }
}

/// Сотые отображаются только в открытом интерфейсе, не создавая частый XPC.
struct RemainingTimeView: View {
    @ObservedObject var model: AppModel
    var large = true
    @State private var visible = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible || !model.active || !model.preciseClockVisible)) { _ in
            Text(DurationText.precise(model.status?.session?.remaining(at: MacClock.continuous)))
                .font(.system(size: large ? 26 : 23, weight: .medium))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Оставшееся время")
        .accessibilityValue(DurationText.expanded(model.remaining))
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}

struct ControlPanelView: View {
    static let width: CGFloat = 356
    @ObservedObject var model: AppModel
    @ObservedObject private var lockControl = IdleLockController.shared
    let openSettings: () -> Void
    let openSetup: () -> Void
    let dismiss: () -> Void
    let quit: () -> Void
    let hover: (Bool) -> Void
    let editing: (Bool) -> Void
    @FocusState private var editingDuration: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var duration: Binding<Int> { .init(get: { model.selectedHours }, set: model.selectHours) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Боггарт").font(.headline)
                Spacer()
                if model.busy || model.checkingStatus || model.awaitingExpiryConfirmation {
                    ProgressView().controlSize(.small).accessibilityLabel(model.stateTitle)
                } else if model.attention {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityLabel(model.stateTitle)
                } else if model.active {
                    NoSleepSymbol().foregroundStyle(Color.accentColor).frame(width: 19, height: 19)
                } else {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityLabel("Удержание выключено")
                }
            }
            if model.attention {
                Text(model.connected ? model.status?.message ?? model.stateTitle : "Нет связи с помощником. Снятие удержания пока не подтверждено.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Повторить восстановление", action: model.stop).disabled(!model.connected || model.busy)
            } else if model.needsIntroduction || model.helperState != .enabled {
                Text("Завершите настройку в открывшемся окне.").font(.callout).foregroundStyle(.secondary)
                Button("Открыть настройку…", action: openSetup)
            } else {
                if model.active {
                    HStack(spacing: 8) {
                        RemainingTimeView(model: model)
                        Spacer(minLength: 0)
                        Button("+1 ч", action: model.extend).disabled(!model.canExtend)
                            .accessibilityLabel("Продлить на час")
                        Button("Стоп", action: model.stop).disabled(model.busy).accessibilityLabel("Остановить удержание")
                    }
                } else {
                    HStack(spacing: 7) {
                        Text("Длительность").font(.callout)
                        TextField("Часы", value: duration, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 38).multilineTextAlignment(.trailing)
                            .focused($editingDuration).disabled(model.busy)
                            .accessibilityLabel("Часы, от 1 до 24").onSubmit { editingDuration = false }
                        Text("ч").foregroundStyle(.secondary)
                        Stepper("Часы", value: duration, in: 1...24).labelsHidden().fixedSize().disabled(model.busy)
                        Spacer(minLength: 0)
                        Button("Не спать", action: model.toggle).buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.blockedReason != nil)
                    }
                }
                Text(model.endingText).font(.caption).foregroundStyle(.secondary)
                if let seconds = model.powerGraceSeconds {
                    Text("Нет питания. Остановка через \(seconds) с.").font(.callout).foregroundStyle(.secondary)
                } else if !model.active, let reason = model.blockedReason {
                    Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Не блокировать экран", isOn: .init(get: { lockControl.requested }, set: lockControl.setRequested))
                    .toggleStyle(.switch).controlSize(.small).disabled(model.busy || model.attention)
                    .help("Только во время сессии с включённым экраном. Пароль и ручная блокировка не меняются.")
                if lockControl.requested {
                    Text("Экран останется включённым. Ручная блокировка ⌃⌘Q работает.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    editingDuration = false; lockControl.cancel(); dismiss(); model.sleepDisplaysAfterClosingPanel()
                } label: { Label("Погасить экраны", systemImage: "display") }
                    .buttonStyle(.borderless).disabled(!model.canSleepDisplays)
                    .help("Выключает опцию «Не блокировать экран» и гасит дисплеи. Сессия продолжается.")
            }
            if let error = model.errorMessage, !model.attention {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = lockControl.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Настройки…", action: openSettings).buttonStyle(.borderless)
                Spacer()
                Menu {
                    Button("Удалить…", action: model.offerRemoval)
                    Button("Выйти", action: quit).keyboardShortcut("q").disabled(model.busy)
                } label: { Image(systemName: "ellipsis").frame(width: 18) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Другие действия")
            }.controlSize(.small)
        }
        .padding(16).frame(width: Self.width).fixedSize(horizontal: false, vertical: true)
        .background {
            if reduceTransparency || contrast == .increased { Color(nsColor: .windowBackgroundColor) }
        }
        .onHover(perform: hover).onChange(of: editingDuration, perform: editing)
        .onDisappear { editing(false) }.onExitCommand(perform: dismiss)
        .accessibilityElement(children: .contain).accessibilityLabel("Управление Боггартом")
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.active {
                HStack { NoSleepSymbol().frame(width: 21, height: 21).foregroundStyle(Color.accentColor); RemainingTimeView(model: model, large: false) }
                Text(model.endingText).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Показывать оставшееся время", isOn: $model.showRemaining)
            Toggle("Запускать при входе в систему", isOn: .init(get: { model.loginEnabled }, set: model.setLoginEnabled)).disabled(model.busy)
            if model.loginApprovalRequired { Button("Разрешить автозапуск…", action: model.openSystemSettings) }
            if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
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
            BoggartAppIcon().frame(width: 100, height: 100)
            Text(model.setupReady ? "Боггарт готов" : "Настройка Боггарта").font(.title2.weight(.semibold))
            if model.setupReady {
                Text("Нажатие включает или останавливает удержание. Наведение открывает управление.")
                Text("Для работы с закрытой крышкой подключите зарядку. Заблокировать Mac: ⌃⌘Q.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Готово", action: done).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else if let blocker = model.setupBlocker {
                Text(blocker).foregroundStyle(.secondary).textSelection(.enabled)
            } else if model.helperState == .requiresApproval {
                Image(systemName: "lock.shield").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Разрешите Боггарту работу в фоне в настройках macOS. Это нужно для работы с закрытой крышкой.")
                Button("Открыть настройки macOS…", action: model.openSystemSettings)
            } else if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Button("Повторить", action: model.configureHelper)
            } else {
                ProgressView().controlSize(.small)
                Text("Подключаем системный помощник…").foregroundStyle(.secondary)
            }
        }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(32).frame(width: 420).onAppear { model.beginInitialSetupOnce() }
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
            } else if let message = model.maintenanceMessage { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Отмена") { model.maintenanceOffer = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(offer.actionTitle, action: model.runMaintenance).buttonStyle(.borderedProminent)
            }.disabled(model.maintenanceBusy)
        }.padding(24).frame(width: 440).interactiveDismissDisabled(model.maintenanceBusy)
    }
}
