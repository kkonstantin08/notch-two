import Defaults
import SwiftUI

struct CustomAccessoryLevels: View {
    @ObservedObject private var bluetooth = CustomBluetooth.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if bluetooth.accessories.isEmpty {
                Text("No connected Bluetooth audio devices").foregroundStyle(.secondary)
            }
            ForEach(bluetooth.accessories) { device in
                Label(device.name, systemImage: device.icon)
                Text(device.levels).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .onAppear { bluetooth.refresh() }
    }
}

struct CustomPomodoroControls: View {
    @ObservedObject private var features = CustomFeatures.shared
    @Default(.customPomodoroOptions) private var options

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(features.pomodoro.phase.label)
                Spacer()
                if let deadline = features.pomodoro.deadline {
                    CustomDeadlineText(deadline: deadline)
                } else {
                    let seconds = Int(features.pomodoro.remaining ?? options.duration(features.pomodoro.phase))
                    Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit()
                }
            }
            HStack {
                Button(features.pomodoro.deadline == nil ? "Start" : "Pause") { features.togglePomodoro() }
                Button("Reset") { features.resetPomodoro() }
                Button("Skip") { features.skipPomodoro() }
            }
        }
    }
}

struct CustomDeadlineText: View {
    let deadline: Date

    var body: some View {
        let now = Date()
        Text(timerInterval: now...max(now, deadline), countsDown: true,
             showsHours: deadline.timeIntervalSince(now) >= 3600)
            .monospacedDigit()
    }
}

struct CustomActivityPill: View {
    static let wingWidth: CGFloat = 118

    let activity: CustomActivity
    let centerWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Label(activity.title, systemImage: activity.icon)
                .frame(width: Self.wingWidth, alignment: .leading)
            Spacer(minLength: 0).frame(width: centerWidth)
            Group {
                if let deadline = activity.deadline {
                    CustomDeadlineText(deadline: deadline)
                } else {
                    Text(activity.detail).foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.wingWidth, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .allowsTightening(true)
        .minimumScaleFactor(0.75)
        .help([activity.title, activity.detail].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

struct NotchPomodoroButton: View {
    @EnvironmentObject private var vm: BoringViewModel
    @State private var visible = false

    var body: some View {
        Button {
            visible.toggle()
        } label: {
            Image(systemName: "timer").frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pomodoro")
        .popover(isPresented: $visible) {
            CustomPomodoroControls()
                .padding()
                .frame(width: 220)
                .onHover { vm.isHoveringPomodoroControls = $0 }
                .onDisappear { vm.isHoveringPomodoroControls = false }
        }
        .onChange(of: visible) { _, active in
            if !active { vm.isHoveringPomodoroControls = false }
        }
    }
}

struct CustomMonthPicker: View {
    @Binding var selection: Date
    let choose: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @Default(.weekStartDay) private var weekStartDay
    @State private var month = Date()
    @State private var eventDays: Set<Date> = []
    @State private var revision = 0
    private let manager = CalendarManager.shared
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStartDay.firstWeekday
        return calendar
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                stepButton("Previous year", symbol: "chevron.left.2", component: .year, amount: -1)
                stepButton("Previous month", symbol: "chevron.left", component: .month, amount: -1)
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                stepButton("Next month", symbol: "chevron.right", component: .month, amount: 1)
                stepButton("Next year", symbol: "chevron.right.2", component: .year, amount: 1)
            }
            let days = CalendarMonthGeometry.days(containing: month, calendar: calendar)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                ForEach(0..<7) { offset in
                    let weekday = (calendar.firstWeekday - 1 + offset) % 7
                    Text(calendar.veryShortStandaloneWeekdaySymbols[weekday])
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(days.indices, id: \.self) { index in
                    if let day = days[index] {
                        Button {
                            choose(day)
                            dismiss()
                        } label: {
                            Text(day.formatted(.dateTime.day()))
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .overlay(alignment: .bottom) {
                                    if eventDays.contains(day) {
                                        Circle()
                                            .fill(Color.effectiveAccent)
                                            .frame(width: 4, height: 4)
                                            .padding(.bottom, 2)
                                    }
                                }
                                .background(calendar.isDate(day, inSameDayAs: selection) ?
                                            Color.effectiveAccentBackground : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                        .accessibilityHint(eventDays.contains(day) ? "Has calendar items" : "")
                    } else {
                        Color.clear.frame(height: 26)
                    }
                }
            }
            Button("Today") {
                let today = Date()
                month = calendar.dateInterval(of: .month, for: today)?.start ?? today
                choose(today)
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { month = calendar.dateInterval(of: .month, for: selection)?.start ?? selection }
        .onReceive(manager.storeRevision) { _ in revision += 1 }
        .task(id: MonthRequest(month: month, revision: revision)) {
            eventDays = []
            let days = await manager.daysWithEvents(in: month)
            guard !Task.isCancelled else { return }
            eventDays = days
        }
    }

    private struct MonthRequest: Equatable {
        let month: Date
        let revision: Int
    }

    private func stepButton(_ name: LocalizedStringKey, symbol: String, component: Calendar.Component, amount: Int) -> some View {
        Button {
            if let next = calendar.date(byAdding: component, value: amount, to: month) { month = next }
        } label: {
            Image(systemName: symbol)
        }
        .accessibilityLabel(name)
    }
}

struct CustomWellnessControls: View {
    @ObservedObject private var features = CustomFeatures.shared

    var body: some View {
        if let activity = features.wellnessActivity {
            VStack(alignment: .leading, spacing: 8) {
                Label(activity.title, systemImage: activity.icon).font(.headline)
                Text(activity.detail).font(.caption).foregroundStyle(.secondary)
                if let deadline = activity.deadline { CustomDeadlineText(deadline: deadline) }
                HStack {
                    Button("Skip") { features.skipEyeBreak() }
                    Button("Snooze") { features.skipEyeBreak(snooze: true) }
                }
            }
            .padding(10)
        }
    }
}
