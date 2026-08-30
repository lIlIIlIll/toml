// SPDX-License-Identifier: Apache-2.0
package toml

import std.collection.*

/// One lint diagnostic and an optional revision-relative repair.
public class TomlLintFinding {
    public let diagnostic: TomlDiagnostic
    private let repair: Option<TomlTextEdit>

    public init(
        diagnostic: TomlDiagnostic,
        repair!: Option<TomlTextEdit> = None<TomlTextEdit>
    ) {
        this.diagnostic = diagnostic
        this.repair = match (repair) {
            case Some(edit) => Some(TomlTextEdit(edit.span, edit.replacementBytes()))
            case None => None<TomlTextEdit>
        }
    }

    public func fix(): Option<TomlTextEdit> {
        match (repair) {
            case Some(edit) => Some(TomlTextEdit(edit.span, edit.replacementBytes()))
            case None => None<TomlTextEdit>
        }
    }
}

/// Extension point for project-specific TOML lint rules.
public interface TomlLintRule {
    func check(document: TomlDocument): ArrayList<TomlLintFinding>
}

/// Reports every edit proposed by the lossless formatter as a fixable issue.
public class TomlFormattingRule <: TomlLintRule {
    public let style: TomlStyle
    public let mode: TomlFormatMode

    public init(
        style!: TomlStyle = TomlStyle.readable,
        mode!: TomlFormatMode = TomlFormatMode.Readable
    ) {
        this.style = style
        this.mode = mode
    }

    public func check(document: TomlDocument): ArrayList<TomlLintFinding> {
        let findings = ArrayList<TomlLintFinding>()
        if (document.hasErrors) { return findings }
        match (TomlFormatter(style: style, mode: mode).preview(document)) {
            case TomlOutcome<ArrayList<TomlTextEdit>>.Failure(_) => ()
            case TomlOutcome<ArrayList<TomlTextEdit>>.Success(edits, _) =>
                for (edit in edits) {
                    findings.add(TomlLintFinding(
                        TomlDiagnostic("lint_formatting", TomlSeverity.Warning,
                            "source does not match the configured TOML style",
                            primarySpan: Some(edit.span)),
                        repair: Some(edit)))
                }
        }
        findings
    }
}

/// Immutable lint output. All exposed fixes are valid, ordered and
/// non-overlapping for the document revision passed to TomlLinter.lint().
public class TomlLintResult {
    private let reportedDiagnostics: ArrayList<TomlDiagnostic>
    private let availableFixes: ArrayList<TomlTextEdit>

    init(diagnostics: Collection<TomlDiagnostic>, fixes: Collection<TomlTextEdit>) {
        reportedDiagnostics = ArrayList<TomlDiagnostic>(diagnostics)
        availableFixes = ArrayList<TomlTextEdit>()
        for (edit in fixes) {
            availableFixes.add(TomlTextEdit(edit.span, edit.replacementBytes()))
        }
    }

    public prop hasProblems: Bool { get() { !reportedDiagnostics.isEmpty() } }
    public prop hasErrors: Bool {
        get() {
            for (diagnostic in reportedDiagnostics) {
                match (diagnostic.severity) {
                    case TomlSeverity.Error => return true
                    case _ => ()
                }
            }
            false
        }
    }
    public prop hasFixes: Bool { get() { !availableFixes.isEmpty() } }

    public func diagnostics(): ArrayList<TomlDiagnostic> {
        ArrayList<TomlDiagnostic>(reportedDiagnostics)
    }

    public func fixes(): ArrayList<TomlTextEdit> {
        let copy = ArrayList<TomlTextEdit>()
        for (edit in availableFixes) {
            copy.add(TomlTextEdit(edit.span, edit.replacementBytes()))
        }
        copy
    }
}

/// Pure, deterministic linter. Rules run in declaration order; the first
/// valid fix wins if two custom rules propose overlapping repairs.
public class TomlLinter {
    private let configuredRules: ArrayList<TomlLintRule>

    /// Creates a linter with the built-in lossless formatting rule.
    public init(
        style!: TomlStyle = TomlStyle.readable,
        mode!: TomlFormatMode = TomlFormatMode.Readable
    ) {
        configuredRules = ArrayList<TomlLintRule>()
        configuredRules.add(TomlFormattingRule(style: style, mode: mode))
    }

