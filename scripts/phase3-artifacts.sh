#!/usr/bin/env bash
# phase3-artifacts.sh — fetch the frp release on the FOREIGN server (which
# can reach GitHub), sign it with an ed25519 key that stays on that server,
# and install it into the panel's agent-artifacts directory so Iran agents
# can fetch it from the panel. Never requires GitHub access from Iran.
#
# Output (stdout): JSON with the pub key + per-arch pins for engine_params.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

FRP_VERSION="${FRP_VERSION:-0.61.1}"

ssh_run "$QL_GERMANY_HOST" bash -s <<EOF
set -euo pipefail
V="$FRP_VERSION"
mkdir -p /root/frp-release /etc/gre-panel/agent-artifacts
cd /root/frp-release
for arch in amd64 arm64; do
  f="frp_\${V}_linux_\${arch}.tar.gz"
  if [ ! -s "\$f" ]; then
    curl -fsSL -o "\$f" "https://github.com/fatedier/frp/releases/download/v\${V}/\${f}" \
      || curl -fsSL -o "\$f" "https://mirrors.tuna.tsinghua.edu.cn/github-release/fatedier/frp/v\${V}/\${f}" \
      || { echo "download failed for \$f" >&2; exit 1; }
  fi
  sha=\$(sha256sum "\$f" | awk '{print \$1}')
  echo "\$arch \$sha \$f"
done
# signing key: generated once, stays on this server (0600, wiped with /etc/gre-panel)
if [ ! -s /root/frp-release/engine-signing-key.ed25519 ]; then
  python3 - <<'PY'
import os
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
k = Ed25519PrivateKey.generate()
open('/root/frp-release/engine-signing-key.ed25519','wb').write(k.private_bytes(
    encoding=__import__('cryptography.hazmat.primitives.serialization',fromlist=['Encoding']).Encoding.Raw,
    format=__import__('cryptography.hazmat.primitives.serialization',fromlist=['PrivateFormat']).PrivateFormat.Raw,
    encryption_algorithm=__import__('cryptography.hazmat.primitives.serialization',fromlist=['NoEncryption']).NoEncryption()))
open('/root/frp-release/engine-pub.b64','w').write(__import__('base64').b64encode(k.public_key().public_bytes(
    encoding=__import__('cryptography.hazmat.primitives.serialization',fromlist=['Encoding']).Encoding.Raw,
    format=__import__('cryptography.hazmat.primitives.serialization',fromlist=['PublicFormat']).PublicFormat.Raw)).decode())
PY
  chmod 600 /root/frp-release/engine-signing-key.ed25519
fi
python3 - <<'PY'
import base64, hashlib, subprocess, json
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, NoEncryption, PublicFormat
key = Ed25519PrivateKey.from_private_bytes(open('/root/frp-release/engine-signing-key.ed25519','rb').read())
pub_b64 = open('/root/frp-release/engine-pub.b64').read().strip()
out = {"engine_artifact_pub_key_b64": pub_b64, "artifacts": {}}
for arch in ("amd64", "arm64"):
    f = f"/root/frp-release/frp_{arch}.tar.gz"
    import glob
    f = glob.glob(f"/root/frp-release/frp_*_linux_{arch}.tar.gz")[0]
    data = open(f, 'rb').read()
    sha = hashlib.sha256(data).hexdigest()
    sig = base64.b64encode(key.sign(data)).decode()
    dest = f.split('/')[-1].replace(f"frp_", "frp-").replace(f"_linux_", "-linux-")
    open(f"/etc/gre-panel/agent-artifacts/{dest}", 'wb').write(data)
    out["artifacts"][arch] = {"file": dest, "sha256": sha, "signature": sig}
print(json.dumps(out))
PY
EOF