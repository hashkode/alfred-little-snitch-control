# Contributing

Bug reports and focused pull requests are welcome.

## Running the tests

`make test` runs entirely against mocks. It needs macOS and zsh — **no Little
Snitch installation, no Little Snitch license, and no administrator password.**
It never changes a real Little Snitch setting and writes nothing outside a
temporary directory.

```sh
make test          # unit and behaviour tests
make build         # writes dist/
make package-test  # validates the built archive
```

`make build` plus installing the result in Alfred requires Alfred 5 with the
Powerpack. Exercising a real privileged action additionally requires Little
Snitch; a trial from Objective Development is enough. If you cannot run those
steps, say so in the pull request and they will be run before merging.

## Before submitting a change

1. `make test` passes.
2. If you touched packaging, `make package-test` passes.
3. If you touched anything privileged — `bin/authorize.applescript`,
   `bin/action`, or the action map — include a short security rationale and
   tests. The maintainer will run [the manual checklist](docs/MANUAL_TESTING.md).
4. Add a CHANGELOG entry.

CI passing is necessary but not sufficient: the test suite deliberately
exercises no privileged path, so the manual checklist remains a human release
gate.

## Boundaries

Please do not introduce:

- arbitrary privileged arguments, or any path by which Alfred input reaches a
  shell;
- password handling of any kind;
- UI scripting, or anything requiring Little Snitch's `allowGUIScripting`;
- a `sudoers` rule, launch daemon, launch agent, or privileged helper;
- an auto-updater, or any runtime download;
- third-party runtime dependencies.

## Style

zsh, two-space indentation, absolute paths for every external binary
(`/usr/bin/stat`, `/bin/mkdir`, …), no `eval`, and `#!/bin/zsh -f` on every
entry point so a user's startup files cannot change behaviour.

## Security issues

Do not open a public issue for a security problem — see [SECURITY.md](SECURITY.md).

## License

Contributions are accepted under the [MIT License](LICENSE).
