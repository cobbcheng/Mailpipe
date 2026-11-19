import Lottie
import SwiftUI

struct OnboardingArtwork: View {
    let step: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LottieView(animation: .named("step-\(step)", subdirectory: "OnboardingArt"))
            .resizable()
            .playbackMode(reduceMotion
                ? .paused(at: .progress(1))
                : .playing(.fromProgress(0, toProgress: 1, loopMode: .playOnce)))
            .aspectRatio(5.0 / 3, contentMode: .fit)
            .id(step)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
