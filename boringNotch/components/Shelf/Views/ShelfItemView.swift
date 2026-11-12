//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI

struct ShelfItemView: View {
    let item: ShelfItem
    let quickLookService: QuickLookService
    @StateObject private var viewModel: ShelfItemViewModel
    @State private var selectionState: ShelfItemSelectionState

    private var isSelected: Bool { selectionState.isSelected }

    private var highlight: HighlightPresentation {
        if isSelected {
            HighlightPresentation(
                fill: Color.accentColor.opacity(0.15),
                stroke: Color.accentColor.opacity(0.8),
                lineWidth: 2
            )
        } else {
            HighlightPresentation(fill: .clear, stroke: .clear, lineWidth: 1)
        }
    }

    init(
        item: ShelfItem,
        quickLookService: QuickLookService
    ) {
        self.item = item
        self.quickLookService = quickLookService
        _viewModel = StateObject(wrappedValue: ShelfItemViewModel(item: item))
        _selectionState = State(initialValue: ShelfSelectionModel.shared.state(for: item.id))
    }

    var body: some View {
        itemContent
        .task(id: item.kind) {
            await viewModel.loadPresentation(for: item)
        }
        .onAppear {
            viewModel.onQuickLookRequest = { urls in
                quickLookService.show(urls: urls, selectFirst: true)
            }
        }
    }

    // MARK: - View Components

    private var itemContent: some View {
        card
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.1), value: isSelected)
            .overlay {
                ShelfItemInteractionView(
                    item: item,
                    viewModel: viewModel,
                    dragPreview: { card.environment(\.colorScheme, .dark) },
                    onPrimaryClick: viewModel.handleClick,
                    onContextClick: viewModel.handleRightClick
                )
            }
    }

    private var card: some View {
        VStack(alignment: .center, spacing: 2) {
            iconView
            textView
        }
        .frame(width: 105)
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(backgroundView)
    }

    private var iconView: some View {
        Image(nsImage: viewModel.presentationIcon)
            .resizable().scaledToFit()
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
    }

    private var textView: some View {
        Text(viewModel.displayName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .frame(height: 28, alignment: .top)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(highlight.fill)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        highlight.stroke,
                        lineWidth: highlight.lineWidth
                    )
            )
    }

    private struct HighlightPresentation {
        let fill: Color
        let stroke: Color
        let lineWidth: CGFloat
    }
}
