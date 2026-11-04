import sys
from pathlib import Path

build = Path(sys.argv[1])
out = Path(sys.argv[2])
parts = {
    "__KILLSWITCH__": "killswitch.sh",
    "__WAIT_READY__": "wait-ready.sh",
    "__OCSERV_CONF__": "ocserv.conf",
    "__PROXY_CFG__": "3proxy.cfg",
    "__PROXY_START__": "proxy-start.sh",
    "__VPNUSER__": "vpnuser.sh",
}
text = (build / "compose.tmpl.yml").read_text()
for marker, name in parts.items():
    body = (build / name).read_text().replace("$", "$$")
    block = "\n".join(("      " + l) if l else "" for l in body.rstrip("\n").split("\n"))
    text = text.replace(marker, block)
out.write_text(text)
