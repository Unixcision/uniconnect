# Agent launch boundary

`AgentResumeArgv` reconstructs native resume commands after the existing Swift
sanitizer has handled captured arguments. Its default behavior and Claude hook
wrapper remain unchanged; the bundled trust policy is applied independently of
an injected syntax-only catalogue.

`Sources/CMUXAgentLaunch/Resources/agent-resume-v1.json` is the single command
syntax catalogue. SwiftPM packages it as a resource bundle; Linux reads that exact
source resource through `uniconnect.resume_catalog`. It must accompany any future
Linux distribution that does not run from the source checkout.

The Swift loader searches the deployed executable/resource directories, including
the app's `Contents/Resources` when its CLI is copied into `Contents/Resources/bin`.
It deliberately avoids the generated `Bundle.module` accessor: that accessor can
trap or silently use the original build tree after a CLI has been relocated.
Missing bundles or catalogue files return a failed resume result, never a crash
or an implicit fallback to source/build paths. The existing Xcode package-resource
embedding and CLI copy phases need no additional resource copy.

Version 1 declares each provider's executable, optional aliases, an argv template,
and the shared no-prompt policy. `{executable}` and `{sessionId}` each substitute
one argument; `{arguments}` inserts an already approved argument vector at its
declared position. Substitution never invokes a shell. `windowOptions` maps Linux's
explicitly saved cwd/model fields to provider options, without importing arbitrary
captured argv.

The bundled catalogue is the shared source for no-prompt flags. Swift's in-memory
`catalogData` injection changes command syntax only; it cannot add, remove, or
reposition a trust flag. Linux's temporary catalogue injection is reserved for
isolated portable tests. Do not copy Swift's captured-argument sanitizer into the
JSON decoder. The shared resource is command syntax and trust policy, not a claim
that all lifecycle/state services are already shared executable code.

Existing callers still use `AgentResumeArgv()`. Isolated tests can supply an
in-memory catalogue with `try AgentResumeArgv(catalogData: data)`, without touching
user histories, environment or provider processes. Python's decoder accepts a
temporary resource path for the same purpose. Missing or invalid catalogues fail
closed rather than replaying a second hard-coded command registry.

`AgentResumeCatalogTests` checks all 17 existing providers, bundle loading,
argument ordering and invalid resources. Its cross-language test emits argv from
Swift and passes 34 vectors to the real Python decoder for exact comparison.
The original resume and sanitizer tests remain unchanged. Running these package
tests on Linux verifies portable Swift behavior, not an AppKit/macOS app build.
Relocation tests build the isolated `Tests/Fixtures` executable package once in a
private scratch directory, then execute the copied `AgentResumeProbe` with its
copied resource bundle. It is a real CLI on both OSes, not the macOS xctest host;
no fixture product is exported by CMUXAgentLaunch. These tests exercise both
adjacent and app-bundled CLI layouts, and require missing resources
to fail closed even while the original build resources are still present.
