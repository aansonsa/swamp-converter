# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private reporting instead:

1. Open the **Security** tab of this repository.
2. Choose **Report a vulnerability**.
3. Describe what you found, how to reproduce it and which version of the app you used (*Swamp Converter > About*).

This is a one-person project, so replies are best effort. A report that comes with steps to reproduce is the fastest to deal with.

## Supported versions

Only the [latest release](https://github.com/aansonsa/swamp-converter/releases/latest) receives fixes.

## What counts

Things worth reporting:

- opening an archive, a document or a link that makes the app write outside its work folder or run something it should not;
- a file name, a page title or a URL that ends up interpreted as a command, an option or AppleScript;
- the yt-dlp installer accepting a download that fails its checksum, or any use of the network outside the downloader;
- anything that lets one app read your files or pages without the permission prompt you expect.

Known and not a vulnerability: the app is signed ad hoc, not with a paid Developer ID, so macOS asks you to confirm it once (see *Honest limits* in the [README](README.md)).
