import Foundation
import SourceKittenFramework

private struct LintResult {
    let violations: [StyleViolation]
    let ruleTime: (id: String, time: Double)?
    let deprecatedToValidIDPairs: [(String, String)]
}

private enum LintableBox {
    case rule(Rule)
    case remoteRule(RemoteRule)

    private var ruleDescription: RuleDescription {
        switch self {
        case .rule(let rule):
            return type(of: rule).description
        case .remoteRule(let remoteRule):
            return remoteRule.ruleDescription
        }
    }

    func lint(file: File, regions: [Region], benchmark: Bool,
              superfluousDisableCommandRule: SuperfluousDisableCommandRule?,
              compilerArguments: [String]) -> LintResult? {
        let lintResultBeforeDisableCommand: LintResult?
        switch self {
        case .rule(let rule):
            lintResultBeforeDisableCommand = rule.lint(file: file, regions: regions, benchmark: benchmark,
                                                       compilerArguments: compilerArguments)
        case .remoteRule(let remoteRule):
            lintResultBeforeDisableCommand = remoteRule.lint(file: file, regions: regions, benchmark: benchmark,
                                                             compilerArguments: compilerArguments)
        }

        guard let lintResult = lintResultBeforeDisableCommand else {
            return nil
        }

        let violations = lintResult.violations
        let (disabledViolationsAndRegions, enabledViolationsAndRegions) = violations.map { violation in
            return (violation, regions.first { $0.contains(violation.location) })
        }.partitioned { _, region in
            return region?.isRuleEnabled(ruleDescription) ?? true
        }

        let ruleIDs = ruleDescription.allIdentifiers +
            (superfluousDisableCommandRule.map({ type(of: $0) })?.description.allIdentifiers ?? [])
        let ruleIdentifiers = Set(ruleIDs.map { RuleIdentifier($0) })

        let superfluousDisableCommandViolations = ruleDescription.superfluousDisableCommandViolations(
            regions: regions.count > 1 ? file.regions(restrictingRuleIdentifiers: ruleIdentifiers) : regions,
            superfluousDisableCommandRule: superfluousDisableCommandRule,
            allViolations: violations
        )

        let enabledViolations: [StyleViolation]
        if file.contents.hasPrefix("#!") { // if a violation happens on the same line as a shebang, ignore it
            enabledViolations = enabledViolationsAndRegions.compactMap { violation, _ in
                if violation.location.line == 1 { return nil }
                return violation
            }
        } else {
            enabledViolations = enabledViolationsAndRegions.map { $0.0 }
        }
        let deprecatedToValidIDPairs = disabledViolationsAndRegions.flatMap { _, region -> [(String, String)] in
            let identifiers = region?.deprecatedAliasesDisabling(ruleDescription: ruleDescription) ?? []
            return identifiers.map { ($0, ruleDescription.identifier) }
        }

        return LintResult(violations: enabledViolations + superfluousDisableCommandViolations,
                          ruleTime: lintResult.ruleTime,
                          deprecatedToValidIDPairs: deprecatedToValidIDPairs)
    }
}

private extension RuleDescription {
    func superfluousDisableCommandViolations(regions: [Region],
                                             superfluousDisableCommandRule: SuperfluousDisableCommandRule?,
                                             allViolations: [StyleViolation]) -> [StyleViolation] {
        guard !regions.isEmpty, let superfluousDisableCommandRule = superfluousDisableCommandRule else {
            return []
        }

        let regionsDisablingCurrentRule = regions.filter { region in
            return region.isRuleDisabled(self)
        }
        let regionsDisablingSuperflousDisableRule = regions.filter { region in
            return region.isRuleDisabled(superfluousDisableCommandRule)
        }

        return regionsDisablingCurrentRule.compactMap { region -> StyleViolation? in
            let isSuperflousRuleDisabled = regionsDisablingSuperflousDisableRule.contains { $0.contains(region.start) }
            guard !isSuperflousRuleDisabled else {
                return nil
            }

            let noViolationsInDisabledRegion = !allViolations.contains { violation in
                return region.contains(violation.location)
            }
            guard noViolationsInDisabledRegion else {
                return nil
            }

            return StyleViolation(
                ruleDescription: type(of: superfluousDisableCommandRule).description,
                severity: superfluousDisableCommandRule.configuration.severity,
                location: region.start,
                reason: superfluousDisableCommandRule.reason(for: self)
            )
        }
    }
}

private extension Rule {
    func lint(file: File, regions: [Region], benchmark: Bool,
              compilerArguments: [String]) -> LintResult? {
        if !(self is SourceKitFreeRule) && file.sourcekitdFailed {
            return nil
        }

        let ruleID = Self.description.identifier

        let violations: [StyleViolation]
        let ruleTime: (String, Double)?
        if benchmark {
            let start = Date()
            violations = validate(file: file, compilerArguments: compilerArguments)
            ruleTime = (ruleID, -start.timeIntervalSinceNow)
        } else {
            violations = validate(file: file, compilerArguments: compilerArguments)
            ruleTime = nil
        }

        return LintResult(violations: violations, ruleTime: ruleTime,
                          deprecatedToValidIDPairs: [])
    }
}

