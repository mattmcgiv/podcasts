import Darwin
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: evaluate-ad-removal-corpus.sh CORPUS_INDEX.json\n", stderr)
    exit(EX_USAGE)
}

do {
    let indexURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let episodes = try AdRemovalGoldenCorpusLoader().load(indexURL: indexURL)
    let report = try AdRemovalGoldenCorpusEvaluator().evaluate(episodes: episodes)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(report)
    FileHandle.standardOutput.write(encoded)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(report.passes ? EXIT_SUCCESS : 2)
} catch {
    fputs("ad-removal corpus evaluation failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
