import SwiftData
import XCTest

@testable import foqos

@MainActor
final class FoqosControlTests: ModelRegressionTestCase {
  private var manager: StrategyManager!

  override func setUpWithError() throws {
    try super.setUpWithError()
    manager = StrategyManager()
  }

  override func tearDownWithError() throws {
    manager.stopTimer()
    manager = nil
    try super.tearDownWithError()
  }

  func testStartAndStopPersistAndRepeatedValuesAreIdempotent() throws {
    let profile = try makeProfile()
    try manager.setProfileActiveFromControl(true, profileID: profile.id, context: context)
    let session = try XCTUnwrap(BlockedProfileSession.mostRecentActiveSession(in: context))
    try manager.setProfileActiveFromControl(true, profileID: profile.id, context: context)
    XCTAssertEqual(BlockedProfileSession.mostRecentActiveSession(in: context)?.id, session.id)
    XCTAssertTrue(controlState.isProfileActive(profile.id.uuidString))
    XCTAssertNotNil(try BlockedProfileSession.findSession(byID: session.id, in: freshContext()))

    try manager.setProfileActiveFromControl(false, profileID: profile.id, context: context)
    try manager.setProfileActiveFromControl(false, profileID: profile.id, context: context)
    XCTAssertNotNil(session.endTime)
    XCTAssertFalse(controlState.isProfileActive(profile.id.uuidString))
    XCTAssertNotNil(
      try BlockedProfileSession.findSession(byID: session.id, in: freshContext())?.endTime
    )
  }