    /// Creates a linter from an explicit ordered rule set.
    public init(rules: Collection<TomlLintRule>) {
        configuredRules = ArrayList<TomlLintRule>(rules)
    }

    public func rules(): ArrayList<TomlLintRule> { configuredRules.clone() }

    public func lint(document: TomlDocument): TomlLintResult {
        let diagnostics = document.diagnostics()
        let fixes = ArrayList<TomlTextEdit>()
        for (rule in configuredRules) {
            for (finding in rule.check(document)) {
                diagnostics.add(finding.diagnostic)
                match (finding.fix()) {
                    case None => ()
                    case Some(edit) =>
                        if (!tomlLintFixIsValid(document, edit)) {
                            diagnostics.add(TomlDiagnostic("lint_invalid_fix", TomlSeverity.Warning,
                                "a lint rule proposed an invalid repair", primarySpan: Some(edit.span)))
                        } else if (tomlLintFixOverlaps(fixes, edit)) {
                            diagnostics.add(TomlDiagnostic("lint_fix_conflict", TomlSeverity.Info,
                                "a lint repair was skipped because it overlaps an earlier repair",
                                primarySpan: Some(edit.span)))
                        } else {
                            tomlInsertLintFix(fixes, edit)
                        }
                }
            }
        }
        TomlLintResult(diagnostics, fixes)
    }

    /// Applies all safe fixes as one atomic document revision.
    public func applyFixes(document: TomlDocument): TomlOutcome<TomlDocument> {
        let result = lint(document)
        if (result.hasErrors) {
            return TomlOutcome<TomlDocument>.Failure(result.diagnostics())
        }
        let fixes = result.fixes()
        if (fixes.isEmpty()) {
            return TomlOutcome<TomlDocument>.Success(document, result.diagnostics())
        }
        let batch = TomlEditBatch(document.revision)
        for (edit in fixes) { let _ = batch.add(edit) }
        match (document.apply(batch)) {
            case TomlOutcome<TomlDocument>.Success(fixed, applyDiagnostics) =>
                let all = result.diagnostics(); all.add(all: applyDiagnostics)
                TomlOutcome<TomlDocument>.Success(fixed, all)
            case TomlOutcome<TomlDocument>.Failure(applyDiagnostics) =>
                let all = result.diagnostics(); all.add(all: applyDiagnostics)
                TomlOutcome<TomlDocument>.Failure(all)
        }
    }
}

public func lintTomlDocument(
    document: TomlDocument,
    style!: TomlStyle = TomlStyle.readable,
    mode!: TomlFormatMode = TomlFormatMode.Readable
): TomlLintResult {
    TomlLinter(style: style, mode: mode).lint(document)
}

public func fixTomlDocument(
    document: TomlDocument,
    style!: TomlStyle = TomlStyle.readable,
    mode!: TomlFormatMode = TomlFormatMode.Readable
): TomlOutcome<TomlDocument> {
    TomlLinter(style: style, mode: mode).applyFixes(document)
}

private func tomlLintFixIsValid(document: TomlDocument, edit: TomlTextEdit): Bool {
    let one = ArrayList<TomlTextEdit>()
    one.add(TomlTextEdit(edit.span, edit.replacementBytes()))
    tomlValidateTextEdits(document.sourceBytes(), one, document.options).isNone()
}

private func tomlLintFixOverlaps(fixes: ArrayList<TomlTextEdit>, candidate: TomlTextEdit): Bool {
    for (current in fixes) {
        if (current.span.start < candidate.span.end && current.span.end > candidate.span.start) {
            return true
        }
        if (current.span.length == 0 && candidate.span.length == 0 &&
            current.span.start == candidate.span.start) { return true }
    }
    false
}

private func tomlInsertLintFix(fixes: ArrayList<TomlTextEdit>, edit: TomlTextEdit): Unit {
    var position = fixes.size
    for (index in 0..fixes.size) {
        if (edit.span.start < fixes[index].span.start ||
            (edit.span.start == fixes[index].span.start && edit.span.end < fixes[index].span.end)) {
            position = index
            break
        }
    }
    fixes.add(TomlTextEdit(edit.span, edit.replacementBytes()), at: position)
}
