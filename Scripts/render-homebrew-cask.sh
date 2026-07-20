#!/usr/bin/env bash
# Render the Homebrew cask for a Continuo release.
# Usage: render-homebrew-cask.sh <version> <sha256> [output-file]
#   version: release version without the "v" prefix (e.g. 0.2.4)
#   sha256:  SHA-256 of dist/Continuo.dmg
#   output-file: defaults to stdout
set -euo pipefail

VERSION="${1:?version is required (e.g. 0.2.4)}"
SHA256="${2:?sha256 is required}"
OUTPUT="${3:--}"

if [[ "${VERSION}" == v* ]]
then
  echo "error: version must not include the v prefix" >&2
  exit 1
fi

if [[ ! "${SHA256}" =~ ^[0-9a-f]{64}$ ]]
then
  echo "error: sha256 must be 64 lowercase hex characters" >&2
  exit 1
fi

render() {
  cat <<EOF
cask "continuo" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/yoavf/continuo/releases/download/v#{version}/Continuo.dmg"
  name "Continuo"
  desc "Continue a coding-agent session in a different agent"
  homepage "https://github.com/yoavf/continuo"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Continuo.app"

  zap trash: [
    "~/Library/Application Support/AgentSync",
    "~/Library/Preferences/org.farhi.continuo.plist",
  ]
end
EOF
}

if [[ "${OUTPUT}" == "-" ]]
then
  render
else
  render >"${OUTPUT}"
fi
