import
  macros,
  strformat,
  faststreams/async_backend,
  faststreams/asynctools_adapters,
  faststreams/inputs,
  faststreams/outputs,
  json_rpc/streamconnection,
  os,
  sugar,
  sequtils,
  hashes,
  osproc,
  suggestapi,
  protocol/enums,
  protocol/types,
  streams,
  uri,
  with,
  tables,
  strutils,
  sets,
  ./utils

const storage = getTempDir() / "nls"
discard existsOrCreateDir(storage)

type
  UriParseError* = object of Defect
    uri: string

macro `%*`*(t: untyped, input: untyped): untyped =
  result = newCall(bindSym("to", brOpen),
                   newCall(bindSym("%*", brOpen), input), t)

proc copyStdioToPipe(pipe: AsyncPipe) {.thread.} =
  var
    inputStream = newFileStream(stdin)
    ch = "X"

  ch[0] = inputStream.readChar();
  while ch[0] != '\0':
    discard waitFor write(pipe, ch[0].addr, 1)
    ch[0] = inputStream.readChar();

proc partial[A, B, C] (fn: proc(a: A, b: B): C {.gcsafe.}, a: A):
    proc (b: B) : C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
  return
    proc(b: B): C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
      return fn(a, b)

type Certainty = enum
  None,
  Folder,
  Cfg,
  Nimble

proc getProjectFile(fileUri: string): string =
  let file = fileUri.decodeUrl
  result = file
  let (dir, _, _) = result.splitFile()
  var
    path = dir
    certainty = None
  while path.len > 0 and path != "/":
    let
      (dir, fname, ext) = path.splitFile()
      current = fname & ext
    if fileExists(path / current.addFileExt(".nim")) and certainty <= Folder:
      result = path / current.addFileExt(".nim")
      certainty = Folder
    if fileExists(path / current.addFileExt(".nim")) and
      (fileExists(path / current.addFileExt(".nim.cfg")) or
      fileExists(path / current.addFileExt(".nims"))) and certainty <= Cfg:
      result = path / current.addFileExt(".nim")
      certainty = Cfg
    if certainty <= Nimble:
      for nimble in walkFiles(path / "*.nimble"):
        let info = execProcess("nimble dump " & nimble)
        var sourceDir, name: string
        for line in info.splitLines:
          if line.startsWith("srcDir"):
            sourceDir = path / line[(1 + line.find '"')..^2]
          if line.startsWith("name"):
            name = line[(1 + line.find '"')..^2]
        let projectFile = sourceDir / (name & ".nim")
        if sourceDir.len != 0 and name.len != 0 and
            file.isRelativeTo(sourceDir) and fileExists(projectFile):
          result = projectFile
          certainty = Nimble
    path = dir

proc pathToUri*(path: string): string =
  # This is a modified copy of encodeUrl in the uri module. This doesn't encode
  # the / character, meaning a full file path can be passed in without breaking
  # it.
  result = "file://" & newStringOfCap(path.len + path.len shr 2) # assume 12% non-alnum-chars
  for c in path:
    case c
    # https://tools.ietf.org/html/rfc3986#section-2.3
    of 'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/': add(result, c)
    else:
      add(result, '%')
      add(result, toHex(ord(c), 2))

proc uriToPath(uri: string): string =
  ## Convert an RFC 8089 file URI to a native, platform-specific, absolute path.
  #let startIdx = when defined(windows): 8 else: 7
  #normalizedPath(uri[startIdx..^1])
  let parsed = uri.parseUri
  if parsed.scheme != "file":
    var e = newException(UriParseError,
      "Invalid scheme: {parsed.scheme}, only \"file\" is supported".fmt)
    e.uri = uri
    raise e
  if parsed.hostname != "":
    var e = newException(UriParseError,
      "Invalid hostname: {parsed.hostname}, only empty hostname is supported".fmt)
    e.uri = uri
    raise e
  return normalizedPath(
    when defined(windows):
      parsed.path[1..^1]
    else:
      parsed.path).decodeUrl

type
  LanguageServer* = ref object
    projectFiles: Table[string, tuple[nimsuggest: SuggestApi,
                                      openFiles: OrderedSet[string]]]
    openFiles: Table[string, tuple[projectFile: string,
                                   fingerTable: seq[seq[tuple[u16pos, offset: int]]]]]
    clientCapabilities*: ClientCapabilities

proc getCharacter(ls: LanguageServer, uri: string, line: int, character: int): int =
  return ls.openFiles[uri].fingerTable[line].utf16to8(character)

proc initialize(ls: LanguageServer, params: InitializeParams):
    Future[InitializeResult] {.async} =
  debugEcho "Initialize, starting..."
  ls.clientCapabilities = params.capabilities;
  return InitializeResult(
    capabilities: ServerCapabilities(
      textDocumentSync: %TextDocumentSyncOptions(
        openClose: some(true),
        change: some(TextDocumentSyncKind.Full.int),
        willSave: some(false),
        willSaveWaitUntil: some(false),
        save: some(SaveOptions(includeText: some(true)))),
      hoverProvider: some(true),
      completionProvider: CompletionOptions(
        resolveProvider: some(false)),
      signatureHelpProvider: SignatureHelpOptions(
        triggerCharacters: some(@["(", ","])),
      definitionProvider: some(true),
      referencesProvider: some(true)#,
      # documentSymbolProvider: some(true),
      # renameProvider: some(true)
      ))

proc initialized(_: JsonNode):
    Future[void] {.async} =
  debugEcho "Client initialized."

proc uriToStash(uri: string): string =
  storage / (hash(uri).toHex & ".nim")

