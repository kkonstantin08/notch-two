//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @Default(.enableSneakPeek) private var musicPeekEnabled
    @Default(.alwaysShowSneakPeek) private var alwaysMusicPeek
    @Default(.sneakPeekStyles) private var musicPeekStyle
    @Default(.sneakPeekAlignment) private var musicPeekAlignment
    @Default(.boringShelf) private var shelfEnabled
    @ObservedObject var notificationManager = SystemNotificationManager.shared
    @ObservedObject private var custom = CustomFeatures.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedActivityID: String?
    @State private var swipedNoticeID: String?
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero
    @State private var horizontalMediaGestureTriggered = false
    @State private var horizontalMediaGestureFeedback: CGFloat = .zero
    @State private var isHoveringMusicArea = false

    @State private var verticalGestureTriggered = false
    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.showNotHumanFace) var showNotHumanFace

    // Use standardized animations from StandardAnimations enum
    private let animationSpring = StandardAnimations.interactive

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10
    private let nowPlayingFallbackNoticeWidth: CGFloat = 330
    /// Matches the popovers' dismiss delay; long enough to reach a control
    /// inside the panel without closing under the pointer.
    private let hoverExitDelayMilliseconds = 350

    // MARK: - Corner Radius Scaling
    private var cornerRadiusScaleFactor: CGFloat? {
        guard Defaults[.cornerRadiusScaling] else { return nil }
        let effectiveHeight = displayClosedNotchHeight
        guard effectiveHeight > 0 else { return nil }
        return effectiveHeight / 38.0
    }

    /// Compact mode gets a rounder opened shape (35 vs 19) — at its smaller
    /// size the standard radius reads square rather than pill-like.
    private var openedInsets: (top: CGFloat, bottom: CGFloat) {
        Defaults[.compactMode] ? compactCornerRadiusInsets.opened : cornerRadiusInsets.opened
    }

    private var topCornerRadius: CGFloat {
        // If the notch is open, return the opened radius.
        if vm.notchState == .open {
            return openedInsets.top
        }

        // For the closed notch, scale if enabled
        let baseClosedTop = cornerRadiusInsets.closed.top
        guard let scaleFactor = cornerRadiusScaleFactor else {
            return displayClosedNotchHeight > 0 ? baseClosedTop : 0
        }
        return max(0, baseClosedTop * scaleFactor)
    }

    private var currentNotchShape: NotchShape {
        // Scale bottom corner radius for closed notch shape when scaling is enabled.
        let baseClosedBottom = cornerRadiusInsets.closed.bottom
        let bottomCorner: CGFloat

        if vm.notchState == .open {
            bottomCorner = openedInsets.bottom
        } else if let scaleFactor = cornerRadiusScaleFactor {
            bottomCorner = max(0, baseClosedBottom * scaleFactor)
        } else {
            bottomCorner = displayClosedNotchHeight > 0 ? baseClosedBottom : 0
        }

        return NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCorner
        )
    }

    /// Closed-notch activities, newest first. A notification sits in front of
    /// music, so an incoming message takes over the display; when it expires
    /// it drops out of this list on its own and music comes back — no
    /// explicit "restore previous activity" bookkeeping needed.
    private var liveActivities: [LiveActivityItem] {
        var items: [LiveActivityItem] = []

        if let notification = notificationManager.activeNotification {
            items.append(.notification(notification))
        }

        if let wellness = custom.wellnessActivity { items.append(.custom(wellness)) }
        if let notice = custom.notice {
            items.append(.custom(.init(id: notice.id, title: notice.title, detail: notice.detail, icon: notice.icon)))
        }
        if custom.capsLock {
            items.append(.custom(.init(id: "capsLock", title: "Caps Lock", detail: "On", icon: "capslock.fill")))
        }
        if let event = custom.eventActivity { items.append(.custom(event)) }
        if let timer = custom.pomodoroActivity { items.append(.custom(timer)) }

        let musicIsShowing = (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled
        // The inline song-change peek is drawn inside the music pill, so it
        // has to bring the pill with it even when the persistent live
        // activity is turned off — otherwise the peek never appears.
        if musicIsShowing || visibleMusicPeekStyle != nil {
            items.append(.music)
        }

        return items
    }

    /// Compact mode must use nil: this frame bounds hit-testing as well as
    /// layout, so any value shorter than the content leaves the transport
    /// row outside the hover region — moving toward the buttons registered
    /// as a hover-exit and closed the notch. The compact panel's height is
    /// controlled by its own internal padding instead, which is the honest
    /// lever anyway.
    private var openNotchHeight: CGFloat? {
        if notificationManager.activeNotification != nil { return nil }
        return Defaults[.compactMode] ? nil : vm.notchSize.height
    }

    /// Compact mode drops the tab bar along with the tabs it switches
    /// between — there's only the player to show, so a switcher would have
    /// nothing to switch to. Also what keeps the panel narrow, since the
    /// header spans the full notch width.
    private var showsHeader: Bool {
        vm.notchState == .open
            && notificationManager.activeNotification == nil
            && !Defaults[.compactMode]
    }

    /// The activity currently on top of the stack — what the chin has to be
    /// sized for.
    private var selectedActivity: LiveActivityItem? {
        let items = liveActivities
        guard !items.isEmpty else { return nil }
        return items[activityIndex(in: items)]
    }

    private var transientActivityID: String? {
        notificationManager.activeNotification.map { LiveActivityItem.notification($0).id } ?? custom.notice?.id
    }

    private func activityIndex(in items: [LiveActivityItem]) -> Int {
        if let transientActivityID, transientActivityID != swipedNoticeID { return 0 }
        return items.firstIndex(where: { $0.id == selectedActivityID }) ?? 0
    }

    private var activityIndexBinding: Binding<Int> {
        Binding(get: { activityIndex(in: liveActivities) }, set: { index in
            let items = liveActivities
            guard items.indices.contains(index) else { return }
            if items[index].id == transientActivityID {
                swipedNoticeID = nil
            } else {
                swipedNoticeID = transientActivityID
                selectedActivityID = items[index].id
            }
        })
    }

    private enum ClosedNotchContent: Equatable {
        case hello
        case nowPlayingFallback
        case batteryStatus
        case osd(SneakContentType)
        case activities([LiveActivityItem])
        case face
        case idle
    }

    private var closedNotchContent: ClosedNotchContent {
        if coordinator.helloAnimationRunning { return .hello }
        if nowPlayingFallbackNoticeActive { return .nowPlayingFallback }
        if coordinator.expandingView.show,
           coordinator.expandingView.type == .battery,
           Defaults[.showPowerStatusNotifications] {
            return .batteryStatus
        }
        if coordinator.shouldShowSneakPeek(on: vm.screenUUID) {
            return .osd(coordinator.sneakPeekState(for: vm.screenUUID).type)
        }
        if !liveActivities.isEmpty, !vm.hideOnClosed {
            return .activities(liveActivities)
        }
        if !coordinator.expandingView.show,
           !musicManager.isPlaying,
           musicManager.isPlayerIdle,
           Defaults[.showNotHumanFace],
           !vm.hideOnClosed {
            return .face
        }
        return .idle
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if shouldDisplayNowPlayingFallbackNotice {
            chinWidth = nowPlayingFallbackNoticeWidth
        } else if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications] {
            chinWidth = 640
        } else if vm.notchState == .closed, !vm.hideOnClosed, let activity = selectedActivity {
            // Sized for whichever activity is actually on top, not for
            // whichever happens to exist — otherwise swiping to music while a
            // notification is still in the stack leaves the chin at the
            // notification's width.
            switch activity {
            case .notification:
                chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
            case .custom:
                chinWidth += 2 * CustomActivityPill.wingWidth + 16
            case .music:
                chinWidth += (2 * max(0, displayClosedNotchHeight - 12) + 20 + 2 * liveActivityEdgeMargin + 2)
                // The inline song-change peek widens the pill itself, so the
                // chin has to grow with it — otherwise the hover region is
                // narrower than what's on screen.
                if visibleMusicPeekStyle == .inline {
                    chinWidth += 2 * inlineMusicPeekLabelWidth
                }
            }
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed {
            chinWidth += (2 * max(0, displayClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    private var shouldDisplayNowPlayingFallbackNotice: Bool {
        vm.notchState == .closed && nowPlayingFallbackNoticeActive
    }

    private var nowPlayingFallbackNoticeActive: Bool {
        guard musicManager.nowPlayingNotice != nil else { return false }

        let selectedScreen = NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
        let targetScreenUUID = selectedScreen?.displayUUID ?? NSScreen.main?.displayUUID
        let currentScreen = vm.screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let isConnected = vm.screenUUID == nil || currentScreen != nil
        let isTargetDisplay = vm.screenUUID == nil || vm.screenUUID == targetScreenUUID

        return isConnected
            && isTargetDisplay
            && !isNotchHeightZero
    }

    // If the closed notch height is 0 (any display/setting), display a 10pt nearly-invisible notch
    // instead of fully hiding it. This preserves layout while avoiding visual artifacts.
    private var isNotchHeightZero: Bool { vm.effectiveClosedNotchHeight == 0 }

    private var displayClosedNotchHeight: CGFloat { isNotchHeightZero ? 10 : vm.effectiveClosedNotchHeight }

    var body: some View {
        @Bindable var dropInteraction = vm.dropInteraction

        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open ? openedInsets.top : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                          .overlay(alignment: .top) {
                              displayClosedNotchHeight.isZero && vm.notchState == .closed ? nil
                        : Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: 6
                    )
                    // Removed conditional bottom padding when using custom 0 notch to keep layout stable
                    .opacity((isNotchHeightZero && vm.notchState == .closed) ? 0.01 : 1)

                mainLayout
                    // alignment: .top matters here — without it this frame
                    // defaults to centering, and shrinking the height for a
                    // notification (openNotchHeight < vm.notchSize.height)
                    // then pulls the visible top edge down by half the
                    // difference instead of staying flush with the window's
                    // top-anchored origin. That's what read as "the notch
                    // sits a bit off the top of the screen."
                    .frame(height: vm.notchState == .open ? openNotchHeight : nil, alignment: .top)
                    .conditionalModifier(true) { view in
                        return view
                            .animation(vm.notchState == .open ? StandardAnimations.open : StandardAnimations.close, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                            // Outermost on purpose: it only fires when the
                            // closed-state content changes (the key is stable
                            // across open/close), and when several keys change
                            // at once the innermost animation wins, so the
                            // open/close springs below keep precedence.
                            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: closedNotchContent)
                    }
                    .contentShape(Rectangle())
                    .conditionalModifier(shelfEnabled) { view in
                        view.shelfDropTarget(isTargeted: $dropInteraction.notchTargeting) { providers in
                            guard !providers.isEmpty, !coordinator.firstLaunch, !ShelfSelectionModel.shared.isDragging else { return false }
                            dropInteraction.dropEvent = true
                            ShelfStateViewModel.shared.load(providers)
                            return true
                        }
                    }
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .gesture(
                        TapGesture().onEnded { doOpen() },
                        including: vm.notchState == .closed && !shouldDisplayNowPlayingFallbackNotice ? .all : .subviews
                    )
                    .conditionalModifier(Defaults[.enableGestures] && !shouldDisplayNowPlayingFallbackNotice) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures] && !shouldDisplayNowPlayingFallbackNotice) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.enableHorizontalMediaGestures] && Defaults[.enableGestures] && !shouldDisplayNowPlayingFallbackNotice) { view in
                        view
                            .panGesture(direction: .left) { translation, phase in
                                handleNextTrackGesture(translation: translation, phase: phase)
                            }
                            .panGesture(direction: .right) { translation, phase in
                                handlePreviousTrackGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        scheduleCloseIfNotHovering(overNotch: vm)
                    }
                    .onReceive(notificationManager.$activeNotification) { next in
                        // @Published emits before clearing the card, so close without rendering Home first.
                        if next == nil {
                            vm.isComposingNotificationReply = false
                            withAnimation(animationSpring) { vm.closeNotificationPresentation() }
                        }
                    }
                    .onChange(of: notificationManager.activeNotification?.id) { _, newID in
                        if newID != nil {
                            if isHovering { notificationManager.holdActive() }
                            guard Defaults[.notificationAutoExpand], vm.notchState == .closed,
                                  !(vm.screenUUID.flatMap { vm.detector.fullscreenStatus[$0] } ?? false),
                                  !vm.hideOnClosed, !isHovering else { return }
                            withAnimation(animationSpring) { _ = vm.open(forNotification: true) }
                        }
                    }
                    .onChange(of: vm.notchState) { _, state in
                        if state == .closed { notificationManager.resumeDismiss() }
                    }
                    .onChange(of: transientActivityID) { _, _ in swipedNoticeID = nil }
                    .onChange(of: vm.popoverKeepsNotchOpen) { _, _ in
                        scheduleCloseIfNotHovering(overNotch: vm)
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .ignoresSafeArea(.all)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: dropInteraction.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if dropInteraction.notchTargeting {
                    withAnimation(animationSpring) { vm.openShelfForDrag() }
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if dropInteraction.dropEvent {
                    dropInteraction.dropEvent = false
                    return
                }

                dropInteraction.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if shouldDisplayNowPlayingFallbackNotice,
                       let notice = musicManager.nowPlayingNotice {
                        nowPlayingFallbackNotice(notice)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    } else if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications] {
                        PowerStatusNotice(notchWidth: vm.closedNotchSize.width, height: displayClosedNotchHeight)
                        } else if coordinator.shouldShowSneakPeek(on: vm.screenUUID) && Defaults[.inlineOSD] && (coordinator.sneakPeekState(for: vm.screenUUID).type != .music) && (coordinator.sneakPeekState(for: vm.screenUUID).type != .battery) && vm.notchState == .closed {
                           InlineOSD(
                              type: coordinator.binding(for: vm.screenUUID).type,
                              value: coordinator.binding(for: vm.screenUUID).value,
                              icon: coordinator.binding(for: vm.screenUUID).icon,
                              accent: coordinator.binding(for: vm.screenUUID).accent,
                              hoverAnimation: $isHovering,
                              gestureProgress: $gestureProgress
                          )
                              .transition(.opacity)
                      } else if !liveActivities.isEmpty && vm.notchState == .closed && !vm.hideOnClosed {
                          LiveActivityStack(items: liveActivities, index: activityIndexBinding) { item in
                              switch item {
                              case .notification(let notification):
                                  NotificationLiveActivity(notification: notification)
                              case .custom(let activity):
                                  CustomActivityPill(activity: activity, centerWidth: vm.closedNotchSize.width,
                                                     height: displayClosedNotchHeight)
                              case .music:
                                  MusicLiveActivity()
                                      .frame(alignment: .center)
                              }
                          }
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed {
                          BoringFaceAnimation()
                       } else if showsHeader {
                           // No tab bar over a notification: it's a glance,
                           // not a place to switch between home and shelf —
                           // and the header spans the full notch width,
                           // which is what was stretching the whole panel
                           // out around a short message.
                           BoringHeader()
                               .frame(height: max(38, displayClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       }
                        // New case to enable compact notch on external displays
                        else if !vm.hasNotch {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: 11) // idle notch height is halved on non notch display
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: displayClosedNotchHeight)
                       }

                        if coordinator.shouldShowSneakPeek(on: vm.screenUUID) {
                           if (coordinator.sneakPeekState(for: vm.screenUUID).type != .music) && (coordinator.sneakPeekState(for: vm.screenUUID).type != .battery) && !Defaults[.inlineOSD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: coordinator.binding(for: vm.screenUUID).type,
                                  value: coordinator.binding(for: vm.screenUUID).value,
                                  icon: coordinator.binding(for: vm.screenUUID).icon,
                                  accent: coordinator.binding(for: vm.screenUUID).accent,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeekState(for: vm.screenUUID).type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                       }
                        }
                      }
                      .conditionalModifier(coordinator.shouldShowSneakPeek(on: vm.screenUUID) && coordinator.sneakPeekState(for: vm.screenUUID).type != .music && vm.notchState == .closed) { view in
                          view
                              .fixedSize()
                      }
                      .zIndex(1)
            if vm.notchState == .open {
                VStack {
                    if notificationManager.activeNotification == nil, let notice = custom.notice, notice.source != .wifi {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notice.title).font(.subheadline.weight(.semibold))
                                Text(notice.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .lineLimit(2)
                        } icon: {
                            Image(systemName: notice.icon)
                        }
                        .frame(maxWidth: 320, alignment: .leading)
                        .padding(.horizontal, 10)
                    }
                    // An open notch with a live notification is showing the
                    // notification card; the usual tabs wait until it is dismissed.
                    if let notification = notificationManager.activeNotification {
                        NotificationExpandedView(notification: notification, showsMore: isHovering)
                            .id(notification.nativeActionID ?? notification.id)
                    } else if custom.wellnessActivity != nil {
                        CustomWellnessControls()
                    } else if Defaults[.compactMode] {
                        // Player only — no tab switching, so currentView is
                        // ignored here rather than offering a shelf the
                        // compact layout has no room (or tab bar) for.
                        // 336 = Atoll's 420 base less 20%, which also lands
                        // within a few points of their Dynamic Island width
                        // (340) — the tighter of their two compact sizes.
                        CompactHomeView(
                            albumArtNamespace: albumArtNamespace,
                            horizontalMediaGestureFeedback: horizontalMediaGestureFeedback
                        )
                        .frame(width: 336)
                        .onHover { hovering in
                            isHoveringMusicArea = hovering
                        }
                        .onDisappear {
                            isHoveringMusicArea = false
                        }
                    } else {
                        switch coordinator.currentView {
                        case .home:
                            NotchHomeView(
                                albumArtNamespace: albumArtNamespace,
                                horizontalMediaGestureFeedback: horizontalMediaGestureFeedback,
                                isHoveringMusicArea: $isHoveringMusicArea
                            )
                        case .shelf:
                            ShelfView(dropInteraction: vm.dropInteraction)
                        }
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
    }

    private func nowPlayingFallbackNotice(_ notice: NowPlayingFallbackNotice) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(notice.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .lineLimit(2)

            Spacer(minLength: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: nowPlayingFallbackNoticeWidth)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
        .onAppear {
            if musicManager.markNowPlayingNoticePresented(notice.id) {
                announceNowPlayingFallbackNotice(notice)
            }
        }
    }

    private func announceNowPlayingFallbackNotice(_ notice: NowPlayingFallbackNotice) {
        let announcement = "\(String(localized: notice.title)). \(String(localized: notice.subtitle))."
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + 20)
            let faceScale = min(1.0, displayClosedNotchHeight / 30.0)
            AnimatedFace(height: 24.0 * faceScale, width: 30.0 * faceScale)
        }.frame(
            height: displayClosedNotchHeight,
            alignment: .center
        )
    }

    private var persistentMusicPeek: Bool {
        let state = coordinator.sneakPeekState(for: vm.screenUUID)
        return musicPeekEnabled && alwaysMusicPeek && musicManager.isPlaying
            && notificationManager.activeNotification == nil && custom.wellnessActivity == nil
            && custom.notice == nil && (!state.show || state.type == .music)
            && (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
    }

    private var visibleMusicPeekStyle: SneakPeekStyle? {
        guard musicPeekEnabled, notificationManager.activeNotification == nil else { return nil }
        let screenPeek = coordinator.sneakPeekState(for: vm.screenUUID)
        let expandedPeek = coordinator.expandingView
        let visible = persistentMusicPeek || (screenPeek.show && screenPeek.type == .music)
            || (expandedPeek.show && expandedPeek.type == .music)
        return visible ? musicPeekStyle : nil
    }

    /// Width of the black centre section of the closed music pill.
    ///
    /// Derived from the real notch width rather than the previous hard-coded
    /// 380. That constant assumed a particular notch size: the title sits
    /// left of the cutout and the artist right of it, separated by a spacer
    /// as wide as the notch itself, so on a wider notch there was no room
    /// left for the artist and the labels collided. Sizing from
    /// closedNotchSize keeps a fixed label budget either side whatever the
    /// hardware is, and keeps liveActivityEdgeMargin in play so content
    /// clears the bezel — the inline path had dropped it entirely.
    private var musicActivityCenterWidth: CGFloat {
        let margin = vm.closedNotchSize.width - 4 + (2 * liveActivityEdgeMargin)
        guard visibleMusicPeekStyle == .inline else { return margin }
        return margin + (2 * inlineMusicPeekLabelWidth)
    }

    /// Space reserved for the title (left of the cutout) and artist (right).
    private let inlineMusicPeekLabelWidth: CGFloat = 110

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        if visibleMusicPeekStyle == .standard {
            VStack(alignment: .leading, spacing: 0) {
                musicActivityHeader
                GeometryReader { geometry in
                    MusicSneakPeekCaption(
                        title: musicManager.songTitle + " - " + musicManager.artistName,
                        color: Defaults[.playerColorTinting]
                            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray,
                        persistent: persistentMusicPeek,
                        alignment: musicPeekAlignment.alignment
                    )
                    .frame(width: geometry.size.width)
                }
                .frame(height: 16)
                .padding(.bottom, 10)
            }
            .fixedSize()
        } else {
            musicActivityHeader
        }
    }

    private var musicActivityHeader: some View {
        HStack(spacing: 0) {
            // Closed-mode album art: scale padding and corner radius according to cornerRadiusScaleFactor
            let baseArtSize = displayClosedNotchHeight - 12
            let scaledArtSize: CGFloat = {
                if let scale = cornerRadiusScaleFactor {
                    return displayClosedNotchHeight - 12 * scale
                }
                return baseArtSize
            }()
            // The art's top/bottom gap to the pill; the leading offset below
            // trims the row's edge slack down to this same inset.
            let artVerticalInset = (displayClosedNotchHeight - scaledArtSize) / 2

            let closedCornerRadius: CGFloat = {
                let base = MusicPlayerImageSizes.cornerRadiusInset.closed
                if let scale = cornerRadiusScaleFactor {
                    return max(0, base * scale)
                }
                return base
            }()

            Image(nsImage: musicManager.albumArt)
                .resizable().scaledToFit()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: closedCornerRadius)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: scaledArtSize,
                    height: scaledArtSize
                )
                .offset(x: artVerticalInset - liveActivityEdgeMargin)

            Rectangle()
                .fill(.black)
                .overlay(
                    // .center, not .top: the album art beside this is
                    // vertically centered, so top-aligned labels sat visibly
                    // high against it.
                    HStack(alignment: .center) {
                        if visibleMusicPeekStyle == .inline {
                            Text(musicManager.songTitle)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: inlineMusicPeekLabelWidth, alignment: .leading)
                                .foregroundStyle(Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor) : .gray)
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: inlineMusicPeekLabelWidth, alignment: .trailing)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )

                        }
                    }
                    .padding(.horizontal, 8)
                )
                .frame(width: musicActivityCenterWidth)

            HStack {
                let tint = Defaults[.coloredSpectrogram]
                    ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.5)
                    : .gray
                MusicVisualizer(isPlaying: musicManager.isPlaying, tintColor: tint)
                    .frame(width: 18, height: 12)
            }
            .frame(
                width: max(
                    0,
                    displayClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    displayClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: displayClosedNotchHeight,
            alignment: .center
        )
    }

}
// MARK: - Gesture & Hover Handling

