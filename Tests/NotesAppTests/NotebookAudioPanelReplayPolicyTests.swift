@testable import NotesApp
import NotesCore
import XCTest

final class NotebookAudioPanelReplayPolicyTests: XCTestCase {
    func testReplayActionRequiresAvailabilityAndIdleAudioActivity() {
        let session = replayableSession()
        XCTAssertTrue(
            NotebookAudioPanelReplayPolicy.isEnabled(
                canStartReplay: true,
                activity: .idle,
                session: session
            )
        )
        XCTAssertFalse(
            NotebookAudioPanelReplayPolicy.isEnabled(
                canStartReplay: false,
                activity: .idle,
                session: session
            )
        )

        let nonIdleActivities: [NotebookAudioCoordinatorActivity] = [
            .startingRecording,
            .recording,
            .stoppingRecording,
            .persistingRecording,
            .preparingPlayback,
            .playing,
            .paused,
            .transcribing,
            .loadingTranscript,
            .cancelling,
        ]
        for activity in nonIdleActivities {
            XCTAssertFalse(
                NotebookAudioPanelReplayPolicy.isEnabled(
                    canStartReplay: true,
                    activity: activity,
                    session: session
                ),
                "Replay must remain disabled while audio is \(activity.rawValue)."
            )
        }
    }

    func testReplayActionRejectsLegacyOrInvalidTimingDescriptors() {
        var session = replayableSession()
        session.timelineFilename = nil
        XCTAssertFalse(isEnabled(session))

        session.timelineFilename = "   "
        XCTAssertFalse(isEnabled(session))

        session.timelineFilename = "timeline.json"
        session.durationSeconds = 0
        XCTAssertFalse(isEnabled(session))

        session.durationSeconds = -Double.infinity
        XCTAssertFalse(isEnabled(session))

        session.durationSeconds = .nan
        XCTAssertFalse(isEnabled(session))
    }

    func testReplayActionRejectsASealedHistoryWithNoRemainingScenes() {
        var session = replayableSession()
        session.schemaVersion = 3
        XCTAssertFalse(isEnabled(session))

        session.replayFilename = "session.replay.json"
        session.replayEventCount = 0
        XCTAssertFalse(isEnabled(session))

        session.replayEventCount = nil
        XCTAssertFalse(isEnabled(session))

        session.replayEventCount = 1
        XCTAssertTrue(isEnabled(session))
    }

    private func isEnabled(_ session: AudioSessionDescriptor) -> Bool {
        NotebookAudioPanelReplayPolicy.isEnabled(
            canStartReplay: true,
            activity: .idle,
            session: session
        )
    }

    private func replayableSession() -> AudioSessionDescriptor {
        AudioSessionDescriptor(
            durationSeconds: 60,
            timelineFilename: "timeline.json"
        )
    }
}
