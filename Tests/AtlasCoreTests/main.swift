import Foundation

// swift run atlastests [filter]
if let filter = CommandLine.arguments.dropFirst().first {
    Harness.filter = filter.lowercased()
    print("running suites matching \"\(filter)\"")
}

NormalizeTests.run()
AtlasTests.run()
GameTests.run()
ChallengeTests.run()
BotTests.run()
CardTests.run()
MediaTests.run()
SimulationTests.run()
ServerTests.run()

exit(Harness.report())
