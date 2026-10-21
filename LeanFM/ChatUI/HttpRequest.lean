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

def frameLength? (bytes : ByteArray) : Except FrameError (Option Nat) := do
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
  for line in headers do
    let name :: parts := line.splitOn ":" | throw (400, "Invalid HTTP header field.")
    if !headerToken name || parts.isEmpty then throw (400, "Invalid HTTP header field.")
    let value := String.intercalate ":" parts
    if value.toList.any (fun c => (c.toNat < 32 && c != '\t') || c.toNat == 127) then
      throw (400, "Invalid HTTP header field value.")
    if name.toLower == "content-length" then lengths := value.trimAscii.toString :: lengths
    if name.toLower == "transfer-encoding" then transfer := true
    if name.toLower == "expect" then expect := true
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
  if bodyLength > maxBodyBytes then throw (413, "HTTP body exceeds the 8 MiB limit.")
  let expected := headerEnd + bodyLength
  if bytes.size > expected then throw (400, "Extra bytes after one HTTP request are not accepted.")
  return some expected

end LeanFM.ChatUI.HttpRequest
