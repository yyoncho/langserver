proc a() = discard
a()
var bbb = 100
bbb = 200
bbb = ""

import std/macros

macro myAssertMacroInner(arg: untyped): untyped =
  result = quote do:
    `arg`



macro helloMacro*(prc: untyped): untyped =
  result = quote do:
    proc helloProc(): string = "Hello"

#[!]#proc helloProc(): void {.helloMacro.}=
  discard

proc call(i: int): void =
  discard