extension ContentView {
    @discardableResult
    private func doOpen() -> Bool {
        var didOpen = false
        withAnimation(animationSpring) {
            didOpen = vm.open()
        }
        return didOpen
    }

    // MARK: - Hover Management

    private var canOpenOnHover: Bool {
        vm.notchState == .closed
            && Defaults[.openNotchOnHover]
            && !shouldDisplayNowPlayingFallbackNotice
            && !coordinator.sneakPeekBlocksHover(
                on: vm.screenUUID, primaryButtonDown: NSEvent.pressedMouseButtons & 1 != 0
            )
    }

    /// Closes the open notch after the hover grace period unless a popover
    /// still owns the pointer.
    private func scheduleCloseIfNotHovering(overNotch notchViewModel: BoringViewModel) {
        guard notchViewModel.notchState == .open,
              !isHovering,
              !notchViewModel.popoverKeepsNotchOpen else { return }
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(hoverExitDelayMilliseconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self.vm.notchState == .open,
                   !self.isHovering,
                   !self.vm.popoverKeepsNotchOpen,
                   !self.vm.dropInteraction.anyDropZoneTargeting,
                   !(self.vm.notificationAutoOpened && self.notificationManager.activeNotification != nil),
                   !SharingStateManager.shared.preventNotchClose {
                    self.vm.close()
                }
            }
        }
    }

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()

        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }

            // Freeze the dismiss countdown the moment the pointer arrives,
            // not when the notch finishes opening. Opening waits out
            // minimumHoverDuration plus an animation, and a notification
            // near the end of its life would expire during that — so it
            // vanished exactly as the notch opened around it.
            if notificationManager.activeNotification != nil {
                notificationManager.holdActive()
            }

            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }

            guard canOpenOnHover else { return }

            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.isHovering, self.canOpenOnHover else { return }

                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(hoverExitDelayMilliseconds))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }

                    // Pointer left — let the notification age out again.
                    self.notificationManager.resumeDismiss()

                    if self.vm.notchState == .open,
                       !self.vm.popoverKeepsNotchOpen,
                       !self.vm.dropInteraction.anyDropZoneTargeting,
                       !(self.vm.notificationAutoOpened && self.notificationManager.activeNotification != nil),
                       !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        if phase == .began { verticalGestureTriggered = false }
        if phase == .ended || phase == .cancelled {
            verticalGestureTriggered = false
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }
        guard !verticalGestureTriggered else { return }

        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            verticalGestureTriggered = true
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        if phase == .began { verticalGestureTriggered = false }
        if phase == .ended || phase == .cancelled {
            verticalGestureTriggered = false
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }
        guard !verticalGestureTriggered else { return }

        guard vm.notchState == .open, !vm.isHoveringCalendar,
              !vm.isHoveringNotificationScroll, !vm.isComposingNotificationReply else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            verticalGestureTriggered = true
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose {
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    private func handleNextTrackGesture(translation: CGFloat, phase: NSEvent.Phase) {
        handleHorizontalMediaGesture(translation: translation, phase: phase, feedback: -1) {
            musicManager.nextTrack()
        }
    }

    private func handlePreviousTrackGesture(translation: CGFloat, phase: NSEvent.Phase) {
        handleHorizontalMediaGesture(translation: translation, phase: phase, feedback: 1) {
            musicManager.previousTrack()
        }
    }

    private func handleHorizontalMediaGesture(
        translation: CGFloat,
        phase: NSEvent.Phase,
        feedback: CGFloat,
        action: () -> Void
    ) {
        guard isHorizontalMediaGestureContext else {
            resetHorizontalMediaGesture()
            return
        }
        guard phase != .ended else {
            resetHorizontalMediaGesture()
            return
        }
        guard !horizontalMediaGestureTriggered else { return }
        guard translation > Defaults[.gestureSensitivity] else { return }

        horizontalMediaGestureTriggered = true
        triggerHorizontalMediaFeedback(feedback)
        action()

        if Defaults[.enableHaptics] {
            haptics.toggle()
        }
    }

    private func resetHorizontalMediaGesture() {
        horizontalMediaGestureTriggered = false
    }

    private func triggerHorizontalMediaFeedback(_ feedback: CGFloat) {
        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.62)) {
            horizontalMediaGestureFeedback = feedback
            if vm.notchState == .closed {
                gestureProgress = 2
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(animationSpring) {
                horizontalMediaGestureFeedback = .zero
                if vm.notchState == .closed {
                    gestureProgress = .zero
                }
            }
        }
    }

    private var isHorizontalMediaGestureContext: Bool {
        switch vm.notchState {
        case .closed:
            guard !vm.hideOnClosed else { return false }

            if coordinator.shouldShowSneakPeek(on: vm.screenUUID) {
                return coordinator.sneakPeekState(for: vm.screenUUID).type == .music
            }

            guard !coordinator.expandingView.show || coordinator.expandingView.type == .music else {
                return false
            }

            return coordinator.musicLiveActivityEnabled && (musicManager.isPlaying || !musicManager.isPlayerIdle)

        case .open:
            if Defaults[.compactMode] {
                return !musicManager.isPlayerIdle && isHoveringMusicArea
            }
            return coordinator.currentView == .home && !musicManager.isPlayerIdle && isHoveringMusicArea
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }
}

#Preview {
    let vm = BoringViewModel(camera: CameraModel())
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
