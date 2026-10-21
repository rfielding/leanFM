import LeanFM.ChatUI.HttpRequest

open LeanFM.ChatUI.HttpRequest

-- Requirement ref: http_dispatch_requires_complete_frame.
def frame (headers body : String) : ByteArray :=
  ("POST /api/login HTTP/1.1\r\nHost: localhost\r\n" ++ headers ++ "\r\n" ++ body).toUTF8

example : ((frameLength? (frame "Content-Length: 5\r\n" "ab")).toOption.bind id).isSome := by native_decide
example : (frameLength? "POST /api/login HTTP/1.1\r\n".toUTF8).toOption == some none := by native_decide
example : (frameLength? (frame "Content-Length: 2\r\n" "abc")).toOption.isNone := by native_decide
example : (frameLength? (frame "Content-Length: 2\r\nContent-Length: 2\r\n" "ab")).toOption.isNone := by native_decide
example : (frameLength? (frame "Content-Length: 2\r\nTransfer-Encoding: chunked\r\n" "ab")).toOption.isNone := by native_decide
example : (frameLength? (frame "Content-Length : 2\r\n" "ab")).toOption.isNone := by native_decide
example : (frameLength? (frame "Content-Length: -1\r\n" "")).toOption.isNone := by native_decide
example : (frameLength? (frame "Content-Length: 8388609\r\n" "")).toOption.isNone := by native_decide
example : ((frameLength? (frame "Content-Length: 2\r\n" "é")).toOption.bind id) ==
    some (frame "Content-Length: 2\r\n" "é").size := by native_decide
