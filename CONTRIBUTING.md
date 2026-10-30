# Contributing

Thanks for looking. Bug reports, ideas and pull requests are welcome.

## Before you open an issue

- Questions and "how do I" belong in [Discussions](https://github.com/aansonsa/swamp-converter/discussions).
- Check the [guide](docs/GUIDE.md) and the [known limits](README.md#honest-limits) first. The ad-hoc signature prompt and the missing optional programs (ffmpeg, LibreOffice, Pandoc, yt-dlp) are expected.
- A bug report is easiest to act on with your macOS version, the app version (*Swamp Converter > About*), what you dragged or pressed, and what *Settings > Tools* shows.

## Building

Only the Command Line Tools are needed. Use `./build.sh` and nothing else (no `xcodebuild`, no `swift build`):

```sh
./build.sh check-modules     # module ownership rules
./build.sh typecheck all     # type-check the whole project
./build.sh selftest [filter] # the built-in tests, run in an isolated folder with no network
./build.sh snapshot <dir>    # offscreen screenshots of the interface
```

Everything is built into `~/Library/Caches/SwampConverter`, so the working tree stays clean. How the modules fit together and how to add an operation: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Pull requests

- One change per pull request, with a short description of what and why.
- `check-modules` and `typecheck all` must pass; CI runs both. Run the self-tests for the area you touched. The full suite also runs from the **Self-tests** workflow, but a few tests there depend on tools the GitHub runner lacks, so judge it against a local run.
- A new operation needs a real test: it runs on a real file and is judged by an independent reader of the result, not only by the exit code. Do not loosen an existing test to make a change pass.
- Changes to the interface come with a screenshot (`./build.sh snapshot`).
- The app, the README and the docs are English only.
- Borrowed code must be MIT, BSD, Apache-2.0, ISC, zlib, Unlicense or CC0, and gets listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- Do not commit `._*` files, build output or the `dist` folder.
