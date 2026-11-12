import Defaults
import SwiftUI

struct CustomFeaturesSettingsView: View {
    @Default(.customWellnessOptions) private var wellness
    @Default(.customFeatures) private var features
    @Default(.customCalendarOptions) private var calendar
    @Default(.customPomodoroOptions) private var pomodoro
    @Default(.customNoticeSeconds) private var seconds
    @Default(.customBluetoothSeconds) private var bluetoothSeconds

    var body: some View {
        Form {
            Section("Calendar") {
                feature(.eventAlerts, "Upcoming event alerts")
                if enabled(.eventAlerts) {
                    Toggle("Use alarms from the event", isOn: $calendar.useEventAlarms)
                    if !calendar.useEventAlarms {
                        Picker("Warn before start", selection: $calendar.leadMinutes) {
                            ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                        }
                    }
                }
                feature(.eventCountdown, "Active event countdown")
                if enabled(.eventCountdown) {
                    Toggle("Show event title", isOn: $calendar.showTitle)
                    Toggle("Show remaining time", isOn: $calendar.showCountdown)
                    Picker("Warn before end", selection: $calendar.endWarningMinutes) {
                        Text("Off").tag(0)
                        ForEach([2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                    }
                }
                if enabled(.eventAlerts) || enabled(.eventCountdown) {
                    Toggle("Play alert sound", isOn: $calendar.sound)
                    CustomCalendarSelection(calendarIDs: $calendar.calendarIDs)
                }
                feature(.calendar, "Month and year navigation")
            }

            Section("Audio") {
                feature(.bluetooth, "Bluetooth audio connection alerts")
                if enabled(.bluetooth) {
                    Stepper("Bluetooth alert duration · \(bluetoothSeconds) s", value: $bluetoothSeconds, in: 1...15)
                }
                feature(.outputName, "Show output device name in volume controls")
                feature(.accessoryBattery, "Headphone and case battery")
                if enabled(.accessoryBattery) { CustomAccessoryLevels() }
            }

            Section("Wellness") {
                feature(.wellness, "20-20-20 eye breaks")
                if enabled(.wellness) {
                    DurationField("Reminder interval", value: $wellness.intervalMinutes)
                    DurationField("Break duration", value: $wellness.breakSeconds, unit: .seconds, range: 5...300, step: 5)
                    DurationField("Snooze", value: $wellness.snoozeMinutes, range: 1...60)
                    Toggle("Play break sound", isOn: $wellness.sound)
                    Toggle("Pause music during breaks", isOn: $wellness.pauseMusic)
                    CustomWellnessControls()
                }
            }

            Section("Pomodoro") {
                feature(.pomodoro, "Pomodoro")
                if enabled(.pomodoro) {
                    DurationField("Focus", value: $pomodoro.focus)
                    DurationField("Short break", value: $pomodoro.shortBreak)
                    DurationField("Long break", value: $pomodoro.longBreak)
                    Toggle("Show countdown in closed Notch", isOn: $pomodoro.countdown)
                    Toggle("Notify when a phase ends", isOn: $pomodoro.notice)
                    CustomPomodoroControls()
                }
            }

            Section("System") {
                feature(.capsLock, "Caps Lock indicator")
                feature(.wifi, "Wi-Fi connection alerts")
                if enabled(.capsLock) {
                    Text("Caps Lock detection in other apps uses macOS Accessibility access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper("Alert duration · \(seconds) s", value: $seconds, in: 1...15)
            }
        }
        .navigationTitle("Custom Features")
    }

    private func enabled(_ feature: CustomFeature) -> Bool { features.contains(feature.rawValue) }

    private func feature(_ feature: CustomFeature, _ label: LocalizedStringKey) -> some View {
        Toggle(label, isOn: Binding(get: { enabled(feature) }, set: { on in
            if on { features.insert(feature.rawValue) } else { features.remove(feature.rawValue) }
        }))
    }
}

private struct DurationField: View {
    private let title: LocalizedStringKey
    private let unit: UnitDuration
    private let range: ClosedRange<Int>
    private let step: Int
    @Binding private var value: Int
    @State private var draft: String
    @FocusState private var editing: Bool

    init(_ title: LocalizedStringKey, value: Binding<Int>, unit: UnitDuration = .minutes,
         range: ClosedRange<Int> = 1...180, step: Int = 1) {
        self.title = title
        self.unit = unit
        self.range = range
        self.step = step
        _value = value
        _draft = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, text: $draft)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 52)
                    .focused($editing)
                    .onSubmit { editing = false }
                    .onExitCommand {
                        draft = String(value)
                        editing = false
                    }
                    .accessibilityHint(Text("Enter a whole number from \(range.lowerBound) to \(range.upperBound) \(unit.symbol)"))
                Text(unit.symbol)
                    .foregroundStyle(.secondary)
                Stepper(value: Binding(get: { validDraft ?? value }, set: { update($0) }), in: range, step: step) {
                    Text(title)
                }
                .labelsHidden()
            }
        }
        .onChange(of: editing) { _, focused in
            if !focused { update(validDraft ?? value) }
        }
        .onChange(of: value) { _, value in
            if !editing { draft = String(value) }
        }
    }

    private var validDraft: Int? {
        guard let value = Int(draft.trimmingCharacters(in: .whitespaces)), range.contains(value) else { return nil }
        return value
    }

    private func update(_ newValue: Int) {
        if value != newValue { value = newValue }
        draft = String(newValue)
    }
}

private struct CustomCalendarSelection: View {
    @ObservedObject private var manager = CalendarManager.shared
    @Binding var calendarIDs: Set<String>?

    var body: some View {
        if manager.eventCalendars.isEmpty {
            Button("Check Calendar access") {
                Task { await manager.checkCalendarAuthorization() }
            }
        } else {
            Toggle("Use all event calendars", isOn: Binding(
                get: { calendarIDs == nil },
                set: { calendarIDs = $0 ? nil : Set(manager.eventCalendars.map(\.id)) }
            ))
            if calendarIDs != nil {
                ForEach(manager.eventCalendars, id: \.id) { calendar in
                    Toggle(calendar.title, isOn: Binding(
                        get: { calendarIDs?.contains(calendar.id) == true },
                        set: { selected in
                            if selected { calendarIDs?.insert(calendar.id) } else { calendarIDs?.remove(calendar.id) }
                        }
                    ))
                }
            }
        }
    }
}
