import ArgumentParser
import Foundation

/// executable の入口。引数を解釈し、サブコマンドなら `run()` の代わりに `execute` へ `Request` を渡す。
/// エラー・ヘルプ・終了コード(使い方の誤りは 64、実行時エラーは 1、ヘルプとバージョンは 0)は、ArgumentParser 標準のまま。
/// ルート(引数なし)と `help` は、標準どおり `run()` がヘルプを出す。
public func runHingeCtl(
    arguments: [String]? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    execute: (Request) async throws -> Void
) async {
    do {
        var command = try HingeCtl.parseAsRoot(arguments)
        if let leaf = command as? any HingeSubcommand {
            try await execute(leaf.request(environment: environment))
        } else {
            try command.run()
        }
    } catch {
        HingeCtl.exit(withError: error)
    }
}
