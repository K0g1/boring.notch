//
//  AnimatedFace.swift
//
// Created by Harsh Vardhan  Goswami  on  04/08/24.
//

import SwiftUI

@MainActor
final class BlinkTaskController {
    private var task: Task<Void, Never>?
    private var generation: UUID?

    var isRunning: Bool { task != nil }

    @discardableResult
    func start(
        interval: Duration = .seconds(3),
        blinkDuration: Duration = .milliseconds(100),
        update: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard task == nil else { return false }

        let currentGeneration = UUID()
        generation = currentGeneration
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard self?.generation == currentGeneration else { break }
                update(true)

                do {
                    try await Task.sleep(for: blinkDuration)
                } catch {
                    break
                }
                guard self?.generation == currentGeneration else { break }
                update(false)
            }

            guard let self, generation == currentGeneration else { return }
            update(false)
            task = nil
            generation = nil
        }
        return true
    }

    func stop(update: @escaping @MainActor (Bool) -> Void) {
        generation = nil
        task?.cancel()
        task = nil
        update(false)
    }

    deinit {
        task?.cancel()
    }
}

struct MinimalFaceFeatures: View {
    @State private var isBlinking = false
    @State private var blinkController = BlinkTaskController()
    @State var height:CGFloat = 20;
    @State var width:CGFloat = 30;
    
    var body: some View {
        VStack(spacing: 4) { // Adjusted spacing to fit within 30x30
            // Eyes
            HStack(spacing: 4) { // Adjusted spacing to fit within 30x30
                Eye(isBlinking: $isBlinking)
                Eye(isBlinking: $isBlinking)
            }
            
            // Nose and mouth combined
            VStack(spacing: 2) { // Adjusted spacing to fit within 30x30
                // Nose
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 3, height: 4)
                
                // Mouth (happy)
                GeometryReader { geometry in
                    Path { path in
                        let width = geometry.size.width
                        let height = geometry.size.height
                        path.move(to: CGPoint(x: 0, y: height / 2))
                        path.addQuadCurve(to: CGPoint(x: width, y: height / 2), control: CGPoint(x: width / 2, y: height))
                    }
                    .stroke(Color.white, lineWidth: 2)
                }
                .frame(width: 14, height: 10)
            }
        }
        .frame(width: self.width, height: self.height) // Maximum size of face
        .onAppear {
            startBlinking()
        }
        .onDisappear {
            stopBlinking()
        }
    }
    
    func startBlinking() {
        blinkController.start { blinking in
            withAnimation(.spring(duration: 0.2)) {
                isBlinking = blinking
            }
        }
    }

    func stopBlinking() {
        blinkController.stop { _ in
            isBlinking = false
        }
    }
}

struct Eye: View {
    @Binding var isBlinking: Bool
    
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white)
            .frame(width: 4, height: isBlinking ? 1 : 4)
            .frame(maxWidth: 15, maxHeight: 15) // Adjusted max size
            .animation(.easeInOut(duration: 0.1), value: isBlinking)
    }
}

struct MinimalFaceFeatures_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
            MinimalFaceFeatures()
        }
        .previewLayout(.fixed(width: 60, height: 60)) // Adjusted preview size for better visibility
    }
}
