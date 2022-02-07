import
  posix,
  os,
  faststreams/async_backend,
  faststreams/asynctools_adapters,
  faststreams/textio,
  faststreams/inputs

proc writeToPipe(p: AsyncPipe, data: pointer, nbytes: int) =
  if posix.write(p.getWriteHandle, data, cint(nbytes)) < 0:
    raiseOsError(osLastError())

proc copyStdioToPipe(pipe: AsyncPipe) {.thread.} =
  var ch = "X222"
  var ch2 = "\n"

  while ch[0] != '\0':
    writeToPipe(pipe, ch[0].addr, 1)
    writeToPipe(pipe, ch[0].addr, 1)
    writeToPipe(pipe, ch[0].addr, 1)
    writeToPipe(pipe, ch[0].addr, 1)
    writeToPipe(pipe, ch[0].addr, 1)
    writeToPipe(pipe, ch[0].addr, 1)
    writeToPipe(pipe, ch2[0].addr, 1)

proc myReadLine(input: AsyncInputStream): Future[void] {.async.} =
  while input.readable:
    echo await input.readLine()

when isMainModule:
  var
    pipe = createPipe(register = true)
    stdioThread: Thread[AsyncPipe]

  createThread(stdioThread, copyStdioToPipe, pipe)
  let a = asyncPipeInput(pipe)
  waitFor(myReadLine(a))
