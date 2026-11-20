export const feedURL = 'https://mailpipeai.com/appcast.xml';

// This shipped build predates the updater and has no archive signature.
export function predatesUpdater(release) {
  return release.build === 34 && release.version === '0.1.0' &&
    release.sha256 === 'f076181f021a75ed133f9f4c048e0463558b08c2b746b36e06ecfd36a789dbf9';
}

function updateItem(release) {
  if (predatesUpdater(release)) return '';
  if (!Number.isSafeInteger(release.build) || release.build <= 34 ||
      !Number.isSafeInteger(release.bytes) || release.bytes <= 0 ||
      !/^\d+(\.\d+){0,2}$/.test(release.version) ||
      !/^\d+\.\d+\.\d+$/.test(release.minimumSystemVersion) ||
      !/^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$/.test(release.filename) ||
      !/^[A-Za-z0-9+/]{86}==$/.test(release.edSignature)) {
    throw new Error('Invalid Sparkle release metadata. Check the build, versions, ZIP and edSignature.');
  }
  const url = new URL('/downloads/' + release.filename, feedURL);
  return `    <item>
      <title>Mailpipe ${release.version}</title>
      <link>https://mailpipeai.com/</link>
      <sparkle:version>${release.build}</sparkle:version>
      <sparkle:shortVersionString>${release.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${release.minimumSystemVersion}</sparkle:minimumSystemVersion>
      <enclosure url="${url}" length="${release.bytes}" type="application/octet-stream" sparkle:edSignature="${release.edSignature}"/>
    </item>
`;
}

export function appcast(release) {
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mailpipe</title>
    <link>${feedURL}</link>
    <description>Mailpipe updates for macOS</description>
${updateItem(release)}  </channel>
</rss>
`;
}
