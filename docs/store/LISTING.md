# Store listing: Nidestream Integration

Copy these into the Chrome Web Store dashboard and the Firefox Add-ons (AMO) submission form.
Packages come from `scripts/package-extensions.sh` (`build/extensions/*.zip`).

## Name

Nidestream Integration

(The manifest name. Searching "Nidestream" finds it in both stores.)

## Summary (132 characters max)

Send downloads, links and videos to the Nidestream download manager for macOS.

## Category

- Chrome Web Store: **Productivity → Tools** (or **Workflow & Planning**)
- Firefox Add-ons: **Download Management**

## Description

Nidestream Integration connects your browser to Nidestream, a free download manager for macOS that
makes downloads faster, resumes them after interruptions, and picks up expired links where they left
off.

With the extension installed and the Nidestream app running:

• Downloads you start in the browser go to Nidestream automatically (you choose which file types).
• Right-click any link and choose "Download with Nidestream".
• "Download all links" and "Download selected links" collect every file on a page so you can pick
  which ones to get.
• Videos and audio a page plays are detected, and a "Download video" button appears over large videos.
  Streaming videos (HLS) are saved as a single file.
• Downloads keep your login: the extension passes the page's cookies and address to Nidestream so
  files behind a sign-in still download.

Nidestream then downloads each file over several connections at once, pauses and resumes, keeps a
queue, schedules downloads and limits speed when you ask it to.

REQUIRES THE NIDESTREAM APP FOR macOS. Without the app running, the extension stays out of the way
and the browser downloads files as usual. Get the app at: https://thedanielbolu.github.io/Nidestream/

Privacy: the extension talks only to the Nidestream app on your own Mac (at 127.0.0.1). It sends
nothing to the developer or anyone else, and has no analytics. Privacy policy: https://thedanielbolu.github.io/Nidestream/privacy.html

## Single purpose (Chrome Web Store, Privacy tab)

Hand downloads, links and media from the browser to the Nidestream download manager app installed on
the same Mac, so Nidestream can download them.

## Permission justifications (Chrome Web Store, Privacy tab)

| Permission | Justification |
| --- | --- |
| `downloads` | To notice when the user starts a download, cancel it in the browser and hand the same file to the Nidestream app instead, which is the extension's purpose. If the app isn't running, the download is left to the browser. |
| `contextMenus` | Adds "Download with Nidestream", "Download selected links with Nidestream", "Download all links with Nidestream" and "Download media with Nidestream" to the right-click menu. |
| `webRequest` | Reads the content type and size of responses (never their contents) to recognise video and audio files and streaming playlists a page loads, so the user can download them. Nothing is blocked or modified. |
| `cookies` | Reads the cookies for a file's address when the user downloads it, and passes them only to the Nidestream app on the same Mac, so files behind a sign-in still download. Cookies are never sent anywhere else. |
| `storage` | Remembers the user's "Take over downloads" switch and the media found on open tabs. |
| `scripting` | When the user chooses "Download all links" or "Download selected links", reads the links on that page so the user can pick which files to download. Runs only on that user action. |
| Host permission `<all_urls>` | Downloads and videos can come from any website, so the extension needs to see download links, media responses and cookies on whatever site the user downloads from. It acts only on downloads, on media the page loads, and on the user's menu choices. |
| Content script on all pages | Shows the "Download video" button when the pointer is over a large video, and short status messages. It reads nothing from the page except the video's address when the user clicks the button. |

**Remote code:** No. All code is in the package.

## Data usage (Chrome Web Store, Privacy tab)

The extension does not collect user data: nothing it handles leaves the user's Mac. Download
addresses, page addresses, page titles and the cookies needed for a download are passed to the
Nidestream app on the same computer over 127.0.0.1, and used only to download the file.

Tick **Authentication information** (the cookies a download needs), **Web history** (the addresses and
titles of pages downloads come from) and **Website content** (the links read from a page for "Download all
links"). Strictly, none of it leaves the Mac, but declaring it matches the permissions a reviewer sees, and
the privacy policy explains that it all stays on the device. Leave the other types unticked, then tick all
three certifications: Nidestream doesn't sell user data, doesn't use it beyond downloading, and doesn't use
it for credit decisions.

## Firefox: data collection

The Firefox package declares `"data_collection_permissions": { "required": ["none"] }`, because no data
is transmitted to the developer or third parties. In the AMO reviewer notes, add:

> The extension only communicates with a companion macOS app on the same computer at
> http://127.0.0.1:51515. To test it, install Nidestream from https://thedanielbolu.github.io/Nidestream/, open it, then
> start any download (for example a .zip file) in Firefox: Nidestream takes it over.
> The app isn't notarized yet: after the first launch is blocked, open System Settings → Privacy &
> Security and click "Open Anyway".

## Support

- Homepage URL: https://thedanielbolu.github.io/Nidestream/
- Support URL: https://github.com/thedanielbolu/Nidestream/issues
- Privacy policy URL: https://thedanielbolu.github.io/Nidestream/privacy.html
