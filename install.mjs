import { execFileSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as https from 'node:https';
import * as os from 'node:os';
import * as path from 'node:path';

const RELEASE_URLS = [
  'https://api.github.com/repos/scheibo/ziglint/releases/latest',
  'https://api.github.com/repos/scheibo/ziglint/releases/tags/latest',
];

const OS_MAP = {
  linux: 'linux',
  darwin: 'macos',
  win32: 'windows',
};

const ARCH_MAP = {
  x64: 'x86_64',
  arm64: 'aarch64',
};

function httpGet(urlString, headers = {}, maxRedirects = 5) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlString);
    const req = https.get(
      url,
      {
        headers: {
          'User-Agent': 'scheibo-ziglint-action',
          ...headers,
        },
      },
      (res) => {
        const status = res.statusCode ?? 0;
        if ([301, 302, 303, 307, 308].includes(status) && res.headers.location) {
          res.resume();
          if (maxRedirects <= 0) {
            reject(new Error(`Too many redirects fetching ${urlString}`));
            return;
          }
          const nextUrl = new URL(res.headers.location, url);
          const nextHeaders = { ...headers };
          if (nextUrl.origin !== url.origin) {
            delete nextHeaders.Authorization;
          }
          resolve(httpGet(nextUrl.toString(), nextHeaders, maxRedirects - 1));
          return;
        }

        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => resolve({ status, body: Buffer.concat(chunks) }));
      }
    );
    req.on('error', reject);
  });
}

function hasZigOnPath() {
  try {
    execFileSync('zig', ['version'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

async function tryDownloadAsset(assetName, token, destPath) {
  const apiHeaders = { Accept: 'application/vnd.github+json' };
  if (token) {
    apiHeaders.Authorization = `Bearer ${token}`;
  }

  for (const releaseUrl of RELEASE_URLS) {
    let apiRes;
    try {
      apiRes = await httpGet(releaseUrl, apiHeaders);
    } catch (err) {
      console.warn(`Warning: failed to query ${releaseUrl}: ${err.message}`);
      continue;
    }

    if (apiRes.status !== 200) {
      continue;
    }

    let release;
    try {
      release = JSON.parse(apiRes.body.toString('utf8'));
    } catch {
      continue;
    }

    const assets = Array.isArray(release.assets) ? release.assets : [];
    const asset = assets.find((a) => a && a.name === assetName);
    if (!asset || !asset.browser_download_url) {
      continue;
    }

    console.log(`Downloading ${assetName} from ${asset.browser_download_url}...`);
    const dlHeaders = {};
    if (token) {
      dlHeaders.Authorization = `Bearer ${token}`;
    }
    const binRes = await httpGet(asset.browser_download_url, dlHeaders);
    if (binRes.status === 200 && binRes.body.length > 0) {
      fs.writeFileSync(destPath, binRes.body);
      return true;
    }
    console.warn(`Warning: downloading ${assetName} returned HTTP ${binRes.status}`);
  }

  return false;
}

async function main() {
  const binaryName = (process.env.INPUT_BINARY_NAME || 'ziglint').trim();
  const token = (process.env.INPUT_TOKEN || '').trim();
  const actionPath = process.env.GITHUB_ACTION_PATH || process.cwd();
  const runnerTemp = process.env.RUNNER_TEMP || os.tmpdir();

  const targetOs = OS_MAP[process.platform];
  const targetArch = ARCH_MAP[process.arch];
  if (!targetOs || !targetArch) {
    throw new Error(`Unsupported platform/architecture: ${process.platform}/${process.arch}`);
  }

  const ext = targetOs === 'windows' ? '.exe' : '';
  const assetName = `ziglint-${targetOs}-${targetArch}${ext}`;
  const binDir = path.join(runnerTemp, 'ziglint-bin');
  fs.mkdirSync(binDir, { recursive: true });
  const destPath = path.join(binDir, `${binaryName}${ext}`);

  const downloaded = await tryDownloadAsset(assetName, token, destPath);
  if (!downloaded) {
    if (!hasZigOnPath()) {
      throw new Error(
        `No prebuilt release asset '${assetName}' found on scheibo/ziglint and 'zig' is not on PATH to build from source.`
      );
    }
    console.log(`No prebuilt asset '${assetName}' found; building from source in ${actionPath}...`);
    const buildPrefix = path.join(runnerTemp, 'ziglint-build-out');
    const cacheDir = path.join(runnerTemp, 'ziglint-zig-cache');
    execFileSync(
      'zig',
      ['build', '-Doptimize=ReleaseFast', '--prefix', buildPrefix, '--cache-dir', cacheDir],
      { cwd: actionPath, stdio: 'inherit' }
    );
    const builtBinary = path.join(buildPrefix, 'bin', `ziglint${ext}`);
    fs.copyFileSync(builtBinary, destPath);
  }

  if (process.platform !== 'win32') {
    fs.chmodSync(destPath, 0o755);
  }

  if (process.env.GITHUB_PATH) {
    fs.appendFileSync(process.env.GITHUB_PATH, `${binDir}${os.EOL}`, 'utf8');
  }

  console.log(`Installed ${destPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
