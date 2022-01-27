import
  unittest,
  os,
  std/osproc,
  ../suggestapi,
  faststreams/async_backend,
  faststreams/textio,
  faststreams/inputs,
  faststreams/outputs,
  faststreams/asynctools_adapters

# let process = startProcess(command = "/home/yyoncho/Sources/nim/langserver/tests/projects/hw/hw.nim",
#                            workingDir = getCurrentDir(),
#                            options = {poUsePath, poEvalCommand})

# let input = asyncPipeInput(process.outputHandle)


# proc foo(input: AsyncInputStream): Future[void] {.async} =
#   while async.readable:
#     let line = input.readLine();
#     echo ">>>>>>> ", line


# waitFor foo()

var process = try:
  startProcess(command = "cat" & " " & "/home/yyoncho/Sources/nim/jsonrpc/test/fixtures/message.txt",
               workingDir = getCurrentDir(),
               options = {poUsePath, poEvalCommand})
except CatchableError as err:
  echo "Failed to start process"
  echo err.msg
  quit 1

let b = asyncPipeInput(process.outputHandle)
