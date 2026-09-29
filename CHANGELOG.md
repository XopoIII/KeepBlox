# Changelog

Every release is listed here, newest first. The format follows Keep a Changelog, and versions follow
semantic versioning.

## Unreleased

### Added

- Repository scaffolding:
  - the pinned toolchain;
  - the lefthook and CI gates (strict mode, 300-line cap, English only, selene, StyLua, luau-lsp);
  - the test runner on LuneBlox.
- `Services`, the seam through which the library reaches every Roblox service.
- Test harness fakes:
  - a seeded virtual scheduler;
  - per-server clocks with skew and drift;
  - DataStore and MessagingService fakes.
