#!/usr/bin/env python3
"""Update one cask through GitHub's Contents API, with optimistic concurrency."""
import base64
import hashlib
import json
import pathlib
import re
import subprocess
import sys

version, artifact = sys.argv[1:]
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("Expected x.y.z")
sha = hashlib.sha256(pathlib.Path(artifact).read_bytes()).hexdigest()
# Ensure the public release asset matches the local artifact before updating the tap.
release = json.loads(subprocess.check_output(["gh", "release", "view", "v" + version, "--repo", "alepee/how-was-your-day", "--json", "assets,isDraft"]))
if release['isDraft'] or not any(a['name'] == 'HowWasYourDay.dmg' and a.get('digest') == 'sha256:' + sha for a in release['assets']):
    raise SystemExit("Published asset SHA-256 missing or mismatched")
cask = '''cask "how-was-your-day" do
  version "%s"
  sha256 "%s"

  url "https://github.com/alepee/how-was-your-day/releases/download/v#{version}/HowWasYourDay.dmg"
  name "How Was Your Day"
  desc "Record, transcribe and review conversations locally"
  homepage "https://github.com/alepee/how-was-your-day"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "How Was Your Day.app"

  uninstall quit: "dev.lepee.hwyd"

  caveats <<~EOS
    This experimental app is not notarized by Apple.
    On first launch, use System Settings > Privacy & Security > Open Anyway.
    Recordings are kept in ~/Library/Application Support/HWYD.
    Uninstalling does not delete recordings or voice enrollment data.
  EOS
end
''' % (version, sha)
endpoint = 'repos/alepee/homebrew-tap/contents/Casks/how-was-your-day.rb'
existing = subprocess.run(['gh', 'api', endpoint], capture_output=True, text=True)
body = {'message': 'chore(how-was-your-day): release ' + version, 'content': base64.b64encode(cask.encode()).decode()}
if existing.returncode == 0:
    current = json.loads(existing.stdout)
    if base64.b64decode(current['content']).decode() == cask:
        print('Homebrew cask already up to date'); sys.exit(0)
    body['sha'] = current['sha']
elif '404' not in existing.stderr:
    raise SystemExit(existing.stderr)
subprocess.run(['gh', 'api', '--method', 'PUT', endpoint, '--input', '-'], input=json.dumps(body), text=True, check=True, stdout=subprocess.DEVNULL)
print('Updated alepee/homebrew-tap/how-was-your-day')
