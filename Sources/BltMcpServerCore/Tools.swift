// MCP ツールカタログ。説明・inputSchema の正本は BlueTickerCore の `apiSkillsCatalog()`。
// 各ツールの実処理（ディスパッチ）は BltServerCore が持つ。ここはビジネスロジック・DB を持たない。

import BlueTickerCore
import Foundation
import MCP

/// blt-mcp が公開するツール一覧。REST `/v1/` の各エンドポイントに対応する
/// （`docs/blt-server-roadmap.md` / `Sources/BlueTicker/Server/ApiSkills.swift` 参照）。
public func mcpToolCatalog() -> [Tool] {
    apiSkillsCatalog().compactMap { mcpTool(from: $0) }
}

private func mcpTool(from skill: ApiSkill) -> Tool? {
    guard let name = skill.mcpTool else { return nil }
    let mcpParams = skill.parameters.compactMap { parameter -> (String, ApiSkillParameter)? in
        guard let mcpName = parameter.mcpName else { return nil }
        return (mcpName, parameter)
    }

    var properties: [String: Value] = [:]
    var required: [Value] = []
    for (mcpName, parameter) in mcpParams {
        properties[mcpName] = mcpPropertySchema(parameter)
        if parameter.effectiveMcpRequired == true {
            required.append(.string(mcpName))
        }
    }

    var schema: [String: Value] = [
        "type": .string("object"),
        "properties": .object(properties),
    ]
    if !required.isEmpty {
        schema["required"] = .array(required)
    }

    // 全ツールは格納済み DB / 固定 EDINET ソースへの read-only serve。副作用・破壊的操作はない。
    let annotations = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, openWorldHint: false)

    return Tool(
        name: name,
        title: skill.name,
        description: skill.description,
        inputSchema: .object(schema),
        annotations: annotations,
        outputSchema: decodeMcpOutputSchema(skill.mcpOutputSchema)
    )
}

private func decodeMcpOutputSchema(_ schemaText: String?) -> Value? {
    guard let schemaText,
        let data = schemaText.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(Value.self, from: data)
    else { return nil }
    return decoded
}

private func mcpPropertySchema(_ parameter: ApiSkillParameter) -> Value {
    var schema: [String: Value] = [
        "description": .string(parameter.description),
    ]
    switch parameter.effectiveMcpType ?? parameter.type {
    case .string:
        schema["type"] = .string("string")
    case .integer:
        schema["type"] = .string("integer")
    case .stringArray:
        schema["type"] = .string("array")
        schema["items"] = .object(["type": .string("string")])
    }
    switch parameter.defaultValue {
    case .int(let value):
        schema["default"] = .int(value)
    case .string(let value):
        schema["default"] = .string(value)
    case nil:
        break
    }
    return .object(schema)
}