  func testAnotherProfileCannotReplaceOrStopTheCurrentSession() throws {
    let session = try makeSession()
    let other = try makeProfile(name: "Reading")
    XCTAssertThrowsError(
      try manager.setProfileActiveFromControl(true, profileID: other.id, context: context)
    ) { XCTAssertEqual($0 as? FoqosControlError, .anotherProfileActive) }
    try manager.setProfileActiveFromControl(false, profileID: other.id, context: context)
    XCTAssertNil(session.endTime)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, session.id)
  }

  func testDisabledBackgroundStopLeavesSessionAndBreakIntact() throws {
    let session = try makeSession()
    session.blockedProfile.disableBackgroundStops = true
    session.startBreak()
    try context.save()
    XCTAssertThrowsError(
      try manager.setProfileActiveFromControl(
        false, profileID: session.blockedProfile.id, context: context
      )
    ) { XCTAssertEqual($0 as? FoqosControlError, .backgroundStopDisabled) }
    XCTAssertNil(session.endTime)
    XCTAssertTrue(session.isBreakActive)
  }

  func testDeletedProfileReturnsAnError() {
    XCTAssertThrowsError(
      try manager.setProfileActiveFromControl(true, profileID: UUID(), context: context)
    ) { XCTAssertEqual($0 as? FoqosControlError, .profileUnavailable) }
  }

  func testHardModeRejectsStopRoutesUntilTheLockExpires() throws {
    let session = try makeSession()
    session.blockedProfile.enableHardMode = true
    try context.save()
    manager.loadActiveSession(context: context)

    manager.toggleBlocking(context: context, activeProfile: session.blockedProfile)
    XCTAssertTrue(session.isActive)
    manager.stopSessionFromBackground(session.blockedProfile.id, context: context)
    XCTAssertTrue(session.isActive)
    XCTAssertThrowsError(
      try manager.setProfileActiveFromControl(
        false, profileID: session.blockedProfile.id, context: context)
    )

    let otherProfile = try makeProfile(name: "Reading")
    for profile in [session.blockedProfile, otherProfile] {
      manager.toggleSessionFromDeeplink(
        profile.id.uuidString,
        url: try XCTUnwrap(URL(string: BlockedProfiles.getProfileDeepLink(profile))),
        context: context
      )
      XCTAssertTrue(session.isActive)
      XCTAssertEqual(SharedData.getActiveSharedSession()?.id, session.id)
    }

    session.startTime = Date().addingTimeInterval(-31 * 60)
    SharedData.createActiveSharedSession(for: session.toSnapshot())
    try context.save()
    try manager.setProfileActiveFromControl(
      false, profileID: session.blockedProfile.id, context: context)
    XCTAssertFalse(session.isActive)
    XCTAssertNil(SharedData.getActiveSharedSession())
  }

  func testHardModeBlocksManualStoppingOfScheduledSessionButAllowsScheduledEnd() throws {
    let profile = try makeProfile()
    profile.enableHardMode = true
    try context.save()
    SharedData.createSessionForSchedular(for: profile.id)

    XCTAssertThrowsError(
      try manager.setProfileActiveFromControl(false, profileID: profile.id, context: context)
    )
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, profile.id)

    ScheduleTimerActivity().stop(for: BlockedProfiles.getSnapshot(for: profile))
    manager.loadActiveSession(context: context)
    XCTAssertNil(manager.activeSession)
  }

  func testMissedScheduleBeganDuringTheSession() throws {
    let missed = try makeProfile(name: "Home")
    // Its schedule starts this minute, as when one schedule ends where the next begins
    missed.schedule = makeSchedule(startingMinutesFromNow: 0)
    let snapshot = BlockedProfiles.getSnapshot(for: missed)
    SharedData.setSnapshot(snapshot, for: missed.id.uuidString)
    let activity = ScheduleTimerActivity()
    var session = SharedData.createSessionForSchedular(for: UUID())
    session.startTime = Date().addingTimeInterval(-60 * 60)

    XCTAssertEqual(
      activity.getMissedScheduleProfile(
        for: session, from: [activity.getDeviceActivityName(from: missed.id.uuidString)]),
      snapshot)
    XCTAssertNil(activity.getMissedScheduleProfile(for: session, from: []))
  }

  func testScheduleThatWasReplacedIsNotMissed() throws {
    let replaced = try makeProfile(name: "Home")
    replaced.schedule = makeSchedule(startingMinutesFromNow: -60)
    SharedData.setSnapshot(
      BlockedProfiles.getSnapshot(for: replaced), for: replaced.id.uuidString)
    let activity = ScheduleTimerActivity()
    let session = SharedData.createSessionForSchedular(for: UUID())

    XCTAssertNil(
      activity.getMissedScheduleProfile(
        for: session, from: [activity.getDeviceActivityName(from: replaced.id.uuidString)]))
  }

  func testOvernightScheduleBelongsToItsStartDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    // referenceDate is a Tuesday at 22:13 UTC.
    let schedule = BlockedProfileSchedule(
      days: [.tuesday], startHour: 22, startMinute: 0, endHour: 7, endMinute: 35)
    let tuesdayStart = referenceDate.addingTimeInterval(-(13 * 60 + 20))

    XCTAssertEqual(schedule.currentStartDate(now: referenceDate, calendar: calendar), tuesdayStart)
    XCTAssertEqual(
      schedule.currentStartDate(
        now: referenceDate.addingTimeInterval(9 * 60 * 60), calendar: calendar), tuesdayStart)
    XCTAssertNil(
      schedule.currentStartDate(
        now: referenceDate.addingTimeInterval(10 * 60 * 60), calendar: calendar))
    XCTAssertNil(
      schedule.currentStartDate(
        now: referenceDate.addingTimeInterval(-15 * 60 * 60), calendar: calendar))
  }

  func testBreakControlStartsAndEndsWithoutEndingTheProfile() throws {
    let session = try makeSession()
    var scheduleCount = 0
    for _ in 0..<2 {
      try manager.setBreakActiveFromControl(true, sessionID: session.id, context: context) {
        _, duration in
        scheduleCount += 1
        XCTAssertEqual(duration, 600)
      }
    }
    XCTAssertEqual(scheduleCount, 1)
    XCTAssertTrue(controlState.isBreakActive)
    XCTAssertTrue(controlState.isProfileActive(session.blockedProfile.id.uuidString))

    try manager.setBreakActiveFromControl(false, sessionID: session.id, context: context)
    try manager.setBreakActiveFromControl(false, sessionID: session.id, context: context)
    XCTAssertFalse(controlState.isBreakActive)
    XCTAssertTrue(controlState.isProfileActive(session.blockedProfile.id.uuidString))
  }

  func testStaleBreakControlCannotAffectAReplacementSession() throws {
    let session = try makeSession()
    for desiredState in [true, false] {
      XCTAssertThrowsError(
        try manager.setBreakActiveFromControl(
          desiredState, sessionID: "previous-session", context: context
        )
      ) { XCTAssertEqual($0 as? FoqosControlError, .sessionChanged) }
    }
    XCTAssertNil(session.breakStartTime)
    XCTAssertNil(session.endTime)
  }

  func testBreakControlEnforcesAllowanceAndEnabledSetting() throws {
    let session = try makeSession()
    session.blockedProfile.enableBreaks = false
    XCTAssertThrowsError(
      try manager.setBreakActiveFromControl(true, sessionID: session.id, context: context)
    ) { XCTAssertEqual($0 as? BreakSessionError, .breaksUnavailable(profileName: "Work")) }

    session.blockedProfile.enableBreaks = true
    session.usedBreakDurationInSeconds = 600
    SharedData.createActiveSharedSession(for: session.toSnapshot())
    try context.save()
    XCTAssertThrowsError(
      try manager.setBreakActiveFromControl(true, sessionID: session.id, context: context)
    ) { XCTAssertEqual($0 as? BreakSessionError, .allowanceExhausted(profileName: "Work")) }
    XCTAssertNil(session.breakStartTime)
  }

  func testBreakControlRequiresAnActiveSession() throws {
    XCTAssertThrowsError(
      try manager.setBreakActiveFromControl(true, sessionID: "", context: context)
    ) { XCTAssertEqual($0 as? BreakSessionError, .noActiveSession) }
    try manager.setBreakActiveFromControl(false, sessionID: "", context: context)
  }

  func testStateReadsExtensionChangesAndIgnoresCompletedSessions() throws {
    let session = try makeSession()
    SharedData.setBreakStartTime(date: Date())
    XCTAssertTrue(controlState.isBreakActive)
    SharedData.setBreakEndTime(date: Date())
    XCTAssertFalse(controlState.isBreakActive)
    XCTAssertTrue(controlState.isProfileActive(session.blockedProfile.id.uuidString))
    SharedData.setEndTime(date: Date())
    XCTAssertFalse(controlState.isProfileActive(session.blockedProfile.id.uuidString))
    XCTAssertFalse(controlState.isBreakActive)
    XCTAssertFalse(controlState.isProfileActive(nil))
    XCTAssertFalse(controlState.isProfileActive("invalid"))
  }

  private var controlState: FoqosControlState {
    FoqosControlState(session: SharedData.getActiveSharedSession())
  }

  private func makeProfile(name: String = "Work") throws -> BlockedProfiles {
    let profile = BlockedProfiles(
      name: name, blockingStrategyId: ManualBlockingStrategy.id,
      enableLiveActivity: false, enableBreaks: true, breakTimeInMinutes: 10,
      allowMultipleBreaks: true
    )
    context.insert(profile)
    try context.save()
    return profile
  }

  private func makeSchedule(startingMinutesFromNow offset: Int) -> BlockedProfileSchedule {
    let start = Calendar.current.dateComponents(
      [.hour, .minute], from: Date().addingTimeInterval(TimeInterval(offset * 60)))
    var schedule = BlockedProfileSchedule(
      days: Weekday.allCases, startHour: start.hour!, startMinute: start.minute!,
      endHour: (start.hour! + 2) % 24, endMinute: start.minute!)
    schedule.updatedAt = Date().addingTimeInterval(-60 * 60)
    return schedule
  }

  private func makeSession() throws -> BlockedProfileSession {
    let profile = try makeProfile()
    let session = BlockedProfileSession.createSession(
      in: context, withTag: ManualBlockingStrategy.id, withProfile: profile
    )
    try context.save()
    return session
  }
}
