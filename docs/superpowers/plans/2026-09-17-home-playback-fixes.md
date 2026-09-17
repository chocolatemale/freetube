# Home and playback fixes

Goal: implement the five requested corrections using the existing SwiftUI / AVQueuePlayer stack.

- [ ] HomeFeedParserTests: reproduce missing lockupViewModel videos, duplicate chip identity, Shorts filtering, and continuation-only pages. Fix HomeFeedService and HomeFeedSection.
- [ ] RootView / HomeFeedScreen / HomeScreen: remove Search from iPhone/iPad tabs; Home toolbar opens search with normal return navigation. Preserve keyboard search routing and mini player. Home remains available.
- [ ] FullScreenPlayer / CustomPlayerControls: fullscreen is a 44-point bottom-right control, separate from configurable top controls and the seek track.
- [ ] Player: reproduce music → video with the existing resolver and inspect crash report. Verify autoplay by observing advancing AVPlayer time, not the isPlaying prediction. Add regression coverage for the cause found.
- [ ] Update AGENTS.md with new pitfalls. Run simulator tests, build, inspect screenshots and playback logs; report any unverified real-account behavior.

No new dependencies, credential persistence, or changes to security invariants. User has specified and authorized the behavior and placement; no additional design approval is needed.
