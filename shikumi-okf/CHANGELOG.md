# Changelog for shikumi-okf

## 0.1.0.0 (unreleased)

- Initial package scaffold (EP-31, Milestone 1): `Shikumi.Okf.Types` defining
  `SomeProgram`, `ProgramDoc`, `ProgramManifest`, and `AppInfo`.
- Program rendering and bundle generation (Milestones 2–3): `Shikumi.Okf.Render`
  (`renderProgramBody`) and `Shikumi.Okf.Generate` (`generateBundle`,
  `writeProgramBundle`, and the per-concept builders), producing one `Shikumi App`
  concept linking to one `Shikumi Program` concept per program.
- Shared OKF profile `profile/shikumi.dhall`, a worked `shikumi-okf-example`
  executable, and the committed `example/out` bundle (Milestone 4). Verified with
  the standalone `okf` CLI: `validate`, `--profile-enforce`, and `graph --json`.
