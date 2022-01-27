import
  ../suggestapi,
  faststreams/async_backend,
  faststreams/textio,
  faststreams/inputs,
  faststreams/outputs,
  faststreams/asynctools_adapters,
  strutils,
  os,
  asyncdispatch,
  asynctools/asyncproc,
  faststreams/asynctools_adapters,
  faststreams/textio


let process = startProcess(# command = "cat /home/yyoncho/Sources/nim/langserver/tests/projects/hw/hw.nim",
                           command = "/home/yyoncho/.nimble/bin/nimsuggest --stdin --find /home/yyoncho/Sources/nim/langserver/tests/projects/hw/hw.nim",
                           # command = "/home/yyoncho/.nimble/bin//nimlsp",
                           workingDir = getCurrentDir(),
                           options = {poUsePath, poEvalCommand})

let input = asyncPipeInput(process.outputHandle)

let output = asyncPipeOutput(process.inputHandle, allowWaitFor = true)

proc send(input: AsyncOutputStream): Future[void] {.async} =
  write(OutputStream(output), "def /home/yyoncho/Sources/nim/langserver/tests/projects/hw/hw.nim:2:0\n")
  flush(output)


proc processOutput(input: AsyncInputStream): Future[void] {.async} =
  while input.readable:
    let line = await input.readLine();
    echo ">>>>>>> ", line
  echo "Done........."


waitFor send(output)
waitFor processOutput(input)

# waitFor processOutput(input)