private extension RemoteRule {
    func lint(file: File, regions: [Region], benchmark: Bool,
              compilerArguments: [String]) -> LintResult? {
        let ruleID = ruleDescription.identifier

        let violations: [StyleViolation]
        let ruleTime: (String, Double)?
        if benchmark {
            let start = Date()
            violations = validate(file: file)
            ruleTime = (ruleID, -start.timeIntervalSinceNow)
        } else {
            violations = validate(file: file)
            ruleTime = nil
        }

        return LintResult(violations: violations, ruleTime: ruleTime,
                          deprecatedToValidIDPairs: [])
    }
}

public struct Linter {
    public let file: File
    private let rules: [Rule]
    private let cache: LinterCache?
    private let configuration: Configuration
    private let compilerArguments: [String]
    private let remoteRules: [RemoteRule]

    public var styleViolations: [StyleViolation] {
        return getStyleViolations().0
    }

    public var styleViolationsAndRuleTimes: ([StyleViolation], [(id: String, time: Double)]) {
        return getStyleViolations(benchmark: true)
    }

    private func getStyleViolations(benchmark: Bool = false) -> ([StyleViolation], [(id: String, time: Double)]) {
        if let cached = cachedStyleViolations(benchmark: benchmark) {
            return cached
        }

        if file.sourcekitdFailed {
            queuedPrintError("Most rules will be skipped because sourcekitd has failed.")
        }
        let regions = file.regions()
        let superfluousDisableCommandRule = rules.first(where: {
            $0 is SuperfluousDisableCommandRule
        }) as? SuperfluousDisableCommandRule

        let lintables = remoteRules.map(LintableBox.remoteRule) + rules.map(LintableBox.rule)
        let validationResults = lintables.parallelCompactMap {
            $0.lint(file: self.file, regions: regions, benchmark: benchmark,
                    superfluousDisableCommandRule: superfluousDisableCommandRule,
                    compilerArguments: self.compilerArguments)
        }
        let violations = validationResults.flatMap { $0.violations }
        let ruleTimes = validationResults.compactMap { $0.ruleTime }
        var deprecatedToValidIdentifier = [String: String]()
        for (key, value) in validationResults.flatMap({ $0.deprecatedToValidIDPairs }) {
            deprecatedToValidIdentifier[key] = value
        }

        if let cache = cache, let path = file.path {
            cache.cache(violations: violations, forFile: path, configuration: configuration)
        }

        for (deprecatedIdentifier, identifier) in deprecatedToValidIdentifier {
            queuedPrintError("'\(deprecatedIdentifier)' rule has been renamed to '\(identifier)' and will be " +
                "completely removed in a future release.")
        }

        return (violations, ruleTimes)
    }

    private func cachedStyleViolations(benchmark: Bool = false) -> ([StyleViolation], [(id: String, time: Double)])? {
        let start: Date! = benchmark ? Date() : nil
        guard let cache = cache, let file = file.path,
            let cachedViolations = cache.violations(forFile: file, configuration: configuration) else {
            return nil
        }

        var ruleTimes = [(id: String, time: Double)]()
        if benchmark {
            // let's assume that all rules should have the same duration and split the duration among them
            let totalTime = -start.timeIntervalSinceNow
            let fractionedTime = totalTime / TimeInterval(rules.count)
            ruleTimes = rules.compactMap { rule in
                let id = type(of: rule).description.identifier
                return (id, fractionedTime)
            }
        }

        return (cachedViolations, ruleTimes)
    }

    public init(file: File, configuration: Configuration = Configuration()!, cache: LinterCache? = nil,
                compilerArguments: [String] = []) {
        self.file = file
        self.configuration = configuration
        self.cache = cache
        self.compilerArguments = compilerArguments
        self.rules = configuration.rules.filter { rule in
            if compilerArguments.isEmpty {
                return !(rule is AnalyzerRule)
            } else {
                return rule is AnalyzerRule
            }
        }
        self.remoteRules = configuration.remoteRules
    }

    public func correct() -> [Correction] {
        if let violations = cachedStyleViolations()?.0, violations.isEmpty {
            return []
        }

        var corrections = [Correction]()
        for rule in rules.compactMap({ $0 as? CorrectableRule }) {
            let newCorrections = rule.correct(file: file, compilerArguments: compilerArguments)
            corrections += newCorrections
            if !newCorrections.isEmpty {
                file.invalidateCache()
            }
        }
        return corrections
    }

    public func format(useTabs: Bool, indentWidth: Int) {
        let formattedContents = try? file.format(trimmingTrailingWhitespace: true,
                                                 useTabs: useTabs,
                                                 indentWidth: indentWidth)
        if let formattedContents = formattedContents {
            file.write(formattedContents)
        }
    }
}
