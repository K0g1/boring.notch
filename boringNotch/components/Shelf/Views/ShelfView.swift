//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    var compact = false
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    @State private var search = ""
    private let spacing: CGFloat = 8
    private var visibleItems: [ShelfItem] {
        tvm.items.filter { $0.matchesSearch(search) }
            .sorted { $0.isPinned && !$1.isPinned }
    }

    var body: some View {
        HStack(spacing: 12) {
            if !compact {
                FileShareView()
                    .aspectRatio(1, contentMode: .fit)
                    .environmentObject(vm)
            }
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
        .onChange(of: search) { selection.clear() }
        .onChange(of: tvm.items) { updateQuickLookSelection() }
        .onDisappear { quickLookService.hide() }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        } else {
            quickLookService.hide()
        }
    }

    var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                vm.dragDetectorTargeting
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                content
                    .padding(compact ? 8 : 16)
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.clear() }
    }

    var content: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search shelf", text: $search)
                    .textFieldStyle(.plain)
                    .font(.caption)
                Button { tvm.paste() } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("v", modifiers: .command)
                .help("Paste onto Shelf (⌘V)")
                .accessibilityLabel("Paste onto Shelf")
            }
            if let notice = tvm.notice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .onTapGesture { tvm.notice = nil }
            }
            if tvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)
                    
                    Text(tvm.isLoading ? "Adding items…" : "Drop files or paste here")
                        .foregroundStyle(.gray)
                        .font(.system(compact ? .caption : .title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else if visibleItems.isEmpty {
                Text("No matching items").foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: spacing) {
                        ForEach(visibleItems) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}
