# Publishing the browser extension

Goal: anyone can search "Nidestream" in the Chrome Web Store or Firefox Add-ons and install the
extension in one click, with automatic updates. The Chrome Web Store version also installs in Edge,
Brave, Arc, Vivaldi and Opera.

## Before you submit

| You need | Why | Cost |
| --- | --- | --- |
| A **Chrome Web Store developer account** ([chrome.google.com/webstore/devconsole](https://chrome.google.com/webstore/devconsole)) | To publish on Chrome. Needs a Google account with 2-step verification. | $5 once |
| A **Firefox account** for [addons.mozilla.org](https://addons.mozilla.org/developers/) | To publish on Firefox. | Free |
| A **public privacy policy URL** | Both stores require one, because the extension handles cookies and page addresses. It's `docs/privacy.html`, published by GitHub Pages at https://thedanielbolu.github.io/Nidestream/privacy.html (see [Publishing the website](#publishing-the-website)). | Free |
| A **public download of the Nidestream app** | The extension does nothing without the app, so the listing has to say where to get it, and reviewers will try it. Plan: a `.dmg` on GitHub Releases. | Free |
| A **support email** | Shown on both listings. | |

`docs/store/LISTING.md` already uses these addresses: the download page https://thedanielbolu.github.io/Nidestream/, the privacy policy
https://thedanielbolu.github.io/Nidestream/privacy.html, and https://github.com/thedanielbolu/Nidestream/issues for support.

## Opening an unsigned app

Until the app is signed and notarized (Apple Developer Program, $99/year), macOS blocks it the first
time it's opened from a download: "Apple could not verify Nidestream is free of malware". Users (and
store reviewers) get past this once:

1. Open the app, then click **Done** on the warning.
2. Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to the
   Nidestream message, and confirm with the Mac's password.

Put these steps on the download page and in the reviewer notes. Signing and notarizing later removes
the warning without changing anything else.

## Publishing the website

The site (download page and privacy policy) is plain HTML in `docs/`, served by GitHub Pages.

1. Create the public repository and push it:

   ```bash
   gh repo create thedanielbolu/Nidestream --public --source . --push
   ```

2. Turn on GitHub Pages for the `docs` folder of `main` (or in the repo: **Settings → Pages → Deploy from
   a branch → main → /docs**):

   ```bash
   gh api -X POST repos/thedanielbolu/Nidestream/pages -f "source[branch]=main" -f "source[path]=/docs"
   ```

3. After a minute the site is at https://thedanielbolu.github.io/Nidestream/ and the privacy policy at
   https://thedanielbolu.github.io/Nidestream/privacy.html.

When the store listings are live, replace the two "coming soon" buttons in `docs/index.html` with links
to them.

## Releasing the app

The download button points at `releases/latest/download/Nidestream.dmg`, so it always serves the newest
release as long as each release has a file named exactly `Nidestream.dmg`.

1. Raise `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`.
2. Build the installer (universal app, about 3 MB):

   ```bash
   scripts/make-dmg.sh
   ```

3. Publish it:

   ```bash
   gh release create v1.0.0 build/Nidestream.dmg --title "Nidestream 1.0.0" --notes "First release."
   ```

## Build the packages and images

```bash
scripts/package-extensions.sh
```

```bash
scripts/make-store-images.sh
```

You get `build/extensions/nidestream-chrome-<version>.zip`, `build/extensions/nidestream-firefox-<version>.zip`,
`build/store/screenshot-1280x800.png` and `build/store/promo-440x280.png`. Both packages have been
installed in real Chrome 155 and Firefox 158 and handed downloads to Nidestream.

## Chrome Web Store

1. In the [developer dashboard](https://chrome.google.com/webstore/devconsole), click **New item** and
   upload `nidestream-chrome-<version>.zip`.
2. **Store listing:** paste the summary and description from `LISTING.md`, pick the category, upload the
   128×128 icon (`BrowserExtension/icons/icon128.png`), the screenshot and the small promo tile.
3. **Privacy:** paste the single purpose and each permission justification from `LISTING.md`, answer
   "No" to remote code, fill in the data usage section as described there, and add the privacy policy URL.
4. **Distribution:** Public, all regions.
5. **Submit for review.** Extensions with access to all sites and cookies get a manual review; expect a
   few days, sometimes longer. Google emails you the result.

## Firefox Add-ons

1. Go to [Submit a New Add-on](https://addons.mozilla.org/developers/addon/submit/), choose
   **On this site** (listed), and upload `nidestream-firefox-<version>.zip`.
2. When asked about source code: the extension isn't minified or bundled, so answer **No**.
3. Fill in the name, summary, description, category (**Download Management**) and the privacy policy
   URL from `LISTING.md`. Add the screenshot.
4. Paste the reviewer notes from `LISTING.md` so the reviewer knows to install the app first.
5. Submit. Listed add-ons are reviewed by Mozilla, usually within a few days.

## Microsoft Edge (optional)

Edge users can already install from the Chrome Web Store. To also appear in Edge's own store, submit
the same Chrome package at [Partner Center](https://partner.microsoft.com/dashboard/microsoftedge/) (free).

## After approval

Send me the store links. The app's **Connect Your Browsers** window can then offer **Add to Chrome** and
**Add to Firefox** buttons that open the store pages, instead of the Developer mode steps.

## Updating

1. Raise `"version"` in `BrowserExtension/manifest.json` (for example 1.1.0 → 1.2.0).
2. Run `scripts/package-extensions.sh`.
3. Upload the new zip in each dashboard (Chrome: **Package → Upload new package**; Firefox: **Upload New
   Version**). Users get the update automatically after review.