proc didOpen(ls: LanguageServer, params: DidOpenTextDocumentParams):
    Future[void] {.async, gcsafe.} =
   with params.textDocument:
     let
       fileStash = uriToStash(uri)
       file = open(fileStash, fmWrite)
       projectFile = getProjectFile(uriToPath(uri))

     debugEcho "New document opened for URI: ", uri, " saving to " & fileStash
     ls.openFiles[uri] = (
       projectFile: projectFile,
       fingerTable: @[])

     if not ls.projectFiles.hasKey(projectFile):
       ls.projectFiles[projectFile] = (nimsuggest: createSuggestApi(projectFile),
                                       openFiles: initOrderedSet[string]())
     ls.projectFiles[projectFile].openFiles.incl(uri)

     for line in text.splitLines:
       ls.openFiles[uri].fingerTable.add line.createUTFMapping()
       file.writeLine line
     file.close()

template getNimsuggest(ls: LanguageServer, uri: string): SuggestApi =
  ls.projectFiles[ls.openFiles[uri].projectFile].nimsuggest

proc didChange(ls: LanguageServer, params: DidChangeTextDocumentParams):
    Future[void] {.async, gcsafe.} =
   with params:
     let
       uri = textDocument.uri
       path = uriToPath(uri)
       fileStash = uriToStash(uri)
       file = open(fileStash, fmWrite)

     ls.openFiles[uri].fingerTable = @[]
     for line in contentChanges[0].text.splitLines:
       ls.openFiles[uri].fingerTable.add line.createUTFMapping()
       file.writeLine line
     file.close()

     discard ls.getNimsuggest(uri).mod(path, dirtyfile = filestash)

proc toMarkedStrings(suggest: Suggest): seq[MarkedStringOption] =
  var label = suggest.qualifiedPath.join(".")
  if suggest.forth != "":
    label &= ": " & suggest.forth

  result = @[
    MarkedStringOption %* {
       "language": "nim",
       "value": label
    }
  ]

  if suggest.doc != "":
    result.add MarkedStringOption %* {
       "language": "markdown",
       "value": suggest.doc
    }

proc hover(ls: LanguageServer, params: HoverParams):
    Future[Option[Hover]] {.async} =
  with (params.position, params.textDocument):
    let
      suggestions = await ls.getNimsuggest(uri).def(
        uriToPath(uri),
        uriToStash(uri),
        line + 1,
        ls.getCharacter(uri, line, character))
    if suggestions.len == 0:
      return none[Hover]();
    else:
      return some(Hover(contents: %toMarkedStrings(suggestions[0])))

proc toLocation(suggest: Suggest): Location =
  with suggest:
    return Location %* {
      "uri": pathToUri(filepath),
      "range": {
         "start": {
            "line": line - 1,
            "character": column
         },
         "end": {
            "line": line - 1,
            "character": column + qualifiedPath[^1].len
         }
      }
    }

proc definition(ls: LanguageServer, params: TextDocumentPositionParams):
    Future[seq[Location]] {.async} =
  with (params.position, params.textDocument):
    return ls
      .getNimsuggest(uri)
      .def(uriToPath(uri),
           uriToStash(uri),
           line + 1,
           ls.getCharacter(uri, line, character))
      .await()
      .map(toLocation);

proc references(ls: LanguageServer, params: ReferenceParams):
    Future[seq[Location]] {.async} =
  with (params.position, params.textDocument, params.context):
    return ls
      .getNimsuggest(uri)
      .use(uriToPath(uri),
           uriToStash(uri),
           line + 1,
           ls.getCharacter(uri, line, character))
      .await()
      .filter(suggest => suggest.section != ideDef or includeDeclaration)
      .map(toLocation);

proc toCompletionItem(suggest: Suggest): CompletionItem =
  with suggest:
    return CompletionItem %* {
      "label": qualifiedPath[^1].strip(chars = {'`'}),
      "kind": nimSymToLSPKind(suggest).int,
      "documentation": doc,
      "detail": nimSymDetails(suggest)
    }

proc completion(ls: LanguageServer, params: CompletionParams):
    Future[seq[CompletionItem]] {.async} =
  with (params.position, params.textDocument):
    return ls
      .getNimsuggest(uri)
      .sug(uriToPath(uri),
           uriToStash(uri),
           line + 1,
           ls.getCharacter(uri, line, character))
      .await()
      .map(toCompletionItem);

proc registerLanguageServerHandlers*(connection: StreamConnection) =
  let ls = LanguageServer(
    projectFiles: initTable[string, tuple[nimsuggest: SuggestApi,
                                          openFiles: OrderedSet[string]]](),
    openFiles: initTable[string, tuple[projectFile: string,
                                       fingerTable: seq[seq[tuple[u16pos, offset: int]]]]]())
  connection.register("initialize", partial(initialize, ls))
  connection.registerNotification("initialized", initialized)
  connection.registerNotification("textDocument/didOpen", partial(didOpen, ls))
  connection.registerNotification("textDocument/didChange", partial(didChange, ls))
  connection.register("textDocument/hover", partial(hover, ls))
  connection.register("textDocument/definition", partial(definition, ls))
  connection.register("textDocument/references", partial(references, ls))
  connection.register("textDocument/completion", partial(completion, ls))

when isMainModule:
  var
    pipe = createPipe(register = true)
    stdioThread: Thread[AsyncPipe]

  createThread(stdioThread, copyStdioToPipe, pipe)

  let connection = StreamConnection.new(asyncPipeInput(pipe),
                                        Async(fileOutput(stdout, allowAsyncOps = true)));
  registerLanguageServerHandlers(connection)
  waitFor connection.start()
