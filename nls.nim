import
  faststreams/async_backend,
  faststreams/asynctools_adapters,
  faststreams/textio,
  faststreams/inputs

proc copyStdioToPipe(pipe: AsyncPipe) {.thread.} =
  var ch = "X222"
  var ch2 = "\n"

  while ch[0] != '\0':
    discard waitFor write(pipe, ch[0].addr, 1)
    discard waitFor write(pipe, ch[0].addr, 1)
    discard waitFor write(pipe, ch[0].addr, 1)
    discard waitFor write(pipe, ch[0].addr, 1)
    discard waitFor write(pipe, ch[0].addr, 1)
    discard waitFor write(pipe, ch[0].addr, 1)
    discard waitFor write(pipe, ch2[0].addr, 1)

proc myReadLine(input: AsyncInputStream): Future[void] {.async.} =
  while input.readable:
    discard input.readLine()

when isMainModule:
  var
    pipe = createPipe(register = true)
    stdioThread: Thread[AsyncPipe]

  createThread(stdioThread, copyStdioToPipe, pipe)
  let a = asyncPipeInput(pipe)
  waitFor(myReadLine(a))
