import ArgumentParser
import Foundation

struct SkillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "ticker を使った調査ワークフローのガイドを出力します"
    )

    func run() async throws {
        print(skillWorkflowText)
    }
}
