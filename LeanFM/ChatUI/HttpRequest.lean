namespace LeanFM.ChatUI.HttpRequest

-- Requirement ref: http_dispatch_requires_complete_frame.
abbrev FrameError := Nat × String
def maxHeaderBytes : Nat := 32768
def maxBodyBytes : Nat := 8388608

def headerEnd? (bytes : ByteArray) : Option Nat := Id.run do
  for i in [:min bytes.size (maxHeaderBytes + 4)] do
    if bytes[i]! == 13 && bytes[i+1]?.getD 0 == 10 &&
        bytes[i+2]?.getD 0 == 13 && bytes[i+3]?.getD 0 == 10 then
      return some (i + 4)
  return none

def headerToken (value : String) : Bool :=
  !value.isEmpty && value.toList.all (fun c =>
    (c.toNat < 128 && c.isAlphanum) || "!#$%&'*+-.^_`|~".contains c)

/-- `bodyCap` sizes the body from the request's LeanFM-Limits header (its value, if any): never
below `maxBodyBytes`, so only a header can raise the cap, and only as far as the caller allows. -/
def frameLength? (bytes : ByteArray) (bodyCap : Option String → Nat := fun _ => maxBodyBytes) : Except FrameError (Option Nat) := do
  let some headerEnd := headerEnd? bytes
    | if bytes.size > maxHeaderBytes then throw (431, "HTTP header exceeds the 32 KiB limit.") else return none
  if headerEnd > maxHeaderBytes then throw (431, "HTTP header exceeds the 32 KiB limit.")
  let some head := String.fromUTF8? (bytes.extract 0 (headerEnd - 4))
    | throw (400, "Invalid HTTP header encoding.")
  let requestLine :: headers := head.splitOn "\r\n" | throw (400, "Missing HTTP request line.")
  match requestLine.splitOn " " with
  | [method, target, version] =>
      if !headerToken method || target.isEmpty || !(version == "HTTP/1.1" || version == "HTTP/1.0") then
        throw (400, "Invalid HTTP request line.")
  | _ => throw (400, "Invalid HTTP request line.")
  if headers.length > 100 then throw (431, "Too many HTTP header fields.")
  let mut lengths : List String := []
  let mut transfer := false
  let mut expect := false
  let mut limitsHeader : Option String := none
  for line in headers do
    let name :: parts := line.splitOn ":" | throw (400, "Invalid HTTP header field.")
    if !headerToken name || parts.isEmpty then throw (400, "Invalid HTTP header field.")
    let value := String.intercalate ":" parts
    if value.toList.any (fun c => (c.toNat < 32 && c != '\t') || c.toNat == 127) then
      throw (400, "Invalid HTTP header field value.")
    if name.toLower == "content-length" then lengths := value.trimAscii.toString :: lengths
    if name.toLower == "transfer-encoding" then transfer := true
    if name.toLower == "expect" then expect := true
    if name.toLower == "leanfm-limits" then limitsHeader := some value.trimAscii.toString
  if transfer then throw (400, "Transfer-Encoding is unsupported; use one Content-Length.")
  if expect then throw (417, "Expect is unsupported; send a bounded Content-Length request.")
  if lengths.length > 1 then throw (400, "Duplicate Content-Length is not accepted.")
  let bodyLength ← match lengths with
    | [] => pure 0
    | value :: _ => do
        if value.isEmpty || value.length > 10 || !value.toList.all Char.isDigit then
          throw (400, "Content-Length must be a bounded decimal byte count.")
        let some count := value.toNat? | throw (400, "Invalid Content-Length.")
        pure count
  let cap := max maxBodyBytes (bodyCap limitsHeader)
  if bodyLength > cap then
    throw (413, s!"HTTP body exceeds the {cap}-byte limit; send the header LeanFM-Limits: requestBytes={bodyLength} to allow it (up to the operator's ceiling), or name the data instead of sending it (serverLog, file)")
  -- bytes after the frame begin the next request on a kept connection; the reader takes exactly
  -- `expected` bytes for this one (selfhost.mcp.keepalive)
  return some (headerEnd + bodyLength)

end LeanFM.ChatUI.HttpRequest
