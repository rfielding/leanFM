#!/usr/bin/env python3
"""Mechanical view generation from Lean output, protoc descriptors and observations.
R3/R5: no invented messages, screenshots or protocol sequences.
"""
import json
from pathlib import Path
import sys
from google.protobuf.descriptor import FieldDescriptor as F

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".cache/proto"))
import Requirements_pb2 as pb

spec = json.loads((ROOT / "spec/tasks.json").read_text())


def field_schema(field):
    if field.type == F.TYPE_MESSAGE:
        result = {"$ref": "#/components/schemas/" + field.message_type.name}
    elif field.type == F.TYPE_STRING:
        result = {"type": "string"}
    elif field.type == F.TYPE_BOOL:
        result = {"type": "boolean"}
    else:
        result = {"type": "integer", "format": "int64" if field.type == F.TYPE_INT64 else "int32"}
        if field.type == F.TYPE_UINT32:
            result["minimum"] = 0
    return {"type": "array", "items": result} if field.label == F.LABEL_REPEATED else result


schemas = {message.name: {"type": "object", "additionalProperties": False,
                         "properties": {f.name: field_schema(f) for f in message.fields}}
           for message in pb.DESCRIPTOR.message_types_by_name.values()}
paths = {}
for contract in spec["http"]:
    operation = {"operationId": contract["task"], "x-leanfm-requirement": "spec/Requirements.lean#" + contract["task"],
                 "description": contract["authentication"] + ". " + contract["response_codec"], "responses": {}}
    if "{id}" in contract["path"]:
        operation["parameters"] = [{"in": "path", "name": "id", "required": True,
                                   "schema": {"type": "string", "pattern": "^[a-f0-9]{48}$"}}]
    if contract["method"] == "POST":
        operation["requestBody"] = {"required": True, "content": {"application/json": {
            "schema": {"$ref": "#/components/schemas/" + contract["requests"][0]}}}}
    if contract["task"] == "play_turn":
        operation["security"] = [{"seatToken": []}]
    for status in contract["statuses"]:
        if contract["task"] == "export_gif":
            mime = "image/gif" if status == 200 else "text/plain"
            response = {"description": contract["response_codec"], "content": {mime: {"schema": {"type": "string"}}},
                        "headers": {"X-GoServer-Trace": {"description": "Base64 JSON TraceEvent array, including direct cause/prior links", "schema": {"type": "string"}}}}
            if status == 200:
                response["headers"].update({name: {"schema": {"type": "string"}} for name in ["X-GoServer-Artifact", "X-GoServer-Final-Ply"]})
        else:
            mime = "text/plain" if status == 403 and contract["task"] != "play_turn" else "application/json"
            response = {"description": "Terminal outcome; Host/Origin admission failures are plain HTTP 403",
                        "content": {mime: {"schema": {"$ref": "#/components/schemas/Response"} if mime == "application/json" else {"type": "string"}}}}
            if status == 403:
                response["content"]["text/plain"] = {"schema": {"type": "string"}}
        operation["responses"][str(status)] = response
    paths.setdefault(contract["path"], {})[contract["method"].lower()] = operation
document = {"openapi": "3.1.0", "info": {"title": "GoServer playable HTTP contract", "version": spec["revision"]},
            "servers": [{"url": "/"}], "paths": paths,
            "components": {"schemas": schemas, "securitySchemes": {"seatToken": {"type": "http", "scheme": "bearer"}}}}
# JSON is a YAML 1.2 document. Exact fields come from protoc, not copied schemas.
(ROOT / "source/server/web/openapi.yaml").write_text(json.dumps(document, indent=2) + "\n")

evidence = ROOT / "evidence/playable-v1/protocol.json"
if evidence.exists():
    observed = next(events for events in json.loads(evidence.read_text())["observed_scenarios"]
                    if events[0]["task"] == "play_turn" and len(events) == 3)
    lines = [r"\begin{tikzpicture}[x=1cm,y=0.9cm,>=stealth]",
             r"\node (client) at (0,0) {Client};", r"\node (server) at (8,0) {GoServer};",
             r"\draw[dashed] (0,-.3) -- (0,-4);", r"\draw[dashed] (8,-.3) -- (8,-4);"]
    alt = []
    for i, event in enumerate(observed, 1):
        a, b = (0, 8) if event["src"] == "Client" else (8, 0)
        lines.append(r"\draw[->] (%d,-%d) -- node[above] {\texttt{%s}} (%d,-%d);" % (a, i, event["message"], b, i))
        alt.append("Message from %s to %s: %s." % (event["src"], event["dst"], event["message"]))
    lines.insert(0, r"\BeginAccSupp{method=escape,ActualText={" + " ".join(alt) + "}}")
    lines.extend([r"\end{tikzpicture}", r"\EndAccSupp{}"])
    (ROOT / "book/generated").mkdir(exist_ok=True)
    (ROOT / "book/generated/observed-turn.tex").write_text("\n".join(lines) + "\n")
    (ROOT / "book/generated/observed-turn-alt.tex").write_text(" ".join(alt) + "\n")
print("ok: OpenAPI schemas from protoc and requirements-owned routes; observed view from trace when available")
