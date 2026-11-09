"""Convert generated SVG to PDF without relying on Cairo's paint-order support."""
from copy import deepcopy
from pathlib import Path
import xml.etree.ElementTree as ET
import cairosvg

root_dir = Path(__file__).resolve().parent
ET.register_namespace("", "http://www.w3.org/2000/svg")
root = ET.parse(root_dir / "global-type-light.svg").getroot()
for parent in root.iter():
    for node in list(parent):
        if node.tag.endswith("}text") and node.get("paint-order") == "stroke":
            outline = deepcopy(node)
            outline.set("fill", "none")
            outline.attrib.pop("paint-order", None)
            parent.insert(list(parent).index(node), outline)
            for key in ("stroke", "stroke-width", "stroke-linejoin", "paint-order"):
                node.attrib.pop(key, None)
data = ET.tostring(root)
(root_dir / "global-type-diagram-print.svg").write_bytes(data)
cairosvg.svg2pdf(bytestring=data, write_to=str(root_dir / "global-type-diagram.pdf"))
cairosvg.svg2png(bytestring=data, write_to=str(root_dir / "global-type-diagram.png"))
